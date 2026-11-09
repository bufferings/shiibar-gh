// What the popover lists, worked out by the app from the unfiltered `list`
// and `activity` answers (DESIGN.md, "What the filters mean"): the chips,
// the search, Group by, the sort order and "+ N more PRs" (DESIGN.md,
// "Screens" and "PRs tab sections").

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

/// The chip, Group by and the sort order: remembered per account (DESIGN.md,
/// "Saved state"). The chip keeps the name `segment` of 0.2, so the chip
/// saved by 0.2 carries over; fields missing from saved data take their
/// defaults.
public struct ListOptions: Equatable, Codable {
    public var segment: PrFilter
    public var groupBy: GroupBy
    public var sort: SortOrder

    public init(segment: PrFilter = .all, groupBy: GroupBy = .owner, sort: SortOrder = .recentlyUpdated) {
        self.segment = segment
        self.groupBy = groupBy
        self.sort = sort
    }

    enum CodingKeys: String, CodingKey { case segment, groupBy, sort }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segment = (try? c.decodeIfPresent(PrFilter.self, forKey: .segment)) ?? .all
        groupBy = (try? c.decodeIfPresent(GroupBy.self, forKey: .groupBy)) ?? .owner
        sort = (try? c.decodeIfPresent(SortOrder.self, forKey: .sort)) ?? .recentlyUpdated
    }

    public static func title(_ segment: PrFilter) -> String {
        switch segment {
        case .all: return "All"
        case .authored: return "Authored by me"
        case .assigned: return "Assigned to me"
        case .reviewRequested: return "Review requested"
        }
    }
}

extension PrFilter {
    /// DESIGN.md, "What the filters mean". Review requested is GitHub's
    /// fact (`review_requested`), not the app's "waiting for your review".
    public func admits(_ card: Card) -> Bool {
        switch self {
        case .all: return true
        case .authored: return card.authoredByMe
        case .assigned: return card.assignedToMe
        case .reviewRequested: return card.reviewRequested
        }
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

    /// An Activity row matches with its PR's fields or its own text and
    /// actor. Without the card, the row's `pr` and `pr_title` stand for it.
    public static func matches(_ row: Row, card: Card?, words: [String]) -> Bool {
        let pr = card.map(prFields) ?? [row.prTitle, row.pr]
        return matches(words, fields: pr + rowFields(row))
    }
}

// MARK: - Sections

/// A section of the PRs tab.
public struct SectionLayout: Equatable, Identifiable {
    public static let snoozedKey = "snoozed"
    public static let noneKey = "none"

    public var key: String
    public var title: String
    /// False for the one list of Group by None.
    public var showsHeader: Bool
    public var isSnoozed: Bool
    /// The red number: PRs waiting for your review; nil when 0.
    public var reviewCount: Int?
    /// "4 PRs", or "2 PRs · until Mon 09:00" for Snoozed.
    public var detail: String
    public var collapsed: Bool
    /// The cards laid out (none while collapsed, folded ones left out).
    public var cards: [Card]
    /// "+ N more PRs".
    public var more: Int
    /// Every card that passes the chip and the search, collapsed or folded
    /// ones too, in order.
    public var matching: [Card]

    public var id: String { key }

    public static func ownerKey(_ owner: String) -> String { "owner:" + owner }

    public var moreText: String? {
        more > 0 ? "+ \(more) more " + (more == 1 ? "PR" : "PRs") : nil
    }
}

/// When "+ N more PRs" folds a PR (DESIGN.md, "PRs tab sections"): decided
/// for every PR when the popover opens, and for a PR when it first appears.
/// While open, decisions only move toward shown: a PR left out of the fold
/// stays out, and a folded PR that gets an unread row (or starts waiting
/// for your review) comes out at once.
public struct FoldState: Equatable {
    /// The PRs decided to stay out of the fold.
    public private(set) var unfolded: Set<String> = []
    private var decideAll = false

    public init() {}

    /// A PR with unread rows or waiting for your review stays out.
    public static func staysOut(_ card: Card) -> Bool {
        card.hasUnread || card.awaitingReview
    }

    /// Decide every PR again now.
    public mutating func decide(_ cards: [Card]) {
        unfolded = Set(cards.filter(Self.staysOut).map(\.id))
        decideAll = false
    }

    /// Decide every PR again when the next list arrives (the popover opened).
    public mutating func decideOnNextList() {
        decideAll = true
    }

    /// A new list: PRs that need to be out come out; none goes back in.
    public mutating func update(_ cards: [Card]) {
        if decideAll {
            decide(cards)
            return
        }
        for card in cards where Self.staysOut(card) {
            unfolded.insert(card.id)
        }
    }
}

public enum Listing {
    static func count(_ n: Int) -> String { n == 1 ? "1 PR" : "\(n) PRs" }

    /// Open PRs (Draft included) first, then Merged and Closed; inside each,
    /// the chosen order, newest first; the id breaks ties.
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

    /// `owner/repo` of `owner/repo#123`.
    public static func repository(_ pr: String) -> String {
        guard let hash = pr.lastIndex(of: "#") else { return pr }
        return String(pr[..<hash])
    }

    struct Group {
        var key: String
        var title: String
        var cards: [Card]
    }

    /// The sections of a Group by in their order, each with its cards
    /// before the chips and the search.
    static func groups(_ cards: [Card], by groupBy: GroupBy, account: Account) -> [Group] {
        switch groupBy {
        case .owner:
            return account.owners.filter(\.enabled).map { owner in
                Group(key: SectionLayout.ownerKey(owner.id), title: owner.displayName, cards: cards.filter { $0.owner == owner.id })
            }
        case .repository:
            let names = Set(cards.map { repository($0.pr) }).sorted {
                let (a, b) = ($0.lowercased(), $1.lowercased())
                return a != b ? a < b : $0 < $1
            }
            return names.map { name in
                Group(key: "repo:" + name, title: name, cards: cards.filter { repository($0.pr) == name })
            }
        case .status:
            func status(_ card: Card) -> String {
                switch card.stateLabel.value {
                case .draft: return "draft"
                case .merged: return "merged"
                case .closed: return "closed"
                case .open, .mergeable, nil: return "open"
                }
            }
            return [("open", "Open"), ("draft", "Draft"), ("merged", "Merged"), ("closed", "Closed")].map { key, title in
                Group(key: "status:" + key, title: title, cards: cards.filter { status($0) == key })
            }
        case .involvement:
            func involvement(_ card: Card) -> String {
                if card.reviewRequested { return "review_requested" }
                if card.authoredByMe { return "authored" }
                if card.assignedToMe { return "assigned" }
                return "others"
            }
            return [
                ("review_requested", "Review requested"), ("authored", "Authored by me"),
                ("assigned", "Assigned to me"), ("others", "Others"),
            ].map { key, title in
                Group(key: "involvement:" + key, title: title, cards: cards.filter { involvement($0) == key })
            }
        case .none:
            return [Group(key: SectionLayout.noneKey, title: "", cards: cards)]
        }
    }

    /// The key a fold is remembered under: per Group by and section. Owner
    /// sections and Snoozed under Owner keep the keys of 0.2.
    public static func collapseKey(_ groupBy: GroupBy, _ section: String) -> String {
        groupBy == .owner ? section : groupBy.rawValue + "|" + section
    }

    /// The PRs tab. `cards` are the unsnoozed cards and `snoozed` the
    /// snoozed ones, both as the daemon sent them (no filters). Sections
    /// without a card after the chip and the search are left out; Snoozed
    /// stays while any PR is snoozed. Counts ignore the chip and the search.
    public static func sections(
        account: Account, cards: [Card], snoozed: [Card], options: ListOptions, search: String,
        collapsed: [String: Bool], expanded: Set<String>, fold: FoldState, timeZone: TimeZone = .current
    ) -> [SectionLayout] {
        let words = Search.words(search)
        func passes(_ card: Card) -> Bool { options.segment.admits(card) && Search.matches(card, words: words) }
        var out: [SectionLayout] = []
        for group in groups(cards, by: options.groupBy, account: account) {
            let matching = sorted(group.cards.filter(passes), by: options.sort)
            guard !matching.isEmpty else { continue }
            let isNone = options.groupBy == .none
            let isCollapsed = isNone ? false : collapsed[collapseKey(options.groupBy, group.key)] ?? false
            let open = !words.isEmpty || expanded.contains(group.key)
            let shown = open ? matching : matching.filter { fold.unfolded.contains($0.id) }
            let review = group.cards.filter(\.awaitingReview).count
            out.append(SectionLayout(
                key: group.key, title: group.title, showsHeader: !isNone, isSnoozed: false,
                reviewCount: review > 0 ? review : nil, detail: count(group.cards.count), collapsed: isCollapsed,
                cards: isCollapsed ? [] : shown, more: isCollapsed ? 0 : matching.count - shown.count, matching: matching
            ))
        }
        if !snoozed.isEmpty {
            let key = SectionLayout.snoozedKey
            let isCollapsed = collapsed[collapseKey(options.groupBy, key)] ?? true
            var detail = count(snoozed.count)
            if let until = snoozed.compactMap(\.snoozedUntil).first {
                detail += " · until " + RelativeTime.weekdayClock(until, timeZone: timeZone)
            }
            let matching = sorted(snoozed.filter(passes), by: options.sort)
            out.append(SectionLayout(
                key: key, title: "Snoozed", showsHeader: true, isSnoozed: true, reviewCount: nil, detail: detail,
                collapsed: isCollapsed, cards: isCollapsed ? [] : matching, more: 0, matching: matching
            ))
        }
        return out
    }

    /// "Nothing needs you" without unsnoozed cards, "Nothing matches" when
    /// the chip and the search leave none; nil otherwise or before the
    /// first answer.
    public static func emptyText(loaded: Bool, cards: [Card], options: ListOptions, search: String) -> String? {
        guard loaded else { return nil }
        if cards.isEmpty { return EmptyState.cards(filtered: false) }
        let words = Search.words(search)
        let any = cards.contains { options.segment.admits($0) && Search.matches($0, words: words) }
        return any ? nil : EmptyState.cards(filtered: true)
    }

    /// The Activity tab: the rows of the owners on (all with `All owners`),
    /// whose PR passes the chip, matching the search. `cards` find each
    /// row's PR.
    public static func activity(
        _ rows: [Row], cards: [Card], segment: PrFilter, owners: Set<String>, search: String
    ) -> [Row] {
        let words = Search.words(search)
        var byPR: [String: Card] = [:]
        for card in cards { byPR[card.pr] = card }
        return rows.filter { row in
            if !owners.isEmpty && !owners.contains(row.owner) { return false }
            let card = byPR[row.pr]
            if segment != .all && !(card.map(segment.admits) ?? false) { return false }
            return Search.matches(row, card: card, words: words)
        }
    }

    /// "No activity", or "Nothing matches" when the chip, the owner buttons
    /// or the search leave no row.
    public static func activityEmptyText(loaded: Bool, all: [Row], shown: [Row]) -> String? {
        guard loaded, shown.isEmpty else { return nil }
        return all.isEmpty ? EmptyState.activity : EmptyState.cards(filtered: true)
    }

    /// ⇧R and Mark all as read: the unread rows of the tab as displayed now,
    /// after the chip, the search and the owner buttons; collapsed sections
    /// count, Snoozed does not (DESIGN.md, "How unread clears"). Rows
    /// already read need nothing, so only unread ids go out.
    public static func rowsToRead(tab: PopoverTab, sections: [SectionLayout], activity: [Row]) -> [String] {
        switch tab {
        case .prs:
            return sections.filter { !$0.isSnoozed }.flatMap(\.matching).flatMap(\.rows).filter(\.unread).map(\.id)
        case .activity:
            return activity.filter(\.unread).map(\.id)
        }
    }
}

// MARK: - Activity owner buttons

public enum ActivityOwners {
    /// The buttons after `All owners`: the enabled owners.
    public static func buttons(_ account: Account) -> [Owner] {
        account.owners.filter(\.enabled)
    }

    /// The remembered owners that still count: removed and disabled ones
    /// are ignored.
    public static func effective(_ selected: Set<String>, account: Account) -> Set<String> {
        Set(buttons(account).map(\.id)).intersection(selected)
    }

    /// `All owners` is on while no owner counts, even when every owner is
    /// on one by one.
    public static func allOwnersOn(_ selected: Set<String>, account: Account) -> Bool {
        effective(selected, account: account).isEmpty
    }
}
