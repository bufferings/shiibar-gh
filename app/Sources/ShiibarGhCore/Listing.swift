// What the popover lists, worked out by the app from the one unfiltered
// `list` answer (DESIGN.md, "What the filters mean"): the tabs All, Review
// and Mine, the Dismissed list, the search, Group by and Then by with their
// group order, the sort order, and "+ N more PRs" (DESIGN.md, "Tabs", "All",
// "Review", "Mine", "Section size", "Dismissed list").

import Foundation

// MARK: - Options

public enum GroupBy: String, Equatable, Codable, CaseIterable {
    case owner, repository, status, involvement, none

    public var title: String {
        switch self {
        case .owner: return "Owner"
        case .repository: return "Repository"
        case .status: return "Status"
        case .involvement: return "Involvement"
        case .none: return "None"
        }
    }
}

public enum SortOrder: String, Equatable, Codable, CaseIterable {
    case recentlyUpdated = "recently_updated", recentlyAdded = "recently_added"

    public var title: String {
        switch self {
        case .recentlyUpdated: return "Recently updated"
        case .recentlyAdded: return "Recently added"
        }
    }
}

/// Group by, Then by and the sort order of All: remembered per account
/// (DESIGN.md, "Saved state"). Group by starts at Repository, Then by at
/// None (DESIGN.md, "All").
public struct ListOptions: Equatable, Codable {
    public private(set) var groupBy: GroupBy
    public private(set) var thenBy: GroupBy
    public var sort: SortOrder

    public init(groupBy: GroupBy = .repository, thenBy: GroupBy = .none, sort: SortOrder = .recentlyUpdated) {
        self.groupBy = groupBy
        self.thenBy = .none
        self.sort = sort
        setThenBy(thenBy)
    }

    enum CodingKeys: String, CodingKey { case groupBy, thenBy, sort }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            groupBy: (try? c.decodeIfPresent(GroupBy.self, forKey: .groupBy)) ?? .repository,
            thenBy: (try? c.decodeIfPresent(GroupBy.self, forKey: .thenBy)) ?? .none,
            sort: (try? c.decodeIfPresent(SortOrder.self, forKey: .sort)) ?? .recentlyUpdated
        )
    }

    /// The same value cannot be on both levels: choosing Then by's value in
    /// Group by sets Then by to None, and so does Group by None.
    public mutating func setGroupBy(_ value: GroupBy) {
        groupBy = value
        if value == .none || value == thenBy { thenBy = .none }
    }

    /// Ignored while Group by is None or for Group by's own value.
    public mutating func setThenBy(_ value: GroupBy) {
        guard groupBy != .none, value != groupBy else {
            thenBy = .none
            return
        }
        thenBy = value
    }

    /// The values the Then by pop-up offers: all but Group by's.
    public var thenByChoices: [GroupBy] {
        GroupBy.allCases.filter { $0 != groupBy }
    }

    /// The Then by button reads `Then by` while it is None.
    public var thenByTitle: String {
        thenBy == .none ? "Then by" : thenBy.title
    }
}

// MARK: - Search

/// DESIGN.md, "What the filters mean": the words of the search, each found
/// case-insensitively in some field. The same rule as the daemon's
/// `search_words`, `card_matches` and `row_matches`.
public enum Search {
    /// Split on Unicode white space and lowercased, as Rust's
    /// `split_whitespace` and `to_lowercase` do.
    public static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !current.isEmpty { words.append(String(current).lowercased()) }
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { words.append(String(current).lowercased()) }
        return words
    }

    /// Every word is part of some field.
    public static func matches(_ words: [String], fields: [String]) -> Bool {
        if words.isEmpty { return true }
        let lowered = fields.map { $0.lowercased() }
        return words.allSatisfy { word in lowered.contains { $0.contains(word) } }
    }

    /// The PR's own fields: title, `owner/repo#number`, author, base, head.
    static func prFields(_ card: Card) -> [String] {
        [card.title, card.pr, card.author, card.base, card.head]
    }

    static func rowFields(_ row: Row) -> [String] {
        [row.text ?? "", row.actor ?? ""]
    }

    /// A PR matches with its own fields or the text and actor of any row.
    public static func matches(_ card: Card, words: [String]) -> Bool {
        matches(words, fields: prFields(card) + card.rows.flatMap(rowFields))
    }
}

// MARK: - Tabs

public enum ListTab: String, Equatable, Codable, CaseIterable {
    case all, review, mine

    public var title: String {
        switch self {
        case .all: return "All"
        case .review: return "Review"
        case .mine: return "Mine"
        }
    }
}

extension PlacementSection {
    public var title: String {
        switch self {
        case .doing: return "Doing"
        case .todo: return "Todo"
        case .waiting: return "Waiting"
        case .done: return "Done"
        case .main: return "Mine"
        }
    }

    /// Review's sections from the top (DESIGN.md, "Review").
    public static let review: [PlacementSection] = [.doing, .todo, .waiting, .done]
}

extension Card {
    /// The tab a card is placed in, or All.
    public var tab: ListTab {
        switch placement?.tab.value {
        case .review?: return .review
        case .mine?: return .mine
        case nil: return .all
        }
    }

    /// The placement tag of All: `Review · Todo`, `Mine`, `Mine · Done`.
    public var placementTag: String? {
        guard let placement, let tab = placement.tab.value, let section = placement.section.value else { return nil }
        switch tab {
        case .review: return "Review · " + section.title
        case .mine: return section == .done ? "Mine · Done" : "Mine"
        }
    }

    /// The card's section key in its own tab, nil without a placement.
    public var sectionKey: String? {
        guard let placement, let tab = placement.tab.value, let section = placement.section.value else { return nil }
        return SectionKey.placed(tab, section)
    }

    /// The grip and dragging: placed in Review or Mine, Done included, not
    /// muted (DESIGN.md, "What a press does").
    public var canDrag: Bool {
        guard let placement, placement.section.value != nil else { return false }
        return !isMuted
    }

    /// ⌥↑↓ and a drop among the cards: as `canDrag`, not in Done, which
    /// keeps its own order.
    public var canReorder: Bool {
        canDrag && placement?.isDone == false
    }
}

// MARK: - Sections

public enum SectionKey {
    /// A section of Review or Mine.
    public static func placed(_ tab: PlacementTab, _ section: PlacementSection) -> String {
        tab.rawValue + "|" + section.rawValue
    }

    /// A group of All: Group by, Then by, the first-level and the
    /// second-level group (empty for the first level itself or without Then
    /// by). DESIGN.md, "Section size".
    public static func all(_ groupBy: GroupBy, _ thenBy: GroupBy, _ first: String, _ second: String) -> String {
        ["all", groupBy.rawValue, thenBy.rawValue, first, second].joined(separator: "|")
    }

    /// The Review or Mine section of a key, nil for All.
    public static func placement(_ key: String) -> (PlacementTab, PlacementSection)? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, let tab = PlacementTab(rawValue: String(parts[0])),
              let section = PlacementSection(rawValue: String(parts[1])) else { return nil }
        return (tab, section)
    }
}

/// One heading and the cards under it. In All with Then by, a first-level
/// group is a heading only (`level` 1, `isLeaf` false) followed by its
/// second-level groups (`level` 2).
public struct SectionLayout: Equatable, Identifiable {
    public var key: String
    public var title: String
    /// 0: no heading (Group by None, the first list of Mine); 1: a band;
    /// 2: an indented small heading.
    public var level: Int
    /// Holds cards (the innermost group).
    public var isLeaf: Bool
    /// `6 PRs`, whatever the search.
    public var detail: String
    public var collapsed: Bool
    /// The cards laid out (none while collapsed; the first 5 while folded).
    public var cards: [Card]
    /// The cards folded into "+ N more PRs".
    public var more: Int
    /// Expanded past 5: `Show less` on the last line and in the heading.
    public var showLess: Bool
    /// The mark of "+ N more PRs" for the folded cards.
    public var moreMark: UnreadMark
    /// Every card after the search, in order, folded and collapsed ones too.
    public var matching: [Card]
    /// Review or Mine, Done included: cards move by drag, keys and menus.
    public var accepts: Bool
    public var isDone: Bool

    public var id: String { key }

    public var showsHeader: Bool { level > 0 }

    /// The last line: "+ N more PRs" or "Show less".
    public var foldLine: String? {
        if more > 0 { return "+ \(more) more " + (more == 1 ? "PR" : "PRs") }
        if showLess { return "Show less" }
        return nil
    }

    /// The Review or Mine section, nil in All.
    public var placement: (PlacementTab, PlacementSection)? { SectionKey.placement(key) }
}

/// Group orders per Group by value, as group keys (owner ids, repository
/// names, the status and involvement keys).
public typealias GroupOrders = [GroupBy: [String]]

public struct GroupItem: Equatable, Identifiable {
    public var key: String
    public var title: String
    public var id: String { key }
}

public enum Listing {
    /// Six or more cards fold to the first five (DESIGN.md, "Section size").
    public static let foldAt = 6
    public static let shownWhenFolded = 5
    /// A card shows its newest three rows (DESIGN.md, "Rows in a card").
    public static let rowsShown = 3

    static func count(_ n: Int) -> String { n == 1 ? "1 PR" : "\(n) PRs" }

    /// `owner/repo` of `owner/repo#123`.
    public static func repository(_ pr: String) -> String {
        guard let hash = pr.lastIndex(of: "#") else { return pr }
        return String(pr[..<hash])
    }

    // MARK: Cards of a tab

    /// The cards of a tab, not dismissed.
    public static func cards(_ cards: [Card], tab: ListTab) -> [Card] {
        cards.filter { !$0.isDismissed && (tab == .all || $0.tab == tab) }
    }

    /// The unread count of a tab: its cards with a blue unread row; muted
    /// gray ones do not count (DESIGN.md, "Tabs").
    public static func unreadCount(_ cards: [Card], tab: ListTab) -> Int {
        Self.cards(cards, tab: tab).filter(\.hasBlueUnread).count
    }

    /// The Dismissed list: newest dismissal first.
    public static func dismissed(_ cards: [Card]) -> [Card] {
        cards.filter(\.isDismissed).sorted {
            let (a, b) = ($0.dismissedAt ?? 0, $1.dismissedAt ?? 0)
            return a != b ? a > b : $0.id < $1.id
        }
    }

    public static func search(_ cards: [Card], _ text: String) -> [Card] {
        let words = Search.words(text)
        return words.isEmpty ? cards : cards.filter { Search.matches($0, words: words) }
    }

    // MARK: Order

    /// All's order inside the innermost group (DESIGN.md, "All"): open PRs
    /// (Draft included) first, then Merged and Closed, each newest first by
    /// the chosen order; muted cards after all of them, in the same way.
    public static func sorted(_ cards: [Card], by order: SortOrder) -> [Card] {
        cards.sorted { a, b in
            if a.isMuted != b.isMuted { return !a.isMuted }
            if a.isFinished != b.isFinished { return !a.isFinished }
            let (ka, kb): (Int64, Int64) = order == .recentlyUpdated
                ? (a.updatedAt, b.updatedAt)
                : (a.addedAt ?? 0, b.addedAt ?? 0)
            if ka != kb { return ka > kb }
            return a.id < b.id
        }
    }

    /// Review and Mine: the daemon's rank, muted cards last.
    public static func ranked(_ cards: [Card]) -> [Card] {
        cards.sorted { a, b in
            if a.isMuted != b.isMuted { return !a.isMuted }
            let (pa, pb) = (a.placement?.position ?? 0, b.placement?.position ?? 0)
            if pa != pb { return pa < pb }
            return a.id < b.id
        }
    }

    // MARK: Groups

    static let statusGroups = [("open", "Open"), ("draft", "Draft"), ("merged", "Merged"), ("closed", "Closed")]
    static let involvementGroups = [
        ("review_requested", "Review requested"), ("authored", "Authored by me"),
        ("assigned", "Assigned to me"), ("others", "Others"),
    ]

    /// The group of a card under a Group by value.
    public static func groupKey(_ card: Card, _ by: GroupBy) -> String {
        switch by {
        case .owner: return card.owner
        case .repository: return repository(card.pr)
        case .status:
            switch card.stateLabel.value {
            case .draft: return "draft"
            case .merged: return "merged"
            case .closed: return "closed"
            case .open, .mergeable, nil: return "open"
            }
        case .involvement:
            // A PR you authored is Authored by me even with a team asked
            // for its review; otherwise the first that applies.
            if card.authoredByMe { return "authored" }
            if card.reviewRequested { return "review_requested" }
            if card.assignedToMe { return "assigned" }
            return "others"
        case .none: return ""
        }
    }

    /// The groups a Group by value offers in their default order: the
    /// enabled owners in registration order (Public last); the repositories
    /// seen so far (`repositories`, kept in the order they came); the four
    /// statuses and involvements.
    public static func defaultGroups(_ by: GroupBy, account: Account, repositories: [String]) -> [GroupItem] {
        switch by {
        case .owner:
            return account.owners.filter(\.enabled).map { GroupItem(key: $0.id, title: $0.displayName) }
        case .repository:
            return repositories.map { GroupItem(key: $0, title: $0) }
        case .status:
            return statusGroups.map { GroupItem(key: $0.0, title: $0.1) }
        case .involvement:
            return involvementGroups.map { GroupItem(key: $0.0, title: $0.1) }
        case .none:
            return [GroupItem(key: "", title: "")]
        }
    }

    /// The groups in the user's order: the saved order first (groups gone
    /// left out), then the rest in their default order.
    public static func orderedGroups(_ by: GroupBy, account: Account, repositories: [String], orders: GroupOrders) -> [GroupItem] {
        let defaults = defaultGroups(by, account: account, repositories: repositories)
        guard let saved = orders[by], !saved.isEmpty else { return defaults }
        var byKey: [String: GroupItem] = [:]
        for item in defaults { byKey[item.key] = item }
        var out = saved.compactMap { byKey.removeValue(forKey: $0) }
        out += defaults.filter { byKey[$0.key] != nil }
        return out
    }

    /// The repositories seen so far: the first ones by name, those that
    /// appear later at the end (DESIGN.md, "All").
    public static func knownRepositories(_ known: [String], cards: [Card]) -> [String] {
        let seen = Set(known)
        let new = Set(cards.map { repository($0.pr) }).subtracting(seen).sorted {
            let (a, b) = ($0.lowercased(), $1.lowercased())
            return a != b ? a < b : $0 < $1
        }
        return known + new
    }

    // MARK: Layout

    /// The fold state of the account and the surface's search.
    public struct Folding: Equatable {
        public var collapsed: Set<String>
        public var expanded: Set<String>
        public var search: String

        public init(collapsed: Set<String> = [], expanded: Set<String> = [], search: String = "") {
            self.collapsed = collapsed
            self.expanded = expanded
            self.search = search
        }
    }

    static func leaf(
        key: String, title: String, level: Int, all: [Card], matching: [Card], folding: Folding, searching: Bool,
        accepts: Bool, isDone: Bool
    ) -> SectionLayout {
        let isCollapsed = level > 0 && folding.collapsed.contains(key)
        let folds = !searching && matching.count >= foldAt
        let expanded = folds && folding.expanded.contains(key)
        let shown = isCollapsed ? [] : (folds && !expanded ? Array(matching.prefix(shownWhenFolded)) : matching)
        let folded = isCollapsed ? [] : Array(matching.dropFirst(shown.count))
        return SectionLayout(
            key: key, title: title, level: level, isLeaf: true, detail: count(all.count), collapsed: isCollapsed,
            cards: shown, more: folded.count, showLess: !isCollapsed && expanded, moreMark: UnreadMark.of(cards: folded),
            matching: matching, accepts: accepts, isDone: isDone
        )
    }

    /// The sections of a tab. `cards` are every card as the daemon sent
    /// them (dismissed ones included). Sections without a card after the
    /// search are left out; the counts ignore the search. Review and Mine
    /// keep their empty sections (Done and Mine's first list included) while
    /// the tab has a card and nothing is searched, so that a card can be
    /// dropped there.
    public static func sections(
        tab: ListTab, cards allCards: [Card], account: Account, options: ListOptions, orders: GroupOrders,
        repositories: [String], folding: Folding
    ) -> [SectionLayout] {
        let tabCards = cards(allCards, tab: tab)
        let searching = !Search.words(folding.search).isEmpty
        let found = Set(search(tabCards, folding.search).map(\.id))
        switch tab {
        case .review, .mine:
            let placementTab: PlacementTab = tab == .review ? .review : .mine
            let sections: [PlacementSection] = tab == .review ? PlacementSection.review : [.main, .done]
            return sections.compactMap { section in
                let all = ranked(tabCards.filter { $0.placement?.section.value == section })
                let matching = all.filter { found.contains($0.id) }
                let keepsEmpty = !searching && !tabCards.isEmpty
                guard !matching.isEmpty || keepsEmpty else { return nil }
                return leaf(
                    key: SectionKey.placed(placementTab, section), title: section.title,
                    level: section == .main ? 0 : 1, all: all, matching: matching, folding: folding, searching: searching,
                    accepts: true, isDone: section == .done
                )
            }
        case .all:
            let first = orderedGroups(options.groupBy, account: account, repositories: repositories, orders: orders)
            let second = options.thenBy == .none
                ? [GroupItem(key: "", title: "")]
                : orderedGroups(options.thenBy, account: account, repositories: repositories, orders: orders)
            var out: [SectionLayout] = []
            for group in first {
                let all = options.groupBy == .none ? tabCards : tabCards.filter { groupKey($0, options.groupBy) == group.key }
                let matching = all.filter { found.contains($0.id) }
                guard !matching.isEmpty else { continue }
                let headerKey = SectionKey.all(options.groupBy, options.thenBy, group.key, "")
                if options.thenBy == .none {
                    out.append(leaf(
                        key: headerKey, title: group.title, level: options.groupBy == .none ? 0 : 1, all: all,
                        matching: sorted(matching, by: options.sort), folding: folding, searching: searching,
                        accepts: false, isDone: false
                    ))
                    continue
                }
                let isCollapsed = folding.collapsed.contains(headerKey)
                out.append(SectionLayout(
                    key: headerKey, title: group.title, level: 1, isLeaf: false, detail: count(all.count),
                    collapsed: isCollapsed, cards: [], more: 0, showLess: false, moreMark: .none,
                    matching: sorted(matching, by: options.sort), accepts: false, isDone: false
                ))
                guard !isCollapsed else { continue }
                for sub in second {
                    let subAll = all.filter { groupKey($0, options.thenBy) == sub.key }
                    let subMatching = sorted(subAll.filter { found.contains($0.id) }, by: options.sort)
                    guard !subMatching.isEmpty else { continue }
                    out.append(leaf(
                        key: SectionKey.all(options.groupBy, options.thenBy, group.key, sub.key), title: sub.title, level: 2,
                        all: subAll, matching: subMatching, folding: folding, searching: searching, accepts: false, isDone: false
                    ))
                }
            }
            return out
        }
    }

    /// The text in place of an empty tab or Dismissed list: `Nothing
    /// matches` when the search leaves no card; nil before the first
    /// answer or when something shows.
    public static func emptyText(loaded: Bool, tab: ListTab?, cards: [Card], search: String) -> String? {
        guard loaded else { return nil }
        let list = tab.map { Self.cards(cards, tab: $0) } ?? dismissed(cards)
        if list.isEmpty {
            switch tab {
            case .all?: return EmptyState.all
            case .review?: return EmptyState.review
            case .mine?: return EmptyState.mine
            case nil: return EmptyState.dismissed
            }
        }
        return Self.search(list, search).isEmpty ? EmptyState.nothingMatches : nil
    }

    /// ⇧R and Mark all as read: every unread row of the tab's cards after
    /// the search, in collapsed and folded sections and in "+ N more" too,
    /// muted rows included (DESIGN.md, "How unread clears").
    public static func rowsToRead(tab: ListTab, cards: [Card], search: String) -> [String] {
        Self.search(Self.cards(cards, tab: tab), search).flatMap(\.rows).filter(\.unread).map(\.id)
    }

    /// The rows a card shows: the newest three, or all while expanded.
    public static func visibleRows(_ card: Card, expanded: Bool) -> [Row] {
        expanded ? card.rows : Array(card.rows.prefix(rowsShown))
    }

    /// "+ N more" in a card, nil when all rows show.
    public static func moreRows(_ card: Card, expanded: Bool) -> Int? {
        guard !expanded, card.rows.count > rowsShown else { return nil }
        return card.rows.count - rowsShown
    }

    public static func moreRowsText(_ count: Int) -> String {
        "+ \(count) more"
    }

    /// The mark of "+ N more" in a card.
    public static func moreRowsMark(_ card: Card) -> UnreadMark {
        UnreadMark.of(Array(card.rows.dropFirst(rowsShown)))
    }

    /// `Older activity on GitHub` ends the expanded rows of a PR that lost
    /// rows past the 20 kept.
    public static func showsOlderActivity(_ card: Card, expanded: Bool) -> Bool {
        expanded && card.olderRows
    }
}
