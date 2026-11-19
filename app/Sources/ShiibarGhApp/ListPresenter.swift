// What the list of one surface draws, split so that a change redraws only
// the views it changes (DESIGN.md, "Speed of operation"):
//
// - `ListContent` is the order of the list (headings, cards, lines). It
//   tells the list (ListTable.swift) to apply a change when the cards, the
//   tab, the search, the folds or the expanded rows change; not for the
//   selection or a drag.
// - `ItemState` is one card's (or heading's) selection, mark as one of
//   several selected cards, drag and heading highlight. A change of the
//   selection sets the states of the items it concerns, and only the line views bound to them
//   (ListCells.swift) draw again. The insertion line of a drag is one view
//   of the list, moved by the list.
//
// `@Published` publishes before the value is set, with the new value
// (Combine `Published.Publisher`); the item states take the new value from
// it, and the list reads the model before the run loop next sleeps.

import AppKit
import Combine
import ShiibarGhCore
import SwiftUI

/// The state of one card, heading, "+ N more PRs" line or empty section.
/// A change tells the line view that shows it, if one does.
@MainActor
final class ItemState {
    /// The line view showing this item (a reused view moves to another).
    weak var view: LineView?
    /// The selected item when it is this card's (or this heading).
    var selected: SelectionItem? { didSet { if selected != oldValue { view?.stateChanged() } } }
    /// One of several selected cards (its heading shows selected).
    var marked = false { didSet { if marked != oldValue { view?.stateChanged() } } }
    var dragged = false { didSet { if dragged != oldValue { view?.stateChanged() } } }
    /// A dragged card would land in this collapsed or empty section.
    var over = false { didSet { if over != oldValue { view?.stateChanged() } } }
    /// A card `Unread only` kept, in its last 0.3 seconds: drawn faded by
    /// the view's opacity, not in its image (ListCells.swift).
    var fading = false { didSet { if fading != oldValue { view?.fadingChanged() } } }
}

@MainActor
final class ListContent: ObservableObject {
    unowned let list: SurfaceListModel
    private var states: [String: ItemState] = [:]
    private var cancellables: Set<AnyCancellable> = []
    /// Set while the list is shown: scrolls to the selection.
    weak var table: ListTableController?
    /// The card a dragged card would land above (`.top`) or below
    /// (`.bottom`, the last card of a section).
    private(set) var dropLine: (String, VerticalEdge)?
    /// Called when `dropLine` changes.
    var onDropLine: (() -> Void)?
    /// Where the list goes (`ListSlot`); `onSlot` places it when the anchor
    /// moves. The header's and the key hints' anchors are for the
    /// measurement mode's check that the list stays clear of them.
    weak var listAnchor: FrameAnchor?
    weak var headerAnchor: FrameAnchor?
    weak var hintsAnchor: FrameAnchor?
    /// The Filter's options while they show: their area's height, for the
    /// surface's least height (`SurfaceRoot.onMinimumHeight`).
    weak var optionsAnchor: FrameAnchor?
    /// The warning and failure bands while they show: left out of the
    /// surface's least height.
    weak var bandsAnchor: FrameAnchor?
    var onSlot: (() -> Void)?
    /// The time and the text scale from the surface.
    var environment: (Int64, CGFloat)? { didSet { onEnvironment?() } }
    var onEnvironment: (() -> Void)?
    weak var drag: CardDragController?
    /// The context the views of this list share. Both live as long as the
    /// surface's list model (kept per account by the app).
    var context: CardContext!

    init(list: SurfaceListModel) {
        self.list = list
        // The order of the list: whatever changes the sections, not the
        // selection or a drag.
        let data = list.data
        let changes: [AnyPublisher<Void, Never>] = [
            data.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            list.$tab.map { _ in () }.eraseToAnyPublisher(),
            list.$showingDismissed.map { _ in () }.eraseToAnyPublisher(),
            list.$expandedRows.map { _ in () }.eraseToAnyPublisher(),
            list.$lingering.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        list.$selection.sink { [weak self] next in self?.selectionChanges(to: next) }.store(in: &cancellables)
        list.$selectedCards.sink { [weak self] next in self?.selectedCardsChange(to: next) }.store(in: &cancellables)
        list.$dragging.sink { [weak self] next in self?.draggingChanges(to: next) }.store(in: &cancellables)
        list.$dropTarget.sink { [weak self] next in self?.dropTargetChanges(to: next) }.store(in: &cancellables)
        list.$fading.sink { [weak self] next in self?.fadingChanges(to: next) }.store(in: &cancellables)
        // Kept cards about to hide: the list keeps the selected item (or the
        // first in view) where it is on the screen (DESIGN.md, "Filter").
        list.lingerHides.sink { [weak self] cards in self?.table?.keepPlace(hiding: cards) }.store(in: &cancellables)
    }

    // MARK: The order

    var entries: [ListEntry] {
        var out: [ListEntry] = []
        if let text = list.emptyText { out.append(.message(text)) }
        // The search of what shows (a tab's, or the Dismissed list's).
        let words = Search.words(list.search)
        if list.showingDismissed {
            for (index, group) in list.dismissedGroups.enumerated() {
                out.append(.heading(HeadingLine(group, first: index == 0)))
                out += group.cards.map { .dismissed($0, search: words) }
            }
            out.append(.end)
            return out
        }
        let showsTag = list.tab == .all
        let expanded = list.expandedRows
        let compact = list.compact
        let showsLabels = list.showLabels
        for section in list.sections {
            if section.showsHeader { out.append(.heading(HeadingLine(section))) }
            for card in section.cards {
                out.append(.card(CardLine(
                    card: card, section: section.key, showsTag: showsTag, indented: section.level == 2,
                    expanded: expanded.contains(card.id), canDrag: section.accepts && card.canDrag,
                    expandedBodies: list.expandedBodies.intersection(card.rows.map(\.id)),
                    compact: compact, unread: compact ? UnreadMark.of(card.rows) : .none, search: words,
                    showsLabels: showsLabels
                )))
            }
            if section.accepts, section.matching.isEmpty, !section.collapsed { out.append(.empty(section.key)) }
            if let text = section.foldLine {
                out.append(.fold(FoldValues(key: section.key, text: text, mark: section.more > 0 ? section.moreMark : .none)))
            }
        }
        out.append(.end)
        return out
    }

    // MARK: Item states

    /// The state of a card (`card:<id>`), heading (`section:<key>`), "+ N
    /// more PRs" line (`more:<key>`) or empty section (`empty:<key>`): the
    /// ids of `ListEntry`.
    func state(_ id: String) -> ItemState {
        if let state = states[id] { return state }
        let state = ItemState()
        if let selection = list.selection, ListEntry.id(of: selection) == id { state.selected = selection }
        if id.hasPrefix("card:") {
            let card = String(id.dropFirst(5))
            state.marked = Self.marked(list.selectedCards).contains(card)
            state.dragged = isDragged(card, dragging: list.dragging, selected: list.selectedCards)
            state.fading = list.fading.contains(card)
        }
        states[id] = state
        return state
    }

    private func isDragged(_ card: String, dragging: String?, selected: CardSelection) -> Bool {
        guard let dragging else { return false }
        return dragging == card || (selected.isMultiple && selected.contains(dragging) && selected.contains(card))
    }

    /// The cards shown as one of several selected.
    private static func marked(_ selected: CardSelection) -> Set<String> {
        selected.isMultiple ? selected.cards : []
    }

    private func selectionChanges(to next: SelectionItem?) {
        let previous = list.selection
        if let previous, previous != next {
            states[ListEntry.id(of: previous)]?.selected = nil
        }
        if let next {
            let state = states[ListEntry.id(of: next)]
            if state?.selected != next { state?.selected = next }
            // After the change is made: scroll only when the item is not in
            // view (a click is always in view).
            DispatchQueue.main.async { [weak self] in self?.reveal(next) }
        }
    }

    private func selectedCardsChange(to next: CardSelection) {
        let before = Self.marked(list.selectedCards)
        let after = Self.marked(next)
        for card in before.symmetricDifference(after) {
            states["card:" + card]?.marked = after.contains(card)
        }
        if let dragging = list.dragging { updateDragged(dragging: dragging, selected: next) }
    }

    private func fadingChanges(to next: Set<String>) {
        for card in list.fading.symmetricDifference(next) {
            states["card:" + card]?.fading = next.contains(card)
        }
    }

    private func draggingChanges(to next: String?) {
        updateDragged(dragging: next, selected: list.selectedCards)
    }

    private func updateDragged(dragging: String?, selected: CardSelection) {
        for (id, state) in states where id.hasPrefix("card:") {
            let value = isDragged(String(id.dropFirst(5)), dragging: dragging, selected: selected)
            if state.dragged != value { state.dragged = value }
        }
    }

    private func dropTargetChanges(to next: DropTarget?) {
        var lines: [String: VerticalEdge] = [:]
        var over: String?
        if let next, let section = list.sections.first(where: { $0.key == next.section }) {
            if section.collapsed || section.cards.isEmpty {
                over = section.key
            } else if let id = CardDrop.lineAbove(next, in: section) {
                lines["card:" + id] = .top
            } else if let last = section.cards.last {
                lines["card:" + last.id] = .bottom
            }
        }
        let line = lines.first.map { (String($0.key.dropFirst(5)), $0.value) }
        if line?.0 != dropLine?.0 || line?.1 != dropLine?.1 {
            dropLine = line
            onDropLine?()
        }
        for (id, state) in states {
            if id.hasPrefix("section:") || id.hasPrefix("empty:") {
                let key = id.hasPrefix("section:") ? String(id.dropFirst(8)) : String(id.dropFirst(6))
                let value = over == key
                if state.over != value { state.over = value }
            }
        }
    }

    // MARK: Scrolling to the selection

    private func reveal(_ item: SelectionItem) {
        guard list.selection == item, list.dragging == nil else { return }
        if drag?.isVisible(item) == true { return }
        table?.reveal(item)
    }
}
