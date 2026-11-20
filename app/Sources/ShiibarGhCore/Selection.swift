// Selecting several cards (DESIGN.md, "Selection"): the cards selected on
// one surface with ⌘-click, ⇧-click, ⇧↑↓ and ⌘A, the anchor of a range,
// which selected cards an operation can take, the multi-card menu of each
// tab, and the order and places of the requests that move several cards so
// they keep the order they were shown in. The selection lives in the app
// only; the daemon sees one request per card.

import Foundation

/// The selected cards of one surface (the popover or the window) and the
/// anchor of a range (⇧-click, ⇧↑↓).
public struct CardSelection: Equatable {
    public private(set) var cards: Set<String> = []
    /// The card clicked, ⌘-clicked or reached by the keyboard last.
    public private(set) var anchor: String?
    /// The end of the range the last ⇧-click or ⇧↑↓ made; nil: the anchor
    /// (DESIGN.md, "Selection").
    public private(set) var end: String?

    /// Where ⇧↑↓ and, with several cards, ↑↓ go on from.
    public var edge: String? { end ?? anchor }

    public init() {}

    public var isEmpty: Bool { cards.isEmpty }
    public var count: Int { cards.count }
    /// Several cards: keys, drags and the menu act on all of them.
    public var isMultiple: Bool { cards.count > 1 }

    public func contains(_ card: String) -> Bool { cards.contains(card) }

    /// A click or ↑↓: this card alone, the anchor.
    public mutating func only(_ card: String) {
        cards = [card]
        anchor = card
        end = nil
    }

    /// ⌘-click: the card in or out of the selection; it becomes the anchor.
    public mutating func toggle(_ card: String) {
        if cards.contains(card) { cards.remove(card) } else { cards.insert(card) }
        anchor = card
        end = nil
        if cards.isEmpty { anchor = nil }
    }

    /// ⇧-click and ⇧↑↓: every card shown from the anchor to `card`
    /// (`shown`: the cards laid out, in order, across sections; not the
    /// folded nor the collapsed ones), in place of the selection. The
    /// anchor stays; without one, `card` alone.
    public mutating func range(to card: String, shown: [String]) {
        if let anchor, let from = shown.firstIndex(of: anchor), let to = shown.firstIndex(of: card) {
            cards = Set(shown[min(from, to)...max(from, to)])
            end = card
        } else {
            only(card)
        }
    }

    /// ⌘A: every card shown.
    public mutating func all(_ shown: [String]) {
        cards = Set(shown)
        if let anchor, cards.contains(anchor) { return }
        anchor = shown.first
    }

    /// The cards (dropped or moved) as the selection.
    public mutating func set(_ selected: [String]) {
        cards = Set(selected)
        if let anchor, cards.contains(anchor) { return }
        anchor = selected.first
    }

    /// Cards back in the selection (an operation the daemon refused).
    public mutating func add<S: Sequence>(_ more: S) where S.Element == String {
        for card in more { cards.insert(card) }
    }

    /// A click on the list's empty part, Esc, a tab switch, the Dismissed
    /// list, closing.
    public mutating func clear() {
        cards = []
        anchor = nil
        end = nil
    }

    /// After the list changed: cards no longer shown (`shown`: laid out)
    /// leave the selection, the anchor with its card.
    public mutating func update(shown: Set<String>) {
        let gone = cards.subtracting(shown)
        if !gone.isEmpty { cards.subtract(gone) }
        if let anchor, !shown.contains(anchor) || cards.isEmpty { self.anchor = nil }
        if let end, !shown.contains(end) || cards.isEmpty { self.end = nil }
    }
}

/// An operation on the selected cards: a key, a drag or an item of the
/// multi-card menu.
public enum MultiOperation: Equatable {
    case dismiss
    /// `Add to Review` or `Add to Mine` (Inbox).
    case add(PlaceTarget)
    /// `Move to …`, I / D / W.
    case move(PlaceTarget)
    /// `Remove from Review`, `Remove from Mine`.
    case remove
}

/// An item of the multi-card menu.
public struct MultiItem: Equatable {
    public var title: String
    public var operation: MultiOperation
}

/// What an operation on the selected cards does.
public struct MultiPlan: Equatable {
    /// Dismiss these cards, in this order.
    public var dismiss: [String] = []
    /// `place` these moves, in this order.
    public var moves: [PlaceMove] = []
    /// Taken without a request (already where they go).
    public var unchanged: [String] = []
    /// Cards the operation cannot take: they stay selected.
    public var skipped: [String] = []

    /// Every card the operation takes.
    public var taken: [String] { dismiss + moves.map(\.card) + unchanged }
}

public enum MultiRules {
    /// The multi-card operations of a tab, in the order of the menu
    /// (DESIGN.md, "Selection").
    public static func operations(_ tab: ListTab) -> [MultiItem] {
        switch tab {
        case .all:
            return [MultiItem(title: "Add to Review", operation: .add(.review(.inbox))), MultiItem(title: "Add to Mine", operation: .add(.mine(.inbox)))]
        case .review:
            return PlacementSection.menuOrder.map { MultiItem(title: "Move to " + $0.title, operation: .move(.review($0))) }
                + [MultiItem(title: "Remove from Review", operation: .remove)]
        case .mine:
            return PlacementSection.menuOrder.map { MultiItem(title: "Move to " + $0.title, operation: .move(.mine($0))) }
                + [MultiItem(title: "Remove from Mine", operation: .remove)]
        }
    }

    /// The operations of the multi-card menu that at least one of `cards`
    /// can take (a move to the section all of them are in is left out).
    public static func menu(_ tab: ListTab, cards: [Card]) -> [MultiItem] {
        operations(tab).filter { item in
            let plan = plan(item.operation, cards: cards)
            return !plan.moves.isEmpty || !plan.dismiss.isEmpty
        } + [MultiItem(title: "Dismiss", operation: .dismiss)]
    }

    /// The selected cards of the tab in the order shown: section by
    /// section as `sections` lays them out, folded and collapsed ones
    /// included (`matching`), then any the search hides, in the order of the
    /// tab.
    public static func ordered(_ selection: CardSelection, sections: [SectionLayout], tabCards: [Card]) -> [Card] {
        var seen: Set<String> = []
        var out: [Card] = []
        for section in sections where section.isLeaf {
            for card in section.matching where selection.contains(card.id) && seen.insert(card.id).inserted {
                out.append(card)
            }
        }
        for card in tabCards where selection.contains(card.id) && seen.insert(card.id).inserted {
            out.append(card)
        }
        return out
    }

    /// The section a target lands in, for a card.
    static func landing(_ target: PlaceTarget, _ card: Card) -> (PlacementTab, PlacementSection)? {
        guard let (tab, section) = target.placed else { return nil }
        return (tab, card.isFinished && card.placement == nil ? .done : section)
    }

    /// The requests of an operation on `cards` (the selected cards in the
    /// order shown). Cards keep that order where they land together:
    /// those going to the top are sent last first with `at: top`, those
    /// going to the bottom in order with `at: bottom`, those dropped before
    /// one card in order with `before`, and those going into Done last
    /// first, so the first shown is the newest there.
    public static func plan(_ operation: MultiOperation, cards: [Card], verb: OperationVerb? = nil) -> MultiPlan {
        var plan = MultiPlan()
        switch operation {
        case .dismiss:
            plan.dismiss = cards.map(\.id)
        case .remove:
            for card in cards {
                if card.placement?.tab.value == .mine && card.authoredByMe {
                    plan.skipped.append(card.id)
                } else {
                    plan.moves.append(PlaceMove(card: card.id, target: .none, position: .byDefault, verb: verb ?? .remove))
                }
            }
        case .add(let target):
            var takes: [Card] = []
            for card in cards {
                if card.placement != nil || (target.placed?.tab == .review && card.authoredByMe) {
                    plan.skipped.append(card.id)
                } else {
                    takes.append(card)
                }
            }
            // Added at the end, in order; closed PRs go to Done by the time
            // they were found closed, whatever the order.
            plan.moves = takes.map { PlaceMove(card: $0.id, target: target, position: .byDefault, verb: verb ?? .add) }
        case .move(let target):
            var top: [Card] = []
            var bottom: [Card] = []
            var done: [Card] = []
            for card in cards {
                guard let (tab, section) = landing(target, card), card.placement?.tab.value == tab else {
                    plan.skipped.append(card.id)
                    continue
                }
                if card.placement?.section.value == section {
                    plan.unchanged.append(card.id)
                    continue
                }
                if section == .done {
                    done.append(card)
                } else if section == .inbox,
                          card.placement?.section.value == .doing || card.placement?.section.value == .waiting {
                    top.append(card)
                } else {
                    bottom.append(card)
                }
            }
            let v = verb ?? .move
            plan.moves = top.reversed().map { PlaceMove(card: $0.id, target: target, position: .top, verb: v) }
                + bottom.map { PlaceMove(card: $0.id, target: target, position: .bottom, verb: v) }
                + done.reversed().map { PlaceMove(card: $0.id, target: target, position: .byDefault, verb: v) }
        }
        return plan
    }

    /// ⌥↑ or ⌥↓ with several cards selected: the selected cards of
    /// `section` move together past the nearest card above (⌥↑) or below
    /// (⌥↓) that is not selected, keeping their order. Selected cards of
    /// other sections, and of Done, are not moved.
    public static func reorder(_ cards: [Card], up: Bool, in section: SectionLayout, all: [Card]) -> [PlaceMove] {
        guard section.accepts, !section.isDone else { return [] }
        let refs = section.matching.map(\.id)
        let taking = cards.filter { refs.contains($0.id) && $0.canReorder }
        let moving = Set(taking.map(\.id))
        guard let first = refs.firstIndex(where: moving.contains), let last = refs.lastIndex(where: moving.contains) else { return [] }
        let position: PlacePosition
        if up {
            guard let previous = refs[..<first].lastIndex(where: { !moving.contains($0) }) else { return [] }
            position = CardDrop.position(previous, lowerHalf: false, in: refs)
        } else {
            guard let next = refs[(last + 1)...].firstIndex(where: { !moving.contains($0) }) else { return [] }
            position = CardDrop.position(next, lowerHalf: true, in: refs)
        }
        return drop(taking, at: DropTarget(section: section.key, position: position), sections: [section], all: all)
    }

    /// The requests of dropping the selected cards (`cards`, in the order
    /// shown) at `target`. When the reference card of the drop is one of
    /// the moving cards, the nearest reference card that does not move
    /// decides (DESIGN.md, "Selection"): the cards land
    /// right before the next reference card that stays (or at the bottom),
    /// or at the top when no reference card before it stays. Nothing is
    /// sent when the order would not change.
    public static func drop(_ cards: [Card], at target: DropTarget, sections: [SectionLayout], all: [Card]) -> [PlaceMove] {
        guard let (tab, section) = SectionKey.placement(target.section) else { return [] }
        let placeTarget = CardDrop.target(tab, section)
        let moving = Set(cards.map(\.id))
        var position = target.position
        if case .before(let id) = position, moving.contains(id) {
            let refs = sections.first { $0.key == target.section }?.matching.map(\.id) ?? []
            if let index = refs.firstIndex(of: id) {
                if !refs[..<index].contains(where: { !moving.contains($0) }) {
                    position = .top
                } else if let next = refs[(index + 1)...].first(where: { !moving.contains($0) }) {
                    position = .before(next)
                } else {
                    position = .bottom
                }
            } else {
                position = .bottom
            }
        }
        let takes = cards.filter { $0.placement?.tab.value == tab }
        let moves: [PlaceMove]
        if section == .done {
            moves = takes.filter { $0.placement?.section.value != .done }.reversed()
                .map { PlaceMove(card: $0.id, target: placeTarget, position: .byDefault, verb: .move) }
        } else {
            switch position {
            case .top:
                moves = takes.reversed().map { PlaceMove(card: $0.id, target: placeTarget, position: .top, verb: .move) }
            default:
                moves = takes.map { PlaceMove(card: $0.id, target: placeTarget, position: position, verb: .move) }
            }
        }
        // The order would not change: nothing is sent. Only the whole drop
        // is left out this way: when some of the cards are where they
        // would land already and others move, every request is sent (those
        // cards land where they are).
        let after = moves.reduce(all) { LocalChange.place($1, $0) }
        func order(_ cards: [Card]) -> [String: [String]] {
            var out: [String: [String]] = [:]
            for card in Listing.ranked(cards.filter { !$0.isDismissed }) {
                if let key = card.sectionKey { out[key, default: []].append(card.id) }
            }
            return out
        }
        return order(after) == order(all) ? [] : moves
    }
}
