// The Filter of a tab (DESIGN.md, "Filter"): what it hides (Mute, the PR
// status, `Unread only`), its summary, its accent-colored dot, and the cards that
// `Unread only` keeps for a while after they are read ("A card read under
// `Unread only`"). Each of All, Review and Mine has its own settings, kept
// per account; the Dismissed list has none.

import Foundation

/// The texts of `Filter` (DESIGN.md, "Filter").
public enum FilterText {
    /// The tooltip of the accent-colored dot.
    public static let dotTip = "Unread pull requests are hidden by the filter"
    /// The button under the options, at the right end.
    public static let reset = "Reset"
    /// The search field's clear button: its tooltip and its name for
    /// assistive apps.
    public static let clearSearch = "Clear"
    public static let clearSearchLabel = "Clear search"
}

/// Whose search text: a tab's, or the Dismissed list's (DESIGN.md, "Search
/// field"). Each is kept per account, like the Filter.
public enum SearchScope: Hashable {
    case tab(ListTab)
    case dismissed

    public static let all: [SearchScope] = ListTab.allCases.map(SearchScope.tab) + [.dismissed]

    /// The key it is saved under.
    public var key: String {
        switch self {
        case .tab(let tab): return tab.rawValue
        case .dismissed: return "dismissed"
        }
    }

    public init?(key: String) {
        if key == "dismissed" {
            self = .dismissed
        } else if let tab = ListTab(rawValue: key) {
            self = .tab(tab)
        } else {
            return nil
        }
    }
}

/// One line of the Filter's options, in the order they show: the same three
/// in every tab, in the order of the summary (DESIGN.md, "Filter"). Group
/// by, Then by and Sort are not here: they are in the Grouping sheet.
public enum FilterOption: CaseIterable {
    case status, muted, unread

    /// The name at the left of the line.
    public var title: String {
        switch self {
        case .status: return "Status"
        case .muted: return "Muted"
        case .unread: return "Unread"
        }
    }
}

/// Filter › Muted: hide the muted cards (the default), show them in gray at
/// their places, or show them only.
public enum MuteChoice: String, Equatable, Codable, CaseIterable {
    case hide, show, only

    public var title: String {
        switch self {
        case .hide: return "Hide"
        case .show: return "Show"
        case .only: return "Only"
        }
    }
}

/// The status of a PR, as Group by Status sorts it (DESIGN.md, "All"):
/// Open (Mergeable included), Draft, Merged, Closed.
public enum PRStatus: String, Equatable, Codable, CaseIterable {
    case open, draft, merged, closed

    public var title: String {
        switch self {
        case .open: return "Open"
        case .draft: return "Draft"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }
}

/// The settings of one tab's Filter. The default hides the muted cards
/// only.
public struct ListFilter: Equatable, Codable {
    public var muted: MuteChoice
    /// The statuses shown; never empty.
    public private(set) var statuses: Set<PRStatus>
    /// Hide the cards without a colored unread row.
    public var unreadOnly: Bool

    public static let allStatuses = Set(PRStatus.allCases)

    public init(muted: MuteChoice = .hide, statuses: Set<PRStatus> = ListFilter.allStatuses, unreadOnly: Bool = false) {
        self.muted = muted
        self.statuses = statuses.isEmpty ? Self.allStatuses : statuses
        self.unreadOnly = unreadOnly
    }

    enum CodingKeys: String, CodingKey { case muted, statuses, unreadOnly }

    /// Values it does not know are left at their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let names = (try? c.decodeIfPresent([String].self, forKey: .statuses)) ?? nil
        self.init(
            muted: (try? c.decodeIfPresent(MuteChoice.self, forKey: .muted)) ?? .hide,
            statuses: names.map { Set($0.compactMap(PRStatus.init(rawValue:))) } ?? Self.allStatuses,
            unreadOnly: (try? c.decodeIfPresent(Bool.self, forKey: .unreadOnly)) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(muted, forKey: .muted)
        try c.encode(PRStatus.allCases.filter(statuses.contains).map(\.rawValue), forKey: .statuses)
        try c.encode(unreadOnly, forKey: .unreadOnly)
    }

    public func shows(_ status: PRStatus) -> Bool {
        statuses.contains(status)
    }

    /// A status on or off. The last one on stays on (DESIGN.md, "Filter":
    /// pressing it does nothing).
    public mutating func setStatus(_ status: PRStatus, _ on: Bool) {
        if on {
            statuses.insert(status)
        } else if statuses != [status] {
            statuses.remove(status)
        }
    }

    /// Whether pressing the status turns it off: not the last one on.
    public func canTurnOff(_ status: PRStatus) -> Bool {
        statuses.contains(status) && statuses.count > 1
    }

    /// Nothing changed from the defaults (Muted Hide, every status, not
    /// Unread only): an empty tab reads its own text, not `Nothing matches`.
    public var isDefault: Bool {
        self == ListFilter()
    }

    /// The summary in the Filter row: the settings changed from the
    /// defaults, the statuses first, then Mute, then `Unread only`, joined
    /// by ` · `; nil when nothing changed (then no summary). Hide is
    /// the default and is not shown.
    public var summary: String? {
        var parts: [String] = []
        if statuses != Self.allStatuses {
            parts += PRStatus.allCases.filter(statuses.contains).map(\.title)
        }
        switch muted {
        case .hide: break
        case .show: parts.append("Muted shown")
        case .only: parts.append("Muted only")
        }
        if unreadOnly { parts.append("Unread only") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: What it hides

    /// Mute hides the card: a muted one under Hide, one not muted under
    /// Only.
    public func hidesByMute(_ card: Card) -> Bool {
        switch muted {
        case .hide: return card.isMuted
        case .show: return false
        case .only: return !card.isMuted
        }
    }

    public func hidesByStatus(_ card: Card) -> Bool {
        !statuses.contains(Listing.status(card))
    }

    /// `Unread only` hides the card: no colored unread row (the rule of the
    /// tabs' unread counts; a card with gray unread rows only is hidden).
    public func hidesByUnread(_ card: Card) -> Bool {
        unreadOnly && !card.hasBlueUnread
    }

    /// The one rule of what the Filter shows. `kept`: `Unread only` keeps
    /// showing the card for now (`UnreadLinger`).
    public func shows(_ card: Card, kept: Bool) -> Bool {
        !hidesByMute(card) && !hidesByStatus(card) && (kept || !hidesByUnread(card))
    }

    /// The tab opened to select `card` (a placement tag, a notification):
    /// only the settings that hide it change (DESIGN.md, "Filter", "Opening
    /// a tab to select a card"). Mute goes to Show, its status is turned
    /// on, `Unread only` off.
    public func revealing(_ card: Card) -> ListFilter {
        var next = self
        if hidesByMute(card) { next.muted = .show }
        if hidesByStatus(card) { next.setStatus(Listing.status(card), true) }
        if hidesByUnread(card) { next.unreadOnly = false }
        return next
    }
}

/// What a tab shows of its cards: its Filter, and the cards `Unread only`
/// keeps showing after they were read (`UnreadLinger`). Every list of a
/// tab (the sections, the counts, "+ N more PRs", ⇧R, the selection, the
/// places of a drop) takes this one value, with no default.
public struct Visibility: Equatable {
    public var filter: ListFilter
    public var kept: Set<String>

    public init(filter: ListFilter, kept: Set<String>) {
        self.filter = filter
        self.kept = kept
    }

    public func shows(_ card: Card) -> Bool {
        filter.shows(card, kept: kept.contains(card.id))
    }
}

/// The cards that `Unread only` keeps showing after they lost their last
/// colored unread row (DESIGN.md, "Filter", "A card read under `Unread
/// only`"), on one surface. Times are seconds of a clock the caller gives
/// (any origin).
///
/// - A card the Filter showed loses its last colored unread row: it is kept.
/// - It stays while it (or an item in it) is selected; once it is not
///   selected, it goes after `duration`, counted from the later of the two.
///   Selected again, the count starts over.
/// - A new colored unread row makes it an ordinary card again.
/// - Opening a tab, changing the Filter (Reset too), the Dismissed list and closing the
///   surface `reset` it: nothing is kept, and the cards shown then are the
///   ones that may be kept next.
public struct UnreadLinger: Equatable {
    /// How long a card read under `Unread only` stays once it is not
    /// selected (DESIGN.md, "Constants").
    public static let standardDuration: Double = 5
    /// The last part of it, in which the card fades.
    public static let fade: Double = 0.3

    public var duration: Double

    /// Kept cards: nil while selected, else when the count started.
    public private(set) var kept: [String: Double?] = [:]
    /// The cards the Filter showed at the last update (they may be kept).
    private var shown: Set<String> = []
    /// Reset: the next update only records what shows.
    private var fresh = true

    public init(duration: Double = UnreadLinger.standardDuration) {
        self.duration = duration
    }

    public var ids: Set<String> { Set(kept.keys) }

    public mutating func reset() {
        kept = [:]
        shown = []
        fresh = true
    }

    /// The tab's cards (not dismissed) changed, or the selection did.
    /// `selected`: the selected cards and the card of the selected item.
    /// Returns whether the kept cards changed.
    @discardableResult
    public mutating func update(cards: [Card], filter: ListFilter, selected: Set<String>, now: Double) -> Bool {
        let before = kept
        guard filter.unreadOnly else {
            kept = [:]
            shown = []
            fresh = false
            return before != kept
        }
        var next: [String: Double?] = [:]
        if !fresh {
            for card in cards where !card.hasBlueUnread {
                let isSelected = selected.contains(card.id)
                if let entry = kept[card.id] {
                    // Selected: held; let go: the count starts now.
                    if isSelected {
                        next[card.id] = .some(nil)
                    } else if let since = entry {
                        next[card.id] = .some(since)
                    } else {
                        next[card.id] = .some(now)
                    }
                } else if shown.contains(card.id) {
                    // It had a colored unread row: shown until now.
                    next[card.id] = .some(isSelected ? nil : now)
                }
            }
        }
        fresh = false
        kept = next
        let keptIds = Set(next.keys)
        shown = Set(cards.lazy.filter { filter.shows($0, kept: keptIds.contains($0.id)) }.map(\.id))
        return before != kept
    }

    /// The cards whose time is up; `blocked` (a drag, a menu) keeps them
    /// all until it ends. They are no longer kept.
    public mutating func expire(now: Double, blocked: Bool) -> Set<String> {
        guard !blocked else { return [] }
        var gone: Set<String> = []
        for (id, since) in kept {
            if let since, now - since >= duration - 1e-9 { gone.insert(id) }
        }
        for id in gone { kept[id] = nil }
        // A card hidden now is no longer shown: it is not kept again.
        shown.subtract(gone)
        return gone
    }

    /// The kept cards in their last `fade` seconds.
    public func fading(now: Double) -> Set<String> {
        Set(kept.compactMap { id, since in
            guard let since else { return nil }
            return now >= since + duration - Self.fade - 1e-9 ? id : nil
        })
    }

    /// When something changes next: a card starts to fade or goes. nil
    /// while nothing counts.
    public func nextDeadline(now: Double) -> Double? {
        var next: Double?
        for since in kept.values {
            guard let since else { continue }
            let fadeAt = since + duration - Self.fade
            let at = now < fadeAt - 1e-9 ? fadeAt : since + duration
            next = min(next ?? at, at)
        }
        return next
    }
}
