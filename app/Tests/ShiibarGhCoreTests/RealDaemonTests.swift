// The supervisor and the client against the real daemon. The daemon binary
// comes from `SHIIBAR_GH_TEST_DAEMON` (a `dev-ingest` build, which never
// reaches the real Keychain or GitHub); without it these tests are skipped.
// The state directory is a temporary one, passed as `SHIIBAR_GH_STATE_DIR`
// through the launcher's environment.

import Foundation
@testable import ShiibarGhCore
import XCTest

final class RealDaemonTests: XCTestCase {
    var dir = ""
    var binary: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["SHIIBAR_GH_TEST_DAEMON"], !path.isEmpty else {
            throw XCTSkip("SHIIBAR_GH_TEST_DAEMON is not set")
        }
        binary = URL(fileURLWithPath: path)
        dir = temporaryDirectory()
    }

    override func tearDown() {
        if !dir.isEmpty {
            let socket = StateDirectory.socket(root: dir)
            let api = SocketDaemonAPI(socketPath: socket, timeout: 1)
            let done = expectation(description: "shutdown")
            Task {
                try? await api.shutdown()
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    private func launcher() -> TestLauncher {
        TestLauncher(executable: binary, stateRoot: dir)
    }

    /// One request line as it is, for the dev-ingest requests.
    @discardableResult
    func dev(_ api: SocketDaemonAPI, _ fields: [String: Any]) async throws -> [String: Any] {
        let data = try await api.call(fields)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func pr(_ id: String, number: Int, requested: Bool = false, assignees: [String] = []) -> [String: Any] {
        [
            "id": id, "owner": "example-org", "repo": "api", "number": number,
            "url": "https://github.example/\(id)", "title": "Title \(id)", "author": "alice",
            "base": "main", "head": "topic", "state": "open", "is_draft": false, "review": "none",
            "checks": "none", "base_status": "none", "mergeable": false, "failed_check": NSNull(),
            "changes_requested_by": NSNull(), "updated_at": T0, "created_at": T0 - 3 * 86_400, "is_private": false,
            "requested_me": requested, "assignees": assignees,
            "links": ["review": "https://github.example/r", "checks": "https://github.example/c", "base": "https://github.example/b"],
        ]
    }

    func event(_ id: String, pr: String, kind: String, at: Int64) -> [String: Any] {
        ["id": id, "pr_id": pr, "kind": kind, "occurred_at": at, "url": "https://github.example/\(id)",
         "actor": "bob", "text": "text \(id)", "comment_id": NSNull()]
    }

    /// The app's model on the real daemon: accounts and owners made with the
    /// dev-ingest requests, then the popover's lists, keys, Settings
    /// requests and the events that come back.
    @MainActor
    func testTheAppRunsAgainstTheRealDaemon() async throws {
        let launcher = launcher()
        let supervisor = DaemonSupervisor(
            socketPath: StateDirectory.socket(root: dir), appVersion: "0.1.0", launcher: launcher,
            callbackQueue: .main, backoff: { _ in 0.1 }
        )
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = SocketDaemonAPI(socketPath: StateDirectory.socket(root: dir))
        let notifier = FakeNotifier()
        let model = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: notifier)
        var snapshots = 0
        supervisor.onEvent = { event in
            if case .snapshot = event { snapshots += 1 }
            model.handle(event)
        }
        supervisor.onConnectionChange = { model.connectionChanged($0) }
        supervisor.start()
        try await wait { snapshots == 1 }
        XCTAssertEqual(launcher.launches, 1)
        XCTAssertEqual(model.accounts, [])
        XCTAssertEqual(model.keychain, .ok)
        let log = (try? String(contentsOfFile: StateDirectory.daemonLog(root: dir), encoding: .utf8)) ?? ""
        guard log.contains("dev-ingest: no GitHub") else {
            return XCTFail("SHIIBAR_GH_TEST_DAEMON must be a dev-ingest build (cargo build -p shiibar-ghd --features dev-ingest)")
        }

        try await dev(api, ["cmd": "dev_clock_set", "now": T0, "tz": "UTC"])
        try await dev(api, ["cmd": "dev_account_add", "id": "3407303", "login": "me", "token": "t1"])
        try await dev(api, ["cmd": "dev_owner_add", "account": "me", "owner": "example-org", "kind": "org", "github_id": 100])
        _ = try await api.ownerAdd(account: "me", owner: "public")
        try await wait { model.account("3407303")?.owners.count == 2 }
        let account = try XCTUnwrap(model.account("3407303"))
        XCTAssertEqual(account.owners.map(\.displayName), ["example-org", "Public"])
        XCTAssertEqual(account.owners.first?.githubId, 100)
        XCTAssertEqual(account.accountColor, .none, "the first account has no color")
        XCTAssertTrue(account.token.registered)

        try await dev(api, ["cmd": "dev_ingest", "account": "me", "ingest": [
            "prs": [pr("PR_1", number: 1, requested: true), pr("PR_2", number: 2, assignees: ["me"])],
            "events": [
                event("RR_1", pr: "PR_1", kind: "review_requested", at: T0 + 10),
                event("M_2", pr: "PR_2", kind: "merged", at: T0 + 20),
            ],
            "succeeded_owners": ["example-org"],
        ]])
        try await wait { model.account("3407303")?.reviewCount == 1 }
        XCTAssertEqual(MenuBarMarks.accessibilityLabel(try XCTUnwrap(model.account("3407303"))), "me, unread, 1 review request")
        try await wait { !notifier.shown.isEmpty }
        XCTAssertEqual(notifier.shown.first?.title, "me · Review requested")
        XCTAssertEqual(notifier.shown.first?.account, "3407303")

        let data = model.viewModel("3407303")
        let view = data.list(.popover)
        model.surfaceDisplayed(.popover, account: "3407303", true)
        model.surfaceOpened(.popover, account: "3407303")
        try await wait { data.cards.count == 2 }
        let section = try XCTUnwrap(view.sections.first)
        XCTAssertEqual(section.title, "example-org")
        XCTAssertEqual(section.reviewCount, 1)
        XCTAssertEqual(section.detail, "2 PRs")
        XCTAssertEqual(section.cards.map(\.pr), ["example-org/api#1", "example-org/api#2"], "both have unread rows")
        let first = try XCTUnwrap(data.cards.first { $0.pr == "example-org/api#1" })
        XCTAssertTrue(first.awaitingReview)
        XCTAssertTrue(first.reviewRequested)
        XCTAssertEqual(first.createdAt, T0 - 3 * 86_400)
        XCTAssertEqual(first.updatedAt, T0)
        XCTAssertEqual(data.cards.first { $0.pr == "example-org/api#2" }?.assignedToMe, true)

        // The chips and the search are the app's own.
        data.options.segment = .assigned
        XCTAssertEqual(view.sections.first?.cards.map(\.pr), ["example-org/api#2"])
        data.options.segment = .all
        view.setSearch("api #1")
        XCTAssertEqual(view.sections.first?.cards.map(\.pr), ["example-org/api#1"])
        view.setSearch("")

        // Selecting the request reads it; the PR still waits for a review.
        view.select(.row(id: "3407303:RR_1", card: "3407303:PR_1"))
        try await wait {
            data.cards.flatMap(\.rows).first { $0.id == "3407303:RR_1" }?.unread == false
        }
        var afterRead: [Card] = []
        for _ in 0..<100 {
            afterRead = try await api.list(ListQuery(account: "me"))
            if afterRead.flatMap(\.rows).first(where: { $0.id == "3407303:RR_1" })?.unread == false { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(afterRead.flatMap(\.rows).first { $0.id == "3407303:RR_1" }?.unread, false, "the daemon has it read")
        XCTAssertEqual(afterRead.first { $0.pr == "example-org/api#1" }?.awaitingReview, true, "the mark stays")
        XCTAssertEqual(model.account("3407303")?.reviewCount, 1)

        // ⇧R reads the rest with `read`.
        view.press(.markAllRead)
        try await wait { data.cards.flatMap(\.rows).allSatisfy { !$0.unread } }
        var allRead: [Card] = []
        for _ in 0..<100 {
            allRead = try await api.list(ListQuery(account: "me"))
            if allRead.flatMap(\.rows).allSatisfy({ !$0.unread }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(allRead.flatMap(\.rows).allSatisfy { !$0.unread }, "the daemon has every row read")

        // S snoozes; the Snoozed section has it.
        view.select(.header(card: "3407303:PR_2"))
        view.press(.snooze)
        try await wait { data.snoozed.count == 1 }
        XCTAssertEqual(view.sections.last?.title, "Snoozed")

        // Activity by owner, in the app.
        view.tab = .activity
        data.toggleOwner(account.owners[1].id)
        XCTAssertEqual(view.activityEmptyText, "Nothing matches")
        data.showAllOwners()
        XCTAssertFalse(view.activity.isEmpty)
        model.surfaceClosed(.popover, account: "3407303")

        // Text size goes through the daemon and comes back as config_changed.
        _ = try await api.configSet("text_size", .int(13))
        try await wait { model.textSize == 13 }
        do {
            _ = try await api.configSet("text_size", .int(19))
            XCTFail("expected invalid")
        } catch let error as DaemonError {
            XCTAssertEqual(error.code, .known(.invalid))
        }
        let saved = try await api.configGet("text_size")
        XCTAssertEqual(saved, .int(13))

        // Settings requests.
        try await api.accountColor("me", .purple)
        try await wait { model.account("3407303")?.accountColor == .purple }
        let org = try XCTUnwrap(model.account("3407303")?.owners.first)
        let table = try await api.ownerEventsSet(account: "me", owner: org.argument, event: .reviewRequested, column: .list, on: false)
        XCTAssertEqual(table["review_requested"], EventCell(list: false, notify: false), "List off turns Notify off")
        XCTAssertEqual(table.count, 16)
        let copied = try await api.ownerEventsCopy(account: "me", from: "public", to: org.argument)
        XCTAssertEqual(copied["review_requested"]?.list, true)
        var excluded = try await api.ownerExclusionsSet(account: "me", owner: org.argument, kind: .repo, name: "example-org/legacy", state: .hidden)
        XCTAssertEqual(excluded.repos, [Exclusion(name: "example-org/legacy", state: .hidden)])
        excluded = try await api.ownerExclusionsRemove(account: "me", owner: org.argument, kind: .repo, name: "example-org/legacy")
        XCTAssertEqual(excluded.repos, [])
        try await api.ownerNotify(account: "me", owner: org.argument, on: false)
        try await api.ownerSkipDrafts(account: "me", owner: org.argument, on: false)
        try await api.ownerEnabled(account: "me", owner: "public", on: false)
        try await wait {
            let owners = model.account("3407303")?.owners ?? []
            return owners.first?.notify == false && owners.first?.skipDrafts == false && owners.last?.enabled == false
        }
        let returnTime = try await api.configGet("snooze_return_time")
        XCTAssertEqual(returnTime, .string("09:00"))
        do {
            _ = try await api.configSet("status_interval_minutes", .int(0))
            XCTFail("expected invalid")
        } catch let error as DaemonError {
            XCTAssertEqual(error.code, .known(.invalid))
        }
        // No GitHub in this build: a lookup cannot reach it.
        do {
            _ = try await api.ownerAdd(account: "me", owner: "rust-lang")
            XCTFail("expected an error")
        } catch let error as DaemonError {
            XCTAssertNotNil(error.code)
        }
        let removed = try await api.ownerRemove(account: "me", owner: "public")
        XCTAssertEqual(removed.owners.map(\.name), ["example-org"])

        try await api.accountRemove("me")
        try await wait { model.accounts.isEmpty }

        let stopped = expectation(description: "stopped")
        supervisor.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 10)
        let gone = Date().addingTimeInterval(10)
        while launcher.isRunning && Date() < gone {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(launcher.isRunning, "Quit stops the daemon")
    }

    /// DESIGN.md, "When a card shows and leaves": a card shown while the
    /// popover is open stays when its last unread row is read, and leaves
    /// after `popover_closed`.
    @MainActor
    func testACardShownWhileOpenStaysUntilThePopoverCloses() async throws {
        let supervisor = DaemonSupervisor(
            socketPath: StateDirectory.socket(root: dir), appVersion: "0.1.0", launcher: launcher(),
            callbackQueue: .main, backoff: { _ in 0.1 }
        )
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = SocketDaemonAPI(socketPath: StateDirectory.socket(root: dir))
        let model = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: FakeNotifier(), reloadDelay: 0.05)
        var connected = false
        supervisor.onEvent = { model.handle($0) }
        supervisor.onConnectionChange = { connected = $0; model.connectionChanged($0) }
        supervisor.start()
        try await wait { connected }
        try await dev(api, ["cmd": "dev_clock_set", "now": T0, "tz": "UTC"])
        try await dev(api, ["cmd": "dev_account_add", "id": "3407303", "login": "me", "token": "t1"])
        try await dev(api, ["cmd": "dev_owner_add", "account": "me", "owner": "example-org", "kind": "org", "github_id": 100])
        var closed = pr("PR_9", number: 9)
        closed["state"] = "closed"
        try await dev(api, ["cmd": "dev_ingest", "account": "me", "ingest": [
            "prs": [closed],
            "events": [event("CL_9", pr: "PR_9", kind: "closed", at: T0 + 10)],
            "succeeded_owners": ["example-org"],
        ]])
        try await wait { model.account("3407303")?.unread == true }

        let data = model.viewModel("3407303")
        let view = data.list(.popover)
        model.surfaceDisplayed(.popover, account: "3407303", true)
        model.surfaceOpened(.popover, account: "3407303")
        try await wait { data.cards.map(\.pr) == ["example-org/api#9"] }
        view.select(.row(id: "3407303:CL_9", card: "3407303:PR_9"))
        var listed: [Card] = []
        for _ in 0..<100 {
            listed = try await api.list(ListQuery(account: "me"))
            if listed.flatMap(\.rows).allSatisfy({ !$0.unread }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(listed.map(\.pr), ["example-org/api#9"], "read, closed, and still listed while open")
        XCTAssertTrue(listed.flatMap(\.rows).allSatisfy { !$0.unread })
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(data.cards.map(\.pr), ["example-org/api#9"], "the app still shows it")

        model.surfaceClosed(.popover, account: "3407303")
        model.surfaceDisplayed(.popover, account: "3407303", false)
        var after: [Card] = listed
        for _ in 0..<100 {
            after = try await api.list(ListQuery(account: "me"))
            if after.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(after, [], "gone after popover_closed")
        let stopped = expectation(description: "stopped")
        supervisor.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 10)
    }

    /// An unreadable test Keychain shows the dialog, and Reset tokens clears
    /// it.
    @MainActor
    func testTheKeychainDialogFollowsTheDaemon() async throws {
        try "not json".write(toFile: (dir as NSString).appendingPathComponent("keychain.json"), atomically: true, encoding: .utf8)
        let launcher = launcher()
        let supervisor = DaemonSupervisor(
            socketPath: StateDirectory.socket(root: dir), appVersion: "0.1.0", launcher: launcher,
            callbackQueue: .main, backoff: { _ in 0.1 }
        )
        let (defaults, suite) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = SocketDaemonAPI(socketPath: StateDirectory.socket(root: dir))
        let model = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: FakeNotifier())
        var dialogs: [KeychainDialog] = []
        model.onKeychainDialog = { dialogs.append($0) }
        var connected = false
        supervisor.onEvent = { model.handle($0) }
        supervisor.onConnectionChange = { connected = $0 }
        supervisor.start()
        try await wait { connected }
        try await dev(api, ["cmd": "dev_account_add", "id": "3407303", "login": "me"])
        model.refresh(nil)
        try await wait { model.keychain == .unreadable }
        XCTAssertEqual(dialogs, [.unreadable])
        XCTAssertTrue(model.account("3407303")?.warnings.contains { $0.kind.value == .tokensUnreadable } ?? false)
        XCTAssertEqual(TokenState.label(account: try XCTUnwrap(model.account("3407303")), keychain: model.keychain, checking: false, now: 0)?.text, "Keychain unavailable")
        model.keychainAction(.unreadable)
        try await wait { model.keychain == .ok }
        try await wait { model.account("3407303")?.warnings.contains { $0.kind.value == .noToken } ?? false }
        XCTAssertEqual(dialogs, [.unreadable])
        let stopped = expectation(description: "stopped")
        supervisor.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 10)
    }

    /// Poll the main actor until the condition holds.
    @MainActor
    func wait(_ timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in \(timeout) s", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testADaemonThatDiesIsStartedAgain() async throws {
        let launcher = launcher()
        let supervisor = DaemonSupervisor(
            socketPath: StateDirectory.socket(root: dir), appVersion: "0.1.0", launcher: launcher,
            callbackQueue: .main, backoff: { _ in 0.1 }
        )
        var snapshots = 0
        supervisor.onEvent = { if case .snapshot = $0 { snapshots += 1 } }
        supervisor.start()
        let deadline = Date().addingTimeInterval(20)
        while snapshots < 1 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(snapshots, 1)
        launcher.kill()
        let again = Date().addingTimeInterval(30)
        while snapshots < 2 && Date() < again {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(launcher.launches, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: StateDirectory.previousDaemonLog(root: dir)),
            "the log of the run that died is kept"
        )
        let stopped = expectation(description: "stopped")
        supervisor.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 10)
    }
}

/// The real launcher with the test's state directory in the environment.
final class TestLauncher: DaemonLauncher {
    private let inner: ProcessDaemonLauncher
    private(set) var launches = 0

    init(executable: URL, stateRoot: String) {
        inner = ProcessDaemonLauncher(
            executable: executable, stateRoot: stateRoot,
            environment: [
                "SHIIBAR_GH_STATE_DIR": stateRoot,
                // The test Keychain: a file in the state directory, never the
                // real Keychain.
                "SHIIBAR_GH_DEV_KEYCHAIN": (stateRoot as NSString).appendingPathComponent("keychain.json"),
                "SHIIBAR_GH_LOG": "info",
                "PATH": "/usr/bin:/bin",
            ]
        )
    }

    var isRunning: Bool { inner.isRunning }

    func launch() throws {
        launches += 1
        try inner.launch()
    }

    func kill() {
        inner.terminate()
    }
}
