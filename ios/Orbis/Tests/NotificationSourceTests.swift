import Foundation
import XCTest
@testable import OrbisCore

final class NotificationSourceTests: XCTestCase {
    // SC111/112: duplicate names and truncation must not make two computers
    // indistinguishable, regardless of pairing order or another phone's labels.
    func testSourcesDisambiguateNamesAndShortFormsStably() throws {
        let inputs = [NotificationSource.Input(hostId: "one", name: "Mac mini", pairingKey: "p1"),
                      .init(hostId: "two", name: "Mac mini", pairingKey: "p2"),
                      .init(hostId: "three", name: "工作电脑", pairingKey: "p3")]
        let sources = NotificationSource.make(inputs, language: "zh-Hans")
        XCTAssertEqual(sources, NotificationSource.make(inputs.reversed(), language: "zh-Hans"))
        XCTAssertNotEqual(sources["one"]?.name, sources["two"]?.name)
        XCTAssertNotEqual(sources["one"]?.compactName, sources["two"]?.compactName)
        XCTAssertNotEqual(sources["one"]?.badge, sources["two"]?.badge)
        XCTAssertEqual(sources["three"]?.name, "工作电脑")
        XCTAssertEqual(sources["three"]?.badge, "工作")
        let prefixes = NotificationSource.make([.init(hostId: "a", name: "Office computer 1", pairingKey: "p1"),
                                               .init(hostId: "b", name: "Office computer 2", pairingKey: "p2")], language: "en")
        XCTAssertNotEqual(prefixes["a"]?.compactName, prefixes["b"]?.compactName)
        XCTAssertNotEqual(prefixes["a"]?.badge, prefixes["b"]?.badge)
        // Keep disambiguation visible even when the system truncates a long
        // notification title, and don't split a Chinese grapheme in the island.
        let longName = String(repeating: "工作电脑", count: 25)
        let long = NotificationSource.make([.init(hostId: "a", name: longName, pairingKey: "a"),
                                           .init(hostId: "b", name: longName, pairingKey: "b")], language: "zh-Hans")
        XCTAssertNotEqual(long["a"]?.name.prefix(4), long["b"]?.name.prefix(4))
        XCTAssertEqual(sources["three"]?.compactName.count, 4)
    }

    // The extension never needs the private pairing or a network request. A
    // removal replaces the directory atomically, with a readable local fallback.
    func testDirectoryRoundTripRemovalAndPrivateDataBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var directory = NotificationSourceDirectory(language: "en", hosts: NotificationSource.make([
            .init(hostId: "host", name: "Work Mac", pairingKey: "opaque-fingerprint")], language: "en"))
        try directory.write(to: url)
        XCTAssertEqual(NotificationSourceDirectory.read(from: url), directory)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["language", "hosts"])
        let hosts = try XCTUnwrap(json["hosts"] as? [String: [String: String]])
        XCTAssertEqual(Set(hosts["host"]!.keys), ["name", "compactName", "badge", "pairingKey"])
        let payload: [AnyHashable: Any] = ["orbis": ["v": 1, "hostId": "host", "category": "approval-requested", "eventId": "same"]]
        XCTAssertEqual(directory.alert(payload)?.title, "Work Mac")
        XCTAssertEqual(directory.alert(payload)?.body, "Approval needed")
        directory.hosts = [:]; try directory.write(to: url)
        let removed = try XCTUnwrap(NotificationSourceDirectory.read(from: url))
        XCTAssertTrue(try XCTUnwrap(removed.alert(payload)?.title).hasPrefix("Computer "))
        XCTAssertNil(removed.alert(["orbis": ["v": 2, "hostId": "host", "category": "approval-requested"]]))
        try Data("broken".utf8).write(to: url)
        XCTAssertNil(NotificationSourceDirectory.read(from: url))
    }

    // Host grouping is independent from event/session IDs, while the wire and
    // local representations use the same SHA256 namespacing contract.
    func testGroupingAndFallbackDoNotExposeRawHostIdentifiers() {
        XCTAssertNotEqual(NotificationSource.threadIdentifier("one"), NotificationSource.threadIdentifier("two"))
        XCTAssertEqual(NotificationSource.threadIdentifier("host"),
            "orbis.host.4740ae6347b0172c01254ff55bae5aff5199f4446e7f6d643d40185b3f475145")
        let source = NotificationSource.fallback(hostId: "private-host-identifier", language: "zh-Hans")
        XCTAssertTrue(source.name.hasPrefix("电脑 "))
        XCTAssertFalse(source.name.contains("private-host-identifier"))
        XCTAssertEqual(source.badge.count, 4)
    }

    func testRemoteNotificationsShowTheMatchingLocalSessionAndGroupSeparately() throws {
        let source = NotificationSource.make([.init(hostId: "host", name: "Work Mac", pairingKey: "pairing")], language: "en")
        var directory = NotificationSourceDirectory(language: "en", hosts: source)
        let first = LiveActivityProjection.focusKey(hostId: "host", agentKind: "claude", sessionId: "private-first-session")
        let second = LiveActivityProjection.focusKey(hostId: "host", agentKind: "codex", sessionId: "private-second-session")
        directory.updateSessionDisplays(hostId: "host", pairingKey: "pairing", sessions: [
            .init(focusKey: first, title: "  第一项\n排查  "), .init(focusKey: second, title: "第二项开发")])
        func payload(_ focus: String) -> [AnyHashable: Any] {
            ["orbis": ["v": 1, "hostId": "host", "category": "approval-requested",
                        "eventId": "focus:" + focus + ":" + String(repeating: "a", count: 32)]]
        }
        let firstAlert = try XCTUnwrap(directory.alert(payload(first)))
        let secondAlert = try XCTUnwrap(directory.alert(payload(second)))
        XCTAssertEqual(firstAlert.title, "Work Mac")
        XCTAssertEqual(firstAlert.subtitle, "第一项 排查")
        XCTAssertEqual(secondAlert.subtitle, "第二项开发")
        XCTAssertNotEqual(firstAlert.threadIdentifier, secondAlert.threadIdentifier)
        XCTAssertEqual(firstAlert.body, "Approval needed")
        let unknown = payload(String(repeating: "b", count: 64))
        XCTAssertEqual(directory.alert(unknown)?.subtitle, "")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try directory.write(to: url)
        let restored = try XCTUnwrap(NotificationSourceDirectory.read(from: url))
        XCTAssertEqual(restored.alert(payload(first)), firstAlert)
        let data = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(data.contains("private-first-session"))
        XCTAssertFalse(data.contains("private-second-session"))
        XCTAssertFalse(data.contains("sessionId"))
    }

    func testSessionDisplayCacheKeepsClosedSessionNamesAndClearsChangedPairings() throws {
        let original = NotificationSource.make([.init(hostId: "host", name: "Mac", pairingKey: "original")], language: "en")
        var directory = NotificationSourceDirectory(language: "en", hosts: original)
        let focus = String(repeating: "a", count: 64)
        directory.updateSessionDisplays(hostId: "host", pairingKey: "original", sessions: [.init(focusKey: focus, title: "Original session")])
        directory.updateSessionDisplays(hostId: "host", pairingKey: "original", sessions: [])
        XCTAssertEqual(directory.sessionDisplays?["host"]?.titles[focus], "Original session")

        let renamed = NotificationSource.make([.init(hostId: "host", name: "New Mac name", pairingKey: "original")], language: "en")
        directory.updateSources(renamed, language: "en")
        XCTAssertEqual(directory.sessionDisplays?["host"]?.titles[focus], "Original session")
        let replaced = NotificationSource.make([.init(hostId: "host", name: "Mac", pairingKey: "replacement")], language: "en")
        directory.updateSources(replaced, language: "en")
        XCTAssertNil(directory.sessionDisplays?["host"])
        directory.updateSessionDisplays(hostId: "host", pairingKey: "original", sessions: [.init(focusKey: focus, title: "Stale update")])
        XCTAssertNil(directory.sessionDisplays?["host"])
        directory.updateSessionDisplays(hostId: "host", pairingKey: "replacement", sessions: [.init(focusKey: focus, title: "New session")])
        directory.updateSources([:], language: "en")
        XCTAssertTrue(directory.sessionDisplays?.isEmpty == true)
    }

    func testFocusEventIdsHaveAnExactBackwardCompatibleEnvelope() throws {
        let focus = String(repeating: "a", count: 64), edge = String(repeating: "b", count: 32)
        let valid = "focus:" + focus + ":" + edge
        XCTAssertEqual(NotificationSource.focusKey(eventId: valid), focus)
        for invalid in [valid + "\n", valid + ":extra", "focus:" + focus.uppercased() + ":" + edge,
                        "focus:" + focus + ":short", "focus:" + focus + ":" + edge.uppercased(), "legacy-event-id"] {
            XCTAssertNil(NotificationSource.focusKey(eventId: invalid), invalid)
        }
        XCTAssertNil(NotificationSource.focusKey(eventId: nil))
        let legacy = Data("{\"language\":\"en\",\"hosts\":{}}".utf8)
        let decoded = try JSONDecoder().decode(NotificationSourceDirectory.self, from: legacy)
        XCTAssertNil(decoded.sessionDisplays)
        XCTAssertEqual(decoded.alert(["orbis": ["v": 1, "hostId": "host", "category": "task-completed", "eventId": "legacy"]])?.subtitle, "")
    }

    func testSessionDisplayCacheAndTitlesStayBounded() throws {
        let hosts = (0..<3).map { NotificationSource.Input(hostId: "host-\($0)", name: "Mac \($0)", pairingKey: "pairing-\($0)") }
        var directory = NotificationSourceDirectory(language: "en", hosts: NotificationSource.make(hosts, language: "en"))
        for host in 0..<3 {
            let sessions = (0..<180).map { index in
                NotificationSourceDirectory.SessionDisplay(focusKey: String(format: "%064x", index), title: String(repeating: "中文标题", count: 100))
            }
            directory.updateSessionDisplays(hostId: "host-\(host)", pairingKey: "pairing-\(host)", sessions: sessions)
        }
        let displays = try XCTUnwrap(directory.sessionDisplays)
        XCTAssertEqual(displays["host-2"]?.titles.count, NotificationSourceDirectory.maximumSessionsPerHost)
        XCTAssertLessThanOrEqual(displays.values.reduce(0) { $0 + $1.titles.count }, NotificationSourceDirectory.maximumSessions)
        XCTAssertTrue(displays.values.flatMap { $0.titles.values }.allSatisfy { $0.count <= 160 && $0.utf8.count <= 640 })
        let data = try JSONEncoder().encode(directory)
        XCTAssertLessThan(data.count, 512 * 1024)
    }

}
