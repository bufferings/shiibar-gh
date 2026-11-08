import Foundation
@testable import ShiibarGhCore
import XCTest

final class WireTests: XCTestCase {
    static let accountJSON = """
    {"id":"3407303","login":"me","color":"teal","token":{"registered":true,"expires_at":1800086400,
     "last_test":{"at":1799990000,"results":[{"item":"account","label":"Account","owner":null,"outcome":"ok","text":"me","url":null},
       {"item":"later","label":"New","owner":null,"outcome":"maybe","text":"?","url":null}]}},
     "updated_at":1800000000,"todo_count":3,"unread":true,"later":1,
     "warnings":[{"kind":"token_expiring","account":"3407303","owner":null,"message":"Token expires in 1 day","until":1800086400,"url":null},
                 {"kind":"something_new","account":"3407303","owner":null,"message":"x","until":null,"url":null}],
     "rate_limit":{"graphql":{"used":1240,"limit":5000,"reset_at":1800003600},"rest":null},
     "owners":[{"id":"o2","name":"example-org","kind":"enterprise","github_id":21955855,"enabled":true,"notify":true,
                "skip_drafts":false,"todo_count":2,"pr_count":4}]}
    """

    func testASnapshotKeepsUnknownValuesAndIgnoresUnknownFields() throws {
        let line = #"{"event":"snapshot","keychain":"broken","db_unreadable":false,"later":1,"accounts":["# + Self.accountJSON + "]}"
        let event = try JSONDecoder().decode(SubscribeEvent.self, from: Data(line.utf8))
        guard case .snapshot(let accounts, let keychain, let unreadable) = event else { return XCTFail("\(event)") }
        XCTAssertFalse(unreadable)
        XCTAssertEqual(keychain, .unknown("broken"))
        let account = try XCTUnwrap(accounts.first)
        XCTAssertEqual(account.color, .unknown("teal"))
        XCTAssertEqual(account.accountColor, .none, "an unknown color draws as None")
        XCTAssertEqual(account.todoCount, 3)
        XCTAssertEqual(account.rateLimit?.graphql, Limit(used: 1240, limit: 5000, resetAt: 1_800_003_600))
        XCTAssertNil(account.rateLimit?.rest)
        XCTAssertEqual(account.token.lastTest?.results[1].item, .unknown("later"))
        XCTAssertEqual(account.token.lastTest?.results[1].outcome, .unknown("maybe"))
        XCTAssertEqual(account.warnings[1].kind, .unknown("something_new"))
        let owner = try XCTUnwrap(account.owners.first)
        XCTAssertEqual(owner.kind, .unknown("enterprise"))
        XCTAssertEqual(owner.githubId, 21_955_855)
        XCTAssertFalse(owner.skipDrafts)
        XCTAssertEqual(owner.argument, "example-org")
    }

    func testAccountEventsDecode() throws {
        let decoder = JSONDecoder()
        let changed = try decoder.decode(SubscribeEvent.self, from: Data((#"{"event":"account_changed","account":"# + Self.accountJSON + "}").utf8))
        guard case .accountChanged(let account) = changed else { return XCTFail("\(changed)") }
        XCTAssertEqual(account.login, "me")
        XCTAssertEqual(try decoder.decode(SubscribeEvent.self, from: Data(#"{"event":"account_removed","id":"7700"}"#.utf8)), .accountRemoved("7700"))
        XCTAssertEqual(
            try decoder.decode(SubscribeEvent.self, from: Data(#"{"event":"keychain_changed","keychain":"unreadable"}"#.utf8)),
            .keychainChanged(.known(.unreadable))
        )
        let public_ = try decoder.decode(Owner.self, from: Data(#"{"id":"o9","name":"public","kind":"public","github_id":null,"enabled":true,"notify":true,"skip_drafts":true,"todo_count":0,"pr_count":0}"#.utf8))
        XCTAssertTrue(public_.isPublic)
        XCTAssertEqual(public_.displayName, "Public")
        XCTAssertEqual(public_.argument, "public")
        XCTAssertEqual(public_.kindTitle, "Public repositories")
    }

    func testUnknownEventsDecodeAsUnknown() throws {
        let event = try JSONDecoder().decode(SubscribeEvent.self, from: Data(#"{"event":"later","x":1}"#.utf8))
        XCTAssertEqual(event, .unknown("later"))
    }

    func testACardCarriesItsAvatarFiltersAndRows() throws {
        let line = """
        {"id":"3407303:PR_1","pr":"org/app#1","account":"3407303","owner":"o2","title":"T","url":"u","author":"alice",
         "author_avatar_url":"https://avatars.example/a?s=32","authored_by_me":false,"assigned_to_me":true,
         "review_requested":true,"state_label":"mergeable",
         "review":"approved","checks":"in_progress","base_status":"behind","base":"main","head":"x",
         "snoozed":true,"snoozed_until":1800000000,"added_at":null,"links":{"review":"r","checks":"c","base":"b"},
         "rows":[{"id":"3407303:E_1","pr":"org/app#1","pr_title":"T","account":"3407303","owner":"o2","kind":"team_mentioned",
                  "todo":true,"done":false,"text":"hi","counts":{"THUMBS_UP":3},"actor":null,"url":"u","occurred_at":5,"unread":true}]}
        """
        let card = try JSONDecoder().decode(Card.self, from: Data(line.utf8))
        XCTAssertEqual(card.authorAvatarUrl, "https://avatars.example/a?s=32")
        XCTAssertFalse(card.authoredByMe)
        XCTAssertTrue(card.assignedToMe)
        XCTAssertTrue(card.reviewRequested)
        XCTAssertEqual(card.owner, "o2")
        XCTAssertEqual(card.checks, .known(.inProgress))
        XCTAssertEqual(card.rows[0].kind, .known(.teamMentioned))
        XCTAssertTrue(card.rows[0].todo)
        XCTAssertTrue(card.hasOpenTodo)
        XCTAssertNil(card.addedAt)
    }

    func testANotificationDecodes() throws {
        let line = """
        {"event":"notify","notification":{"id":"n1","type":"summary","account":"3407303","owner":"o2","rows":["a","b"],"pr":null,
         "url":null,"title":"me · 2 new events","subtitle":"org · in 2 PRs","body":null}}
        """
        let event = try JSONDecoder().decode(SubscribeEvent.self, from: Data(line.utf8))
        guard case .notify(let note) = event else { return XCTFail("\(event)") }
        XCTAssertEqual(note.type, .known(.summary))
        XCTAssertEqual(note.account, "3407303")
        XCTAssertEqual(note.subtitle, "org · in 2 PRs")
        XCTAssertNil(note.body)
    }

    func testTablesAndExclusionsDecode() throws {
        let events = try JSONDecoder().decode(EventsResponse.self, from: Data(#"{"ok":true,"events":{"review_requested":{"list":true,"todo":false,"notify":true}}}"#.utf8))
        XCTAssertEqual(events.events["review_requested"], EventCell(list: true, todo: false, notify: true))
        let list = try JSONDecoder().decode(ExclusionsResponse.self, from: Data(#"{"ok":true,"exclusions":{"repos":[{"name":"o/r","state":"hidden"}],"users":[{"name":"bot","state":"list_only"}]}}"#.utf8))
        XCTAssertEqual(list.exclusions.list(.repo), [Exclusion(name: "o/r", state: .hidden)])
        XCTAssertEqual(list.exclusions.list(.user), [Exclusion(name: "bot", state: .listOnly)])
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
            return #"{"ok":false,"code":"keychain_unavailable","error":"Couldn't read tokens from Keychain"}"#
        }
        let api = SocketDaemonAPI(socketPath: fake.path)
        let cards = try await api.list(ListQuery(account: "me", todo: true, filter: .reviewRequested, snoozed: true))
        XCTAssertEqual(cards, [])
        do {
            try await api.done("x", on: true)
            XCTFail("expected an error")
        } catch let error as DaemonError {
            XCTAssertEqual(error.code, .known(.keychainUnavailable))
            XCTAssertEqual(error.message, "Couldn't read tokens from Keychain")
        }
        let list = try XCTUnwrap(fake.requests.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: Any])
        XCTAssertEqual(object["cmd"] as? String, "list")
        XCTAssertEqual(object["account"] as? String, "me")
        XCTAssertEqual(object["filter"] as? String, "review_requested")
        XCTAssertEqual(object["todo"] as? Bool, true)
        XCTAssertEqual(object["snoozed"] as? Bool, true)
        XCTAssertNil(object["owner"])
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
        func account(_ n: Int, _ color: String) -> String {
            #"{"id":"\#(5000 + n)","login":"a\#(n)","color":"\#(color)","token":{"registered":true,"expires_at":null,"last_test":null},"updated_at":null,"todo_count":0,"unread":false,"warnings":[],"rate_limit":null,"owners":[]}"#
        }
        let accounts = (0..<200).map { account($0, "none") }
        fake.greeting = [
            #"{"event":"snapshot","keychain":"ok","db_unreadable":false,"accounts":["# + accounts.joined(separator: ",") + "]}",
            #"{"event":"brand_new","x":1}"#,
            #"{"event":"account_changed","account":"# + account(1, "blue") + "}",
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
        guard case .snapshot(let received, _, _) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(received.count, 200)
        guard case .accountChanged(let changed) = events.last else { return XCTFail("\(events)") }
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
