// The lists of the popover worked out without a screen: tabs, sections,
// groups, "+ N more PRs", the Dismissed list, the selection, the keys and
// their hints, the menus, and moving cards (DESIGN.md, "Tabs" to "Selection
// and keys").

import Foundation
@testable import ShiibarGhCore
import XCTest

final class SearchTests: XCTestCase {
    /// The example table of DESIGN.md, "What the filters mean", shared with
    /// the daemon's `search_follows_the_examples_of_the_design`.
    func testTheDesignExamples() {
        let card = sampleCards()[1]
        XCTAssertEqual(card.pr, "example-org/api#407")
        for text in ["api 407", "#407", "api #407", "API", "example-org/api#407"] {
            XCTAssertTrue(Search.matches(card, words: Search.words(text)), text)
        }
        XCTAssertFalse(Search.matches(card, words: Search.words("api #408")))
    }

    func testEveryWordMatchesSomeField() {
        let card = sampleCards()[1]
        XCTAssertTrue(Search.matches(card, words: Search.words("al retry")), "author and a row's text")
        XCTAssertTrue(Search.matches(card, words: Search.words("rk")), "a row's actor")
        XCTAssertFalse(Search.matches(card, words: Search.words("al nothing")))
        XCTAssertEqual(Search.words("  A\u{3000}b\n"), ["a", "b"], "Unicode white space splits")
    }
}

final class OptionsTests: XCTestCase {
    func testGroupByStartsAtRepositoryAndTheTwoLevelsDiffer() {
        var options = ListOptions()
        XCTAssertEqual(options.groupBy, .repository)
        XCTAssertEqual(options.thenBy, .none)
        XCTAssertEqual(options.thenByTitle, "Then by")
        options.setThenBy(.status)
        XCTAssertEqual(options.thenBy, .status)
        XCTAssertEqual(options.thenByTitle, "Status")
        XCTAssertEqual(options.thenByChoices, [.owner, .status, .involvement, .none], "Group by's value is not offered")
        options.setGroupBy(.status)
        XCTAssertEqual(options.thenBy, .none, "Then by's value chosen in Group by turns Then by to None")
        options.setThenBy(.status)
        XCTAssertEqual(options.thenBy, .none, "the same value is refused")
        options.setThenBy(.owner)
        options.setGroupBy(.none)
        XCTAssertEqual(options.thenBy, .none, "Group by None turns Then by off")
        options.setThenBy(.owner)
        XCTAssertEqual(options.thenBy, .none)
    }

    func testOptionsRoundTripAndBadValuesFallBack() throws {
        let options = ListOptions(groupBy: .owner, thenBy: .involvement, sort: .recentlyAdded)
        let data = try JSONEncoder().encode(options)
        XCTAssertEqual(try JSONDecoder().decode(ListOptions.self, from: data), options)
        let odd = try JSONDecoder().decode(ListOptions.self, from: Data(#"{"groupBy":"owner","thenBy":"owner","sort":"x"}"#.utf8))
        XCTAssertEqual(odd, ListOptions(groupBy: .owner))
        XCTAssertEqual(try JSONDecoder().decode(ListOptions.self, from: Data("{}".utf8)), ListOptions())
    }
}

final class TabTests: XCTestCase {
    func testTheCardsOfEachTabLeaveTheDismissedOut() {
        let cards = sampleCards()
        XCTAssertEqual(Listing.cards(cards, tab: .all).count, 14)
        XCTAssertEqual(Listing.cards(cards, tab: .review).map(\.id), ["R1", "T1", "T2", "T3", "T4", "T5", "T6", "T7", "W1", "D1"])
        XCTAssertEqual(Listing.cards(cards, tab: .mine).map(\.id), ["M1", "M2", "M3"])
        XCTAssertEqual(Listing.dismissed(cards).map(\.id), ["X2", "X1"], "newest dismissal first")
    }

    /// Cards with a blue unread row; a gray muted row does not count, a
    /// mention in a muted card does (DESIGN.md, "Tabs").
    func testUnreadCountsCountCardsWithABlueRow() {
        let cards = sampleCards()
        XCTAssertEqual(Listing.unreadCount(cards, tab: .all), 3, "T1, T7 and M1; not T6 or N1")
        XCTAssertEqual(Listing.unreadCount(cards, tab: .review), 2)
        XCTAssertEqual(Listing.unreadCount(cards, tab: .mine), 1)
        XCTAssertEqual(Listing.unreadCount([], tab: .all), 0)
    }

    func testThePlacementTag() {
        let cards = sampleCards()
        let tags = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.placementTag ?? "-") })
        XCTAssertEqual(tags["R1"], "Review · Doing")
        XCTAssertEqual(tags["T1"], "Review · Todo")
        XCTAssertEqual(tags["W1"], "Review · Waiting")
        XCTAssertEqual(tags["D1"], "Review · Done")
        XCTAssertEqual(tags["M1"], "Mine")
        XCTAssertEqual(tags["M3"], "Mine · Done")
        XCTAssertEqual(tags["N1"], "-")
    }

    func testEmptyTexts() {
        XCTAssertNil(Listing.emptyText(loaded: false, tab: .all, cards: [], search: ""))
        XCTAssertEqual(Listing.emptyText(loaded: true, tab: .all, cards: [], search: ""), "No pull requests")
        XCTAssertEqual(Listing.emptyText(loaded: true, tab: .review, cards: [], search: ""), "No pull requests to review")
        XCTAssertEqual(Listing.emptyText(loaded: true, tab: .mine, cards: [], search: ""), "No pull requests of yours")
        XCTAssertEqual(Listing.emptyText(loaded: true, tab: nil, cards: [], search: ""), "No dismissed pull requests")
        XCTAssertEqual(Listing.emptyText(loaded: true, tab: .review, cards: sampleCards(), search: "retry timeout"), "Nothing matches")
        XCTAssertEqual(Listing.emptyText(loaded: true, tab: nil, cards: sampleCards(), search: "zzz"), "Nothing matches")
        XCTAssertNil(Listing.emptyText(loaded: true, tab: .review, cards: sampleCards(), search: "retry"))
    }
}

final class SectionTests: XCTestCase {
    /// Empty sections, Done included, stay as places to drop a card; not
    /// while searching or while the tab has no card (DESIGN.md, "Review"
    /// and "Mine").
    func testReviewKeepsItsEmptySectionsAsDropPlaces() {
        let one = sampleCards().filter { $0.id == "T1" }
        let sections = layout(.review, cards: one)
        XCTAssertEqual(sections.map(\.title), ["Doing", "Todo", "Waiting", "Done"])
        XCTAssertEqual(sections.map(\.detail), ["0 PRs", "1 PR", "0 PRs", "0 PRs"])
        XCTAssertEqual(
            CardDrop.target(.header("review|doing"), sections: sections),
            DropTarget(section: "review|doing", position: .bottom)
        )
        XCTAssertEqual(
            CardDrop.target(.header("review|done"), sections: sections),
            DropTarget(section: "review|done", position: .byDefault)
        )
        XCTAssertEqual(layout(.review, cards: one, search: "retry").map(\.title), ["Todo"])
        XCTAssertEqual(layout(.review, cards: []).map(\.title), [])
        XCTAssertEqual(layout(.mine, cards: one).map(\.title), [])
    }

    /// Mine keeps its empty Done, and its empty first list, while it has a
    /// card and nothing is searched.
    func testMineKeepsItsEmptySectionsAsDropPlaces() {
        let m1 = sampleCards().filter { $0.id == "M1" }
        XCTAssertEqual(layout(.mine, cards: m1).map(\.key), ["mine|main", "mine|done"])
        XCTAssertEqual(layout(.mine, cards: m1)[1].detail, "0 PRs")
        let m3 = sampleCards().filter { $0.id == "M3" }
        XCTAssertEqual(layout(.mine, cards: m3).map(\.key), ["mine|main", "mine|done"])
        XCTAssertEqual(layout(.mine, cards: m1, search: "zzz").map(\.key), [])
        XCTAssertEqual(layout(.mine, cards: []).map(\.key), [])
    }

    func testReviewHasItsFourSectionsAndFoldsPastFive() {
        let sections = layout(.review)
        XCTAssertEqual(sections.map(\.title), ["Doing", "Todo", "Waiting", "Done"])
        XCTAssertEqual(sections.map(\.key), ["review|doing", "review|todo", "review|waiting", "review|done"])
        XCTAssertEqual(sections.map(\.accepts), [true, true, true, true])
        XCTAssertEqual(sections.map(\.isDone), [false, false, false, true])
        let todo = sections[1]
        XCTAssertEqual(todo.cards.map(\.id), ["T1", "T2", "T3", "T4", "T5"])
        XCTAssertEqual(todo.more, 2)
        XCTAssertEqual(todo.foldLine, "+ 2 more PRs")
        XCTAssertEqual(todo.moreMark, .blue, "T7's mention is blue though T7 is muted")
        XCTAssertEqual(todo.detail, "7 PRs")
        XCTAssertEqual(sections[0].detail, "1 PR")
        XCTAssertNil(sections[0].foldLine)
    }

    func testMutedCardsGoLastInTheirRankAndAGrayFoldGetsTheRing() {
        var cards = sampleCards()
        // T6 ranked first by the daemon, but muted: after the others.
        cards[6].placement?.position = -1
        let todo = layout(.review, cards: cards)[1]
        XCTAssertEqual(todo.matching.map(\.id), ["T1", "T2", "T3", "T4", "T5", "T6", "T7"])
        cards[7].rows[0].unread = false
        XCTAssertEqual(layout(.review, cards: cards)[1].moreMark, .ring, "only gray unread left in the fold")
        cards[6].rows[0].unread = false
        XCTAssertEqual(layout(.review, cards: cards)[1].moreMark, .none)
        XCTAssertEqual(layout(.review, cards: cards)[1].foldLine, "+ 2 more PRs")
    }

    func testOneMorePRAndExpandingAndTheSearch() {
        let cards = sampleCards().filter { $0.id != "T7" }
        XCTAssertEqual(layout(.review, cards: cards)[1].foldLine, "+ 1 more PR")
        let open = layout(.review, expanded: ["review|todo"])[1]
        XCTAssertEqual(open.cards.count, 7)
        XCTAssertTrue(open.showLess)
        XCTAssertEqual(open.foldLine, "Show less")
        let searched = layout(.review, expanded: [], search: "Title")[1]
        XCTAssertEqual(searched.cards.count, 7, "no fold with a search")
        XCTAssertNil(searched.foldLine)
        XCTAssertEqual(layout(.review, search: "renovate").map(\.title), ["Todo"], "sections without a match go")
        XCTAssertEqual(layout(.review, search: "renovate")[0].detail, "7 PRs", "counts ignore the search")
        let collapsed = layout(.review, collapsed: ["review|todo"])[1]
        XCTAssertTrue(collapsed.collapsed)
        XCTAssertEqual(collapsed.cards, [])
        XCTAssertNil(collapsed.foldLine)
        XCTAssertEqual(collapsed.matching.count, 7)
    }

    func testMineIsOneListWithoutAHeadingThenDone() {
        let sections = layout(.mine)
        XCTAssertEqual(sections.map(\.key), ["mine|main", "mine|done"])
        XCTAssertEqual(sections.map(\.showsHeader), [false, true])
        XCTAssertEqual(sections.map(\.accepts), [true, true])
        XCTAssertEqual(sections[0].cards.map(\.id), ["M1", "M2"])
    }

    func testAllGroupsByRepositoryAndSortsOpenFirstMutedLast() {
        let sections = layout(.all)
        XCTAssertEqual(sections.map(\.title), ["acme-corp/infra", "acme-corp/web", "example-org/api", "example-org/docs", "example-org/web"])
        XCTAssertEqual(sections.map(\.level), [1, 1, 1, 1, 1])
        XCTAssertEqual(sections[2].cards.map(\.id), ["T4", "T1", "M1", "M3", "T7"])
        XCTAssertEqual(sections[4].cards.map(\.id), ["T5", "T2", "R1", "T6"])
        XCTAssertEqual(sections[0].cards.map(\.id), ["W1", "D1"])
        XCTAssertEqual(sections[2].key, "all|repository|none|example-org/api|")
        XCTAssertTrue(sections.allSatisfy { !$0.accepts })
        let added = layout(.all, options: ListOptions(groupBy: .none, sort: .recentlyAdded))
        XCTAssertEqual(added.count, 1)
        XCTAssertFalse(added[0].showsHeader)
        XCTAssertEqual(added[0].cards.count, 5, "the one list folds too")
        XCTAssertEqual(added[0].more, 9)
    }

    func testTwoLevelsAndTheirKeys() {
        let options = ListOptions(groupBy: .repository, thenBy: .status)
        let sections = layout(.all, options: options)
        let api = sections.filter { $0.key.hasPrefix("all|repository|status|example-org/api|") }
        XCTAssertEqual(api.map(\.title), ["example-org/api", "Open", "Closed"])
        XCTAssertEqual(api.map(\.level), [1, 2, 2])
        XCTAssertEqual(api.map(\.isLeaf), [false, true, true])
        XCTAssertEqual(api[0].detail, "5 PRs")
        XCTAssertEqual(api[1].cards.map(\.id), ["T4", "T1", "M1", "T7"])
        XCTAssertEqual(api[2].key, "all|repository|status|example-org/api|closed")
        // Folding the first level hides its groups; the key has no second
        // part.
        let folded = layout(.all, options: options, collapsed: ["all|repository|status|example-org/api|"])
        XCTAssertEqual(folded.filter { $0.key.hasPrefix("all|repository|status|example-org/api|") }.map(\.title), ["example-org/api"])
        XCTAssertTrue(folded.first { $0.title == "example-org/api" }!.collapsed)
    }

    func testGroupOrdersAndNewRepositoriesAtTheEnd() {
        let known = Listing.knownRepositories(["z/last", "example-org/api"], cards: sampleCards())
        XCTAssertEqual(known, ["z/last", "example-org/api", "acme-corp/infra", "acme-corp/web", "example-org/docs", "example-org/web"])
        let ordered = layout(.all, repositories: known)
        XCTAssertEqual(ordered.map(\.title), ["example-org/api", "acme-corp/infra", "acme-corp/web", "example-org/docs", "example-org/web"])
        let status = layout(.all, options: ListOptions(groupBy: .status), orders: [.status: ["closed", "open"]])
        XCTAssertEqual(status.map(\.title), ["Closed", "Open", "Merged"], "saved first, the rest in default order")
        let owners = Listing.orderedGroups(.owner, account: sampleAccount(disabled: ["o3"]), repositories: [], orders: [.owner: ["o4", "gone", "o2"]])
        XCTAssertEqual(owners.map(\.title), ["Public", "example-org"], "enabled owners only; removed ones drop")
        XCTAssertEqual(Listing.defaultGroups(.owner, account: sampleAccount(), repositories: []).map(\.title), ["example-org", "acme-corp", "Public"])
    }

    func testInvolvementPutsYourOwnPRUnderAuthoredByMe() {
        let cards = [
            card("a", authored: true, reviewRequested: true),
            card("b", assigned: true, reviewRequested: true),
            card("c", assigned: true),
            card("d"),
        ]
        XCTAssertEqual(cards.map { Listing.groupKey($0, .involvement) }, ["authored", "review_requested", "assigned", "others"])
        let sections = layout(.all, options: ListOptions(groupBy: .involvement), cards: cards)
        XCTAssertEqual(sections.map(\.title), ["Review requested", "Authored by me", "Assigned to me", "Others"])
    }

    /// ⇧R: the tab's unread rows after the search, folded, collapsed and
    /// muted ones too.
    func testMarkAllReadTakesEveryUnreadRowOfTheTab() {
        let cards = sampleCards()
        XCTAssertEqual(Listing.rowsToRead(tab: .review, cards: cards, search: ""), ["A", "D", "t6", "t7"])
        XCTAssertEqual(Listing.rowsToRead(tab: .review, cards: cards, search: "renovate"), ["t6", "t7"])
        XCTAssertEqual(Listing.rowsToRead(tab: .all, cards: cards, search: "").count, 6, "N1's gray row and M1's too")
    }

    func testTheRowsOfACard() {
        let t1 = sampleCards()[1]
        XCTAssertEqual(Listing.visibleRows(t1, expanded: false).map(\.id), ["A", "B", "C"])
        XCTAssertEqual(Listing.moreRows(t1, expanded: false), 2)
        XCTAssertEqual(Listing.moreRowsText(2), "+ 2 more")
        XCTAssertEqual(Listing.moreRowsMark(t1), .blue, "D is unread")
        XCTAssertNil(Listing.moreRows(t1, expanded: true))
        XCTAssertFalse(Listing.showsOlderActivity(t1, expanded: false))
        XCTAssertTrue(Listing.showsOlderActivity(t1, expanded: true))
        XCTAssertFalse(Listing.showsOlderActivity(sampleCards()[0], expanded: true))
        XCTAssertNil(Listing.moreRows(sampleCards()[0], expanded: false))
    }
}

final class SelectionAndHintTests: XCTestCase {
    func testTheSelectionWalksHeadingsCardsRowsAndFoldLines() {
        let items = PopoverLogic.items(view(.review))
        XCTAssertEqual(Array(items.prefix(9)), [
            .section("review|doing"), .header(card: "R1"), .row(id: "r1", card: "R1"),
            .section("review|todo"), .header(card: "T1"), .row(id: "A", card: "T1"), .row(id: "B", card: "T1"),
            .row(id: "C", card: "T1"), .moreRows(card: "T1"),
        ])
        XCTAssertTrue(items.contains(.more("review|todo")))
        let expanded = PopoverLogic.items(view(.review, expandedRows: ["T1"]))
        XCTAssertTrue(expanded.contains(.row(id: "E", card: "T1")))
        XCTAssertTrue(expanded.contains(.olderActivity(card: "T1")))
        XCTAssertFalse(expanded.contains(.moreRows(card: "T1")))
        XCTAssertEqual(PopoverLogic.items(view(.mine)).first, .header(card: "M1"), "no heading for Mine's first list")
        XCTAssertEqual(PopoverLogic.items(view(nil)), [.header(card: "X2"), .header(card: "X1")])
        XCTAssertEqual(PopoverLogic.move(nil, up: false, in: items), items.first)
        XCTAssertEqual(PopoverLogic.move(nil, up: true, in: items), items.last)
        XCTAssertEqual(PopoverLogic.move(items[0], up: true, in: items), items[0])
        XCTAssertEqual(PopoverLogic.keep(.row(id: "A", card: "gone"), in: items), .row(id: "A", card: "T1"))
        XCTAssertNil(PopoverLogic.keep(.header(card: "gone"), in: items))
    }

    func hint(_ selection: SelectionItem?, _ view: ListView) -> String {
        PopoverLogic.hints(selection: selection, view: view).map { "\($0.key) \($0.text)" }.joined(separator: "  ")
    }

    /// Every line of the hint table of DESIGN.md, "Keyboard".
    func testTheHintTable() {
        let review = view(.review)
        XCTAssertEqual(hint(.header(card: "T1"), review), "↑↓ Move  ⏎ Open  ⌥↑↓ Reorder  D T W Move to  ⌫ Dismiss  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(.header(card: "T7"), review), "↑↓ Move  ⏎ Open  D T W Move to  ⌫ Dismiss  ⇧R Mark all read  ⌘F Search", "muted: no Reorder")
        XCTAssertEqual(hint(.header(card: "D1"), review), "↑↓ Move  ⏎ Open  D T W Move to  ⌫ Dismiss  ⇧R Mark all read  ⌘F Search",
                       "Done: no Reorder")
        XCTAssertEqual(hint(.header(card: "M1"), view(.mine)), "↑↓ Move  ⏎ Open  ⌥↑↓ Reorder  ⌫ Dismiss  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(.header(card: "M3"), view(.mine)), "↑↓ Move  ⏎ Open  ⌫ Dismiss  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(.header(card: "T1"), view(.all)), "↑↓ Move  ⏎ Open  ⌫ Dismiss  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(.header(card: "X1"), view(nil)), "↑↓ Move  ⏎ Open  ⌫ Restore  esc Back  ⌘F Search")
        XCTAssertEqual(hint(nil, view(nil)), "esc Back  ⌘F Search")
        XCTAssertEqual(hint(nil, view(nil, cards: [])), "esc Back  ⌘F Search")
        XCTAssertEqual(hint(.row(id: "A", card: "T1"), review), "↑↓ Move  ⏎ Open  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(nil, review), "↑↓ Move  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(.section("review|todo"), review), "↑↓ Move  ⏎ Collapse  ⇧R Mark all read  ⌘F Search")
        let collapsed = ListView(tab: .review, sections: layout(.review, collapsed: ["review|todo"]), cards: sampleCards())
        XCTAssertEqual(hint(.section("review|todo"), collapsed), "↑↓ Move  ⏎ Expand  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(.more("review|todo"), review), "↑↓ Move  ⏎ Expand  ⇧R Mark all read  ⌘F Search")
        let expanded = ListView(tab: .review, sections: layout(.review, expanded: ["review|todo"]), cards: sampleCards())
        XCTAssertEqual(hint(.more("review|todo"), expanded), "↑↓ Move  ⏎ Show less  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(.moreRows(card: "T1"), review), "↑↓ Move  ⏎ Expand  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(.olderActivity(card: "T1"), review), "↑↓ Move  ⏎ Open  ⇧R Mark all read  ⌘F Search")
    }

    func testWhatTheKeysAskFor() {
        let review = view(.review)
        func act(_ key: Key, _ selection: SelectionItem?, _ view: ListView = review) -> PopoverAction? {
            PopoverLogic.action(for: key, selection: selection, view: view)
        }
        XCTAssertEqual(act(.open, .header(card: "T1")), .open("https://github.com/p/T1", read: nil))
        XCTAssertEqual(act(.open, .row(id: "A", card: "T1")), .open("https://github.com/c/A", read: "A"))
        XCTAssertEqual(act(.open, .section("review|todo")), .toggleSection("review|todo"))
        XCTAssertEqual(act(.open, .more("review|todo")), .toggleMore("review|todo"))
        XCTAssertEqual(act(.open, .moreRows(card: "T1")), .expandRows(card: "T1"))
        XCTAssertEqual(act(.open, .olderActivity(card: "T1")), .open("https://github.com/p/T1", read: nil))
        XCTAssertEqual(act(.markAllRead, nil), .markAllRead)
        XCTAssertNil(act(.markAllRead, nil, view(nil)), "no rows in the Dismissed list")
        // ⌫: the card of the header or the row; Restore in Dismissed.
        XCTAssertEqual(act(.delete, .row(id: "A", card: "T1")), .dismiss(card: "T1"))
        XCTAssertEqual(act(.delete, .header(card: "X1"), view(nil)), .restore(card: "X1"))
        XCTAssertNil(act(.delete, .section("review|todo")))
        // ⌥↑↓ among the cards that are not muted.
        XCTAssertEqual(act(.reorder(up: true), .header(card: "T2")),
                       .place(PlaceMove(card: "T2", target: .review(.todo), position: .before("T1"), verb: .move)))
        XCTAssertEqual(act(.reorder(up: false), .row(id: "A", card: "T1")),
                       .place(PlaceMove(card: "T1", target: .review(.todo), position: .before("T3"), verb: .move)))
        XCTAssertNil(act(.reorder(up: true), .header(card: "T1")), "the top")
        XCTAssertNil(act(.reorder(up: false), .header(card: "T5")), "the last that is not muted")
        XCTAssertNil(act(.reorder(up: true), .header(card: "T7")), "a muted card does not move")
        XCTAssertNil(act(.reorder(up: true), .header(card: "D1")), "Done")
        XCTAssertNil(act(.reorder(up: true), .header(card: "T2"), view(.all)), "All")
        XCTAssertEqual(act(.reorder(up: false), .header(card: "M1"), view(.mine)),
                       .place(PlaceMove(card: "M1", target: .mine, position: .bottom, verb: .move)))
        // D / T / W in Review only, also for a muted card.
        XCTAssertEqual(act(.moveTo(.doing), .header(card: "T1")),
                       .place(PlaceMove(card: "T1", target: .review(.doing), position: .byDefault, verb: .move)))
        XCTAssertEqual(act(.moveTo(.waiting), .header(card: "T7")),
                       .place(PlaceMove(card: "T7", target: .review(.waiting), position: .byDefault, verb: .move)))
        XCTAssertNil(act(.moveTo(.todo), .header(card: "T1")), "already there")
        XCTAssertEqual(act(.moveTo(.todo), .header(card: "D1")),
                       .place(PlaceMove(card: "D1", target: .review(.todo), position: .byDefault, verb: .move)), "out of Done")
        XCTAssertNil(act(.reorder(up: false), .header(card: "M3"), view(.mine)), "Mine's Done")
        XCTAssertNil(act(.moveTo(.todo), .header(card: "M1"), view(.mine)), "Mine")
        XCTAssertNil(act(.moveTo(.todo), .header(card: "N1"), view(.all)), "All")
    }

    func testTheLinkCommandCCopies() {
        let review = view(.review)
        XCTAssertEqual(PopoverLogic.link(for: .header(card: "T1"), view: review), "https://github.com/p/T1")
        XCTAssertEqual(PopoverLogic.link(for: .row(id: "A", card: "T1"), view: review), "https://github.com/c/A")
        XCTAssertNil(PopoverLogic.link(for: .section("review|todo"), view: review))
        XCTAssertNil(PopoverLogic.link(for: nil, view: review))
    }
}

final class MenuTests: XCTestCase {
    func titles(_ entries: [MenuEntry?]) -> [String] {
        entries.map { $0?.title ?? "-" }
    }

    /// Main.html, "Right-click on a card header in Review › Todo".
    func testACardInTodo() {
        let menu = PopoverLogic.menu(for: .header(card: "T1"), view: view(.review), hasTextSelection: false, login: "bufferings-work")
        XCTAssertEqual(titles(menu), [
            "Open on GitHub", "Copy link", "-", "Move to Doing", "Move to Waiting", "Move to Done", "Remove from Review", "-",
            "Mute this pull request", "Mute example-org/api", "Mute @al", "-", "Dismiss", "-", "Mark all as read",
        ])
        XCTAssertEqual(menu[3]?.action, .place(PlaceMove(card: "T1", target: .review(.doing), position: .byDefault, verb: .move)))
        XCTAssertEqual(menu[5]?.action, .place(PlaceMove(card: "T1", target: .review(.done), position: .byDefault, verb: .move)))
        XCTAssertEqual(menu[6]?.action, .place(PlaceMove(card: "T1", target: .none, position: .byDefault, verb: .remove)))
        XCTAssertEqual(menu[9]?.action, .mute(.repo, "example-org/api"))
    }

    /// Main.html, "Text selected in a title, then right-click".
    func testAnAssignedCardInMineWithSelectedText() {
        let menu = PopoverLogic.menu(for: .header(card: "M2"), view: view(.all), hasTextSelection: true, login: "bufferings-work")
        XCTAssertEqual(titles(menu), [
            "Open on GitHub", "Copy", "Copy link", "-", "Move to Done", "Remove from Mine", "-",
            "Mute this pull request", "Mute acme-corp/web", "Mute @mk", "-", "Dismiss", "-", "Mark all as read",
        ])
        XCTAssertEqual(menu[4]?.action, .place(PlaceMove(card: "M2", target: .mineDone, position: .byDefault, verb: .move)))
    }

    /// A card in Done moves out and is removed like any other (DESIGN.md,
    /// "Review" and the mouse table of "Keyboard").
    func testACardInDone() {
        let all = view(.all)
        func items(_ id: String) -> [MenuEntry?] {
            PopoverLogic.menu(for: .header(card: id), view: all, hasTextSelection: false, login: "bufferings-work")
        }
        let d1 = items("D1")
        XCTAssertEqual(Array(titles(d1)[2...7]), ["-", "Move to Doing", "Move to Todo", "Move to Waiting", "Remove from Review", "-"])
        XCTAssertEqual(d1[4]?.action, .place(PlaceMove(card: "D1", target: .review(.todo), position: .byDefault, verb: .move)))
        let m3 = items("M3")
        XCTAssertEqual(Array(titles(m3)[2...4]), ["-", "Move to Mine", "-"], "your own PR stays in Mine")
        XCTAssertEqual(m3[3]?.action, .place(PlaceMove(card: "M3", target: .mine, position: .byDefault, verb: .move)))
    }

    func testPlacementItemsLeaveOutWhatDoesNotApply() {
        let all = view(.all)
        func items(_ id: String) -> [String] {
            titles(PopoverLogic.menu(for: .header(card: id), view: all, hasTextSelection: false, login: "bufferings-work"))
        }
        XCTAssertFalse(items("M1").contains("Remove from Mine"), "your own PR stays in Mine")
        XCTAssertFalse(items("M1").contains { $0.hasPrefix("Mute @") }, "no Mute @<your login>")
        XCTAssertTrue(items("M1").contains("Mute example-org/api"))
        XCTAssertTrue(items("N1").contains("Add to Review"))
        XCTAssertTrue(items("N1").contains("Add to Mine"))
        let menu = PopoverLogic.menu(for: .header(card: "N1"), view: all, hasTextSelection: false, login: "x")
        XCTAssertEqual(menu[3]?.action, .place(PlaceMove(card: "N1", target: .review(.todo), position: .byDefault, verb: .add)))
        XCTAssertEqual(menu[4]?.action, .place(PlaceMove(card: "N1", target: .mine, position: .byDefault, verb: .add)))
        let own = card("O", authored: true)
        let ownMenu = titles(PopoverLogic.menu(for: .header(card: "O"), view: view(.all, cards: [own]), hasTextSelection: false, login: "x"))
        XCTAssertFalse(ownMenu.contains("Add to Review"), "your own PR is never in Review")
        XCTAssertTrue(ownMenu.contains("Add to Mine"))
        let t7 = titles(PopoverLogic.menu(for: .header(card: "T7"), view: view(.review), hasTextSelection: false, login: "x"))
        XCTAssertTrue(t7.contains("Mute this pull request"))
        XCTAssertTrue(t7.contains("Unmute example-org/api"))
        XCTAssertTrue(t7.contains("Unmute @renovate"))
    }

    /// Main.html, "Right-click on a row".
    func testARowMenu() {
        let review = view(.review)
        let menu = PopoverLogic.menu(for: .row(id: "A", card: "T1"), view: review, hasTextSelection: false, login: "bufferings-work")
        XCTAssertEqual(titles(menu), ["Open on GitHub", "Copy link", "-", "Mute @al", "-", "Mark all as read"])
        XCTAssertEqual(menu[0]?.action, .open("https://github.com/c/A", read: "A"))
        XCTAssertEqual(titles(PopoverLogic.menu(for: .row(id: "A", card: "T1"), view: review, hasTextSelection: false, login: "AL")),
                       ["Open on GitHub", "Copy link", "-", "Mark all as read"], "your own row")
        XCTAssertEqual(titles(PopoverLogic.menu(for: .row(id: "r1", card: "R1"), view: review, hasTextSelection: true, login: "x")),
                       ["Open on GitHub", "Copy", "Copy link", "-", "Mark all as read"], "no actor")
        XCTAssertEqual(PopoverLogic.menu(for: .row(id: "A", card: "T1"), view: review, hasTextSelection: false, login: "x", mutedUsers: ["Al"])[3]?.action,
                       .unmute(.user, "al"))
        XCTAssertEqual(PopoverLogic.menu(for: .section("review|todo"), view: review, hasTextSelection: false, login: "x"), [])
    }

    func testADismissedCardMenu() {
        let menu = PopoverLogic.menu(for: .header(card: "X1"), view: view(nil), hasTextSelection: true, login: "x")
        XCTAssertEqual(titles(menu), ["Open on GitHub", "Copy", "Copy link", "-", "Restore"])
        XCTAssertEqual(menu[4]?.action, .restore(card: "X1"))
    }
}

final class CardMoveTests: XCTestCase {
    func testWhereADropLands() {
        let sections = layout(.review)
        XCTAssertEqual(CardDrop.target(.card("T3", lowerHalf: false), sections: sections), DropTarget(section: "review|todo", position: .before("T3")))
        XCTAssertEqual(CardDrop.target(.card("T3", lowerHalf: true), sections: sections), DropTarget(section: "review|todo", position: .before("T4")))
        XCTAssertEqual(CardDrop.target(.card("T5", lowerHalf: true), sections: sections), DropTarget(section: "review|todo", position: .bottom),
                       "muted cards always stay after")
        XCTAssertEqual(CardDrop.target(.card("T6", lowerHalf: false), sections: sections), DropTarget(section: "review|todo", position: .bottom),
                       "over a muted card: after the last that is not")
        XCTAssertEqual(CardDrop.target(.header("review|doing"), sections: sections), DropTarget(section: "review|doing", position: .bottom))
        XCTAssertEqual(CardDrop.target(.more("review|todo"), sections: sections), DropTarget(section: "review|todo", position: .bottom))
        let collapsed = layout(.review, collapsed: ["review|waiting"])
        XCTAssertEqual(CardDrop.target(.header("review|waiting"), sections: collapsed), DropTarget(section: "review|waiting", position: .bottom))
        XCTAssertEqual(CardDrop.target(.header("review|done"), sections: sections), DropTarget(section: "review|done", position: .byDefault),
                       "Done by its own order")
        XCTAssertEqual(CardDrop.target(.card("D1", lowerHalf: false), sections: sections), DropTarget(section: "review|done", position: .byDefault))
        XCTAssertEqual(CardDrop.target(.card("M3", lowerHalf: true), sections: layout(.mine)), DropTarget(section: "mine|done", position: .byDefault))
        XCTAssertNil(CardDrop.target(.card("T1", lowerHalf: false), sections: layout(.all)), "no drag in All")
        XCTAssertEqual(CardDrop.target(.card("M2", lowerHalf: false), sections: layout(.mine)), DropTarget(section: "mine|main", position: .before("M2")))
    }

    func testTheLine() {
        let todo = layout(.review)[1]
        XCTAssertEqual(CardDrop.lineAbove(DropTarget(section: todo.key, position: .before("T3")), in: todo), "T3")
        XCTAssertNil(CardDrop.lineAbove(DropTarget(section: todo.key, position: .bottom), in: todo), "above + 2 more PRs")
        let open = layout(.review, expanded: ["review|todo"])[1]
        XCTAssertEqual(CardDrop.lineAbove(DropTarget(section: open.key, position: .bottom), in: open), "T6", "above the muted cards")
        let done = layout(.review)[3]
        XCTAssertEqual(CardDrop.lineAbove(DropTarget(section: done.key, position: .byDefault), in: done), "D1", "Done: the top")
    }

    func testADropBecomesAPlaceAndTheSameSpotNothing() {
        let cards = sampleCards()
        let t2 = cards[2]
        XCTAssertNil(CardDrop.move(t2, to: DropTarget(section: "review|todo", position: .before("T3")), cards: cards))
        XCTAssertEqual(CardDrop.move(t2, to: DropTarget(section: "review|todo", position: .before("T5")), cards: cards),
                       PlaceMove(card: "T2", target: .review(.todo), position: .before("T5"), verb: .move))
        XCTAssertNil(CardDrop.move(cards[5], to: DropTarget(section: "review|todo", position: .bottom), cards: cards), "T5 is the last already")
        XCTAssertEqual(CardDrop.move(cards[0], to: DropTarget(section: "review|todo", position: .bottom), cards: cards),
                       PlaceMove(card: "R1", target: .review(.todo), position: .bottom, verb: .move))
        XCTAssertEqual(CardDrop.move(cards[11], to: DropTarget(section: "mine|main", position: .before("M1")), cards: cards),
                       PlaceMove(card: "M2", target: .mine, position: .before("M1"), verb: .move))
        // Into Done: no position; a card in Done stays where Done puts it.
        XCTAssertEqual(CardDrop.move(t2, to: DropTarget(section: "review|done", position: .byDefault), cards: cards),
                       PlaceMove(card: "T2", target: .review(.done), position: .byDefault, verb: .move))
        XCTAssertEqual(CardDrop.move(cards[11], to: DropTarget(section: "mine|done", position: .byDefault), cards: cards),
                       PlaceMove(card: "M2", target: .mineDone, position: .byDefault, verb: .move))
        let d1 = cards.first { $0.id == "D1" }!
        XCTAssertNil(CardDrop.move(d1, to: DropTarget(section: "review|done", position: .byDefault), cards: cards))
        XCTAssertEqual(CardDrop.move(d1, to: DropTarget(section: "review|doing", position: .bottom), cards: cards),
                       PlaceMove(card: "D1", target: .review(.doing), position: .bottom, verb: .move), "a merged card moves out")
    }

    func order(_ cards: [Card], _ key: String) -> [String] {
        Listing.ranked(cards.filter { $0.sectionKey == key && !$0.isDismissed }).map(\.id)
    }

    /// Moves shown before the daemon answers follow its rules (DESIGN.md,
    /// "Review" and "Wire format", `place`).
    func testAMoveShownAtOnceFollowsThePlaceRules() {
        let cards = sampleCards()
        func place(_ id: String, _ target: PlaceTarget, _ position: PlacePosition = .byDefault) -> [Card] {
            LocalChange.place(PlaceMove(card: id, target: target, position: position, verb: .move)).apply(cards)
        }
        // To Todo from Doing or Waiting: the top.
        var moved = place("R1", .review(.todo))
        XCTAssertEqual(order(moved, "review|todo"), ["R1", "T1", "T2", "T3", "T4", "T5", "T6", "T7"])
        XCTAssertEqual(order(moved, "review|doing"), [])
        XCTAssertEqual(moved.first { $0.id == "T7" }?.placement?.position, 7)
        moved = place("W1", .review(.todo))
        XCTAssertEqual(order(moved, "review|todo").first, "W1")
        // From elsewhere: the bottom, before the muted cards.
        moved = place("N1", .review(.todo))
        XCTAssertEqual(order(moved, "review|todo"), ["T1", "T2", "T3", "T4", "T5", "N1", "T6", "T7"])
        // A muted card goes among the muted ones.
        moved = place("T6", .review(.doing))
        XCTAssertEqual(order(moved, "review|doing"), ["R1", "T6"])
        moved = place("T1", .review(.todo), .before("T4"))
        XCTAssertEqual(order(moved, "review|todo"), ["T2", "T3", "T1", "T4", "T5", "T6", "T7"])
        moved = place("T5", .review(.todo), .top)
        XCTAssertEqual(order(moved, "review|todo"), ["T5", "T1", "T2", "T3", "T4", "T6", "T7"])
        // Remove from …: no placement; the rest numbered again.
        moved = place("M1", .none)
        XCTAssertNil(moved.first { $0.id == "M1" }?.placement)
        XCTAssertEqual(moved.first { $0.id == "M2" }?.placement?.position, 0)
        // A closed PR without a placement goes straight to Done.
        let closed = card("Z", state: .closed)
        let added = LocalChange.place(PlaceMove(card: "Z", target: .mine, position: .byDefault, verb: .add)).apply(cards + [closed])
        XCTAssertEqual(order(added, "mine|done"), ["Z", "M3"])
        // Into Done: the top, newest entry first; out of Done: no automatic
        // Dismiss any more.
        moved = place("T3", .review(.done))
        XCTAssertEqual(order(moved, "review|done"), ["T3", "D1"])
        XCTAssertEqual(order(moved, "review|todo"), ["T1", "T2", "T4", "T5", "T6", "T7"])
        moved = place("M2", .mineDone)
        XCTAssertEqual(order(moved, "mine|done"), ["M2", "M3"])
        var due = cards
        due[due.firstIndex { $0.id == "D1" }!].autoDismissAt = T0 + 86_400
        moved = LocalChange.place(PlaceMove(card: "D1", target: .review(.todo), position: .byDefault, verb: .move)).apply(due)
        XCTAssertEqual(order(moved, "review|todo"), ["T1", "T2", "T3", "T4", "T5", "D1", "T6", "T7"], "from Done: the bottom")
        XCTAssertNil(moved.first { $0.id == "D1" }?.autoDismissAt)
    }

    func testDismissRestoreReadAndMuteShownAtOnce() {
        let cards = sampleCards()
        let dismissed = LocalChange.dismiss(card: "T1", at: T0, expiresAt: T0 + 7 * 86_400).apply(cards)
        XCTAssertEqual(Listing.dismissed(dismissed).first?.id, "T1")
        XCTAssertFalse(Listing.cards(dismissed, tab: .review).contains { $0.id == "T1" })
        XCTAssertEqual(dismissed.first { $0.id == "T1" }?.placement, cards[1].placement, "the placement stays")
        let restored = LocalChange.restore(card: "X1").apply(cards)
        XCTAssertNil(restored.first { $0.id == "X1" }?.dismissedAt)
        let read = LocalChange.read(["A", "t7"]).apply(cards)
        XCTAssertEqual(read[1].rows[0].unread, false)
        XCTAssertEqual(read[7].rows[0].unread, false)

        let repo = LocalChange.mute(.repo, "Example-Org/Web").apply(cards)
        let r1 = repo[0]
        XCTAssertEqual(r1.muted, [.known(.repo)])
        XCTAssertEqual(r1.rows[0].muted, true)
        XCTAssertEqual(order(repo, "review|doing"), ["R1"])
        XCTAssertEqual(order(repo, "review|todo"), ["T1", "T3", "T4", "T2", "T5", "T6", "T7"], "muted cards go last, in their rank")
        // A user's rows in other PRs, but not mentions, state changes or
        // reactions.
        var mixed = cards
        mixed[1].rows.append(row("S", pr: "example-org/api#407", kind: .checksFailed, actor: "al"))
        let user = LocalChange.mute(.user, "AL").apply(mixed)
        XCTAssertEqual(user[1].muted, [.known(.author)], "al wrote T1")
        XCTAssertEqual(user[1].rows.map(\.muted), [false, true, true, true, true, true], "the mention stays blue")
        let other = LocalChange.mute(.user, "rk").apply(mixed)
        XCTAssertEqual(other[1].muted, [], "rk did not write T1")
        XCTAssertEqual(other[1].rows.map(\.muted), [false, false, false, true, false, false], "only rk's reply")
        let unmuted = LocalChange.unmute(.user, "renovate").apply(cards)
        XCTAssertEqual(unmuted[6].muted, [])
        XCTAssertEqual(unmuted[6].rows[0].muted, false)
        XCTAssertEqual(unmuted[7].muted, [.known(.repo)], "still muted for its repository")
        let pr = LocalChange.mute(.pr, "acme-corp/web#80").apply(cards)
        XCTAssertEqual(pr[13].muted, [.known(.pr)])
        XCTAssertEqual(LocalChange.mute(.pr, "x").verb, .mute)
        XCTAssertEqual(LocalChange.read([]).verb, .markAsRead)
    }

    /// A local mute touches only what it targets: a row the daemon sent
    /// muted (by a user mute the app has not read) stays muted when another
    /// card is muted or unmuted.
    func testALocalMuteLeavesOtherCardsAsTheDaemonSentThem() {
        var cards = sampleCards()
        cards[1].rows[1].muted = true
        let muted = LocalChange.mute(.pr, "acme-corp/web#80").apply(cards)
        XCTAssertEqual(muted[1].rows[1].muted, true, "another card")
        XCTAssertEqual(muted[1], cards[1])
        let unmuted = LocalChange.unmute(.repo, "example-org/web").apply(cards)
        XCTAssertEqual(unmuted[1], cards[1], "another card")
        let user = LocalChange.mute(.user, "nobody-here").apply(cards)
        XCTAssertEqual(user, cards, "no card or row of that user")
    }
}
