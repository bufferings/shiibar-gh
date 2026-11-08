// The popover's state without a screen: tabs, the filter row, the owner
// sections, the selection, the keys and their hint line (DESIGN.md,
// "Screens", "Keyboard" and "Selection and keys"), which rows count as shown
// for `seen`, and when `popover_opened` and `popover_closed` go out.

import Foundation

public enum PopoverTab: String, Equatable, Codable { case prs, activity }

/// The filter row: the Todo toggle and the segment. Remembered per account
/// (DESIGN.md, "Screens"; kept in UserDefaults).
public struct FilterState: Equatable, Codable {
    public var todo: Bool
    public var segment: PrFilter

    public init(todo: Bool = false, segment: PrFilter = .all) {
        self.todo = todo
        self.segment = segment
    }

    /// The cards are narrowed down, so an empty list is "Nothing matches".
    public var narrows: Bool { todo || segment != .all }

    public static func title(_ segment: PrFilter) -> String {
        switch segment {
        case .all: return "All"
        case .authored: return "Authored by me"
        case .assigned: return "Assigned to me"
        case .reviewRequested: return "Review requested"
        }
    }
}

/// A section of the PRs tab: one per enabled owner in the account's order
/// (Public last, as the daemon sends them), then Snoozed.
public struct SectionLayout: Equatable, Identifiable {
    public static let snoozedKey = "snoozed"

    public var key: String
    public var title: String
    public var isSnoozed: Bool
    /// The red number; nil when 0 (and for Snoozed).
    public var todoCount: Int?
    /// "4 PRs", or "2 PRs · until Mon 09:00" for Snoozed.
    public var detail: String
    public var collapsed: Bool
    /// The cards laid out under the header (none while collapsed).
    public var cards: [Card]
    /// "+ N more PRs": the cards without Todo left out until expanded.
    public var more: Int

    public var id: String { key }

    public static func ownerKey(_ owner: String) -> String { "owner:" + owner }

    public var moreText: String? {
        more > 0 ? "+ \(more) more " + (more == 1 ? "PR" : "PRs") : nil
    }
}

/// One stop of the selection.
public enum SelectionItem: Equatable, Hashable {
    case section(String)
    /// A card's header: the three lines above the rows.
    case header(card: String)
    case row(id: String, card: String?)
    /// "+ N more PRs" of a section.
    case more(String)

    public var id: String {
        switch self {
        case .section(let key): return "section:" + key
        case .header(let card): return "header:" + card
        case .row(let id, _): return "row:" + id
        case .more(let key): return "more:" + key
        }
    }
}

public enum Key: Equatable {
    case up, down, open, done, todo, snooze
}

/// What a key or a click asks for. The app carries it out.
public enum PopoverAction: Equatable {
    case open(String)
    case done(row: String, on: Bool)
    case todo(row: String, on: Bool)
    case snooze(pr: String)
    case unsnooze(pr: String)
    case toggleSection(String)
    case expand(String)
}

public struct KeyHint: Equatable {
    public var key: String
    public var text: String

    public init(_ key: String, _ text: String) {
        self.key = key
        self.text = text
    }
}

public enum PopoverLogic {
    static func count(_ n: Int) -> String { n == 1 ? "1 PR" : "\(n) PRs" }

    /// The sections of the PRs tab. `cards` are the account's unsnoozed
    /// cards after the filters, `snoozed` the snoozed ones after the
    /// filters, `allSnoozed` the snoozed PRs without filters (the Snoozed
    /// header's count and `until` do not depend on the filters). Owner
    /// sections start expanded and Snoozed collapsed; `collapsed` holds the
    /// user's choices. A section shows its Todo PRs and gathers the others
    /// into "+ N more PRs" until it is in `expanded`. While the unsnoozed
    /// cards are empty (`showsEmpty`), "Nothing needs you" or "Nothing
    /// matches" takes the place of the owner sections and only Snoozed
    /// stays (DESIGN.md, "First run, failure and empty").
    public static func sections(
        account: Account, cards: [Card], snoozed: [Card], allSnoozed: [Card],
        collapsed: [String: Bool], expanded: Set<String>, showsEmpty: Bool = false,
        timeZone: TimeZone = .current
    ) -> [SectionLayout] {
        var out: [SectionLayout] = []
        for owner in account.owners where owner.enabled && !showsEmpty {
            let key = SectionLayout.ownerKey(owner.id)
            let mine = cards.filter { $0.owner == owner.id }
            let isCollapsed = collapsed[key] ?? false
            let open = expanded.contains(key)
            let shown = open ? mine : mine.filter(\.hasOpenTodo)
            out.append(SectionLayout(
                key: key, title: owner.displayName, isSnoozed: false,
                todoCount: owner.todoCount > 0 ? owner.todoCount : nil,
                detail: count(owner.prCount), collapsed: isCollapsed,
                cards: isCollapsed ? [] : shown, more: isCollapsed ? 0 : mine.count - shown.count
            ))
        }
        if !allSnoozed.isEmpty || !snoozed.isEmpty {
            let key = SectionLayout.snoozedKey
            let isCollapsed = collapsed[key] ?? true
            var detail = count(max(allSnoozed.count, snoozed.count))
            if let until = (allSnoozed + snoozed).compactMap(\.snoozedUntil).first {
                detail += " · until " + RelativeTime.weekdayClock(until, timeZone: timeZone)
            }
            out.append(SectionLayout(
                key: key, title: "Snoozed", isSnoozed: true, todoCount: nil, detail: detail,
                collapsed: isCollapsed, cards: isCollapsed ? [] : snoozed, more: 0
            ))
        }
        return out
    }

    /// "Nothing needs you" or "Nothing matches" once the list has loaded
    /// and no unsnoozed card is left; nil otherwise.
    public static func emptyText(loaded: Bool, cards: [Card], filter: FilterState) -> String? {
        guard loaded && cards.isEmpty else { return nil }
        return EmptyState.cards(filtered: filter.narrows)
    }

    /// PRs: each section's header, then its cards (header, rows) and its
    /// "+ N more PRs", top to bottom. Activity: the rows only.
    public static func items(tab: PopoverTab, sections: [SectionLayout], activity: [Row]) -> [SelectionItem] {
        switch tab {
        case .prs:
            var items: [SelectionItem] = []
            for section in sections {
                items.append(.section(section.key))
                for card in section.cards {
                    items.append(.header(card: card.id))
                    items.append(contentsOf: card.rows.map { .row(id: $0.id, card: card.id) })
                }
                if section.more > 0 { items.append(.more(section.key)) }
            }
            return items
        case .activity:
            return activity.map { .row(id: $0.id, card: nil) }
        }
    }

    /// The selection after ↑ or ↓. Nothing selected starts at the top (↓)
    /// or the bottom (↑).
    public static func move(_ selection: SelectionItem?, up: Bool, in items: [SelectionItem]) -> SelectionItem? {
        guard !items.isEmpty else { return nil }
        guard let selection, let index = items.firstIndex(of: selection) else {
            return up ? items.last : items.first
        }
        let next = up ? max(0, index - 1) : min(items.count - 1, index + 1)
        return items[next]
    }

    /// Keep the selection on the same item after a reload, else nothing.
    public static func keep(_ selection: SelectionItem?, in items: [SelectionItem]) -> SelectionItem? {
        guard let selection else { return nil }
        if items.contains(selection) { return selection }
        if case .row(let id, _) = selection {
            return items.first { if case .row(id, _) = $0 { return true } else { return false } }
        }
        return nil
    }

    static func card(_ id: String, in sections: [SectionLayout]) -> Card? {
        sections.lazy.flatMap(\.cards).first { $0.id == id }
    }

    static func row(_ id: String, sections: [SectionLayout], activity: [Row]) -> Row? {
        sections.lazy.flatMap(\.cards).flatMap(\.rows).first { $0.id == id } ?? activity.first { $0.id == id }
    }

    /// ⏎, T, D and S on the selected item (DESIGN.md, "Selection and keys").
    public static func action(
        for key: Key, selection: SelectionItem?, sections: [SectionLayout], activity: [Row]
    ) -> PopoverAction? {
        guard let selection else { return nil }
        switch selection {
        case .section(let section):
            guard sections.contains(where: { $0.key == section }) else { return nil }
            return key == .open ? .toggleSection(section) : nil
        case .more(let section):
            guard sections.contains(where: { $0.key == section && $0.more > 0 }) else { return nil }
            return key == .open ? .expand(section) : nil
        case .header(let cardId):
            guard let card = card(cardId, in: sections) else { return nil }
            switch key {
            case .open: return .open(card.url)
            case .snooze: return card.snoozed ? .unsnooze(pr: card.pr) : .snooze(pr: card.pr)
            case .done, .todo, .up, .down: return nil
            }
        case .row(let rowId, _):
            guard let row = row(rowId, sections: sections, activity: activity) else { return nil }
            switch key {
            case .open: return .open(row.url)
            case .todo: return row.done ? nil : .todo(row: row.id, on: !row.todo)
            case .done: return row.todo ? .done(row: row.id, on: !row.done) : nil
            case .snooze, .up, .down: return nil
            }
        }
    }

    /// The hint line for the selection (DESIGN.md, "Keyboard"): only the
    /// keys that do something, named by what they do.
    public static func hints(selection: SelectionItem?, sections: [SectionLayout], activity: [Row]) -> [KeyHint] {
        var hints = [KeyHint("↑↓", "Move")]
        guard let selection else { return hints }
        switch selection {
        case .section(let key):
            let collapsed = sections.first { $0.key == key }?.collapsed ?? false
            hints.append(KeyHint("⏎", collapsed ? "Expand" : "Collapse"))
        case .more:
            hints.append(KeyHint("⏎", "Expand"))
        case .header(let cardId):
            hints.append(KeyHint("⏎", "Open"))
            let snoozed = card(cardId, in: sections)?.snoozed ?? false
            hints.append(KeyHint("S", snoozed ? "Unsnooze" : "Snooze"))
        case .row(let rowId, _):
            hints.append(KeyHint("⏎", "Open"))
            guard let row = row(rowId, sections: sections, activity: activity) else { break }
            if row.todo && !row.done {
                hints.append(KeyHint("D", "Done"))
                hints.append(KeyHint("T", "Remove from Todo"))
            } else if row.done {
                if row.todo { hints.append(KeyHint("D", "Not done")) }
            } else {
                hints.append(KeyHint("T", "Add to Todo"))
            }
        }
        return hints
    }
}

// MARK: - Activity owner buttons

public enum ActivityOwners {
    /// The owner arguments to send: the buttons that are on, in the
    /// account's order. None on is every owner.
    public static func arguments(_ selected: Set<String>, account: Account) -> [String] {
        account.owners.filter { $0.enabled && selected.contains($0.id) }.map(\.argument)
    }

    /// The buttons: the enabled owners.
    public static func buttons(_ account: Account) -> [Owner] {
        account.owners.filter(\.enabled)
    }
}

// MARK: - Seen

public enum Visibility {
    /// The rows with any part inside the visible part of the list. Rows
    /// scrolled away are not shown; rows collapsed or filtered out are not
    /// laid out at all, so they never appear in `frames`.
    public static func shown(frames: [String: ClosedRange<Double>], viewport: ClosedRange<Double>) -> Set<String> {
        Set(frames.compactMap { id, frame in
            frame.upperBound > viewport.lowerBound && frame.lowerBound < viewport.upperBound ? id : nil
        })
    }
}

/// The `seen` rows of one open period: each unread row is sent once.
public struct SeenTracker: Equatable {
    private var sent: Set<String> = []

    public init() {}

    public mutating func newlySeen(shown: Set<String>, unread: Set<String>) -> [String] {
        let fresh = shown.intersection(unread).subtracting(sent)
        sent.formUnion(fresh)
        return fresh.sorted()
    }

    public mutating func reset() {
        sent = []
    }
}

// MARK: - Open surfaces

/// The popover, or the always-on-top window while it has the focus.
public enum Surface: Hashable {
    case popover
    case window
}

/// An account is open while any of its surfaces is: 0 to 1 sends
/// `popover_opened`, 1 to 0 `popover_closed`. Keyed by account id.
public struct OpenSurfaces: Equatable {
    private var open: [String: Set<Surface>] = [:]

    public init() {}

    public mutating func opened(_ surface: Surface, account: String) -> Bool {
        let wasOpen = !(open[account]?.isEmpty ?? true)
        open[account, default: []].insert(surface)
        return !wasOpen
    }

    public mutating func closed(_ surface: Surface, account: String) -> Bool {
        guard var surfaces = open[account], surfaces.contains(surface) else { return false }
        surfaces.remove(surface)
        open[account] = surfaces.isEmpty ? nil : surfaces
        return surfaces.isEmpty
    }

    public func isOpen(_ account: String) -> Bool {
        !(open[account]?.isEmpty ?? true)
    }

    public func isOpen(_ surface: Surface, account: String) -> Bool {
        open[account]?.contains(surface) ?? false
    }

    public mutating func forget(_ account: String) {
        open[account] = nil
    }

    public var openAccounts: [String] {
        open.keys.sorted()
    }
}

// MARK: - What a surface shows

/// The body of an account's popover and window (DESIGN.md, "First run,
/// failure and empty" and "When the database cannot be read").
public enum PopoverContent: Equatable {
    /// "Couldn't read saved state" and Reset only.
    case unreadable
    /// "No owners yet", "Add an owner in Settings" and Settings only.
    case noOwners
    /// The banner, tabs, filter row, list, usage and key hints.
    case list
}

/// The popover of the shiibar-gh icon shown while there is no account.
public enum NoAccountsContent: Equatable {
    case unreadable
    case noAccounts
}

/// Where a Settings button goes.
public enum SettingsDestination: Equatable {
    case general
    /// Accounts with this account selected.
    case account(String)
    case accounts
}

public enum SurfaceRules {
    public static func content(account: Account?, dbUnreadable: Bool) -> PopoverContent {
        if dbUnreadable { return .unreadable }
        if let account, account.owners.isEmpty { return .noOwners }
        return .list
    }

    public static func noAccountsContent(dbUnreadable: Bool) -> NoAccountsContent {
        dbUnreadable ? .unreadable : .noAccounts
    }

    /// The shiibar-gh icon shows when there is no account (DESIGN.md,
    /// "Screens").
    public static func showsAppIcon(_ accounts: [Account]) -> Bool {
        accounts.isEmpty
    }
}
