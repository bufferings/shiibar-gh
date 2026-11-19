// All's `Recent activity`, the section order of Review and Mine, the unread
// mark of a collapsed heading, the names on screen and ⌘R (DESIGN.md, "All",
// "Review", "Mine", "Section size", "Overview and scope", "Keyboard").

import Foundation
@testable import ShiibarGhCore
import XCTest

final class RecentActivityTests: XCTestCase {
    /// The newest row that is not muted, read or not; else the time the
    /// card was added; else 0.
    func testTheTimeACardSortsBy() {
        let rows = [
            row("a", pr: "o/r#1", at: T0 + 10),
            row("b", pr: "o/r#1", unread: true, at: T0 + 5),
            row("c", pr: "o/r#1", muted: true, at: T0 + 50),
        ]
        XCTAssertEqual(Listing.activityAt(card("1", added: T0 - 100, updated: T0 + 999, rows: rows)), T0 + 10)
        XCTAssertEqual(Listing.activityAt(card("2", added: T0 - 100, rows: [rows[2]])), T0 - 100, "only a muted row")
        XCTAssertEqual(Listing.activityAt(card("3", added: T0 - 100, updated: T0 + 999)), T0 - 100, "no row: the time added")
        var unknown = card("4")
        unknown.addedAt = nil
        XCTAssertEqual(Listing.activityAt(unknown), 0)
    }

    /// The same scenes as the daemon's `list --tab all` (crates/shiibar-ghd,
    /// table_card_visibility): a card without rows, one whose only row is
    /// of a kind whose List is off (the wire leaves it out), one with a
    /// muted row only, a muted card with a mention, a merged card and a
    /// closed one with the account's own read row. Merged and closed cards
    /// do not go last; a tie goes by the PR key.
    func testAllIsInRecentActivityOrderOpenOrNot() {
        let added = T0 + 10
        let cards = [
            card("1001:PR_1", added: added, updated: T0 + 999),
            card("1001:PR_2", state: .merged, added: added, rows: [
                row("M_2", pr: "org/app#2", kind: .merged, actor: "alice", unread: true, at: T0 + 60),
                row("E_2", pr: "org/app#2", kind: .commentOther, actor: "alice", unread: true, at: T0 + 50),
            ]),
            card("1001:PR_3", added: added),
            card("1001:PR_4", added: added, rows: [
                row("E_4", pr: "org/app#4", kind: .commentOther, actor: "eve", unread: true, muted: true, at: T0 + 80),
            ]),
            card("1001:PR_5", muted: [.author], added: added, rows: [
                row("E_5", pr: "org/app#5", kind: .commentOther, actor: "alice", unread: true, muted: true, at: T0 + 90),
                row("N_5", pr: "org/app#5", kind: .mentioned, actor: "alice", unread: true, at: T0 + 40),
            ]),
            card("1001:PR_6", state: .closed, added: added, rows: [
                row("C_6", pr: "org/app#6", kind: .closed, actor: "me", at: T0 + 55),
            ]),
        ]
        let order = Listing.sorted(cards.shuffled(), by: .recentActivity).map(\.id)
        XCTAssertEqual(order, ["1001:PR_2", "1001:PR_6", "1001:PR_5", "1001:PR_1", "1001:PR_3", "1001:PR_4"])
        let byAdded = Listing.sorted(cards, by: .recentlyAdded).map(\.id)
        XCTAssertEqual(byAdded, cards.map(\.id), "all added at once: by the key, merged and closed included")
    }

    /// A tie goes by the PR key as a string, as the daemon sorts it
    /// (`PR_10` before `PR_9`); a card without the time it was added sorts
    /// as the oldest. The daemon's test (table_card_visibility,
    /// `ties_go_by_the_key_as_a_string`) uses the same values.
    func testTiesGoByTheKeyAsAStringAndAnUnknownAddTimeIsTheOldest() {
        var unknown = card("1001:PR_1", added: T0)
        unknown.addedAt = nil
        let cards = [card("1001:PR_9", added: T0), card("1001:PR_10", added: T0), card("1001:PR_2", added: T0), unknown]
        XCTAssertEqual(Listing.sorted(cards, by: .recentActivity).map(\.id), ["1001:PR_10", "1001:PR_2", "1001:PR_9", "1001:PR_1"])
        XCTAssertEqual(Listing.sorted(cards, by: .recentlyAdded).map(\.id), ["1001:PR_10", "1001:PR_2", "1001:PR_9", "1001:PR_1"])
    }

    /// `Recent activity` keeps 0.6's saved value of `Recently updated`.
    func testTheSortNamesAndThe06Choice() throws {
        XCTAssertEqual(SortOrder.allCases.map(\.title), ["Recent activity", "Recently added"])
        XCTAssertEqual(ListOptions().sort, .recentActivity, "the default")
        let saved = try JSONDecoder().decode(ListOptions.self, from: Data(#"{"groupBy":"owner","thenBy":"none","sort":"recently_updated"}"#.utf8))
        XCTAssertEqual(saved.sort, .recentActivity)
        XCTAssertEqual(saved.groupBy, .owner)
        let added = try JSONDecoder().decode(ListOptions.self, from: Data(#"{"sort":"recently_added"}"#.utf8))
        XCTAssertEqual(added.sort, .recentlyAdded)
        let written = try JSONEncoder().encode(ListOptions(sort: .recentActivity))
        XCTAssertTrue(String(decoding: written, as: UTF8.self).contains(#""sort":"recently_updated""#), "0.6 reads it back too")
    }

    /// Status starts as Merged, Closed, Open, Draft; the Filter's statuses,
    /// summary and saved form keep `PRStatus`'s order.
    func testTheStatusGroupsStartWithMerged() {
        let groups = Listing.defaultGroups(.status, account: sampleAccount(), repositories: [])
        XCTAssertEqual(groups.map(\.title), ["Merged", "Closed", "Open", "Draft"])
        XCTAssertEqual(PRStatus.allCases, [.open, .draft, .merged, .closed])
        let saved = Listing.orderedGroups(.status, account: sampleAccount(), repositories: [], orders: [.status: ["open", "draft", "merged", "closed"]])
        XCTAssertEqual(saved.map(\.title), ["Open", "Draft", "Merged", "Closed"], "an order the user saved stays")
    }
}

final class SectionOrderTests: XCTestCase {
    /// The screen shows Done, Waiting, Doing, Inbox; the menus follow the flow, Inbox,
    /// Doing, Waiting, Done.
    func testTheShownOrderAndTheMenuOrder() {
        XCTAssertEqual(PlacementSection.displayOrder, [.done, .waiting, .doing, .inbox])
        XCTAssertEqual(PlacementSection.menuOrder, [.inbox, .doing, .waiting, .done])
        XCTAssertEqual(MultiRules.operations(.review).map(\.title),
                       ["Move to Inbox", "Move to Doing", "Move to Waiting", "Move to Done", "Remove from Review"])
        XCTAssertEqual(MultiRules.operations(.mine).map(\.title),
                       ["Move to Inbox", "Move to Doing", "Move to Waiting", "Move to Done", "Remove from Mine"])
        XCTAssertEqual(layout(.review).map(\.key), ["review|done", "review|waiting", "review|doing", "review|inbox"])
        XCTAssertEqual(SectionKey.placed(.mine, .inbox), "mine|inbox", "the keys of the folds stay")
    }

    /// ↑↓ walk the sections in the order shown: from Done's last card to
    /// Waiting, from Doing to Inbox.
    func testTheArrowsFollowTheShownOrder() {
        let items = PopoverLogic.items(view(.review))
        let d1 = items.firstIndex(of: .header(card: "D1"))!
        XCTAssertEqual(PopoverLogic.move(items[d1], up: false, in: items), .section("review|waiting"))
        let r1 = items.firstIndex(of: .row(id: "r1", card: "R1"))!
        XCTAssertEqual(PopoverLogic.move(items[r1], up: false, in: items), .section("review|inbox"))
    }
}

final class FoldMarkTests: XCTestCase {
    /// A collapsed section: the dot for a colored unread card; nothing when
    /// open (DESIGN.md, "Section size").
    func testACollapsedSectionShowsTheDot() {
        let open = layout(.review)
        XCTAssertTrue(open.allSatisfy { $0.foldMark == .none }, "no mark on an open heading")
        let collapsed = layout(.review, collapsed: ["review|inbox", "review|done", "review|doing"])
        let marks = Dictionary(uniqueKeysWithValues: collapsed.map { ($0.key, $0.foldMark) })
        XCTAssertEqual(marks["review|inbox"], .blue, "T1's unread rows")
        XCTAssertEqual(marks["review|done"], UnreadMark.none, "D1 has no unread row")
        XCTAssertEqual(marks["review|doing"], UnreadMark.none, "R1's row is read")
        XCTAssertEqual(marks["review|waiting"], UnreadMark.none, "open")
    }

    /// Only gray unread rows: the ring. A card the Filter hides does not
    /// count; the search does not change the mark.
    func testTheRingTheFilterAndTheSearch() {
        let cards = [
            card("G1", placement: review(.inbox, 0), muted: [.author], rows: [row("g", pr: "example-org/api#G1", unread: true, muted: true)]),
            card("G2", placement: review(.inbox, 1), rows: [row("h", pr: "example-org/api#G2")]),
        ]
        let shown = layout(.review, cards: cards, collapsed: ["review|inbox"], filter: mutedShown)
        XCTAssertEqual(shown.first { $0.key == "review|inbox" }?.foldMark, .ring)
        let hidden = layout(.review, cards: cards, collapsed: ["review|inbox"], filter: mutedHidden)
        XCTAssertEqual(hidden.first { $0.key == "review|inbox" }?.foldMark, UnreadMark.none, "the muted card is hidden")
        let blue = cards + [card("G3", placement: review(.inbox, 2), rows: [row("i", pr: "example-org/api#G3", unread: true)])]
        let searched = layout(.review, cards: blue, collapsed: ["review|inbox"], search: "Title G2", filter: mutedShown)
        XCTAssertEqual(searched.first { $0.key == "review|inbox" }?.foldMark, .blue, "G3 does not match the search but counts")
    }

    /// All: a collapsed group of the first level takes the cards of all its
    /// second-level groups; a collapsed second-level group its own.
    func testAllsGroupsOfBothLevels() {
        let options = ListOptions(groupBy: .repository, thenBy: .status)
        let first = layout(.all, options: options, collapsed: ["all|repository|status|example-org/api|"])
        let api = first.first { $0.key == "all|repository|status|example-org/api|" }
        XCTAssertEqual(api?.foldMark, .blue, "T1's and T7's unread rows")
        let second = layout(.all, options: options, collapsed: [
            "all|repository|status|example-org/api|closed", "all|repository|status|example-org/api|open",
        ])
        let marks = Dictionary(uniqueKeysWithValues: second.map { ($0.key, $0.foldMark) })
        XCTAssertEqual(marks["all|repository|status|example-org/api|"], UnreadMark.none, "open")
        XCTAssertEqual(marks["all|repository|status|example-org/api|open"], .blue)
        XCTAssertEqual(marks["all|repository|status|example-org/api|closed"], UnreadMark.none, "M3 has no rows")
        let one = layout(.all, collapsed: ["all|repository|none|acme-corp/web|"])
        XCTAssertEqual(one.first { $0.title == "acme-corp/web" }?.foldMark, .ring, "N1's gray row only")
    }
}

final class NamesAndKeysTests: XCTestCase {
    /// The app's name on screen is `Shiibar GH`; the CLI, the state
    /// directory and the token's description keep `shiibar-gh`.
    @MainActor
    func testTheNameOnScreen() {
        XCTAssertEqual(MainMenu.appName, "Shiibar GH")
        let app = MainMenu.make().items[0].submenu!
        XCTAssertEqual(app.title, "Shiibar GH")
        XCTAssertEqual(app.items.map(\.title), ["About Shiibar GH", "", "Settings…", "", "Close Window", "", "Quit Shiibar GH"])
        XCTAssertEqual(MainMenu.make().items[1].submenu?.items.map(\.title), ["Undo", "Redo", "", "Cut", "Copy", "Paste", "Select All"])
        XCTAssertEqual(KeychainDialog.unavailable.message, "If macOS asked whether Shiibar GH may use the Keychain, allow it, then retry.")
        XCTAssertEqual(SettingsText.loginItemBlocked, "Allow Shiibar GH in System Settings › General › Login Items")
        XCTAssertEqual(SettingsText.removeAccountDetail,
                       "Deletes this account and its owners from Shiibar GH: token, PRs, mutes and settings. Nothing changes on GitHub.")
        XCTAssertEqual(SettingsText.removeOwnerDetail, "Deletes this owner from Shiibar GH: its PRs and settings. Nothing changes on GitHub.")
        XCTAssertEqual(StateDirectory.root(environment: ["HOME": "/Users/example"]), "/Users/example/.local/state/shiibar-gh")
    }

    /// ⌘R: in the list, the search field and the Dismissed list; nothing
    /// while the × confirmation shows.
    func testCommandRRefreshes() {
        let r = KeyPress(characters: "r", modifiers: [.command])
        XCTAssertEqual(KeyRules.decide(r, inSearch: false, hasSearchText: false), .refresh)
        XCTAssertEqual(KeyRules.decide(r, inSearch: true, hasSearchText: true), .refresh)
        XCTAssertEqual(KeyRules.decide(r, inSearch: false, hasSearchText: false, inDismissed: true), .refresh)
        XCTAssertEqual(KeyRules.decide(r, inSearch: false, hasSearchText: false, confirming: true), .ignore)
        XCTAssertEqual(KeyRules.decide(r, inSearch: false, hasSearchText: false, sheet: true), .ignore, "the Grouping sheet")
        XCTAssertEqual(KeyRules.decide(r, inSearch: true, hasSearchText: false, sheet: true), .ignore)
        XCTAssertEqual(KeyRules.decide(KeyPress(characters: "R", modifiers: [.shift]), inSearch: false, hasSearchText: false), .key(.markAllRead))
    }

    /// The popover closes when the app stops being active, not the
    /// measurement mode's.
    func testThePopoverClosesWhenTheAppResigns() {
        XCTAssertTrue(SurfaceRules.closesPopoverOnResign(shown: true, measuring: false))
        XCTAssertFalse(SurfaceRules.closesPopoverOnResign(shown: true, measuring: true))
        XCTAssertFalse(SurfaceRules.closesPopoverOnResign(shown: false, measuring: false))
    }
}
