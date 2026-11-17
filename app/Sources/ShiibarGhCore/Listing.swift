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

    /// The Then by button shows its value, `None` included (DESIGN.md,
    /// "All").
    public var thenByTitle: String {
        thenBy.title
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

    /// Some word is part of the row's text or actor.
    static func rowHasMatch(_ row: Row, words: [String]) -> Bool {
        let lowered = rowFields(row).map { $0.lowercased() }
        return words.contains { word in lowered.contains { $0.contains(word) } }
    }
}

// MARK: - What matched

/// DESIGN.md, "Showing what matched": where the words of the search are
/// found in the text a card shows, for its yellow background. The words are
/// those of `Search.words` (split and lowercased the same way), found
/// case-insensitively, every occurrence of every word, in the displayed
/// strings of the fields the search looks at. Ranges are UTF-16 offsets of
/// the displayed string (how AppKit and CoreText index text), in order and
/// merged where they overlap or touch.
public enum Highlight {
    /// Every occurrence of every word in `text`.
    public static func ranges(_ words: [String], in text: String) -> [Range<Int>] {
        guard !words.isEmpty, !text.isEmpty else { return [] }
        // Lowercased character by character, each lowered character with the
        // UTF-16 range of the character it came from.
        var lowered: [Character] = []
        var origins: [Range<Int>] = []
        var offset = 0
        for character in text {
            let width = character.utf16.count
            for lower in String(character).lowercased() {
                lowered.append(lower)
                origins.append(offset..<(offset + width))
            }
            offset += width
        }
        var found: [Range<Int>] = []
        for word in words {
            let pattern = Array(word)
            guard !pattern.isEmpty, pattern.count <= lowered.count else { continue }
            for start in 0...(lowered.count - pattern.count) where lowered[start] == pattern[0] {
                var i = 1
                while i < pattern.count, lowered[start + i] == pattern[i] { i += 1 }
                if i == pattern.count {
                    found.append(origins[start].lowerBound..<origins[start + pattern.count - 1].upperBound)
                }
            }
        }
        return merged(found)
    }

    static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
            if let last = out.last, range.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }

    static func shifted(_ ranges: [Range<Int>], by delta: Int) -> [Range<Int>] {
        ranges.map { ($0.lowerBound + delta)..<($0.upperBound + delta) }
    }

    /// `owner/repo #123` (`Warnings.prLabel`), found in `owner/repo#123` as
    /// the search finds it: a match across the `#` (`api#407`) marks the
    /// displayed characters on both sides of the space.
    public static func prLabel(_ words: [String], pr: String) -> [Range<Int>] {
        let found = ranges(words, in: pr)
        guard let hash = pr.lastIndex(of: "#") else { return found }
        let at = pr[..<hash].utf16.count
        var out: [Range<Int>] = []
        for range in found {
            if range.upperBound <= at {
                out.append(range)
            } else if range.lowerBound >= at {
                out.append((range.lowerBound + 1)..<(range.upperBound + 1))
            } else {
                out.append(range.lowerBound..<at)
                out.append((at + 1)..<(range.upperBound + 1))
            }
        }
        return out
    }

    /// `base ← head`, as line 3 of a card shows them.
    public static func baseHead(_ words: [String], base: String, head: String) -> [Range<Int>] {
        ranges(words, in: base) + shifted(ranges(words, in: head), by: base.utf16.count + " \u{2190} ".utf16.count)
    }

    /// The author in line 3's times (`opened 3 days ago by alice · updated
    /// 2 hr ago`, `CardText.times`): the login only.
    public static func author(_ words: [String], author: String, times: String) -> [Range<Int>] {
        guard !author.isEmpty, let at = times.range(of: "by \(author) \u{00B7} ") else { return [] }
        return shifted(ranges(words, in: author), by: times[..<at.lowerBound].utf16.count + 3)
    }

    /// The matches in a row's displayed meta (`alice · 9 min ago`: the actor
    /// only, not the time) and body (the text; `by alice`: the actor only;
    /// a reaction's quoted text: the text only).
    public struct RowMatches: Equatable {
        public var meta: [Range<Int>] = []
        public var body: [Range<Int>] = []
    }

    public static func row(_ words: [String], _ row: Row, _ p: RowPresentation) -> RowMatches {
        var out = RowMatches()
        guard !words.isEmpty else { return out }
        let actor = row.actor.flatMap { $0.isEmpty ? nil : $0 }
        if let actor, p.meta.hasPrefix(actor + " \u{00B7} ") {
            out.meta = ranges(words, in: actor)
        }
        guard let body = p.body else { return out }
        let text = row.text.map(RowText.normalize).flatMap { $0.isEmpty ? nil : $0 }
        if let text, body == text {
            out.body = ranges(words, in: text)
        } else if let text, body == "\u{201C}\(text)\u{201D}" {
            out.body = shifted(ranges(words, in: text), by: 1)
        } else if text == nil, let actor, body == "by \(actor)" {
            out.body = shifted(ranges(words, in: actor), by: 3)
        }
        return out
    }

    /// Some match is in the part of a text cut off with "…" (`shownEnd`:
    /// the UTF-16 offset where the shown text ends; nil when all of it
    /// shows): the "…" gets the background, and a collapsed row body's
    /// `more` too. Whether a match shows as well does not matter.
    public static func hidesMatch(_ found: [Range<Int>], shownEnd: Int?) -> Bool {
        guard let shownEnd else { return false }
        return found.contains { $0.upperBound > shownEnd }
    }

    /// Some match shows: its start is before where the shown text ends.
    public static func showsMatch(_ found: [Range<Int>], shownEnd: Int?) -> Bool {
        guard let shownEnd else { return !found.isEmpty }
        return found.contains { $0.lowerBound < shownEnd }
    }

    /// The card's "+ N more" gets the background: a row folded into it
    /// matches (its text or actor), whatever the rows shown match.
    public static func marksMoreRows(_ card: Card, words: [String], expanded: Bool) -> Bool {
        guard !words.isEmpty, Listing.moreRows(card, expanded: expanded) != nil else { return false }
        return card.rows.dropFirst(Listing.rowsShown).contains { Search.rowHasMatch($0, words: words) }
    }

    /// A text the card shows, for `shownEnd` (the app lays the text out).
    public enum CutText: Hashable {
        case prLabel, title, baseHead
        /// A row's body as it shows now (collapsed or expanded).
        case body(row: String)
    }

    /// The matches of a text and whether its "…" gets the background.
    public struct TextMarks: Equatable {
        public var found: [Range<Int>] = []
        public var ellipsis = false
        public var shows = false

        public init(_ found: [Range<Int>], shownEnd: () -> Int?) {
            self.found = found
            guard !found.isEmpty else { return }
            let end = shownEnd()
            ellipsis = Highlight.hidesMatch(found, shownEnd: end)
            shows = Highlight.showsMatch(found, shownEnd: end)
        }

        public init() {}

        var yellow: Bool { shows || ellipsis }
    }

    public struct RowMarks: Equatable {
        public var meta: [Range<Int>] = []
        public var body = TextMarks()
        /// The row's `more` (collapsed, with a match in the part it hides).
        public var more = false
    }

    /// Everything of a card that gets the yellow background (DESIGN.md,
    /// "Showing what matched").
    public struct CardMarks: Equatable {
        public var prLabel = TextMarks()
        public var title = TextMarks()
        public var baseHead = TextMarks()
        public var author: [Range<Int>] = []
        public var rows: [String: RowMarks] = [:]
        public var moreRows = false

        /// Some yellow background shows on the card. With search text,
        /// every card shown has one, except in Compact a card matched only
        /// by what its heading does not show.
        public var anyYellow: Bool {
            prLabel.yellow || title.yellow || baseHead.yellow || !author.isEmpty || moreRows
                || rows.values.contains { !$0.meta.isEmpty || $0.body.yellow || $0.more }
        }
    }

    /// The marks of a card shown with `words`. `shownEnd` gives where the
    /// shown part of a text ends (nil: all of it shows); it is asked only
    /// for texts with matches. `expandedBodies`: the rows whose `more` was
    /// pressed. Compact: the heading only.
    public static func card(
        _ card: Card, words: [String], now: Int64, expanded: Bool, expandedBodies: Set<String>, compact: Bool,
        shownEnd: (CutText, String) -> Int?
    ) -> CardMarks {
        var marks = CardMarks()
        guard !words.isEmpty else { return marks }
        let label = Warnings.prLabel(card.pr)
        marks.prLabel = TextMarks(prLabel(words, pr: card.pr)) { shownEnd(.prLabel, label) }
        marks.title = TextMarks(ranges(words, in: card.title)) { shownEnd(.title, card.title) }
        let baseHead = "\(card.base) \u{2190} \(card.head)"
        marks.baseHead = TextMarks(self.baseHead(words, base: card.base, head: card.head)) { shownEnd(.baseHead, baseHead) }
        marks.author = author(words, author: card.author, times: CardText.times(card, now: now))
        guard !compact else { return marks }
        for row in Listing.visibleRows(card, expanded: expanded) {
            let open = expandedBodies.contains(row.id)
            let p = RowPresentation(row, now: now, cardMuted: card.isMuted, expanded: open)
            let found = self.row(words, row, p)
            var rowMarks = RowMarks(meta: found.meta)
            if let body = p.body {
                rowMarks.body = TextMarks(found.body) { shownEnd(.body(row: row.id), body) }
                rowMarks.more = !open && rowMarks.body.ellipsis
            }
            marks.rows[row.id] = rowMarks
        }
        marks.moreRows = marksMoreRows(card, words: words, expanded: expanded)
        return marks
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
        }
    }

    /// The sections of Review and of Mine from the top (DESIGN.md,
    /// "Review", "Mine").
    public static let order: [PlacementSection] = [.doing, .todo, .waiting, .done]
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

    /// The placement tag of All, the tab and the section: `Review · Todo`,
    /// `Mine · Waiting` (DESIGN.md, "All").
    public var placementTag: String? {
        guard let placement, let tab = placement.tab.value, let section = placement.section.value else { return nil }
        let name: String
        switch tab {
        case .review: name = "Review"
        case .mine: name = "Mine"
        }
        return name + " \u{00B7} " + section.title
    }

    /// The card's section key in its own tab, nil without a placement.
    public var sectionKey: String? {
        guard let placement, let tab = placement.tab.value, let section = placement.section.value else { return nil }
        return SectionKey.placed(tab, section)
    }

    /// Dragging: placed in Review or Mine, Done included; a muted card
    /// the Filter shows too (DESIGN.md, "What a press does").
    public var canDrag: Bool {
        guard let placement, placement.section.value != nil else { return false }
        return true
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
    /// 0: no heading (Group by None); 1: a band; 2: an indented small
    /// heading.
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

    /// The cards `Dismiss all` dismisses, nil when the heading does not
    /// show it (DESIGN.md, "Dismiss", "`Dismiss all`"): the Done of Review
    /// or Mine, not collapsed, with two or more cards the Filter and the
    /// search leave (folded ones included: `matching`). One card has its own
    /// ×, which does the same. The heading's count ignores the search, so
    /// this can be fewer.
    public var dismissAllCards: [Card]? {
        guard accepts, isDone, !collapsed, matching.count >= 2 else { return nil }
        return matching
    }
}

/// A repository of the Dismissed list: its heading (`owner/repo` and the
/// count of its dismissed cards, whatever the search) and its cards after
/// the search.
public struct DismissedGroup: Equatable {
    public var repository: String
    /// `3 PRs`.
    public var detail: String
    public var cards: [Card]
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

    /// The cards of a tab, not dismissed, muted ones included.
    public static func cards(_ cards: [Card], tab: ListTab) -> [Card] {
        cards.filter { !$0.isDismissed && (tab == .all || $0.tab == tab) }
    }

    /// The cards a tab shows before the search: those its Filter does not
    /// hide (DESIGN.md, "Filter").
    public static func shown(_ cards: [Card], tab: ListTab, visibility: Visibility) -> [Card] {
        Self.cards(cards, tab: tab).filter(visibility.shows)
    }

    /// The unread count of a tab: its cards with a colored unread row, whatever
    /// the Filter and the search; muted gray ones do not count, a hidden
    /// muted card with an unread mention does (DESIGN.md, "Tabs").
    public static func unreadCount(_ cards: [Card], tab: ListTab) -> Int {
        Self.cards(cards, tab: tab).filter(\.hasBlueUnread).count
    }

    /// The accent-colored dot of `Filter`: a card of this tab that the Filter hides
    /// has a colored unread row. The search does not count (DESIGN.md,
    /// "Filter", "Accent-color dot"); `Unread only` never hides such a card.
    public static func filterDot(_ cards: [Card], tab: ListTab, filter: ListFilter) -> Bool {
        Self.cards(cards, tab: tab).contains { $0.hasBlueUnread && !filter.shows($0, kept: false) }
    }

    /// The status of a PR: Group by Status and the Filter's statuses.
    public static func status(_ card: Card) -> PRStatus {
        switch card.stateLabel.value {
        case .draft: return .draft
        case .merged: return .merged
        case .closed: return .closed
        case .open, .mergeable, nil: return .open
        }
    }

    /// The Dismissed list: newest dismissal first.
    public static func dismissed(_ cards: [Card]) -> [Card] {
        cards.filter(\.isDismissed).sorted {
            let (a, b) = ($0.dismissedAt ?? 0, $1.dismissedAt ?? 0)
            return a != b ? a > b : $0.id < $1.id
        }
    }

    /// The Dismissed list by repository (DESIGN.md, "Dismissed list"): the
    /// groups newest dismissal first by the newest dismissal in each, the
    /// same time by `owner/repo` ignoring case; the cards of a group as in
    /// `dismissed`. The order and the counts come from every dismissed card,
    /// whatever the search; a group the search leaves no card in is left
    /// out.
    public static func dismissedGroups(_ cards: [Card], search text: String) -> [DismissedGroup] {
        var groups: [String: [Card]] = [:]
        var newest: [String: Int64] = [:]
        for card in dismissed(cards) {
            let repo = repository(card.pr)
            groups[repo, default: []].append(card)
            newest[repo] = max(newest[repo] ?? Int64.min, card.dismissedAt ?? 0)
        }
        let order = groups.keys.sorted { a, b in
            let (ta, tb) = (newest[a] ?? 0, newest[b] ?? 0)
            if ta != tb { return ta > tb }
            let (la, lb) = (a.lowercased(), b.lowercased())
            return la != lb ? la < lb : a < b
        }
        return order.compactMap { repo in
            let all = groups[repo] ?? []
            let matching = search(all, text)
            guard !matching.isEmpty else { return nil }
            return DismissedGroup(repository: repo, detail: count(all.count), cards: matching)
        }
    }

    public static func search(_ cards: [Card], _ text: String) -> [Card] {
        let words = Search.words(text)
        return words.isEmpty ? cards : cards.filter { Search.matches($0, words: words) }
    }

    // MARK: Order

    /// All's order inside the innermost group (DESIGN.md, "All"): open PRs
    /// (Draft included) first, then Merged and Closed, each newest first by
    /// the chosen order; muted cards the Filter shows are placed by the
    /// same rule.
    public static func sorted(_ cards: [Card], by order: SortOrder) -> [Card] {
        cards.sorted { a, b in
            if a.isFinished != b.isFinished { return !a.isFinished }
            let (ka, kb): (Int64, Int64) = order == .recentlyUpdated
                ? (a.updatedAt, b.updatedAt)
                : (a.addedAt ?? 0, b.addedAt ?? 0)
            if ka != kb { return ka > kb }
            return a.id < b.id
        }
    }

    /// Review and Mine: the daemon's rank, muted cards included.
    public static func ranked(_ cards: [Card]) -> [Card] {
        cards.sorted { a, b in
            let (pa, pb) = (a.placement?.position ?? 0, b.placement?.position ?? 0)
            if pa != pb { return pa < pb }
            return a.id < b.id
        }
    }

    // MARK: Groups

    static let statusGroups = PRStatus.allCases.map { ($0.rawValue, $0.title) }
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
            return status(card).rawValue
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

    /// The fold state of the account, the surface's search and what the
    /// tab's Filter shows.
    public struct Folding: Equatable {
        public var collapsed: Set<String>
        public var expanded: Set<String>
        public var search: String
        public var visibility: Visibility

        public init(collapsed: Set<String> = [], expanded: Set<String> = [], search: String = "", visibility: Visibility) {
            self.collapsed = collapsed
            self.expanded = expanded
            self.search = search
            self.visibility = visibility
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
    /// them (dismissed ones included). The cards the Filter hides are left
    /// out of everything: the sections, the counts, "+ N more PRs" and the
    /// groups (DESIGN.md, "Filter"). Sections without a
    /// card after the search are left out; the counts ignore the search.
    /// Review and Mine keep their empty sections (Done included) while the
    /// tab shows a card and nothing is searched, so that a card can be
    /// dropped there.
    public static func sections(
        tab: ListTab, cards allCards: [Card], account: Account, options: ListOptions, orders: GroupOrders,
        repositories: [String], folding: Folding
    ) -> [SectionLayout] {
        let tabCards = shown(allCards, tab: tab, visibility: folding.visibility)
        let searching = !Search.words(folding.search).isEmpty
        let found = Set(search(tabCards, folding.search).map(\.id))
        switch tab {
        case .review, .mine:
            let placementTab: PlacementTab = tab == .review ? .review : .mine
            return PlacementSection.order.compactMap { section in
                let all = ranked(tabCards.filter { $0.placement?.section.value == section })
                let matching = all.filter { found.contains($0.id) }
                let keepsEmpty = !searching && !tabCards.isEmpty
                guard !matching.isEmpty || keepsEmpty else { return nil }
                return leaf(
                    key: SectionKey.placed(placementTab, section), title: section.title,
                    level: 1, all: all, matching: matching, folding: folding, searching: searching,
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

    /// The text in place of an empty tab: when no card shows, `Nothing
    /// matches` if there is search text or the Filter is not at its
    /// defaults, else the tab's own text (DESIGN.md, "First run, failure
    /// and empty"); nil before the first answer or when something shows.
    public static func emptyText(loaded: Bool, tab: ListTab, cards: [Card], search: String, visibility: Visibility) -> String? {
        guard loaded else { return nil }
        guard Self.search(shown(cards, tab: tab, visibility: visibility), search).isEmpty else { return nil }
        if !Search.words(search).isEmpty || !visibility.filter.isDefault { return EmptyState.nothingMatches }
        switch tab {
        case .all: return EmptyState.all
        case .review: return EmptyState.review
        case .mine: return EmptyState.mine
        }
    }

    /// The text in place of an empty Dismissed list (no Filter there):
    /// `Nothing matches` when its search leaves no card.
    public static func dismissedEmptyText(loaded: Bool, cards: [Card], search: String) -> String? {
        guard loaded else { return nil }
        let list = dismissed(cards)
        if list.isEmpty { return EmptyState.dismissed }
        return Self.search(list, search).isEmpty ? EmptyState.nothingMatches : nil
    }

    /// ⇧R and Mark all as read: every unread row of the tab's cards after
    /// the search, in collapsed and folded sections and in "+ N more" too,
    /// muted rows of muted cards the Filter shows included; not those of
    /// the cards the Filter hides (DESIGN.md, "How unread clears").
    public static func rowsToRead(tab: ListTab, cards: [Card], search: String, visibility: Visibility) -> [String] {
        Self.search(shown(cards, tab: tab, visibility: visibility), search).flatMap(\.rows).filter(\.unread).map(\.id)
    }

    /// Whether a card's rows show past the newest three: it is expanded and
    /// has more than three.
    static func rowsExpanded(_ card: Card, _ expanded: Bool) -> Bool {
        expanded && card.rows.count > rowsShown
    }

    /// The rows a card shows: the newest three, or all while expanded.
    public static func visibleRows(_ card: Card, expanded: Bool) -> [Row] {
        rowsExpanded(card, expanded) ? card.rows : Array(card.rows.prefix(rowsShown))
    }

    /// "+ N more" in a card, nil when all rows show.
    public static func moreRows(_ card: Card, expanded: Bool) -> Int? {
        guard !rowsExpanded(card, expanded), card.rows.count > rowsShown else { return nil }
        return card.rows.count - rowsShown
    }

    /// `Show less` at the end of a card's expanded rows (DESIGN.md, "Rows in
    /// a card"): it stays until pressed.
    public static func showsLessRows(_ card: Card, expanded: Bool) -> Bool {
        rowsExpanded(card, expanded)
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
        rowsExpanded(card, expanded) && card.olderRows
    }
}
