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

/// DESIGN.md, "Showing what matched": the ranges of the displayed strings
/// that get the yellow background.
final class HighlightTests: XCTestCase {
    func testEveryOccurrenceOfEveryWordCaseInsensitive() {
        let words = Search.words("RE fix")
        XCTAssertEqual(Highlight.ranges(words, in: "Fix retry: re-read and FIX"), [0..<3, 4..<6, 11..<13, 14..<16, 23..<26])
        XCTAssertEqual(Highlight.ranges(Search.words("aa"), in: "aaa"), [0..<3], "overlapping occurrences merge")
        XCTAssertEqual(Highlight.ranges(Search.words("é"), in: "👍 Café"), [6..<7], "UTF-16 offsets")
    }

    func testNoSearchTextMarksNothing() {
        let words = Search.words("  ")
        XCTAssertEqual(words, [])
        XCTAssertEqual(Highlight.ranges(words, in: "anything"), [])
        XCTAssertEqual(Highlight.prLabel(words, pr: "example-org/api#407"), [])
        let card = card("1", rows: (0..<5).map { row("r\($0)", pr: "example-org/api#1", text: "text") })
        XCTAssertFalse(Highlight.marksMoreRows(card, words: words, expanded: false))
        XCTAssertEqual(Highlight.row(words, card.rows[0], RowPresentation(card.rows[0], now: 0)), Highlight.RowMatches())
    }

    /// `owner/repo #number` shows a space before `#`: a word across the
    /// `#` marks the characters on both sides of it.
    func testTheNumberAcrossTheHash() {
        XCTAssertEqual(Warnings.prLabel("example-org/api#407"), "example-org/api #407")
        XCTAssertEqual(Highlight.prLabel(Search.words("api#407"), pr: "example-org/api#407"), [12..<15, 16..<20])
        XCTAssertEqual(Highlight.prLabel(Search.words("#407"), pr: "example-org/api#407"), [16..<20])
        XCTAssertEqual(Highlight.prLabel(Search.words("ORG 40"), pr: "example-org/api#407"), [8..<11, 17..<19])
        XCTAssertEqual(Highlight.baseHead(Search.words("ma fix"), base: "main", head: "fix/main"), [0..<2, 7..<10, 11..<13])
    }

    /// The row's displayed strings: the actor in the meta (not the time),
    /// the body, `by <actor>`, a reaction's quoted text; the author in line
    /// 3's times.
    func testTheFieldsAsDisplayed() {
        let words = Search.words("al min")
        let comment = row("c", pr: "p#1", kind: .comment, text: "Mini  change\nfor all", actor: "alice", at: 0)
        let p = RowPresentation(comment, now: 120)
        XCTAssertEqual(p.meta, "alice · 2 min ago")
        XCTAssertEqual(Highlight.row(words, comment, p), Highlight.RowMatches(meta: [0..<2], body: [0..<3, 16..<18]),
                       "not the `min` of the time; the body as normalized")
        let merged = row("m", pr: "p#1", kind: .merged, actor: "alice")
        XCTAssertEqual(Highlight.row(words, merged, RowPresentation(merged, now: 0)).body, [3..<5], "by alice")
        let author = Highlight.author(words, author: "alice", times: "opened 3 days ago by alice · updated 2 min ago")
        XCTAssertEqual(author, [21..<23], "the login only")
    }

    /// A match in a hidden part marks what hides it, whether or not another
    /// match shows. Nothing expands.
    func testHiddenMatchesAreMarkedWhateverShows() {
        XCTAssertTrue(Highlight.hidesMatch([40..<44], shownEnd: 30))
        XCTAssertTrue(Highlight.hidesMatch([10..<14, 40..<44], shownEnd: 30), "a match shows too")
        XCTAssertTrue(Highlight.hidesMatch([28..<34], shownEnd: 30), "partly cut")
        XCTAssertFalse(Highlight.hidesMatch([10..<14], shownEnd: 30))
        XCTAssertFalse(Highlight.hidesMatch([40..<44], shownEnd: nil), "all shown")

        let rows = (0..<5).map { row("r\($0)", pr: "example-org/api#1", text: $0 == 4 ? "the flaky test" : "lgtm", actor: $0 == 3 ? "zed" : "bo") }
        let folded = card("1", rows: rows)
        XCTAssertTrue(Highlight.marksMoreRows(folded, words: Search.words("FLAKY"), expanded: false), "a folded row's text")
        XCTAssertTrue(Highlight.marksMoreRows(folded, words: Search.words("zed"), expanded: false), "a folded row's actor")
        XCTAssertTrue(Highlight.marksMoreRows(folded, words: Search.words("flaky lgtm"), expanded: false), "a row shown matches too")
        XCTAssertFalse(Highlight.marksMoreRows(folded, words: Search.words("flaky"), expanded: true), "expanded: no + N more")
        XCTAssertFalse(Highlight.marksMoreRows(folded, words: Search.words("title"), expanded: false), "no row matches")
    }

    /// Every card shown with search text has a yellow background somewhere
    /// (the cases of the demo data, `make-data.py --demo`): a laid-out text
    /// shows 40 characters a line here.
    func testEveryCardShownHasAYellowBackground() {
        let long = "A single long line: Could you take a look at the migration plan before Friday? The second step rewrites "
            + "the index of the events table. I am not sure whether we want to keep the old column around for one more release, "
            + "because the CLI of 0.4 still reads it when it lists the rows of a PR."
        let rows = [
            row("long", pr: "org/repo-19#198", kind: .comment, text: long, actor: "user04"),
            row("reply", pr: "org/repo-19#198", kind: .reply, text: "Could you take a look at the migration plan before Friday?", actor: "user04"),
            row("f1", pr: "org/repo-19#198", kind: .comment, text: "Follow-up 1: The second step rewrites the index.", actor: "user04"),
            row("f2", pr: "org/repo-19#198", kind: .comment, text: "Follow-up 2: I am not sure whether we want to keep it,", actor: "user04"),
            row("f3", pr: "org/repo-19#198", kind: .comment, text: "Follow-up 3: because the CLI of 0.4 still reads it.", actor: "user04"),
        ]
        let demo = card("198", rows: rows)
        func marks(_ text: String, expanded: Bool = false, bodies: Set<String> = [], compact: Bool = false) -> Highlight.CardMarks {
            Highlight.card(demo, words: Search.words(text), now: 0, expanded: expanded, expandedBodies: bodies, compact: compact) { cut, text in
                let lines: Int
                if case .body(let id) = cut { lines = bodies.contains(id) ? 5 : 1 } else { lines = 1 }
                let length = (text as NSString).length
                return length > lines * 40 ? lines * 40 - 2 : nil
            }
        }
        // `Follow`: a row shown matches, and so do the two folded ones.
        let follow = marks("Follow")
        XCTAssertTrue(follow.moreRows)
        XCTAssertTrue(follow.rows["f1"]?.body.shows == true)
        // `because`: only behind `more` and in a folded row.
        let because = marks("because")
        XCTAssertEqual(because.rows["long"]?.more, true)
        XCTAssertEqual(because.rows["long"]?.body.ellipsis, true)
        XCTAssertTrue(because.moreRows)
        // `more` pressed: the match is past the 5 lines, under the "…".
        let expanded = marks("because", bodies: ["long"])
        XCTAssertEqual(expanded.rows["long"]?.more, false)
        XCTAssertEqual(expanded.rows["long"]?.body.ellipsis, true)
        for (text, rowsOpen, bodies) in [("because", true, Set<String>()), ("because", true, ["long"]), ("Follow", true, []), ("CLI", false, [])] {
            XCTAssertTrue(marks(text, expanded: rowsOpen, bodies: bodies).anyYellow, "\(text) \(rowsOpen) \(bodies)")
        }
        // The exception: Compact, matched by rows only.
        XCTAssertFalse(marks("because", compact: true).anyYellow)
    }
}

final class OptionsTests: XCTestCase {
    func testGroupByStartsAtRepositoryAndTheTwoLevelsDiffer() {
        var options = ListOptions()
        XCTAssertEqual(options.groupBy, .repository)
        XCTAssertEqual(options.thenBy, .none)
        XCTAssertEqual(options.thenByTitle, "None", "the value, None included")
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

    /// Cards with a colored unread row; a gray muted row does not count, a
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
        XCTAssertEqual(tags["M1"], "Mine · Todo", "the tab and the section, as Review's")
        XCTAssertEqual(tags["M3"], "Mine · Done")
        XCTAssertEqual(card("x", placement: mine(.doing, 0)).placementTag, "Mine · Doing")
        XCTAssertEqual(card("x", placement: mine(.waiting, 0)).placementTag, "Mine · Waiting")
        XCTAssertEqual(tags["N1"], "-")
    }

    func testEmptyTexts() {
        let plain = shows(mutedHidden)
        XCTAssertNil(Listing.emptyText(loaded: false, tab: .all, cards: [], search: "", visibility: plain))
        XCTAssertEqual(Listing.emptyText(loaded: true, tab: .all, cards: [], search: "", visibility: plain), "No pull requests")
        XCTAssertEqual(Listing.emptyText(loaded: true, tab: .review, cards: [], search: "", visibility: plain), "No pull requests to review")
        XCTAssertEqual(Listing.emptyText(loaded: true, tab: .mine, cards: [], search: "", visibility: plain), "No pull requests of yours")
        XCTAssertEqual(Listing.dismissedEmptyText(loaded: true, cards: [], search: ""), "No dismissed pull requests")
        XCTAssertNil(Listing.dismissedEmptyText(loaded: false, cards: [], search: ""))
        XCTAssertEqual(
            Listing.emptyText(loaded: true, tab: .review, cards: sampleCards(), search: "retry timeout", visibility: plain), "Nothing matches"
        )
        XCTAssertEqual(Listing.dismissedEmptyText(loaded: true, cards: sampleCards(), search: "zzz"), "Nothing matches")
        XCTAssertNil(Listing.emptyText(loaded: true, tab: .review, cards: sampleCards(), search: "retry", visibility: plain))
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
            DropTarget(section: "review|doing", position: .top)
        )
        XCTAssertEqual(
            CardDrop.target(.header("review|done"), sections: sections),
            DropTarget(section: "review|done", position: .byDefault)
        )
        XCTAssertEqual(layout(.review, cards: one, search: "retry").map(\.title), ["Todo"])
        XCTAssertEqual(layout(.review, cards: []).map(\.title), [])
        XCTAssertEqual(layout(.mine, cards: one).map(\.title), [])
    }

    /// Mine keeps its empty sections, as Review does, while it has a card
    /// and nothing is searched (DESIGN.md, "Mine").
    func testMineKeepsItsEmptySectionsAsDropPlaces() {
        let m1 = sampleCards().filter { $0.id == "M1" }
        XCTAssertEqual(layout(.mine, cards: m1).map(\.key), ["mine|doing", "mine|todo", "mine|waiting", "mine|done"])
        XCTAssertEqual(layout(.mine, cards: m1).map(\.detail), ["0 PRs", "1 PR", "0 PRs", "0 PRs"])
        XCTAssertEqual(layout(.mine, cards: m1).map(\.level), [1, 1, 1, 1], "every section has its heading")
        let m3 = sampleCards().filter { $0.id == "M3" }
        XCTAssertEqual(layout(.mine, cards: m3).map(\.key), ["mine|doing", "mine|todo", "mine|waiting", "mine|done"])
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

    /// 0.5: a muted card the Filter shows is at its own rank, not
    /// last (DESIGN.md, "Review").
    func testMutedCardsShowAtTheirRankAndAGrayFoldGetsTheRing() {
        var ranked = sampleCards()
        ranked[6].placement?.position = -1
        XCTAssertEqual(layout(.review, cards: ranked)[1].matching.map(\.id), ["T6", "T1", "T2", "T3", "T4", "T5", "T7"])
        var cards = sampleCards()
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
        XCTAssertEqual(layout(.review, search: "example-bot").map(\.title), ["Todo"], "sections without a match go")
        XCTAssertEqual(layout(.review, search: "example-bot")[0].detail, "7 PRs", "counts ignore the search")
        let collapsed = layout(.review, collapsed: ["review|todo"])[1]
        XCTAssertTrue(collapsed.collapsed)
        XCTAssertEqual(collapsed.cards, [])
        XCTAssertNil(collapsed.foldLine)
        XCTAssertEqual(collapsed.matching.count, 7)
    }

    func testMineHasReviewsFourSections() {
        let sections = layout(.mine)
        XCTAssertEqual(sections.map(\.title), ["Doing", "Todo", "Waiting", "Done"])
        XCTAssertEqual(sections.map(\.key), ["mine|doing", "mine|todo", "mine|waiting", "mine|done"])
        XCTAssertEqual(sections.map(\.showsHeader), [true, true, true, true])
        XCTAssertEqual(sections.map(\.accepts), [true, true, true, true])
        XCTAssertEqual(sections.map(\.isDone), [false, false, false, true])
        XCTAssertEqual(sections[1].cards.map(\.id), ["M1", "M2"])
        XCTAssertEqual(sections[3].cards.map(\.id), ["M3"])
    }

    /// "+ N more PRs" and the collapse of Mine's sections, each by its own
    /// key (DESIGN.md, "Section size").
    func testMineFoldsPastFiveAndCollapsesBySection() {
        let todo = (0..<7).map { card("Q\($0)", authored: true, placement: mine(.todo, $0)) }
        let waiting = (0..<2).map { card("V\($0)", placement: mine(.waiting, $0)) }
        let sections = layout(.mine, cards: todo + waiting, collapsed: ["mine|waiting"])
        XCTAssertEqual(sections[1].cards.count, 5)
        XCTAssertEqual(sections[1].foldLine, "+ 2 more PRs")
        XCTAssertTrue(sections[2].collapsed)
        XCTAssertEqual(sections[2].cards, [])
        let open = layout(.mine, cards: todo + waiting, expanded: ["mine|todo"])
        XCTAssertEqual(open[1].cards.count, 7)
        XCTAssertEqual(open[1].foldLine, "Show less")
    }

    /// Open first, then Merged and Closed; muted cards the Filter shows
    /// by the same rule (DESIGN.md, "All").
    func testAllGroupsByRepositoryAndSortsOpenFirst() {
        let sections = layout(.all)
        XCTAssertEqual(sections.map(\.title), ["acme-corp/infra", "acme-corp/web", "example-org/api", "example-org/docs", "example-org/web"])
        XCTAssertEqual(sections.map(\.level), [1, 1, 1, 1, 1])
        XCTAssertEqual(sections[2].cards.map(\.id), ["T7", "T4", "T1", "M1", "M3"])
        XCTAssertEqual(sections[4].cards.map(\.id), ["T6", "T5", "T2", "R1"])
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
        XCTAssertEqual(api[1].cards.map(\.id), ["T7", "T4", "T1", "M1"])
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
    /// muted ones the Filter shows too; not those of the cards the Filter
    /// hides (DESIGN.md, "How unread clears").
    func testMarkAllReadTakesEveryUnreadRowOfTheTab() {
        let cards = sampleCards()
        let all = shows(mutedShown)
        XCTAssertEqual(Listing.rowsToRead(tab: .review, cards: cards, search: "", visibility: all), ["A", "D", "t6", "t7"])
        XCTAssertEqual(Listing.rowsToRead(tab: .review, cards: cards, search: "example-bot", visibility: all), ["t6", "t7"])
        XCTAssertEqual(Listing.rowsToRead(tab: .all, cards: cards, search: "", visibility: all).count, 6, "N1's gray row and M1's too")
        let hide = shows(mutedHidden)
        XCTAssertEqual(Listing.rowsToRead(tab: .review, cards: cards, search: "", visibility: hide), ["A", "D"], "hidden muted cards")
        XCTAssertEqual(Listing.rowsToRead(tab: .review, cards: cards, search: "example-bot", visibility: hide), [])
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
        XCTAssertEqual(Array(PopoverLogic.items(view(.mine)).prefix(3)), [.section("mine|doing"), .section("mine|todo"), .header(card: "M1")],
                       "every section of Mine has its heading")
        XCTAssertEqual(PopoverLogic.items(view(nil)), [.header(card: "X2"), .header(card: "X1")], "card headers only, no repository")
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
        XCTAssertEqual(hint(.header(card: "T7"), review), "↑↓ Move  ⏎ Open  ⌥↑↓ Reorder  D T W Move to  ⌫ Dismiss  ⇧R Mark all read  ⌘F Search", "a muted card shown moves like the others")
        XCTAssertEqual(hint(.header(card: "D1"), review), "↑↓ Move  ⏎ Open  D T W Move to  ⌫ Dismiss  ⇧R Mark all read  ⌘F Search",
                       "Done: no Reorder")
        XCTAssertEqual(hint(.header(card: "M1"), view(.mine)), "↑↓ Move  ⏎ Open  ⌥↑↓ Reorder  D T W Move to  ⌫ Dismiss  ⇧R Mark all read  ⌘F Search",
                       "Mine as Review")
        XCTAssertEqual(hint(.header(card: "M3"), view(.mine)), "↑↓ Move  ⏎ Open  D T W Move to  ⌫ Dismiss  ⇧R Mark all read  ⌘F Search",
                       "Mine's Done as Review's")
        XCTAssertEqual(hint(.section("mine|doing"), view(.mine)), "↑↓ Move  ⏎ Collapse  ⇧R Mark all read  ⌘F Search")
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
        XCTAssertEqual(hint(.lessRows(card: "T1"), view(.review, expandedRows: ["T1"])), "↑↓ Move  ⏎ Show less  ⇧R Mark all read  ⌘F Search")
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
        XCTAssertEqual(act(.open, .lessRows(card: "T1")), .collapseRows(card: "T1"))
        XCTAssertEqual(act(.markAllRead, nil), .markAllRead)
        XCTAssertNil(act(.markAllRead, nil, view(nil)), "no rows in the Dismissed list")
        // ⌫: the card of the header or the row; Restore in Dismissed.
        XCTAssertEqual(act(.delete, .row(id: "A", card: "T1")), .dismiss(card: "T1"))
        XCTAssertEqual(act(.delete, .header(card: "X1"), view(nil)), .restore(card: "X1"))
        XCTAssertNil(act(.delete, .section("review|todo")))
        // ⌥↑↓ past the previous or next reference card; past V1, the top.
        XCTAssertEqual(act(.reorder(up: true), .header(card: "T2")),
                       .place(PlaceMove(card: "T2", target: .review(.todo), position: .top, verb: .move)))
        XCTAssertEqual(act(.reorder(up: true), .header(card: "T3")),
                       .place(PlaceMove(card: "T3", target: .review(.todo), position: .before("T2"), verb: .move)))
        XCTAssertEqual(act(.reorder(up: false), .row(id: "A", card: "T1")),
                       .place(PlaceMove(card: "T1", target: .review(.todo), position: .before("T3"), verb: .move)))
        XCTAssertNil(act(.reorder(up: true), .header(card: "T1")), "the top")
        XCTAssertEqual(act(.reorder(up: false), .header(card: "T5")),
                       .place(PlaceMove(card: "T5", target: .review(.todo), position: .before("T7"), verb: .move)), "past muted T6, shown")
        XCTAssertEqual(act(.reorder(up: true), .header(card: "T7")),
                       .place(PlaceMove(card: "T7", target: .review(.todo), position: .before("T6"), verb: .move)), "a muted card shown moves")
        XCTAssertNil(act(.reorder(up: false), .header(card: "T7")), "the last")
        XCTAssertNil(act(.reorder(up: true), .header(card: "D1")), "Done")
        XCTAssertNil(act(.reorder(up: true), .header(card: "T2"), view(.all)), "All")
        XCTAssertEqual(act(.reorder(up: false), .header(card: "M1"), view(.mine)),
                       .place(PlaceMove(card: "M1", target: .mine(.todo), position: .bottom, verb: .move)))
        XCTAssertEqual(act(.reorder(up: true), .header(card: "M2"), view(.mine)),
                       .place(PlaceMove(card: "M2", target: .mine(.todo), position: .top, verb: .move)))
        // D / T / W in Review and Mine, also for a muted card.
        XCTAssertEqual(act(.moveTo(.doing), .header(card: "T1")),
                       .place(PlaceMove(card: "T1", target: .review(.doing), position: .byDefault, verb: .move)))
        XCTAssertEqual(act(.moveTo(.waiting), .header(card: "T7")),
                       .place(PlaceMove(card: "T7", target: .review(.waiting), position: .byDefault, verb: .move)))
        XCTAssertNil(act(.moveTo(.todo), .header(card: "T1")), "already there")
        XCTAssertEqual(act(.moveTo(.todo), .header(card: "D1")),
                       .place(PlaceMove(card: "D1", target: .review(.todo), position: .byDefault, verb: .move)), "out of Done")
        XCTAssertNil(act(.reorder(up: false), .header(card: "M3"), view(.mine)), "Mine's Done")
        XCTAssertEqual(act(.moveTo(.doing), .header(card: "M1"), view(.mine)),
                       .place(PlaceMove(card: "M1", target: .mine(.doing), position: .byDefault, verb: .move)), "Mine")
        XCTAssertEqual(act(.moveTo(.waiting), .row(id: "m1", card: "M1"), view(.mine)),
                       .place(PlaceMove(card: "M1", target: .mine(.waiting), position: .byDefault, verb: .move)), "a row's card")
        XCTAssertNil(act(.moveTo(.todo), .header(card: "M1"), view(.mine)), "already there")
        XCTAssertEqual(act(.moveTo(.todo), .header(card: "M3"), view(.mine)),
                       .place(PlaceMove(card: "M3", target: .mine(.todo), position: .byDefault, verb: .move)), "out of Mine's Done")
        XCTAssertNil(act(.moveTo(.todo), .header(card: "N1"), view(.all)), "All")
        XCTAssertNil(act(.moveTo(.doing), .header(card: "M1"), view(.all)), "All, a card placed in Mine")
        XCTAssertNil(act(.moveTo(.doing), .header(card: "T1"), view(.all)), "All, a card placed in Review")
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
        let menu = PopoverLogic.menu(for: .header(card: "T1"), view: view(.review), login: "bufferings-work")
        XCTAssertEqual(titles(menu), [
            "Open on GitHub", "Copy link", "-", "Move to Doing", "Move to Waiting", "Move to Done", "Remove from Review", "-",
            "Mute this pull request", "Mute example-org/api", "Mute @al", "-", "Dismiss", "-", "Mark all as read",
        ])
        XCTAssertEqual(menu[3]?.action, .place(PlaceMove(card: "T1", target: .review(.doing), position: .byDefault, verb: .move)))
        XCTAssertEqual(menu[5]?.action, .place(PlaceMove(card: "T1", target: .review(.done), position: .byDefault, verb: .move)))
        XCTAssertEqual(menu[6]?.action, .place(PlaceMove(card: "T1", target: .none, position: .byDefault, verb: .remove)))
        XCTAssertEqual(menu[9]?.action, .mute(.repo, "example-org/api"))
    }

    /// An assigned card in Mine: no `Copy` item (no text can be selected).
    func testAnAssignedCardInMine() {
        let menu = PopoverLogic.menu(for: .header(card: "M2"), view: view(.all), login: "bufferings-work")
        XCTAssertEqual(titles(menu), [
            "Open on GitHub", "Copy link", "-", "Move to Doing", "Move to Waiting", "Move to Done", "Remove from Mine", "-",
            "Mute this pull request", "Mute acme-corp/web", "Mute @mk", "-", "Dismiss", "-", "Mark all as read",
        ])
        XCTAssertEqual(menu[3]?.action, .place(PlaceMove(card: "M2", target: .mine(.doing), position: .byDefault, verb: .move)))
        XCTAssertEqual(menu[4]?.action, .place(PlaceMove(card: "M2", target: .mine(.waiting), position: .byDefault, verb: .move)))
        XCTAssertEqual(menu[5]?.action, .place(PlaceMove(card: "M2", target: .mine(.done), position: .byDefault, verb: .move)))
        XCTAssertFalse(titles(menu).contains("Move to Mine"))
    }

    /// A card in Done moves out and is removed like any other (DESIGN.md,
    /// "Review" and the mouse table of "Keyboard").
    func testACardInDone() {
        let all = view(.all)
        func items(_ id: String) -> [MenuEntry?] {
            PopoverLogic.menu(for: .header(card: id), view: all, login: "bufferings-work")
        }
        let d1 = items("D1")
        XCTAssertEqual(Array(titles(d1)[2...7]), ["-", "Move to Doing", "Move to Todo", "Move to Waiting", "Remove from Review", "-"])
        XCTAssertEqual(d1[4]?.action, .place(PlaceMove(card: "D1", target: .review(.todo), position: .byDefault, verb: .move)))
        let m3 = items("M3")
        XCTAssertEqual(Array(titles(m3)[2...6]), ["-", "Move to Doing", "Move to Todo", "Move to Waiting", "-"], "your own PR stays in Mine")
        XCTAssertEqual(m3[4]?.action, .place(PlaceMove(card: "M3", target: .mine(.todo), position: .byDefault, verb: .move)))
    }

    func testPlacementItemsLeaveOutWhatDoesNotApply() {
        let all = view(.all)
        func items(_ id: String) -> [String] {
            titles(PopoverLogic.menu(for: .header(card: id), view: all, login: "bufferings-work"))
        }
        XCTAssertFalse(items("M1").contains("Remove from Mine"), "your own PR stays in Mine")
        XCTAssertFalse(items("M1").contains { $0.hasPrefix("Mute @") }, "no Mute @<your login>")
        XCTAssertTrue(items("M1").contains("Mute example-org/api"))
        XCTAssertTrue(items("N1").contains("Add to Review"))
        XCTAssertTrue(items("N1").contains("Add to Mine"))
        let menu = PopoverLogic.menu(for: .header(card: "N1"), view: all, login: "x")
        XCTAssertEqual(menu[3]?.action, .place(PlaceMove(card: "N1", target: .review(.todo), position: .byDefault, verb: .add)))
        XCTAssertEqual(menu[4]?.action, .place(PlaceMove(card: "N1", target: .mine(.todo), position: .byDefault, verb: .add)))
        let own = card("O", authored: true)
        let ownMenu = titles(PopoverLogic.menu(for: .header(card: "O"), view: view(.all, cards: [own]), login: "x"))
        XCTAssertFalse(ownMenu.contains("Add to Review"), "your own PR is never in Review")
        XCTAssertTrue(ownMenu.contains("Add to Mine"))
        let t7 = titles(PopoverLogic.menu(for: .header(card: "T7"), view: view(.review), login: "x"))
        XCTAssertTrue(t7.contains("Unmute this pull request"))
        XCTAssertTrue(t7.contains("Mute example-org/api"))
        XCTAssertTrue(t7.contains("Unmute @example-bot"))
    }

    /// Main.html, "Right-click on a row".
    func testARowMenu() {
        let review = view(.review)
        let menu = PopoverLogic.menu(for: .row(id: "A", card: "T1"), view: review, login: "bufferings-work")
        XCTAssertEqual(titles(menu), ["Open on GitHub", "Copy link", "-", "Mute @al", "-", "Mark all as read"])
        XCTAssertEqual(menu[0]?.action, .open("https://github.com/c/A", read: "A"))
        XCTAssertEqual(titles(PopoverLogic.menu(for: .row(id: "A", card: "T1"), view: review, login: "AL")),
                       ["Open on GitHub", "Copy link", "-", "Mark all as read"], "your own row")
        XCTAssertEqual(titles(PopoverLogic.menu(for: .row(id: "r1", card: "R1"), view: review, login: "x")),
                       ["Open on GitHub", "Copy link", "-", "Mark all as read"], "no actor")
        XCTAssertEqual(PopoverLogic.menu(for: .row(id: "A", card: "T1"), view: review, login: "x", mutes: Mutes(users: ["Al"]))[3]?.action,
                       .unmute(.user, "al"))
        XCTAssertEqual(PopoverLogic.menu(for: .section("review|todo"), view: review, login: "x"), [])
    }

    func testADismissedCardMenu() {
        let menu = PopoverLogic.menu(for: .header(card: "X1"), view: view(nil), login: "x")
        XCTAssertEqual(titles(menu), ["Open on GitHub", "Copy link", "-", "Restore"])
        XCTAssertEqual(menu[3]?.action, .restore(card: "X1"))
    }
}

final class CardMoveTests: XCTestCase {
    func testWhereADropLands() {
        let sections = layout(.review)
        XCTAssertEqual(CardDrop.target(.card("T3", lowerHalf: false), sections: sections), DropTarget(section: "review|todo", position: .before("T3")))
        XCTAssertEqual(CardDrop.target(.card("T3", lowerHalf: true), sections: sections), DropTarget(section: "review|todo", position: .before("T4")))
        XCTAssertEqual(CardDrop.target(.card("T5", lowerHalf: true), sections: sections), DropTarget(section: "review|todo", position: .before("T6")),
                       "the lower half of the last shown: before the first folded")
        XCTAssertEqual(CardDrop.target(.card("T6", lowerHalf: false), sections: sections), DropTarget(section: "review|todo", position: .before("T6")),
                       "a muted card shown is a place like the others")
        XCTAssertEqual(CardDrop.target(.card("T7", lowerHalf: true), sections: sections), DropTarget(section: "review|todo", position: .bottom))
        XCTAssertEqual(CardDrop.target(.header("review|doing"), sections: sections), DropTarget(section: "review|doing", position: .top),
                       "a heading: the top")
        let first = sections[1].matching[0].id
        XCTAssertEqual(CardDrop.target(.card(first, lowerHalf: false), sections: sections), DropTarget(section: "review|todo", position: .top),
                       "the first card's upper half: the top")
        XCTAssertEqual(CardDrop.target(.more("review|todo"), sections: sections), DropTarget(section: "review|todo", position: .before("T6")),
                       "+ N more PRs: right after the last card shown")
        let collapsed = layout(.review, collapsed: ["review|waiting"])
        XCTAssertEqual(CardDrop.target(.header("review|waiting"), sections: collapsed), DropTarget(section: "review|waiting", position: .top))
        XCTAssertEqual(CardDrop.target(.header("review|done"), sections: sections), DropTarget(section: "review|done", position: .byDefault),
                       "Done by its own order")
        XCTAssertEqual(CardDrop.target(.card("D1", lowerHalf: false), sections: sections), DropTarget(section: "review|done", position: .byDefault))
        XCTAssertEqual(CardDrop.target(.card("M3", lowerHalf: true), sections: layout(.mine)), DropTarget(section: "mine|done", position: .byDefault))
        XCTAssertNil(CardDrop.target(.card("T1", lowerHalf: false), sections: layout(.all)), "no drag in All")
        XCTAssertEqual(CardDrop.target(.card("M2", lowerHalf: false), sections: layout(.mine)), DropTarget(section: "mine|todo", position: .before("M2")))
        XCTAssertEqual(CardDrop.target(.card("M1", lowerHalf: false), sections: layout(.mine)), DropTarget(section: "mine|todo", position: .top))
        XCTAssertEqual(CardDrop.target(.header("mine|doing"), sections: layout(.mine)), DropTarget(section: "mine|doing", position: .top),
                       "an empty section of Mine")
        XCTAssertEqual(CardDrop.target(.header("mine|waiting"), sections: layout(.mine)), DropTarget(section: "mine|waiting", position: .top))
        XCTAssertEqual(CardDrop.target(.header("mine|done"), sections: layout(.mine)), DropTarget(section: "mine|done", position: .byDefault))
    }

    func testTheLine() {
        let todo = layout(.review)[1]
        XCTAssertEqual(CardDrop.lineAbove(DropTarget(section: todo.key, position: .before("T3")), in: todo), "T3")
        XCTAssertNil(CardDrop.lineAbove(DropTarget(section: todo.key, position: .bottom), in: todo), "above + 2 more PRs")
        XCTAssertEqual(CardDrop.lineAbove(DropTarget(section: todo.key, position: .top), in: todo), todo.cards.first?.id, "the top")
        let open = layout(.review, expanded: ["review|todo"])[1]
        XCTAssertNil(CardDrop.lineAbove(DropTarget(section: open.key, position: .bottom), in: open), "below the last card")
        XCTAssertEqual(CardDrop.lineAbove(DropTarget(section: open.key, position: .before("T6")), in: open), "T6")
        XCTAssertNil(CardDrop.lineAbove(DropTarget(section: todo.key, position: .before("T6")), in: todo), "a folded card: the end")
        let done = layout(.review)[3]
        XCTAssertEqual(CardDrop.lineAbove(DropTarget(section: done.key, position: .byDefault), in: done), "D1", "Done: the top")
    }

    func testADropBecomesAPlaceAndTheSameSpotNothing() {
        let cards = sampleCards()
        let t2 = cards[2]
        XCTAssertNil(CardDrop.move(t2, to: DropTarget(section: "review|todo", position: .before("T3")), cards: cards))
        XCTAssertEqual(CardDrop.move(t2, to: DropTarget(section: "review|todo", position: .before("T5")), cards: cards),
                       PlaceMove(card: "T2", target: .review(.todo), position: .before("T5"), verb: .move))
        XCTAssertNil(CardDrop.move(cards[7], to: DropTarget(section: "review|todo", position: .bottom), cards: cards), "T7 is the last already")
        XCTAssertEqual(CardDrop.move(cards[5], to: DropTarget(section: "review|todo", position: .bottom), cards: cards),
                       PlaceMove(card: "T5", target: .review(.todo), position: .bottom, verb: .move), "past the muted cards")
        XCTAssertEqual(CardDrop.move(cards[0], to: DropTarget(section: "review|todo", position: .bottom), cards: cards),
                       PlaceMove(card: "R1", target: .review(.todo), position: .bottom, verb: .move))
        XCTAssertEqual(CardDrop.move(cards[11], to: DropTarget(section: "mine|todo", position: .before("M1")), cards: cards),
                       PlaceMove(card: "M2", target: .mine(.todo), position: .before("M1"), verb: .move))
        XCTAssertEqual(CardDrop.move(cards[11], to: DropTarget(section: "mine|doing", position: .top), cards: cards),
                       PlaceMove(card: "M2", target: .mine(.doing), position: .top, verb: .move))
        XCTAssertEqual(CardDrop.move(cards[11], to: DropTarget(section: "mine|waiting", position: .top), cards: cards),
                       PlaceMove(card: "M2", target: .mine(.waiting), position: .top, verb: .move))
        // Into Done: no position; a card in Done stays where Done puts it.
        XCTAssertEqual(CardDrop.move(t2, to: DropTarget(section: "review|done", position: .byDefault), cards: cards),
                       PlaceMove(card: "T2", target: .review(.done), position: .byDefault, verb: .move))
        XCTAssertEqual(CardDrop.move(cards[11], to: DropTarget(section: "mine|done", position: .byDefault), cards: cards),
                       PlaceMove(card: "M2", target: .mine(.done), position: .byDefault, verb: .move))
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
        // From elsewhere: the bottom, muted cards or not.
        moved = place("N1", .review(.todo))
        XCTAssertEqual(order(moved, "review|todo"), ["T1", "T2", "T3", "T4", "T5", "T6", "T7", "N1"])
        // A muted card moves like the others.
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
        let added = LocalChange.place(PlaceMove(card: "Z", target: .mine(.todo), position: .byDefault, verb: .add)).apply(cards + [closed])
        XCTAssertEqual(order(added, "mine|done"), ["Z", "M3"])
        // Into Done: the top, newest entry first; out of Done: no automatic
        // Dismiss any more.
        moved = place("T3", .review(.done))
        XCTAssertEqual(order(moved, "review|done"), ["T3", "D1"])
        XCTAssertEqual(order(moved, "review|todo"), ["T1", "T2", "T4", "T5", "T6", "T7"])
        moved = place("M2", .mine(.done))
        XCTAssertEqual(order(moved, "mine|done"), ["M2", "M3"])
        var due = cards
        due[due.firstIndex { $0.id == "D1" }!].autoDismissAt = T0 + 86_400
        moved = LocalChange.place(PlaceMove(card: "D1", target: .review(.todo), position: .byDefault, verb: .move)).apply(due)
        XCTAssertEqual(order(moved, "review|todo"), ["T1", "T2", "T3", "T4", "T5", "T6", "T7", "D1"], "from Done: the bottom")
        XCTAssertNil(moved.first { $0.id == "D1" }?.autoDismissAt)
    }

    /// Mine's moves shown at once follow the same rules as Review's: to
    /// Todo at the top from Doing or Waiting of the same tab, else at the
    /// bottom (DESIGN.md, "Mine", "Wire format").
    func testAMoveInMineShownAtOnceFollowsThePlaceRules() {
        var cards = sampleCards()
        cards.append(card("MD", pr: "example-org/api#430", authored: true, placement: mine(.doing, 0)))
        cards.append(card("MW", pr: "example-org/api#431", authored: true, placement: mine(.waiting, 0)))
        func place(_ id: String, _ target: PlaceTarget, _ position: PlacePosition = .byDefault) -> [Card] {
            LocalChange.place(PlaceMove(card: id, target: target, position: position, verb: .move)).apply(cards)
        }
        XCTAssertEqual(order(place("MD", .mine(.todo)), "mine|todo"), ["MD", "M1", "M2"], "from Mine's Doing: the top")
        XCTAssertEqual(order(place("MW", .mine(.todo)), "mine|todo"), ["MW", "M1", "M2"], "from Mine's Waiting: the top")
        XCTAssertEqual(order(place("M3", .mine(.todo)), "mine|todo"), ["M1", "M2", "M3"], "from Done: the bottom")
        XCTAssertEqual(order(place("R1", .mine(.todo)), "mine|todo"), ["M1", "M2", "R1"], "from Review's Doing: the bottom")
        XCTAssertEqual(order(place("N1", .mine(.todo)), "mine|todo"), ["M1", "M2", "N1"], "without a placement: the bottom")
        XCTAssertEqual(order(place("MW", .review(.todo)), "review|todo").last, "MW", "from Mine's Waiting to Review: the bottom")
        XCTAssertEqual(order(place("M1", .mine(.doing)), "mine|doing"), ["MD", "M1"], "to Doing: the bottom")
        XCTAssertEqual(order(place("M2", .mine(.waiting), .top), "mine|waiting"), ["M2", "MW"])
        let done = place("M1", .mine(.done))
        XCTAssertEqual(order(done, "mine|done"), ["M1", "M3"])
        XCTAssertEqual(done.first { $0.id == "M1" }?.placement?.section.value, .done)
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
        XCTAssertEqual(order(repo, "review|todo"), ["T1", "T2", "T3", "T4", "T5", "T6", "T7"], "a mute moves no card")
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
        let unmuted = LocalChange.unmute(.user, "example-bot").apply(cards)
        XCTAssertEqual(unmuted[6].muted, [])
        XCTAssertEqual(unmuted[6].rows[0].muted, false)
        XCTAssertEqual(unmuted[7].muted, [.known(.pr)], "still muted by itself")
        let pr = LocalChange.mute(.pr, "acme-corp/web#80").apply(cards)
        XCTAssertEqual(pr[13].muted, [.known(.pr)])
        XCTAssertEqual(pr[13].prMute, .known(.mute))
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

/// `Dismiss all` on the heading of Done (DESIGN.md, "Dismiss", "`Dismiss
/// all`"; "Section size").
final class DismissAllTargetTests: XCTestCase {
    /// Review's Done: D1 and E1–E5 merged, E6 merged and muted (its author
    /// muted).
    func doneCards() -> [Card] {
        var cards = sampleCards()
        for n in 1...6 {
            cards.append(card("E\(n)", pr: "example-org/web#\(300 + n)", author: n == 6 ? "example-bot" : "ts", state: .merged,
                              placement: review(.done, n), muted: n == 6 ? [.author] : []))
        }
        return cards
    }

    func done(_ tab: ListTab = .review, cards: [Card]? = nil, filter: ListFilter = mutedHidden, search: String = "",
              collapsed: Set<String> = [], expanded: Set<String> = []) -> SectionLayout? {
        layout(tab, cards: cards ?? doneCards(), collapsed: collapsed, expanded: expanded, search: search, filter: filter).first { $0.isDone }
    }

    func testTheCardsAreThoseTheFilterAndTheSearchLeaveFoldedOnesIncluded() {
        let section = done()!
        XCTAssertEqual(section.cards.count, 5, "five shown, one folded")
        XCTAssertEqual(section.more, 1)
        XCTAssertEqual(section.dismissAllCards?.map(\.id), ["D1", "E1", "E2", "E3", "E4", "E5"], "the folded one too, not muted E6")
        XCTAssertEqual(section.detail, "6 PRs")
        XCTAssertEqual(done(filter: mutedShown)?.dismissAllCards?.count, 7, "the Filter shows the muted one")
        // The search leaves fewer cards than the heading counts.
        let searched = done(search: "web#30")!
        XCTAssertEqual(searched.dismissAllCards?.map(\.id), ["E1", "E2", "E3", "E4", "E5"])
        XCTAssertEqual(searched.detail, "6 PRs", "the count ignores the search")
        // `Unread only` keeping read cards: they are shown, so they are taken.
        let kept = layout(.review, cards: doneCards(), filter: ListFilter(unreadOnly: true), kept: ["E2", "E3"]).first { $0.isDone }
        XCTAssertEqual(kept?.dismissAllCards?.map(\.id), ["E2", "E3"])
    }

    /// Two or more cards: one card has its own ×, which does the same.
    func testItShowsForTwoCardsOrMore() {
        let one = sampleCards().filter { $0.id == "D1" }
        let two = one + [card("E1", pr: "example-org/web#301", state: .merged, placement: review(.done, 1))]
        XCTAssertNil(done(cards: one)?.dismissAllCards, "one card")
        XCTAssertEqual(done(cards: two)?.dismissAllCards?.map(\.id), ["D1", "E1"], "two cards")
        XCTAssertNil(done(search: "web#303")?.dismissAllCards, "the search leaves one")
        XCTAssertNil(done(filter: ListFilter(statuses: [.closed]))?.dismissAllCards, "the Filter leaves none")
        var closed = doneCards()
        closed[closed.firstIndex { $0.id == "E1" }!].stateLabel = .known(.closed)
        XCTAssertNil(done(cards: closed, filter: ListFilter(statuses: [.closed]))?.dismissAllCards, "the Filter leaves one")
        // Folded cards count: five shown, one folded behind "+ 1 more PR".
        let six = done()!
        XCTAssertEqual(six.cards.count, 5)
        XCTAssertEqual(six.dismissAllCards?.count, 6)
    }

    func testItShowsOnlyOnAnOpenDoneWithCards() {
        XCTAssertNil(done(collapsed: ["review|done"])?.dismissAllCards, "collapsed")
        XCTAssertNil(done(filter: ListFilter(statuses: [.open]))?.dismissAllCards, "the Filter leaves no card: an empty Done")
        XCTAssertNotNil(done(filter: ListFilter(statuses: [.open])), "the empty Done still shows")
        XCTAssertNil(done(search: "zzz"), "no match: no section")
        let sections = layout(.review, cards: doneCards())
        XCTAssertEqual(sections.map { $0.dismissAllCards != nil }, [false, false, false, true], "Done only")
        XCTAssertNil(layout(.all, cards: doneCards()).first { $0.dismissAllCards != nil }, "not in All")
        XCTAssertNil(done(.mine, cards: sampleCards())?.dismissAllCards, "Mine's Done with one card")
        let m4 = card("M4", authored: true, state: .merged, placement: mine(.done, 1))
        XCTAssertEqual(done(.mine, cards: sampleCards() + [m4])?.dismissAllCards?.map(\.id), ["M3", "M4"], "Mine's Done too")
        XCTAssertEqual(done(expanded: ["review|done"])?.dismissAllCards?.count, 6, "expanded: the same cards")
    }

    func testTheConfirmationTexts() {
        XCTAssertEqual(DismissedText.confirmAllTitle(count: 12), "Dismiss 12 pull requests?")
        XCTAssertEqual(DismissedText.confirmAllTitle(count: 2), "Dismiss 2 pull requests?")
        XCTAssertEqual(DismissedText.confirmAllText(keepDays: 7),
                       "They move to the Dismissed list and are removed after 7 days. You can restore them from there.")
        XCTAssertEqual(DismissedText.confirmAllText(keepDays: 1),
                       "They move to the Dismissed list and are removed after 1 day. You can restore them from there.")
        XCTAssertEqual(DismissConfirmation.all(section: "review|done", cards: ["a", "b"]).title, "Dismiss 2 pull requests?")
        XCTAssertEqual(DismissConfirmation.card("a").title, "Dismiss this pull request?")
        XCTAssertEqual(DismissConfirmation.card("a").text(keepDays: 7), DismissedText.confirmText(keepDays: 7))
        XCTAssertEqual(DismissedText.dismissAll, "Dismiss all")
        XCTAssertEqual(SettingsText.confirmDismissDetail, "Asks when you press × on a card or Dismiss all")
    }
}

/// The Dismissed list by repository (DESIGN.md, "Dismissed list").
final class DismissedGroupTests: XCTestCase {
    func dismissed(_ id: String, _ pr: String, at: Int64) -> Card {
        card(id, pr: pr, dismissedAt: at, expires: at + 7 * 86_400)
    }

    func testTheGroupsAndTheirOrder() {
        let cards = [
            dismissed("a1", "example-org/api#1", at: 100),
            dismissed("w1", "example-org/web#1", at: 300),
            dismissed("a2", "example-org/api#2", at: 200),
            dismissed("i1", "acme-corp/infra#1", at: 50),
            dismissed("w2", "example-org/web#2", at: 10),
            card("open", pr: "example-org/api#9"),
        ]
        let groups = Listing.dismissedGroups(cards, search: "")
        XCTAssertEqual(groups.map(\.repository), ["example-org/web", "example-org/api", "acme-corp/infra"], "by the newest dismissal in each")
        XCTAssertEqual(groups.map(\.detail), ["2 PRs", "2 PRs", "1 PR"])
        XCTAssertEqual(groups.map { $0.cards.map(\.id) }, [["w1", "w2"], ["a2", "a1"], ["i1"]], "newest first inside")
    }

    func testTheSameTimeGoesByNameIgnoringCase() {
        let cards = [
            dismissed("b", "Beta/app#1", at: 100),
            dismissed("a", "alpha/app#1", at: 100),
            dismissed("c", "charlie/app#1", at: 100),
            dismissed("c2", "charlie/app#2", at: 100),
            dismissed("c1", "charlie/app#3", at: 100),
        ]
        let groups = Listing.dismissedGroups(cards, search: "")
        XCTAssertEqual(groups.map(\.repository), ["alpha/app", "Beta/app", "charlie/app"])
        XCTAssertEqual(groups[2].cards.map(\.id), ["c", "c1", "c2"], "the same time: by id, as 0.5")
    }

    func testTheSearchLeavesOutGroupsButNotTheCountsNorTheOrder() {
        let cards = [
            dismissed("w1", "example-org/web#1", at: 300),
            dismissed("a1", "example-org/api#1", at: 200),
            dismissed("a2", "example-org/api#2", at: 100),
        ]
        var titled = cards
        titled[2].title = "Fix the retry"
        let groups = Listing.dismissedGroups(titled, search: "retry")
        XCTAssertEqual(groups.map(\.repository), ["example-org/api"], "a group with no match is left out")
        XCTAssertEqual(groups[0].detail, "2 PRs", "the count ignores the search")
        XCTAssertEqual(groups[0].cards.map(\.id), ["a2"])
        // The order comes from every card: a1 keeps api's place.
        let both = Listing.dismissedGroups(titled, search: "example-org")
        XCTAssertEqual(both.map(\.repository), ["example-org/web", "example-org/api"])
        XCTAssertEqual(Listing.dismissedGroups([], search: ""), [])
    }

    /// ↑↓ go from card to card across the groups; the headings are not
    /// items (DESIGN.md, "Selection and keys").
    func testTheArrowsSkipTheHeadings() {
        let cards = [
            dismissed("w1", "example-org/web#1", at: 300),
            dismissed("a1", "example-org/api#1", at: 200),
            dismissed("w2", "example-org/web#2", at: 100),
        ]
        let items = PopoverLogic.items(view(nil, cards: cards))
        XCTAssertEqual(items, [.header(card: "w1"), .header(card: "w2"), .header(card: "a1")])
        XCTAssertEqual(PopoverLogic.move(.header(card: "w2"), up: false, in: items), .header(card: "a1"))
        XCTAssertEqual(PopoverLogic.move(.header(card: "a1"), up: true, in: items), .header(card: "w2"))
    }
}
