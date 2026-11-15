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

/// Where a card lands in a section: right before a card (`before`), at the
/// top (`at: top`) or at the bottom (`at: bottom`), hidden cards included
/// (DESIGN.md, "What a press does", "Hidden cards and places").
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
    /// and the Dismissed list (DESIGN.md, "What a press does"). The places
    /// are among the reference cards (`SectionLayout.matching`: the cards
    /// the search and Show muted leave, folded and collapsed ones
    /// included), V1, V2, … ("Hidden cards and places"): a heading and the
    /// upper half of V1 are the top, the upper half of Vk is before Vk, the
    /// lower half of Vk is before V(k+1) or the bottom, "+ N more PRs" is
    /// right after the last card shown.
    /// Anywhere in Done it lands by Done's own order: newest first, no
    /// position.
    public static func target(_ zone: DropZone, sections: [SectionLayout]) -> DropTarget? {
        switch zone {
        case .header(let key):
            // A heading: the top of the section, open or collapsed.
            guard let section = sections.first(where: { $0.key == key }), section.accepts else { return nil }
            return DropTarget(section: key, position: section.isDone ? .byDefault : .top)
        case .more(let key):
            // "+ N more PRs": right after the last card shown (DESIGN.md,
            // "Selection"); the drop opens the section.
            guard let section = sections.first(where: { $0.key == key }), section.accepts else { return nil }
            if section.isDone { return DropTarget(section: key, position: .byDefault) }
            let refs = section.matching.map(\.id)
            guard let last = section.cards.last, let index = refs.firstIndex(of: last.id) else {
                return DropTarget(section: key, position: .bottom)
            }
            return DropTarget(section: key, position: position(index, lowerHalf: true, in: refs))
        case .card(let id, let lowerHalf):
            guard let section = sections.first(where: { $0.isLeaf && $0.matching.contains { $0.id == id } }),
                  section.accepts else { return nil }
            if section.isDone { return DropTarget(section: section.key, position: .byDefault) }
            let cards = section.matching
            guard let index = cards.firstIndex(where: { $0.id == id }) else { return nil }
            return DropTarget(section: section.key, position: position(index, lowerHalf: lowerHalf, in: cards.map(\.id)))
        }
    }

    /// The place of a drop over the upper or lower half of the reference
    /// card at `index` of `refs`.
    static func position(_ index: Int, lowerHalf: Bool, in refs: [String]) -> PlacePosition {
        if !lowerHalf { return index == 0 ? .top : .before(refs[index]) }
        return index + 1 < refs.count ? .before(refs[index + 1]) : .bottom
    }

    /// The card the insertion line is drawn above, or nil for the end of the
    /// section's shown cards (above "+ N more PRs" if there is one).
    public static func lineAbove(_ target: DropTarget, in section: SectionLayout) -> String? {
        // Done: the newest entry, above the first card.
        if section.isDone { return section.cards.first?.id }
        switch target.position {
        case .before(let id):
            // Before a folded card: the end of the shown ones.
            return section.cards.contains(where: { $0.id == id }) ? id : nil
        case .top:
            return section.cards.first?.id
        case .bottom, .byDefault:
            return nil
        }
    }

    /// Every card of a section that is not dismissed, hidden ones included,
    /// by rank.
    static func wholeSection(_ key: String, _ cards: [Card]) -> [String] {
        Listing.ranked(cards.filter { !$0.isDismissed && $0.sectionKey == key }).map(\.id)
    }

    /// The `place` of a drop, nil when the card would stay where it is.
    /// `before` names a card by its id here; the request takes its PR.
    public static func move(_ card: Card, to target: DropTarget, cards: [Card]) -> PlaceMove? {
        guard let (tab, section) = SectionKey.placement(target.section) else { return nil }
        let placeTarget = Self.target(tab, section)
        if card.sectionKey == target.section {
            // Done keeps its own order: a card already there stays.
            if section == .done { return nil }
            let order = wholeSection(target.section, cards)
            var after = order.filter { $0 != card.id }
            switch target.position {
            case .before(let other):
                guard let index = after.firstIndex(of: other) else { return nil }
                after.insert(card.id, at: index)
            case .top:
                after.insert(card.id, at: 0)
            default:
                after.append(card.id)
            }
            if after == order { return nil }
        }
        return PlaceMove(card: card.id, target: placeTarget, position: target.position, verb: .move)
    }

    /// ⌥↑ or ⌥↓: past the previous or next reference card (`refs`: the
    /// section's `matching`), landing where a drop over its upper half (⌥↑;
    /// past V1, the top) or its lower half (⌥↓) would ("Hidden cards and
    /// places"). Nil where it cannot move: All, Done, the ends.
    public static func reorder(_ card: Card, up: Bool, refs: [Card]) -> PlaceMove? {
        guard card.canReorder, let key = card.sectionKey, let (tab, section) = SectionKey.placement(key) else { return nil }
        let target = Self.target(tab, section)
        let ids = refs.map(\.id)
        guard let index = ids.firstIndex(of: card.id) else { return nil }
        if up {
            guard index > 0 else { return nil }
            return PlaceMove(card: card.id, target: target, position: position(index - 1, lowerHalf: false, in: ids), verb: .move)
        }
        guard index + 1 < ids.count else { return nil }
        return PlaceMove(card: card.id, target: target, position: position(index + 1, lowerHalf: true, in: ids), verb: .move)
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

    /// The cards with this change made. `mutes` are the account's mutes;
    /// a mute or unmute changes them too, for the changes after it.
    public func apply(_ cards: [Card], mutes: inout Mutes) -> [Card] {
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
        case .mute(let kind, let name), .unmute(let kind, let name):
            let on: Bool
            if case .mute = self { on = true } else { on = false }
            mutes = mutes.changing(kind, name, on: on)
            return MuteRules.apply(cards, kind: kind, name: name, on: on, mutes: mutes)
        }
    }

    /// The same, with the mutes read off the cards.
    public func apply(_ cards: [Card]) -> [Card] {
        var mutes = Mutes.inferred(from: cards)
        return apply(cards, mutes: &mutes)
    }

    /// The card at its new place: ranks of the sections it leaves and
    /// joins are numbered again, muted cards where their rank puts them
    /// (DESIGN.md, "Review": placement does not depend on Mute).
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
            var order = Listing.ranked(out.filter { $0.id != card.id && $0.sectionKey == key }).map(\.id)
            let index: Int
            if section == .done {
                // Done is newest first; the daemon places it by the time.
                index = 0
            } else {
                switch move.position {
                case .before(let other): index = order.firstIndex(of: other) ?? order.count
                case .top: index = 0
                case .bottom: index = order.count
                case .byDefault:
                    let fromDoingOrWaiting = from?.tab.value == .review
                        && (from?.section.value == .doing || from?.section.value == .waiting)
                    index = section == .todo && fromDoingOrWaiting ? 0 : order.count
                }
            }
            order.insert(card.id, at: index)
            out = renumber(out, order)
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
