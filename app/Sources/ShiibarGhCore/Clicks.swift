// What a click does (DESIGN.md, "What a press does"): a click on a card's
// heading or a row selects it at once; the second click of a series (count
// 2) opens it only when the first click of the series was on the same
// heading or row, not on a control; later clicks of the series (count 3 and
// more) do nothing more; a control acts once per series. The app reads
// the click count (`NSEvent.clickCount`) and what is under the pointer, and
// does what `ClickClassifier.classify` returns.

import Foundation

/// What a click landed on.
public enum ClickTarget: Equatable {
    /// A card's heading or a row, not on one of its controls.
    case item(SelectionItem)
    /// A control: a status icon, the chain icon, ×, the
    /// placement tag, "+ N more", `Show less`, `Older activity on GitHub`,
    /// a section heading, "+ N more PRs". `id` tells one control from
    /// another.
    case control(String)
}

public enum ClickOutcome: Equatable {
    /// Select the item (a row is read): the first click.
    case select(SelectionItem)
    /// Open the item (a row is read): the second click of a series on the
    /// same item.
    case open(SelectionItem)
    /// Let the control act: the first click of a series on it.
    case control(String)
    /// Nothing: every other click of a series.
    case nothing
}

/// Remembers the first click of the current series.
public struct ClickClassifier: Equatable {
    private var first: ClickTarget?

    public init() {}

    /// `count` is the click count of the press (1 for a single click).
    public mutating func classify(_ target: ClickTarget, count: Int) -> ClickOutcome {
        if count <= 1 {
            first = target
            switch target {
            case .item(let item): return .select(item)
            case .control(let id): return .control(id)
            }
        }
        // A triple click opens once, at its second click.
        guard count == 2, case .item(let item) = target, first == target else { return .nothing }
        return .open(item)
    }
}

/// A press on a card's heading or row (DESIGN.md, "What a press does" and
/// "Selection and operating on several cards"): what happens at once, and
/// what waits for the release because the press may still become a drag.
/// - On one of several selected cards: nothing at once; on release without
///   a drag, the item alone is selected (a drag moves them all).
/// - On a card that can be dragged: the item is selected at once; a row is
///   read on release, only if no drag started.
/// - Else: the click as it is, a row read at once.
public struct CardPress: Equatable {
    /// What the press does now.
    public enum Now: Equatable {
        case click(readsRow: Bool)
        case nothing
    }

    /// What the release does, if no drag started.
    public enum Release: Equatable {
        case select(SelectionItem)
        case read(SelectionItem)
    }

    public private(set) var pending: Release?

    public init() {}

    public mutating func down(
        _ item: SelectionItem, count: Int, severalSelected: Bool, cardSelected: Bool, draggable: Bool
    ) -> Now {
        pending = nil
        guard count == 1 else { return .click(readsRow: true) }
        if severalSelected && cardSelected {
            pending = .select(item)
            return .nothing
        }
        if draggable {
            pending = .read(item)
            return .click(readsRow: false)
        }
        return .click(readsRow: true)
    }

    /// A drag started: the release does nothing.
    public mutating func dragStarted() {
        pending = nil
    }

    /// The release: what it does, once.
    public mutating func up() -> Release? {
        defer { pending = nil }
        return pending
    }
}
