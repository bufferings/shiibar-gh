// What one surface (the popover or the window) of an account shows: its
// tab, whether the Dismissed list is open and its selection (the selected
// item and the selected cards) (DESIGN.md, "Open in window": the popover and
// the window keep these apart), and the cards `Unread only` keeps showing
// for a while (`UnreadLinger`). The expanded rows of the cards and of the row
// bodies, the Filters, whether `Filter` is open and the search texts are the
// account's and shared. The data and the saved choices come from the shared
// `AccountViewModel`.

import Combine
import Foundation

/// A property that publishes its new value before it is set, as
/// `@Published` does, but does not tell the model's observers
/// (`objectWillChange`): the selection and a drag change often,
/// and only the views that show them follow them (the list's line views,
/// `SurfaceChrome`), not every view of the surface.
@propertyWrapper
public struct Quiet<Value> {
    private final class Box {
        var value: Value
        let willChange = PassthroughSubject<Value, Never>()

        init(_ value: Value) {
            self.value = value
        }
    }

    private let box: Box

    public init(wrappedValue: Value) {
        box = Box(wrappedValue)
    }

    /// Subscribers get the new value before it is stored, as with
    /// `@Published`: while they run, the property still reads the old one.
    public var wrappedValue: Value {
        get { box.value }
        nonmutating set {
            box.willChange.send(newValue)
            box.value = newValue
        }
    }

    /// The current value, then each new one.
    public var projectedValue: AnyPublisher<Value, Never> {
        box.willChange.prepend(box.value).eraseToAnyPublisher()
    }
}

/// What the surface shows around the list that follows the selection: the
/// key hints. Published only when a value changes.
@MainActor
public final class SurfaceChrome: ObservableObject {
    @Published public internal(set) var hints: [KeyHint] = []

    nonisolated init() {}
}

@MainActor
public final class SurfaceListModel: ObservableObject {
    public let surface: Surface
    public unowned let data: AccountViewModel
    /// The last tab, kept per surface (DESIGN.md, "Tabs").
    @Published public private(set) var tab: ListTab
    @Published public private(set) var showingDismissed = false
    /// Whether the search field has the keyboard.
    @Published public var searchFocused = false
    @Quiet public private(set) var selection: SelectionItem? = nil { didSet { refreshChrome(); selectionMoved() } }
    /// Cards whose rows show past the newest three: the account's, kept
    /// (DESIGN.md, "Rows in a card"), mirrored here for the list.
    @Published public private(set) var expandedRows: Set<String>
    /// The selected cards of this surface (DESIGN.md, "Selection"): the
    /// card of the selected item, or several with ⌘-click, ⇧-click, ⇧↑↓ and
    /// ⌘A. Not kept.
    @Quiet public private(set) var selectedCards = CardSelection() { didSet { refreshChrome(); selectionMoved() } }
    /// The Grouping sheet shows.
    @Published public var showsGrouping = false
    /// The card whose × was pressed while its confirmation sheet shows
    /// (DESIGN.md, "Confirming ×"): the list takes no input meanwhile.
    @Published public private(set) var confirmingDismiss: String? = nil
    /// `Don't ask again` on that sheet; off each time the sheet opens.
    @Published public var skipsNextConfirmations = false
    /// The card whose height changes because `more`, `less`, "+ N more" or
    /// `Show less` was pressed here: the list shows that change as an
    /// animation (DESIGN.md, "Row body"). Taken by the list once.
    private var animatedCard: String?

    public func takeAnimatedCard() -> String? {
        defer { animatedCard = nil }
        return animatedCard
    }
    /// The card being dragged, while a drag is on.
    @Quiet public private(set) var dragging: String? = nil
    /// How many cards the drag moves (all the selected ones when the
    /// dragged card is one of them).
    @Quiet public private(set) var draggingCount = 1
    /// Where the dragged card would land, for the insertion line.
    @Quiet public private(set) var dropTarget: DropTarget? = nil
    /// The cards `Unread only` keeps showing after they were read
    /// (DESIGN.md, "Filter"): shown, counted and selectable like the others.
    @Published public private(set) var lingering: Set<String> = []
    /// The kept cards in their last 0.3 seconds: drawn faded.
    @Quiet public private(set) var fading: Set<String> = []
    /// Sent with the kept cards whose time is up, right before they hide:
    /// the list keeps the selected item (or the first in view) where it is
    /// on the screen.
    public let lingerHides = PassthroughSubject<Set<String>, Never>()
    private var linger: UnreadLinger
    private var lingerDeadline: Double?
    private var lingerGeneration = 0
    /// A right-click menu shows: no kept card hides until it closes.
    public private(set) var menuShowing = false
    private var forward: AnyCancellable?
    private var clicks = ClickClassifier()

    init(data: AccountViewModel, surface: Surface) {
        self.data = data
        self.surface = surface
        linger = UnreadLinger(duration: data.app.linger.duration)
        tab = data.app.store.lastTab(account: data.accountId, surface: surface)
        expandedRows = data.expandedRows
        forward = data.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // The model changed (its data, the tab, the search): the hints
        // once the change is made.
        chromeWatch = objectWillChange.sink { [weak self] _ in
            guard let self, !self.chromeScheduled else { return }
            self.chromeScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.chromeScheduled = false
                self?.refreshChrome()
            }
        }
        refreshChrome()
    }

    /// The key hints (`SurfaceChrome`).
    public let chrome = SurfaceChrome()
    private var chromeWatch: AnyCancellable?
    private var chromeScheduled = false

    func refreshChrome() {
        let hints = self.hints
        if chrome.hints != hints { chrome.hints = hints }
    }

    var app: AppModel { data.app }

    /// `auto_dismiss_after_days`, for the tooltip of `Dismissed in N days`.
    public var autoDismissDays: Int64 { app.autoDismissDays }

    // MARK: Derived lists

    /// Whose search text the search field shows: the tab's, or the
    /// Dismissed list's.
    public var searchScope: SearchScope {
        showingDismissed ? .dismissed : .tab(tab)
    }

    /// The search text of what shows (the account's).
    public var search: String {
        data.search(searchScope)
    }

    // MARK: Filter

    /// The Filter of the tab shown (the account's).
    public var filter: ListFilter { data.filter(tab) }

    /// What the tab shows: its Filter and the cards kept by `Unread only`.
    public var visibility: Visibility {
        Visibility(filter: filter, kept: lingering)
    }

    /// The blue dot of `Filter`: a card of the tab shown that the Filter
    /// hides has a blue unread row (DESIGN.md, "Filter").
    public var filterDot: Bool {
        Listing.filterDot(data.cards, tab: tab, filter: filter)
    }

    /// `Filter` open on the tab shown (the account's, per tab, for the
    /// popover and the window).
    public var filterOpen: Bool { data.filterOpen(tab) }

    /// The Filter row under the search row (DESIGN.md, "Screens",
    /// "Filter"): always, every setting at its default too; not while the
    /// Dismissed list shows (the search row only).
    public var showsFilterRow: Bool { !showingDismissed }

    /// The summary in the Filter row: a setting of the tab shown differs
    /// from its default, `Filter` open or closed.
    public var showsFilterSummary: Bool { showsFilterRow && !filter.isDefault }

    /// `Reset` under the options can be pressed: a setting of the tab shown
    /// differs from its default (it shows disabled otherwise, so the
    /// options keep their height).
    public var canResetFilter: Bool { showsFilterRow && !filter.isDefault }

    /// The summary in the Filter row; nil when there is none.
    public var filterSummary: String? { showsFilterSummary ? filter.summary : nil }

    /// The options show: `Filter` open and not the Dismissed list (whose
    /// opening leaves the open state as it is).
    public var showsFilterOptions: Bool { filterOpen && !showingDismissed }

    /// The lines of the options: the same in every tab (DESIGN.md,
    /// "Filter").
    public var filterOptions: [FilterOption] { FilterOption.allCases }

    /// The `Grouping…` button at the right end of the Filter row: All
    /// only, not while the Dismissed list shows (DESIGN.md, "All",
    /// "Grouping settings").
    public var showsGroupingButton: Bool { tab == .all && showsFilterRow }

    /// The `Grouping…` button pressed: the Grouping sheet shows.
    public func openGrouping() {
        guard showsGroupingButton else { return }
        showsGrouping = true
    }

    /// A press on the word, the chevron or the dot (the summary does
    /// nothing).
    public func toggleFilterOpen() {
        data.setFilterOpen(!filterOpen, tab: tab)
    }

    /// `Reset` under the options: the tab's Status, Muted and Unread only
    /// go back to their defaults, as a change of the settings. The search
    /// text, the other tabs and whether `Filter` is open stay.
    public func resetFilter() {
        guard canResetFilter else { return }
        data.setFilter(ListFilter(), tab: tab)
    }

    public func setMuteChoice(_ choice: MuteChoice) {
        var next = filter
        next.muted = choice
        data.setFilter(next, tab: tab)
    }

    /// A status checkbox pressed: the last one on stays on.
    public func toggleStatus(_ status: PRStatus) {
        var next = filter
        next.setStatus(status, !next.shows(status))
        data.setFilter(next, tab: tab)
    }

    public func setUnreadOnly(_ on: Bool) {
        var next = filter
        next.unreadOnly = on
        data.setFilter(next, tab: tab)
    }

    /// A tab's Filter changed (here or on the other surface): on that tab
    /// the cards `Unread only` kept hide at once, the cards it hides now
    /// leave the selection.
    func filterChanged(_ changed: ListTab) {
        guard changed == tab, !showingDismissed else { return }
        resetLinger()
        keepSelection()
    }

    // MARK: Unread only

    /// The selection moved: a kept card held by it starts counting once
    /// it is let go.
    private func selectionMoved() {
        updateLinger()
    }

    /// The cards changed (AccountViewModel), or the selection did: a card
    /// shown that lost its last blue unread row is kept. Worked out before
    /// the selection follows the change, so a selected card that was read
    /// stays selected.
    func updateLinger() {
        guard !showingDismissed else { return }
        // A popover or window not shown keeps nothing: a card read while it
        // is closed does not show when it opens (DESIGN.md, "Filter").
        guard isShown else {
            if !linger.ids.isEmpty || !lingering.isEmpty || !fading.isEmpty { dropLinger() }
            linger.reset()
            return
        }
        let filter = self.filter
        guard filter.unreadOnly || !lingering.isEmpty || !fading.isEmpty else { return }
        var selected = selectedCards.cards
        if let card = selection?.owningCard { selected.insert(card) }
        let now = app.linger.now()
        linger.update(cards: Listing.cards(data.cards, tab: tab), filter: filter, selected: selected, now: now)
        publishLinger(now: now)
    }

    /// Whether this surface is shown: the popover while it is open, the
    /// window while it is open (with the focus or not).
    public var isShown: Bool {
        app.isDisplayed(surface, account: data.accountId)
    }

    /// Nothing kept, no timer, nothing faded.
    private func dropLinger() {
        linger.reset()
        lingerGeneration += 1
        lingerDeadline = nil
        if !fading.isEmpty { fading = [] }
        if !lingering.isEmpty { lingering = [] }
    }

    /// The surface is shown again (the popover opened, the window opened):
    /// the cards without a blue unread row now do not show, selected or
    /// not (DESIGN.md, "Filter").
    func shown() {
        resetLinger()
        keepSelection()
    }

    /// Nothing kept: a tab opened, the Filter changed, the Dismissed list,
    /// the surface closed. The cards shown now are the ones kept next.
    private func resetLinger() {
        dropLinger()
        updateLinger()
    }

    private var lingerBlocked: Bool { dragging != nil || menuShowing }

    private func publishLinger(now: Double) {
        let ids = linger.ids
        if ids != lingering { lingering = ids }
        let faded = linger.fading(now: now)
        if faded != fading { fading = faded }
        guard var next = linger.nextDeadline(now: now) else {
            lingerDeadline = nil
            lingerGeneration += 1
            return
        }
        // Time is up but a drag or a menu holds the cards: the end of it
        // hides them (`lingerTick`).
        if lingerBlocked, next <= now { return }
        next = max(next, now)
        if lingerDeadline == next { return }
        lingerDeadline = next
        lingerGeneration += 1
        let generation = lingerGeneration
        app.linger.schedule(next - now) { [weak self] in
            guard let self, self.lingerGeneration == generation else { return }
            self.lingerDeadline = nil
            self.lingerTick()
        }
    }

    /// The time of a kept card came: it fades, or it hides (not during a
    /// drag or a menu).
    public func lingerTick() {
        guard !showingDismissed else { return }
        let now = app.linger.now()
        let gone = linger.expire(now: now, blocked: lingerBlocked)
        if !gone.isEmpty { lingerHides.send(gone) }
        publishLinger(now: now)
        if !gone.isEmpty { keepSelection() }
    }

    /// The right-click menu shows, then closes.
    public func menuOpened() {
        menuShowing = true
    }

    public func menuClosed() {
        menuShowing = false
        if !lingering.isEmpty { lingerTick() }
    }

    /// Row bodies expanded with `more` (the account's).
    public var expandedBodies: Set<String> { data.expandedBodies }

    private struct SectionsKey: Equatable {
        var revision: Int
        var tab: ListTab
        var dismissed: Bool
        var search: String
        var kept: Set<String>
    }

    /// The last few: switching tabs back and forth finds them.
    private var cachedSections: [(SectionsKey, [SectionLayout])] = []

    /// Worked out once per change of the data, the tab or the search.
    public var sections: [SectionLayout] {
        let key = SectionsKey(revision: data.revision, tab: tab, dismissed: showingDismissed, search: search, kept: lingering)
        if let (_, sections) = cachedSections.first(where: { $0.0 == key }) { return sections }
        let sections: [SectionLayout]
        if let account = data.account, !showingDismissed {
            sections = Listing.sections(
                tab: tab, cards: data.cards, account: account, options: data.options, orders: data.groupOrders,
                repositories: data.repositories,
                folding: Listing.Folding(
                    collapsed: data.collapsed, expanded: data.expanded, search: search, visibility: visibility
                )
            )
        } else {
            sections = []
        }
        cachedSections.removeAll { $0.0.revision != key.revision }
        cachedSections.insert((key, sections), at: 0)
        if cachedSections.count > 4 { cachedSections.removeLast() }
        return sections
    }

    /// The Dismissed list after its search.
    public var dismissedCards: [Card] {
        Listing.search(Listing.dismissed(data.cards), data.search(.dismissed))
    }

    /// Every dismissed card, whatever the search: the count.
    public var dismissedCount: Int {
        Listing.dismissed(data.cards).count
    }

    public func unreadCount(_ tab: ListTab) -> Int {
        Listing.unreadCount(data.cards, tab: tab)
    }

    public var view: ListView {
        showingDismissed
            ? ListView(tab: nil, dismissed: dismissedCards, expandedRows: data.expandedRows, cards: data.cards)
            : ListView(tab: tab, sections: sections, expandedRows: data.expandedRows, cards: data.cards, compact: data.compact)
    }

    /// The text in place of an empty list.
    public var emptyText: String? {
        showingDismissed
            ? Listing.dismissedEmptyText(loaded: data.loaded, cards: data.cards, search: search)
            : Listing.emptyText(loaded: data.loaded, tab: tab, cards: data.cards, search: search, visibility: visibility)
    }

    public var items: [SelectionItem] {
        PopoverLogic.items(view)
    }

    public var hints: [KeyHint] {
        multiple && !showingDismissed
            ? PopoverLogic.multipleHints(tab: tab, canReorder: reorderSection != nil)
            : PopoverLogic.hints(selection: selection, view: view)
    }

    /// The rows ⇧R and Mark all as read send.
    public var rowsToRead: [String] {
        showingDismissed ? [] : Listing.rowsToRead(tab: tab, cards: data.cards, search: search, visibility: visibility)
    }

    /// The cards laid out now, in order (the ⇧-click range, ⌘A).
    public var shownCards: [String] {
        if showingDismissed { return dismissedCards.map(\.id) }
        return sections.filter(\.isLeaf).flatMap { $0.cards.map(\.id) }
    }

    /// The selected cards in the order shown.
    public var selectedInOrder: [Card] {
        if showingDismissed { return dismissedCards.filter { selectedCards.contains($0.id) } }
        return MultiRules.ordered(selectedCards, sections: sections, tabCards: tabShown)
    }

    /// Several cards are selected: keys, a drag and the menu act on all.
    public var multiple: Bool { selectedCards.isMultiple }

    /// The cards of the tab before the search, folding and collapsing:
    /// those the Filter shows.
    private var tabShown: [Card] {
        Listing.shown(data.cards, tab: tab, visibility: visibility)
    }

    func keepSelection() {
        let kept = PopoverLogic.keep(selection, in: items)
        if kept != selection { selection = kept }
        updateSelectedCards()
    }

    /// Selected cards that are no longer shown leave the selection
    /// (dismissed, moved out, folded, hidden by the Filter…), the
    /// anchor with its card (DESIGN.md, "Selection"). The selected item's
    /// card stays selected.
    private func updateSelectedCards() {
        var next = selectedCards
        next.update(shown: Set(shownCards))
        if let card = selection?.owningCard, !next.contains(card) {
            if next.isEmpty { next.only(card) } else { next.add([card]) }
        }
        if next != selectedCards { selectedCards = next }
    }

    /// A new list arrived.
    func listArrived() {
        keepSelection()
        if let pr = pendingReveal {
            pendingReveal = nil
            reveal(pr: pr, waitForList: false)
        }
    }

    /// A PR to show once the next list arrives: the notification came
    /// before the card was read.
    private var pendingReveal: String?

    // MARK: Tabs and the Dismissed list

    public func openTab(_ next: ListTab) {
        if showingDismissed { closeDismissedList() }
        guard next != tab else { return }
        tab = next
        app.store.setLastTab(next, account: data.accountId, surface: surface)
        clearSelectedCards()
        resetLinger()
        keepSelection()
    }

    public func openDismissedList() {
        guard !showingDismissed else { return }
        resetLinger()
        showingDismissed = true
        searchFocused = false
        clearSelectedCards()
        selection = nil
    }

    /// ← or Esc: back to the tab; the list's search text stays.
    public func closeDismissedList() {
        guard showingDismissed else { return }
        showingDismissed = false
        searchFocused = false
        clearSelectedCards()
        selection = nil
        resetLinger()
    }

    // MARK: Selection, keys and clicks

    /// Select an item alone: by ↑↓, a click or a right click. Its card is
    /// the only selected card; a row is read.
    public func select(_ item: SelectionItem?, readsRow: Bool = true) {
        if item != selection { selection = item }
        var cards = selectedCards
        if let card = item?.owningCard { cards.only(card) } else { cards.clear() }
        if cards != selectedCards { selectedCards = cards }
        if readsRow, case .row(let id, _)? = item { data.markRead([id]) }
    }

    /// The press that selected `item` ended without starting a drag: a row
    /// is read now (a press on a row that becomes a drag reads nothing).
    func pressEnded(on item: SelectionItem) {
        if case .row(let id, _) = item, selection == item { data.markRead([id]) }
    }

    private var press = CardPress()

    /// A press on a card's heading or row (`CardPress`). `draggable`: the
    /// card can be dragged here (Review and Mine).
    public func pressDown(_ item: SelectionItem, count: Int, draggable: Bool) {
        let card = item.owningCard
        let now = press.down(
            item, count: count, severalSelected: multiple, cardSelected: card.map { selectedCards.contains($0) } ?? false,
            draggable: draggable
        )
        if case .click(let readsRow) = now { click(.item(item), count: count, readsRow: readsRow) }
    }

    /// The press ended. After a drag (`beginDrag`) it does nothing.
    public func pressUp() {
        switch press.up() {
        case .select(let item)?: click(.item(item), count: 1)
        case .read(let item)?: pressEnded(on: item)
        case nil: break
        }
    }

    /// How a click with ⌘ or ⇧ selects (DESIGN.md, "Selection").
    public enum ClickExtent: Equatable {
        /// ⌘: the card in or out of the selection.
        case toggle
        /// ⇧: the cards shown from the anchor to this one.
        case range
    }

    /// ⌘-click or ⇧-click on a card (anywhere but its controls). The
    /// Dismissed list selects one card only: there it is a plain click.
    public func click(card: String, extent: ClickExtent) {
        clicks = ClickClassifier()
        if showingDismissed {
            select(.header(card: card))
            return
        }
        var cards = selectedCards
        switch extent {
        case .toggle:
            cards.toggle(card)
            if cards.contains(card) {
                selection = .header(card: card)
            } else if selection?.owningCard == card {
                selection = selectedInOrder(cards).last.map { .header(card: $0.id) }
            }
        case .range:
            cards.range(to: card, shown: shownCards)
            selection = .header(card: card)
        }
        if cards != selectedCards { selectedCards = cards }
    }

    private func selectedInOrder(_ cards: CardSelection) -> [Card] {
        MultiRules.ordered(cards, sections: sections, tabCards: tabShown)
    }

    /// A click on the list's empty part, or Esc: nothing selected.
    public func clearSelection() {
        if selection != nil { selection = nil }
        clearSelectedCards()
    }

    private func clearSelectedCards() {
        if !selectedCards.isEmpty || selectedCards.anchor != nil { selectedCards.clear() }
    }

    /// A click (DESIGN.md, "What a press does"): `count` is the click
    /// count. The first click selects at once, a double click on the same
    /// heading or row opens it, a control acts once per series. Returns
    /// whether a control may act.
    /// `readsRow` false: a row selected is read only at `pressEnded(on:)`,
    /// once the press is known not to start a drag.
    @discardableResult
    public func click(_ target: ClickTarget, count: Int, readsRow: Bool = true) -> Bool {
        switch clicks.classify(target, count: count) {
        case .select(let item):
            select(item, readsRow: readsRow)
        case .open(let item):
            if let action = PopoverLogic.action(for: .open, selection: item, view: view) { perform(action) }
        case .control:
            return true
        case .nothing:
            break
        }
        return false
    }

    /// The right-click menu of an item. On a selected card while several
    /// are selected: the multi-card menu, for all of them. Else the item is
    /// selected alone (and read) first.
    public func rightClick(_ item: SelectionItem) -> [MenuEntry?] {
        if !showingDismissed, multiple, let card = item.owningCard, selectedCards.contains(card) {
            // The multi-card menu (DESIGN.md, "Selection"): the selection
            // stays, a row is not read.
            let cards = selectedInOrder
            let items = MultiRules.menu(tab, cards: cards)
            let moves = items.filter { $0.operation != .dismiss }.map { MenuEntry($0.title, .multi($0.operation)) }
            var entries: [MenuEntry?] = [MenuEntry("Copy link", .copyLinks)]
            if !moves.isEmpty { entries += [nil] + moves }
            entries += [nil, MenuEntry("Dismiss", .multi(.dismiss)), nil, MenuEntry("Mark all as read", .markAllRead)]
            return entries
        }
        select(item)
        if data.mutes == nil { data.loadMutes() }
        return PopoverLogic.menu(for: item, view: view, login: data.account?.login ?? "", mutes: data.mutes)
    }

    /// The confirmation sheet's `Dismiss` (⏎) or `Cancel` (Esc): only the
    /// card whose × was pressed is dismissed, whatever is selected.
    /// `Don't ask again` counts with `Dismiss` only.
    public func answerDismiss(_ confirmed: Bool) {
        guard let card = confirmingDismiss else { return }
        confirmingDismiss = nil
        guard confirmed else { return }
        if skipsNextConfirmations { app.stopConfirmingDismiss() }
        data.dismiss(card)
    }

    /// A key while the surface has the focus and the search field does not.
    public func press(_ key: Key) {
        // The confirmation sheet shows: the list takes no input.
        guard confirmingDismiss == nil else { return }
        switch key {
        case .up, .down:
            // With several cards: from the edge of the selection, to the
            // item before or after it, alone.
            if multiple, let edge = selectedCards.edge {
                select(PopoverLogic.move(.header(card: edge), up: key == .up, in: items))
            } else {
                select(PopoverLogic.move(selection, up: key == .up, in: items))
            }
        case .find:
            searchFocused = true
        case .copy:
            if multiple {
                perform(.copyLinks)
            } else if let link = PopoverLogic.link(for: selection, view: view) {
                app.copy(link)
            }
        case .open where multiple:
            // Several cards: ⏎ does nothing.
            break
        case .tab(let next):
            openTab(next)
        case .back:
            closeDismissedList()
        case .extend(let up):
            extend(up: up)
        case .selectAll:
            guard !showingDismissed else { return }
            var cards = selectedCards
            cards.all(shownCards)
            if cards != selectedCards { selectedCards = cards }
            if selection?.owningCard.map({ cards.contains($0) }) != true {
                selection = shownCards.first.map { .header(card: $0) }
            }
        case .clearSelection:
            clearSelection()
        case .delete where !showingDismissed && multiple:
            multi(.dismiss)
        case .moveTo(let section) where !showingDismissed && multiple:
            guard tab == .review, section != .done else { return }
            multi(.move(.review(section)))
        case .reorder(let up) where !showingDismissed && multiple:
            reorderSelected(up: up)
        case .open, .markAllRead, .delete, .reorder, .moveTo:
            if let action = PopoverLogic.action(for: key, selection: selection, view: view) {
                perform(action)
            }
        }
    }

    /// Esc or ↓ in the search field (DESIGN.md, "Search field"): Esc clears
    /// the text, if any, and both go back to the list. The popover stays.
    public func leaveSearch(clearing: Bool) {
        if clearing { setSearch("") }
        searchFocused = false
    }

    /// Typed in the search field, or cleared by its clear button: the
    /// text of what shows, on both surfaces.
    public func setSearch(_ text: String) {
        data.setSearch(text, searchScope)
    }

    public func perform(_ action: PopoverAction) {
        switch action {
        case .multi(let operation):
            multi(operation)
        case .copyLinks:
            // One link a line, in the order shown.
            app.copy(selectedInOrder.map(\.url).joined(separator: "\n"))
        case .open(let url, let read):
            if let read { data.markRead([read]) }
            app.open(url)
        case .copyLink(let text):
            app.copy(text)
        case .place(let move):
            data.place(move)
        case .dismiss(let card):
            data.dismiss(card)
        case .confirmDismiss(let card):
            if app.confirmDismiss {
                skipsNextConfirmations = false
                confirmingDismiss = card
            } else {
                data.dismiss(card)
            }
        case .restore(let card):
            data.restore(card)
        case .mute(let kind, let name):
            data.mute(kind, name, on: true)
        case .unmute(let kind, let name):
            data.mute(kind, name, on: false)
        case .toggleSection(let key):
            let section = sections.first { $0.key == key }
            data.setCollapsed(key, !(section?.collapsed ?? false))
        case .toggleMore(let key):
            guard let section = sections.first(where: { $0.key == key }) else { return }
            data.setExpanded(key, section.more > 0)
        case .expandRows(let card):
            animatedCard = card
            // "+ N more" goes: its card's heading takes the selection.
            if selection == .moreRows(card: card) { selection = .header(card: card) }
            data.setRowsExpanded(card, true)
        case .collapseRows(let card):
            animatedCard = card
            let previous = selection
            data.setRowsExpanded(card, false)
            // An item that went with the rows: "+ N more" takes its place.
            if let previous, previous.owningCard == card, !items.contains(previous) {
                selection = .moreRows(card: card)
            }
        case .toggleBody(let row):
            animatedCard = data.cards.first { $0.rows.contains { $0.id == row } }?.id
            data.setBodyExpanded(row, !data.expandedBodies.contains(row))
        case .showInTab(let card):
            if let pr = data.cards.first(where: { $0.id == card })?.pr { reveal(pr: pr) }
        case .markAllRead:
            data.markRead(rowsToRead)
        }
    }

    /// Compact: the account's (DESIGN.md, "Compact"). Not in the Dismissed
    /// list.
    public var compact: Bool { data.compact }

    public func toggleCompact() {
        data.setCompact(!data.compact)
    }

    /// Compact turned on or off: an item of a card that no longer shows
    /// (a row, `+ N more`…) gives the selection to the card's heading.
    func compactChanged() {
        if let item = selection, let card = item.owningCard, !items.contains(item), items.contains(.header(card: card)) {
            selection = .header(card: card)
        }
        keepSelection()
    }

    /// The account's expanded rows changed (here or on the other surface).
    func rowsChanged() {
        if expandedRows != data.expandedRows { expandedRows = data.expandedRows }
        keepSelection()
    }

    // MARK: Several cards

    /// ⇧↑ or ⇧↓: the next card above or below the selected item's card
    /// joins the range from the anchor (DESIGN.md, "Selection").
    private func extend(up: Bool) {
        // The Dismissed list selects one card: ⇧↑↓ is ↑↓ there.
        guard !showingDismissed else { return press(up ? .up : .down) }
        let shown = shownCards
        guard !shown.isEmpty else { return }
        let current = selectedCards.edge ?? selection?.owningCard
        let next: String
        if let current, let index = shown.firstIndex(of: current) {
            next = shown[up ? max(0, index - 1) : min(shown.count - 1, index + 1)]
        } else {
            next = up ? shown[shown.count - 1] : shown[0]
        }
        var cards = selectedCards
        if cards.anchor == nil, let current { cards.only(current) }
        cards.range(to: next, shown: shown)
        selection = .header(card: next)
        if cards != selectedCards { selectedCards = cards }
    }

    /// An operation on every selected card of the tab (⌫, D / T / W or an
    /// item of the multi-card menu). The cards stay selected; those it
    /// cannot take stay as they are.
    public func multi(_ operation: MultiOperation) {
        apply(MultiRules.plan(operation, cards: selectedInOrder))
    }

    /// Whether ⌥↑↓ moves the selected cards: those not in Done are all in
    /// one section of Review or Mine (DESIGN.md, "Selection").
    var reorderSection: SectionLayout? {
        guard tab != .all, !showingDismissed else { return nil }
        let keys = Set(selectedInOrder.compactMap { view.card($0.id)?.1 }.filter { !$0.isDone }.map(\.key))
        guard keys.count == 1, let key = keys.first else { return nil }
        return sections.first { $0.key == key }
    }

    /// ⌥↑ or ⌥↓ with several cards selected: they move together, when
    /// those not in Done are all in one section.
    private func reorderSelected(up: Bool) {
        guard let section = reorderSection else { return }
        let moves = MultiRules.reorder(selectedInOrder, up: up, in: section, all: data.cards)
        if !moves.isEmpty { data.placeAll(moves, failed: { _ in }) }
    }

    private func apply(_ plan: MultiPlan) {
        // A card the daemon refused to dismiss comes back selected.
        let reselect: ([String]) -> Void = { [weak self] failed in
            guard let self else { return }
            var cards = self.selectedCards
            cards.add(failed)
            if cards != self.selectedCards { self.selectedCards = cards }
        }
        if !plan.dismiss.isEmpty { data.dismissAll(plan.dismiss, failed: reselect) }
        if !plan.moves.isEmpty { data.placeAll(plan.moves, failed: reselect) }
    }

    /// Show the PR's card: its tab (All without a placement), its search
    /// text cleared,
    /// its section and group unfolded, the card selected. A card no longer
    /// shown (dismissed, gone) only opens the tab (DESIGN.md, "macOS
    /// notifications").
    public func reveal(pr: String, waitForList: Bool = true) {
        closeDismissedList()
        guard let card = data.cards.first(where: { $0.pr == pr }) else {
            // Not read yet (the surface just opened): the list on its way
            // decides.
            if waitForList { pendingReveal = pr }
            return
        }
        openTab(card.tab)
        data.setSearch("", .tab(tab))
        // The tab's Filter hides the card: only what hides it changes
        // (DESIGN.md, "Filter", "Opening a tab to select a card").
        if !card.isDismissed, !visibility.shows(card) {
            data.setFilter(filter.revealing(card), tab: tab)
        }
        guard !card.isDismissed else {
            keepSelection()
            return
        }
        for _ in 0..<3 {
            let sections = self.sections
            if let leaf = sections.first(where: { $0.isLeaf && $0.matching.contains { $0.id == card.id } }) {
                if leaf.collapsed {
                    data.setCollapsed(leaf.key, false)
                    continue
                }
                if !leaf.cards.contains(where: { $0.id == card.id }) {
                    data.setExpanded(leaf.key, true)
                    continue
                }
                // The revealed card alone, in this tab or another (the
                // other selected cards go with it).
                select(.header(card: card.id))
                return
            }
            guard let parent = sections.first(where: { !$0.isLeaf && $0.matching.contains { $0.id == card.id } }) else { return }
            data.setCollapsed(parent.key, false)
        }
    }

    // MARK: Drag and drop

    /// Whether a drag can start on the card: Review and Mine only.
    public func canDrag(_ card: String) -> Bool {
        guard !showingDismissed, tab != .all, let (card, section) = view.card(card), let section else { return false }
        return section.accepts && card.canDrag
    }

    /// What a press on a card that moved past the drag threshold does (once
    /// per press): in Review and Mine the card is dragged; in All, which is
    /// sorted by itself, nothing moves and a hint says where to reorder; in
    /// the Dismissed list, nothing.
    public enum DragStart: Equatable {
        case drag
        case hint(String)
        case nothing
    }

    public static let allIsSortedHint = "All is sorted automatically. Reorder in Review or Mine."

    public func dragStart(card: String) -> DragStart {
        guard !showingDismissed, view.card(card) != nil else { return .nothing }
        if canDrag(card) { return .drag }
        return tab == .all ? .hint(Self.allIsSortedHint) : .nothing
    }

    /// A drag started on a card. A selected card takes the other selected
    /// ones along; an unselected one goes alone.
    public func beginDrag(_ card: String) {
        press.dragStarted()
        dragging = card
        draggingCount = multiple && selectedCards.contains(card) ? selectedInOrder.count : 1
        dropTarget = nil
    }

    /// The pointer of a card drag moved over `zone`: where it would land,
    /// nil when it cannot (the line goes and the drop is refused).
    @discardableResult
    public func dragOver(_ zone: DropZone?) -> DropTarget? {
        guard dragging != nil else { return nil }
        let target = zone.flatMap { CardDrop.target($0, sections: sections) }
        if dropTarget != target { dropTarget = target }
        return target
    }

    /// The pointer left `zone`.
    public func dragExited(_ zone: DropZone) {
        if dropTarget != nil, dropTarget == CardDrop.target(zone, sections: sections) { dropTarget = nil }
    }

    /// The card dropped over `zone`. True when it was taken (even where it
    /// changes nothing), false when refused.
    @discardableResult
    public func drop(_ zone: DropZone?) -> Bool {
        defer {
            dragging = nil
            draggingCount = 1
            dropTarget = nil
            if !lingering.isEmpty { lingerTick() }
        }
        guard let id = dragging, let card = data.cards.first(where: { $0.id == id }), let zone,
              let target = CardDrop.target(zone, sections: sections) else { return false }
        // Dropped on "+ N more PRs": after the last card shown, and the
        // section opens to show where they went. Only a section that has
        // the line (cards folded): a release in the gap under a section's
        // last card comes here too. Not Done's: Done takes cards by its own
        // order.
        if case .more(let key) = zone, let section = sections.first(where: { $0.key == key }), !section.isDone, section.more > 0 {
            data.setExpanded(key, true)
        }
        if multiple && selectedCards.contains(id) {
            let cards = selectedInOrder
            let moves = MultiRules.drop(cards, at: target, sections: sections, all: data.cards)
            if !moves.isEmpty { data.placeAll(moves, failed: { _ in }) }
            // The moved cards are the selection.
            var selected = selectedCards
            selected.set(cards.map(\.id))
            if selected != selectedCards { selectedCards = selected }
            selection = .header(card: id)
            return true
        }
        if let move = CardDrop.move(card, to: target, cards: data.cards) { data.place(move) }
        // The dropped card is the selection.
        selection = .header(card: id)
        var selected = selectedCards
        selected.only(id)
        if selected != selectedCards { selectedCards = selected }
        return true
    }

    /// The drag ended without a drop here (released elsewhere, or Esc).
    public func endDrag() {
        dragging = nil
        draggingCount = 1
        dropTarget = nil
        if !lingering.isEmpty { lingerTick() }
    }

    // MARK: Open and closed

    /// The surface opened: the search field does not take the keyboard
    /// (DESIGN.md, "Search field"); ⌘F moves there.
    func opened() {
        searchFocused = false
    }

    /// Counts the times the surface closed (the popover, or the window):
    /// the list's scroll positions of each tab are kept while it stays the
    /// same (DESIGN.md, "Scroll position").
    public private(set) var openings = 0

    /// The popover closed (`ends`), or the window lost the focus. The
    /// popover drops its selected cards and the Dismissed list. The search
    /// texts stay (DESIGN.md, "Search field"); the expanded rows stay until
    /// `Show less` (DESIGN.md, "Rows in a card").
    func closed(ends: Bool) {
        if ends { end() }
        keepSelection()
    }

    /// The window closed: its selected cards and the Dismissed list go;
    /// the search texts stay.
    func windowClosed() {
        end()
        keepSelection()
    }

    private func end() {
        openings += 1
        showingDismissed = false
        searchFocused = false
        confirmingDismiss = nil
        clearSelectedCards()
        resetLinger()
    }
}
