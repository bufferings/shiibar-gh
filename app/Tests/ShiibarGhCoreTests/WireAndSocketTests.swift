import Foundation
@testable import ShiibarGhCore
import XCTest

final class WireTests: XCTestCase {
    func testASnapshotKeepsUnknownValuesAndIgnoresUnknownFields() throws {
        let line = """
        {"event":"snapshot","db_unreadable":false,"later":1,"scopes":[{"id":"org","name":"Org","kind":"enterprise",
        "enabled":true,"notify":false,"color":"teal","badge":3,"dot":true,"updated_at":1800000000,"extra":{},
        "warnings":[{"kind":"token_expiring","token":"scope","message":"m","until":1800086400},
                    {"kind":"something_new","token":"other","message":"","until":null}]}]}
        """
        let event = try JSONDecoder().decode(SubscribeEvent.self, from: Data(line.utf8))
        guard case .snapshot(let scopes, let unreadable) = event else { return XCTFail("\(event)") }
        XCTAssertFalse(unreadable)
        let scope = try XCTUnwrap(scopes.first)
        XCTAssertEqual(scope.kind, .unknown("enterprise"))
        XCTAssertEqual(scope.color, .unknown("teal"))
        XCTAssertEqual(Palette.color(of: scope), .gray, "an unknown color draws gray")
        XCTAssertEqual(scope.badge, 3)
        XCTAssertEqual(scope.warnings[0].kind, .known(.tokenExpiring))
        XCTAssertEqual(scope.warnings[1].kind, .unknown("something_new"))
        XCTAssertEqual(scope.warnings[1].token, .unknown("other"))
    }

    func testUnknownEventsDecodeAsUnknown() throws {
        let event = try JSONDecoder().decode(SubscribeEvent.self, from: Data(#"{"event":"later","x":1}"#.utf8))
        XCTAssertEqual(event, .unknown("later"))
    }

    func testACardCarriesItsAvatarAndRows() throws {
        let line = """
        {"id":"PR_1","pr":"org/app#1","scope":"org","title":"T","url":"u","author":"alice",
         "author_avatar_url":"https://avatars.example/a?s=32","mine":false,"state_label":"mergeable",
         "review":"approved","checks":"in_progress","base_status":"behind","base":"main","head":"x",
         "snoozed":true,"snoozed_until":1800000000,"added_at":null,"links":{"review":"r","checks":"c","base":"b"},
         "rows":[{"id":"E_1","pr":"org/app#1","pr_title":"T","kind":"reaction","class":"event","text":"hi",
                  "counts":{"THUMBS_UP":3},"actor":null,"url":"u","occurred_at":5,"unread":true,"done":false}]}
        """
        let card = try JSONDecoder().decode(Card.self, from: Data(line.utf8))
        XCTAssertEqual(card.authorAvatarUrl, "https://avatars.example/a?s=32")
        XCTAssertEqual(card.stateLabel, .known(.mergeable))
        XCTAssertEqual(card.checks, .known(.inProgress))
        XCTAssertEqual(card.rows[0].counts, ["THUMBS_UP": 3])
        XCTAssertEqual(card.rows[0].rowClass, .known(.event))
        XCTAssertNil(card.addedAt)
    }

    func testANotificationDecodes() throws {
        let line = """
        {"event":"notify","notification":{"id":"n1","type":"summary","scope":"org","rows":["a","b"],"pr":null,
         "url":null,"title":"org · 2 new events","subtitle":null,"body":"In 1 PR"}}
        """
        let event = try JSONDecoder().decode(SubscribeEvent.self, from: Data(line.utf8))
        guard case .notify(let note) = event else { return XCTFail("\(event)") }
        XCTAssertEqual(note.type, .known(.summary))
        XCTAssertEqual(note.body, "In 1 PR")
    }

    func testConfigValuesTellBooleansFromNumbers() throws {
        XCTAssertEqual(try SocketDaemonAPI.configValue(Data(#"{"ok":true,"value":true}"#.utf8)), .bool(true))
        XCTAssertEqual(try SocketDaemonAPI.configValue(Data(#"{"ok":true,"value":1}"#.utf8)), .int(1))
        XCTAssertEqual(try SocketDaemonAPI.configValue(Data(#"{"ok":true,"value":0}"#.utf8)), .int(0))
        XCTAssertEqual(try SocketDaemonAPI.configValue(Data(#"{"ok":true,"value":"09:00"}"#.utf8)), .string("09:00"))
    }

    func testTheLineBufferJoinsLinesSplitOverReads() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.feed(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(buffer.feed(Data("1}\n{\"b\"".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}"])
        XCTAssertEqual(buffer.feed(Data(":2}\n\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"b\":2}"])
    }
}

final class SocketClientTests: XCTestCase {
    var dir = ""
    var fake: FakeDaemon!

    override func setUpWithError() throws {
        dir = temporaryDirectory()
        fake = try FakeDaemon(path: StateDirectory.socket(root: dir))
    }

    override func tearDown() {
        fake.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testARequestGetsItsAnswerAndErrorsCarryTheirCode() async throws {
        fake.respond = { line in
            if line.contains("\"list\"") {
                return ok(["cards": []])
            }
            return #"{"ok":false,"code":"not_found","error":"not found: scope x"}"#
        }
        let api = SocketDaemonAPI(socketPath: fake.path)
        let cards = try await api.list(ListFilter(scope: "org", needsAction: true))
        XCTAssertEqual(cards, [])
        do {
            try await api.done("x")
            XCTFail("expected an error")
        } catch let error as DaemonError {
            XCTAssertEqual(error.code, .known(.notFound))
            XCTAssertEqual(error.message, "not found: scope x")
        }
        let list = try XCTUnwrap(fake.requests.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: Any])
        XCTAssertEqual(object["cmd"] as? String, "list")
        XCTAssertEqual(object["scope"] as? String, "org")
        XCTAssertEqual(object["needs_action"] as? Bool, true)
    }

    func testAMissingDaemonIsAnErrorWithoutACode() async {
        fake.stop()
        do {
            _ = try await SocketDaemonAPI(socketPath: fake.path, timeout: 1).info()
            XCTFail("expected an error")
        } catch let error as DaemonError {
            XCTAssertNil(error.code)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testTheSubscriptionReadsALongSnapshotSentInPiecesAndSkipsUnknownEvents() {
        let scopes = (0..<200).map { #"{"id":"o\#($0)","name":"o\#($0)","kind":null,"enabled":true,"notify":true,"color":"gray","badge":0,"dot":false,"warnings":[],"updated_at":null}"# }
        fake.greeting = [
            #"{"event":"snapshot","db_unreadable":false,"scopes":["# + scopes.joined(separator: ",") + "]}",
            #"{"event":"brand_new","x":1}"#,
            #"{"event":"scope_changed","scope":{"id":"o1","name":"o1","kind":"org","enabled":true,"notify":true,"color":"blue","badge":1,"dot":true,"warnings":[],"updated_at":null}}"#,
        ]
        fake.chunk = 700
        fake.respond = { _ in ok(["version": "0.1.0", "started_at": 1]) }
        let supervisor = DaemonSupervisor(
            socketPath: fake.path, appVersion: "0.1.0", launcher: nil, callbackQueue: .main,
            backoff: { _ in 0.05 }
        )
        var events: [SubscribeEvent] = []
        supervisor.onEvent = { events.append($0) }
        supervisor.start()
        eventually { events.count == 2 }
        guard case .snapshot(let received, _) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(received.count, 200)
        guard case .scopeChanged(let changed) = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(changed.color, .known(.blue))
        XCTAssertTrue(fake.requests.contains(#"{"cmd":"subscribe","client":"app"}"#))
        supervisor.shutdown(timeout: 1) {}
    }

    func testTheSubscriptionReconnectsAfterTheDaemonDropsIt() {
        fake.respond = { _ in ok(["version": "0.1.0", "started_at": 1]) }
        let supervisor = DaemonSupervisor(
            socketPath: fake.path, appVersion: "0.1.0", launcher: nil, callbackQueue: .main,
            backoff: { _ in 0.05 }
        )
        var states: [Bool] = []
        supervisor.onConnectionChange = { states.append($0) }
        supervisor.start()
        eventually { states == [true] }
        fake.dropSubscribers()
        eventually { states == [true, false, true] }
        XCTAssertEqual(fake.commands.filter { $0 == "subscribe" }.count, 2)
        var finished = false
        supervisor.shutdown(timeout: 1) { finished = true }
        eventually { finished }
        XCTAssertEqual(fake.commands.last, "shutdown", "quitting stops the daemon")
    }

    func testADaemonOfAnotherVersionIsShutDownAndReplaced() {
        fake.respond = { line in
            line.contains("info") ? ok(["version": "0.0.9", "started_at": 1]) : ok()
        }
        let launcher = CountingLauncher()
        let supervisor = DaemonSupervisor(
            socketPath: fake.path, appVersion: "0.1.0", launcher: launcher, callbackQueue: .main,
            backoff: { _ in 0.05 }
        )
        launcher.onLaunch = { [fake] in
            // The old daemon is gone once asked; the new one answers.
            fake?.respond = { _ in ok(["version": "0.1.0", "started_at": 2]) }
        }
        fake.respond = { [fake] line in
            if line.contains("shutdown") {
                fake?.respond = { _ in "" }
                return ok()
            }
            return ok(["version": "0.0.9", "started_at": 1])
        }
        supervisor.start()
        eventually { launcher.launches == 1 }
        XCTAssertEqual(Array(fake.commands.prefix(2)), ["info", "shutdown"])
        supervisor.shutdown(timeout: 1) {}
    }
}

final class CountingLauncher: DaemonLauncher {
    var launches = 0
    var running = false
    var onLaunch: (() -> Void)?

    var isRunning: Bool { running }

    func launch() throws {
        launches += 1
        onLaunch?()
    }
}
