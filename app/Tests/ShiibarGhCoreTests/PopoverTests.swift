import Foundation
@testable import ShiibarGhCore
import XCTest

func sampleCards() -> [Card] {
    [
        Card(id: "PR_1", pr: "o/r#1", url: "https://github.com/o/r/pull/1", rows: [
            Row(id: "A", pr: "o/r#1", kind: .mentioned, rowClass: .needsAction, url: "https://github.com/c/A"),
            Row(id: "B", pr: "o/r#1", kind: .merged, rowClass: .event, url: "https://github.com/c/B"),
        ]),
        Card(id: "PR_2", pr: "o/r#2", url: "https://github.com/o/r/pull/2", snoozed: true, rows: [
            Row(id: "C", pr: "o/r#2", kind: .comment, rowClass: .needsAction, url: "https://github.com/c/C", done: true),
        ]),
    ]
}

final class PopoverLogicTests: XCTestCase {
    func testTheSelectionWalksHeadersAndRowsOnPRsAndRowsOnActivity() {
        let cards = sampleCards()
        let activity = cards.flatMap(\.rows)
        let prs = PopoverLogic.items(tab: .prs, cards: cards, activity: activity)
        XCTAssertEqual(prs, [
            .header(card: "PR_1"), .row(id: "A", card: "PR_1"), .row(id: "B", card: "PR_1"),
            .header(card: "PR_2"), .row(id: "C", card: "PR_2"),
        ])
        let rows = PopoverLogic.items(tab: .activity, cards: cards, activity: activity)
        XCTAssertEqual(rows.map(\.id), ["row:A", "row:B", "row:C"])

        XCTAssertEqual(PopoverLogic.move(nil, up: false, in: prs), prs.first)
        XCTAssertEqual(PopoverLogic.move(nil, up: true, in: prs), prs.last)
        XCTAssertEqual(PopoverLogic.move(prs[0], up: true, in: prs), prs[0], "stays at the top")
        XCTAssertEqual(PopoverLogic.move(prs[1], up: false, in: prs), prs[2])
        XCTAssertEqual(PopoverLogic.move(prs[4], up: false, in: prs), prs[4], "stays at the bottom")
        XCTAssertNil(PopoverLogic.move(nil, up: false, in: []))
        XCTAssertEqual(PopoverLogic.keep(.row(id: "A", card: "PR_1"), in: rows), .row(id: "A", card: nil), "a row stays selected across tabs")
        XCTAssertNil(PopoverLogic.keep(.header(card: "PR_1"), in: rows))
    }

    func testKeysTable() {
        let cards = sampleCards()
        let activity = cards.flatMap(\.rows)
        let cases: [(Key, SelectionItem, PopoverAction?)] = [
            (.open, .header(card: "PR_1"), .open("https://github.com/o/r/pull/1")),
            (.snooze, .header(card: "PR_1"), .snooze(pr: "o/r#1")),
            (.done, .header(card: "PR_1"), nil),
            (.snooze, .header(card: "PR_2"), nil),
            (.open, .row(id: "A", card: "PR_1"), .open("https://github.com/c/A")),
            (.done, .row(id: "A", card: "PR_1"), .done(row: "A")),
            (.done, .row(id: "B", card: "PR_1"), nil),
            (.done, .row(id: "C", card: "PR_2"), .undone(row: "C")),
            (.snooze, .row(id: "A", card: nil), .snooze(pr: "o/r#1")),
            (.snooze, .row(id: "C", card: nil), nil),
            (.open, .row(id: "gone", card: nil), nil),
        ]
        for (key, selection, want) in cases {
            XCTAssertEqual(PopoverLogic.action(for: key, selection: selection, cards: cards, activity: activity), want, "\(key) \(selection)")
        }
        XCTAssertNil(PopoverLogic.action(for: .open, selection: nil, cards: cards, activity: activity))
    }

    func testChips() {
        var chips = Chips()
        chips.pick(.mine)
        XCTAssertEqual(chips.author, .mine)
        chips.pick(.others)
        XCTAssertEqual(chips.author, .others, "one of the two")
        chips.pick(.others)
        XCTAssertEqual(chips.author, .all, "both off is everything")
        XCTAssertFalse(Chips(showSnoozed: true).narrows)
        XCTAssertTrue(Chips(needsAction: true).narrows)
        XCTAssertEqual(
            Chips(needsAction: true, author: .others, showSnoozed: true).filter(scope: "org"),
            ListFilter(scope: "org", needsAction: true, mine: false, others: true, snoozed: true)
        )
    }

    func testOnlyRowsInsideTheVisibleAreaAreShown() {
        let frames: [String: ClosedRange<Double>] = [
            "above": -40 ... -1, "touching": -10 ... 5, "inside": 20 ... 50, "edge": 299 ... 330, "below": 300 ... 340,
        ]
        XCTAssertEqual(Visibility.shown(frames: frames, viewport: 0 ... 300), ["touching", "inside", "edge"])
    }

    func testSeenGoesOncePerOpenPeriodForUnreadRows() {
        var tracker = SeenTracker()
        XCTAssertEqual(tracker.newlySeen(shown: ["A", "B"], unread: ["A"]), ["A"])
        XCTAssertEqual(tracker.newlySeen(shown: ["A", "C"], unread: ["A", "C"]), ["C"])
        tracker.reset()
        XCTAssertEqual(tracker.newlySeen(shown: ["A"], unread: ["A"]), ["A"])
    }

    func testOpenSurfacesCountPerScope() {
        var surfaces = OpenSurfaces()
        XCTAssertTrue(surfaces.opened(.popover, scope: "org"))
        XCTAssertFalse(surfaces.opened(.window, scope: "org"), "already open")
        XCTAssertFalse(surfaces.closed(.popover, scope: "org"), "the window still has the focus")
        XCTAssertTrue(surfaces.closed(.window, scope: "org"))
        XCTAssertFalse(surfaces.closed(.window, scope: "org"), "closing twice sends nothing")
        XCTAssertTrue(surfaces.opened(.window, scope: "public"))
        XCTAssertEqual(surfaces.openScopes, ["public"])
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var api: FakeAPI!
    var opener: FakeOpener!
    var notifier: FakeNotifier!
    var model: AppModel!

    override func setUp() async throws {
        (defaults, suite) = testDefaults()
        api = FakeAPI()
        opener = FakeOpener()
        notifier = FakeNotifier()
        model = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: opener, notifier: notifier, clock: { T0 })
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    func testPopoverAndWindowShareOneOpenStatePerScope() async {
        model.surfaceOpened(.popover, scope: "org")
        await settle()
        model.surfaceOpened(.window, scope: "org")
        model.surfaceClosed(.popover, scope: "org")
        await settle()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("popover_") }, ["popover_opened org"])
        model.surfaceClosed(.window, scope: "org")
        await settle()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("popover_") }, ["popover_opened org", "popover_closed org"])
    }

    func testAReconnectSendsPopoverOpenedAgainForOpenScopes() async {
        model.surfaceOpened(.popover, scope: "org")
        await settle()
        api.clearCalls()
        model.connectionChanged(false)
        model.connectionChanged(true)
        await settle()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("popover_") }, ["popover_opened org"])
        model.surfaceClosed(.popover, scope: "org")
        await settle()
        api.clearCalls()
        model.connectionChanged(true)
        await settle()
        XCTAssertTrue(api.calls.filter { $0.hasPrefix("popover_") }.isEmpty)
    }

    func testSeenGoesOnlyWhileOpenAndOnlyForUnreadShownRows() async {
        api.cards = sampleCards()
        let view = model.viewModel("org")
        model.surfaceDisplayed(.window, scope: "org", true)
        await settle()
        view.rowsShown(["A", "B", "C"], surface: .window)
        await settle()
        XCTAssertFalse(api.calls.contains { $0.hasPrefix("seen") }, "the window without the focus is closed")

        model.surfaceOpened(.window, scope: "org")
        await settle()
        XCTAssertTrue(api.calls.contains("seen A,B,C"), "\(api.calls)")
        api.clearCalls()
        view.rowsShown(["A", "B"], surface: .window)
        await settle()
        XCTAssertFalse(api.calls.contains { $0.hasPrefix("seen") }, "sent once per open period")
        model.surfaceClosed(.window, scope: "org")
        model.surfaceOpened(.window, scope: "org")
        await settle()
        XCTAssertTrue(api.calls.contains("seen A,B"), "\(api.calls)")
    }

    func testSeenComesOnlyFromTheSurfaceThatIsOpenAndFromItsNewLayout() async {
        api.cards = sampleCards()
        let view = model.viewModel("org")
        // The popover of an earlier open reported rows; a new popover has not
        // laid out yet.
        model.surfaceDisplayed(.popover, scope: "org", true)
        view.rowsShown(["A"], surface: .popover)
        model.surfaceDisplayed(.popover, scope: "org", false)
        model.surfaceDisplayed(.window, scope: "org", true)
        view.rowsShown(["B"], surface: .window)
        await settle()
        model.surfaceOpened(.popover, scope: "org")
        await settle()
        XCTAssertFalse(api.calls.contains { $0.hasPrefix("seen") }, "nothing before the new layout: \(api.calls)")
        view.rowsShown(["B"], surface: .window)
        await settle()
        XCTAssertFalse(api.calls.contains { $0.hasPrefix("seen") }, "the window has no focus")
        view.rowsShown(["C"], surface: .popover)
        await settle()
        XCTAssertTrue(api.calls.contains("seen C"), "\(api.calls)")
    }

    func testRowsHiddenByTheChipsAreNeverSentAsSeen() async {
        // With Needs action on, the daemon returns only PR_1: the rows of
        // PR_2 are not laid out, and a stale report of them sends nothing.
        api.cards = [sampleCards()[0]]
        let view = model.viewModel("org")
        view.chips.needsAction = true
        model.surfaceDisplayed(.popover, scope: "org", true)
        model.surfaceOpened(.popover, scope: "org")
        await settle()
        view.rowsShown(["A", "C"], surface: .popover)
        await settle()
        XCTAssertTrue(api.calls.contains("seen A"), "\(api.calls)")
        XCTAssertFalse(api.calls.contains { $0.hasPrefix("seen") && $0.contains("C") })
    }

    func testARemovedScopeGetsNoPopoverClosed() async {
        model.handle(.snapshot(scopes: [Scope(id: "org")], dbUnreadable: false))
        model.surfaceOpened(.popover, scope: "org")
        await settle()
        model.handle(.snapshot(scopes: [], dbUnreadable: false))
        model.surfaceClosed(.popover, scope: "org")
        await settle()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("popover_") }, ["popover_opened org"])
    }

    func testChipsReachTheDaemonAndAreKept() async {
        let view = model.viewModel("org")
        view.chips.needsAction = true
        view.chips.pick(.others)
        await settle()
        XCTAssertTrue(api.calls.contains("list org needs=true mine=false others=true snoozed=false"), "\(api.calls)")
        let again = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: opener, notifier: notifier)
        XCTAssertEqual(again.viewModel("org").chips, Chips(needsAction: true, author: .others))
        XCTAssertEqual(again.viewModel("other").chips, Chips(), "each scope keeps its own chips")
        again.viewModel("other").chips.showSnoozed = true
        let third = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: opener, notifier: notifier)
        XCTAssertEqual(third.viewModel("org").chips, Chips(needsAction: true, author: .others))
        XCTAssertEqual(third.viewModel("other").chips, Chips(showSnoozed: true))
    }

    func testKeysAndClicksAct() async {
        api.cards = sampleCards()
        let view = model.viewModel("org")
        model.surfaceDisplayed(.popover, scope: "org", true)
        await settle()
        view.press(.down)
        view.press(.open)
        XCTAssertEqual(opener.opened, [URL(string: "https://github.com/o/r/pull/1")!])
        view.press(.down)
        view.press(.done)
        view.press(.snooze)
        await settle()
        XCTAssertTrue(api.calls.contains("done A"))
        XCTAssertTrue(api.calls.contains("snooze o/r#1"))
        view.perform(.unsnooze(pr: "o/r#2"))
        await settle()
        XCTAssertTrue(api.calls.contains("unsnooze o/r#2"))
    }

    func testNotificationsShowAtOnceAndClicksGoToTheWebOrThePopover() {
        var opened: [String] = []
        model.onOpenPopover = { opened.append($0) }
        let single = DaemonNotification(id: "1", type: .single, scope: "org", url: "https://github.com/c/1", title: "org · Mentioned")
        model.handle(.notify(single))
        XCTAssertEqual(notifier.shown, [single])
        model.notificationClicked(type: .single, scope: "org", url: single.url)
        XCTAssertEqual(opener.opened, [URL(string: "https://github.com/c/1")!])
        XCTAssertEqual(opened, [], "an individual notification skips the popover")
        model.notificationClicked(type: .summary, scope: "org", url: nil)
        XCTAssertEqual(opened, ["org"])
    }

    func testSnapshotsAndChangesKeepTheScopes() {
        model.handle(.snapshot(scopes: [Scope(id: "org"), Scope(id: "off", enabled: false)], dbUnreadable: true))
        XCTAssertTrue(model.dbUnreadable)
        XCTAssertEqual(model.menuBarScopes.map(\.id), ["org"], "a disabled scope has no icon")
        model.handle(.scopeChanged(Scope(id: "org", badge: 2)))
        XCTAssertEqual(model.scope("org")?.badge, 2)
        model.handle(.unknown("later"))
        XCTAssertEqual(model.scopes.count, 2)
    }

    func testLaunchAtLoginAppliesTheDefaultOnceAndTheSettingFollows() async throws {
        let store = UIStateStore(defaults: defaults)
        let item = FakeLoginItem(.notRegistered)
        let launch = LaunchAtLogin(service: item, api: api, store: store)
        await launch.applyAtLaunch(runningFromBundle: true)
        XCTAssertEqual(item.calls, ["register"])
        XCTAssertTrue(launch.isOn)

        try await launch.set(false)
        await settle()
        XCTAssertEqual(api.config["launch_at_login"], .bool(false), "the setting follows the status")
        await launch.applyAtLaunch(runningFromBundle: true)
        XCTAssertEqual(item.calls, ["register", "unregister"], "the default is not applied again")

        item.registerResult = .requiresApproval
        try await launch.set(true)
        await settle()
        XCTAssertTrue(launch.isOn, "waiting for approval counts as on")
        XCTAssertEqual(api.config["launch_at_login"], .bool(true))

        let fresh = FakeLoginItem(.notRegistered)
        let (other, otherSuite) = testDefaults()
        defer { other.removePersistentDomain(forName: otherSuite) }
        await LaunchAtLogin(service: fresh, api: api, store: UIStateStore(defaults: other)).applyAtLaunch(runningFromBundle: false)
        XCTAssertEqual(fresh.calls, [], "only an app bundle registers")
    }

    func testAvatarsLoadOnceAndFailuresStayEmpty() async {
        let loader = FakeImages()
        let avatars = AvatarStore(loader: loader)
        avatars.request("https://avatars.example/a")
        avatars.request("https://avatars.example/a")
        avatars.request("https://avatars.example/fail")
        avatars.request("file:///etc/passwd")
        avatars.request(nil)
        await settle()
        XCTAssertEqual(avatars.image(for: "https://avatars.example/a"), Data([1]))
        XCTAssertNil(avatars.image(for: "https://avatars.example/fail"))
        avatars.request("https://avatars.example/fail")
        await settle()
        XCTAssertEqual(loader.loads.sorted(), ["https://avatars.example/a", "https://avatars.example/fail"])
    }

    func testOnlyHttpsAvatarsAreLoaded() async {
        let loader = FakeImages()
        let avatars = AvatarStore(loader: loader)
        avatars.request("http://avatars.example/plain")
        avatars.request("https://avatars.example/secure")
        await settle()
        XCTAssertEqual(loader.loads, ["https://avatars.example/secure"])
        XCTAssertNil(avatars.image(for: "http://avatars.example/plain"))
        XCTAssertEqual(avatars.image(for: "https://avatars.example/secure"), Data([1]))
    }

    func testAFailedAvatarIsTriedAgainLater() async {
        let loader = FakeImages()
        var now = Date(timeIntervalSince1970: 0)
        let avatars = AvatarStore(loader: loader, retryAfter: 300, clock: { now })
        avatars.request("https://avatars.example/fail")
        await settle()
        avatars.request("https://avatars.example/fail")
        await settle()
        XCTAssertEqual(loader.loads.count, 1, "not right away")
        now = now.addingTimeInterval(301)
        avatars.request("https://avatars.example/fail")
        await settle()
        XCTAssertEqual(loader.loads.count, 2)
    }
}

final class FakeImages: ImageLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var loads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func load(_ url: URL) async throws -> Data {
        lock.withLock { log.append(url.absoluteString) }
        if url.absoluteString.contains("fail") { throw URLError(.badServerResponse) }
        return Data([1])
    }
}
