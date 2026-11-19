import Foundation
import XCTest
import Combine
#if canImport(OrbisCore)
@testable import OrbisCore
#else
@testable import Orbis
#endif

// APNS-L03–L08: run the same lifecycle assertions on macOS and in the iOS app
// test host. Synthetic transport controls completion order; no real APNs is used.
@MainActor final class PushRegistrationTests: XCTestCase {
    private func pairing(_ host: String = "host", credential: String = "credential", relay: String = "wss://relay.example") -> HostPairing {
        HostPairing(hostId: host, hostName: host, hostPub: "pub", pskRoot: "root",
            relay: RelayCredential(relayUrl: relay, deviceId: "device-" + host, credential: credential), lan: [])
    }
    private func until(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out: " + label); throw URLError(.timedOut)
    }
    private func token(_ request: URLRequest) -> String? {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["token"] as? String
    }

    // APNS-L15: a locally optimized Release app still receives sandbox tokens
    // with development signing; missing metadata must not invent an environment.
    func testBundledSigningEnvironmentIsLoadedAndMissingOrCorruptMetadataIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = ["CFBundleIdentifier": "com.orbising.push-environment-test", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Info.plist"))
        let resource = directory.appendingPathComponent("OrbisPushEnvironment.plist")
        try PropertyListSerialization.data(fromPropertyList: ["aps-environment": "development"], format: .binary, options: 0)
            .write(to: resource)
        let bundle = try XCTUnwrap(Bundle(url: directory))
        XCTAssertEqual(PushRegistrationEnvironment.load(from: bundle), "sandbox")
        try Data("invalid-plist".utf8).write(to: resource)
        XCTAssertNil(PushRegistrationEnvironment.load(from: bundle))
        try FileManager.default.removeItem(at: resource)
        XCTAssertNil(PushRegistrationEnvironment.load(from: bundle))
    }

    func testSigningEnvironmentControlsRegistrationAndMissingEnvironmentAllowsCleanup() async throws {
        for (entitlement, expected) in [("development", "sandbox"), ("production", "production")] {
            let environment = PushRegistrationEnvironment.resolve(entitlement)
            XCTAssertEqual(environment, expected)
            let request = try XCTUnwrap(PushRegistrationTarget(pairing()).request(token: "token", environment: environment))
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: String]
            XCTAssertEqual(body["environment"], expected)
        }
        for value in [nil, "sandbox", "", "unknown", 1] as [Any?] {
            XCTAssertNil(PushRegistrationEnvironment.resolve(value))
        }
        XCTAssertNil(PushRegistrationTarget(pairing()).request(token: "token", environment: nil))
        var requests: [URLRequest] = []
        let state = PushRegistrationCoordinator(environment: nil, send: { requests.append($0); return 204 })
        defer { state.shutdown() }
        state.updatePairings([pairing()]); state.setAuthorizationAllowed(true); state.receiveToken("late-token")
        await Task.yield()
        XCTAssertTrue(requests.isEmpty)
        state.setAuthorizationAllowed(false)
        try await until("cleanup without signing metadata") { requests.count == 1 }
        XCTAssertNil(token(requests[0]))
    }

    func testFreshInstallAndRelaunchWaitForAPNsInsteadOfReusingStoredToken() async throws {
        var requests: [URLRequest] = []
        let state = PushRegistrationCoordinator(environment: "production", send: { requests.append($0); return 204 })
        defer { state.shutdown() }
        state.updatePairings([pairing()]); state.setAuthorizationAllowed(true)
        state.refresh(); await Task.yield()
        XCTAssertTrue(requests.isEmpty)
        state.receiveToken("fresh-after-reinstall")
        try await until("fresh token registration") { requests.count == 1 }
        XCTAssertEqual(token(requests[0]), "fresh-after-reinstall")
    }

    func testAddingRemovingAndReplacingPairingsWhileOneRemains() async throws {
        var requests: [URLRequest] = []
        let state = PushRegistrationCoordinator(environment: "production", send: { requests.append($0); return 204 })
        defer { state.shutdown() }
        state.updatePairings([pairing()]); state.setAuthorizationAllowed(true); state.receiveToken("token")
        try await until("first pairing") { requests.count == 1 }
        state.updatePairings([pairing(), pairing("second")])
        try await until("second pairing without empty transition") { requests.count == 2 }
        state.updatePairings([pairing("second")])
        try await until("first pairing removed") { requests.count == 3 }
        XCTAssertNil(token(requests[2]))
        state.updatePairings([pairing("second", credential: "new-credential", relay: "wss://new.example")])
        try await until("same Host new relay") { requests.count == 5 }
        XCTAssertEqual(Set(requests.suffix(2).map { $0.url!.host! }), ["relay.example", "new.example"])
        XCTAssertEqual(token(requests.first { $0.url!.host! == "new.example" }!), "token")
    }

    func testRevokingPermissionRemovesTokensAndIgnoresLateAPNsCallback() async throws {
        var requests: [URLRequest] = []
        let state = PushRegistrationCoordinator(environment: "production", send: { requests.append($0); return 204 })
        defer { state.shutdown() }
        state.updatePairings([pairing()]); state.setAuthorizationAllowed(true); state.receiveToken("old")
        try await until("initial") { requests.count == 1 }
        state.setAuthorizationAllowed(false); state.receiveToken("late")
        try await until("permission removal") { requests.count == 2 }
        XCTAssertNil(token(requests[1]))
        state.setAuthorizationAllowed(true)
        await Task.yield(); XCTAssertEqual(requests.count, 2)
        state.receiveToken("new")
        try await until("permission restored") { requests.count == 3 }
        XCTAssertEqual(token(requests[2]), "new")
    }

    func testDeniedPermissionOnRelaunchUnregistersEvenWithoutAnAPNsToken() async throws {
        var requests: [URLRequest] = []
        let state = PushRegistrationCoordinator(environment: "production", send: { requests.append($0); return 204 })
        defer { state.shutdown() }
        state.updatePairings([pairing()]); state.setAuthorizationAllowed(false)
        try await until("remove previous install token") { requests.count == 1 }
        XCTAssertNil(token(requests[0]))
    }

    func testSlowOldRegistrationCannotWinAfterRotationAndUnpair() async throws {
        var requests: [URLRequest] = [], completion: CheckedContinuation<Int, Never>?
        let state = PushRegistrationCoordinator(environment: "production", send: { request in
            requests.append(request)
            if requests.count == 1 { return await withCheckedContinuation { completion = $0 } }
            return 204
        })
        defer { state.shutdown() }
        state.updatePairings([pairing()]); state.setAuthorizationAllowed(true); state.receiveToken("old")
        try await until("old request in flight") { completion != nil }
        state.receiveToken("new"); state.updatePairings([])
        await Task.yield(); XCTAssertEqual(requests.count, 1)
        completion?.resume(returning: 503)
        try await until("unregister follows old completion") { requests.count == 2 }
        XCTAssertNil(token(requests[1]))
    }

    func testOfflineRemovalSurvivesProcessRestartWithoutPersistingToken() async throws {
        var retired: [PushRegistrationTarget] = []
        var firstRequests = 0
        let first = PushRegistrationCoordinator(environment: "production", retryDelays: [],
            saveRetired: { retired = $0 }, send: { _ in firstRequests += 1; return 503 })
        first.updatePairings([pairing()]); first.updatePairings([])
        try await until("durable offline removal") { firstRequests == 1 && retired.count == 1 }
        first.shutdown()
        var requests: [URLRequest] = []
        let second = PushRegistrationCoordinator(environment: "production", loadRetired: { retired },
            saveRetired: { retired = $0 }, send: { requests.append($0); return 204 })
        defer { second.shutdown() }
        try await until("recovered removal acknowledged") { requests.count == 1 && retired.isEmpty }
        XCTAssertNil(token(requests[0]))
    }

    func testReaddingPairingWhileRemovalIsInFlightRegistersLast() async throws {
        var requests: [URLRequest] = [], completion: CheckedContinuation<Int, Never>?
        let state = PushRegistrationCoordinator(environment: "production", send: { request in
            requests.append(request)
            if requests.count == 2 { return await withCheckedContinuation { completion = $0 } }
            return 204
        })
        defer { state.shutdown() }
        state.updatePairings([pairing()]); state.setAuthorizationAllowed(true); state.receiveToken("token")
        try await until("initial") { requests.count == 1 }
        state.updatePairings([])
        try await until("removal in flight") { completion != nil }
        state.updatePairings([pairing()]); completion?.resume(returning: 204)
        try await until("re-added pairing") { requests.count == 3 }
        XCTAssertEqual(token(requests[2]), "token")
    }

    func testTransientFailureRetriesAndForegroundRepairsRelayStateLoss() async throws {
        var requests: [URLRequest] = []
        let state = PushRegistrationCoordinator(environment: "production", retryDelays: [1_000_000], send: {
            requests.append($0); return requests.count == 1 ? 503 : 204
        })
        defer { state.shutdown() }
        state.updatePairings([pairing()]); state.setAuthorizationAllowed(true); state.receiveToken("token")
        try await until("retry") { requests.count == 2 }
        state.refresh()
        try await until("foreground reconciliation") { requests.count == 3 }
        XCTAssertEqual(requests.compactMap(token), ["token", "token", "token"])
    }

    func testUnsupportedOldRelayAndEnvironmentMismatchDoNotBusyRetry() async throws {
        for status in [404, 409] {
            var count = 0
            let state = PushRegistrationCoordinator(environment: "sandbox", retryDelays: [1_000_000], send: { _ in count += 1; return status })
            state.updatePairings([pairing()]); state.setAuthorizationAllowed(true); state.receiveToken("token")
            try await until("unsupported response") { count == 1 }
            try await Task.sleep(nanoseconds: 10_000_000)
            XCTAssertEqual(count, 1)
            state.refresh(); try await until("explicit recovery") { count == 2 }
            state.shutdown()
        }
    }

    func testHTTPSOnlyAndCorrectEnvironmentWithoutURLSecrets() throws {
        XCTAssertNil(PushRegistrationTarget(pairing(relay: "ws://relay.example")).request(token: "token", environment: "sandbox"))
        XCTAssertNil(PushRegistrationTarget(pairing(relay: "wss://user:pass@relay.example")).request(token: "token", environment: "sandbox"))
        let request = try XCTUnwrap(PushRegistrationTarget(pairing(relay: "wss://relay.example?query=private#fragment"))
            .request(token: "token", environment: "sandbox"))
        XCTAssertEqual(request.url!.absoluteString, "https://relay.example/v1/push/register")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer credential")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: String]
        XCTAssertEqual(body["environment"], "sandbox")
    }

    // APNS-L11: delivery before subscription survives, and consuming inside the
    // subscriber does not leave a stale Host for the next view subscription.
    func testColdOpenValidationAndSynchronousConsumption() {
        let queue = PushNotificationOpenQueue()
        queue.receive(["orbis": ["v": 1, "hostId": "host", "category": "task-completed"]])
        var opened: [String] = []
        let subscription = queue.publisher.sink { target in
            if let target { opened.append(target.hostId); queue.consume() }
        }
        XCTAssertEqual(opened, ["host"])
        XCTAssertNil(queue.hostId)
        queue.receive(["orbis": ["v": 2, "hostId": "wrong", "category": "task-completed"]])
        queue.receive(["orbis": ["v": 1, "hostId": "wrong", "category": "unknown"]])
        XCTAssertEqual(opened, ["host"])
        subscription.cancel()
    }

    // SC114: local completions used to be silently rejected by the remote-only
    // parser. Both generations survive cold start and never open a random chat.
    func testLocalNotificationOpenValidatesPairingAndExactSession() throws {
        let queue = PushNotificationOpenQueue()
        queue.receive(["hostId": "host", "sessionId": "session"])
        var opened: [PushNotificationOpenTarget] = []
        let subscription = queue.publisher.sink { target in
            if let target { opened.append(target); queue.consume() }
        }
        defer { subscription.cancel() }
        XCTAssertEqual(opened.count, 1)
        let sessions: [(runtimeId: String, sessionId: String?)] = [("runtime", "session"), ("other", "other-session")]
        XCTAssertEqual(opened[0].destination(currentPairingKey: "pairing", sessions: sessions, confirmed: true), .runtime("runtime"))
        XCTAssertNil(opened[0].destination(currentPairingKey: "pairing", sessions: sessions, confirmed: false))
        XCTAssertEqual(opened[0].destination(currentPairingKey: "pairing", sessions: [("other", "other-session")], confirmed: true), .home)
        queue.receive(["orbis": ["v": 1, "category": "task-completed", "hostId": "host", "sessionId": "session", "pairingKey": "original"]])
        XCTAssertEqual(opened.count, 2)
        XCTAssertNil(opened[1].destination(currentPairingKey: "replacement", sessions: sessions, confirmed: true))
        XCTAssertNil(opened[1].destination(currentPairingKey: nil, sessions: sessions, confirmed: true))
        XCTAssertEqual(opened[1].destination(currentPairingKey: "original", sessions: sessions, confirmed: true), .runtime("runtime"))
        queue.receive(["orbis": ["v": 1, "category": "approval-requested", "hostId": "second"]])
        XCTAssertEqual(opened.last?.hostId, "second")
        XCTAssertEqual(opened.last?.destination(currentPairingKey: "second-pairing", sessions: sessions, confirmed: true), .home)
        XCTAssertNil(queue.hostId)
        XCTAssertNil(PushNotificationOpenTarget(["hostId": " ", "sessionId": "session"]))
        XCTAssertNil(PushNotificationOpenTarget(["hostId": "host", "sessionId": 3]))
        XCTAssertNil(PushNotificationOpenTarget(["orbis": ["v": 9, "hostId": "host"], "hostId": "host"]))
        XCTAssertNil(PushNotificationOpenTarget(["orbis": "malformed", "hostId": "host", "sessionId": "session"]))
    }

    private final class OpenStorage: SecureStorage {
        var hosts: [HostPairing]
        init(_ hosts: [HostPairing]) { self.hosts = hosts }
        func deviceIdentity() throws -> DeviceIdentity { .generate() }
        func pairings() -> [HostPairing] { hosts }
        func savePairings(_ values: [HostPairing]) throws { hosts = values }
    }
    private final class OpenTransport: OrbisTransport {
        var receive: (([String: Any], String?) -> Void)?
        var connects = 0
        func pair(qr: PairingQR, deviceName: String, identity: DeviceIdentity,
                  completion: @escaping (Result<HostPairing, Error>) -> Void) { completion(.failure(PairingError.invalidQR)) }
        func connect(pairing: HostPairing, identity: DeviceIdentity, receive: @escaping ([String: Any], String?) -> Void,
                     state: @escaping (ConnectionState, String?) -> Void) {
            connects += 1; self.receive = receive; state(.connecting, nil)
        }
        func disconnect() {}
        func send(_ object: [String: Any]) -> Bool { true }
        func ready(_ sessions: [(String, String)]) {
            receive?(["type": "device.ready", "protocolVersion": orbisProtocolVersion,
                "runtimes": sessions.map { runtime, session in
                    ["runtimeId": runtime, "sessionId": session, "agentKind": "claude", "name": session,
                     "cwd": "/repo", "status": "idle"]
                }], "ctl")
        }
    }
    private func remoteOpen(_ session: String, host: String = "host") -> [AnyHashable: Any] {
        let focus = LiveActivityProjection.focusKey(hostId: host, agentKind: "claude", sessionId: session)
        return ["orbis": ["v": 1, "category": "task-completed", "hostId": host,
                          "eventId": "focus:" + focus + ":" + String(repeating: "a", count: 32)]]
    }

    // The real Store/HostConnection path must wait through cold launch and a
    // connecting transport, then select the notification's session, not the first one.
    func testNotificationColdOpenWaitsForDirectoryAndFollowsNewRuntimeIdentity() async throws {
        let transport = OpenTransport(), queue = PushNotificationOpenQueue()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = OrbisStore(secure: OpenStorage([pairing()]), transport: transport, autoConnect: false,
                               preferences: nil, transferRoot: root)
        defer { store.activeConnection.shutdown(); try? FileManager.default.removeItem(at: root) }
        queue.receive(remoteOpen("second-session"))
        let coordinator = PushNotificationOpenCoordinator(queue: queue)
        defer { coordinator.cancelQueuedOpen() }
        var opened: [PushNotificationOpenCoordinator.Navigation] = []
        let subscription = coordinator.navigation.sink { if let target = $0 { opened.append(target) } }
        defer { subscription.cancel() }
        coordinator.bind(store, foreground: false)
        XCTAssertEqual(transport.connects, 0)
        coordinator.setForeground(true)
        XCTAssertEqual(transport.connects, 1)
        XCTAssertTrue(opened.isEmpty)
        await Task.yield()
        XCTAssertTrue(opened.isEmpty)
        transport.ready([("first-runtime", "first-session"), ("replacement-runtime", "second-session")])
        await store.waitForPendingEvents()
        try await until("notification target selected") { opened.count == 1 }
        XCTAssertEqual(opened, [.init(hostId: "host", runtimeId: "replacement-runtime")])
        XCTAssertEqual(store.selectedRuntimeId, "replacement-runtime")
        XCTAssertNil(queue.hostId)
        transport.ready([("third-runtime", "third-session")])
        await store.waitForPendingEvents()
        await Task.yield()
        XCTAssertEqual(opened.count, 1)
    }

    // A later tap supersedes the earlier one. Explicit navigation and moving
    // to the background must prevent a delayed connection from taking over.
    func testNotificationReplacementAndUserCancellation() async throws {
        let transport = OpenTransport(), queue = PushNotificationOpenQueue()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = OrbisStore(secure: OpenStorage([pairing()]), transport: transport, autoConnect: false,
                               preferences: nil, transferRoot: root)
        defer { store.activeConnection.shutdown(); try? FileManager.default.removeItem(at: root) }
        let coordinator = PushNotificationOpenCoordinator(queue: queue)
        coordinator.bind(store, foreground: true)
        defer { coordinator.cancelQueuedOpen() }
        var opened: [PushNotificationOpenCoordinator.Navigation] = []
        let subscription = coordinator.navigation.sink { if let target = $0 { opened.append(target) } }
        defer { subscription.cancel() }
        coordinator.receive(remoteOpen("first"))
        coordinator.receive(remoteOpen("second"))
        transport.ready([("a", "first"), ("b", "second")])
        await store.waitForPendingEvents()
        try await until("newest notification selected") { opened.count == 1 }
        XCTAssertEqual(opened.first?.runtimeId, "b")
        coordinator.receive(remoteOpen("not-online-yet"))
        coordinator.cancelQueuedOpen()
        transport.ready([("c", "not-online-yet")])
        await store.waitForPendingEvents()
        await Task.yield()
        XCTAssertEqual(opened.count, 1)
        coordinator.receive(remoteOpen("background-session"))
        coordinator.setForeground(false)
        transport.ready([("d", "background-session")])
        await store.waitForPendingEvents()
        coordinator.setForeground(true)
        await Task.yield()
        XCTAssertEqual(opened.count, 1)
    }

    func testNotificationTimeoutAndReplacedPairingCannotOpenAnotherChat() async throws {
        let transport = OpenTransport(), queue = PushNotificationOpenQueue()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = OrbisStore(secure: OpenStorage([pairing()]), transport: transport, autoConnect: false,
                               preferences: nil, transferRoot: root)
        defer { store.activeConnection.shutdown(); try? FileManager.default.removeItem(at: root) }
        let coordinator = PushNotificationOpenCoordinator(queue: queue, timeout: .milliseconds(30))
        coordinator.bind(store, foreground: true)
        var opened: [PushNotificationOpenCoordinator.Navigation] = []
        let subscription = coordinator.navigation.sink { if let target = $0 { opened.append(target) } }
        defer { subscription.cancel(); coordinator.cancelQueuedOpen() }
        coordinator.receive(["hostId": "host", "sessionId": "private", "pairingKey": "replaced"])
        XCTAssertNil(queue.hostId)
        XCTAssertEqual(transport.connects, 0)
        coordinator.receive(remoteOpen("before-repair"))
        let replacementTransport = OpenTransport()
        let replacementStore = OrbisStore(secure: OpenStorage([pairing(credential: "new-credential")]),
            transport: replacementTransport, autoConnect: false, preferences: nil,
            transferRoot: root.appendingPathComponent("replacement"))
        defer { replacementStore.activeConnection.shutdown() }
        coordinator.bind(replacementStore, foreground: true)
        XCTAssertNil(queue.hostId, "A queued notification cannot cross a replacement pairing")
        XCTAssertTrue(opened.isEmpty)
        coordinator.bind(store, foreground: true)
        coordinator.receive(remoteOpen("missing"))
        try await until("unreachable target falls back to its Host") { opened.count == 1 }
        XCTAssertEqual(opened, [.init(hostId: "host", runtimeId: nil)])
        XCTAssertNil(queue.hostId)
        transport.ready([("unrelated", "another-chat")])
        await store.waitForPendingEvents()
        await Task.yield()
        XCTAssertEqual(opened.count, 1)
    }

    // Replacing credentials under the same Host/device IDs must invalidate a
    // local alert, whereas renaming the computer leaves the pairing unchanged.
    func testNotificationBindingIncludesCompletePairing() {
        let original = pairing()
        var renamed = original; renamed.hostName = "New display name"
        XCTAssertEqual(PushNotificationIdentity.pairingKey(original), PushNotificationIdentity.pairingKey(renamed))
        XCTAssertNotEqual(PushNotificationIdentity.pairingKey(original),
                          PushNotificationIdentity.pairingKey(pairing(credential: "replacement")))
        let rekeyed = HostPairing(hostId: original.hostId, hostName: original.hostName, hostPub: original.hostPub,
            pskRoot: "new-root", relay: original.relay, lan: original.lan)
        XCTAssertNotEqual(PushNotificationIdentity.pairingKey(original), PushNotificationIdentity.pairingKey(rekeyed))
    }

    // APNS-L12: test the actual capability gate and request sequence, including
    // unexpected success statuses that must not masquerade as registration.
    func testCapabilityMustMatchBeforeTokenUpload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = try XCTUnwrap(PushRegistrationTarget(pairing()).request(token: "token", environment: "production"))
        for (status, config, expected, count) in [
            (200, "{\"version\":1,\"environment\":\"production\"}", 204, 2),
            (200, "{\"version\":1,\"environment\":\"sandbox\"}", 409, 1),
            (200, "{\"version\":2,\"environment\":\"production\"}", 409, 1),
            (200, "invalid-json", 409, 1), (201, "", 409, 1), (204, "", 409, 1),
            (404, "", 404, 1), (503, "", 503, 1)
        ] {
            PushHTTPFixture.configure(status: status, data: config)
            let result = try await PushRegistrationHTTP.send(request, using: session)
            XCTAssertEqual(result, expected)
            let requests = PushHTTPFixture.requests
            XCTAssertEqual(requests.count, count)
            XCTAssertEqual(requests.first?.url?.path, "/v1/push/config")
            XCTAssertEqual(requests.first?.httpMethod, "GET")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "environment", value: "production")])
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer credential")
            if count == 2 {
                XCTAssertEqual(requests.last?.url?.path, "/v1/push/register")
                XCTAssertEqual(requests.last?.httpMethod, "POST")
            }
        }
    }

    func testRemovalBypassesUnavailableCapabilityAndRedirectIsRefused() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        PushHTTPFixture.configure(status: 503, data: "")
        let request = try XCTUnwrap(PushRegistrationTarget(pairing()).request(token: nil, environment: "production"))
        let status = try await PushRegistrationHTTP.send(request, using: session)
        XCTAssertEqual(status, 204)
        XCTAssertEqual(PushHTTPFixture.requests.map { $0.url!.path }, ["/v1/push/register"])
        let production = PushRegistrationHTTP.session
        let delegate = try XCTUnwrap(production.delegate as? URLSessionTaskDelegate)
        let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil))
        var followed = true
        let task = production.dataTask(with: request)
        delegate.urlSession?(production, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://other.example")!), completionHandler: { followed = $0 != nil })
        XCTAssertFalse(followed)
        task.cancel()
    }

    // APNS-L14/SC113: the isolated runner supplies actual release sources. Old
    // v0.1.19 lacks config; recent releases advertise it. The fixture declares
    // which contract it is exercising, including upgrade and rollback.
    func testRealPreviousReleaseRelayCompatibilityWhenFixtureProvided() async throws {
        guard let old = ProcessInfo.processInfo.environment["ORBIS_PUSH_COMPAT_OLD"],
              let candidate = ProcessInfo.processInfo.environment["ORBIS_PUSH_COMPAT_NEW"] else {
            throw XCTSkip("Run via apns-lifecycle compatibility fixture")
        }
        let token = String(repeating: "c", count: 64)
        let releasedStatus = ProcessInfo.processInfo.environment["ORBIS_PUSH_COMPAT_OLD_SUPPORTS_CONFIG"] == "1" ? 204 : 404
        var request = try XCTUnwrap(PushRegistrationTarget(pairing(credential: "compat-phone-secret"))
            .request(token: token, environment: "production"))
        request.url = URL(string: old + "/v1/push/register")
        var status = try await PushRegistrationHTTP.send(request)
        XCTAssertEqual(status, releasedStatus)
        request.url = URL(string: candidate + "/v1/push/register")
        status = try await PushRegistrationHTTP.send(request)
        XCTAssertEqual(status, 204)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token, "environment": "sandbox"])
        status = try await PushRegistrationHTTP.send(request)
        XCTAssertEqual(status, 409)
        // Reconnecting after an upgrade/revert renegotiates every time.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token, "environment": "production"])
        request.url = URL(string: old + "/v1/push/register")
        status = try await PushRegistrationHTTP.send(request)
        XCTAssertEqual(status, releasedStatus)
    }
}

private final class PushHTTPFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var status = 200
    private static var data = Data()
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func configure(status: Int, data: String) {
        lock.lock(); defer { lock.unlock() }
        self.status = status; self.data = Data(data.utf8); recorded = []
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "relay.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let capability = request.url?.path == "/v1/push/config"
        let status = capability ? Self.status : 204, data = capability ? Self.data : Data()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
