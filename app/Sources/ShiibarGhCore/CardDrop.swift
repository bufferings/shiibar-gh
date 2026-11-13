// Moving a card (DESIGN.md, "Review", "Mine", "What a press does" and
// "Keyboard"): what a dragged card is over, where it lands, the line that
// shows it, the moves of ⌥↑↓ and D / T / W, and the same moves applied to
// the cards on screen before the daemon answers. A landing is the `before`
// or `at` of the wire's `place` (DESIGN.md, "Wire format"), so the daemon
// gets the place the screen shows.

import Foundation
import UniformTypeIdentifiers

/// What a dragged card is over.
public enum DropZone: Equatable {
    /// A card; `lowerHalf` when the pointer is below the card's middle.
    case card(String, lowerHalf: Bool)
    /// A section's heading, collapsed or not.
    case header(String)
    /// The "+ N more PRs" (or "Show less") line of a section.
    case more(String)
}

/// Where a card lands in a section: right before a card (`before`) or after
/// the last card that is not muted (`at: bottom`).
public struct DropTarget: Equatable {
    public var section: String
    public var position: PlacePosition

    public init(section: String, position: PlacePosition) {
        self.section = section
        self.position = position
    }
}

/// A move for `place`: the card, where it goes, and the verb of the
/// failure band.
public struct PlaceMove: Equatable {
    public var card: String
    public var target: PlaceTarget
    public var position: PlacePosition
    public var verb: OperationVerb

    public init(card: String, target: PlaceTarget, position: PlacePosition, verb: OperationVerb) {
        self.card = card
        self.target = target
        self.position = position
        self.verb = verb
    }
}

public enum CardDrop {
    /// The pasteboard type of a dragged card: a dynamic type of this
    /// process's own, so that a drag from elsewhere (text, files) never
    /// looks like a card. `UTType(filenameExtension:conformingTo:)` makes a
    /// dynamic type for an extension the system does not know (UTType.h).
    public static let type: UTType = UTType(filenameExtension: "shiibar-gh-card", conformingTo: .data) ?? .data

    /// Where a drop over `zone` lands, or nil where nothing can drop: All
    /// and the Dismissed list (DESIGN.md, "What a press does"). Over a
    /// card's upper half the card lands before it, over the lower half
    /// before the next card that is not muted (or at the bottom). Over a
    /// muted card, a heading, a collapsed section or "+ N more PRs" it
    /// lands after the last card that is not muted. Anywhere in Done it
    /// lands by Done's own order: newest first, no position.
    public static func target(_ zone: DropZone, sections: [SectionLayout]) -> DropTarget? {
        switch zone {
        case .header(let key), .more(let key):
            guard let section = sections.first(where: { $0.key == key }), section.accepts else { return nil }
            return DropTarget(section: key, position: section.isDone ? .byDefault : .bottom)
        case .card(let id, let lowerHalf):
            guard let section = sections.first(where: { $0.isLeaf && $0.matching.contains { $0.id == id } }),
                  section.accepts else { return nil }
            if section.isDone { return DropTarget(section: section.key, position: .byDefault) }
            let cards = section.matching
            guard let index = cards.firstIndex(where: { $0.id == id }) else { return nil }
            if cards[index].isMuted { return DropTarget(section: section.key, position: .bottom) }
            if !lowerHalf { return DropTarget(section: section.key, position: .before(id)) }
            if let next = cards[(index + 1)...].first(where: { !$0.isMuted }) {
                return DropTarget(section: section.key, position: .before(next.id))
            }
            return DropTarget(section: section.key, position: .bottom)
        }
    }

    /// The card the insertion line is drawn above, or nil for the end of the
    /// section's shown cards (above "+ N more PRs" if there is one).
    public static func lineAbove(_ target: DropTarget, in section: SectionLayout) -> String? {
        // Done: the newest entry, above the first card.
        if section.isDone { return section.cards.first?.id }
        switch target.position {
        case .before(let id):
            if section.cards.contains(where: { $0.id == id }) { return id }
            return section.cards.first(where: \.isMuted)?.id
        case .bottom, .top, .byDefault:
            return section.cards.first(where: \.isMuted)?.id
        }
    }

    /// The `place` of a drop, nil when the card would stay where it is.
    /// `before` names a card by its id here; the request takes its PR.
    public static func move(_ card: Card, to target: DropTarget, cards: [Card]) -> PlaceMove? {
        guard let (tab, section) = SectionKey.placement(target.section) else { return nil }
        let placeTarget = Self.target(tab, section)
        if card.sectionKey == target.section {
            // Done keeps its own order: a card already there stays.
            if section == .done { return nil }
            let order = Listing.ranked(cards.filter { !$0.isDismissed && $0.sectionKey == target.section && !$0.isMuted }).map(\.id)
            var after = order.filter { $0 != card.id }
            switch target.position {
            case .before(let other):
                guard let index = after.firstIndex(of: other) else { return nil }
                after.insert(card.id, at: index)
            default:
                after.append(card.id)
            }
            if after == order { return nil }
        }
        return PlaceMove(card: card.id, target: placeTarget, position: target.position, verb: .move)
    }

    /// ⌥↑ or ⌥↓: one place up or down among the cards that are not muted,
    /// in the order shown (`shown`: the section's cards after the search).
    /// Nil where it cannot move: All, Done, a muted card, the ends.
    public static func reorder(_ card: Card, up: Bool, shown: [Card], cards: [Card]) -> PlaceMove? {
        guard card.canReorder, let key = card.sectionKey, let (tab, section) = SectionKey.placement(key) else { return nil }
        let target = Self.target(tab, section)
        let visible = shown.filter { !$0.isMuted }
        guard let index = visible.firstIndex(where: { $0.id == card.id }) else { return nil }
        if up {
            guard index > 0 else { return nil }
            return PlaceMove(card: card.id, target: target, position: .before(visible[index - 1].id), verb: .move)
        }
        guard index + 1 < visible.count else { return nil }
        // After the next shown card: before whatever follows it in the
        // whole section, hidden by the search or not.
        let full = Listing.ranked(cards.filter { !$0.isDismissed && $0.sectionKey == key && !$0.isMuted })
        let next = visible[index + 1]
        guard let at = full.firstIndex(where: { $0.id == next.id }) else { return nil }
        let rest = full[(at + 1)...].filter { $0.id != card.id }
        return PlaceMove(card: card.id, target: target, position: rest.first.map { .before($0.id) } ?? .bottom, verb: .move)
    }

    /// D, T or W in Review: to that section at its default place, from
    /// Done too; nothing for Mine or the section the card is in.
    public static func moveTo(_ section: PlacementSection, _ card: Card) -> PlaceMove? {
        guard let placement = card.placement, placement.tab.value == .review,
              placement.section.value != section, section != .done else { return nil }
        return PlaceMove(card: card.id, target: .review(section), position: .byDefault, verb: .move)
    }

    /// The `place` target of a section of Review or Mine.
    public static func target(_ tab: PlacementTab, _ section: PlacementSection) -> PlaceTarget {
        switch tab {
        case .review: return .review(section)
        case .mine: return section == .done ? .mineDone : .mine
        }
    }
}

// MARK: - Applying moves before the daemon answers

/// The local operations (DESIGN.md, "Showing what an operation did"),
/// applied to the cards on screen at once and kept until a list read after
/// the daemon's answer, or taken back when the daemon refuses.
public enum LocalChange: Equatable {
    case place(PlaceMove)
    case dismiss(card: String, at: Int64, expiresAt: Int64)
    case restore(card: String)
    case mute(MuteKind, String)
    case unmute(MuteKind, String)
    case read(Set<String>)

    public var verb: OperationVerb {
        switch self {
        case .place(let move): return move.verb
        case .dismiss: return .dismiss
        case .restore: return .restore
        case .mute: return .mute
        case .unmute: return .unmute
        case .read: return .markAsRead
        }
    }

    /// Rows a user mute leaves alone: state changes and reactions carry no
    /// actor of their own, and mentions always notify (DESIGN.md, "Mute").
    static let userMuteExempt: Set<RowKind> = [
        .changesRequested, .checksFailed, .checksPassed, .conflicts, .mergeable, .reaction, .mentioned,
    ]

    /// The cards with this change made. `mutedUsers` are the account's
    /// muted users, for the rows of a card that stops being muted.
    public func apply(_ cards: [Card], mutedUsers: [String] = []) -> [Card] {
        switch self {
        case .place(let move):
            return Self.place(move, cards)
        case .dismiss(let id, let at, let expiresAt):
            return cards.map { card in
                guard card.id == id else { return card }
                var card = card
                card.dismissedAt = at
                card.dismissExpiresAt = expiresAt
                return card
            }
        case .restore(let id):
            return cards.map { card in
                guard card.id == id else { return card }
                var card = card
                card.dismissedAt = nil
                card.dismissExpiresAt = nil
                return card
            }
        case .read(let ids):
            return cards.map { card in
                guard card.rows.contains(where: { ids.contains($0.id) && $0.unread }) else { return card }
                var card = card
                card.rows = card.rows.map { row in
                    var row = row
                    if ids.contains(row.id) { row.unread = false }
                    return row
                }
                return card
            }
        case .mute(let kind, let name):
            return Self.mute(cards, kind: kind, name: name, on: true, mutedUsers: mutedUsers)
        case .unmute(let kind, let name):
            return Self.mute(cards, kind: kind, name: name, on: false, mutedUsers: mutedUsers)
        }
    }

    static func reason(_ kind: MuteKind) -> MuteReason {
        switch kind {
        case .pr: return .pr
        case .repo: return .repo
        case .user: return .author
        }
    }

    static func targets(_ card: Card, kind: MuteKind, name: String) -> Bool {
        let name = name.lowercased()
        switch kind {
        case .pr: return card.pr.lowercased() == name
        case .repo: return Listing.repository(card.pr).lowercased() == name
        case .user: return card.author.lowercased() == name
        }
    }

    /// Only what the mute targets changes: the cards it names (their muted
    /// reasons and rows) and, for a user, the rows that user made. Every
    /// other card and row keeps what the daemon sent.
    static func mute(_ cards: [Card], kind: MuteKind, name: String, on: Bool, mutedUsers: [String]) -> [Card] {
        let lowered = name.lowercased()
        var users = Set(mutedUsers.map { $0.lowercased() })
        if kind == .user {
            if on { users.insert(lowered) } else { users.remove(lowered) }
        }
        let reason = reason(kind)
        func userMutable(_ row: Row) -> Bool {
            guard let rowKind = row.kind.value else { return false }
            return !userMuteExempt.contains(rowKind)
        }
        return cards.map { card in
            let targeted = targets(card, kind: kind, name: name)
            let byActor = kind == .user && card.rows.contains { $0.actor?.lowercased() == lowered }
            guard targeted || byActor else { return card }
            var card = card
            if targeted {
                card.muted.removeAll { $0.value == reason }
                if on { card.muted.append(.known(reason)) }
            }
            let cardMuted = card.isMuted
            card.rows = card.rows.map { row in
                var row = row
                guard let rowKind = row.kind.value, rowKind != .mentioned else { return row }
                if targeted {
                    // The card's own mute changed: every row follows it,
                    // and a row of a muted user stays gray without it.
                    let byUser = userMutable(row) && row.actor.map { users.contains($0.lowercased()) } == true
                    row.muted = cardMuted || byUser
                } else if row.actor?.lowercased() == lowered, userMutable(row) {
                    row.muted = cardMuted || on
                }
                return row
            }
            return card
        }
    }

    /// The card at its new place: ranks of the sections it leaves and
    /// joins are numbered again, muted cards last (DESIGN.md, "Review").
    static func place(_ move: PlaceMove, _ cards: [Card]) -> [Card] {
        guard let card = cards.first(where: { $0.id == move.card }) else { return cards }
        let from = card.placement
        var newPlacement: Placement?
        switch move.target {
        case .none:
            newPlacement = nil
        case .review(let section):
            let finishedUnplaced = card.isFinished && from == nil
            newPlacement = Placement(tab: .review, section: finishedUnplaced ? .done : section)
        case .mine:
            let finishedUnplaced = card.isFinished && from == nil
            newPlacement = Placement(tab: .mine, section: finishedUnplaced ? .done : .main)
        case .mineDone:
            newPlacement = Placement(tab: .mine, section: .done)
        }
        var out = cards.map { other -> Card in
            guard other.id == card.id else { return other }
            var other = other
            other.placement = newPlacement
            // Out of Done no automatic Dismiss is due; into Done the next
            // list brings its time.
            if newPlacement?.isDone != true, newPlacement != nil { other.autoDismissAt = nil }
            return other
        }
        if let target = newPlacement, let tab = target.tab.value, let section = target.section.value {
            let key = SectionKey.placed(tab, section)
            let members = Listing.ranked(out.filter { $0.id != card.id && $0.sectionKey == key })
            var plain = members.filter { !$0.isMuted }.map(\.id)
            var muted = members.filter(\.isMuted).map(\.id)
            func insert(into list: inout [String]) {
                let index: Int
                if section == .done {
                    // Done is newest first; the daemon places it by the time
                    // it saw the PR close.
                    index = 0
                } else {
                    switch move.position {
                    case .before(let other): index = list.firstIndex(of: other) ?? list.count
                    case .top: index = 0
                    case .bottom: index = list.count
                    case .byDefault:
                        let fromDoingOrWaiting = from?.tab.value == .review
                            && (from?.section.value == .doing || from?.section.value == .waiting)
                        index = section == .todo && fromDoingOrWaiting ? 0 : list.count
                    }
                }
                list.insert(card.id, at: index)
            }
            if card.isMuted { insert(into: &muted) } else { insert(into: &plain) }
            out = renumber(out, plain + muted)
        }
        let newKey = newPlacement.flatMap { placement -> String? in
            guard let tab = placement.tab.value, let section = placement.section.value else { return nil }
            return SectionKey.placed(tab, section)
        }
        if let from, let tab = from.tab.value, let section = from.section.value, SectionKey.placed(tab, section) != newKey {
            let key = SectionKey.placed(tab, section)
            let left = Listing.ranked(out.filter { $0.id != card.id && $0.sectionKey == key }).map(\.id)
            out = renumber(out, left)
        }
        return out
    }

    static func renumber(_ cards: [Card], _ order: [String]) -> [Card] {
        var rank: [String: Int] = [:]
        for (index, id) in order.enumerated() { rank[id] = index }
        return cards.map { card in
            guard let position = rank[card.id], card.placement != nil else { return card }
            var card = card
            card.placement?.position = position
            return card
        }
    }
}
