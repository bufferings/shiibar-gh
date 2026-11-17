// The Filter (DESIGN.md, "Filter", "All", "Review", "Mine", "Section
// size", "What a press does": "Hidden cards and places", "Selection and
// operating on several cards", "How unread clears", "macOS notifications",
// "First run, failure and empty", "Saved state"),
// without a screen. No test waits for the 5 seconds of `Unread only`: the
// clock and the timer are the test's (`FakeLingerClock`).

import Combine
import Foundation
@testable import ShiibarGhCore
import XCTest

// MARK: - The settings and what they hide

final class FilterValueTests: XCTestCase {
    /// One card for each status (Mergeable is Open), muted or not, with a
    /// colored unread row or not (a muted card without one has a gray unread
    /// row: hidden by `Unread only` too).
    func grid() -> [Card] {
        var out: [Card] = []
        let states: [StateLabel] = [.open, .mergeable, .draft, .merged, .closed]
        for (i, state) in states.enumerated() {
            for muted in [false, true] {
                for blue in [false, true] {
                    let id = "\(state.rawValue)-\(muted ? "m" : "n")-\(blue ? "b" : "r")"
                    let pr = "example-org/api#\(i * 10 + (muted ? 2 : 0) + (blue ? 1 : 0))"
                    var rows: [Row] = []
                    if blue {
                        rows.append(row(id + "-row", pr: pr, kind: muted ? .mentioned : .comment, unread: true))
                    } else if muted {
                        rows.append(row(id + "-row", pr: pr, unread: true, muted: true))
                    }
                    out.append(card(id, pr: pr, author: muted ? "example-bot" : "al", state: state, muted: muted ? [.author] : [], rows: rows))
                }
            }
        }
        return out
    }

    /// Every combination of Muted (3), the statuses on (the 15 non-empty
    /// sets) and `Unread only` (2): the cards shown.
    func testEveryCombination() {
        let cards = grid()
        XCTAssertEqual(cards.filter(\.hasBlueUnread).count, 10)
        XCTAssertEqual(cards.filter { $0.isMuted && !$0.hasBlueUnread }.allSatisfy(\.hasGrayUnread), true)
        var combinations = 0
        for muted in MuteChoice.allCases {
            for mask in 1..<16 {
                let statuses = Set(PRStatus.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
                for unreadOnly in [false, true] {
                    let filter = ListFilter(muted: muted, statuses: statuses, unreadOnly: unreadOnly)
                    let shown = Listing.shown(cards, tab: .all, visibility: shows(filter)).map(\.id)
                    let expected = cards.filter { card in
                        let status: PRStatus
                        switch card.stateLabel.value {
                        case .draft?: status = .draft
                        case .merged?: status = .merged
                        case .closed?: status = .closed
                        default: status = .open
                        }
                        let byMute = muted == .show || (muted == .hide ? !card.isMuted : card.isMuted)
                        return byMute && statuses.contains(status) && (!unreadOnly || card.hasBlueUnread)
                    }.map(\.id)
                    XCTAssertEqual(shown, expected, "\(muted) \(statuses.map(\.rawValue).sorted()) unread only \(unreadOnly)")
                    combinations += 1
                }
            }
        }
        XCTAssertEqual(combinations, 90)
    }

    /// The status is the one Group by Status uses.
    func testTheStatusIsGroupByStatus() {
        for card in grid() {
            XCTAssertEqual(Listing.status(card).rawValue, Listing.groupKey(card, .status))
        }
        XCTAssertEqual(Listing.status(card("x", state: .mergeable)), .open)
    }

    func testTheLastStatusOnStaysOn() {
        var filter = ListFilter()
        filter.setStatus(.open, false)
        filter.setStatus(.draft, false)
        filter.setStatus(.merged, false)
        XCTAssertEqual(filter.statuses, [.closed])
        XCTAssertFalse(filter.canTurnOff(.closed))
        filter.setStatus(.closed, false)
        XCTAssertEqual(filter.statuses, [.closed], "pressing the last one does nothing")
        filter.setStatus(.open, true)
        XCTAssertTrue(filter.canTurnOff(.closed))
        XCTAssertEqual(ListFilter(statuses: []).statuses, ListFilter.allStatuses, "never empty")
    }

    /// Statuses, then Mute, then `Unread only`, by ` · `; nothing at the
    /// defaults; Hide is never in it (DESIGN.md, "Filter", "Closed").
    func testTheSummary() {
        XCTAssertNil(ListFilter().summary)
        XCTAssertTrue(ListFilter().isDefault)
        XCTAssertEqual(ListFilter(muted: .show).summary, "Muted shown")
        XCTAssertEqual(ListFilter(muted: .only).summary, "Muted only")
        XCTAssertEqual(ListFilter(unreadOnly: true).summary, "Unread only")
        XCTAssertEqual(ListFilter(statuses: [.draft, .open]).summary, "Open · Draft", "in the order of the statuses")
        XCTAssertEqual(
            ListFilter(muted: .only, statuses: [.closed, .open, .draft], unreadOnly: true).summary,
            "Open · Draft · Closed · Muted only · Unread only"
        )
        XCTAssertEqual(ListFilter(muted: .show, unreadOnly: true).summary, "Muted shown · Unread only")
        XCTAssertFalse(ListFilter(muted: .show).isDefault)
        XCTAssertFalse(ListFilter(statuses: [.open]).isDefault)
        XCTAssertFalse(ListFilter(unreadOnly: true).isDefault)
    }

    func testTheSettingsReadBack() throws {
        let filter = ListFilter(muted: .only, statuses: [.merged, .open], unreadOnly: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(filter)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"muted":"only","statuses":["open","merged"],"unreadOnly":true}"#)
        XCTAssertEqual(try JSONDecoder().decode(ListFilter.self, from: data), filter)
        let odd = Data(#"{"muted":"maybe","statuses":["later"]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ListFilter.self, from: odd), ListFilter(), "unknown values: the defaults")
    }

    /// The tab opened to select a card: only what hides it changes.
    func testRevealingChangesOnlyWhatHidesTheCard() {
        let muted = card("m", muted: [.author], rows: [row("r", pr: "example-org/api#m", unread: true, muted: true)])
        let plain = card("p", state: .merged)
        let custom = ListFilter(muted: .hide, statuses: [.open, .draft], unreadOnly: false)
        XCTAssertEqual(custom.revealing(muted), ListFilter(muted: .show, statuses: [.open, .draft]), "Hide: Show")
        XCTAssertEqual(custom.revealing(plain), ListFilter(muted: .hide, statuses: [.open, .draft, .merged]), "its status on")
        XCTAssertEqual(ListFilter(muted: .only).revealing(plain), ListFilter(muted: .show, statuses: [.open, .draft, .merged, .closed]))
        XCTAssertEqual(ListFilter(muted: .only).revealing(muted), ListFilter(muted: .only), "Only shows a muted card: it stays Only")
        XCTAssertEqual(ListFilter(unreadOnly: true).revealing(plain), ListFilter(), "read: Unread only off")
        XCTAssertEqual(ListFilter(muted: .show, unreadOnly: true).revealing(muted), ListFilter(muted: .show), "gray rows only: hidden by Unread only")
    }
}

// MARK: - The lists the Filter makes

final class FilterListTests: XCTestCase {
    /// The tab's unread count ignores the Filter and the search.
    func testTheUnreadCountsIgnoreTheFilter() {
        let cards = sampleCards()
        XCTAssertEqual(Listing.unreadCount(cards, tab: .review), 2, "T1 and the hidden T7 (a mention)")
        XCTAssertEqual(Listing.unreadCount(cards, tab: .all), 3, "T1, T7 and M1")
        // The function takes no Filter: whatever it hides, the count stays.
        XCTAssertEqual(Listing.shown(cards, tab: .review, visibility: shows(ListFilter(statuses: [.merged]))).count, 1)
    }

    /// The dot: a card the Filter hides has a colored unread row; the search
    /// does not count; only the tab shown.
    func testTheBlueDot() {
        let cards = sampleCards()
        XCTAssertTrue(Listing.filterDot(cards, tab: .review, filter: mutedHidden), "T7's unread mention, hidden by Hide")
        XCTAssertFalse(Listing.filterDot(cards, tab: .review, filter: mutedShown))
        XCTAssertTrue(Listing.filterDot(cards, tab: .review, filter: ListFilter(muted: .show, statuses: [.merged])), "T1, hidden by Status")
        XCTAssertFalse(Listing.filterDot(cards, tab: .review, filter: ListFilter(muted: .show, unreadOnly: true)),
                       "Unread only alone never hides a blue card")
        XCTAssertTrue(Listing.filterDot(cards, tab: .review, filter: ListFilter(muted: .only)), "T1 hidden by Only")
        // Per tab: Mine's M1 is blue, not hidden by Hide.
        XCTAssertFalse(Listing.filterDot(cards, tab: .mine, filter: mutedHidden))
        XCTAssertTrue(Listing.filterDot(cards, tab: .mine, filter: ListFilter(statuses: [.closed])))
        // A gray unread row does not light it: N1 (muted user's row) under Only.
        var gray = cards
        gray[7].rows[0].unread = false
        XCTAssertFalse(Listing.filterDot(gray, tab: .review, filter: mutedHidden), "T6 has a gray unread row only")
        // A dismissed card does not count.
        var dismissed = cards
        dismissed[7].dismissedAt = T0
        XCTAssertFalse(Listing.filterDot(dismissed, tab: .review, filter: mutedHidden))
    }

    /// Headings, "+ N more PRs" and groups count what the Filter shows.
    func testHeadingsFoldsAndGroupsFollowTheFilter() {
        let open = ListFilter(muted: .show, statuses: [.open])
        let todo = layout(.review, filter: open)[1]
        XCTAssertEqual(todo.detail, "7 PRs")
        let merged = layout(.review, filter: ListFilter(muted: .show, statuses: [.merged, .closed]))
        XCTAssertEqual(merged.map(\.detail), ["0 PRs", "0 PRs", "0 PRs", "1 PR"], "the empty sections stay for a drop")
        XCTAssertEqual(merged.map(\.key), ["review|doing", "review|todo", "review|waiting", "review|done"])
        XCTAssertNil(merged[1].foldLine)
        // Mine: Review's four sections, the empty ones kept.
        let mine = layout(.mine, filter: ListFilter(statuses: [.closed]))
        XCTAssertEqual(mine.map(\.key), ["mine|doing", "mine|todo", "mine|waiting", "mine|done"])
        XCTAssertEqual(mine.map(\.matching.count), [0, 0, 0, 1])
        // Unread only: Todo holds T1 alone; the other sections empty.
        let unread = layout(.review, filter: ListFilter(unreadOnly: true))
        XCTAssertEqual(unread.map(\.detail), ["0 PRs", "1 PR", "0 PRs", "0 PRs"])
        // A Filter that leaves no card: no section at all.
        XCTAssertEqual(layout(.review, filter: ListFilter(muted: .hide, statuses: [.closed])).map(\.key), [])
        // All: groups without a card are not shown.
        let all = layout(.all, filter: ListFilter(muted: .only))
        XCTAssertEqual(all.map(\.title), ["example-org/api", "example-org/web"])
        XCTAssertEqual(all.map(\.detail), ["1 PR", "1 PR"])
        // Six cards fold; with the Filter hiding two of them, they do not.
        let six = (0..<6).map { card("F\($0)", placement: review(.todo, $0), rows: $0 < 4 ? [row("f\($0)", pr: "example-org/api#F\($0)", unread: true)] : []) }
        XCTAssertEqual(layout(.review, cards: six, filter: mutedHidden)[1].foldLine, "+ 1 more PR")
        XCTAssertNil(layout(.review, cards: six, filter: ListFilter(unreadOnly: true))[1].foldLine)
    }

    /// An empty tab: its own text only with no search and the default
    /// Filter; else `Nothing matches`.
    func testTheEmptyTexts() {
        let none: [Card] = []
        XCTAssertEqual(Listing.emptyText(loaded: true, tab: .all, cards: none, search: "", visibility: shows(mutedHidden)), EmptyState.all)
        XCTAssertEqual(Listing.emptyText(loaded: true, tab: .all, cards: none, search: "x", visibility: shows(mutedHidden)), EmptyState.nothingMatches,
                       "no card at all, but search text: Nothing matches")
        XCTAssertEqual(Listing.emptyText(loaded: true, tab: .mine, cards: none, search: "", visibility: shows(ListFilter(unreadOnly: true))),
                       EmptyState.nothingMatches)
        XCTAssertEqual(Listing.emptyText(loaded: true, tab: .review, cards: none, search: " ", visibility: shows(mutedHidden)), EmptyState.review,
                       "white space is no search")
        let cards = sampleCards()
        XCTAssertEqual(
            Listing.emptyText(loaded: true, tab: .review, cards: cards, search: "", visibility: shows(ListFilter(statuses: [.closed]))),
            EmptyState.nothingMatches
        )
        XCTAssertNil(Listing.emptyText(loaded: true, tab: .review, cards: cards, search: "", visibility: shows(ListFilter(unreadOnly: true))))
        // Muted Show alone, every card muted… none here: Mine with Only.
        XCTAssertEqual(
            Listing.emptyText(loaded: true, tab: .mine, cards: cards, search: "", visibility: shows(ListFilter(muted: .only))),
            EmptyState.nothingMatches
        )
    }

    /// ⇧R leaves out the rows of the cards the Filter hides.
    func testMarkAllReadLeavesOutWhatTheFilterHides() {
        let cards = sampleCards()
        XCTAssertEqual(Listing.rowsToRead(tab: .review, cards: cards, search: "", visibility: shows(ListFilter(muted: .only))), ["t6", "t7"])
        XCTAssertEqual(Listing.rowsToRead(tab: .review, cards: cards, search: "", visibility: shows(ListFilter(muted: .show, unreadOnly: true))),
                       ["A", "D", "t7"], "T6 has a gray row only")
        XCTAssertEqual(Listing.rowsToRead(tab: .review, cards: cards, search: "", visibility: shows(ListFilter(muted: .show, statuses: [.merged]))), [])
    }

    /// Cards the Filter hides are hidden cards: drops and ⌥↑↓ land among
    /// the cards shown (DESIGN.md, "Hidden cards and places").
    func testHiddenCardsAndPlaces() {
        // Todo: A (open), B (merged, hidden by Status), C, D (draft, hidden), E.
        let cards = [
            card("A", placement: review(.todo, 0)),
            card("B", state: .merged, placement: review(.todo, 1)),
            card("C", placement: review(.todo, 2)),
            card("D", state: .draft, placement: review(.todo, 3)),
            card("E", placement: review(.todo, 4)),
        ]
        let s = layout(.review, cards: cards, filter: ListFilter(statuses: [.open]))
        XCTAssertEqual(s[1].matching.map(\.id), ["A", "C", "E"])
        XCTAssertEqual(CardDrop.target(.card("A", lowerHalf: false), sections: s)?.position, .top, "above B too")
        XCTAssertEqual(CardDrop.target(.card("C", lowerHalf: false), sections: s)?.position, .before("C"), "B stays above")
        XCTAssertEqual(CardDrop.target(.card("C", lowerHalf: true), sections: s)?.position, .before("E"), "D stays above")
        XCTAssertEqual(CardDrop.target(.card("E", lowerHalf: true), sections: s)?.position, .bottom)
        XCTAssertEqual(CardDrop.reorder(cards[2], up: true, refs: s[1].matching)?.position, .top, "⌥↑ past V1")
        XCTAssertEqual(CardDrop.reorder(cards[0], up: false, refs: s[1].matching)?.position, .before("E"))
        // Move to …: `at` by default, in the whole section.
        let plan = MultiRules.plan(.move(.review(.waiting)), cards: [cards[2]])
        XCTAssertEqual(plan.moves.map(\.position), [.bottom])
        let moved = LocalChange.place(PlaceMove(card: "E", target: .review(.todo), position: .before("C"), verb: .move)).apply(cards)
        XCTAssertEqual(Listing.ranked(moved.filter { $0.sectionKey == "review|todo" }).map(\.id), ["A", "B", "E", "C", "D"])
    }

    /// Kept cards (`Unread only`) are shown cards: counted, places.
    func testKeptCardsAreShownCards() {
        let cards = sampleCards()
        let filter = ListFilter(unreadOnly: true)
        let kept = layout(.review, cards: cards, filter: filter, kept: ["T2"])
        XCTAssertEqual(kept[1].matching.map(\.id), ["T1", "T2"])
        XCTAssertEqual(kept[1].detail, "2 PRs")
        XCTAssertEqual(CardDrop.target(.card("T1", lowerHalf: true), sections: kept)?.position, .before("T2"))
        XCTAssertEqual(layout(.review, cards: cards, filter: ListFilter(statuses: [.merged], unreadOnly: true), kept: ["T2"]).flatMap(\.matching).map(\.id), [],
                       "kept only past Unread only: Status still hides it")
    }
}

// MARK: - `Unread only`'s wait, alone

final class UnreadLingerTests: XCTestCase {
    /// Kept while selected (no time yet).
    func held(_ id: String) -> [String: Double?] {
        var out: [String: Double?] = [:]
        out[id] = .some(nil)
        return out
    }

    func cards(read: Set<String> = []) -> [Card] {
        ["U1", "U2", "U3"].enumerated().map { i, id in
            card(id, pr: "example-org/api#\(id)", placement: review(.todo, i),
                 rows: [row(id.lowercased(), pr: "example-org/api#\(id)", unread: !read.contains(id))])
        } + [card("R", pr: "example-org/api#R", placement: review(.todo, 3))]
    }

    func testTheWait() {
        var linger = UnreadLinger(duration: 5)
        let filter = ListFilter(unreadOnly: true)
        XCTAssertFalse(linger.update(cards: cards(), filter: filter, selected: [], now: 0), "first: only what shows is noted")
        XCTAssertTrue(linger.update(cards: cards(read: ["U1"]), filter: filter, selected: ["U1"], now: 1))
        XCTAssertEqual(linger.kept, held("U1"), "selected: held")
        XCTAssertNil(linger.nextDeadline(now: 1))
        linger.update(cards: cards(read: ["U1"]), filter: filter, selected: ["U2"], now: 3)
        XCTAssertEqual(linger.kept, ["U1": 3], "let go at 3: counts from 3, the later one")
        XCTAssertEqual(linger.nextDeadline(now: 3)!, 7.7, accuracy: 1e-9)
        XCTAssertEqual(linger.fading(now: 7.6), [])
        XCTAssertEqual(linger.fading(now: 7.7), ["U1"], "the last 0.3 s")
        XCTAssertEqual(linger.nextDeadline(now: 7.7)!, 8, accuracy: 1e-9)
        XCTAssertEqual(linger.expire(now: 7.9, blocked: false), [])
        XCTAssertEqual(linger.expire(now: 8, blocked: true), [], "a drag or a menu holds it")
        XCTAssertEqual(linger.expire(now: 8, blocked: false), ["U1"])
        XCTAssertEqual(linger.ids, [])
        // Not kept again: it is no longer shown.
        linger.update(cards: cards(read: ["U1"]), filter: filter, selected: ["U1"], now: 9)
        XCTAssertEqual(linger.ids, [])
    }

    func testReadWhileNotSelectedCountsFromTheRead() {
        var linger = UnreadLinger(duration: 5)
        let filter = ListFilter(unreadOnly: true)
        linger.update(cards: cards(), filter: filter, selected: ["U2"], now: 0)
        linger.update(cards: cards(read: ["U1"]), filter: filter, selected: ["U2"], now: 2)
        XCTAssertEqual(linger.kept, ["U1": 2])
        // Selected again, then let go: from the start.
        linger.update(cards: cards(read: ["U1"]), filter: filter, selected: ["U1"], now: 4)
        XCTAssertEqual(linger.kept, held("U1"))
        linger.update(cards: cards(read: ["U1"]), filter: filter, selected: [], now: 6)
        XCTAssertEqual(linger.kept, ["U1": 6])
        // A new colored unread row: an ordinary card again.
        linger.update(cards: cards(), filter: filter, selected: [], now: 7)
        XCTAssertEqual(linger.ids, [])
    }

    func testOffOrResetKeepsNothing() {
        var linger = UnreadLinger(duration: 5)
        linger.update(cards: cards(), filter: ListFilter(), selected: [], now: 0)
        linger.update(cards: cards(read: ["U1"]), filter: ListFilter(), selected: [], now: 1)
        XCTAssertEqual(linger.ids, [], "Unread only off")
        let filter = ListFilter(unreadOnly: true)
        linger.update(cards: cards(), filter: filter, selected: [], now: 2)
        linger.update(cards: cards(read: ["U2"]), filter: filter, selected: [], now: 3)
        XCTAssertEqual(linger.ids, ["U2"])
        linger.reset()
        XCTAssertEqual(linger.ids, [])
        linger.update(cards: cards(read: ["U2", "U3"]), filter: filter, selected: ["U3"], now: 4)
        XCTAssertEqual(linger.ids, [], "after a reset the first update only notes what shows: U3 was read before")
    }
}

// MARK: - The Filter on the surfaces

/// The clock and the timer of `Unread only` (LingerTiming), moved by hand.
@MainActor
final class FakeLingerClock {
    var now: Double = 1000
    private var due: [(at: Double, fire: @MainActor () -> Void)] = []

    var timing: LingerTiming {
        LingerTiming(duration: 5, now: { [unowned self] in self.now }, schedule: { [unowned self] delay, fire in
            MainActor.assumeIsolated { self.due.append((self.now + delay, fire)) }
        })
    }

    /// Moves the time and fires what is due, in order.
    func advance(_ seconds: Double) {
        now += seconds
        while let index = due.indices.filter({ due[$0].at <= now + 1e-9 }).min(by: { due[$0].at < due[$1].at }) {
            let entry = due.remove(at: index)
            entry.fire()
        }
    }
}

@MainActor
final class FilterModelTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var api: FakeAPI!
    var model: AppModel!
    var clock: FakeLingerClock!

    override func setUp() async throws {
        (defaults, suite) = testDefaults()
        api = FakeAPI()
        api.appliesReads = true
        clock = FakeLingerClock()
        model = AppModel(
            api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: FakeNotifier(), copier: FakeCopier(),
            failureDuration: 0.8, clock: { T0 }, linger: clock.timing
        )
        model.handle(.snapshot(accounts: [sampleAccount()], keychain: .known(.ok), dbUnreadable: false))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Todo: U1–U3 with a colored unread row each, R read, G with a gray
    /// unread row only; Doing: K (blue); W1 waiting, read.
    func unreadCards() -> [Card] {
        ["U1", "U2", "U3"].enumerated().map { i, id in
            card(id, pr: "example-org/api#\(i + 1)", author: "al", placement: review(.todo, i),
                 rows: [row(id.lowercased(), pr: "example-org/api#\(i + 1)", actor: "zz", unread: true)])
        } + [
            card("R", pr: "example-org/api#9", placement: review(.todo, 3)),
            card("G", pr: "example-org/api#8", placement: review(.todo, 4),
                 rows: [row("g", pr: "example-org/api#8", actor: "bot", unread: true, muted: true)]),
            card("K", pr: "example-org/web#5", placement: review(.doing, 0), rows: [row("k", pr: "example-org/web#5", unread: true)]),
            card("W1", pr: "acme-corp/infra#61", owner: "o3", placement: review(.waiting, 0)),
        ]
    }

    func loaded(_ tab: ListTab, cards: [Card], surface: Surface = .popover) async -> SurfaceListModel {
        api.cards = cards
        let data = model.viewModel("3407303")
        data.reload()
        await settle()
        let list = data.list(surface)
        // Shown, as the popover or the window is while open.
        model.surfaceDisplayed(surface, account: "3407303", true, opening: true)
        list.openTab(tab)
        return list
    }

    /// Shows a surface of the account (opens it), or hides it.
    func show(_ surface: Surface, _ shown: Bool) {
        model.surfaceDisplayed(surface, account: "3407303", shown, opening: true)
    }

    func ids(_ list: SurfaceListModel) -> [String] {
        list.sections.flatMap { $0.matching.map(\.id) }
    }

    func unreadOnly() async -> SurfaceListModel {
        let list = await loaded(.review, cards: unreadCards())
        list.setUnreadOnly(true)
        XCTAssertEqual(ids(list), ["K", "U1", "U2", "U3"])
        return list
    }

    // MARK: Settings per tab, per account

    func testEachTabHasItsOwnFilterKeptPerAccount() async {
        let list = await loaded(.all, cards: sampleCards())
        list.setMuteChoice(.only)
        XCTAssertEqual(list.data.filter(.all).muted, .only)
        XCTAssertEqual(list.data.filter(.review), ListFilter(), "Review is not changed")
        XCTAssertEqual(list.data.filter(.mine), ListFilter())
        list.openTab(.review)
        XCTAssertNil(list.filter.summary)
        list.toggleStatus(.open)
        XCTAssertEqual(list.filter.statuses, [.draft, .merged, .closed])
        let window = list.data.list(.window)
        window.openTab(.review)
        XCTAssertEqual(window.filter, list.filter, "the popover and the window share it")
        let saved = UIStateStore(defaults: defaults).filters(account: "3407303")
        XCTAssertEqual(saved[.all], ListFilter(muted: .only))
        XCTAssertEqual(saved[.review], ListFilter(statuses: [.draft, .merged, .closed]))
        XCTAssertEqual(UIStateStore(defaults: defaults).filters(account: "583231")[.all], ListFilter(), "another account")
        // Group by and the sort are not in the summary.
        list.data.setGroupBy(.status)
        list.data.setSort(.recentlyAdded)
        list.openTab(.all)
        XCTAssertEqual(list.filter.summary, "Muted only")
    }

    /// DESIGN.md, "Filter", "When open": open or closed is kept per tab,
    /// per account, shared by the popover and the window, and saved;
    /// closed by default. A tab switch shows the destination's state.
    func testOpenOrClosedIsKeptPerTab() async {
        let popover = await loaded(.review, cards: sampleCards())
        let window = popover.data.list(.window)
        window.openTab(.review)
        XCTAssertFalse(popover.filterOpen, "closed at first")
        popover.toggleFilterOpen()
        XCTAssertTrue(popover.filterOpen)
        XCTAssertTrue(window.filterOpen, "the window shows the same tab's state")
        popover.openTab(.all)
        XCTAssertFalse(popover.filterOpen, "All keeps its own state")
        XCTAssertFalse(popover.showsFilterOptions)
        XCTAssertTrue(window.filterOpen, "Review stays open")
        popover.toggleFilterOpen()
        popover.openTab(.mine)
        XCTAssertFalse(popover.filterOpen, "Mine is closed")
        popover.openTab(.review)
        XCTAssertTrue(popover.showsFilterOptions, "back to Review: open")
        XCTAssertEqual(UIStateStore(defaults: defaults).filtersOpen(account: "3407303"), [.all, .review], "saved per tab")
        XCTAssertEqual(UIStateStore(defaults: defaults).filtersOpen(account: "1"), [], "per account")
        popover.openDismissedList()
        XCTAssertTrue(popover.filterOpen, "the Dismissed list leaves it as it is")
        popover.closeDismissedList()
        window.toggleFilterOpen()
        XCTAssertFalse(popover.filterOpen, "closed from the window")
        XCTAssertTrue(popover.data.filterOpen(.all))
    }

    /// DESIGN.md, "Filter", "Filter row": the row always shows, every
    /// setting at its default too, but not with the Dismissed list; the
    /// summary only while a setting of the tab shown differs from its
    /// default, with `Filter` open or closed. `Reset` under the options is
    /// enabled exactly then.
    func testTheSummaryShowsOnlyWhileASettingDiffers() async {
        let list = await loaded(.review, cards: sampleCards())
        XCTAssertTrue(list.showsFilterRow, "all defaults: the row still shows")
        XCTAssertFalse(list.showsFilterSummary, "all defaults: no summary")
        XCTAssertNil(list.filterSummary)
        XCTAssertFalse(list.canResetFilter, "all defaults: Reset disabled")
        list.setMuteChoice(.show)
        XCTAssertTrue(list.showsFilterSummary)
        XCTAssertTrue(list.canResetFilter)
        XCTAssertEqual(list.filterSummary, "Muted shown")
        list.toggleFilterOpen()
        XCTAssertTrue(list.showsFilterOptions)
        XCTAssertEqual(list.filterSummary, "Muted shown", "open too")
        list.toggleStatus(.closed)
        list.setUnreadOnly(true)
        XCTAssertEqual(list.filterSummary, "Open · Draft · Merged · Muted shown · Unread only", "the order of the summary")
        list.openDismissedList()
        XCTAssertFalse(list.showsFilterRow, "not with the Dismissed list")
        XCTAssertFalse(list.showsFilterSummary)
        XCTAssertNil(list.filterSummary)
        list.closeDismissedList()
        XCTAssertTrue(list.showsFilterRow)
        XCTAssertTrue(list.showsFilterSummary)
        list.openTab(.all)
        XCTAssertTrue(list.showsFilterRow)
        XCTAssertFalse(list.showsFilterSummary, "All's settings are the defaults")
        list.openTab(.review)
        list.setMuteChoice(.hide)
        list.toggleStatus(.closed)
        XCTAssertTrue(list.showsFilterSummary)
        list.setUnreadOnly(false)
        XCTAssertFalse(list.showsFilterSummary, "back to the defaults by hand: the summary goes")
        XCTAssertFalse(list.canResetFilter)
        XCTAssertTrue(list.showsFilterRow, "the row stays")
        list.toggleFilterOpen()
        XCTAssertFalse(list.showsFilterSummary, "closed with the defaults: no summary")
        XCTAssertTrue(list.showsFilterRow)
        XCTAssertEqual(ListFilter(muted: .hide).summary, nil, "Hide is the default")
    }

    /// `Reset`: the tab's Status, Muted and Unread only go back to the
    /// defaults. The search text, the other tabs' settings and whether
    /// `Filter` is open stay.
    func testResetReturnsTheTabsSettingsOnly() async {
        let list = await loaded(.review, cards: sampleCards())
        let window = list.data.list(.window)
        list.data.setFilter(ListFilter(muted: .only), tab: .all)
        list.data.setFilter(ListFilter(unreadOnly: true), tab: .mine)
        list.setMuteChoice(.show)
        list.toggleStatus(.merged)
        list.setUnreadOnly(true)
        list.toggleFilterOpen()
        list.setSearch("api")
        list.resetFilter()
        XCTAssertEqual(list.filter, ListFilter())
        XCTAssertFalse(list.showsFilterSummary)
        XCTAssertFalse(list.canResetFilter, "nothing left to reset")
        XCTAssertEqual(list.search, "api", "the search text stays")
        XCTAssertTrue(list.filterOpen, "the options stay open")
        XCTAssertEqual(list.data.filter(.all), ListFilter(muted: .only), "other tabs stay")
        XCTAssertEqual(list.data.filter(.mine), ListFilter(unreadOnly: true))
        XCTAssertEqual(UIStateStore(defaults: defaults).filters(account: "3407303")[.review], ListFilter(), "saved")
        window.openTab(.review)
        XCTAssertEqual(window.filter, ListFilter(), "the window's too")
        // With all defaults there is nothing to reset.
        list.resetFilter()
        XCTAssertEqual(list.filter, ListFilter())
        // In the Dismissed list there is no line and no Reset.
        list.setMuteChoice(.show)
        list.openDismissedList()
        list.resetFilter()
        XCTAssertEqual(list.data.filter(.review), ListFilter(muted: .show), "nothing reset from the Dismissed list")
    }

    /// `Reset` is a change of the settings: the cards `Unread only` kept
    /// hide at once, and a hidden card leaves the selection.
    func testResetDropsTheKeptCardsAtOnce() async {
        let list = await unreadOnly()
        list.toggleStatus(.closed)
        list.select(.row(id: "u1", card: "U1"))
        await settle()
        list.select(.header(card: "U2"))
        await settle()
        XCTAssertEqual(list.lingering, ["U1"], "read, kept for now")
        list.resetFilter()
        XCTAssertEqual(list.lingering, [], "dropped at once")
        XCTAssertEqual(list.filter, ListFilter())
        XCTAssertTrue(ids(list).contains("R"), "the read cards show again")
        XCTAssertEqual(list.selection, .header(card: "U2"), "a card still shown keeps the selection")
        // Under Unread only again: what shows now is what may be kept next.
        list.setUnreadOnly(true)
        XCTAssertFalse(ids(list).contains("U1"))
        assertSelectionConsistent(list)
    }

    /// The accent-colored dot of the tab shown only, whatever the search.
    func testTheDotOfTheTabShown() async {
        let list = await loaded(.review, cards: sampleCards())
        XCTAssertTrue(list.filterDot, "T7's mention, hidden")
        list.setSearch("cargo")
        XCTAssertTrue(list.filterDot, "the search changes nothing")
        list.openTab(.mine)
        XCTAssertFalse(list.filterDot, "Mine hides nothing blue")
        list.openTab(.review)
        list.setMuteChoice(.show)
        XCTAssertFalse(list.filterDot)
    }

    /// The Dismissed list ignores the Filter.
    func testTheDismissedListIgnoresTheFilter() async {
        let list = await loaded(.review, cards: sampleCards())
        list.setMuteChoice(.only)
        list.setUnreadOnly(true)
        list.openDismissedList()
        XCTAssertEqual(list.dismissedCards.map(\.id), ["X2", "X1"])
        XCTAssertNil(list.emptyText)
        list.setSearch("zzz")
        XCTAssertEqual(list.emptyText, EmptyState.nothingMatches)
        XCTAssertEqual(list.rowsToRead, [])
    }

    // MARK: Selection

    func testAChangeOfTheFilterDeselectsWhatItHides() async {
        let list = await loaded(.review, cards: sampleCards())
        list.select(.header(card: "T1"))
        list.click(card: "T2", extent: .toggle)
        list.click(card: "D1", extent: .toggle)
        list.toggleStatus(.merged)
        XCTAssertEqual(list.selectedCards.cards, ["T1", "T2"], "D1 hidden: deselected")
        list.toggleStatus(.merged)
        XCTAssertEqual(list.selectedCards.cards, ["T1", "T2"], "shown again: not selected again")
        list.setMuteChoice(.only)
        XCTAssertEqual(list.selectedCards.cards, [])
        assertSelectionConsistent(list)
    }

    func testAPRThatChangesStatusLeavesTheSelection() async {
        let list = await loaded(.review, cards: sampleCards())
        list.toggleStatus(.merged)
        list.toggleStatus(.closed)
        list.select(.header(card: "T1"))
        list.click(card: "T2", extent: .toggle)
        api.cards = sampleCards().map { card in
            guard card.id == "T2" else { return card }
            var merged = card
            merged.stateLabel = .known(.merged)
            return merged
        }
        list.data.reload()
        await settle()
        XCTAssertEqual(list.selectedCards.cards, ["T1"])
        assertSelectionConsistent(list)
    }

    // MARK: Opening a tab to select a card

    func testANotificationChangesOnlyWhatHidesTheCard() async {
        let list = await loaded(.all, cards: sampleCards())
        list.data.setFilter(ListFilter(muted: .hide, statuses: [.merged], unreadOnly: true), tab: .review)
        model.notificationClicked(type: .single, account: "3407303", url: nil, pr: "example-org/api#402")
        XCTAssertEqual(list.tab, .review)
        XCTAssertEqual(list.filter, ListFilter(muted: .show, statuses: [.open, .merged], unreadOnly: true),
                       "Mute to Show, Open on; T7 has a blue mention: Unread only stays")
        XCTAssertEqual(list.selection, .header(card: "T7"))
        XCTAssertEqual(list.data.filter(.all), ListFilter(), "other tabs stay")
        // Only shows a muted card: it stays Only.
        list.data.setFilter(ListFilter(muted: .only), tab: .review)
        model.notificationClicked(type: .single, account: "3407303", url: nil, pr: "example-org/api#402")
        XCTAssertEqual(list.filter, ListFilter(muted: .only))
        XCTAssertEqual(list.selection, .header(card: "T7"))
        // A read card under Unread only: Unread only goes off.
        list.data.setFilter(ListFilter(unreadOnly: true), tab: .review)
        model.notificationClicked(type: .single, account: "3407303", url: nil, pr: "example-org/web#230")
        XCTAssertEqual(list.filter, ListFilter())
        XCTAssertEqual(list.selection, .header(card: "T2"))
    }

    func testThePlacementTagClearsTheSearchUnfoldsAndChangesWhatHides() async {
        let list = await loaded(.review, cards: sampleCards())
        list.setSearch("nothing")
        list.perform(.toggleSection("review|todo"))
        list.toggleStatus(.open)
        list.openTab(.all)
        list.perform(.showInTab(card: "T5"))
        XCTAssertEqual(list.tab, .review)
        XCTAssertEqual(list.search, "")
        XCTAssertEqual(list.filter, ListFilter(), "Open on again; nothing else changed")
        XCTAssertEqual(list.selection, .header(card: "T5"))
        XCTAssertTrue(list.sections[1].cards.contains { $0.id == "T5" }, "Todo opened")
        assertSelectionConsistent(list)
    }

    // MARK: Saved state

    func testTheFiltersStartFromTheDefaultsAndAreReadBack() {
        // The Show muted of an unreleased development build is not read.
        defaults.set(true, forKey: "v4.showMuted.1")
        let store = UIStateStore(defaults: defaults)
        XCTAssertEqual(store.filters(account: "1"), [.all: ListFilter(), .review: ListFilter(), .mine: ListFilter()])
        XCTAssertEqual(store.filtersOpen(account: "1"), [], "closed")
        // The single open state of an unreleased development build is not
        // read.
        defaults.set(true, forKey: "v4.filterOpen.1")
        XCTAssertEqual(UIStateStore(defaults: defaults).filtersOpen(account: "1"), [])
        var filters = store.filters(account: "1")
        filters[.mine] = ListFilter(statuses: [.draft])
        store.setFilters(filters, account: "1")
        XCTAssertEqual(UIStateStore(defaults: defaults).filters(account: "1")[.mine], ListFilter(statuses: [.draft]))
        XCTAssertEqual(UIStateStore(defaults: defaults).filters(account: "1")[.all], ListFilter())
        XCTAssertEqual(UIStateStore(defaults: defaults).filters(account: "2")[.mine], ListFilter(), "per account")
    }

    // MARK: Unread only: a card that becomes read

    func testASelectedCardThatIsReadStaysUntilFiveSecondsAfterTheSelectionLeaves() async {
        let list = await unreadOnly()
        list.select(.row(id: "u2", card: "U2"))
        await settle()
        XCTAssertEqual(list.lingering, ["U2"], "read, selected: kept")
        XCTAssertEqual(list.selection, .row(id: "u2", card: "U2"), "the selection stays")
        clock.advance(60)
        XCTAssertEqual(ids(list), ["K", "U1", "U2", "U3"], "selected: never hides")
        XCTAssertEqual(list.sections[1].detail, "3 PRs", "counted as shown")
        // ↓ to U3's heading: U2 counts from now.
        list.press(.down)
        XCTAssertEqual(list.selection, .header(card: "U3"))
        clock.advance(4.6)
        XCTAssertEqual(list.fading, [])
        clock.advance(0.1)
        XCTAssertEqual(list.fading, ["U2"], "the last 0.3 s")
        XCTAssertTrue(list.lingering.contains("U2"))
        clock.advance(0.3)
        XCTAssertEqual(list.lingering, [])
        XCTAssertEqual(list.fading, [])
        XCTAssertEqual(ids(list), ["K", "U1", "U3"])
        XCTAssertEqual(list.selection, .header(card: "U3"), "the selection stays where it was")
        assertSelectionConsistent(list)
    }

    func testSelectingAgainStartsOverAndANewUnreadRowEndsIt() async {
        let list = await unreadOnly()
        list.select(.row(id: "u1", card: "U1"))
        await settle()
        list.select(.header(card: "U2"))
        clock.advance(3)
        list.select(.header(card: "U1"))
        clock.advance(10)
        XCTAssertEqual(list.lingering, ["U1"])
        list.select(.header(card: "U2"))
        clock.advance(4)
        XCTAssertEqual(list.lingering, ["U1"], "4 s after it was let go again")
        // A new colored unread row: an ordinary card.
        api.cards = unreadCards()
        list.data.reload()
        await settle()
        XCTAssertEqual(list.lingering, [])
        clock.advance(10)
        XCTAssertTrue(ids(list).contains("U1"))
    }

    /// Kept cards are shown: ⌘A takes them.
    func testKeptCardsAreSelectable() async {
        let list = await unreadOnly()
        list.select(.row(id: "u1", card: "U1"))
        await settle()
        list.select(.header(card: "U2"))
        list.press(.selectAll)
        XCTAssertEqual(list.selectedCards.cards, ["K", "U1", "U2", "U3"])
        list.clearSelection()
        clock.advance(5)
        XCTAssertEqual(list.lingering, [], "time counts on through ⌘A and Esc")
    }

    func testTheWholeTabReadByShiftR() async {
        let list = await unreadOnly()
        list.press(.markAllRead)
        await settle()
        XCTAssertEqual(list.lingering, ["K", "U1", "U2", "U3"])
        XCTAssertNil(list.emptyText)
        clock.advance(5)
        XCTAssertEqual(ids(list), [])
        XCTAssertEqual(list.emptyText, EmptyState.nothingMatches)
    }

    /// Read elsewhere (the other surface, the CLI): kept too, including the
    /// cards the search hides, folded or collapsed ones.
    func testCardsReadElsewhereAreKeptEvenWhenNotInView() async {
        let list = await unreadOnly()
        list.setSearch("api#1")
        list.perform(.toggleSection("review|doing"))
        api.cards = unreadCards().map { card in
            var card = card
            if ["U3", "K"].contains(card.id) { card.rows = card.rows.map { var row = $0; row.unread = false; return row } }
            return card
        }
        list.data.reload()
        await settle()
        XCTAssertEqual(list.lingering, ["U3", "K"], "U3: not matching the search; K: collapsed Doing")
        list.setSearch("")
        XCTAssertTrue(ids(list).contains("U3"), "a search change does not stop the count")
        clock.advance(5)
        XCTAssertEqual(list.lingering, [])
        XCTAssertFalse(ids(list).contains("U3"))
    }

    func testTheOtherSurfaceKeepsItsOwn() async {
        let popover = await unreadOnly()
        let window = popover.data.list(.window)
        show(.window, true)
        window.openTab(.review)
        popover.select(.row(id: "u1", card: "U1"))
        await settle()
        XCTAssertEqual(popover.lingering, ["U1"])
        XCTAssertEqual(window.lingering, ["U1"], "the window showed it too: kept there, not selected")
        clock.advance(5)
        XCTAssertEqual(window.lingering, [])
        XCTAssertEqual(popover.lingering, ["U1"], "selected in the popover")
    }

    func testATabSwitchAFilterChangeTheDismissedListAndClosingHideAtOnce() async {
        let list = await unreadOnly()
        list.select(.row(id: "u1", card: "U1"))
        await settle()
        list.openTab(.mine)
        list.openTab(.review)
        XCTAssertEqual(list.lingering, [])
        XCTAssertFalse(ids(list).contains("U1"), "hidden although it was selected")
        XCTAssertNil(list.selection)
        // A Filter change.
        list.select(.row(id: "u2", card: "U2"))
        await settle()
        XCTAssertEqual(list.lingering, ["U2"])
        list.setMuteChoice(.show)
        XCTAssertEqual(list.lingering, [])
        XCTAssertNil(list.selection, "the hidden card's selection goes")
        // The Dismissed list.
        list.select(.row(id: "u3", card: "U3"))
        await settle()
        XCTAssertEqual(list.lingering, ["U3"])
        list.openDismissedList()
        list.closeDismissedList()
        XCTAssertEqual(list.lingering, [])
        XCTAssertEqual(ids(list), ["K"])
        // Closing the popover.
        list.select(.row(id: "k", card: "K"))
        await settle()
        XCTAssertEqual(list.lingering, ["K"])
        model.surfaceOpened(.popover, account: "3407303")
        model.surfaceClosed(.popover, account: "3407303")
        XCTAssertEqual(list.lingering, [])
        XCTAssertEqual(ids(list), [])
        assertSelectionConsistent(list)
    }

    /// Turned on: a card without a colored unread row does not show, selected
    /// or not.
    func testTurningUnreadOnlyOnHidesTheReadCardsAtOnce() async {
        let list = await loaded(.review, cards: unreadCards())
        list.select(.header(card: "R"))
        list.setUnreadOnly(true)
        XCTAssertFalse(ids(list).contains("R"))
        XCTAssertFalse(ids(list).contains("G"), "a gray unread row only")
        XCTAssertNil(list.selection)
        XCTAssertEqual(list.lingering, [])
    }

    func testADragAndAMenuHoldTheKeptCards() async {
        let list = await unreadOnly()
        list.select(.row(id: "u1", card: "U1"))
        await settle()
        list.select(.header(card: "U3"))
        list.beginDrag("U3")
        clock.advance(10)
        XCTAssertEqual(list.lingering, ["U1"], "not during a drag")
        list.endDrag()
        XCTAssertEqual(list.lingering, [], "the drag ended: hidden")
        // A right-click menu.
        list.select(.row(id: "u2", card: "U2"))
        await settle()
        _ = list.rightClick(.header(card: "U3"))
        list.menuOpened()
        clock.advance(10)
        XCTAssertEqual(list.lingering, ["U2"])
        list.menuClosed()
        XCTAssertEqual(list.lingering, [])
    }

    /// A Mute that turns the last blue row gray keeps the card (Muted Show).
    func testAMuteThatGraysTheRowKeepsTheCard() async {
        let list = await loaded(.review, cards: unreadCards())
        list.setMuteChoice(.show)
        list.setUnreadOnly(true)
        list.perform(.mute(.user, "zz"))
        XCTAssertEqual(list.lingering, ["U1", "U2", "U3"], "their rows are gray now")
        clock.advance(5)
        XCTAssertEqual(ids(list), ["K"])
    }

    // MARK: Stage 3 and 4 findings

    /// A popover or window not shown keeps nothing: a card read while it is
    /// closed (on the other surface, or by the CLI) does not show when it
    /// opens, even within the 5 seconds (DESIGN.md, "Filter").
    func testAClosedSurfaceKeepsNothingAndOpensWithoutTheCardsReadMeanwhile() async {
        let popover = await unreadOnly()
        let window = popover.data.list(.window)
        show(.window, true)
        window.openTab(.review)
        // The popover closed; U1 read in the window.
        model.surfaceOpened(.popover, account: "3407303")
        model.surfaceClosed(.popover, account: "3407303")
        show(.popover, false)
        window.select(.row(id: "u1", card: "U1"))
        await settle()
        XCTAssertEqual(window.lingering, ["U1"], "the window shows it: kept there")
        XCTAssertEqual(popover.lingering, [], "the closed popover keeps nothing")
        window.select(.header(card: "U2"))
        clock.advance(1)
        show(.popover, true)
        XCTAssertFalse(ids(popover).contains("U1"), "opened within the 5 s: not shown")
        XCTAssertTrue(ids(window).contains("U1"), "the window still counts")
        // The reverse: the window closed, U2 read in the popover.
        show(.window, false)
        popover.select(.row(id: "u2", card: "U2"))
        await settle()
        XCTAssertEqual(popover.lingering, ["U2"])
        XCTAssertEqual(window.lingering, [])
        popover.select(.header(card: "U3"))
        show(.window, true)
        window.openTab(.review)
        XCTAssertFalse(ids(window).contains("U2"))
        // Read by the CLI (the list read again) while the popover is closed.
        show(.popover, false)
        api.cards = unreadCards().map { card in
            var card = card
            card.rows = card.rows.map { var row = $0; row.unread = false; return row }
            return card
        }
        popover.data.reload()
        await settle()
        XCTAssertEqual(popover.lingering, [])
        show(.popover, true)
        XCTAssertEqual(ids(popover), [], "nothing read meanwhile shows")
        XCTAssertEqual(window.lingering, ["K", "U3"], "the shown window keeps what it showed (U1 and U2 were read before it opened)")
    }

    /// Group by, Then by and the sort do not stop the count; only the
    /// filtering settings hide kept cards at once.
    func testGroupingAndSortKeepCounting() async {
        let list = await loaded(.all, cards: unreadCards())
        list.setUnreadOnly(true)
        list.select(.row(id: "u1", card: "U1"))
        await settle()
        list.select(.header(card: "U2"))
        list.data.setGroupBy(.status)
        list.data.setThenBy(.owner)
        list.data.setSort(.recentlyAdded)
        XCTAssertEqual(list.lingering, ["U1"])
        clock.advance(4.9)
        XCTAssertEqual(list.lingering, ["U1"])
        clock.advance(0.1)
        XCTAssertEqual(list.lingering, [])
        // A filtering setting: at once.
        list.select(.row(id: "u2", card: "U2"))
        await settle()
        XCTAssertEqual(list.lingering, ["U2"])
        list.toggleStatus(.closed)
        XCTAssertEqual(list.lingering, [])
    }

    /// A notification that opens the tab already shown is not a tab switch.
    func testANotificationToTheTabShownKeepsCounting() async {
        let list = await unreadOnly()
        list.select(.row(id: "u1", card: "U1"))
        await settle()
        list.select(.header(card: "U3"))
        clock.advance(2)
        model.notificationClicked(type: .single, account: "3407303", url: nil, pr: "example-org/api#2")
        XCTAssertEqual(list.selection, .header(card: "U2"))
        XCTAssertEqual(list.lingering, ["U1"], "still kept, still counting")
        clock.advance(3)
        XCTAssertEqual(list.lingering, [])
    }

    /// The scroll position is kept only when a card hides after its wait
    /// (also at the end of a drag or a menu): `lingerHides` is sent then,
    /// not on a tab switch or a Filter change.
    func testOnlyTheTimedHideKeepsThePlace() async {
        let list = await unreadOnly()
        var sent: [Set<String>] = []
        let watch = list.lingerHides.sink { sent.append($0) }
        defer { watch.cancel() }
        list.select(.row(id: "u1", card: "U1"))
        await settle()
        list.setMuteChoice(.show)
        XCTAssertEqual(sent, [], "a Filter change hides at once, nothing kept in place")
        list.select(.row(id: "u2", card: "U2"))
        await settle()
        list.openTab(.mine)
        list.openTab(.review)
        XCTAssertEqual(sent, [], "a tab switch: the same")
        list.select(.row(id: "u3", card: "U3"))
        await settle()
        list.select(.header(card: "K"))
        clock.advance(5)
        XCTAssertEqual(sent, [["U3"]], "after the 5 s")
        list.select(.row(id: "k", card: "K"))
        await settle()
        list.clearSelection()
        list.beginDrag("K")
        clock.advance(6)
        list.endDrag()
        XCTAssertEqual(sent, [["U3"], ["K"]], "at the end of a drag")
    }

    /// While the Dismissed list shows: the search row only, no Filter row,
    /// no options.
    func testTheDismissedListShowsNoFilter() async {
        let list = await loaded(.review, cards: sampleCards())
        list.toggleFilterOpen()
        XCTAssertTrue(list.showsFilterRow)
        XCTAssertTrue(list.showsFilterOptions)
        list.openDismissedList()
        XCTAssertFalse(list.showsFilterRow, "the search row only")
        XCTAssertFalse(list.showsFilterOptions)
        XCTAssertTrue(list.filterOpen, "open is kept")
        list.closeDismissedList()
        XCTAssertTrue(list.showsFilterOptions)
    }

    /// The options are the same three lines in every tab, in the order of
    /// the summary: Status, Muted, Unread; no Group by, Then by or Sort.
    func testTheOptionLinesAreTheSameInEveryTab() async {
        let list = await loaded(.all, cards: sampleCards())
        for tab in ListTab.allCases {
            list.openTab(tab)
            list.toggleFilterOpen()
            XCTAssertTrue(list.showsFilterOptions, "\(tab)")
            XCTAssertEqual(list.filterOptions, [.status, .muted, .unread], "\(tab)")
            XCTAssertEqual(list.filterOptions.map(\.title), ["Status", "Muted", "Unread"], "\(tab)")
        }
        // The summary lists them in the same order.
        list.openTab(.review)
        list.setMuteChoice(.only)
        list.setUnreadOnly(true)
        list.toggleStatus(.closed)
        XCTAssertEqual(list.filter.summary, "Open · Draft · Merged · Muted only · Unread only")
    }

    /// `Grouping…` shows in the Filter row in All only, not while the
    /// Dismissed list shows, and opens the Grouping sheet.
    func testTheGroupingButtonShowsInAllOnly() async {
        let list = await loaded(.review, cards: sampleCards())
        XCTAssertFalse(list.showsGroupingButton, "Review")
        list.openGrouping()
        XCTAssertFalse(list.showsGrouping, "no button, no sheet")
        list.openTab(.mine)
        XCTAssertFalse(list.showsGroupingButton, "Mine")
        list.openTab(.all)
        XCTAssertTrue(list.showsGroupingButton, "All")
        list.toggleFilterOpen()
        XCTAssertTrue(list.showsGroupingButton, "open or closed Filter alike")
        list.openDismissedList()
        XCTAssertFalse(list.showsGroupingButton, "the Dismissed list: no Filter row")
        list.closeDismissedList()
        XCTAssertTrue(list.showsGroupingButton)
        list.openGrouping()
        XCTAssertTrue(list.showsGrouping, "the button opens the sheet")
        list.showsGrouping = false
    }

    /// Sort, now in the Grouping sheet, orders All at once and is kept per
    /// account.
    func testSortFromTheGroupingSheetOrdersAll() async {
        let cards = [
            card("A", pr: "example-org/api#1", added: T0 + 30, updated: T0 + 10),
            card("B", pr: "example-org/api#2", added: T0 + 20, updated: T0 + 30),
            card("C", pr: "example-org/api#3", added: T0 + 10, updated: T0 + 20),
        ]
        let list = await loaded(.all, cards: cards)
        list.data.setGroupBy(.none)
        XCTAssertEqual(list.shownCards, ["B", "C", "A"], "Recently updated: the default")
        list.openGrouping()
        list.data.setSort(.recentlyAdded)
        XCTAssertEqual(list.shownCards, ["A", "B", "C"], "applied at once, the sheet still open")
        XCTAssertTrue(list.showsGrouping)
        XCTAssertEqual(UIStateStore(defaults: defaults).options(account: "3407303").sort, .recentlyAdded)
        XCTAssertNil(list.filter.summary, "not in the Filter's summary")
        list.data.setSort(.recentlyUpdated)
        XCTAssertEqual(list.shownCards, ["B", "C", "A"])
    }

    /// A card folded into "+ N more PRs" is kept too.
    func testAFoldedCardIsKept() async {
        let cards = (0..<7).map { i in
            card("F\(i)", pr: "example-org/api#\(10 + i)", placement: review(.todo, i),
                 rows: [row("f\(i)", pr: "example-org/api#\(10 + i)", unread: true)])
        }
        let list = await loaded(.review, cards: cards)
        list.setUnreadOnly(true)
        let todo = list.sections.first { $0.key == "review|todo" }
        XCTAssertEqual(todo?.more, 2)
        api.cards = cards.map { card in
            guard card.id == "F6" else { return card }
            var read = card
            read.rows[0].unread = false
            return read
        }
        list.data.reload()
        await settle()
        XCTAssertEqual(list.lingering, ["F6"])
        XCTAssertEqual(list.sections.first { $0.key == "review|todo" }?.detail, "7 PRs")
        clock.advance(5)
        XCTAssertEqual(list.sections.first { $0.key == "review|todo" }?.detail, "6 PRs")
    }

    /// The tab's unread count does not follow the search text.
    func testTheUnreadCountIgnoresTheSearch() async {
        let list = await loaded(.review, cards: sampleCards())
        let before = ListTab.allCases.map { list.unreadCount($0) }
        list.setSearch("zzz-nothing")
        XCTAssertEqual(ListTab.allCases.map { list.unreadCount($0) }, before)
        list.setUnreadOnly(true)
        list.setMuteChoice(.only)
        XCTAssertEqual(ListTab.allCases.map { list.unreadCount($0) }, before, "nor the Filter")
    }

    func testTheDotTooltip() {
        XCTAssertEqual(FilterText.dotTip, "Unread pull requests are hidden by the filter")
    }

    /// The development switch of the 5 seconds.
    func testTheWaitSwitch() {
        let key = LingerTiming.environmentKey
        XCTAssertEqual(key, "SHIIBAR_GH_UNREAD_ONLY_SECONDS")
        XCTAssertEqual(LingerTiming.duration(environment: [:]), 5)
        XCTAssertEqual(LingerTiming.duration(environment: [key: "10"]), 10)
        XCTAssertEqual(LingerTiming.duration(environment: [key: "1.5"]), 1.5)
        for bad in ["0", "-3", "abc", "", "inf", "nan"] {
            XCTAssertEqual(LingerTiming.duration(environment: [key: bad]), 5, bad)
        }
        XCTAssertEqual(LingerTiming().duration, 5)
    }
}
