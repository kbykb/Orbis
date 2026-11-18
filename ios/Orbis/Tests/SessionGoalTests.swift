import Foundation
import Testing
@testable import OrbisCore

@MainActor @Suite("Native Codex goals")
struct SessionGoalTests {
    private final class Storage: SecureStorage {
        let pairing = HostPairing(hostId: "host", hostName: "PC", hostPub: "pub", pskRoot: "root",
            relay: RelayCredential(relayUrl: "ws://localhost", deviceId: "phone", credential: "credential"), lan: [])
        func deviceIdentity() throws -> DeviceIdentity { .generate() }
        func pairings() -> [HostPairing] { [pairing] }
        func savePairings(_ pairings: [HostPairing]) throws {}
    }
    private final class Transport: OrbisTransport {
        var sent: [[String: Any]] = []
        var receive: (([String: Any], String?) -> Void)?
        var drain: (() async -> Void)?
        var sequence = 0
        func pair(qr: PairingQR, deviceName: String, identity: DeviceIdentity, completion: @escaping (Result<HostPairing, Error>) -> Void) {
            completion(.failure(PairingError.invalidQR))
        }
        func connect(pairing: HostPairing, identity: DeviceIdentity, receive: @escaping ([String: Any], String?) -> Void, state: @escaping (ConnectionState, String?) -> Void) {
            self.receive = receive; state(.secured, nil)
        }
        func disconnect() {}
        func send(_ object: [String: Any]) -> Bool { sent.append(object); return true }
        func emit(_ object: [String: Any]) async { receive?(object, "ctl"); await drain?() }
        func event(_ event: [String: Any]) async {
            sequence += 1
            await emit(["type": "runtime.event", "runtimeId": "a", "sequence": sequence, "event": event])
        }
    }
    private func setup(supported: Bool = true) async -> (OrbisStore, Transport) {
        let transport = Transport()
        let store = OrbisStore(secure: Storage(), transport: transport, preferences: nil)
        transport.drain = { [weak store] in await store?.waitForPendingEvents() }
        await transport.emit(["type": "device.ready", "modelEpoch": "epoch", "runtimes": [
            ["runtimeId": "a", "sessionId": "codex-desktop:thread-a", "name": "Codex", "cwd": "/repo",
             "status": "running", "agentKind": "codexDesktop", "goalSupported": supported]]])
        return (store, transport)
    }
    private func goal(_ thread: String = "thread-a") -> [String: Any] {
        ["threadId": thread, "objective": "Find the measured cause", "status": "active", "tokenBudget": NSNull(),
         "tokensUsed": 1234, "timeUsedSeconds": 12.5, "createdAt": 1, "updatedAt": 2]
    }

    @Test func readsAndPausesTheNativeGoalWithoutSendingChat() async throws {
        let (store, transport) = await setup(); let host = store.activeConnection
        #expect(host.requestGoal(runtimeId: "a", sessionId: "codex-desktop:thread-a"))
        let request = try #require(transport.sent.last { ($0["command"] as? [String: Any])?["type"] as? String == "session.goal.read" })
        await transport.event(["type": "session.goal", "goal": goal()])
        await transport.event(["type": "command.result", "commandId": request["commandId"]!, "ok": true, "status": "success"])
        #expect(host.sessionGoals["a"]?.goal?.timeUsedSeconds == 12.5)
        #expect(host.sessionGoals["a"]?.pending == false)
        #expect(host.requestGoal(runtimeId: "a", sessionId: "codex-desktop:thread-a", status: "paused"))
        let command = try #require(transport.sent.last?["command"] as? [String: Any])
        #expect(command["type"] as? String == "session.goal.set")
        #expect(command["status"] as? String == "paused")
        #expect(command["objective"] == nil)
        #expect(host.pendingSends.isEmpty)
    }

    @Test func rejectsAReplacementSessionAndForeignGoal() async {
        let (store, transport) = await setup(); let host = store.activeConnection
        #expect(!host.requestGoal(runtimeId: "a", sessionId: "other", status: "active"))
        await transport.event(["type": "session.goal", "goal": goal("other")])
        #expect(host.sessionGoals["a"] == nil)
        await transport.event(["type": "session.goal", "goal": goal()])
        await transport.event(["type": "session.goal", "goal": NSNull()])
        #expect(host.sessionGoals["a"]?.loaded == true)
        #expect(host.sessionGoals["a"]?.goal == nil)
    }

    @Test func unsupportedAndFailedReadsNeverClaimAnEmptyGoal() async throws {
        let (unsupported, _) = await setup(supported: false)
        #expect(!unsupported.activeConnection.requestGoal(runtimeId: "a", sessionId: "codex-desktop:thread-a"))
        let (store, transport) = await setup(); let host = store.activeConnection
        #expect(host.requestGoal(runtimeId: "a", sessionId: "codex-desktop:thread-a"))
        let id = try #require(transport.sent.last?["commandId"] as? String)
        await transport.event(["type": "command.result", "commandId": id, "ok": false, "status": "failure", "error": "目标读取失败"])
        #expect(host.sessionGoals["a"]?.pending == false)
        #expect(host.sessionGoals["a"]?.loaded == false)
        #expect(host.sessionGoals["a"]?.error == "目标读取失败")
    }
}
