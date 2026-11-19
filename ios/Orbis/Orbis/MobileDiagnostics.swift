import Combine
import Foundation

/// Opt-in attachment diagnostics. Callers pass only state/counts and attempt IDs,
/// never chat text, file names/paths, selected file contents, or credentials.
@MainActor final class MobileDiagnostics: ObservableObject {
    static let shared = MobileDiagnostics()
    static let preferenceKey = "orbis.mobileDiagnostics.enabled"

    @Published private(set) var enabled: Bool
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var storageError = false

    private let defaults: UserDefaults
    private let journal: MobileDiagnosticJournal
    private var sender: (([String: Any]) -> Bool)?

    init(directory: URL? = nil, defaults: UserDefaults = .standard,
         heartbeatQueue: DispatchQueue = .main, heartbeatInterval: TimeInterval = 1,
         stallAfter: TimeInterval = 2, waitingAfter: TimeInterval = 10,
         retryAfter: TimeInterval = 5) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.preferenceKey)
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Orbis/MobileDiagnostics", isDirectory: true)
        journal = MobileDiagnosticJournal(directory: directory, heartbeatQueue: heartbeatQueue,
            heartbeatInterval: heartbeatInterval, stallAfter: stallAfter,
            waitingAfter: waitingAfter, retryAfter: retryAfter)
        journal.start(enabled: enabled, status: { [weak self] count, uploaded, storageError in
            DispatchQueue.main.async { [weak self] in
                self?.pendingCount = count
                self?.lastUploadAt = uploaded
                self?.storageError = storageError
            }
        }, send: { [weak self] batch, completion in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.enabled else { completion(false); return }
                completion(self.sender?(batch) ?? false)
            }
        })
    }

    func setEnabled(_ value: Bool, context: [String: String] = [:]) {
        guard value != enabled else { return }
        enabled = value
        defaults.set(value, forKey: Self.preferenceKey)
        journal.setEnabled(value, context: context)
    }

    func record(_ event: String, severity: String = "info", detail: [String: String] = [:]) {
        journal.record(event, severity: severity, detail: detail)
    }

    func beginFilePicker(detail: [String: String] = [:]) { journal.beginFilePicker(detail: detail) }
    func endFilePicker(reason: String, attemptId: String? = nil) {
        journal.endFilePicker(reason: reason, attemptId: attemptId)
    }
    func setForeground(_ foreground: Bool) { journal.setForeground(foreground) }

    /// The sender uses the selected, already paired Host's encrypted transport.
    /// It supplies the app's protocolVersion; false means keep this batch on disk.
    func setTransport(sender: (([String: Any]) -> Bool)?) {
        self.sender = sender
        if sender != nil { flush() }
    }

    func flush() { journal.flush() }
    func acknowledge(batchId: String) { journal.acknowledge(batchId: batchId) }

    func shutdown() { journal.shutdown() }
}

private struct MobileDiagnosticEvent: Codable {
    let id: String
    let at: Int64
    let event: String
    let severity: String
    let detail: [String: String]

    var wire: [String: Any] {
        ["id": id, "at": at, "event": event, "severity": severity, "detail": detail]
    }
}

/// All mutable journal/watchdog state, disk access, and timeout decisions belong
/// to this queue. A hung UI therefore cannot prevent the stall record reaching disk.
private final class MobileDiagnosticJournal {
    private let queue = DispatchQueue(label: "orbis.mobile-diagnostics", qos: .utility)
    private let directory: URL
    private let file: URL
    private let heartbeatQueue: DispatchQueue
    private let heartbeatInterval: TimeInterval
    private let stallAfter: TimeInterval
    private let waitingAfter: TimeInterval
    private let retryAfter: TimeInterval
    private var status: ((Int, Date?, Bool) -> Void)?
    private var send: (([String: Any], @escaping (Bool) -> Void) -> Void)?
    private var enabled = false
    private var foreground = true
    private var stopped = false
    private var events: [MobileDiagnosticEvent] = []
    private var batch: (id: String, events: [MobileDiagnosticEvent])?
    private var sending = false
    private var attempts = 0
    private var lastUploadAt: Date?
    private var storageError = false
    private var timer: DispatchSourceTimer?
    private var pickerDetail: [String: String]?
    private var pickerStarted: TimeInterval = 0
    private var waitingRecorded = false
    private var heartbeatSequence: UInt64 = 0
    private var pendingHeartbeat: (sequence: UInt64, at: TimeInterval)?
    private var stalled = false

    init(directory: URL, heartbeatQueue: DispatchQueue, heartbeatInterval: TimeInterval,
         stallAfter: TimeInterval, waitingAfter: TimeInterval, retryAfter: TimeInterval) {
        self.directory = directory
        file = directory.appendingPathComponent("mobile-diagnostics.json")
        self.heartbeatQueue = heartbeatQueue
        self.heartbeatInterval = heartbeatInterval
        self.stallAfter = stallAfter
        self.waitingAfter = waitingAfter
        self.retryAfter = retryAfter
    }

    func start(enabled: Bool, status: @escaping (Int, Date?, Bool) -> Void,
               send: @escaping ([String: Any], @escaping (Bool) -> Void) -> Void) {
        queue.async {
            self.enabled = enabled
            self.status = status
            self.send = send
            if let data = try? Data(contentsOf: self.file) {
                self.events = (try? JSONDecoder().decode([MobileDiagnosticEvent].self, from: data)) ?? []
            }
            self.publish()
            if enabled { self.append("diagnostics.restarted") }
        }
    }

    func setEnabled(_ value: Bool, context: [String: String]) {
        queue.async {
            if !value { self.append("diagnostics.disabled") }
            self.enabled = value
            if value { self.append("diagnostics.enabled", detail: context) }
            self.updateWatchdog()
            self.flushOnQueue(resetRetries: true)
        }
    }

    func record(_ event: String, severity: String, detail: [String: String]) {
        queue.async { self.append(event, severity: severity, detail: detail) }
    }

    func beginFilePicker(detail: [String: String]) {
        queue.async {
            guard self.enabled, !self.stopped else { return }
            self.pickerDetail = detail
            self.pickerStarted = ProcessInfo.processInfo.systemUptime
            self.waitingRecorded = false
            self.append("attachment.picker.begin", detail: detail)
            self.updateWatchdog()
        }
    }

    func endFilePicker(reason: String, attemptId: String?) {
        queue.async {
            if let attemptId, self.pickerDetail?["attemptId"] != attemptId { return }
            if var detail = self.pickerDetail {
                detail["reason"] = reason
                self.append("attachment.picker.end", detail: detail)
            }
            self.pickerDetail = nil
            self.updateWatchdog()
        }
    }

    func setForeground(_ value: Bool) {
        queue.async {
            self.foreground = value
            self.append(value ? "app.foreground" : "app.background")
            self.updateWatchdog()
            if value { self.flushOnQueue(resetRetries: true) }
        }
    }

    func flush() { queue.async { self.flushOnQueue(resetRetries: true) } }

    func acknowledge(batchId: String) {
        queue.async {
            guard let batch = self.batch, batch.id == batchId else { return }
            let ids = Set(batch.events.map(\.id))
            self.events.removeAll { ids.contains($0.id) }
            self.batch = nil
            self.sending = false
            self.attempts = 0
            self.lastUploadAt = Date()
            self.persist()
            self.flushOnQueue(resetRetries: false)
        }
    }

    func shutdown() {
        queue.async {
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
            self.send = nil
            self.status = nil
        }
    }

    private func append(_ event: String, severity: String = "info", detail: [String: String] = [:]) {
        guard enabled, !stopped else { return }
        let limitedDetail = detail.sorted { $0.key < $1.key }.prefix(12).reduce(into: [String: String]()) {
            $0[String($1.key.prefix(32))] = String($1.value.prefix(256))
        }
        events.append(MobileDiagnosticEvent(id: UUID().uuidString, at: Int64(Date().timeIntervalSince1970 * 1_000),
            event: String(event.prefix(64)), severity: severity, detail: limitedDetail))
        if events.count > 256 { events.removeFirst(events.count - 256) }
        persist()
        flushOnQueue(resetRetries: false)
    }

    private func persist() {
        do {
            var data = try JSONEncoder().encode(events)
            if data.count > 128 * 1024 {
                let encoder = JSONEncoder()
                var size = 2
                var retained = 0
                for event in events.reversed() {
                    let eventSize = try encoder.encode(event).count + 1
                    if size + eventSize > 128 * 1024 { break }
                    size += eventSize
                    retained += 1
                }
                events.removeFirst(events.count - retained)
                data = try encoder.encode(events)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            storageError = false
        } catch {
            storageError = true
        }
        publish()
    }

    private func publish() { status?(events.count, lastUploadAt, storageError) }

    private func flushOnQueue(resetRetries: Bool) {
        guard enabled, foreground, !stopped, !sending, !events.isEmpty else { return }
        if resetRetries { attempts = 0 }
        guard attempts < 3 else { return }
        if batch == nil { batch = (UUID().uuidString, Array(events.prefix(32))) }
        guard let batch else { return }
        sending = true
        attempts += 1
        let payload: [String: Any] = ["type": "diagnostics.mobile.batch", "batchId": batch.id,
                                      "events": batch.events.map(\.wire)]
        send?(payload) { [weak self] sent in
            guard let self else { return }
            self.queue.async { [self] in
                guard self.batch?.id == batch.id else { return }
                guard sent else { self.sending = false; return }
                self.queue.asyncAfter(deadline: .now() + self.retryAfter) { [weak self] in
                    guard let self, self.batch?.id == batch.id else { return }
                    self.sending = false
                    self.flushOnQueue(resetRetries: false)
                }
            }
        }
    }

    private func updateWatchdog() {
        guard enabled, foreground, pickerDetail != nil, !stopped else {
            timer?.cancel()
            timer = nil
            pendingHeartbeat = nil
            stalled = false
            return
        }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if !waitingRecorded, now - pickerStarted >= waitingAfter {
            waitingRecorded = true
            var detail = pickerDetail ?? [:]
            let lag = pendingHeartbeat.map { now - $0.at } ?? 0
            detail["mainResponsive"] = lag < stallAfter ? "true" : "false"
            detail["sinceHeartbeatMs"] = String(Int(lag * 1_000))
            append("attachment.picker.waiting", detail: detail)
        }
        if let pending = pendingHeartbeat {
            if !stalled, now - pending.at >= stallAfter {
                stalled = true
                var detail = pickerDetail ?? [:]
                detail["elapsedMs"] = String(Int((now - pending.at) * 1_000))
                append("main_thread.stalled", severity: "warning", detail: detail)
            }
            return
        }
        heartbeatSequence &+= 1
        let sequence = heartbeatSequence
        pendingHeartbeat = (sequence, now)
        heartbeatQueue.async { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard let pending = self.pendingHeartbeat, pending.sequence == sequence else { return }
                if self.stalled {
                    var detail = self.pickerDetail ?? [:]
                    detail["elapsedMs"] = String(Int((ProcessInfo.processInfo.systemUptime - pending.at) * 1_000))
                    self.append("main_thread.recovered", detail: detail)
                }
                self.pendingHeartbeat = nil
                self.stalled = false
            }
        }
    }
}
