// The popover's state without a screen: tabs, chips, the selection and the
// keys (DESIGN.md, "Screens", "Keyboard" and "Selection and keys"), which
// rows count as shown for `seen`, and when `popover_opened` and
// `popover_closed` go out.

import Foundation

public enum PopoverTab: String, Equatable, Codable { case prs, activity }

public enum AuthorChip: String, Equatable, Codable { case all, mine, others }

/// The chips. Kept in UserDefaults (DESIGN.md, "Saved state").
public struct Chips: Equatable, Codable {
    public var needsAction: Bool
    public var author: AuthorChip
    public var showSnoozed: Bool

    public init(needsAction: Bool = false, author: AuthorChip = .all, showSnoozed: Bool = false) {
        self.needsAction = needsAction
        self.author = author
        self.showSnoozed = showSnoozed
    }

    /// My PRs and Others' PRs: at most one on; picking the one that is on
    /// turns both off.
    public mutating func pick(_ author: AuthorChip) {
        self.author = self.author == author ? .all : author
    }

    public func filter(scope: String) -> ListFilter {
        ListFilter(
            scope: scope, needsAction: needsAction, mine: author == .mine,
            others: author == .others, snoozed: showSnoozed
        )
    }

    /// The cards are narrowed down, so an empty list is "Nothing matches".
    /// Show snoozed widens the list and does not count.
    public var narrows: Bool { needsAction || author != .all }
}

/// One stop of the selection.
public enum SelectionItem: Equatable, Hashable {
    /// A card's header: the three lines above the rows.
    case header(card: String)
    case row(id: String, card: String?)

    public var id: String {
        switch self {
        case .header(let card): return "header:" + card
        case .row(let id, _): return "row:" + id
        }
    }
}

public enum Key: Equatable {
    case up, down, open, done, snooze
}

/// What a key or a click asks for. The app carries it out.
public enum PopoverAction: Equatable {
    case open(String)
    case done(row: String)
    case undone(row: String)
    case snooze(pr: String)
    case unsnooze(pr: String)
}

public enum PopoverLogic {
    /// PRs: each card's header, then its rows, top to bottom. Activity: the
    /// rows only.
    public static func items(tab: PopoverTab, cards: [Card], activity: [Row]) -> [SelectionItem] {
        switch tab {
        case .prs:
            return cards.flatMap { card in
                [SelectionItem.header(card: card.id)] + card.rows.map { .row(id: $0.id, card: card.id) }
            }
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

    /// ⏎, D and S on the selected item (DESIGN.md, "Selection and keys"). A
    /// header opens the PR, snoozes it, and ignores D. A row opens its place,
    /// D toggles Done on a Needs action row only, and S snoozes its PR. S on
    /// a PR that is already snoozed does nothing.
    public static func action(
        for key: Key, selection: SelectionItem?, cards: [Card], activity: [Row]
    ) -> PopoverAction? {
        guard let selection else { return nil }
        switch selection {
        case .header(let cardId):
            guard let card = cards.first(where: { $0.id == cardId }) else { return nil }
            switch key {
            case .open: return .open(card.url)
            case .snooze: return card.snoozed ? nil : .snooze(pr: card.pr)
            case .done, .up, .down: return nil
            }
        case .row(let rowId, _):
            let row = cards.flatMap(\.rows).first { $0.id == rowId } ?? activity.first { $0.id == rowId }
            guard let row else { return nil }
            switch key {
            case .open: return .open(row.url)
            case .done:
                guard row.isNeedsAction else { return nil }
                return row.done ? .undone(row: row.id) : .done(row: row.id)
            case .snooze:
                let snoozed = cards.first { $0.pr == row.pr }?.snoozed ?? false
                return snoozed ? nil : .snooze(pr: row.pr)
            case .up, .down: return nil
            }
        }
    }
}

// MARK: - Seen

public enum Visibility {
    /// The rows with any part inside the visible part of the list. Rows
    /// scrolled away are not shown; rows hidden by the chips are not laid
    /// out at all, so they never appear in `frames`.
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

    /// The unread rows among `shown` not sent yet, sorted for a stable
    /// request.
    public mutating func newlySeen(shown: Set<String>, unread: Set<String>) -> [String] {
        let fresh = shown.intersection(unread).subtracting(sent)
        sent.formUnion(fresh)
        return fresh.sorted()
    }

    /// The popover closed: the next open sends again.
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

/// A scope is open while any of its surfaces is (docs/tasks/M3.md, "Menu bar
/// and popover"): 0 to 1 sends `popover_opened`, 1 to 0 `popover_closed`.
public struct OpenSurfaces: Equatable {
    private var open: [String: Set<Surface>] = [:]

    public init() {}

    /// True when the scope just became open.
    public mutating func opened(_ surface: Surface, scope: String) -> Bool {
        let wasOpen = !(open[scope]?.isEmpty ?? true)
        open[scope, default: []].insert(surface)
        return !wasOpen
    }

    /// True when the scope just became closed.
    public mutating func closed(_ surface: Surface, scope: String) -> Bool {
        guard var surfaces = open[scope], surfaces.contains(surface) else { return false }
        surfaces.remove(surface)
        open[scope] = surfaces.isEmpty ? nil : surfaces
        return surfaces.isEmpty
    }

    public func isOpen(_ scope: String) -> Bool {
        !(open[scope]?.isEmpty ?? true)
    }

    public func isOpen(_ surface: Surface, scope: String) -> Bool {
        open[scope]?.contains(surface) ?? false
    }

    /// The scope is gone (removed): nothing is sent for it any more.
    public mutating func forget(_ scope: String) {
        open[scope] = nil
    }

    /// The scopes to send `popover_opened` for again after a reconnect.
    public var openScopes: [String] {
        open.keys.sorted()
    }
}

// MARK: - What a surface shows

/// The body of a scope's popover and window (DESIGN.md, "First run, failure
/// and empty" and "When the database cannot be read").
public enum PopoverContent: Equatable {
    /// "Couldn't read saved state" and Reset only.
    case unreadable
    /// "Add a token in Settings" and Settings only.
    case noToken
    /// The banner, tabs, chips, list and key hints.
    case list
}

/// The popover of the shiibar-gh icon shown while no scope icon is.
public enum NoScopeContent: Equatable {
    case unreadable
    case noScopes
}

/// Where a Settings button goes.
public enum SettingsDestination: Equatable {
    case general
    case scopes
}

public enum SurfaceRules {
    public static func content(scope: Scope?, dbUnreadable: Bool) -> PopoverContent {
        if dbUnreadable { return .unreadable }
        if let scope, Warnings.needsToken(scope) { return .noToken }
        return .list
    }

    public static func noScopeContent(dbUnreadable: Bool) -> NoScopeContent {
        dbUnreadable ? .unreadable : .noScopes
    }

    /// The shiibar-gh icon shows when no scope icon does: no scope, or every
    /// scope disabled (DESIGN.md, "Screens").
    public static func showsAppIcon(_ scopes: [Scope]) -> Bool {
        !scopes.contains(where: \.enabled)
    }

    /// The header's Settings and the ⌄ menu open General; the banner's
    /// Settings, the no-token state and the no-scope popover open Scopes
    /// (docs/tasks/M3.md, "Menu bar and popover"; DESIGN.md, "First run,
    /// failure and empty").
    public static let headerSettings = SettingsDestination.general
    public static let bannerSettings = SettingsDestination.scopes
    public static let noTokenSettings = SettingsDestination.scopes
    public static let noScopesSettings = SettingsDestination.scopes

    /// "Snoozed until Mon 09:00", from the card's `snoozed_until`.
    public static func snoozedUntil(_ at: Int64, timeZone: TimeZone = .current) -> String {
        "Snoozed until " + RelativeTime.weekdayClock(at, timeZone: timeZone)
    }
}

/// How a chip looks (docs/design/Main.html `.chip`; DESIGN.md, "Screens"):
/// every chip off has the gray border and text; a chip on is filled, orange
/// for Needs action and black (light text in the dark appearance) for the
/// others, and starts with ✓ so the state is not shown by color alone.
public struct ChipLook: Equatable {
    public var on: Bool
    public var fill: Shade
    public var border: Shade
    public var text: Shade

    public init(on: Bool, action: Bool) {
        self.on = on
        if on {
            let color = action ? Palette.badge : Palette.text
            fill = color
            border = color
            text = action ? Palette.onColor : Palette.surface
        } else {
            fill = Palette.surface
            border = Palette.controlBorder
            text = Palette.strongText
        }
    }

    public func label(_ title: String) -> String {
        on ? "\u{2713} " + title : title
    }
}
