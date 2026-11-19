import Foundation
import XCTest
#if canImport(OrbisCore)
@testable import OrbisCore
#else
@testable import Orbis
#endif

@MainActor final class MobileDiagnosticsTests: XCTestCase {
    private func until(_ label: String, _ condition: () throws -> Bool) async throws {
        for _ in 0..<500 {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out: " + label)
        throw URLError(.timedOut)
    }

    private func fixture() -> (URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return (directory, defaults)
    }

    private func records(_ directory: URL) throws -> [[String: Any]] {
        let file = directory.appendingPathComponent("mobile-diagnostics.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
    }

    func testOfflineRecordsSurviveRelaunchAndOnlyMatchingHostAckDeletesThem() async throws {
        let (directory, defaults) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = MobileDiagnostics(directory: directory, defaults: defaults)
        XCTAssertFalse(first.enabled)
        first.record("must.not.collect")
        first.setEnabled(true)
        first.record("attachment.picker.created", detail: ["attemptId": "test-attempt"])
        try await until("two durable records") { try self.records(directory).count == 2 }
        XCTAssertFalse(try records(directory).contains { $0["event"] as? String == "must.not.collect" })
        first.shutdown()

        let restored = MobileDiagnostics(directory: directory, defaults: defaults, retryAfter: 0.04)
        defer { restored.shutdown() }
        var batches: [[String: Any]] = []
        restored.setTransport { payload in batches.append(payload); return true }
        try await until("restored batch") { !batches.isEmpty }
        let firstBatch = try XCTUnwrap(batches.first)
        let batchId = try XCTUnwrap(firstBatch["batchId"] as? String)
        XCTAssertEqual(firstBatch["type"] as? String, "diagnostics.mobile.batch")
        let events = try XCTUnwrap(firstBatch["events"] as? [[String: Any]])
        XCTAssertTrue(events.contains { $0["event"] as? String == "attachment.picker.created" })
        XCTAssertNotNil(events.first?["at"] as? Int64)
        restored.acknowledge(batchId: UUID().uuidString)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(try records(directory).isEmpty)
        XCTAssertTrue(batches.allSatisfy { $0["batchId"] as? String == batchId })
        restored.acknowledge(batchId: batchId)
        try await until("ack removes durable records") { try self.records(directory).isEmpty }
        XCTAssertNotNil(restored.lastUploadAt)
    }

    func testWatchdogPersistsOneStallWithoutMainQueueAndRecordsRecovery() async throws {
        let (directory, defaults) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let heartbeat = DispatchQueue(label: "test.suspended-main")
        heartbeat.suspend()
        let diagnostics = MobileDiagnostics(directory: directory, defaults: defaults,
            heartbeatQueue: heartbeat, heartbeatInterval: 0.02, stallAfter: 0.06, waitingAfter: 0.1)
        defer { diagnostics.shutdown() }
        diagnostics.setEnabled(true)
        diagnostics.beginFilePicker(detail: ["attemptId": "attempt-1"])
        try await until("stall persisted while heartbeat cannot run") {
            try self.records(directory).contains { $0["event"] as? String == "attachment.picker.waiting" }
        }
        let stalled = try records(directory)
        XCTAssertEqual(stalled.filter { $0["event"] as? String == "main_thread.stalled" }.count, 1)
        let waiting = stalled.first { $0["event"] as? String == "attachment.picker.waiting" }
        XCTAssertEqual((waiting?["detail"] as? [String: String])?["mainResponsive"], "false")
        heartbeat.resume()
        try await until("recovery recorded") {
            try self.records(directory).contains { $0["event"] as? String == "main_thread.recovered" }
        }
        diagnostics.endFilePicker(reason: "cancelled")
        try await until("picker ended") { try self.records(directory).last?["event"] as? String == "attachment.picker.end" }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try records(directory).filter { $0["event"] as? String == "main_thread.stalled" }.count, 1)
    }

    func testJournalIsBoundedAndUploadRetriesStopUntilExplicitFlush() async throws {
        let (directory, defaults) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = MobileDiagnostics(directory: directory, defaults: defaults, retryAfter: 0.02)
        defer { diagnostics.shutdown() }
        diagnostics.setEnabled(true)
        for index in 0..<300 { diagnostics.record("event.\(index)") }
        try await until("count limit reached after all writes") {
            try self.records(directory).last?["event"] as? String == "event.299"
        }
        XCTAssertEqual(try records(directory).count, 256)
        let largeDetail = Dictionary(uniqueKeysWithValues: (0..<12).map { ("field\($0)", String(repeating: "值", count: 256)) })
        for index in 0..<50 { diagnostics.record("large.\(index)", detail: largeDetail) }
        try await until("byte limit reached after all writes") {
            try self.records(directory).last?["event"] as? String == "large.49"
        }
        let bytes = try Data(contentsOf: directory.appendingPathComponent("mobile-diagnostics.json")).count
        XCTAssertLessThanOrEqual(bytes, 128 * 1024)

        var batches: [[String: Any]] = []
        diagnostics.setTransport { payload in batches.append(payload); return true }
        try await until("bounded ack retries") { batches.count == 3 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(Set(batches.compactMap { $0["batchId"] as? String }).count, 1)
        XCTAssertLessThanOrEqual((batches.first?["events"] as? [[String: Any]])?.count ?? 99, 32)
        diagnostics.flush()
        try await until("explicit retry") { batches.count > 3 }
    }
}
