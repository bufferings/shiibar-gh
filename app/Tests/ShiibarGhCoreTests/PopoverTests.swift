import Foundation
@testable import ShiibarGhCore
import XCTest

/// bufferings-work with example-org (o2), acme-corp (o3) and Public (o4).
func sampleAccount(disabled: Set<String> = []) -> Account {
    Account(
        id: "3407303", login: "bufferings-work", color: .red, reviewCount: 1, unread: true,
        owners: [
            Owner(id: "o2", name: "example-org", kind: .org, enabled: !disabled.contains("o2"), reviewCount: 1, prCount: 4),
            Owner(id: "o3", name: "acme-corp", kind: .org, enabled: !disabled.contains("o3"), reviewCount: 0, prCount: 1),
            Owner(id: "o4", name: "public", kind: .public, enabled: !disabled.contains("o4"), reviewCount: 0, prCount: 0),
        ]
    )
}

func row(_ id: String, pr: String, owner: String = "o2", kind: RowKind = .comment, text: String? = nil, actor: String? = nil, unread: Bool = false) -> Row {
    Row(id: id, pr: pr, owner: owner, kind: kind, text: text, actor: actor, url: "https://github.com/c/\(id)", unread: unread)
}

/// example-org: C1 (unread row A), C2 (read), C3 (waiting for your review),
/// C4 (merged, newest); acme-corp: C5 (authored, unread row G).
func sampleCards() -> [Card] {
    [
        Card(id: "C1", pr: "example-org/api#407", owner: "o2", title: "Limit comment fetching", url: "https://github.com/p/1",
             author: "al", authoredByMe: false, assignedToMe: true, addedAt: T0 - 500, updatedAt: T0 - 100,
             rows: [row("A", pr: "example-org/api#407", kind: .mentioned, text: "could you check the retry path?", actor: "al", unread: true),
                    row("B", pr: "example-org/api#407", text: "pushed a fix", actor: "al")]),
        Card(id: "C2", pr: "example-org/api#5", owner: "o2", title: "Bump deps", url: "https://github.com/p/2",
             author: "renovate", authoredByMe: false, addedAt: T0 - 900, updatedAt: T0 - 50,
             rows: [row("D", pr: "example-org/api#5")]),
        Card(id: "C3", pr: "example-org/web#212", owner: "o2", title: "Add dark mode", url: "https://github.com/p/3",
             author: "mk", authoredByMe: false, reviewRequested: true, awaitingReview: true, base: "main", head: "feat/dark-settings",
             addedAt: T0 - 100, updatedAt: T0 - 300,
             rows: [row("E", pr: "example-org/web#212", kind: .teamReviewRequested, text: "for frontend team")]),
        Card(id: "C4", pr: "example-org/web#9", owner: "o2", title: "Old one", url: "https://github.com/p/4",
             author: "mk", authoredByMe: false, stateLabel: .merged, addedAt: T0 - 50, updatedAt: T0, rows: []),
        Card(id: "C5", pr: "acme-corp/billing#88", owner: "o3", title: "Billing", url: "https://github.com/p/5",
             author: "bufferings-work", authoredByMe: true, addedAt: T0 - 10, updatedAt: T0 - 10,
             rows: [row("G", pr: "acme-corp/billing#88", owner: "o3", unread: true)]),
    ]
}

func snoozedCards() -> [Card] {
    [
        Card(id: "S1", pr: "example-org/api#1", owner: "o2", url: "https://github.com/p/s1", authoredByMe: false,
             snoozed: true, snoozedUntil: 1_800_090_000, updatedAt: T0 - 5, rows: [row("H", pr: "example-org/api#1", unread: true)]),
        Card(id: "S2", pr: "acme-corp/ops#2", owner: "o3", url: "https://github.com/p/s2", authoredByMe: true,
             snoozed: true, snoozedUntil: 1_800_090_000, updatedAt: T0 - 6),
    ]
}

/// The fold as decided when the popover opened with `cards`.
func decided(_ cards: [Card] = sampleCards()) -> FoldState {
    var fold = FoldState()
    fold.decide(cards)
    return fold
}

func sections(
    _ options: ListOptions = ListOptions(), search: String = "", cards: [Card] = sampleCards(), snoozed: [Card] = snoozedCards(),
    collapsed: [String: Bool] = [:], expanded: Set<String> = [], fold: FoldState? = nil, account: Account = sampleAccount()
) -> [SectionLayout] {
    Listing.sections(
        account: account, cards: cards, snoozed: snoozed, options: options, search: search,
        collapsed: collapsed, expanded: expanded, fold: fold ?? decided(cards), timeZone: utc
    )
}

final class SearchTests: XCTestCase {
    /// The example table of DESIGN.md, "What the filters mean", shared with
    /// the daemon's `search_follows_the_examples_of_the_design`.
    func testTheDesignExamples() {
        let card = sampleCards()[0]
        for text in ["api 407", "#407", "api #407", "API", "example-org/api#407"] {
            XCTAssertTrue(Search.matches(card, words: Search.words(text)), text)
        }
        XCTAssertFalse(Search.matches(card, words: Search.words("api #408")))
    }

    func testEveryWordMatchesSomeField() {
        let card = sampleCards()[2]
        XCTAssertTrue(Search.matches(card, words: Search.words("dark mk")), "title and author")
        XCTAssertTrue(Search.matches(card, words: Search.words("feat/dark MAIN")), "head and base")
        XCTAssertTrue(Search.matches(card, words: Search.words("frontend")), "a row's text")
        XCTAssertTrue(Search.matches(sampleCards()[0], words: Search.words("retry al")), "a row's text and actor")
        XCTAssertFalse(Search.matches(card, words: Search.words("dark nothing")))
        XCTAssertTrue(Search.matches(card, words: Search.words("   ")), "no words: no filter")
        XCTAssertEqual(Search.words(" Api\u{3000}#407\t"), ["api", "#407"], "split on Unicode white space")
    }

    func testAnActivityRowMatchesWithItsPRAndItsOwnTextOnly() {
        let card = sampleCards()[0]
        let a = card.rows[0], b = card.rows[1]
        XCTAssertTrue(Search.matches(a, card: card, words: Search.words("retry")))
        XCTAssertFalse(Search.matches(b, card: card, words: Search.words("retry")), "another row's text does not count")
        XCTAssertTrue(Search.matches(b, card: card, words: Search.words("api #407 fix")))
        XCTAssertTrue(Search.matches(b, card: nil, words: Search.words("example-org/api#407")), "without the card, pr stands in")
    }
}

final class ListingTests: XCTestCase {
    func testChips() {
        let cards = sampleCards()
        XCTAssertEqual(cards.filter(PrFilter.all.admits).count, 5)
        XCTAssertEqual(cards.filter(PrFilter.authored.admits).map(\.id), ["C5"])
        XCTAssertEqual(cards.filter(PrFilter.assigned.admits).map(\.id), ["C1"])
        XCTAssertEqual(cards.filter(PrFilter.reviewRequested.admits).map(\.id), ["C3"])
        XCTAssertEqual(PrFilter.allCases.map(ListOptions.title), ["All", "Authored by me", "Assigned to me", "Review requested"])
        XCTAssertEqual(GroupBy.allCases.map(\.title), ["Owner", "Repository", "Status", "Involvement", "None"])
        XCTAssertEqual(SortOrder.allCases.map(\.title), ["Recently updated", "Recently added"])
        XCTAssertEqual(ListOptions(), ListOptions(segment: .all, groupBy: .owner, sort: .recentlyUpdated))
    }

    func testOptionsSavedBy02KeepTheirChip() throws {
        let old = try JSONDecoder().decode(ListOptions.self, from: Data(#"{"todo":true,"segment":"assigned"}"#.utf8))
        XCTAssertEqual(old, ListOptions(segment: .assigned))
    }

    func testGroupByOwnerFoldsAndPutsSnoozedLast() {
        let s = sections()
        XCTAssertEqual(s.map(\.title), ["example-org", "acme-corp", "Snoozed"], "Public has no card, so no section")
        XCTAssertEqual(s.map(\.reviewCount), [1, nil, nil])
        XCTAssertEqual(s.map(\.detail), ["4 PRs", "1 PR", "2 PRs · until Sat 09:00"])
        XCTAssertEqual(s[0].matching.map(\.id), ["C2", "C1", "C3", "C4"], "open first, newest update first, Merged after")
        XCTAssertEqual(s[0].cards.map(\.id), ["C1", "C3"], "unread or waiting for your review")
        XCTAssertEqual(s[0].moreText, "+ 2 more PRs")
        XCTAssertEqual(s[1].cards.map(\.id), ["C5"])
        XCTAssertNil(s[1].moreText)
        XCTAssertTrue(s[2].collapsed, "Snoozed starts collapsed")
        XCTAssertEqual(s[2].cards, [])
        XCTAssertEqual(s[2].more, 0)
        XCTAssertTrue(s.allSatisfy(\.showsHeader))
    }

    func testRecentlyAddedSortsByTheAddTimeWithOpenPRsFirst() {
        let s = sections(ListOptions(sort: .recentlyAdded), expanded: ["owner:o2"])
        XCTAssertEqual(s[0].cards.map(\.id), ["C3", "C1", "C2", "C4"])
        XCTAssertNil(s[0].moreText, "expanded")
    }

    func testGroupByRepositoryStatusAndInvolvement() {
        let repo = sections(ListOptions(groupBy: .repository), expanded: ["repo:example-org/api", "repo:example-org/web"])
        XCTAssertEqual(repo.map(\.title), ["acme-corp/billing", "example-org/api", "example-org/web", "Snoozed"])
        XCTAssertEqual(repo[1].cards.map(\.id), ["C2", "C1"])
        XCTAssertEqual(repo.map(\.detail).prefix(3), ["1 PR", "2 PRs", "2 PRs"])

        var cards = sampleCards()
        cards[1].stateLabel = .known(.draft)
        cards[4].stateLabel = .known(.mergeable)
        let status = sections(ListOptions(groupBy: .status), cards: cards)
        XCTAssertEqual(status.map(\.title), ["Open", "Draft", "Merged", "Snoozed"], "Closed has no card")
        XCTAssertEqual(status[0].matching.map(\.id), ["C5", "C1", "C3"], "Mergeable is open")
        XCTAssertEqual(status[0].reviewCount, 1)

        let involvement = sections(ListOptions(groupBy: .involvement))
        XCTAssertEqual(involvement.map(\.title), ["Review requested", "Authored by me", "Assigned to me", "Others", "Snoozed"])
        XCTAssertEqual(involvement.map { $0.matching.map(\.id) }, [["C3"], ["C5"], ["C1"], ["C2", "C4"], ["S1", "S2"]])
    }

    func testAPRGoesToTheFirstInvolvementThatApplies() {
        var cards = sampleCards()
        cards[2].authoredByMe = true
        cards[2].assignedToMe = true
        cards[0].authoredByMe = true
        let s = sections(ListOptions(groupBy: .involvement), cards: cards)
        XCTAssertEqual(s[0].matching.map(\.id), ["C3"])
        XCTAssertEqual(s[1].matching.map(\.id), ["C5", "C1"])
        XCTAssertEqual(s.map(\.title).contains("Assigned to me"), false, "no card left for it")
    }

    func testGroupByNoneIsOneListWithoutHeaders() {
        let s = sections(ListOptions(groupBy: .none), collapsed: ["none|none": true, "none|snoozed": false])
        XCTAssertEqual(s.map(\.key), ["none", "snoozed"])
        XCTAssertFalse(s[0].showsHeader)
        XCTAssertFalse(s[0].collapsed, "the one list does not fold")
        XCTAssertEqual(s[0].matching.map(\.id), ["C5", "C2", "C1", "C3", "C4"])
        XCTAssertEqual(s[0].cards.map(\.id), ["C5", "C1", "C3"])
        let items = PopoverLogic.items(tab: .prs, sections: s, activity: [])
        XCTAssertEqual(items.map(\.id), [
            "header:C5", "row:G", "header:C1", "row:A", "row:B", "header:C3", "row:E", "more:none",
            "section:snoozed", "header:S1", "row:H", "header:S2",
        ])
    }

    func testCollapsingIsKeptPerGroupByAndSection() {
        XCTAssertEqual(Listing.collapseKey(.owner, "owner:o2"), "owner:o2", "the key of 0.2")
        XCTAssertEqual(Listing.collapseKey(.owner, "snoozed"), "snoozed")
        XCTAssertEqual(Listing.collapseKey(.status, "status:open"), "status|status:open")
        let folded = sections(collapsed: ["owner:o2": true, "snoozed": false])
        XCTAssertTrue(folded[0].collapsed)
        XCTAssertEqual(folded[0].cards, [])
        XCTAssertNil(folded[0].moreText)
        XCTAssertEqual(folded[0].matching.count, 4, "still counted for ⇧R")
        XCTAssertEqual(folded[2].cards.map(\.id), ["S1", "S2"], "Snoozed never folds into + N more")
        let status = sections(ListOptions(groupBy: .status), collapsed: ["owner:o2": true])
        XCTAssertFalse(status[0].collapsed, "another Group by has its own")
    }

    func testChipsAndSearchHideSectionsButNotTheirCounts() {
        let authored = sections(ListOptions(segment: .authored))
        XCTAssertEqual(authored.map(\.title), ["acme-corp", "Snoozed"])
        XCTAssertEqual(authored[0].detail, "1 PR")
        XCTAssertEqual(authored[1].detail, "2 PRs · until Sat 09:00", "Snoozed counts all")
        XCTAssertEqual(authored[1].matching.map(\.id), ["S2"], "chips apply in Snoozed")
        let search = sections(search: "api", collapsed: ["snoozed": false])
        XCTAssertEqual(search.map(\.title), ["example-org", "Snoozed"])
        XCTAssertEqual(search[0].detail, "4 PRs")
        XCTAssertEqual(search[0].reviewCount, 1, "the red count ignores the search")
        XCTAssertEqual(search[0].cards.map(\.id), ["C2", "C1"], "with a search nothing folds")
        XCTAssertEqual(search[1].cards.map(\.id), ["S1"])
        let chip = sections(ListOptions(segment: .assigned))
        XCTAssertEqual(chip[0].cards.map(\.id), ["C1"])
        let none = sections(search: "nothing-like-this")
        XCTAssertEqual(none.map(\.title), ["Snoozed"], "Snoozed keeps its until with no match")
        XCTAssertEqual(none[0].detail, "2 PRs · until Sat 09:00")
    }

    func testEmptyTexts() {
        XCTAssertNil(Listing.emptyText(loaded: false, cards: [], options: ListOptions(), search: ""))
        XCTAssertEqual(Listing.emptyText(loaded: true, cards: [], options: ListOptions(segment: .authored), search: "x"), "Nothing needs you")
        XCTAssertNil(Listing.emptyText(loaded: true, cards: sampleCards(), options: ListOptions(), search: ""))
        XCTAssertEqual(Listing.emptyText(loaded: true, cards: sampleCards(), options: ListOptions(), search: "zzz"), "Nothing matches")
        var others = sampleCards()
        others.removeAll { $0.reviewRequested }
        XCTAssertEqual(Listing.emptyText(loaded: true, cards: others, options: ListOptions(segment: .reviewRequested), search: ""), "Nothing matches")
        XCTAssertNil(Listing.activityEmptyText(loaded: true, all: [], shown: [row("x", pr: "a#1")]))
        XCTAssertEqual(Listing.activityEmptyText(loaded: true, all: [], shown: []), "No activity")
        XCTAssertEqual(Listing.activityEmptyText(loaded: true, all: [row("x", pr: "a#1")], shown: []), "Nothing matches")
    }

    /// DESIGN.md, "PRs tab sections": decided when the popover opens and
    /// when a PR first appears; while open, decisions only move toward
    /// shown.
    func testTheFoldIsDecidedOnOpenAndOnlyUnfoldsWhileOpen() {
        var cards = sampleCards()
        var fold = decided(cards)
        XCTAssertEqual(fold.unfolded, ["C1", "C3", "C5"])
        // The last unread row of C1 is read while open: C1 stays out.
        cards[0].rows[0].unread = false
        fold.update(cards)
        XCTAssertEqual(fold.unfolded, ["C1", "C3", "C5"])
        XCTAssertEqual(sections(cards: cards, fold: fold)[0].cards.map(\.id), ["C1", "C3"])
        // A new PR is decided when it shows up; a read one folds.
        cards.append(Card(id: "C6", pr: "example-org/api#6", owner: "o2", updatedAt: T0 + 1, rows: [row("N", pr: "example-org/api#6", unread: true)]))
        cards.append(Card(id: "C7", pr: "example-org/api#7", owner: "o2", updatedAt: T0 + 2))
        fold.update(cards)
        XCTAssertEqual(fold.unfolded, ["C1", "C3", "C5", "C6"])
        // A folded PR that gets a new unread row comes out at once.
        XCTAssertEqual(sections(cards: cards, fold: fold)[0].moreText, "+ 3 more PRs")
        cards[1].rows[0].unread = true
        fold.update(cards)
        XCTAssertTrue(fold.unfolded.contains("C2"))
        XCTAssertEqual(sections(cards: cards, fold: fold)[0].moreText, "+ 2 more PRs")
        // So does one that starts waiting for your review.
        cards[6].awaitingReview = true
        fold.update(cards)
        XCTAssertTrue(fold.unfolded.contains("C7"))
        // Closing decides again: C1, read now, folds.
        cards[1].rows[0].unread = false
        fold.decide(cards)
        XCTAssertEqual(fold.unfolded, ["C3", "C5", "C6", "C7"])
        // Opening decides again with the next list.
        cards[5].rows[0].unread = false
        fold.decideOnNextList()
        fold.update(cards)
        XCTAssertEqual(fold.unfolded, ["C3", "C5", "C7"])
    }

    func testActivityOwnersChipAndSearch() {
        let account = sampleAccount(disabled: ["o4"])
        let rows = sampleCards().flatMap(\.rows) + [row("Z", pr: "gone/x#1", owner: "o4")]
        let cards = sampleCards()
        func ids(_ segment: PrFilter = .all, owners: Set<String> = [], search: String = "") -> [String] {
            Listing.activity(rows, cards: cards, segment: segment, owners: ActivityOwners.effective(owners, account: account), search: search).map(\.id)
        }
        XCTAssertEqual(ids(), ["A", "B", "D", "E", "G", "Z"])
        XCTAssertEqual(ids(owners: ["o3"]), ["G"])
        XCTAssertEqual(ids(owners: ["o3", "o2"]), ["A", "B", "D", "E", "G"])
        XCTAssertEqual(ids(owners: ["o4", "removed"]), ["A", "B", "D", "E", "G", "Z"], "disabled and removed owners are ignored: all")
        XCTAssertEqual(ids(.reviewRequested), ["E"], "the chip applies by the row's PR")
        XCTAssertEqual(ids(search: "retry"), ["A"])
        XCTAssertEqual(ids(search: "api #407"), ["A", "B"])
    }

    func testAllOwners() {
        let account = sampleAccount(disabled: ["o4"])
        XCTAssertEqual(ActivityOwners.buttons(account).map(\.displayName), ["example-org", "acme-corp"])
        XCTAssertTrue(ActivityOwners.allOwnersOn([], account: account), "nothing remembered")
        XCTAssertTrue(ActivityOwners.allOwnersOn(["o4", "gone"], account: account), "disabled and removed are ignored")
        XCTAssertFalse(ActivityOwners.allOwnersOn(["o2"], account: account))
        XCTAssertFalse(ActivityOwners.allOwnersOn(["o2", "o3"], account: account), "every owner on one by one is not All owners")
    }

    /// DESIGN.md, "How unread clears": ⇧R reads what the tab shows after the
    /// chip, the search and the owner buttons; collapsed sections count,
    /// Snoozed does not.
    func testTheRowsMarkAllAsReadSends() {
        let s = sections(collapsed: ["owner:o2": true, "snoozed": false])
        XCTAssertEqual(Listing.rowsToRead(tab: .prs, sections: s, activity: []), ["A", "G"])
        let narrowed = sections(ListOptions(segment: .authored))
        XCTAssertEqual(Listing.rowsToRead(tab: .prs, sections: narrowed, activity: []), ["G"])
        let searched = sections(search: "retry")
        XCTAssertEqual(Listing.rowsToRead(tab: .prs, sections: searched, activity: []), ["A"])
        let activity = [row("x", pr: "a#1", unread: true), row("y", pr: "a#1"), row("z", pr: "a#1", unread: true)]
        XCTAssertEqual(Listing.rowsToRead(tab: .activity, sections: s, activity: activity), ["x", "z"])
    }
}

final class PopoverLogicTests: XCTestCase {
    func testTheSelectionWalksSectionsHeadersRowsAndMore() {
        let s = sections(collapsed: ["snoozed": false])
        let items = PopoverLogic.items(tab: .prs, sections: s, activity: [])
        XCTAssertEqual(items.map(\.id), [
            "section:owner:o2", "header:C1", "row:A", "row:B", "header:C3", "row:E", "more:owner:o2",
            "section:owner:o3", "header:C5", "row:G",
            "section:snoozed", "header:S1", "row:H", "header:S2",
        ])
        XCTAssertEqual(PopoverLogic.move(nil, up: false, in: items), items.first)
        XCTAssertEqual(PopoverLogic.move(nil, up: true, in: items), items.last)
        XCTAssertEqual(PopoverLogic.move(items[0], up: true, in: items), items[0], "stops at the top")
        let activity = sampleCards().flatMap(\.rows)
        XCTAssertEqual(PopoverLogic.items(tab: .activity, sections: s, activity: activity).map(\.id), activity.map { "row:" + $0.id })
        XCTAssertEqual(PopoverLogic.keep(.row(id: "A", card: "C1"), in: [.row(id: "A", card: nil)]), .row(id: "A", card: nil), "kept by the row id")
        XCTAssertNil(PopoverLogic.keep(.more("owner:o2"), in: []))
    }

    func testKeysTable() {
        let s = sections(collapsed: ["snoozed": false])
        func act(_ key: Key, _ item: SelectionItem?) -> PopoverAction? {
            PopoverLogic.action(for: key, selection: item, sections: s, activity: [])
        }
        XCTAssertEqual(act(.open, .section("owner:o2")), .toggleSection("owner:o2"))
        XCTAssertNil(act(.snooze, .section("owner:o2")))
        XCTAssertEqual(act(.open, .more("owner:o2")), .expand("owner:o2"))
        XCTAssertEqual(act(.open, .header(card: "C1")), .open("https://github.com/p/1", read: nil))
        XCTAssertEqual(act(.snooze, .header(card: "C1")), .snooze(pr: "example-org/api#407"))
        XCTAssertEqual(act(.snooze, .header(card: "S1")), .unsnooze(pr: "example-org/api#1"), "S in Snoozed unsnoozes")
        XCTAssertEqual(act(.open, .row(id: "A", card: "C1")), .open("https://github.com/c/A", read: "A"), "⏎ opens and reads")
        XCTAssertNil(act(.snooze, .row(id: "A", card: "C1")), "S does nothing on a row")
        XCTAssertEqual(act(.markAllRead, nil), .markAllRead, "⇧R with any selection")
        XCTAssertNil(act(.open, nil))
        let none = sections(ListOptions(groupBy: .none))
        XCTAssertNil(PopoverLogic.action(for: .open, selection: .section("none"), sections: none, activity: []))
    }

    /// The table of DESIGN.md, "Keyboard": ⇧R and ⌘F in every state.
    func testTheHintFollowsTheSelection() {
        let s = sections(collapsed: ["owner:o3": true, "snoozed": false])
        func hint(_ item: SelectionItem?) -> String {
            PopoverLogic.hints(selection: item, sections: s, activity: []).map { "\($0.key) \($0.text)" }.joined(separator: "  ")
        }
        XCTAssertEqual(hint(.header(card: "C1")), "↑↓ Move  ⏎ Open  S Snooze  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(.header(card: "S1")), "↑↓ Move  ⏎ Open  S Unsnooze  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(.row(id: "A", card: "C1")), "↑↓ Move  ⏎ Open  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(nil), "↑↓ Move  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(.section("owner:o2")), "↑↓ Move  ⏎ Collapse  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(.section("owner:o3")), "↑↓ Move  ⏎ Expand  ⇧R Mark all read  ⌘F Search")
        XCTAssertEqual(hint(.more("owner:o2")), "↑↓ Move  ⏎ Expand  ⇧R Mark all read  ⌘F Search")
    }

    /// DESIGN.md, "Keyboard", the mouse table; Main.html "Right-click on a
    /// row".
    func testTheRightClickMenu() {
        let s = sections(collapsed: ["snoozed": false])
        let returnAt = SnoozeTime.next("09:00", now: T0 + 7_200, timeZone: utc)
        func titles(_ item: SelectionItem, tab: PopoverTab = .prs, activity: [Row] = []) -> [String] {
            PopoverLogic.menu(for: item, tab: tab, sections: s, activity: activity, returnAt: returnAt, timeZone: utc).map { $0?.title ?? "-" }
        }
        XCTAssertEqual(titles(.header(card: "C1")), ["Open on GitHub", "Copy link", "-", "Snooze until Sat 09:00", "-", "Mark all as read"])
        XCTAssertEqual(titles(.row(id: "A", card: "C1")), ["Open on GitHub", "Copy link", "-", "Snooze until Sat 09:00", "-", "Mark all as read"])
        XCTAssertEqual(titles(.header(card: "S1")), ["Open on GitHub", "Copy link", "-", "Unsnooze", "-", "Mark all as read"])
        XCTAssertEqual(titles(.row(id: "H", card: "S1")), ["Open on GitHub", "Copy link", "-", "Unsnooze", "-", "Mark all as read"])
        XCTAssertEqual(titles(.row(id: "A", card: nil), tab: .activity, activity: sampleCards()[0].rows), ["Open on GitHub", "Copy link", "-", "Mark all as read"], "no Snooze in Activity")
        XCTAssertEqual(titles(.section("owner:o2")), [])
        XCTAssertEqual(titles(.more("owner:o2")), [])
        let actions = PopoverLogic.menu(for: .row(id: "A", card: "C1"), tab: .prs, sections: s, activity: [], returnAt: returnAt).compactMap { $0?.action }
        XCTAssertEqual(actions, [.open("https://github.com/c/A", read: "A"), .copyLink("https://github.com/c/A"), .snooze(pr: "example-org/api#407"), .markAllRead])
        let header = PopoverLogic.menu(for: .header(card: "C1"), tab: .prs, sections: s, activity: [], returnAt: returnAt).compactMap { $0?.action }
        XCTAssertEqual(header.prefix(2), [.open("https://github.com/p/1", read: nil), .copyLink("https://github.com/p/1")])
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
            copier: copier, reloadDelay: 0.05, clock: { T0 }
        )
        model.handle(.snapshot(accounts: [sampleAccount(), Account(id: "583231", login: "bufferings")], keychain: .known(.ok), dbUnreadable: false))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// A view model with the sample lists loaded.
    /// The popover's list model with the sample lists loaded.
    func loaded() async -> SurfaceListModel {
        api.cards = sampleCards()
        api.snoozedCards = snoozedCards()
        api.rows = sampleCards().flatMap(\.rows)
        let data = model.viewModel("3407303")
        data.reload()
        await settle()
        return data.list(.popover)
    }

    func lists() -> [String] {
        api.calls.filter { $0.hasPrefix("list") || $0.hasPrefix("activity") }
    }

    func testTheListsAreAskedWithoutFiltersAndFilteredHere() async {
        let view = model.viewModel("3407303").list(.popover)
        api.cards = sampleCards()
        model.surfaceDisplayed(.popover, account: "3407303", true)
        await settle()
        XCTAssertEqual(Set(lists()), ["list bufferings-work snoozed=false", "list bufferings-work snoozed=true", "activity bufferings-work"])
        api.clearCalls()
        view.data.options.segment = .reviewRequested
        view.data.options.groupBy = .involvement
        view.data.options.sort = .recentlyAdded
        view.data.toggleOwner("o4")
        view.setSearch("dark")
        await settle()
        XCTAssertEqual(lists(), [], "chips, owners, search, Group by and sort ask the daemon nothing")
        XCTAssertEqual(view.sections.map(\.title), ["Review requested"])
        let store = UIStateStore(defaults: defaults)
        XCTAssertEqual(store.options(account: "3407303"), ListOptions(segment: .reviewRequested, groupBy: .involvement, sort: .recentlyAdded), "kept per account")
        XCTAssertEqual(store.options(account: "583231"), ListOptions())
        XCTAssertEqual(store.activityOwners(account: "3407303"), ["o4"])
    }

    func testSelectingARowReadsItAndTheDotGoesAtOnce() async {
        let view = await loaded()
        view.select(.header(card: "C1"))
        view.select(.row(id: "B", card: "C1"))
        await settle()
        XCTAssertFalse(api.calls.contains { $0.hasPrefix("read") }, "a header and a read row send nothing")
        view.select(.row(id: "A", card: "C1"))
        XCTAssertEqual(view.data.cards[0].rows[0].unread, false, "shown read before the daemon answers")
        XCTAssertEqual(view.data.allActivity.first { $0.id == "A" }?.unread, false)
        await settle()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("read") }, ["read A"])
        // A list that still has A unread (it was on its way) does not bring
        // the dot back.
        view.data.reload()
        await settle()
        XCTAssertEqual(view.data.cards[0].rows[0].unread, false)
        // ↓ from A selects B (read already), then header C3.
        view.press(.down)
        view.press(.down)
        XCTAssertEqual(view.selection, .header(card: "C3"))
    }

    func testARefusedReadBringsTheDotBack() async {
        let view = await loaded()
        api.failNext = DaemonError(code: .notFound, message: "not_found")
        view.select(.row(id: "A", card: "C1"))
        await settle()
        await settle()
        XCTAssertEqual(view.data.cards[0].rows[0].unread, true)
        XCTAssertNotNil(model.lastError)
    }

    func testOpeningOpensAndReads() async {
        let view = await loaded()
        view.select(.header(card: "C1"))
        view.press(.open)
        view.doubleClick(.row(id: "G", card: "C5"))
        await settle()
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://github.com/p/1", "https://github.com/c/G"])
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("read") }, ["read G"], "a header opens the PR only")
        XCTAssertEqual(view.selection, .row(id: "G", card: "C5"), "a double click selects too")
    }

    func testRightClickSelectsReadsAndOffersTheMenu() async {
        let view = await loaded()
        let menu = view.rightClick(.row(id: "A", card: "C1"))
        XCTAssertEqual(view.selection, .row(id: "A", card: "C1"))
        XCTAssertEqual(menu.compactMap { $0?.title }, ["Open on GitHub", "Copy link", "Snooze until Fri 09:00", "Mark all as read"].map {
            $0.replacingOccurrences(of: "Fri", with: RelativeTime.weekdayClock(SnoozeTime.next(nil, now: T0)).prefix(3).description)
        })
        view.perform(.copyLink("https://github.com/c/A"))
        view.perform(.snooze(pr: "example-org/api#407"))
        await settle()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("read") }, ["read A"])
        XCTAssertEqual(copier.copied, ["https://github.com/c/A"])
        XCTAssertTrue(api.calls.contains("snooze bufferings-work example-org/api#407"))
    }

    func testMarkAllAsReadSendsTheRowsShownWithTheirIds() async {
        let view = await loaded()
        view.data.options.segment = .authored
        view.press(.markAllRead)
        await settle()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("read") }, ["read G"], "only what the chip shows; never read_all")
        view.data.options.segment = .all
        view.tab = .activity
        view.data.toggleOwner("o2")
        view.perform(.markAllRead)
        await settle()
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("read") }, ["read G", "read A"])
        XCTAssertFalse(api.calls.contains { $0.hasPrefix("read_all") })
        XCTAssertEqual(view.data.snoozed[0].rows[0].unread, true, "Snoozed rows stay unread")
    }

    func testABurstOfAccountChangesReadsTheListsOnce() async throws {
        _ = await loaded()
        model.surfaceDisplayed(.popover, account: "3407303", true)
        await settle()
        api.clearCalls()
        for _ in 0..<5 { model.handle(.accountChanged(sampleAccount())) }
        try await Task.sleep(nanoseconds: 300_000_000)
        await settle()
        XCTAssertEqual(lists().filter { $0.hasPrefix("list") && $0.hasSuffix("snoozed=false") }.count, 1)
    }

    func testTheFoldHoldsWhileOpenAndIsDecidedAgainOnClose() async {
        api.cards = sampleCards()
        let view = model.viewModel("3407303").list(.popover)
        model.surfaceDisplayed(.popover, account: "3407303", true)
        model.surfaceOpened(.popover, account: "3407303")
        await settle()
        XCTAssertEqual(view.sections[0].cards.map(\.id), ["C1", "C3"])
        view.select(.row(id: "A", card: "C1"))
        var read = sampleCards()
        read[0].rows[0].unread = false
        api.cards = read
        view.data.reload()
        await settle()
        XCTAssertEqual(view.sections[0].cards.map(\.id), ["C1", "C3"], "C1 stays out of the fold while open")
        view.perform(.expand("owner:o2"))
        XCTAssertNil(view.sections[0].moreText)
        model.surfaceClosed(.popover, account: "3407303")
        XCTAssertEqual(view.sections[0].cards.map(\.id), ["C3"], "closing folds again")
        XCTAssertEqual(view.expanded, [])
        await settle()
        XCTAssertTrue(api.calls.contains("popover_closed bufferings-work"))
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("read") }, ["read A"], "closing reads nothing")
    }

    func testSearchIsPerTabAndClearedWhenThePopoverCloses() async {
        let view = await loaded()
        model.surfaceOpened(.popover, account: "3407303")
        view.press(.find)
        XCTAssertTrue(view.searchFocused)
        view.setSearch("retry")
        view.tab = .activity
        XCTAssertEqual(view.search, "", "Activity has its own")
        view.setSearch("billing")
        XCTAssertEqual(view.activity.map(\.id), ["G"])
        view.tab = .prs
        XCTAssertEqual(view.search, "retry")
        view.leaveSearch(clearing: false)
        XCTAssertFalse(view.searchFocused)
        XCTAssertEqual(view.search, "retry", "↓ keeps the text")
        view.searchFocused = true
        view.leaveSearch(clearing: true)
        XCTAssertEqual(view.search, "", "Esc clears it")
        XCTAssertFalse(view.searchFocused)
        view.setSearch("x")
        model.surfaceClosed(.popover, account: "3407303")
        XCTAssertEqual(view.search, "")
        view.tab = .activity
        XCTAssertEqual(view.search, "")
    }

    func testTheWindowKeepsItsSearchUntilItCloses() async {
        let view = await loaded().data.list(.window)
        model.surfaceDisplayed(.window, account: "3407303", true)
        model.surfaceOpened(.window, account: "3407303")
        view.setSearch("retry")
        model.surfaceClosed(.window, account: "3407303")
        XCTAssertEqual(view.search, "retry", "losing the focus keeps it")
        model.surfaceDisplayed(.window, account: "3407303", false)
        XCTAssertEqual(view.search, "")
    }

    func testAllOwnersAndTheOwnerButtons() async {
        let view = await loaded()
        view.tab = .activity
        XCTAssertTrue(view.data.allOwnersOn)
        view.data.toggleOwner("o3")
        XCTAssertFalse(view.data.allOwnersOn)
        XCTAssertTrue(view.data.isOwnerOn("o3"))
        XCTAssertEqual(view.activity.map(\.id), ["G"])
        view.data.toggleOwner("o2")
        view.data.toggleOwner("o4")
        XCTAssertFalse(view.data.allOwnersOn, "every owner on is not All owners")
        view.data.showAllOwners()
        XCTAssertTrue(view.data.allOwnersOn)
        XCTAssertFalse(view.data.isOwnerOn("o3"))
        XCTAssertEqual(view.activity.count, 5)
    }

    func testAFoldedPRWithANewUnreadRowComesOutWhileOpen() async {
        api.cards = sampleCards()
        let data = model.viewModel("3407303")
        model.surfaceDisplayed(.popover, account: "3407303", true)
        model.surfaceOpened(.popover, account: "3407303")
        await settle()
        let view = data.list(.popover)
        XCTAssertEqual(view.sections[0].cards.map(\.id), ["C1", "C3"])
        var cards = sampleCards()
        cards[1].rows[0].unread = true
        api.cards = cards
        model.handle(.accountChanged(sampleAccount()))
        try? await Task.sleep(nanoseconds: 200_000_000)
        await settle()
        XCTAssertEqual(view.sections[0].cards.map(\.id), ["C2", "C1", "C3"])
    }

    /// The popover and the window of one account keep their own tab,
    /// search, selection and fold; the chip, Group by, sort, folds of
    /// sections and Activity owners are the account's.
    func testThePopoverAndTheWindowKeepTheirOwnSearchSelectionAndFold() async {
        let popover = await loaded()
        let window = model.viewModel("3407303").list(.window)
        model.surfaceDisplayed(.window, account: "3407303", true)
        model.surfaceOpened(.popover, account: "3407303")
        model.viewModel("3407303").reload()
        await settle()
        popover.setSearch("retry")
        popover.select(.header(card: "C1"))
        popover.perform(.expand("owner:o2"))
        XCTAssertEqual(window.search, "")
        XCTAssertNil(window.selection)
        XCTAssertEqual(window.sections[0].moreText, "+ 2 more PRs", "the window keeps its fold")
        XCTAssertNil(popover.sections[0].moreText)
        window.tab = .activity
        XCTAssertEqual(popover.tab, .prs)
        window.setSearch("billing")
        XCTAssertEqual(popover.searches[.activity], nil)
        // Shared choices.
        popover.data.options.segment = .authored
        XCTAssertEqual(window.data.options.segment, .authored)
        popover.perform(.toggleSection("owner:o3"))
        XCTAssertEqual(window.sections.first { $0.key == "owner:o3" }?.collapsed, true)
        // The popover closing clears its search only.
        model.surfaceClosed(.popover, account: "3407303")
        XCTAssertEqual(popover.search, "")
        XCTAssertEqual(window.search, "billing")
        // The window losing the focus keeps it; closing clears it.
        model.surfaceOpened(.window, account: "3407303")
        model.surfaceClosed(.window, account: "3407303")
        XCTAssertEqual(window.search, "billing")
        model.surfaceDisplayed(.window, account: "3407303", false)
        XCTAssertEqual(window.search, "")
    }

    /// The daemon keeps the cards of a `list` answered after
    /// `popover_opened`: the lists are read only once it is answered.
    func testTheListsWaitForPopoverOpened() async throws {
        api.popoverOpenedDelay = 200_000_000
        let list = model.viewModel("3407303").list(.popover)
        list.searchFocused = true
        // The first display of the account, as the popover opens it.
        model.surfaceDisplayed(.popover, account: "3407303", true, opening: true)
        model.surfaceOpened(.popover, account: "3407303")
        XCTAssertFalse(list.searchFocused, "the search field does not take the keyboard on open")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(lists(), [], "nothing before the answer")
        try await Task.sleep(nanoseconds: 250_000_000)
        await settle()
        let calls = api.calls
        let answered = try XCTUnwrap(calls.firstIndex(of: "answered popover_opened"))
        let firstList = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("list") })
        XCTAssertLessThan(answered, firstList)
        XCTAssertEqual(lists().filter { $0.hasSuffix("snoozed=false") }.count, 1, "one read, after the answer")
        // A window displayed again without the focus reads at once.
        model.surfaceClosed(.popover, account: "3407303")
        model.surfaceDisplayed(.popover, account: "3407303", false)
        api.clearCalls()
        model.surfaceDisplayed(.window, account: "3407303", true)
        await settle()
        XCTAssertEqual(lists().filter { $0.hasSuffix("snoozed=false") }.count, 1)
        model.surfaceDisplayed(.window, account: "3407303", false)
        model.surfaceOpened(.popover, account: "3407303")
        try await Task.sleep(nanoseconds: 350_000_000)
        await settle()
        // The same on a reconnect.
        api.clearCalls()
        model.connectionChanged(false)
        model.connectionChanged(true)
        try await Task.sleep(nanoseconds: 350_000_000)
        await settle()
        let again = api.calls
        let reopened = try XCTUnwrap(again.firstIndex(of: "answered popover_opened"))
        let relist = try XCTUnwrap(again.firstIndex { $0.hasPrefix("list") })
        XCTAssertLessThan(reopened, relist)
    }

    /// DESIGN.md:61: the window decides "+ N more PRs" again when it loses
    /// the focus.
    func testTheWindowFoldsAgainWhenItLosesTheFocus() async {
        api.cards = sampleCards()
        let data = model.viewModel("3407303")
        let window = data.list(.window)
        model.surfaceDisplayed(.window, account: "3407303", true)
        model.surfaceOpened(.window, account: "3407303")
        await settle()
        XCTAssertEqual(window.sections[0].cards.map(\.id), ["C1", "C3"])
        window.select(.row(id: "A", card: "C1"))
        await settle()
        XCTAssertEqual(window.sections[0].cards.map(\.id), ["C1", "C3"], "C1 stays while the window has the focus")
        model.surfaceClosed(.window, account: "3407303")
        XCTAssertEqual(window.sections[0].cards.map(\.id), ["C3"], "losing the focus folds C1")
        XCTAssertEqual(window.sections[0].moreText, "+ 3 more PRs")
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
        model.handle(.configChanged(key: "snooze_return_time", value: .string("07:30")))
        XCTAssertEqual(model.nextReturn(timeZone: utc), T0 + 86_400 - 1_800)
    }

    func testSectionsFoldAndAreKeptPerGroupBy() async {
        let view = await loaded()
        view.perform(.toggleSection("owner:o2"))
        view.perform(.toggleSection("snoozed"))
        XCTAssertEqual(view.sections.map(\.collapsed), [true, false, false])
        view.data.options.groupBy = .status
        view.perform(.toggleSection("status:open"))
        XCTAssertEqual(UIStateStore(defaults: defaults).collapsed(account: "3407303"), ["owner:o2": true, "snoozed": false, "status|status:open": true])
        XCTAssertEqual(AccountViewModel(account: "3407303", app: model).collapsed, ["owner:o2": true, "snoozed": false, "status|status:open": true])
    }

    func testWithNoCardsTheKeysNeverReachAHiddenSection() async {
        api.cards = []
        let view = model.viewModel("3407303").list(.popover)
        view.data.reload()
        await settle()
        XCTAssertEqual(view.emptyText, "Nothing needs you")
        XCTAssertEqual(view.items, [])
        view.press(.down)
        XCTAssertNil(view.selection)
        view.select(.section("owner:o2"))
        view.press(.open)
        XCTAssertEqual(view.data.collapsed, [:])
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
