import Foundation
import Testing
@testable import OrbisCore

@Suite("Mobile diagnostics production Host interoperability") @MainActor
struct MobileDiagnosticsTransportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORBIS_TEST_NODE"] != nil,
        "Set ORBIS_TEST_NODE and build the Node Host/Relay for the isolated production fixture."))
    func persistedInfoAndWatchdogWarningCrossEncryptedRelayAndAckClearsPhoneJournal() async throws {
        let node = try #require(ProcessInfo.processInfo.environment["ORBIS_TEST_NODE"])
        let fixture = try #require(Bundle.module.url(forResource: "mobile-diagnostics-host", withExtension: "mjs", subdirectory: "Fixtures"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orbis-mobile-production-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let phoneDirectory = folder.appendingPathComponent("phone")
        let phoneFile = phoneDirectory.appendingPathComponent("mobile-diagnostics.json")
        let hostFile = folder.appendingPathComponent("host/mobile-diagnostics.ndjson")
        let preferences = try #require(UserDefaults(suiteName: UUID().uuidString))
        let heartbeat = DispatchQueue(label: "mobile-production-test.suspended-heartbeat")
        heartbeat.suspend()
        var heartbeatSuspended = true
        defer { if heartbeatSuspended { heartbeat.resume() } }
        let diagnostics = MobileDiagnostics(directory: phoneDirectory, defaults: preferences,
            heartbeatQueue: heartbeat, heartbeatInterval: 0.02, stallAfter: 0.06, waitingAfter: 0.1)
        defer { diagnostics.shutdown() }
        diagnostics.setEnabled(true)
        diagnostics.beginFilePicker(detail: ["attemptId": "production-integration", "source": "files"])
        try await until {
            (try? self.phoneEvents(phoneFile).contains { $0["event"] as? String == "attachment.picker.waiting" }) == true
        }
        heartbeat.resume()
        heartbeatSuspended = false
        try await until {
            (try? self.phoneEvents(phoneFile).contains { $0["event"] as? String == "main_thread.recovered" }) == true
        }
        diagnostics.endFilePicker(reason: "cancelled")
        try await until { (try? self.phoneEvents(phoneFile).last?["event"] as? String) == "attachment.picker.end" }
        let originalEvents = try phoneEvents(phoneFile)
        #expect(originalEvents.contains { $0["severity"] as? String == "info" })
        #expect(originalEvents.contains { $0["event"] as? String == "main_thread.stalled" && $0["severity"] as? String == "warning" })

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [fixture.path, folder.path]
        var environment = ProcessInfo.processInfo.environment
        environment["ORBIS_TEST_REPOSITORY"] = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let qrFile = folder.appendingPathComponent("qr.json")
        try await until { FileManager.default.fileExists(atPath: qrFile.path) }
        let qr = try PairingQR.parse(String(contentsOf: qrFile, encoding: .utf8))
        let identity = DeviceIdentity.generate()
        let pairingTransport = RelayTransport(relayMode: .ws, preferences: nil)
        let pairing: HostPairing = try await withCheckedThrowingContinuation { continuation in
            pairingTransport.pair(qr: qr, deviceName: "Mobile diagnostics integration", identity: identity) { continuation.resume(with: $0) }
        }
        let transport = RelayTransport(relayMode: .ws, preferences: nil)
        defer { diagnostics.setTransport(sender: nil); transport.disconnect() }
        var ready = false
        var acknowledged: [String] = []
        var protocolErrors: [[String: Any]] = []
        transport.connect(pairing: pairing, identity: identity, receive: { message, _ in
            if message["type"] as? String == "device.ready" {
                ready = (message["hostFeatures"] as? [String] ?? []).contains("diagnostics.mobile")
                if ready {
                    diagnostics.setTransport { payload in
                        var request = payload
                        request["protocolVersion"] = orbisProtocolVersion
                        return transport.send(request)
                    }
                }
            }
            if message["type"] as? String == "diagnostics.mobile.ack", let batchId = message["batchId"] as? String {
                acknowledged.append(batchId)
                diagnostics.acknowledge(batchId: batchId)
            }
            if message["type"] as? String == "protocol.error" { protocolErrors.append(message) }
        }, state: { _, _ in })
        try await until {
            ready && !acknowledged.isEmpty && diagnostics.pendingCount == 0 &&
                (try? self.phoneEvents(phoneFile).isEmpty) == true
        }
        #expect(protocolErrors.isEmpty)
        #expect(diagnostics.lastUploadAt != nil)
        let text = try String(contentsOf: hostFile, encoding: .utf8)
        let saved = try text.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(Set(saved.compactMap { $0["id"] as? String }) == Set(originalEvents.compactMap { $0["id"] as? String }))
        #expect(saved.contains { $0["event"] as? String == "main_thread.stalled" && $0["severity"] as? String == "warning" })
        #expect(saved.allSatisfy { acknowledged.contains($0["batchId"] as? String ?? "") && $0["receivedAt"] != nil })
    }

    private func phoneEvents(_ file: URL) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
    }

    private func until(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try #require(condition(), "Timed out waiting for mobile diagnostics production interoperability")
    }
}
