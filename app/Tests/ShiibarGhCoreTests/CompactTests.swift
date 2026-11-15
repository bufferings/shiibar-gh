// Compact (DESIGN.md, "Compact"): the cards of the tabs show their heading
// only; ↑↓ visit headings and the lines that are not rows; nothing hidden is
// read; the value is the account's, kept and shared by the popover and the
// window; the Dismissed list does not change.

import Foundation
@testable import ShiibarGhCore
import XCTest

@MainActor
final class CompactTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var api: FakeAPI!
    var model: AppModel!

    override func setUp() async throws {
        (defaults, suite) = testDefaults()
        api = FakeAPI()
        model = makeModel()
        model.handle(.snapshot(accounts: [sampleAccount()], keychain: .known(.ok), dbUnreadable: false))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func makeModel() -> AppModel {
        AppModel(
            api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: FakeNotifier(),
            copier: FakeCopier(), failureDuration: 0.8, clock: { T0 }
        )
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

    func testOffByDefault() async {
        let list = await loaded(.review)
        XCTAssertFalse(list.compact)
    }

    func testTheStopsAreHeadingsAndTheLinesThatAreNotRows() async {
        let list = await loaded(.review)
        list.data.setShowMuted(true)
        // Off: T1's rows, its "+ N more" and the rest are stops.
        XCTAssertTrue(list.items.contains(.row(id: "A", card: "T1")))
        XCTAssertTrue(list.items.contains(.moreRows(card: "T1")))
        list.toggleCompact()
        XCTAssertTrue(list.compact)
        let items = list.items
        for item in items {
            switch item {
            case .section, .header, .more: break
            default: XCTFail("\(item) is a stop while Compact is on")
            }
        }
        XCTAssertTrue(items.contains(.header(card: "T1")))
        XCTAssertTrue(items.contains(.section("review|todo")))
        XCTAssertTrue(items.contains(.more("review|todo")), "+ N more PRs stays")
        list.toggleCompact()
        XCTAssertTrue(list.items.contains(.row(id: "A", card: "T1")), "off again: the rows are back")
    }

    func testDownGoesFromCardToCardAndReadsNothing() async {
        let list = await loaded(.review)
        list.toggleCompact()
        list.select(.header(card: "T1"))
        list.press(.down)
        XCTAssertEqual(list.selection, .header(card: "T2"))
        list.press(.up)
        list.press(.up)
        XCTAssertEqual(list.selection, .section("review|todo"))
        await settle()
        XCTAssertEqual(calls("read"), [], "the hidden rows stay unread")
    }

    func testTurningItOnMovesASelectedRowToItsCardsHeading() async {
        let list = await loaded(.review)
        list.select(.row(id: "B", card: "T1"))
        list.toggleCompact()
        XCTAssertEqual(list.selection, .header(card: "T1"))
        list.toggleCompact()
        list.select(.moreRows(card: "T1"))
        list.toggleCompact()
        XCTAssertEqual(list.selection, .header(card: "T1"), "+ N more of a card goes too")
    }

    func testTheOtherSurfacesSelectionMovesToo() async {
        let list = await loaded(.review)
        let window = list.data.list(.window)
        window.openTab(.review)
        window.select(.row(id: "C", card: "T1"))
        list.toggleCompact()
        XCTAssertEqual(window.selection, .header(card: "T1"))
        XCTAssertTrue(window.compact, "the popover and the window share it")
    }

    func testItIsKeptPerAccount() async {
        let list = await loaded(.all)
        list.toggleCompact()
        XCTAssertTrue(UIStateStore(defaults: defaults).compact(account: "3407303"))
        XCTAssertFalse(UIStateStore(defaults: defaults).compact(account: "other"))
        // A new model reads it back.
        let again = makeModel()
        again.handle(.snapshot(accounts: [sampleAccount()], keychain: .known(.ok), dbUnreadable: false))
        XCTAssertTrue(again.viewModel("3407303").compact)
    }

    func testTheDismissedListDoesNotChange() async {
        let list = await loaded(.review)
        list.openDismissedList()
        let off = list.items
        list.toggleCompact()
        XCTAssertEqual(list.items, off)
        XCTAssertEqual(list.view.isDismissed, true)
        XCTAssertFalse(list.view.compact, "the Dismissed list's view is not compact")
    }

    func testCountsSearchAndShiftRStayTheSame() async {
        let list = await loaded(.review)
        let unread = list.unreadCount(.review)
        let toRead = list.rowsToRead
        list.setSearch("retry")
        let found = list.shownCards
        list.setSearch("")
        list.toggleCompact()
        XCTAssertEqual(list.unreadCount(.review), unread)
        XCTAssertEqual(list.rowsToRead, toRead)
        list.setSearch("retry")
        XCTAssertEqual(list.shownCards, found, "a row's body still matches")
    }

    func testTheHeadingMarkFollowsTheUnreadRows() {
        let blue = sampleCards().first { $0.id == "T1" }!
        let gray = sampleCards().first { $0.id == "N1" }!
        let none = sampleCards().first { $0.id == "T2" }!
        XCTAssertEqual(UnreadMark.of(blue.rows), .blue)
        XCTAssertEqual(UnreadMark.of(gray.rows), .ring, "only muted rows unread: the gray ring")
        XCTAssertEqual(UnreadMark.of(none.rows), .none)
    }
}
