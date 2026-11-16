// The account and surface models against a fake daemon: what goes to the
// daemon, what shows at once, the failure band, tabs, the Dismissed list,
// searches, notifications and the saved UI state.

import Foundation
@testable import ShiibarGhCore
import XCTest

final class SurfaceRuleTests: XCTestCase {
    func testWhatASurfaceShows() {
        XCTAssertEqual(SurfaceRules.content(account: sampleAccount(), dbUnreadable: true), .unreadable)
        XCTAssertEqual(SurfaceRules.content(account: Account(id: "a"), dbUnreadable: false), .noOwners)
        XCTAssertEqual(SurfaceRules.content(account: sampleAccount(), dbUnreadable: false), .list)
        XCTAssertEqual(SurfaceRules.noAccountsContent(dbUnreadable: true), .unreadable)
        XCTAssertEqual(SurfaceRules.noAccountsContent(dbUnreadable: false), .noAccounts)
        XCTAssertTrue(SurfaceRules.showsAppIcon([]))
        XCTAssertFalse(SurfaceRules.showsAppIcon([Account(id: "a")]))
    }

    func testOpenSurfacesCountPerAccount() {
        var surfaces = OpenSurfaces()
        XCTAssertTrue(surfaces.opened(.popover, account: "1001"))
        XCTAssertFalse(surfaces.opened(.window, account: "1001"), "already open")
        XCTAssertFalse(surfaces.closed(.popover, account: "1001"), "the window still has the focus")
        XCTAssertTrue(surfaces.closed(.window, account: "1001"))
        XCTAssertFalse(surfaces.closed(.window, account: "1001"), "closing twice sends nothing")
        XCTAssertTrue(surfaces.opened(.window, account: "583231"))
        XCTAssertEqual(surfaces.openAccounts, ["583231"])
    }

    func testTokenChecksRunFromTheSaveAnswerToANewTest() {
        var checks = TokenChecks()
        let old = Account(id: "3407303", token: TokenInfo(lastTest: LastTest(at: 100, results: [])))
        checks.started(old, before: 100, now: T0)
        XCTAssertTrue(checks.isChecking("3407303", now: T0))
        checks.update(Account(id: "3407303", token: TokenInfo(lastTest: nil)))
        XCTAssertTrue(checks.isChecking("3407303", now: T0), "the save clears last_test first")
        checks.update(Account(id: "3407303", token: TokenInfo(lastTest: LastTest(at: 200, results: []))))
        XCTAssertFalse(checks.isChecking("3407303", now: T0), "the new test ends it")

        checks.started(Account(id: "9919001"), before: nil, now: T0)
        XCTAssertTrue(checks.isChecking("9919001", now: T0))
        XCTAssertFalse(checks.isChecking("9919001", now: T0 + TokenChecks.limit), "a check that never ends stops counting")
        checks.forget("9919001")
        XCTAssertFalse(checks.isChecking("9919001", now: T0))

        checks.started(Account(id: "1200", token: TokenInfo(lastTest: LastTest(at: 300, results: []))), before: 100, now: T0)
        XCTAssertFalse(checks.isChecking("1200", now: T0), "the test came before the answer")
    }

}

@MainActor
final class AppModelTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var api: FakeAPI!
    var opener: FakeOpener!
    var notifier: FakeNotifier!
    var copier: FakeCopier!
    var model: AppModel!

    override func setUp() async throws {
        (defaults, suite) = testDefaults()
        api = FakeAPI()
        opener = FakeOpener()
        notifier = FakeNotifier()
        copier = FakeCopier()
        model = AppModel(
            api: api, store: UIStateStore(defaults: defaults), opener: opener, notifier: notifier,
            copier: copier, failureDuration: 0.8, clock: { T0 }
        )
        model.handle(.snapshot(accounts: [sampleAccount(), Account(id: "583231", login: "bufferings")], keychain: .known(.ok), dbUnreadable: false))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// The popover's list model with the sample cards loaded.
    func loaded(_ cards: [Card] = sampleCards()) async -> SurfaceListModel {
        api.cards = cards
        let data = model.viewModel("3407303")
        data.reload()
        await settle()
        return data.list(.popover)
    }

    func lists() -> [String] {
        api.calls.filter { $0.hasPrefix("list") }
    }

    func calls(_ prefix: String) -> [String] {
        api.calls.filter { $0.hasPrefix(prefix) }
    }

    func testTheListIsAskedOnceWithDismissedCardsAndWorkedOutHere() async {
        let view = model.viewModel("3407303").list(.popover)
        api.cards = sampleCards()
        model.surfaceDisplayed(.popover, account: "3407303", true)
        await settle()
        XCTAssertEqual(lists(), ["list bufferings-work dismissed=include"])
        api.clearCalls()
        view.openTab(.all)
        view.data.setGroupBy(.involvement)
        view.data.setThenBy(.status)
        view.data.setSort(.recentlyAdded)
        view.setSearch("dark")
        view.openTab(.review)
        view.openDismissedList()
        await settle()
        XCTAssertEqual(lists(), [], "tabs, Group by, sort, search and the Dismissed list ask the daemon nothing")
        let store = UIStateStore(defaults: defaults)
        XCTAssertEqual(store.options(account: "3407303"), ListOptions(groupBy: .involvement, thenBy: .status, sort: .recentlyAdded), "kept per account")
        XCTAssertEqual(store.options(account: "583231"), ListOptions())
    }

    /// No wait after `account_changed`; changes during a read make one
    /// more read after it (DESIGN.md, "Showing what an operation did").
    func testAccountChangesReadTheListAtOnceAndOnceMoreAfterABurst() async {
        _ = await loaded()
        model.surfaceDisplayed(.popover, account: "3407303", true)
        await settle()
        api.clearCalls()
        model.handle(.accountChanged(sampleAccount()))
        XCTAssertEqual(lists().count, 0, "the request is on its way")
        await settle()
        XCTAssertEqual(lists().count, 1)
        api.clearCalls()
        api.popoverOpenedDelay = 0
        for _ in 0..<5 { model.handle(.accountChanged(sampleAccount())) }
        await settle()
        await settle()
        XCTAssertEqual(lists().count, 2, "one now, one for the rest of the burst")
    }

    func testSelectingARowReadsItAndTheDotGoesAtOnce() async throws {
        let view = await loaded()
        view.openTab(.review)
        view.select(.header(card: "T1"))
        view.select(.row(id: "B", card: "T1"))
        await settle()
        XCTAssertEqual(calls("read"), [], "a header and a read row send nothing")
        api.operationDelay = 200_000_000
        view.select(.row(id: "A", card: "T1"))
        XCTAssertEqual(view.data.cards[1].rows[0].unread, false, "shown read before the daemon answers")
        // A list read before the answer still has A unread: the dot stays
        // off.
        view.data.reload()
        await settle()
        XCTAssertEqual(lists().count, 2)
        XCTAssertEqual(view.data.cards[1].rows[0].unread, false)
        var read = sampleCards()
        read[1].rows[0].unread = false
        api.cards = read
        try await Task.sleep(nanoseconds: 300_000_000)
        await settle()
        XCTAssertEqual(calls("read"), ["read A"])
        XCTAssertEqual(lists().count, 3, "read again after the answer")
        XCTAssertEqual(view.data.cards[1].rows[0].unread, false)
        XCTAssertNil(view.data.failure)
    }

    func testARefusedReadBringsTheDotBackWithTheBand() async throws {
        let view = await loaded()
        api.refuse["read"] = DaemonError(code: .notFound, message: "Row not found")
        view.select(.row(id: "A", card: "T1"))
        XCTAssertEqual(view.data.cards[1].rows[0].unread, false)
        await settle()
        XCTAssertEqual(view.data.cards[1].rows[0].unread, true)
        XCTAssertEqual(view.data.failure, "Couldn't mark as read: Row not found")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertNil(view.data.failure, "gone after its time")
    }

    /// DESIGN.md, "Confirming ×": the × asks first and concerns its own
    /// card only; ⌫ and the menu's `Dismiss` do not ask.
    func testTheCrossAsksBeforeDismissing() async {
        let view = await loaded()
        view.openTab(.review)
        view.select(.header(card: "T1"))
        view.perform(.confirmDismiss(card: "N1"))
        XCTAssertEqual(view.confirmingDismiss, "N1")
        XCTAssertNil(view.data.cards.first { $0.id == "N1" }?.dismissedAt, "nothing dismissed yet")
        view.press(.delete)
        XCTAssertNil(view.data.cards.first { $0.id == "T1" }?.dismissedAt, "the list takes no key meanwhile")
        XCTAssertEqual(
            KeyRules.decide(KeyPress(keyCode: KeyPress.delete), inSearch: false, hasSearchText: false, confirming: true), .ignore
        )
        XCTAssertEqual(KeyRules.decide(KeyPress(keyCode: KeyPress.returnKey), inSearch: false, hasSearchText: false, confirming: true), .answerDismiss(true))
        XCTAssertEqual(KeyRules.decide(KeyPress(keyCode: KeyPress.escape), inSearch: true, hasSearchText: true, confirming: true), .answerDismiss(false))
        view.answerDismiss(false)
        XCTAssertNil(view.confirmingDismiss)
        XCTAssertNil(view.data.cards.first { $0.id == "N1" }?.dismissedAt, "Cancel changes nothing")
        view.perform(.confirmDismiss(card: "N1"))
        view.answerDismiss(true)
        XCTAssertNotNil(view.data.cards.first { $0.id == "N1" }?.dismissedAt, "Dismiss: the card pressed")
        XCTAssertNil(view.data.cards.first { $0.id == "T1" }?.dismissedAt, "not the selected one")
        XCTAssertEqual(DismissedText.confirmText(keepDays: 7), "It moves to the Dismissed list and is removed after 7 days. You can restore it from there.")
        // ⌫ and the menu's `Dismiss` dismiss at once.
        view.press(.delete)
        XCTAssertNotNil(view.data.cards.first { $0.id == "T1" }?.dismissedAt)
        XCTAssertNil(view.confirmingDismiss)
        view.perform(.dismiss(card: "M2"))
        XCTAssertNotNil(view.data.cards.first { $0.id == "M2" }?.dismissedAt)
    }

    /// DESIGN.md, "Confirming ×": `Don't ask again` counts with `Dismiss`
    /// only; then the × dismisses at once.
    func testDontAskAgainStopsTheConfirmation() async throws {
        let view = await loaded()
        view.openTab(.review)
        view.perform(.confirmDismiss(card: "N1"))
        view.skipsNextConfirmations = true
        view.answerDismiss(false)
        XCTAssertTrue(view.data.app.confirmDismiss, "Cancel leaves the setting")
        view.perform(.confirmDismiss(card: "N1"))
        XCTAssertFalse(view.skipsNextConfirmations, "off each time the sheet opens")
        view.skipsNextConfirmations = true
        view.answerDismiss(true)
        XCTAssertFalse(view.data.app.confirmDismiss)
        XCTAssertNotNil(view.data.cards.first { $0.id == "N1" }?.dismissedAt)
        view.perform(.confirmDismiss(card: "T1"))
        XCTAssertNil(view.confirmingDismiss, "no sheet")
        XCTAssertNotNil(view.data.cards.first { $0.id == "T1" }?.dismissedAt)
        try await Task.sleep(nanoseconds: 100_000_000)
        let saved = try await view.data.app.api.configGet(DismissedText.confirmKey)
        XCTAssertEqual(saved.boolValue, false, "saved as the setting")
    }

    /// Main.html: "Couldn't dismiss: daemon not running".
    func testADismissShowsAtOnceAndComesBackWhenTheDaemonIsAway() async {
        let view = await loaded()
        view.openTab(.review)
        api.operationDelay = 100_000_000
        api.refuse["dismiss"] = DaemonError.unreachable(SocketError.closed)
        view.select(.header(card: "T1"))
        view.press(.delete)
        XCTAssertFalse(view.sections[1].matching.contains { $0.id == "T1" }, "gone from Todo at once")
        XCTAssertEqual(view.dismissedCount, 3)
        XCTAssertEqual(view.data.cards.first { $0.id == "T1" }?.dismissExpiresAt, T0 + 7 * 86_400)
        XCTAssertNil(view.selection)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await settle()
        XCTAssertEqual(calls("dismiss"), ["dismiss bufferings-work example-org/api#407"])
        XCTAssertTrue(view.sections[1].matching.contains { $0.id == "T1" }, "back where it was")
        XCTAssertEqual(view.data.failure, "Couldn't dismiss: daemon not running")
        // The next operation clears the band.
        api.refuse = [:]
        api.operationDelay = 0
        view.perform(.restore(card: "X1"))
        XCTAssertNil(view.data.failure)
        await settle()
        XCTAssertEqual(calls("restore"), ["restore bufferings-work example-org/web#205"])
    }

    func testAMoveWaitsInPlaceForTheAnswerAndTheNextList() async throws {
        let view = await loaded()
        view.openTab(.review)
        api.operationDelay = 200_000_000
        view.select(.header(card: "T3"))
        view.press(.moveTo(.doing))
        XCTAssertEqual(view.sections[0].cards.map(\.id), ["R1", "T3"], "at once, at the end of Doing")
        XCTAssertEqual(view.selection, .header(card: "T3"), "the selection follows the card")
        // A list read meanwhile (an account_changed) does not take it back.
        view.data.reload()
        await settle()
        XCTAssertEqual(view.sections[0].cards.map(\.id), ["R1", "T3"])
        // The daemon moved it: the list after the answer has it there.
        var moved = sampleCards()
        moved[3].placement = review(.doing, 1)
        api.cards = moved
        try await Task.sleep(nanoseconds: 300_000_000)
        await settle()
        XCTAssertEqual(calls("place"), ["place bufferings-work example-org/docs#88 review doing"])
        XCTAssertEqual(lists().count, 3, "read again after the answer")
        XCTAssertEqual(view.sections[0].cards.map(\.id), ["R1", "T3"])
        api.clearCalls()
        api.operationDelay = 0
        view.select(.header(card: "T4"))
        view.press(.reorder(up: true))
        await settle()
        XCTAssertEqual(calls("place"), ["place bufferings-work example-org/api#415 review todo before example-org/web#230"],
                       "`before` names the PR")
    }

    func testDraggingACardPlacesItInBothSurfaces() async {
        let popover = await loaded()
        popover.openTab(.review)
        let window = popover.data.list(.window)
        window.openTab(.review)
        api.operationDelay = 100_000_000
        popover.beginDrag("T4")
        XCTAssertEqual(popover.dragOver(.card("T1", lowerHalf: false)), DropTarget(section: "review|todo", position: .top), "the first card")
        XCTAssertEqual(popover.dragOver(.card("T2", lowerHalf: false)), DropTarget(section: "review|todo", position: .before("T2")))
        // Done takes a drop anywhere, by its own order: no position.
        XCTAssertEqual(popover.dragOver(.header("review|done")), DropTarget(section: "review|done", position: .byDefault))
        XCTAssertEqual(popover.dragOver(.card("D1", lowerHalf: true)), DropTarget(section: "review|done", position: .byDefault))
        XCTAssertTrue(popover.drop(.card("D1", lowerHalf: true)))
        XCTAssertEqual(window.sections[3].cards.map(\.id), ["T4", "D1"], "newest entry first, in the window too")
        try? await Task.sleep(nanoseconds: 200_000_000)
        await settle()
        // And out of Done again, onto a heading: the top of the section.
        popover.beginDrag("T4")
        XCTAssertTrue(popover.drop(.header("review|doing")))
        XCTAssertNil(popover.dragging)
        XCTAssertEqual(window.sections[0].cards.map(\.id), ["T4", "R1"], "the window shows it too")
        try? await Task.sleep(nanoseconds: 200_000_000)
        await settle()
        XCTAssertEqual(calls("place"), [
            "place bufferings-work example-org/api#415 review done",
            "place bufferings-work example-org/api#415 review doing top",
        ])
        // A drop where the card already is sends nothing.
        api.clearCalls()
        popover.beginDrag("T2")
        XCTAssertTrue(popover.drop(.card("T3", lowerHalf: false)))
        await settle()
        XCTAssertEqual(calls("place"), [])
    }

    func testMuteFromTheMenuShowsGrayAtOnceAndKeepsTheMutes() async {
        let view = await loaded()
        view.openTab(.review)
        api.mutes = Mutes(repos: ["example-org/web"])
        api.refuse["mute"] = nil
        view.perform(.mute(.repo, "example-org/web"))
        XCTAssertTrue(view.data.cards[0].isMuted)
        await settle()
        XCTAssertEqual(calls("mute"), ["mute bufferings-work repo example-org/web"])
        XCTAssertEqual(view.data.mutes, Mutes(repos: ["example-org/web"]))
        api.refuse["unmute"] = DaemonError(code: .notFound, message: "Not muted")
        view.perform(.unmute(.user, "example-bot"))
        await settle()
        XCTAssertEqual(view.data.failure, "Couldn't unmute: Not muted")
        XCTAssertTrue(view.data.cards[6].isMuted, "back to muted")
        // A mute made elsewhere (Settings, the CLI) comes with
        // `account_changed`: the mutes are read again.
        api.mutes = Mutes(repos: ["example-org/web"], users: ["alice"])
        api.clearCalls()
        model.handle(.accountChanged(view.data.account!))
        await settle()
        XCTAssertTrue(calls("mutes_get").count >= 1)
        XCTAssertEqual(view.data.mutes, Mutes(repos: ["example-org/web"], users: ["alice"]))
    }

    func testTheVerbsOfTheBand() async {
        let view = await loaded()
        view.openTab(.review)
        api.refuse["place"] = DaemonError(code: .invalid, message: "Invalid")
        view.perform(.place(PlaceMove(card: "N1", target: .mine, position: .byDefault, verb: .add)))
        await settle()
        XCTAssertEqual(view.data.failure, "Couldn't add: Invalid")
        view.perform(.place(PlaceMove(card: "M2", target: .none, position: .byDefault, verb: .remove)))
        await settle()
        XCTAssertEqual(view.data.failure, "Couldn't remove: Invalid")
        view.select(.header(card: "T1"))
        view.press(.reorder(up: false))
        await settle()
        XCTAssertEqual(view.data.failure, "Couldn't move: Invalid")
    }

    func testOpeningOpensAndReads() async {
        let view = await loaded()
        view.openTab(.review)
        view.select(.header(card: "T1"))
        view.press(.open)
        view.perform(.expandRows(card: "T1"))
        view.select(.row(id: "D", card: "T1"))
        view.press(.open)
        await settle()
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://github.com/p/T1", "https://github.com/c/D"])
        XCTAssertEqual(calls("read"), ["read D"], "a header opens the PR only")
    }

    func testRightClickSelectsReadsAndOffersTheMenu() async {
        let view = await loaded()
        view.openTab(.review)
        let menu = view.rightClick(.row(id: "A", card: "T1"))
        XCTAssertEqual(view.selection, .row(id: "A", card: "T1"))
        XCTAssertEqual(menu.compactMap { $0?.title }, ["Open on GitHub", "Copy link", "Mute @al", "Mark all as read"])
        view.perform(.copyLink("https://github.com/c/A"))
        await settle()
        XCTAssertEqual(calls("read"), ["read A"])
        XCTAssertEqual(calls("mutes_get"), ["mutes_get bufferings-work"], "a row's menu reads the mutes once")
        XCTAssertEqual(copier.copied, ["https://github.com/c/A"])
    }

    func testMarkAllAsReadSendsTheRowsOfTheTab() async {
        let view = await loaded()
        view.openTab(.mine)
        view.press(.markAllRead)
        await settle()
        XCTAssertEqual(calls("read"), ["read m1"], "only the tab's; never read_all")
        view.openTab(.review)
        view.setSearch("example-bot")
        view.perform(.markAllRead)
        await settle()
        XCTAssertEqual(calls("read"), ["read m1"], "the muted cards the Filter hides are left out")
        view.setMuteChoice(.show)
        view.perform(.markAllRead)
        await settle()
        XCTAssertEqual(calls("read"), ["read m1", "read t6,t7"], "after the search, folded and muted rows shown too")
        XCTAssertFalse(api.calls.contains { $0.hasPrefix("read_all") })
    }

    func testTabsAreKeptPerSurfaceAndCountTheirUnreadCards() async {
        let popover = await loaded()
        let window = popover.data.list(.window)
        XCTAssertEqual(popover.tab, .all)
        popover.openTab(.review)
        window.openTab(.mine)
        XCTAssertEqual(popover.unreadCount(.all), 3)
        XCTAssertEqual(popover.unreadCount(.review), 2)
        XCTAssertEqual(popover.unreadCount(.mine), 1)
        let store = UIStateStore(defaults: defaults)
        XCTAssertEqual(store.lastTab(account: "3407303", surface: .popover), .review)
        XCTAssertEqual(store.lastTab(account: "3407303", surface: .window), .mine)
        let again = AccountViewModel(account: "3407303", app: model)
        XCTAssertEqual(again.list(.popover).tab, .review)
        XCTAssertEqual(again.list(.window).tab, .mine)
        popover.press(.tab(.mine))
        XCTAssertEqual(popover.tab, .mine)
        XCTAssertEqual(window.tab, .mine)
    }

    func testTheDismissedListHasItsOwnSearchAndKeepsIt() async {
        let view = await loaded()
        model.surfaceOpened(.popover, account: "3407303")
        view.openTab(.review)
        view.setSearch("retry")
        view.openDismissedList()
        XCTAssertTrue(view.showingDismissed)
        XCTAssertEqual(view.search, "", "its own search")
        XCTAssertEqual(view.dismissedCards.map(\.id), ["X2", "X1"])
        XCTAssertEqual(view.rowsToRead, [])
        view.setSearch("bastion infra")
        XCTAssertEqual(view.dismissedCards.map(\.id), [], "no match")
        view.setSearch("infra")
        XCTAssertEqual(view.dismissedCards.map(\.id), ["X2"])
        view.select(.header(card: "X2"))
        view.press(.delete)
        await settle()
        XCTAssertEqual(calls("restore"), ["restore bufferings-work acme-corp/infra#55"])
        view.press(.back)
        XCTAssertFalse(view.showingDismissed)
        XCTAssertEqual(view.search, "retry", "the tab's search stays")
        view.openDismissedList()
        XCTAssertEqual(view.search, "infra", "closing the list keeps its search (DESIGN.md, \"Dismissed list\")")
        view.setSearch("zzz-none")
        view.press(.tab(.all))
        XCTAssertFalse(view.showingDismissed, "⌘1 opens the tab")
        view.openDismissedList()
        model.surfaceClosed(.popover, account: "3407303")
        XCTAssertFalse(view.showingDismissed, "the next opening shows the tab")
        XCTAssertEqual(view.data.search(.dismissed), "zzz-none", "closing the popover keeps it")
        XCTAssertEqual(view.data.search(.tab(.review)), "retry")
        view.openDismissedList()
        XCTAssertEqual(view.search, "zzz-none")
        XCTAssertEqual(view.dismissedCards.map(\.id), [], "and it still applies")
    }

    func testSearchIsPerTabAndKeptWhenThePopoverCloses() async {
        let view = await loaded()
        model.surfaceOpened(.popover, account: "3407303")
        view.press(.find)
        XCTAssertTrue(view.searchFocused)
        view.setSearch("retry")
        view.openTab(.mine)
        XCTAssertEqual(view.search, "", "Mine has its own")
        view.openTab(.all)
        XCTAssertEqual(view.search, "retry")
        view.leaveSearch(clearing: false)
        XCTAssertFalse(view.searchFocused)
        XCTAssertEqual(view.search, "retry", "↓ keeps the text")
        view.searchFocused = true
        view.leaveSearch(clearing: true)
        XCTAssertEqual(view.search, "", "Esc clears it")
        view.setSearch("x")
        model.surfaceClosed(.popover, account: "3407303")
        XCTAssertEqual(view.search, "x", "closing the popover keeps it")
        XCTAssertFalse(view.searchFocused)
        model.surfaceOpened(.popover, account: "3407303")
        XCTAssertEqual(view.search, "x", "the next opening shows it")
        XCTAssertFalse(view.searchFocused, "the field does not take the keyboard")
        view.setSearch("")
        XCTAssertEqual(view.search, "", "the clear button empties it")
        XCTAssertEqual(UIStateStore(defaults: defaults).searches(account: "3407303"), [:], "nothing left saved")
    }

    /// DESIGN.md, "Search field": the search text is kept like the Filter:
    /// per tab and for the Dismissed list, per account, shared by the
    /// popover and the window, kept when they close and after a restart.
    func testTheSearchTextIsTheAccountsSharedAndKept() async {
        let popover = await loaded()
        let window = popover.data.list(.window)
        model.surfaceDisplayed(.window, account: "3407303", true)
        model.surfaceOpened(.window, account: "3407303")
        popover.openTab(.review)
        window.openTab(.review)
        window.setSearch("retry")
        XCTAssertEqual(popover.search, "retry", "the window's text is the popover's")
        XCTAssertEqual(popover.sections.flatMap { $0.matching.map(\.id) }, window.sections.flatMap { $0.matching.map(\.id) })
        popover.openTab(.mine)
        popover.setSearch("api")
        XCTAssertEqual(window.search, "retry", "per tab")
        window.openTab(.mine)
        XCTAssertEqual(window.search, "api")
        window.openDismissedList()
        window.setSearch("infra")
        XCTAssertEqual(popover.search, "api", "the Dismissed list has its own")
        popover.openDismissedList()
        XCTAssertEqual(popover.search, "infra", "shared too")
        popover.closeDismissedList()
        model.surfaceClosed(.window, account: "3407303")
        XCTAssertEqual(window.search, "infra", "losing the focus keeps it")
        model.surfaceDisplayed(.window, account: "3407303", false)
        XCTAssertFalse(window.showingDismissed, "closing the window closes its Dismissed list")
        XCTAssertEqual(window.search, "api", "closing the window keeps the texts")
        XCTAssertEqual(popover.data.search(.dismissed), "infra")
        model.surfaceClosed(.popover, account: "3407303")

        // Another account has its own.
        let other = model.viewModel("583231")
        XCTAssertEqual(other.search(.tab(.review)), "")
        other.setSearch("dark", .tab(.review))
        XCTAssertEqual(popover.data.search(.tab(.review)), "retry")

        // A restart: a new store over the same UserDefaults.
        let store = UIStateStore(defaults: defaults)
        XCTAssertEqual(
            store.searches(account: "3407303"), [.tab(.review): "retry", .tab(.mine): "api", .dismissed: "infra"]
        )
        XCTAssertEqual(store.searches(account: "583231"), [.tab(.review): "dark"])
        let again = AppModel(
            api: api, store: UIStateStore(defaults: defaults), opener: opener, notifier: notifier, copier: copier, clock: { T0 }
        )
        let data = AccountViewModel(account: "3407303", app: again)
        let restarted = data.list(.popover)
        restarted.openTab(.review)
        XCTAssertEqual(restarted.search, "retry")
        restarted.openTab(.all)
        XCTAssertEqual(restarted.search, "")
        restarted.openDismissedList()
        XCTAssertEqual(restarted.search, "infra")
        withExtendedLifetime((again, data)) {}
    }

    func testFoldsAndExpansionsAreKeptPerSectionAndShared() async {
        let popover = await loaded()
        popover.data.setFilter(ListFilter(muted: .show), tab: .review)
        popover.openTab(.review)
        popover.perform(.toggleMore("review|todo"))
        XCTAssertEqual(popover.sections[1].foldLine, "Show less")
        popover.perform(.toggleSection("review|waiting"))
        let window = popover.data.list(.window)
        window.openTab(.review)
        XCTAssertEqual(window.sections[1].cards.count, 7, "the expansion is the account's")
        XCTAssertTrue(window.sections[2].collapsed)
        model.surfaceOpened(.popover, account: "3407303")
        model.surfaceClosed(.popover, account: "3407303")
        XCTAssertEqual(popover.sections[1].foldLine, "Show less", "kept across openings")
        let store = UIStateStore(defaults: defaults)
        XCTAssertEqual(store.expanded(account: "3407303"), ["review|todo"])
        XCTAssertEqual(store.collapsed(account: "3407303"), ["review|waiting"])
        popover.select(.more("review|todo"))
        popover.press(.open)
        XCTAssertEqual(popover.sections[1].foldLine, "+ 2 more PRs")
        XCTAssertEqual(popover.selection, .more("review|todo"))
        XCTAssertEqual(store.expanded(account: "3407303"), [])
    }

    /// DESIGN.md, "Rows in a card": "+ N more" stays expanded until `Show
    /// less`, across closing, kept per account and PR and shared by the
    /// popover and the window; forgotten once the card is gone.
    func testRowsStayExpandedUntilShowLess() async {
        let view = await loaded()
        view.openTab(.review)
        view.select(.moreRows(card: "T1"))
        view.press(.open)
        XCTAssertEqual(view.expandedRows, ["T1"])
        XCTAssertEqual(view.selection, .header(card: "T1"))
        XCTAssertTrue(view.items.contains(.olderActivity(card: "T1")))
        XCTAssertEqual(view.items.last { $0.owningCard == "T1" }, .lessRows(card: "T1"), "Show less ends the rows")
        view.select(.olderActivity(card: "T1"))
        view.press(.open)
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://github.com/p/T1"])
        model.surfaceOpened(.popover, account: "3407303")
        model.surfaceClosed(.popover, account: "3407303")
        XCTAssertEqual(view.expandedRows, ["T1"], "closing keeps it")
        XCTAssertEqual(view.data.list(.window).expandedRows, ["T1"], "the window shares it")
        let store = UIStateStore(defaults: defaults)
        XCTAssertEqual(store.expandedRows(account: "3407303"), ["T1"])
        XCTAssertEqual(AccountViewModel(account: "3407303", app: model).expandedRows, ["T1"], "read back")
        view.select(.lessRows(card: "T1"))
        XCTAssertEqual(view.selectedCards.cards, ["T1"], "Show less selects its card")
        view.press(.open)
        XCTAssertEqual(view.expandedRows, [])
        XCTAssertEqual(view.selection, .moreRows(card: "T1"), "+ N more takes the place of Show less")
        XCTAssertEqual(store.expandedRows(account: "3407303"), [])
        view.perform(.expandRows(card: "T1"))
        api.cards = sampleCards().filter { $0.id != "T1" }
        view.data.reload()
        await settle()
        XCTAssertEqual(store.expandedRows(account: "3407303"), [], "the card is gone")
    }

    /// DESIGN.md, "Row body": `more` and `less` keep the selection and the
    /// unread state; the state is kept per account and row until `less`,
    /// and forgotten when the row is gone.
    func testRowBodiesExpandUntilLess() async {
        let view = await loaded()
        view.openTab(.review)
        view.select(.header(card: "T2"))
        view.perform(.toggleBody(row: "A"))
        XCTAssertEqual(view.expandedBodies, ["A"])
        XCTAssertEqual(view.selection, .header(card: "T2"), "the selection stays")
        await settle()
        XCTAssertEqual(calls("read"), [], "not read")
        XCTAssertEqual(view.data.list(.window).expandedBodies, ["A"])
        let store = UIStateStore(defaults: defaults)
        XCTAssertEqual(store.expandedBodies(account: "3407303"), ["A"])
        model.surfaceOpened(.popover, account: "3407303")
        model.surfaceClosed(.popover, account: "3407303")
        XCTAssertEqual(view.expandedBodies, ["A"], "kept across closing")
        view.perform(.toggleBody(row: "A"))
        XCTAssertEqual(view.expandedBodies, [])
        view.perform(.toggleBody(row: "B"))
        var gone = sampleCards()
        gone[1].rows.remove(at: 1)
        api.cards = gone
        view.data.reload()
        await settle()
        XCTAssertEqual(store.expandedBodies(account: "3407303"), [], "the row was deleted")
    }

    func testGroupOrdersAreKeptAndNewRepositoriesComeLast() async {
        let view = await loaded()
        let data = view.data
        XCTAssertEqual(data.repositories, ["acme-corp/infra", "acme-corp/web", "example-org/api", "example-org/docs", "example-org/web"])
        data.moveGroups(.repository, from: [4], to: 0)
        XCTAssertEqual(data.groups(.repository).first?.title, "example-org/web")
        data.moveGroups(.status, from: [3], to: 0)
        XCTAssertEqual(data.groups(.status).map(\.title), ["Closed", "Open", "Draft", "Merged"])
        api.cards = sampleCards() + [card("Q", pr: "aaa/first#1")]
        data.reload()
        await settle()
        XCTAssertEqual(data.repositories.last, "aaa/first", "a new repository comes at the end")
        let store = UIStateStore(defaults: defaults)
        XCTAssertEqual(store.repositories(account: "3407303").first, "example-org/web")
        XCTAssertEqual(store.groupOrders(account: "3407303")[.status], ["closed", "open", "draft", "merged"])
        XCTAssertEqual(AccountViewModel(account: "3407303", app: model).groups(.status).first?.title, "Closed")
    }

    /// 0.4 reads no UI state of 0.3 (DESIGN.md, "Updating from 0.3 and
    /// 0.2").
    func testTheUIStateOf03IsNotRead() {
        let options = try! JSONEncoder().encode(["groupBy": "status", "sort": "recently_added"])
        defaults.set(options, forKey: "popover.filter.3407303")
        defaults.set(["owner:o2": true], forKey: "popover.collapsed.3407303")
        defaults.set(false, forKey: "window.keepOnTop.3407303")
        defaults.set("{{0, 0}, {10, 10}}", forKey: "window.frame.3407303")
        let store = UIStateStore(defaults: defaults)
        XCTAssertEqual(store.options(account: "3407303"), ListOptions())
        XCTAssertEqual(store.collapsed(account: "3407303"), [])
        XCTAssertTrue(store.keepOnTop(account: "3407303"))
        XCTAssertNil(store.windowFrame(account: "3407303"))
        store.setKeepOnTop(false, account: "3407303")
        XCTAssertEqual(defaults.object(forKey: "v4.window.keepOnTop.3407303") as? Bool, false)
    }

    /// DESIGN.md, "macOS notifications": an individual notification opens
    /// the tab of the PR, clears the search and unfolds the card.
    func testAClickedNotificationShowsTheCard() async {
        let view = await loaded()
        var shown: [String] = []
        var popovers: [String] = []
        model.onShowAccount = { shown.append("\($0) \($1)") }
        model.onOpenPopover = { popovers.append($0) }
        view.openTab(.mine)
        view.setSearch("keep")
        view.openTab(.review)
        view.setSearch("nothing")
        view.perform(.toggleSection("review|todo"))
        let note = DaemonNotification(id: "n", type: .single, account: "3407303", pr: "example-org/api#402", url: "https://github.com/x", title: "t")
        model.handle(.notify(note))
        XCTAssertEqual(notifier.shown, [note])
        model.notificationClicked(type: .single, account: "3407303", url: "https://github.com/x", pr: "example-org/api#402")
        XCTAssertEqual(shown, ["3407303 popover"])
        XCTAssertEqual(view.data.filter(.review).muted, .show, "T7 is muted: Review's Muted goes to Show to show it")
        XCTAssertEqual(view.data.filter(.all), ListFilter(), "the other tabs' Filters stay")
        XCTAssertEqual(view.tab, .review)
        XCTAssertEqual(view.search, "")
        XCTAssertEqual(view.data.list(.window).data.search(.tab(.review)), "", "the account's text: the window's too")
        XCTAssertEqual(UIStateStore(defaults: defaults).searches(account: "3407303"), [.tab(.mine): "keep"], "and the saved one")
        XCTAssertEqual(view.data.search(.tab(.mine)), "keep", "the other tabs' texts stay")
        XCTAssertEqual(view.selection, .header(card: "T7"))
        XCTAssertTrue(view.sections[1].cards.contains { $0.id == "T7" }, "unfolded and expanded")
        XCTAssertEqual(opener.opened, [], "no browser, no read")
        XCTAssertEqual(calls("read"), [])
        // A PR without a placement opens All; a dismissed one only its tab.
        model.notificationClicked(type: .single, account: "3407303", url: nil, pr: "acme-corp/web#80")
        XCTAssertEqual(view.tab, .all)
        XCTAssertEqual(view.selection, .header(card: "N1"))
        model.notificationClicked(type: .single, account: "3407303", url: nil, pr: "acme-corp/infra#55")
        XCTAssertEqual(view.tab, .review)
        XCTAssertNil(view.selection)
        // With the window open, the window shows it.
        model.surfaceDisplayed(.window, account: "3407303", true)
        model.notificationClicked(type: .single, account: "3407303", url: nil, pr: "example-org/api#421")
        XCTAssertEqual(shown.last, "3407303 window")
        XCTAssertEqual(view.data.list(.window).selection, .header(card: "M1"))
        model.notificationClicked(type: .summary, account: "583231", url: nil)
        XCTAssertEqual(popovers, ["583231"])
        // A summary with the window open: the window comes to the front, as
        // for a click on the menu bar icon.
        model.notificationClicked(type: .summary, account: "3407303", url: nil)
        XCTAssertEqual(popovers, ["583231"])
        XCTAssertEqual(shown.last, "3407303 window")
    }

    /// The notification came before the list: the card shows once it is
    /// read.
    func testANotificationBeforeTheListShowsTheCardWhenItComes() async {
        model.onShowAccount = { _, _ in }
        api.cards = sampleCards()
        model.notificationClicked(type: .single, account: "3407303", url: nil, pr: "acme-corp/web#77")
        let view = model.viewModel("3407303").list(.popover)
        XCTAssertNil(view.selection)
        view.data.reload()
        await settle()
        XCTAssertEqual(view.tab, .mine)
        XCTAssertEqual(view.selection, .header(card: "M2"))
    }

    func testThePlacementTagOpensItsTab() async {
        let view = await loaded()
        view.perform(.showInTab(card: "M2"))
        XCTAssertEqual(view.tab, .mine)
        XCTAssertEqual(view.selection, .header(card: "M2"))
    }

    func testRefreshShowsProgressUntilTheAnswer() async {
        model.refresh("3407303")
        XCTAssertEqual(model.refreshing, ["3407303"])
        await settle()
        XCTAssertEqual(model.refreshing, [])
        XCTAssertEqual(api.calls.last, "refresh bufferings-work")
    }

    func testTheDaysToKeepFollowTheSetting() async {
        api.config["dismissed_keep_days"] = .int(3)
        await model.loadConfig()
        XCTAssertEqual(model.keepDays, 3)
        model.handle(.configChanged(key: "dismissed_keep_days", value: .int(10)))
        XCTAssertEqual(model.keepDays, 10)
        let view = await loaded()
        view.perform(.dismiss(card: "N1"))
        XCTAssertEqual(view.data.cards.first { $0.id == "N1" }?.dismissExpiresAt, T0 + 10 * 86_400)
    }

    /// The daemon keeps the automatic Dismiss while open: the list is read
    /// once `popover_opened` is answered.
    func testTheListWaitsForPopoverOpened() async throws {
        api.popoverOpenedDelay = 200_000_000
        let list = model.viewModel("3407303").list(.popover)
        list.searchFocused = true
        model.surfaceDisplayed(.popover, account: "3407303", true, opening: true)
        model.surfaceOpened(.popover, account: "3407303")
        XCTAssertFalse(list.searchFocused, "the search field does not take the keyboard on open")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(lists(), [], "nothing before the answer")
        for _ in 0..<200 where lists().isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await settle()
        let calls = api.calls
        let answered = try XCTUnwrap(calls.firstIndex(of: "answered popover_opened"))
        let firstList = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("list") })
        XCTAssertLessThan(answered, firstList)
        XCTAssertEqual(lists().count, 1)
    }

    func testTextSizeKeysSendConfigSetAndStopAtTheEnds() async {
        api.config["text_size"] = .int(17)
        await model.loadConfig()
        XCTAssertEqual(model.textSize, 17)
        model.changeTextSize(.larger)
        await settle()
        XCTAssertEqual(model.textSize, 18)
        api.clearCalls()
        model.changeTextSize(.larger)
        await settle()
        XCTAssertEqual(api.calls, [], "⌘= at 18 sends nothing")
        model.changeTextSize(.reset)
        await settle()
        XCTAssertEqual(api.calls, ["config_set text_size int(12)"])
        model.handle(.configChanged(key: "text_size", value: .int(9)))
        XCTAssertEqual(model.textSize, 9, "config_changed applies at once")
        api.clearCalls()
        model.changeTextSize(.smaller)
        await settle()
        XCTAssertEqual(api.calls, [], "⌘− at 9 sends nothing")
    }

    // MARK: Copy

    func testCommandCCopiesTheLinkAndTheMenuHasNoCopy() async {
        let view = await loaded()
        view.openTab(.review)
        XCTAssertFalse(view.rightClick(.header(card: "T1")).compactMap { $0?.title }.contains("Copy"))
        view.press(.copy)
        view.select(.row(id: "A", card: "T1"))
        view.press(.copy)
        view.select(.section("review|todo"))
        view.press(.copy)
        XCTAssertEqual(copier.copied, ["https://github.com/p/T1", "https://github.com/c/A"], "nothing for a heading")
    }

    func testKeepOnTopIsKeptPerAccount() {
        let view = model.viewModel("3407303").list(.popover)
        XCTAssertTrue(view.data.keepOnTop, "on by default")
        view.data.toggleKeepOnTop()
        XCTAssertFalse(view.data.keepOnTop)
        XCTAssertFalse(UIStateStore(defaults: defaults).keepOnTop(account: "3407303"))
        XCTAssertTrue(model.viewModel("583231").keepOnTop)
        XCTAssertFalse(AccountViewModel(account: "3407303", app: model).keepOnTop, "read back")
    }

    func testPopoverAndWindowShareOneOpenStatePerAccountAndSendTheLogin() async {
        model.surfaceOpened(.popover, account: "3407303")
        model.surfaceOpened(.window, account: "3407303")
        model.surfaceClosed(.popover, account: "3407303")
        await settle()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("popover") }, ["popover_opened bufferings-work"])
        model.surfaceClosed(.window, account: "3407303")
        await settle()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("popover") }, ["popover_opened bufferings-work", "popover_closed bufferings-work"])
    }

    func testAReconnectSendsPopoverOpenedAgainForOpenAccounts() async {
        model.surfaceOpened(.popover, account: "583231")
        await settle()
        api.clearCalls()
        model.connectionChanged(false)
        model.connectionChanged(true)
        await settle()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("popover") }, ["popover_opened bufferings"])
    }

    func testAccountsChangeAndGoAway() {
        var changed = sampleAccount()
        changed.login = "renamed"
        model.handle(.accountChanged(changed))
        XCTAssertEqual(model.account("3407303")?.login, "renamed")
        model.handle(.accountChanged(Account(id: "8800")))
        XCTAssertEqual(model.accounts.map(\.id), ["3407303", "583231", "8800"])
        model.handle(.accountRemoved("583231"))
        XCTAssertEqual(model.accounts.map(\.id), ["3407303", "8800"])
        model.handle(.unknown("later"))
        XCTAssertEqual(model.accounts.count, 2)
    }

    func testTheKeychainDialogShowsOnceAndAgainAfterAFailedRetry() async {
        var dialogs: [KeychainDialog] = []
        model.onKeychainDialog = { dialogs.append($0) }
        model.handle(.keychainChanged(.known(.unavailable)))
        model.handle(.snapshot(accounts: [], keychain: .known(.unavailable), dbUnreadable: false))
        XCTAssertEqual(dialogs, [.unavailable])
        XCTAssertEqual(model.keychain, .unavailable)
        api.refreshWarnings = [Warning(kind: .keychainUnavailable)]
        model.keychainAction(.unavailable)
        await settle()
        XCTAssertEqual(api.calls.last, "refresh ")
        XCTAssertEqual(dialogs, [.unavailable, .unavailable], "Retry failed: the same dialog again")
        api.refreshWarnings = []
        model.keychainAction(.unavailable)
        await settle()
        XCTAssertEqual(dialogs.count, 2, "Retry worked")
        model.handle(.keychainChanged(.known(.unreadable)))
        model.keychainAction(.unreadable)
        await settle()
        XCTAssertEqual(api.calls.last, "token_reset")
        XCTAssertEqual(dialogs, [.unavailable, .unavailable, .unreadable])
        model.handle(.keychainChanged(.known(.ok)))
        XCTAssertEqual(model.keychain, .ok)
    }

    func testAccountsGoneFromASnapshotLeaveNoViewModel() {
        _ = model.viewModel("3407303")
        _ = model.viewModel("583231")
        model.surfaceDisplayed(.popover, account: "583231", true)
        model.handle(.snapshot(accounts: [sampleAccount()], keychain: .known(.ok), dbUnreadable: false))
        XCTAssertTrue(model.hasViewModel("3407303"))
        XCTAssertFalse(model.hasViewModel("583231"))
    }

    func testBannerButtons() {
        var settings: [SettingsDestination] = []
        var dialogs: [KeychainDialog] = []
        model.onOpenSettings = { settings.append($0) }
        model.onKeychainDialog = { dialogs.append($0) }
        model.bannerButton(.settings, account: "3407303")
        model.bannerButton(.authorize("https://github.com/orgs/x/sso"), account: "3407303")
        model.bannerButton(.retry, account: "3407303")
        model.bannerButton(.resetTokens, account: nil)
        XCTAssertEqual(settings, [.account("3407303")])
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://github.com/orgs/x/sso"])
        XCTAssertEqual(dialogs, [.unavailable, .unreadable])
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
