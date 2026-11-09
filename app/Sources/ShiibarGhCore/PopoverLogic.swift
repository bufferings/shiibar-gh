// The popover's state without a screen: tabs, the selection, the keys and
// their hint line, the right-click menu (DESIGN.md, "Screens", "Keyboard"
// and "Selection and keys"), and when `popover_opened` and
// `popover_closed` go out.

import Foundation

public enum PopoverTab: String, Equatable, Codable { case prs, activity }

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
    case up, down, open, snooze, markAllRead, find
}

/// What a key, a click or a menu item asks for. The app carries it out.
public enum PopoverAction: Equatable {
    /// Open the URL; `read` is the row opened, which is read too.
    case open(String, read: String?)
    case copyLink(String)
    case snooze(pr: String)
    case unsnooze(pr: String)
    case toggleSection(String)
    case expand(String)
    case markAllRead
}

public struct KeyHint: Equatable {
    public var key: String
    public var text: String

    public init(_ key: String, _ text: String) {
        self.key = key
        self.text = text
    }
}

/// An item of the right-click menu of a card header or a row (DESIGN.md,
/// "Keyboard", the mouse table). nil in a list is a separator.
public struct MenuEntry: Equatable {
    public var title: String
    public var action: PopoverAction

    public init(_ title: String, _ action: PopoverAction) {
        self.title = title
        self.action = action
    }
}

public enum PopoverLogic {
    /// PRs: each section's header (none for Group by None), then its cards
    /// (header, rows) and its "+ N more PRs", top to bottom. Activity: the
    /// rows only.
    public static func items(tab: PopoverTab, sections: [SectionLayout], activity: [Row]) -> [SelectionItem] {
        switch tab {
        case .prs:
            var items: [SelectionItem] = []
            for section in sections {
                if section.showsHeader { items.append(.section(section.key)) }
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

    /// Keep the selection on the same item after a reload, a row by its id
    /// wherever it went; else nothing.
    public static func keep(_ selection: SelectionItem?, in items: [SelectionItem]) -> SelectionItem? {
        guard let selection else { return nil }
        if items.contains(selection) { return selection }
        if case .row(let id, _) = selection {
            return items.first { if case .row(id, _) = $0 { return true } else { return false } }
        }
        return nil
    }

    static func card(_ id: String, in sections: [SectionLayout]) -> (Card, SectionLayout)? {
        for section in sections {
            if let card = section.matching.first(where: { $0.id == id }) { return (card, section) }
        }
        return nil
    }

    static func row(_ id: String, sections: [SectionLayout], activity: [Row]) -> Row? {
        sections.lazy.flatMap(\.matching).flatMap(\.rows).first { $0.id == id } ?? activity.first { $0.id == id }
    }

    /// ⏎ and S on the selected item (DESIGN.md, "Selection and keys"). ⇧R
    /// and ⌘F do not depend on the selection.
    public static func action(
        for key: Key, selection: SelectionItem?, sections: [SectionLayout], activity: [Row]
    ) -> PopoverAction? {
        if key == .markAllRead { return .markAllRead }
        guard let selection else { return nil }
        switch selection {
        case .section(let section):
            guard sections.contains(where: { $0.key == section && $0.showsHeader }) else { return nil }
            return key == .open ? .toggleSection(section) : nil
        case .more(let section):
            guard sections.contains(where: { $0.key == section && $0.more > 0 }) else { return nil }
            return key == .open ? .expand(section) : nil
        case .header(let cardId):
            guard let (card, _) = card(cardId, in: sections) else { return nil }
            switch key {
            case .open: return .open(card.url, read: nil)
            case .snooze: return card.snoozed ? .unsnooze(pr: card.pr) : .snooze(pr: card.pr)
            default: return nil
            }
        case .row(let rowId, _):
            guard let row = row(rowId, sections: sections, activity: activity) else { return nil }
            return key == .open ? .open(row.url, read: row.id) : nil
        }
    }

    static let markAllHint = KeyHint("\u{21E7}R", "Mark all read")
    static let searchHint = KeyHint("\u{2318}F", "Search")

    /// The hint line for the selection (DESIGN.md, "Keyboard"): only the
    /// keys that do something, named by what they do; ⇧R and ⌘F always.
    public static func hints(selection: SelectionItem?, sections: [SectionLayout], activity: [Row]) -> [KeyHint] {
        var hints = [KeyHint("\u{2191}\u{2193}", "Move")]
        switch selection {
        case nil:
            break
        case .section(let key)?:
            let collapsed = sections.first { $0.key == key }?.collapsed ?? false
            hints.append(KeyHint("\u{23CE}", collapsed ? "Expand" : "Collapse"))
        case .more?:
            hints.append(KeyHint("\u{23CE}", "Expand"))
        case .header(let cardId)?:
            hints.append(KeyHint("\u{23CE}", "Open"))
            let snoozed = card(cardId, in: sections)?.0.snoozed ?? false
            hints.append(KeyHint("S", snoozed ? "Unsnooze" : "Snooze"))
        case .row?:
            hints.append(KeyHint("\u{23CE}", "Open"))
        }
        return hints + [markAllHint, searchHint]
    }

    /// The right-click menu of a card header or a row: Open on GitHub, Copy
    /// link, Snooze until <time> (Unsnooze in Snoozed; none in Activity),
    /// Mark all as read. `returnAt` is the next Return time. Nil entries
    /// are separators; other items have no menu.
    public static func menu(
        for item: SelectionItem, tab: PopoverTab, sections: [SectionLayout], activity: [Row],
        returnAt: Int64, timeZone: TimeZone = .current
    ) -> [MenuEntry?] {
        let url: String
        let read: String?
        var card: Card?
        switch item {
        case .header(let id):
            guard let found = Self.card(id, in: sections)?.0 else { return [] }
            card = found
            url = found.url
            read = nil
        case .row(let id, let cardId):
            guard let row = row(id, sections: sections, activity: activity) else { return [] }
            url = row.url
            read = row.id
            if tab == .prs, let cardId { card = Self.card(cardId, in: sections)?.0 }
        case .section, .more:
            return []
        }
        var entries: [MenuEntry?] = [MenuEntry("Open on GitHub", .open(url, read: read)), MenuEntry("Copy link", .copyLink(url))]
        if tab == .prs, let card {
            entries.append(nil)
            entries.append(card.snoozed
                ? MenuEntry("Unsnooze", .unsnooze(pr: card.pr))
                : MenuEntry("Snooze until " + RelativeTime.weekdayClock(returnAt, timeZone: timeZone), .snooze(pr: card.pr)))
        }
        entries.append(nil)
        entries.append(MenuEntry("Mark all as read", .markAllRead))
        return entries
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
    /// The banner, tabs, the two filter rows, the list and key hints.
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
