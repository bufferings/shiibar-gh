// The popover's state without a screen: the selection, the keys and their
// hint line, the right-click menus (DESIGN.md, "Screens", "Keyboard" and
// "Selection and keys"), and when `popover_opened` and `popover_closed` go
// out.

import Foundation

/// One stop of the selection.
public enum SelectionItem: Equatable, Hashable {
    /// A section or group heading.
    case section(String)
    /// A card's header: the three lines above the rows.
    case header(card: String)
    case row(id: String, card: String)
    /// "+ N more" in a card.
    case moreRows(card: String)
    /// `Older activity on GitHub` at the end of a card's expanded rows.
    case olderActivity(card: String)
    /// "+ N more PRs" or "Show less" of a section.
    case more(String)

    public var id: String {
        switch self {
        case .section(let key): return "section:" + key
        case .header(let card): return "header:" + card
        case .row(let id, _): return "row:" + id
        case .moreRows(let card): return "more-rows:" + card
        case .olderActivity(let card): return "older:" + card
        case .more(let key): return "more:" + key
        }
    }

    /// The card a header or a row belongs to: the target of ⌫, ⌥↑↓ and
    /// D / T / W (DESIGN.md, "Keyboard").
    public var card: String? {
        switch self {
        case .header(let card), .row(_, let card): return card
        case .section, .moreRows, .olderActivity, .more: return nil
        }
    }
}

public enum Key: Equatable {
    case up, down, open, markAllRead, find
    /// ⌘C: the selected text, else the link of the selected item.
    case copy
    /// ⌫: Dismiss, or Restore in the Dismissed list.
    case delete
    /// ⌥↑ and ⌥↓.
    case reorder(up: Bool)
    /// D, T and W.
    case moveTo(PlacementSection)
    /// ⌘1, ⌘2 and ⌘3.
    case tab(ListTab)
    /// Esc in the Dismissed list.
    case back
}

/// What a key, a click or a menu item asks for. The app carries it out.
public enum PopoverAction: Equatable {
    /// Open the URL; `read` is the row opened, which is read too.
    case open(String, read: String?)
    case copyLink(String)
    /// Copy this text (⌘C over selected text).
    case copyText(String)
    /// `Copy` of the right-click menu: the text selected in the surface.
    case copySelectedText
    case place(PlaceMove)
    case dismiss(card: String)
    case restore(card: String)
    case mute(MuteKind, String)
    case unmute(MuteKind, String)
    /// A heading: fold or unfold the section.
    case toggleSection(String)
    /// "+ N more PRs" (expand) and "Show less" (fold again).
    case toggleMore(String)
    /// "+ N more" in a card.
    case expandRows(card: String)
    /// The placement tag: open that tab with the card selected.
    case showInTab(card: String)
    case markAllRead
}

/// The text selected with the mouse in a surface's cards and rows. The app
/// keeps it in AppKit text views; the logic only reads and clears it.
@MainActor
public protocol TextSelecting: AnyObject {
    /// The selected text; nil when nothing is selected.
    var selectedText: String? { get }
    func clearSelection()
}

public struct KeyHint: Equatable {
    public var key: String
    public var text: String

    public init(_ key: String, _ text: String) {
        self.key = key
        self.text = text
    }
}

/// An item of a right-click menu (DESIGN.md, "Keyboard", the mouse table).
/// nil in a list is a separator.
public struct MenuEntry: Equatable {
    public var title: String
    public var action: PopoverAction

    public init(_ title: String, _ action: PopoverAction) {
        self.title = title
        self.action = action
    }
}

/// What a surface lists now: a tab's sections, or the Dismissed list.
public struct ListView: Equatable {
    /// nil for the Dismissed list.
    public var tab: ListTab?
    public var sections: [SectionLayout]
    /// The Dismissed list's cards after its search.
    public var dismissed: [Card]
    /// Cards whose rows are expanded.
    public var expandedRows: Set<String>
    /// Every card of the account, before the search: the whole section a
    /// reorder moves in.
    public var cards: [Card]

    public init(
        tab: ListTab?, sections: [SectionLayout] = [], dismissed: [Card] = [], expandedRows: Set<String> = [], cards: [Card] = []
    ) {
        self.tab = tab
        self.sections = sections
        self.dismissed = dismissed
        self.expandedRows = expandedRows
        self.cards = cards
    }

    public var isDismissed: Bool { tab == nil }

    /// A card shown or folded in this view, with its section.
    public func card(_ id: String) -> (Card, SectionLayout?)? {
        if isDismissed { return dismissed.first { $0.id == id }.map { ($0, nil) } }
        for section in sections where section.isLeaf {
            if let card = section.matching.first(where: { $0.id == id }) { return (card, section) }
        }
        return nil
    }

    public func row(_ id: String) -> (Row, Card)? {
        for section in sections where section.isLeaf {
            for card in section.matching {
                if let row = card.rows.first(where: { $0.id == id }) { return (row, card) }
            }
        }
        return nil
    }
}

public enum PopoverLogic {
    /// Tabs: each heading, then each card's header, its rows, its "+ N more"
    /// or `Older activity on GitHub`, and the section's "+ N more PRs" (or
    /// "Show less"), top to bottom. The Dismissed list: the card headers.
    public static func items(_ view: ListView) -> [SelectionItem] {
        if view.isDismissed { return view.dismissed.map { .header(card: $0.id) } }
        var items: [SelectionItem] = []
        for section in view.sections {
            if section.showsHeader { items.append(.section(section.key)) }
            for card in section.cards {
                let expanded = view.expandedRows.contains(card.id)
                items.append(.header(card: card.id))
                items += Listing.visibleRows(card, expanded: expanded).map { .row(id: $0.id, card: card.id) }
                if Listing.moreRows(card, expanded: expanded) != nil { items.append(.moreRows(card: card.id)) }
                if Listing.showsOlderActivity(card, expanded: expanded) { items.append(.olderActivity(card: card.id)) }
            }
            if section.foldLine != nil { items.append(.more(section.key)) }
        }
        return items
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

    /// Keep the selection on the same item after a change, a row by its id
    /// wherever it went; else nothing.
    public static func keep(_ selection: SelectionItem?, in items: [SelectionItem]) -> SelectionItem? {
        guard let selection else { return nil }
        if items.contains(selection) { return selection }
        if case .row(let id, _) = selection {
            return items.first { if case .row(id, _) = $0 { return true } else { return false } }
        }
        return nil
    }

    // MARK: Keys

    /// What a key asks for on the selected item; nil when it does nothing
    /// (DESIGN.md, "Keyboard"). ⇧R, ⌘F, ⌘C, ⌘1–3 and Esc are handled by the
    /// surface.
    public static func action(for key: Key, selection: SelectionItem?, view: ListView) -> PopoverAction? {
        if key == .markAllRead { return view.isDismissed ? nil : .markAllRead }
        guard let selection else { return nil }
        switch key {
        case .open:
            switch selection {
            case .section(let key):
                guard view.sections.contains(where: { $0.key == key && $0.showsHeader }) else { return nil }
                return .toggleSection(key)
            case .more(let key):
                guard view.sections.contains(where: { $0.key == key && $0.foldLine != nil }) else { return nil }
                return .toggleMore(key)
            case .header(let id):
                return view.card(id).map { .open($0.0.url, read: nil) }
            case .row(let id, _):
                return view.row(id).map { .open($0.0.url, read: $0.0.id) }
            case .moreRows(let id):
                return view.card(id) == nil ? nil : .expandRows(card: id)
            case .olderActivity(let id):
                return view.card(id).map { .open($0.0.url, read: nil) }
            }
        case .delete:
            guard let id = selection.card, let (card, _) = view.card(id) else { return nil }
            return view.isDismissed ? .restore(card: card.id) : .dismiss(card: card.id)
        case .reorder(let up):
            guard !view.isDismissed, view.tab != .all, let id = selection.card, let (card, section) = view.card(id),
                  let section, let move = CardDrop.reorder(card, up: up, shown: section.matching, cards: view.cards)
            else { return nil }
            return .place(move)
        case .moveTo(let target):
            guard view.tab == .review, let id = selection.card, let (card, _) = view.card(id),
                  let move = CardDrop.moveTo(target, card) else { return nil }
            return .place(move)
        default:
            return nil
        }
    }

    static let markAllHint = KeyHint("\u{21E7}R", "Mark all read")
    static let searchHint = KeyHint("\u{2318}F", "Search")
    static let moveHint = KeyHint("\u{2191}\u{2193}", "Move")
    static let openHint = KeyHint("\u{23CE}", "Open")
    static let backHint = KeyHint("esc", "Back")

    /// The hint line for the selection (DESIGN.md, "Keyboard"): only the
    /// keys that do something, named by what they do. ⇧R and ⌘F always in
    /// the tabs; the Dismissed list has no ⇧R.
    public static func hints(selection: SelectionItem?, view: ListView) -> [KeyHint] {
        if view.isDismissed {
            guard case .header(let id)? = selection, view.card(id) != nil else { return [backHint, searchHint] }
            return [moveHint, openHint, KeyHint("\u{232B}", "Restore"), backHint, searchHint]
        }
        var hints = [moveHint]
        switch selection {
        case nil:
            break
        case .section(let key)?:
            let collapsed = view.sections.first { $0.key == key }?.collapsed ?? false
            hints.append(KeyHint("\u{23CE}", collapsed ? "Expand" : "Collapse"))
        case .more(let key)?:
            let less = view.sections.first { $0.key == key }.map { $0.more == 0 && $0.showLess } ?? false
            hints.append(KeyHint("\u{23CE}", less ? "Show less" : "Expand"))
        case .moreRows?:
            hints.append(KeyHint("\u{23CE}", "Expand"))
        case .olderActivity?, .row?:
            hints.append(openHint)
        case .header(let id)?:
            hints.append(openHint)
            if let (card, _) = view.card(id), view.tab != .all, let placement = card.placement {
                if !card.isMuted, !placement.isDone { hints.append(KeyHint("\u{2325}\u{2191}\u{2193}", "Reorder")) }
                if view.tab == .review { hints.append(KeyHint("D T W", "Move to")) }
            }
            hints.append(KeyHint("\u{232B}", "Dismiss"))
        }
        return hints + [markAllHint, searchHint]
    }

    /// The link ⌘C copies when no text is selected (DESIGN.md, "Keyboard"):
    /// the PR of a card header, the place of a row; nothing for the rest.
    public static func link(for selection: SelectionItem?, view: ListView) -> String? {
        switch selection {
        case .header(let id)?: return view.card(id)?.0.url
        case .row(let id, _)?: return view.row(id)?.0.url
        default: return nil
        }
    }

    // MARK: Menus

    /// The right-click menu of a card header, a row or a card of the
    /// Dismissed list (DESIGN.md, "Keyboard", the mouse table); items that
    /// do not apply are left out. `login` is the account's, for "your own
    /// rows"; `mutedUsers` tells Mute from Unmute for a row's actor.
    public static func menu(
        for item: SelectionItem, view: ListView, hasTextSelection: Bool, login: String, mutedUsers: [String] = []
    ) -> [MenuEntry?] {
        func head(_ url: String, read: String?) -> [MenuEntry?] {
            var entries: [MenuEntry?] = [MenuEntry("Open on GitHub", .open(url, read: read))]
            if hasTextSelection { entries.append(MenuEntry("Copy", .copySelectedText)) }
            entries.append(MenuEntry("Copy link", .copyLink(url)))
            return entries
        }
        switch item {
        case .header(let id):
            guard let (card, _) = view.card(id) else { return [] }
            if view.isDismissed {
                return head(card.url, read: nil) + [nil, MenuEntry("Restore", .restore(card: card.id))]
            }
            var entries = head(card.url, read: nil)
            let placing = placementEntries(card)
            if !placing.isEmpty { entries += [nil] + placing }
            entries += [nil] + muteEntries(card, login: login)
            entries += [nil, MenuEntry("Dismiss", .dismiss(card: card.id)), nil, MenuEntry("Mark all as read", .markAllRead)]
            return entries
        case .row(let id, _):
            guard let (row, _) = view.row(id) else { return [] }
            var entries = head(row.url, read: row.id)
            if let actor = row.actor, !actor.isEmpty, actor.lowercased() != login.lowercased() {
                let muted = mutedUsers.contains { $0.lowercased() == actor.lowercased() }
                entries += [nil, MenuEntry((muted ? "Unmute @" : "Mute @") + actor, muted ? .unmute(.user, actor) : .mute(.user, actor))]
            }
            entries += [nil, MenuEntry("Mark all as read", .markAllRead)]
            return entries
        case .section, .moreRows, .olderActivity, .more:
            return []
        }
    }

    /// Move to …, Remove from …, Add to … for the card's placement, Done
    /// included; your own PR is never removed from Mine nor added to Review.
    static func placementEntries(_ card: Card) -> [MenuEntry] {
        guard let placement = card.placement else {
            var entries: [MenuEntry] = []
            if !card.authoredByMe {
                entries.append(MenuEntry("Add to Review", .place(PlaceMove(card: card.id, target: .review(.todo), position: .byDefault, verb: .add))))
            }
            entries.append(MenuEntry("Add to Mine", .place(PlaceMove(card: card.id, target: .mine, position: .byDefault, verb: .add))))
            return entries
        }
        guard let tab = placement.tab.value else { return [] }
        func move(_ title: String, _ target: PlaceTarget) -> MenuEntry {
            MenuEntry("Move to " + title, .place(PlaceMove(card: card.id, target: target, position: .byDefault, verb: .move)))
        }
        let remove = PlaceMove(card: card.id, target: .none, position: .byDefault, verb: .remove)
        switch tab {
        case .review:
            var entries = PlacementSection.review.filter { $0 != placement.section.value }.map { move($0.title, .review($0)) }
            entries.append(MenuEntry("Remove from Review", .place(remove)))
            return entries
        case .mine:
            var entries = [placement.isDone ? move(PlacementSection.main.title, .mine) : move(PlacementSection.done.title, .mineDone)]
            if !card.authoredByMe { entries.append(MenuEntry("Remove from Mine", .place(remove))) }
            return entries
        }
    }

    /// Mute this pull request, Mute owner/repo, Mute @author; each reads
    /// Unmute … while that is muted. Your own PR offers no `Mute @<you>`
    /// (DESIGN.md, the mouse table), only its Unmute if you muted yourself
    /// elsewhere.
    static func muteEntries(_ card: Card, login: String = "") -> [MenuEntry?] {
        var entries: [MenuEntry?] = []
        let repo = Listing.repository(card.pr)
        entries.append(card.isMuted(for: .pr)
            ? MenuEntry("Unmute this pull request", .unmute(.pr, card.pr))
            : MenuEntry("Mute this pull request", .mute(.pr, card.pr)))
        entries.append(card.isMuted(for: .repo)
            ? MenuEntry("Unmute " + repo, .unmute(.repo, repo))
            : MenuEntry("Mute " + repo, .mute(.repo, repo)))
        let mine = card.authoredByMe || (!login.isEmpty && card.author.lowercased() == login.lowercased())
        if !card.author.isEmpty, !mine || card.isMuted(for: .author) {
            entries.append(card.isMuted(for: .author)
                ? MenuEntry("Unmute @" + card.author, .unmute(.user, card.author))
                : MenuEntry("Mute @" + card.author, .mute(.user, card.author)))
        }
        return entries
    }
}

// MARK: - Open surfaces

/// The popover, or the always-on-top window while it has the focus.
public enum Surface: String, Hashable {
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
    /// The banners, the tab row, the search row, the list and key hints.
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
    /// Accounts with the Add account sheet shown (`Add account…` of `No
    /// accounts yet`).
    case addAccount
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
