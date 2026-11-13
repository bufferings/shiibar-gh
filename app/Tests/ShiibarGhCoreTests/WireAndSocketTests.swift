import Foundation
@testable import ShiibarGhCore
import XCTest

final class WireTests: XCTestCase {
    static let accountJSON = """
    {"id":"3407303","login":"me","color":"teal","token":{"registered":true,"expires_at":1800086400,
     "last_test":{"at":1799990000,"results":[{"item":"account","label":"Account","owner":null,"outcome":"ok","text":"me","url":null},
       {"item":"later","label":"New","owner":null,"outcome":"maybe","text":"?","url":null}]}},
     "updated_at":1800000000,"review_count":3,"unread":true,"later":1,
     "warnings":[{"kind":"token_expiring","account":"3407303","owner":null,"message":"Token expires in 1 day","until":1800086400,"url":null},
                 {"kind":"something_new","account":"3407303","owner":null,"message":"x","until":null,"url":null}],
     "rate_limit":{"graphql":{"used":1240,"limit":5000,"reset_at":1800003600},"rest":null},
     "owners":[{"id":"o2","name":"example-org","kind":"enterprise","github_id":21955855,"enabled":true,"notify":true,
                "skip_drafts":false,"review_count":2,"pr_count":4}]}
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
        XCTAssertEqual(account.owners.first?.prCount, 4)
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
        let public_ = try decoder.decode(Owner.self, from: Data(#"{"id":"o9","name":"public","kind":"public","github_id":null,"enabled":true,"notify":true,"skip_drafts":true,"review_count":0,"pr_count":0}"#.utf8))
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
         "review_requested":true,"awaiting_review":true,"state_label":"mergeable",
         "review":"approved","checks":"in_progress","base_status":"behind","base":"main","head":"x",
         "added_at":null,"created_at":null,"updated_at":1799990000,"links":{"review":"r","checks":"c","base":"b"},
         "placement":{"tab":"review","section":"waiting","position":2},"muted":["repo","author","later"],
         "dismissed_at":null,"dismiss_expires_at":null,"older_rows":true,
         "rows":[{"id":"3407303:E_1","pr":"org/app#1","pr_title":"T","account":"3407303","owner":"o2","kind":"team_mentioned",
                  "text":"hi","counts":{"THUMBS_UP":3},"actor":null,"url":"u","occurred_at":5,"unread":true,"muted":true},
                 {"id":"3407303:E_2","pr":"org/app#1","pr_title":"T","account":"3407303","owner":"o2","kind":"reopened",
                  "text":null,"counts":null,"actor":"bob","url":"u","occurred_at":4,"unread":false,"muted":false}]}
        """
        let card = try JSONDecoder().decode(Card.self, from: Data(line.utf8))
        XCTAssertEqual(card.authorAvatarUrl, "https://avatars.example/a?s=32")
        XCTAssertFalse(card.authoredByMe)
        XCTAssertTrue(card.assignedToMe)
        XCTAssertTrue(card.reviewRequested)
        XCTAssertEqual(card.owner, "o2")
        XCTAssertEqual(card.checks, .known(.inProgress))
        XCTAssertEqual(card.rows[0].kind, .known(.teamMentioned))
        XCTAssertTrue(card.rows[0].unread)
        XCTAssertTrue(card.rows[0].muted)
        XCTAssertEqual(card.rows[1].kind, .known(.reopened))
        XCTAssertTrue(card.hasUnread)
        XCTAssertFalse(card.hasBlueUnread, "its only unread row is muted")
        XCTAssertTrue(card.awaitingReview)
        XCTAssertNil(card.addedAt)
        XCTAssertNil(card.createdAt)
        XCTAssertEqual(card.updatedAt, 1_799_990_000)
        XCTAssertEqual(card.placement, Placement(tab: .review, section: .waiting, position: 2))
        XCTAssertEqual(card.muted, [.known(.repo), .known(.author), .unknown("later")])
        XCTAssertTrue(card.isMuted(for: .author))
        XCTAssertFalse(card.isMuted(for: .pr))
        XCTAssertNil(card.dismissedAt)
        XCTAssertTrue(card.olderRows)
    }

    /// A card without the 0.4 fields (an older daemon) still reads, with
    /// no placement, nothing muted and nothing dismissed.
    func testACardWithoutTheNewFieldsReads() throws {
        let line = """
        {"id":"c","pr":"o/r#1","account":"1","owner":"o2","title":"T","url":"u","author":"a","author_avatar_url":null,
         "authored_by_me":true,"state_label":"merged","review":"none","checks":"none","base_status":"none","base":"main","head":"x",
         "updated_at":1,"links":{"review":"r","checks":"c","base":"b"},"rows":[]}
        """
        let card = try JSONDecoder().decode(Card.self, from: Data(line.utf8))
        XCTAssertNil(card.placement)
        XCTAssertEqual(card.muted, [])
        XCTAssertFalse(card.olderRows)
        let dismissed = try JSONDecoder().decode(Card.self, from: Data(line.replacingOccurrences(of: #""rows":[]"#, with: #""rows":[],"dismissed_at":10,"dismiss_expires_at":604810,"placement":{"tab":"mine","section":"done","position":0}"#).utf8))
        XCTAssertEqual(dismissed.dismissedAt, 10)
        XCTAssertEqual(dismissed.dismissExpiresAt, 604_810)
        XCTAssertEqual(dismissed.placement?.isDone, true)
        XCTAssertNil(dismissed.autoDismissAt)
        let due = try JSONDecoder().decode(Card.self, from: Data(line.replacingOccurrences(of: #""rows":[]"#, with: #""rows":[],"auto_dismiss_at":259200"#).utf8))
        XCTAssertEqual(due.autoDismissAt, 259_200)
        XCTAssertEqual(dismissed.tab, .mine)
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

    func testTablesAndMutesDecode() throws {
        let events = try JSONDecoder().decode(EventsResponse.self, from: Data(#"{"ok":true,"events":{"review_requested":{"list":true,"notify":false}}}"#.utf8))
        XCTAssertEqual(events.events["review_requested"], EventCell(list: true, notify: false))
        let mutes = try JSONDecoder().decode(MutesResponse.self, from: Data(#"{"ok":true,"mutes":{"repos":["o/r"],"users":["renovate"],"prs":["o/r#2"]}}"#.utf8)).mutes
        XCTAssertEqual(mutes, Mutes(repos: ["o/r"], users: ["renovate"], prs: ["o/r#2"]))
        XCTAssertTrue(mutes.contains(.user, "Renovate"))
        XCTAssertEqual(mutes.list(.pr), ["o/r#2"])
        XCTAssertEqual(EventKind.allCases.map(\.rawValue), [
            "review_requested", "team_review_requested", "mentioned", "team_mentioned", "comment", "comment_other", "reply",
            "reply_mentioned", "reaction", "approved", "changes_requested", "checks_failed", "checks_passed", "conflicts", "mergeable",
            "merge_queue_added", "merge_queue_removed", "merged_closed", "reopened",
        ], "DESIGN.md, Wire format")
        XCTAssertEqual(WarningKind(rawValue: "status_fetch_failed"), .statusFetchFailed)
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
        let cards = try await api.list(.app("me"))
        XCTAssertEqual(cards, [])
        do {
            try await api.read(["x"])
            XCTFail("expected an error")
        } catch let error as DaemonError {
            XCTAssertEqual(error.code, .known(.keychainUnavailable))
            XCTAssertEqual(error.message, "Couldn't read tokens from Keychain")
        }
        let list = try XCTUnwrap(fake.requests.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: Any])
        XCTAssertEqual(object["cmd"] as? String, "list")
        XCTAssertEqual(object["account"] as? String, "me")
        XCTAssertEqual(object["dismissed"] as? String, "include")
        XCTAssertNil(object["tab"])
        XCTAssertNil(object["filter"], "the app filters by itself")
        XCTAssertNil(object["search"])
        XCTAssertNil(object["todo"])
        XCTAssertNil(object["owner"])
        let read = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fake.requests[1].utf8)) as? [String: Any])
        XCTAssertEqual(read["cmd"] as? String, "read")
        XCTAssertEqual(read["row_ids"] as? [String], ["x"])
    }

    func testTheAppAsksForListsWithTheAccountOnly() throws {
        func object(_ fields: [String: Any]) -> [String: String] {
            fields.mapValues { "\($0)" }
        }
        XCTAssertEqual(object(ListQuery.app("me").fields), ["cmd": "list", "account": "me", "dismissed": "include"])
        XCTAssertEqual(object(ListQuery(account: "me", tab: .review, dismissed: .only).fields),
                       ["cmd": "list", "account": "me", "tab": "review", "dismissed": "only"])
        let cli = ListQuery(account: "me", filter: .authored, search: "api #407").fields
        XCTAssertEqual(cli["search"] as? String, "api #407")
        XCTAssertEqual(cli["filter"] as? String, "authored")
    }

    /// `place`, `dismiss`, `restore`, `mute`, `unmute` and `mutes_get` as
    /// DESIGN.md, "Wire format" names their arguments.
    func testTheOperationsOfZeroFourGoOutAsTheWireSays() async throws {
        fake.respond = { line in
            line.contains("mute") ? ok(["mutes": ["repos": ["o/r"], "users": [], "prs": []]]) : ok(["card": [:]])
        }
        let api = SocketDaemonAPI(socketPath: fake.path)
        try await api.place(account: "me", pr: "o/r#1", target: .review(.todo), position: .before("o/r#2"))
        try await api.place(account: "me", pr: "o/r#1", target: .mine, position: .bottom)
        try await api.place(account: "me", pr: "o/r#1", target: .none, position: .byDefault)
        try await api.place(account: "me", pr: "o/r#1", target: .review(.waiting), position: .top)
        try await api.place(account: "me", pr: "o/r#1", target: .review(.done), position: .byDefault)
        try await api.place(account: "me", pr: "o/r#1", target: .mineDone, position: .byDefault)
        try await api.dismiss(account: "me", pr: "o/r#1")
        try await api.restore(account: "me", pr: "o/r#1")
        let muted = try await api.mute(account: "me", kind: .repo, name: "o/r")
        XCTAssertEqual(muted.repos, ["o/r"])
        _ = try await api.unmute(account: "me", kind: .user, name: "renovate")
        _ = try await api.mutes(account: "me")
        let sent = try fake.requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]).mapValues { "\($0)" } }
        XCTAssertEqual(sent, [
            ["cmd": "place", "account": "me", "pr": "o/r#1", "tab": "review", "section": "todo", "before": "o/r#2"],
            ["cmd": "place", "account": "me", "pr": "o/r#1", "tab": "mine", "at": "bottom"],
            ["cmd": "place", "account": "me", "pr": "o/r#1", "tab": "none"],
            ["cmd": "place", "account": "me", "pr": "o/r#1", "tab": "review", "section": "waiting", "at": "top"],
            ["cmd": "place", "account": "me", "pr": "o/r#1", "tab": "review", "section": "done"],
            ["cmd": "place", "account": "me", "pr": "o/r#1", "tab": "mine", "section": "done"],
            ["cmd": "dismiss", "account": "me", "pr": "o/r#1"],
            ["cmd": "restore", "account": "me", "pr": "o/r#1"],
            ["cmd": "mute", "account": "me", "kind": "repo", "name": "o/r"],
            ["cmd": "unmute", "account": "me", "kind": "user", "name": "renovate"],
            ["cmd": "mutes_get", "account": "me"],
        ])
    }

    func testAMissingDaemonIsAnErrorWithoutACode() async {
        fake.stop()
        do {
            _ = try await SocketDaemonAPI(socketPath: fake.path, timeout: 1).info()
            XCTFail("expected an error")
        } catch let error as DaemonError {
            XCTAssertNil(error.code)
            XCTAssertTrue(error.isUnreachable, "the band reads daemon not running")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testTheSubscriptionReadsALongSnapshotSentInPiecesAndSkipsUnknownEvents() {
        func account(_ n: Int, _ color: String) -> String {
            #"{"id":"\#(5000 + n)","login":"a\#(n)","color":"\#(color)","token":{"registered":true,"expires_at":null,"last_test":null},"updated_at":null,"review_count":0,"unread":false,"warnings":[],"rate_limit":null,"owners":[]}"#
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
