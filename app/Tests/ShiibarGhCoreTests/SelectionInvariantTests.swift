// The selected item and the selected cards agree (DESIGN.md, "Selection and
// operating on several cards"): revealing a card selects it alone, a drop
// under a section's last card does not open the section, a press that
// becomes a drag reads no row; and a few rules without a screen.

import Foundation
@testable import ShiibarGhCore
import XCTest

/// The selected item's card is one of the selected cards; with one card
/// selected, it is that card.
@MainActor
func assertSelectionConsistent(_ list: SurfaceListModel, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let card = list.selection?.owningCard else { return }
    XCTAssertTrue(list.selectedCards.contains(card), "the item's card \(card) is not selected \(message)", file: file, line: line)
    if !list.multiple {
        XCTAssertEqual(list.selectedCards.cards, [card], "one card: the item's \(message)", file: file, line: line)
    }
}

@MainActor
final class SelectionInvariantTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var api: FakeAPI!
    var model: AppModel!

    override func setUp() async throws {
        (defaults, suite) = testDefaults()
        api = FakeAPI()
        model = AppModel(
            api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: FakeNotifier(),
            copier: FakeCopier(), failureDuration: 0.8, clock: { T0 }
        )
        model.handle(.snapshot(accounts: [sampleAccount()], keychain: .known(.ok), dbUnreadable: false))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func loaded(_ tab: ListTab, cards: [Card] = sampleCards()) async -> SurfaceListModel {
        api.cards = cards
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

    // MARK: Revealing a card

    func testThePlacementTagSelectsTheCardAloneInItsTab() async {
        // All: T1 selected, then W1's tag `Review · Waiting`.
        let list = await loaded(.all)
        list.select(.header(card: "T1"))
        list.perform(.showInTab(card: "W1"))
        XCTAssertEqual(list.tab, .review)
        XCTAssertEqual(list.selection, .header(card: "W1"))
        XCTAssertEqual(list.selectedCards.cards, ["W1"])
        XCTAssertEqual(list.selectedCards.anchor, "W1")
        assertSelectionConsistent(list)
        list.press(.moveTo(.doing))
        assertSelectionConsistent(list, "after D")
        XCTAssertEqual(list.selectedCards.cards, ["W1"])
        await settle()
        api.clearCalls()
        list.press(.delete)
        await settle()
        XCTAssertEqual(calls("dismiss"), ["dismiss bufferings-work acme-corp/infra#61"], "W1 only")
    }

    func testANotificationInTheSameTabReplacesSeveralSelectedCards() async {
        let list = await loaded(.review)
        list.select(.header(card: "T1"))
        list.click(card: "T2", extent: .toggle)
        XCTAssertTrue(list.multiple)
        list.reveal(pr: "example-org/web#219")
        XCTAssertEqual(list.selection, .header(card: "T5"))
        XCTAssertEqual(list.selectedCards.cards, ["T5"])
        XCTAssertEqual(list.selectedCards.anchor, "T5")
        assertSelectionConsistent(list)
        api.clearCalls()
        list.press(.delete)
        await settle()
        XCTAssertEqual(calls("dismiss"), ["dismiss bufferings-work example-org/web#219"], "T5 only")
    }

    func testEverySelectionChangeKeepsTheItemAndTheCardsTogether() async {
        let list = await loaded(.review)
        list.select(.row(id: "A", card: "T1"))
        assertSelectionConsistent(list, "a row")
        list.click(card: "T3", extent: .toggle)
        assertSelectionConsistent(list, "⌘-click")
        list.click(card: "T3", extent: .toggle)
        assertSelectionConsistent(list, "⌘-click off")
        list.click(card: "W1", extent: .range)
        assertSelectionConsistent(list, "⇧-click")
        list.press(.selectAll)
        assertSelectionConsistent(list, "⌘A")
        list.press(.down)
        assertSelectionConsistent(list, "↓")
        list.press(.extend(up: false))
        assertSelectionConsistent(list, "⇧↓")
        list.perform(.expandRows(card: "T1"))
        assertSelectionConsistent(list, "+ N more")
        list.select(.lessRows(card: "T1"))
        list.perform(.collapseRows(card: "T1"))
        assertSelectionConsistent(list, "Show less")
        list.toggleCompact()
        assertSelectionConsistent(list, "Compact")
        list.reveal(pr: "acme-corp/infra#58")
        assertSelectionConsistent(list, "reveal")
        list.beginDrag("T2")
        list.drop(.card("T4", lowerHalf: true))
        assertSelectionConsistent(list, "drop")
        list.openTab(.all)
        assertSelectionConsistent(list, "tab")
    }

    // MARK: A drop under a section's last card

    func testADropUnderTheLastCardOfASectionWithoutMorePRsDoesNotOpenIt() async {
        // Todo with three cards: no "+ N more PRs" line. A release in the gap
        // under T3 comes as the section's last line.
        let cards = sampleCards().filter { !["T4", "T5", "T6", "T7"].contains($0.id) }
        let list = await loaded(.review, cards: cards)
        let todo = list.sections.first { $0.key == "review|todo" }
        XCTAssertEqual(todo?.more, 0)
        list.beginDrag("W1")
        XCTAssertTrue(list.drop(.more("review|todo")))
        XCTAssertFalse(UIStateStore(defaults: defaults).expanded(account: "3407303").contains("review|todo"), "not kept as expanded")
        XCTAssertFalse(list.data.expanded.contains("review|todo"))
        await settle()
        XCTAssertEqual(calls("place"), ["place bufferings-work acme-corp/infra#61 review todo bottom"])
    }

    // MARK: A press (CardPress)

    func testAPressOnARowThatMayBecomeADragReadsItOnRelease() async {
        let list = await loaded(.review)
        list.pressDown(.row(id: "A", card: "T1"), count: 1, draggable: true)
        XCTAssertEqual(list.selection, .row(id: "A", card: "T1"), "selected at once")
        await settle()
        XCTAssertEqual(calls("read"), [], "not read while the press may become a drag")
        list.pressUp()
        await settle()
        XCTAssertEqual(calls("read"), ["read A"])
    }

    func testAPressThatBecomesADragReadsNothing() async {
        let list = await loaded(.review)
        list.pressDown(.row(id: "A", card: "T1"), count: 1, draggable: true)
        list.beginDrag("T1")
        list.drop(.header("review|waiting"))
        list.pressUp()
        await settle()
        XCTAssertEqual(calls("read"), [])
    }

    func testAPlainClickWhereNoDragCanStartReadsAtOnce() async {
        let list = await loaded(.all)
        list.pressDown(.row(id: "A", card: "T1"), count: 1, draggable: false)
        await settle()
        XCTAssertEqual(calls("read"), ["read A"])
        list.pressUp()
        await settle()
        XCTAssertEqual(calls("read"), ["read A"], "once")
    }

    func testAPressOnOneOfSeveralSelectedCardsSelectsItAloneOnRelease() async {
        let list = await loaded(.review)
        list.select(.header(card: "T1"))
        list.click(card: "T2", extent: .toggle)
        list.pressDown(.header(card: "T1"), count: 1, draggable: true)
        XCTAssertEqual(list.selectedCards.cards, ["T1", "T2"], "kept while the press may drag them all")
        list.pressUp()
        XCTAssertEqual(list.selectedCards.cards, ["T1"], "released without a drag: T1 alone")
        assertSelectionConsistent(list)
    }

    func testAPressOnOneOfSeveralSelectedCardsThatDragsKeepsThemAll() async {
        let list = await loaded(.review)
        list.select(.header(card: "T1"))
        list.click(card: "T2", extent: .toggle)
        list.pressDown(.header(card: "T1"), count: 1, draggable: true)
        list.beginDrag("T1")
        XCTAssertEqual(list.draggingCount, 2)
        list.endDrag()
        list.pressUp()
        XCTAssertEqual(list.selectedCards.cards, ["T1", "T2"])
    }

    func testCardPressRules() {
        var press = CardPress()
        let row = SelectionItem.row(id: "A", card: "T1")
        XCTAssertEqual(press.down(row, count: 1, severalSelected: false, cardSelected: false, draggable: false), .click(readsRow: true))
        XCTAssertNil(press.up())
        XCTAssertEqual(press.down(row, count: 1, severalSelected: false, cardSelected: false, draggable: true), .click(readsRow: false))
        XCTAssertEqual(press.up(), .read(row))
        XCTAssertNil(press.up(), "once")
        XCTAssertEqual(press.down(row, count: 1, severalSelected: true, cardSelected: true, draggable: true), .nothing)
        press.dragStarted()
        XCTAssertNil(press.up(), "a drag: nothing on release")
        XCTAssertEqual(press.down(row, count: 1, severalSelected: true, cardSelected: false, draggable: true), .click(readsRow: false),
                       "a card not among the selected: selected at once")
        XCTAssertEqual(press.down(row, count: 2, severalSelected: true, cardSelected: true, draggable: true), .click(readsRow: true),
                       "a double click as it is")
        XCTAssertNil(press.up())
    }

    // MARK: A drag in All

    func testADragInAllShowsTheHintAndMovesNothing() async {
        let list = await loaded(.all)
        list.pressDown(.header(card: "T2"), count: 1, draggable: false)
        XCTAssertEqual(list.dragStart(card: "T2"), .hint("All is sorted automatically. Reorder in Review or Mine."))
        XCTAssertNil(list.dragging, "nothing lifts")
        list.pressUp()
        XCTAssertEqual(list.selectedCards.cards, ["T2"], "the press's own selection only")
        await settle()
        XCTAssertEqual(calls("place"), [])
    }

    func testReviewAndMineDragTheDismissedListDoesNothing() async {
        let list = await loaded(.review)
        XCTAssertEqual(list.dragStart(card: "T2"), .drag)
        list.openTab(.mine)
        XCTAssertEqual(list.dragStart(card: "M1"), .drag)
        list.openDismissedList()
        XCTAssertEqual(list.dragStart(card: "X1"), .nothing, "no hint in the Dismissed list")
    }

    // MARK: Cards leaving the selection

    func testClearingTheSearchDoesNotGiveBackWhatItTookOut() async {
        let list = await loaded(.review)
        list.select(.header(card: "T1"))
        list.click(card: "T2", extent: .toggle)
        list.click(card: "T3", extent: .toggle)
        list.setSearch("retry")
        XCTAssertEqual(list.selectedCards.cards, ["T1"], "T2 and T3 no longer shown")
        list.setSearch("")
        XCTAssertEqual(list.selectedCards.cards, ["T1"])
        assertSelectionConsistent(list)
    }

    func testMutedHideTakesTheMutedCardsOut() async {
        let list = await loaded(.review)
        list.data.setFilter(ListFilter(muted: .show), tab: .review)
        list.perform(.toggleMore("review|todo"))
        list.select(.header(card: "T1"))
        list.click(card: "T6", extent: .toggle)
        XCTAssertEqual(list.selectedCards.cards, ["T1", "T6"])
        list.data.setFilter(ListFilter(), tab: .review)
        XCTAssertEqual(list.selectedCards.cards, ["T1"])
        assertSelectionConsistent(list)
    }

    func testFoldingTakesTheHiddenCardsOut() async {
        let list = await loaded(.review)
        list.data.setFilter(ListFilter(muted: .show), tab: .review)
        list.perform(.toggleMore("review|todo"))
        list.select(.header(card: "T1"))
        list.click(card: "T7", extent: .toggle)
        list.perform(.toggleMore("review|todo"))
        XCTAssertEqual(list.selectedCards.cards, ["T1"], "Show less: T7 folded again")
        list.click(card: "W1", extent: .toggle)
        list.perform(.toggleSection("review|todo"))
        XCTAssertEqual(list.selectedCards.cards, ["W1"], "Todo collapsed: T1 hidden")
        assertSelectionConsistent(list)
    }

    func testACardMutedWhileTheFilterHidesMutedCardsLeavesTheSelection() async {
        let list = await loaded(.review)
        list.select(.header(card: "T1"))
        list.click(card: "T2", extent: .toggle)
        api.cards = sampleCards().map { card in
            guard card.id == "T2" else { return card }
            var muted = card
            muted.muted = [Lenient(.pr)]
            return muted
        }
        list.data.reload()
        await settle()
        XCTAssertEqual(list.selectedCards.cards, ["T1"])
        assertSelectionConsistent(list)
    }

    func testACardThatGoesAwayLeavesTheSelection() async {
        // An owner turned off, or a PR that can no longer be read: the
        // card is no longer in the list.
        let list = await loaded(.review)
        list.select(.header(card: "T1"))
        list.click(card: "T2", extent: .toggle)
        api.cards = sampleCards().filter { $0.id != "T2" }
        list.data.reload()
        await settle()
        XCTAssertEqual(list.selectedCards.cards, ["T1"])
        assertSelectionConsistent(list)
    }

    func testTheDismissedListSelectsOneCard() async {
        let list = await loaded(.review)
        list.openDismissedList()
        list.select(.header(card: "X1"))
        list.click(card: "X2", extent: .toggle)
        XCTAssertEqual(list.selectedCards.cards, ["X2"], "⌘-click is a plain click there")
        XCTAssertEqual(list.selection, .header(card: "X2"))
        list.click(card: "X1", extent: .range)
        XCTAssertEqual(list.selectedCards.cards, ["X1"], "⇧-click too")
        list.press(.selectAll)
        XCTAssertEqual(list.selectedCards.cards, ["X1"], "⌘A does nothing")
        assertSelectionConsistent(list)
    }

    // MARK: Rules without a screen

    func testThePopoverHeightIsKeptPerAccount() {
        let store = UIStateStore(defaults: defaults)
        XCTAssertNil(store.popoverHeight(account: "3407303"), "nothing until dragged: the default height")
        store.setPopoverHeight(712, account: "3407303")
        XCTAssertEqual(UIStateStore(defaults: defaults).popoverHeight(account: "3407303"), 712)
        XCTAssertNil(store.popoverHeight(account: "other"))
    }

    func testATabWhoseCardsAreAllMutedIsEmptyWithTheDefaultFilter() {
        let cards = sampleCards().filter { ["T6", "T7"].contains($0.id) }
        XCTAssertEqual(Listing.emptyText(loaded: true, tab: .review, cards: cards, search: "", visibility: shows(mutedHidden)), EmptyState.review)
        XCTAssertNil(Listing.emptyText(loaded: true, tab: .review, cards: cards, search: "", visibility: shows(mutedShown)))
    }

    func testADropWhereOnlySomeCardsMoveSendsEveryRequest() {
        let cards = sampleCards()
        let sections = layout(.review, expanded: ["review|todo"])
        // T2 is right before T3 already; W1 comes from Waiting.
        let moving = cards.filter { ["T2", "W1"].contains($0.id) }
        let moves = MultiRules.drop(moving, at: DropTarget(section: "review|todo", position: .before("T3")), sections: sections, all: cards)
        XCTAssertEqual(moves.map(\.card), ["T2", "W1"], "the whole drop changes the order: both are sent")
        XCTAssertEqual(moves.map(\.position), [.before("T3"), .before("T3")])
    }
}
