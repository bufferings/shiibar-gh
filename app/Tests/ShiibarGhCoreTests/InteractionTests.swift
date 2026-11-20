// Clicks, double clicks, the selection of several cards and what acts on
// them (DESIGN.md, "What a press does" and "Selection and operating on
// several cards"), without a screen.

import Foundation
@testable import ShiibarGhCore
import XCTest

final class ClickTests: XCTestCase {
    let heading = ClickTarget.item(.header(card: "T1"))
    let row = ClickTarget.item(.row(id: "A", card: "T1"))

    func testTheFirstClickSelectsAtOnceAndASecondOnTheSameItemOpens() {
        var clicks = ClickClassifier()
        XCTAssertEqual(clicks.classify(heading, count: 1), .select(.header(card: "T1")), "no wait for a second click")
        XCTAssertEqual(clicks.classify(heading, count: 2), .open(.header(card: "T1")))
        XCTAssertEqual(clicks.classify(row, count: 1), .select(.row(id: "A", card: "T1")))
        XCTAssertEqual(clicks.classify(row, count: 2), .open(.row(id: "A", card: "T1")))
    }

    func testASeriesStartedElsewhereDoesNothing() {
        var clicks = ClickClassifier()
        _ = clicks.classify(heading, count: 1)
        XCTAssertEqual(clicks.classify(row, count: 2), .nothing, "first on the heading, second on a row")
        _ = clicks.classify(.control("T1|chain"), count: 1)
        XCTAssertEqual(clicks.classify(heading, count: 2), .nothing, "first on a control, second on the heading")
        var fresh = ClickClassifier()
        XCTAssertEqual(fresh.classify(heading, count: 2), .nothing, "a series whose first click was not seen")
    }

    func testAControlActsOncePerSeries() {
        var clicks = ClickClassifier()
        XCTAssertEqual(clicks.classify(.control("T1|chain"), count: 1), .control("T1|chain"))
        XCTAssertEqual(clicks.classify(.control("T1|chain"), count: 2), .nothing, "a double click acts once and opens nothing")
        XCTAssertEqual(clicks.classify(.control("T1|chain"), count: 3), .nothing)
    }

    func testATripleClickOpensOnceAtItsSecondClick() {
        // A click series opens at count 2 only; counts 3 and more do nothing
        // more (no second open).
        var clicks = ClickClassifier()
        XCTAssertEqual(clicks.classify(heading, count: 1), .select(.header(card: "T1")))
        XCTAssertEqual(clicks.classify(heading, count: 2), .open(.header(card: "T1")))
        XCTAssertEqual(clicks.classify(heading, count: 3), .nothing)
        XCTAssertEqual(clicks.classify(heading, count: 4), .nothing)
    }

    func testACountPastTwoWithoutTheSecondOpensNothing() {
        var clicks = ClickClassifier()
        _ = clicks.classify(heading, count: 1)
        XCTAssertEqual(clicks.classify(heading, count: 3), .nothing)
    }
}

final class SelectionTests: XCTestCase {
    let shown = ["R1", "T1", "T2", "T3", "T4", "W1", "D1"]

    func testAClickSelectsOneCardAndCommandClickTogglesIt() {
        var selected = CardSelection()
        selected.only("T2")
        XCTAssertEqual(selected.cards, ["T2"])
        XCTAssertEqual(selected.anchor, "T2")
        XCTAssertFalse(selected.isMultiple)
        selected.toggle("W1")
        XCTAssertEqual(selected.cards, ["T2", "W1"])
        XCTAssertEqual(selected.anchor, "W1", "⌘-click sets the anchor")
        XCTAssertTrue(selected.isMultiple)
        selected.toggle("W1")
        XCTAssertEqual(selected.cards, ["T2"])
        selected.toggle("T2")
        XCTAssertTrue(selected.isEmpty)
        XCTAssertNil(selected.anchor, "nothing selected: no anchor")
    }

    func testShiftClickSelectsTheRangeFromTheAnchor() {
        var selected = CardSelection()
        selected.only("T2")
        selected.range(to: "W1", shown: shown)
        XCTAssertEqual(selected.cards, ["T2", "T3", "T4", "W1"], "across sections")
        XCTAssertEqual(selected.anchor, "T2", "the anchor stays")
        selected.range(to: "R1", shown: shown)
        XCTAssertEqual(selected.cards, ["R1", "T1", "T2"], "the range replaces the selection, upwards too")
        var none = CardSelection()
        none.range(to: "T3", shown: shown)
        XCTAssertEqual(none.cards, ["T3"], "without an anchor: that card alone")
    }

    func testSelectAllAndCardsNoLongerShown() {
        var selected = CardSelection()
        selected.all(shown)
        XCTAssertEqual(selected.cards, Set(shown))
        XCTAssertEqual(selected.anchor, "R1")
        selected.update(shown: ["T1", "T2"])
        XCTAssertEqual(selected.cards, ["T1", "T2"], "cards no longer shown leave the selection")
        XCTAssertNil(selected.anchor, "R1 is no longer shown")
        selected.clear()
        XCTAssertTrue(selected.isEmpty)
    }
}

final class MultiRulesTests: XCTestCase {
    let cards = sampleCards()

    func cards(_ ids: [String]) -> [Card] {
        ids.compactMap { id in cards.first { $0.id == id } }
    }

    func testTheMultiCardMenuOfEachTab() {
        func titles(_ tab: ListTab, _ ids: [String]) -> [String] { MultiRules.menu(tab, cards: cards(ids)).map(\.title) }
        XCTAssertEqual(titles(.all, ["N1", "T1"]), ["Add to Review", "Add to Mine", "Dismiss"])
        XCTAssertEqual(titles(.review, ["T1", "W1"]),
                       ["Move to Inbox", "Move to Doing", "Move to Waiting", "Move to Done", "Remove from Review", "Dismiss"])
        XCTAssertEqual(titles(.review, ["T1", "T2"]), ["Move to Doing", "Move to Waiting", "Move to Done", "Remove from Review", "Dismiss"],
                       "not to the section all of them are in")
        XCTAssertEqual(titles(.mine, ["M1", "M2"]), ["Move to Doing", "Move to Waiting", "Move to Done", "Remove from Mine", "Dismiss"],
                       "Mine as Review")
        XCTAssertEqual(titles(.mine, ["M1", "M3"]),
                       ["Move to Inbox", "Move to Doing", "Move to Waiting", "Move to Done", "Dismiss"], "your own PRs stay in Mine")
    }

    func testCardsAnOperationCannotTakeAreSkipped() {
        let add = MultiRules.plan(.add(.review(.inbox)), cards: cards(["N1", "M1", "T1"]))
        XCTAssertEqual(add.moves.map(\.card), ["N1"])
        XCTAssertEqual(add.skipped, ["M1", "T1"], "your own PR, a placed card")
        let mine = MultiRules.plan(.add(.mine(.inbox)), cards: cards(["N1", "M1"]))
        XCTAssertEqual(mine.moves.first?.target, .mine(.inbox), "Add to Mine: Inbox")
        XCTAssertEqual(mine.moves.map(\.card), ["N1"])
        XCTAssertEqual(mine.skipped, ["M1"])
        let remove = MultiRules.plan(.remove, cards: cards(["M1", "M2"]))
        XCTAssertEqual(remove.moves, [PlaceMove(card: "M2", target: .none, position: .byDefault, verb: .remove)])
        XCTAssertEqual(remove.skipped, ["M1"], "your own PR stays in Mine")
        XCTAssertEqual(MultiRules.plan(.dismiss, cards: cards(["T1", "T2"])).dismiss, ["T1", "T2"])
    }

    func testMovesKeepTheOrderShown() {
        // Doing and Waiting go to the top of Inbox, Done to its end; T1 is
        // there already.
        let plan = MultiRules.plan(.move(.review(.inbox)), cards: cards(["R1", "T1", "W1", "D1"]))
        XCTAssertEqual(plan.moves, [
            PlaceMove(card: "W1", target: .review(.inbox), position: .top, verb: .move),
            PlaceMove(card: "R1", target: .review(.inbox), position: .top, verb: .move),
            PlaceMove(card: "D1", target: .review(.inbox), position: .bottom, verb: .move),
        ], "the last of the top group goes first")
        XCTAssertEqual(plan.unchanged, ["T1"], "taken without a request")
        let after = plan.moves.reduce(cards) { LocalChange.place($1, $0) }
        XCTAssertEqual(Listing.ranked(after.filter { $0.sectionKey == "review|inbox" && !$0.isMuted }).map(\.id),
                       ["R1", "W1", "T1", "T2", "T3", "T4", "T5", "D1"])
        let done = MultiRules.plan(.move(.review(.done)), cards: cards(["T1", "T2", "T3"]))
        XCTAssertEqual(done.moves.map(\.card), ["T3", "T2", "T1"], "into Done the last first: the first shown is the newest")
        let mine = MultiRules.plan(.move(.mine(.done)), cards: cards(["M1", "M2", "T1"]))
        XCTAssertEqual(mine.moves.map(\.card), ["M2", "M1"])
        XCTAssertEqual(mine.skipped, ["T1"], "not in Mine")
        // Mine's Inbox: from its Doing and Waiting at the top, from Done at
        // the bottom, as Review's.
        var more = cards
        more.append(card("MD", authored: true, placement: Placement(tab: .mine, section: .doing)))
        more.append(card("MW", authored: true, placement: Placement(tab: .mine, section: .waiting)))
        let pick = { (ids: [String]) in ids.compactMap { id in more.first { $0.id == id } } }
        let inbox = MultiRules.plan(.move(.mine(.inbox)), cards: pick(["MD", "M1", "MW", "M3"]))
        XCTAssertEqual(inbox.moves, [
            PlaceMove(card: "MW", target: .mine(.inbox), position: .top, verb: .move),
            PlaceMove(card: "MD", target: .mine(.inbox), position: .top, verb: .move),
            PlaceMove(card: "M3", target: .mine(.inbox), position: .bottom, verb: .move),
        ])
        XCTAssertEqual(inbox.unchanged, ["M1"])
        let afterInbox = inbox.moves.reduce(more) { LocalChange.place($1, $0) }
        XCTAssertEqual(Listing.ranked(afterInbox.filter { $0.sectionKey == "mine|inbox" }).map(\.id), ["MD", "MW", "M1", "M2", "M3"])
    }

    func testADropOnAMovingCardMovesOnToTheNextThatStays() {
        let sections = layout(.review, expanded: ["review|inbox"])
        let moving = cards(["T2", "T3"])
        let moves = MultiRules.drop(moving, at: DropTarget(section: "review|inbox", position: .before("T3")), sections: sections, all: cards)
        XCTAssertEqual(moves, [], "T2 and T3 stay where they are: nothing is sent")
        let on = MultiRules.drop(cards(["T1", "T3"]), at: DropTarget(section: "review|inbox", position: .before("T3")), sections: sections, all: cards)
        XCTAssertEqual(on.map(\.card), ["T1", "T3"])
        XCTAssertEqual(on.map(\.position), [.before("T4"), .before("T4")], "the next card that does not move")
        let end = MultiRules.drop(cards(["T1", "T5"]), at: DropTarget(section: "review|inbox", position: .before("T5")), sections: sections, all: cards)
        XCTAssertEqual(end.map(\.position), [.before("T6"), .before("T6")], "the next that stays, a muted card shown too")
        let last = MultiRules.drop(cards(["T1", "T7"]), at: DropTarget(section: "review|inbox", position: .before("T7")), sections: sections, all: cards)
        XCTAssertEqual(last.map(\.position), [.bottom, .bottom], "no card after it: the bottom")
        let top = MultiRules.drop(cards(["T3", "T4"]), at: DropTarget(section: "review|inbox", position: .top), sections: sections, all: cards)
        XCTAssertEqual(top.map(\.card), ["T4", "T3"])
        let after = top.reduce(cards) { LocalChange.place($1, $0) }
        XCTAssertEqual(Listing.ranked(after.filter { $0.sectionKey == "review|inbox" && !$0.isMuted }).map(\.id),
                       ["T3", "T4", "T1", "T2", "T5"], "the order shown is kept")
        let into = MultiRules.drop(cards(["R1", "W1"]), at: DropTarget(section: "review|inbox", position: .before("T2")), sections: sections, all: cards)
        XCTAssertEqual(into.map(\.card), ["R1", "W1"])
        XCTAssertEqual(into.map(\.position), [.before("T2"), .before("T2")])
        let done = MultiRules.drop(cards(["T1", "T2", "D1"]), at: DropTarget(section: "review|done", position: .byDefault), sections: sections, all: cards)
        XCTAssertEqual(done.map(\.card), ["T2", "T1"], "D1 is in Done already")
    }

    func testTheSelectedCardsInTheOrderShown() {
        var selected = CardSelection()
        for id in ["W1", "T5", "R1"] { selected.toggle(id) }
        let sections = layout(.review)
        let tabCards = Listing.cards(cards, tab: .review)
        // The order shown: Waiting (W1), Doing (R1), Inbox (T5).
        XCTAssertEqual(MultiRules.ordered(selected, sections: sections, tabCards: tabCards).map(\.id), ["W1", "R1", "T5"])
    }

    func testOptionArrowsMoveSeveralSelectedCardsTogether() {
        let sections = layout(.review, expanded: ["review|inbox"])
        let inbox = sections.first { $0.key == "review|inbox" }!
        let up = MultiRules.reorder(cards(["T3", "T4"]), up: true, in: inbox, all: cards)
        XCTAssertEqual(up.map(\.card), ["T3", "T4"])
        XCTAssertEqual(up.map(\.position), [.before("T2"), .before("T2")], "past the card above that is not selected")
        let down = MultiRules.reorder(cards(["T3", "T4"]), up: false, in: inbox, all: cards)
        XCTAssertEqual(down.map(\.position), [.before("T6"), .before("T6")], "past the card below")
        XCTAssertEqual(MultiRules.reorder(cards(["T1", "T2"]), up: true, in: inbox, all: cards), [], "at the top already")
        XCTAssertEqual(MultiRules.reorder(cards(["T1", "W1"]), up: false, in: inbox, all: cards).map(\.card), ["T1"],
                       "a card of another section stays")
    }
}

final class SelectionKeyTests: XCTestCase {
    func testSelectionKeysAndEsc() {
        let esc = KeyPress(keyCode: KeyPress.escape)
        let space = KeyPress(keyCode: 49, characters: " ")
        XCTAssertEqual(KeyRules.decide(space, inSearch: false, hasSearchText: false), .pass, "Space does nothing")
        XCTAssertEqual(KeyRules.decide(KeyPress(keyCode: KeyPress.upArrow, modifiers: [.shift]), inSearch: false, hasSearchText: false),
                       .key(.extend(up: true)))
        XCTAssertEqual(KeyRules.decide(KeyPress(keyCode: KeyPress.downArrow, modifiers: [.shift]), inSearch: false, hasSearchText: false),
                       .key(.extend(up: false)))
        let all = KeyPress(characters: "a", modifiers: [.command])
        XCTAssertEqual(KeyRules.decide(all, inSearch: false, hasSearchText: false), .key(.selectAll))
        XCTAssertEqual(KeyRules.decide(all, inSearch: true, hasSearchText: true), .pass, "the field's own select all")
        XCTAssertEqual(KeyRules.decide(esc, inSearch: false, hasSearchText: false, hasSelection: true), .key(.clearSelection))
        XCTAssertEqual(KeyRules.decide(esc, inSearch: false, hasSearchText: false), .pass)
        XCTAssertEqual(KeyRules.decide(esc, inSearch: false, hasSearchText: false, inDismissed: true, hasSelection: true), .key(.back))
        XCTAssertEqual(KeyRules.decide(esc, inSearch: true, hasSearchText: true, hasSelection: true), .leaveSearch(clearing: true))
    }
}

@MainActor
final class SelectedCardsTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var api: FakeAPI!
    var model: AppModel!
    var copier: FakeCopier!

    override func setUp() async throws {
        (defaults, suite) = testDefaults()
        api = FakeAPI()
        copier = FakeCopier()
        model = AppModel(
            api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: FakeNotifier(),
            copier: copier, failureDuration: 0.8, clock: { T0 }
        )
        model.handle(.snapshot(accounts: [sampleAccount()], keychain: .known(.ok), dbUnreadable: false))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func loaded(_ tab: ListTab) async -> SurfaceListModel {
        api.cards = sampleCards()
        let data = model.viewModel("3407303")
        data.reload()
        await settle()
        let list = data.list(.popover)
        list.openTab(tab)
        return list
    }

    func calls(_ prefix: String) -> [String] {
        api.calls.filter { $0.hasPrefix(prefix) }
    }

    func testShiftClickTakesTheShownCardsFromTheAnchor() async {
        let list = await loaded(.review)
        // From the top: Done D1, Waiting W1, Doing R1, Inbox T1–T5; T6 and
        // T7 are folded into "+ 2 more PRs".
        list.click(.item(.header(card: "T4")), count: 1)
        list.click(card: "W1", extent: .range)
        XCTAssertEqual(list.selectedCards.cards, ["W1", "R1", "T1", "T2", "T3", "T4"])
        XCTAssertEqual(list.selection, .header(card: "W1"))
        list.click(card: "T2", extent: .toggle)
        XCTAssertEqual(list.selectedCards.cards, ["W1", "R1", "T1", "T3", "T4"])
        list.click(.item(.row(id: "A", card: "T1")), count: 1)
        XCTAssertEqual(list.selectedCards.cards, ["T1"], "a plain click selects that card alone")
        XCTAssertEqual(list.selection, .row(id: "A", card: "T1"))
    }

    func testShiftArrowsAndSelectAll() async {
        let list = await loaded(.review)
        list.select(.header(card: "T2"))
        list.press(.extend(up: false))
        list.press(.extend(up: false))
        XCTAssertEqual(list.selectedCards.cards, ["T2", "T3", "T4"])
        XCTAssertEqual(list.selection, .header(card: "T4"))
        list.press(.extend(up: true))
        XCTAssertEqual(list.selectedCards.cards, ["T2", "T3"], "back towards the anchor")
        list.press(.selectAll)
        XCTAssertEqual(list.selectedCards.cards, Set(list.shownCards))
        list.press(.clearSelection)
        XCTAssertTrue(list.selectedCards.isEmpty, "Esc")
        XCTAssertNil(list.selection)
    }

    func testDismissTakesEverySelectedCardAndARefusedOneStaysSelected() async {
        let list = await loaded(.review)
        list.select(.header(card: "T3"))
        list.click(card: "T1", extent: .toggle)
        list.click(card: "T2", extent: .toggle)
        api.refuseContaining["example-org/web#230"] = DaemonError(code: .notFound, message: "not found: PR example-org/web#230")
        list.press(.delete)
        XCTAssertEqual(list.sections[3].matching.first?.id, "T4", "shown at once")
        await settle()
        await settle()
        XCTAssertEqual(calls("dismiss"), [
            "dismiss bufferings-work example-org/api#407", "dismiss bufferings-work example-org/web#230",
            "dismiss bufferings-work example-org/docs#88",
        ], "in the order shown, one after another")
        XCTAssertTrue(list.selectedCards.contains("T2"), "the refused card comes back selected")
        XCTAssertEqual(list.data.failure, "Couldn't dismiss: not found: PR example-org/web#230", "one band")
    }

    func testKeysTakeEverySelectedCardAndKeepThemSelected() async {
        let list = await loaded(.review)
        list.select(.header(card: "T1"))
        list.click(card: "D1", extent: .toggle)
        list.press(.moveTo(.doing))
        await settle()
        await settle()
        // In the order shown: Done first.
        XCTAssertEqual(calls("place"), [
            "place bufferings-work acme-corp/infra#58 review doing bottom",
            "place bufferings-work example-org/api#407 review doing bottom",
        ])
        XCTAssertEqual(list.selectedCards.cards, ["T1", "D1"], "the moved cards stay selected")
        api.clearCalls()
        list.select(.header(card: "T2"))
        list.press(.delete)
        await settle()
        await settle()
        XCTAssertEqual(calls("dismiss"), ["dismiss bufferings-work example-org/web#230"], "one card selected: that card")
    }

    func testTheMenuOnASelectedCardActsOnAllAndCopyTakesEveryLink() async {
        let list = await loaded(.review)
        list.select(.header(card: "T1"))
        list.click(card: "T2", extent: .toggle)
        let menu = list.rightClick(.header(card: "T2"))
        XCTAssertEqual(menu.map { $0?.title ?? "-" }, [
            "Copy link", "-", "Move to Doing", "Move to Waiting", "Move to Done", "Remove from Review", "-", "Dismiss", "-", "Mark all as read",
        ])
        XCTAssertEqual(list.selectedCards.cards, ["T1", "T2"], "a right click on a selected card keeps the selection")
        list.press(.copy)
        XCTAssertEqual(copier.copied.last,
                       "https://github.com/p/T1\nhttps://github.com/p/T2", "one link a line")
        let single = list.rightClick(.header(card: "T3"))
        XCTAssertEqual(list.selectedCards.cards, ["T3"], "an unselected card is selected alone first")
        XCTAssertEqual(single.first??.title, "Open on GitHub")
    }

    func testTabsTheDismissedListAndClosingClearSeveralSelectedCards() async {
        let list = await loaded(.review)
        list.select(.header(card: "T1"))
        list.click(card: "T2", extent: .toggle)
        list.openTab(.all)
        XCTAssertFalse(list.multiple, "a tab switch")
        list.click(card: "N1", extent: .toggle)
        list.click(card: "T1", extent: .toggle)
        list.openDismissedList()
        XCTAssertTrue(list.selectedCards.isEmpty, "the Dismissed list")
        list.click(card: "X1", extent: .toggle)
        list.click(card: "X2", extent: .toggle)
        XCTAssertEqual(list.selectedCards.cards, ["X2"], "one card only in the Dismissed list")
        list.closeDismissedList()
        list.click(card: "N1", extent: .toggle)
        list.click(card: "T1", extent: .toggle)
        model.surfaceOpened(.popover, account: "3407303")
        model.surfaceClosed(.popover, account: "3407303")
        XCTAssertFalse(list.multiple, "closing the popover")
    }

    func testACardThatStopsBeingShownLeavesTheSelection() async {
        let list = await loaded(.review)
        list.select(.header(card: "T1"))
        list.click(card: "T2", extent: .toggle)
        list.perform(.dismiss(card: "T1"))
        XCTAssertEqual(list.selectedCards.cards, ["T2"], "dismissed")
        list.perform(.place(PlaceMove(card: "T2", target: .mine(.inbox), position: .byDefault, verb: .move)))
        XCTAssertFalse(list.selectedCards.contains("T2"), "moved to another tab")
    }

    func testDraggingASelectedCardMovesEverySelectedCard() async {
        let list = await loaded(.review)
        list.select(.header(card: "R1"))
        list.click(card: "W1", extent: .toggle)
        list.beginDrag("W1")
        XCTAssertEqual(list.draggingCount, 2)
        XCTAssertTrue(list.drop(.card("T2", lowerHalf: false)))
        // Waiting (W1) shows above Doing (R1).
        XCTAssertEqual(list.sections[3].cards.map(\.id), ["T1", "W1", "R1", "T2", "T3"], "shown at once, in the order shown")
        await settle()
        await settle()
        XCTAssertEqual(calls("place"), [
            "place bufferings-work acme-corp/infra#61 review inbox before example-org/web#230",
            "place bufferings-work example-org/web#212 review inbox before example-org/web#230",
        ])
        XCTAssertEqual(list.selectedCards.cards, ["R1", "W1"], "the moved cards are the selection")
        api.clearCalls()
        list.beginDrag("T3")
        XCTAssertEqual(list.draggingCount, 1, "an unselected card moves alone")
        list.drop(.header("review|inbox"))
        await settle()
        await settle()
        XCTAssertEqual(calls("place"), ["place bufferings-work example-org/docs#88 review inbox top"])
        XCTAssertEqual(list.selectedCards.cards, ["T3"], "the dropped card is the selection")
    }

    func testADropOnMorePRsLandsAfterTheLastShownCardAndOpensTheSection() async {
        let list = await loaded(.review)
        list.data.setFilter(ListFilter(muted: .show), tab: .review)
        // Inbox shows T1–T5; T6 and T7 (muted) are folded.
        list.beginDrag("W1")
        XCTAssertEqual(list.dragOver(.more("review|inbox")), DropTarget(section: "review|inbox", position: .before("T6")))
        XCTAssertTrue(list.drop(.more("review|inbox")))
        XCTAssertEqual(list.sections.first { $0.key == "review|inbox" }?.more, 0, "the section opened")
        XCTAssertEqual(list.selectedCards.cards, ["W1"])
        await settle()
        await settle()
        XCTAssertEqual(calls("place"), ["place bufferings-work acme-corp/infra#61 review inbox before example-org/web#241"])
    }

    func testHoveringOverMorePRsWhileDraggingLeavesTheSectionFolded() async {
        // No spring-loading (DESIGN.md, "Selection"): only a drop opens it.
        let list = await loaded(.review)
        list.data.setFilter(ListFilter(muted: .show), tab: .review)
        list.beginDrag("W1")
        list.dragOver(.more("review|inbox"))
        list.dragOver(.more("review|inbox"))
        list.endDrag()
        XCTAssertEqual(list.sections.first { $0.key == "review|inbox" }?.more, 2)
    }

    /// Mine has Review's sections: the upper half of Inbox's first card is
    /// its top (DESIGN.md, "What a press does").
    func testADropOnTheUpperHalfOfMinesFirstCardGoesToTheTop() async {
        let list = await loaded(.mine)
        XCTAssertEqual(list.sections.map(\.key), ["mine|done", "mine|waiting", "mine|doing", "mine|inbox"])
        XCTAssertEqual(list.sections[3].cards.map(\.id), ["M1", "M2"])
        list.beginDrag("M2")
        XCTAssertEqual(list.dragOver(.card("M1", lowerHalf: false)), DropTarget(section: "mine|inbox", position: .top))
        XCTAssertTrue(list.drop(.card("M1", lowerHalf: false)))
        XCTAssertEqual(list.sections[3].cards.map(\.id), ["M2", "M1"], "shown at once")
        await settle()
        await settle()
        XCTAssertEqual(calls("place"), ["place bufferings-work acme-corp/web#77 mine inbox top"])
    }

    /// A drop on an empty section of Mine (its frame or its heading).
    func testADropOnAnEmptySectionOfMine() async {
        let list = await loaded(.mine)
        list.beginDrag("M2")
        XCTAssertEqual(list.dragOver(.header("mine|doing")), DropTarget(section: "mine|doing", position: .top))
        XCTAssertTrue(list.drop(.header("mine|doing")))
        XCTAssertEqual(list.sections[2].cards.map(\.id), ["M2"], "shown at once")
        await settle()
        await settle()
        XCTAssertEqual(calls("place"), ["place bufferings-work acme-corp/web#77 mine doing top"])
        api.clearCalls()
        list.beginDrag("M1")
        XCTAssertTrue(list.drop(.header("mine|done")))
        await settle()
        await settle()
        XCTAssertEqual(calls("place"), ["place bufferings-work example-org/api#421 mine done"])
    }

    func testOptionUpMovesToTheTopOfMine() async {
        let list = await loaded(.mine)
        list.select(.header(card: "M2"))
        list.press(.reorder(up: true))
        XCTAssertEqual(list.sections[3].cards.map(\.id), ["M2", "M1"])
        await settle()
        await settle()
        XCTAssertEqual(calls("place"), ["place bufferings-work acme-corp/web#77 mine inbox top"])
    }

    /// I / D / W move the selected card in Mine as in Review; in All they
    /// do nothing (DESIGN.md, "Keyboard").
    func testDTWMoveInMineAndDoNothingInAll() async {
        let list = await loaded(.mine)
        list.select(.header(card: "M2"))
        list.press(.moveTo(.doing))
        XCTAssertEqual(list.sections[2].cards.map(\.id), ["M2"])
        XCTAssertEqual(list.selection, .header(card: "M2"), "the moved card stays selected")
        list.press(.moveTo(.inbox))
        XCTAssertEqual(list.sections[3].cards.map(\.id), ["M2", "M1"], "from Doing: the top of Inbox")
        await settle()
        await settle()
        XCTAssertEqual(calls("place"), ["place bufferings-work acme-corp/web#77 mine doing", "place bufferings-work acme-corp/web#77 mine inbox"])
        // Several cards (the fake daemon kept them in Inbox).
        api.clearCalls()
        list.select(.header(card: "M2"))
        list.click(card: "M1", extent: .toggle)
        list.press(.moveTo(.waiting))
        XCTAssertEqual(list.sections[1].cards.map(\.id), ["M1", "M2"], "in the order shown")
        await settle()
        await settle()
        XCTAssertEqual(calls("place").count, 2)
        XCTAssertTrue(calls("place").allSatisfy { $0.hasSuffix("mine waiting bottom") }, "\(calls("place"))")
        // All: nothing.
        api.clearCalls()
        list.openTab(.all)
        list.select(.header(card: "M1"))
        list.press(.moveTo(.doing))
        list.select(.header(card: "T1"))
        list.click(card: "M2", extent: .toggle)
        list.press(.moveTo(.doing))
        await settle()
        await settle()
        XCTAssertEqual(calls("place"), [], "I / D / W do nothing in All")
    }

    func testSelectedCardsDropTogetherAtTheTopOfMine() async {
        let list = await loaded(.mine)
        list.select(.header(card: "M2"))
        list.click(card: "M3", extent: .toggle)
        list.beginDrag("M3")
        XCTAssertEqual(list.draggingCount, 2)
        XCTAssertTrue(list.drop(.card("M1", lowerHalf: false)))
        XCTAssertEqual(list.sections[3].cards.map(\.id), ["M3", "M2", "M1"], "in the order shown: Done's M3 first")
        await settle()
        await settle()
        XCTAssertEqual(calls("place").count, 2)
        XCTAssertTrue(calls("place").allSatisfy { $0.hasSuffix("mine inbox top") }, "\(calls("place"))")
    }

    func testArrowsEnterAndHintsWithSeveralCards() async {
        let list = await loaded(.review)
        list.select(.header(card: "T2"))
        list.press(.extend(up: false))
        list.press(.extend(up: false))
        XCTAssertEqual(list.hints.map(\.text), ["Move", "Reorder", "Move to", "Dismiss", "Clear", "Mark all read", "Search"])
        list.press(.open)
        XCTAssertTrue(calls("open").isEmpty, "⏎ does nothing with several cards")
        list.press(.down)
        XCTAssertEqual(list.selection, .header(card: "T5"), "↑↓ go on from the edge of the selection (T4), alone")
        XCTAssertFalse(list.multiple)
    }

    func testOptionArrowsDoNothingAcrossTwoSections() async {
        let list = await loaded(.review)
        list.select(.header(card: "T2"))
        list.click(card: "W1", extent: .toggle)
        XCTAssertNil(list.reorderSection)
        XCTAssertFalse(list.hints.map(\.text).contains("Reorder"))
        list.press(.reorder(up: true))
        await settle()
        XCTAssertTrue(calls("place").isEmpty)
        list.click(card: "D1", extent: .toggle)
        list.click(card: "W1", extent: .toggle)
        XCTAssertNotNil(list.reorderSection, "a card in Done does not count")
    }

    func testShiftArrowsInTheDismissedListMoveLikeArrows() async {
        let list = await loaded(.review)
        list.openDismissedList()
        list.press(.extend(up: false))
        XCTAssertEqual(list.selection, .header(card: list.dismissedCards.first!.id))
        list.press(.selectAll)
        XCTAssertFalse(list.multiple, "⌘A does nothing there")
    }

    func testADropOnDonesMorePRsDoesNotOpenIt() async {
        let done = (0..<7).map { card("Q\($0)", placement: review(.done, $0), updated: T0 - Int64($0)) }
        api.cards = sampleCards() + done
        let data = model.viewModel("3407303")
        data.reload()
        await settle()
        let list = data.list(.popover)
        list.openTab(.review)
        let key = "review|done"
        XCTAssertGreaterThan(list.sections.first { $0.key == key }?.more ?? 0, 0)
        list.beginDrag("T1")
        XCTAssertTrue(list.drop(.more(key)))
        XCTAssertGreaterThan(list.sections.first { $0.key == key }?.more ?? 0, 0, "Done stays folded")
    }
}
