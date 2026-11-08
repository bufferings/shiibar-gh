import Foundation
@testable import ShiibarGhCore
import XCTest

/// bufferings-work with example-org (o2), acme-corp (o3) and Public (o4).
func sampleAccount(todo: (Int, Int) = (2, 0), disabled: Set<String> = []) -> Account {
    Account(
        id: "3407303", login: "bufferings-work", color: .red, todoCount: todo.0 + todo.1, unread: true,
        owners: [
            Owner(id: "o2", name: "example-org", kind: .org, enabled: !disabled.contains("o2"), todoCount: todo.0, prCount: 4),
            Owner(id: "o3", name: "acme-corp", kind: .org, enabled: !disabled.contains("o3"), todoCount: todo.1, prCount: 1),
            Owner(id: "o4", name: "public", kind: .public, enabled: !disabled.contains("o4"), todoCount: 0, prCount: 0),
        ]
    )
}

func todoRow(_ id: String, pr: String, done: Bool = false) -> Row {
    Row(id: id, pr: pr, owner: "o2", kind: .mentioned, todo: true, done: done, url: "https://github.com/c/\(id)")
}

func eventRow(_ id: String, pr: String, owner: String = "o2") -> Row {
    Row(id: id, pr: pr, owner: owner, kind: .merged, url: "https://github.com/c/\(id)")
}

/// example-org: two Todo PRs and two without; acme-corp: one without.
func sampleCards() -> [Card] {
    [
        Card(id: "C1", pr: "example-org/api#407", owner: "o2", url: "https://github.com/p/1", rows: [todoRow("A", pr: "example-org/api#407"), eventRow("B", pr: "example-org/api#407")]),
        Card(id: "C2", pr: "example-org/api#5", owner: "o2", url: "https://github.com/p/2", rows: [eventRow("D", pr: "example-org/api#5")]),
        Card(id: "C3", pr: "example-org/web#212", owner: "o2", url: "https://github.com/p/3", rows: [todoRow("E", pr: "example-org/web#212", done: true), todoRow("F", pr: "example-org/web#212")]),
        Card(id: "C4", pr: "example-org/web#9", owner: "o2", url: "https://github.com/p/4", rows: []),
        Card(id: "C5", pr: "acme-corp/billing#88", owner: "o3", url: "https://github.com/p/5", rows: [eventRow("G", pr: "acme-corp/billing#88", owner: "o3")]),
    ]
}

func snoozedCards() -> [Card] {
    [Card(id: "S1", pr: "example-org/api#1", owner: "o2", url: "https://github.com/p/s1", snoozed: true, snoozedUntil: 1_800_090_000, rows: [todoRow("H", pr: "example-org/api#1")])]
}

final class PopoverLogicTests: XCTestCase {
    func sections(collapsed: [String: Bool] = [:], expanded: Set<String> = [], account: Account = sampleAccount()) -> [SectionLayout] {
        PopoverLogic.sections(
            account: account, cards: sampleCards(), snoozed: snoozedCards(), allSnoozed: snoozedCards() + [Card(id: "S2", owner: "o3", snoozed: true, snoozedUntil: 1_800_090_000)],
            collapsed: collapsed, expanded: expanded, timeZone: utc
        )
    }

    func testSectionsFollowTheOwnersWithTodoPRsFirstAndSnoozedLast() {
        let s = sections()
        XCTAssertEqual(s.map(\.title), ["example-org", "acme-corp", "Public", "Snoozed"])
        XCTAssertEqual(s.map(\.todoCount), [2, nil, nil, nil], "the red number comes from the owner, 0 hides it")
        XCTAssertEqual(s.map(\.detail), ["4 PRs", "1 PR", "0 PRs", "2 PRs · until Sat 09:00"], "the Snoozed count without filters")
        XCTAssertEqual(s[0].cards.map(\.id), ["C1", "C3"], "the PRs with an open Todo row, in their fixed order")
        XCTAssertEqual(s[0].moreText, "+ 2 more PRs")
        XCTAssertEqual(s[1].cards, [])
        XCTAssertEqual(s[1].moreText, "+ 1 more PR")
        XCTAssertEqual(s[2].more, 0)
        XCTAssertTrue(s[3].collapsed, "Snoozed starts collapsed")
        XCTAssertEqual(s[3].cards, [])
        XCTAssertFalse(s[0].collapsed, "owners start expanded")
    }

    func testExpandingAndCollapsing() {
        let open = sections(expanded: [SectionLayout.ownerKey("o2")])
        XCTAssertEqual(open[0].cards.map(\.id), ["C1", "C2", "C3", "C4"], "+ N more shows the rest in place")
        XCTAssertNil(open[0].moreText)
        let folded = sections(collapsed: [SectionLayout.ownerKey("o2"): true, SectionLayout.snoozedKey: false])
        XCTAssertTrue(folded[0].collapsed)
        XCTAssertEqual(folded[0].cards, [])
        XCTAssertNil(folded[0].moreText, "a collapsed section has no + N more")
        XCTAssertEqual(folded[3].cards.map(\.id), ["S1"])
    }

    func testSnoozedKeepsItsCountAndUntilWhenTheFiltersLeaveNoSnoozedCard() {
        let s = PopoverLogic.sections(
            account: sampleAccount(), cards: sampleCards(), snoozed: [], allSnoozed: snoozedCards(),
            collapsed: [SectionLayout.snoozedKey: false], expanded: [], timeZone: utc
        )
        XCTAssertEqual(s.last?.title, "Snoozed")
        XCTAssertEqual(s.last?.detail, "1 PR · until Sat 09:00")
        XCTAssertEqual(s.last?.cards, [])
    }

    func testTheEmptyStateTakesThePlaceOfTheOwnerSections() {
        XCTAssertNil(PopoverLogic.emptyText(loaded: false, cards: [], filter: FilterState()))
        XCTAssertNil(PopoverLogic.emptyText(loaded: true, cards: sampleCards(), filter: FilterState()))
        XCTAssertEqual(PopoverLogic.emptyText(loaded: true, cards: [], filter: FilterState()), "Nothing needs you")
        XCTAssertEqual(PopoverLogic.emptyText(loaded: true, cards: [], filter: FilterState(todo: true)), "Nothing matches")
        let s = PopoverLogic.sections(
            account: sampleAccount(), cards: [], snoozed: snoozedCards(), allSnoozed: snoozedCards(),
            collapsed: [:], expanded: [], showsEmpty: true
        )
        XCTAssertEqual(s.map(\.title), ["Snoozed"], "only Snoozed stays")
        let items = PopoverLogic.items(tab: .prs, sections: s, activity: [])
        XCTAssertEqual(items, [.section("snoozed")], "no hidden owner header to select")
        XCTAssertEqual(PopoverLogic.move(nil, up: false, in: items), .section("snoozed"))
        XCTAssertNil(PopoverLogic.action(for: .open, selection: .section("owner:o2"), sections: s, activity: []), "a section not shown does not fold")
        XCTAssertNil(PopoverLogic.action(for: .open, selection: .more("owner:o2"), sections: s, activity: []))
    }

    func testADisabledOwnerHasNoSectionAndNoSnoozedSectionWithoutSnoozedPRs() {
        let s = PopoverLogic.sections(
            account: sampleAccount(disabled: ["o3"]), cards: sampleCards(), snoozed: [], allSnoozed: [],
            collapsed: [:], expanded: []
        )
        XCTAssertEqual(s.map(\.title), ["example-org", "Public"])
    }

    func testTheSelectionWalksSectionsHeadersRowsAndMore() {
        let s = sections(collapsed: [SectionLayout.snoozedKey: false])
        let items = PopoverLogic.items(tab: .prs, sections: s, activity: [])
        XCTAssertEqual(items.map(\.id), [
            "section:owner:o2", "header:C1", "row:A", "row:B", "header:C3", "row:E", "row:F", "more:owner:o2",
            "section:owner:o3", "more:owner:o3", "section:owner:o4",
            "section:snoozed", "header:S1", "row:H",
        ])
        XCTAssertEqual(PopoverLogic.move(nil, up: false, in: items), items.first)
        XCTAssertEqual(PopoverLogic.move(nil, up: true, in: items), items.last)
        XCTAssertEqual(PopoverLogic.move(items[0], up: true, in: items), items[0], "stops at the top")
        XCTAssertEqual(PopoverLogic.move(items[7], up: false, in: items), items[8])
        let activity = sampleCards().flatMap(\.rows)
        XCTAssertEqual(PopoverLogic.items(tab: .activity, sections: s, activity: activity).map(\.id), activity.map { "row:" + $0.id })
        XCTAssertEqual(PopoverLogic.keep(.row(id: "A", card: "C1"), in: [.row(id: "A", card: nil)]), .row(id: "A", card: nil))
        XCTAssertNil(PopoverLogic.keep(.more("owner:o2"), in: []))
    }

    func testKeysTable() {
        let s = sections(collapsed: [SectionLayout.snoozedKey: false])
        func act(_ key: Key, _ item: SelectionItem) -> PopoverAction? {
            PopoverLogic.action(for: key, selection: item, sections: s, activity: [])
        }
        let section = SelectionItem.section("owner:o2")
        XCTAssertEqual(act(.open, section), .toggleSection("owner:o2"))
        XCTAssertNil(act(.snooze, section))
        XCTAssertNil(act(.todo, section))
        XCTAssertEqual(act(.open, .more("owner:o2")), .expand("owner:o2"))
        XCTAssertNil(act(.done, .more("owner:o2")))
        let header = SelectionItem.header(card: "C1")
        XCTAssertEqual(act(.open, header), .open("https://github.com/p/1"))
        XCTAssertEqual(act(.snooze, header), .snooze(pr: "example-org/api#407"))
        XCTAssertNil(act(.done, header))
        XCTAssertNil(act(.todo, header))
        XCTAssertEqual(act(.snooze, .header(card: "S1")), .unsnooze(pr: "example-org/api#1"), "S in Snoozed unsnoozes")
        let todo = SelectionItem.row(id: "A", card: "C1")
        XCTAssertEqual(act(.open, todo), .open("https://github.com/c/A"))
        XCTAssertEqual(act(.done, todo), .done(row: "A", on: true))
        XCTAssertEqual(act(.todo, todo), .todo(row: "A", on: false), "T removes from Todo")
        XCTAssertNil(act(.snooze, todo))
        let event = SelectionItem.row(id: "B", card: "C1")
        XCTAssertEqual(act(.todo, event), .todo(row: "B", on: true), "T adds to Todo")
        XCTAssertNil(act(.done, event), "D only on Todo rows")
        let done = SelectionItem.row(id: "E", card: "C3")
        XCTAssertEqual(act(.done, done), .done(row: "E", on: false), "Not done")
        XCTAssertNil(act(.todo, done), "T does nothing on a Done row")
        XCTAssertNil(PopoverLogic.action(for: .open, selection: nil, sections: s, activity: []))
    }

    func testTheHintFollowsTheSelection() {
        let s = sections(collapsed: [SectionLayout.ownerKey("o3"): true, SectionLayout.snoozedKey: false])
        func hint(_ item: SelectionItem?) -> String {
            PopoverLogic.hints(selection: item, sections: s, activity: []).map { "\($0.key) \($0.text)" }.joined(separator: "  ")
        }
        XCTAssertEqual(hint(.header(card: "C1")), "↑↓ Move  ⏎ Open  S Snooze")
        XCTAssertEqual(hint(.header(card: "S1")), "↑↓ Move  ⏎ Open  S Unsnooze")
        XCTAssertEqual(hint(.row(id: "B", card: "C1")), "↑↓ Move  ⏎ Open  T Add to Todo")
        XCTAssertEqual(hint(.row(id: "A", card: "C1")), "↑↓ Move  ⏎ Open  D Done  T Remove from Todo")
        XCTAssertEqual(hint(.row(id: "E", card: "C3")), "↑↓ Move  ⏎ Open  D Not done")
        XCTAssertEqual(hint(.section("owner:o2")), "↑↓ Move  ⏎ Collapse")
        XCTAssertEqual(hint(.section("owner:o3")), "↑↓ Move  ⏎ Expand")
        XCTAssertEqual(hint(.more("owner:o2")), "↑↓ Move  ⏎ Expand")
        XCTAssertEqual(hint(nil), "↑↓ Move", "nothing selected: only Move")
    }

    func testFilterTitlesAndNarrowing() {
        XCTAssertEqual(PrFilter.allCases.map(FilterState.title), ["All", "Authored by me", "Assigned to me", "Review requested"])
        XCTAssertEqual(PrFilter.allCases.map(\.rawValue), ["all", "authored", "assigned", "review_requested"])
        XCTAssertFalse(FilterState().narrows)
        XCTAssertTrue(FilterState(todo: true).narrows)
        XCTAssertTrue(FilterState(segment: .assigned).narrows)
    }

    func testActivityOwnerArguments() {
        let account = sampleAccount(disabled: ["o3"])
        XCTAssertEqual(ActivityOwners.buttons(account).map(\.displayName), ["example-org", "Public"])
        XCTAssertEqual(ActivityOwners.arguments([], account: account), [], "none on is every owner")
        XCTAssertEqual(ActivityOwners.arguments(["o4", "o2", "o3", "gone"], account: account), ["example-org", "public"])
    }

    func testWhatASurfaceShows() {
        XCTAssertEqual(SurfaceRules.content(account: sampleAccount(), dbUnreadable: true), .unreadable)
        XCTAssertEqual(SurfaceRules.content(account: Account(id: "a"), dbUnreadable: false), .noOwners)
        XCTAssertEqual(SurfaceRules.content(account: sampleAccount(), dbUnreadable: false), .list)
        XCTAssertEqual(SurfaceRules.noAccountsContent(dbUnreadable: true), .unreadable)
        XCTAssertEqual(SurfaceRules.noAccountsContent(dbUnreadable: false), .noAccounts)
        XCTAssertTrue(SurfaceRules.showsAppIcon([]))
        XCTAssertFalse(SurfaceRules.showsAppIcon([Account(id: "a")]))
    }

    func testOnlyRowsInsideTheVisibleAreaAreShown() {
        let frames: [String: ClosedRange<Double>] = ["a": 0...40, "b": 40...80, "c": 300...340, "d": -50 ... -1]
        XCTAssertEqual(Visibility.shown(frames: frames, viewport: 0...100), ["a", "b"])
    }

    func testSeenGoesOncePerOpenPeriodForUnreadRows() {
        var tracker = SeenTracker()
        XCTAssertEqual(tracker.newlySeen(shown: ["a", "b"], unread: ["a"]), ["a"])
        XCTAssertEqual(tracker.newlySeen(shown: ["a", "b"], unread: ["a", "b"]), ["b"])
        tracker.reset()
        XCTAssertEqual(tracker.newlySeen(shown: ["a"], unread: ["a"]), ["a"])
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
    var model: AppModel!

    override func setUp() async throws {
        (defaults, suite) = testDefaults()
        api = FakeAPI()
        opener = FakeOpener()
        notifier = FakeNotifier()
        model = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: opener, notifier: notifier, clock: { T0 })
        model.handle(.snapshot(accounts: [sampleAccount(), Account(id: "583231", login: "bufferings")], keychain: .known(.ok), dbUnreadable: false))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
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

    func testTheListsAskForTheAccountWithItsFilters() async {
        let view = model.viewModel("3407303")
        model.surfaceDisplayed(.popover, account: "3407303", true)
        await settle()
        XCTAssertEqual(Set(api.calls.filter { $0.hasPrefix("list") || $0.hasPrefix("activity") }), [
            "list bufferings-work todo=false filter=all snoozed=false",
            "list bufferings-work todo=false filter=all snoozed=true",
            "activity bufferings-work owners= todo=false filter=all",
        ])
        api.clearCalls()
        view.filter = FilterState(todo: true, segment: .reviewRequested)
        view.toggleOwner("o4")
        await settle()
        XCTAssertTrue(api.calls.contains("list bufferings-work todo=true filter=review_requested snoozed=true"))
        XCTAssertTrue(api.calls.contains("activity bufferings-work owners=public todo=true filter=review_requested"))
        let store = UIStateStore(defaults: defaults)
        XCTAssertEqual(store.filter(account: "3407303"), FilterState(todo: true, segment: .reviewRequested), "kept per account")
        XCTAssertEqual(store.filter(account: "583231"), FilterState())
        XCTAssertEqual(store.activityOwners(account: "3407303"), ["o4"])
    }

    func testSectionsFoldAndAreKeptButMoreIsNot() async {
        api.cards = sampleCards()
        api.snoozedCards = snoozedCards()
        let view = model.viewModel("3407303")
        view.reload()
        await settle()
        XCTAssertEqual(view.allSnoozed.count, 1)
        XCTAssertEqual(view.sections.first?.cards.map(\.id), ["C1", "C3"])
        view.perform(.toggleSection("owner:o2"))
        view.perform(.toggleSection("snoozed"))
        view.perform(.expand("owner:o3"))
        XCTAssertEqual(view.sections.map(\.collapsed), [true, false, false, false])
        XCTAssertEqual(view.sections[1].cards.map(\.id), ["C5"])
        XCTAssertEqual(UIStateStore(defaults: defaults).collapsed(account: "3407303"), ["owner:o2": true, "snoozed": false])
        // A new model reads the folds back; the + N more expansion is gone.
        let again = AccountViewModel(account: "3407303", app: model)
        XCTAssertEqual(again.collapsed, ["owner:o2": true, "snoozed": false])
        XCTAssertEqual(again.expanded, [])
        model.surfaceOpened(.popover, account: "3407303")
        model.surfaceClosed(.popover, account: "3407303")
        XCTAssertEqual(view.expanded, [], "closing folds + N more again")
    }

    func testKeysAndClicksAct() async {
        api.cards = sampleCards()
        let view = model.viewModel("3407303")
        view.reload()
        await settle()
        view.selection = .row(id: "A", card: "C1")
        view.press(.todo)
        view.press(.done)
        view.press(.open)
        view.selection = .header(card: "C1")
        view.press(.snooze)
        view.selection = .section("owner:o2")
        view.press(.open)
        await settle()
        XCTAssertTrue(api.calls.contains("todo A false"))
        XCTAssertTrue(api.calls.contains("done A true"))
        XCTAssertTrue(api.calls.contains("snooze bufferings-work example-org/api#407"))
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://github.com/c/A"])
        XCTAssertEqual(view.collapsed["owner:o2"], true)
        XCTAssertEqual(view.selection, .section("owner:o2"), "the header stays selected after folding")
        view.selection = nil
        view.press(.down)
        XCTAssertEqual(view.selection, .section("owner:o2"))
    }

    func testSeenGoesOnlyWhileOpenAndOnlyForUnreadShownRows() async {
        api.cards = sampleCards()
        let view = model.viewModel("3407303")
        model.surfaceDisplayed(.popover, account: "3407303", true)
        await settle()
        view.rowsShown(["A", "G"], surface: .popover)
        await settle()
        XCTAssertFalse(api.calls.contains { $0.hasPrefix("seen") }, "not open yet")
        model.surfaceOpened(.popover, account: "3407303")
        await settle()
        // G is in acme-corp's "+ 1 more PR": not laid out, so never shown.
        view.rowsShown(["A", "B"], surface: .popover)
        view.rowsShown(["A", "B"], surface: .popover)
        await settle()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("seen") }, ["seen A,B"])
    }

    func testNotificationsShowAtOnceAndClicksGoToTheWebOrThePopover() {
        var opened: [String] = []
        model.onOpenPopover = { opened.append($0) }
        let note = DaemonNotification(id: "n", type: .single, account: "3407303", url: "https://github.com/x", title: "bufferings-work · Mentioned")
        model.handle(.notify(note))
        XCTAssertEqual(notifier.shown, [note])
        model.notificationClicked(type: .single, account: "3407303", url: "https://github.com/x")
        model.notificationClicked(type: .summary, account: "583231", url: nil)
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://github.com/x"])
        XCTAssertEqual(opened, ["583231"])
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

    func testWithNoCardsTheKeysNeverReachAHiddenOwnerHeader() async {
        api.cards = []
        let view = model.viewModel("3407303")
        view.reload()
        await settle()
        XCTAssertEqual(view.emptyText, "Nothing needs you")
        XCTAssertEqual(view.items, [], "no Snoozed PRs either")
        view.press(.down)
        XCTAssertNil(view.selection, "↓ finds nothing to select")
        view.selection = .section("owner:o2")
        view.press(.open)
        XCTAssertEqual(view.collapsed, [:], "⏎ does not fold a section that is not shown")
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
