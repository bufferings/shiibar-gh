// The app's state, fed by the `subscribe` connection, and what the popover,
// the window and Settings do through the daemon. Views observe it; nothing
// here touches AppKit, so `swift test` covers it with a fake daemon.

import Foundation

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var scopes: [Scope] = []
    @Published public private(set) var dbUnreadable = false
    @Published public private(set) var connected = false
    /// The last request that failed, for the surface that made it.
    @Published public var lastError: String?

    public let api: DaemonAPI
    public let store: UIStateStore
    private let opener: URLOpening
    private let notifier: NotificationPresenting
    private var surfaces = OpenSurfaces()
    private var viewModels: [String: ScopeViewModel] = [:]
    /// The scopes some surface shows, open or not: their lists follow
    /// `scope_changed`.
    private var displayed: [String: Set<Surface>] = [:]
    private let clock: () -> Int64

    /// Asks the app to show a scope's popover (a summary notification).
    public var onOpenPopover: ((String) -> Void)?
    /// Asks the app to show Settings on the Scopes tab.
    public var onOpenSettings: (() -> Void)?
    /// The scope list changed: Settings refetches `settings_status`.
    public var onScopesChanged: (() -> Void)?

    public init(
        api: DaemonAPI, store: UIStateStore, opener: URLOpening, notifier: NotificationPresenting,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.api = api
        self.store = store
        self.opener = opener
        self.notifier = notifier
        self.clock = clock
    }

    public var now: Int64 { clock() }

    /// The scopes with a menu bar icon: disabled scopes have none.
    public var menuBarScopes: [Scope] {
        scopes.filter(\.enabled)
    }

    public func scope(_ id: String) -> Scope? {
        scopes.first { $0.id == id }
    }

    public func viewModel(_ scope: String) -> ScopeViewModel {
        if let model = viewModels[scope] { return model }
        let model = ScopeViewModel(scope: scope, app: self)
        viewModels[scope] = model
        return model
    }

    // MARK: - Subscribe

    public func handle(_ event: SubscribeEvent) {
        switch event {
        case .snapshot(let scopes, let unreadable):
            // A removed scope's popover and window close with it; no
            // `popover_closed` goes out for a scope the daemon no longer has.
            let ids = Set(scopes.map(\.id))
            for scope in surfaces.openScopes where !ids.contains(scope) {
                surfaces.forget(scope)
            }
            self.scopes = scopes
            dbUnreadable = unreadable
            onScopesChanged?()
            reloadDisplayed()
        case .scopeChanged(let scope):
            if let index = scopes.firstIndex(where: { $0.id == scope.id }) {
                scopes[index] = scope
            } else {
                scopes.append(scope)
            }
            onScopesChanged?()
            if displayed[scope.id] != nil {
                viewModels[scope.id]?.reload()
            }
        case .notify(let notification):
            notifier.present(notification)
        case .unknown:
            break
        }
    }

    /// The connection came back with a snapshot, or went away. On return,
    /// `popover_opened` goes again for every open scope (DESIGN.md, "Wire
    /// format").
    public func connectionChanged(_ isConnected: Bool) {
        connected = isConnected
        guard isConnected else { return }
        for scope in surfaces.openScopes {
            send { try await $0.popoverOpened(scope) }
        }
    }

    // MARK: - Surfaces

    /// A surface shows the scope's list, open or not (the window keeps
    /// showing while another app has the focus).
    public func surfaceDisplayed(_ surface: Surface, scope: String, _ shown: Bool) {
        if !shown { viewModels[scope]?.clearShown(surface) }
        if shown {
            let first = displayed[scope] == nil
            displayed[scope, default: []].insert(surface)
            if first { viewModel(scope).reload() }
        } else if var set = displayed[scope] {
            set.remove(surface)
            displayed[scope] = set.isEmpty ? nil : set
        }
    }

    /// The popover opened, or the window got the focus. `seen` goes only
    /// for rows laid out in this surface: a new popover reports its rows
    /// once laid out; the window already shows its rows, so the ones it
    /// reported last count right away.
    public func surfaceOpened(_ surface: Surface, scope: String) {
        if surfaces.isOpen(surface, scope: scope) { return }
        if surfaces.opened(surface, scope: scope) {
            send { try await $0.popoverOpened(scope) }
        }
        let model = viewModel(scope)
        model.reload()
        if surface == .popover {
            model.clearShown(.popover)
        } else {
            model.rowsShown(model.shown(.window), surface: .window)
        }
    }

    /// The popover closed, or the window closed or lost the focus.
    public func surfaceClosed(_ surface: Surface, scope: String) {
        if surface == .popover { viewModels[scope]?.clearShown(.popover) }
        if surfaces.closed(surface, scope: scope) {
            viewModels[scope]?.seen.reset()
            send { try await $0.popoverClosed(scope) }
        }
    }

    public func isOpen(_ scope: String) -> Bool {
        surfaces.isOpen(scope)
    }

    public func isOpen(_ surface: Surface, scope: String) -> Bool {
        surfaces.isOpen(surface, scope: scope)
    }

    // MARK: - Actions

    public func perform(_ action: PopoverAction, scope: String) {
        switch action {
        case .open(let url):
            if let url = URL(string: url) { opener.open(url) }
        case .done(let row):
            change(scope) { try await $0.done(row) }
        case .undone(let row):
            change(scope) { try await $0.undone(row) }
        case .snooze(let pr):
            change(scope) { try await $0.snooze(pr) }
        case .unsnooze(let pr):
            change(scope) { try await $0.unsnooze(pr) }
        }
    }

    public func refresh(_ scope: String?) {
        send { _ = try await $0.refresh(scope) }
    }

    public func reset() {
        send { try await $0.reset() }
    }

    public func openSettings() {
        onOpenSettings?()
    }

    public func open(_ url: String) {
        if let url = URL(string: url) { opener.open(url) }
    }

    /// A clicked notification: an individual one opens its place on the web
    /// without the popover and without touching the dots; a summary opens
    /// the scope's popover (DESIGN.md, "macOS notifications").
    public func notificationClicked(type: NotificationType?, scope: String, url: String?) {
        if type == .summary {
            onOpenPopover?(scope)
        } else if let url, let parsed = URL(string: url) {
            opener.open(parsed)
        }
    }

    func seen(_ rows: [String]) {
        guard !rows.isEmpty else { return }
        send { try await $0.seen(rows) }
    }

    private func change(_ scope: String, _ request: @escaping (DaemonAPI) async throws -> Void) {
        let api = self.api
        Task {
            do {
                try await request(api)
                lastError = nil
            } catch {
                lastError = "\(error)"
            }
            viewModels[scope]?.reload()
        }
    }

    private func send(_ request: @escaping (DaemonAPI) async throws -> Void) {
        let api = self.api
        Task {
            do {
                try await request(api)
            } catch {
                lastError = "\(error)"
            }
        }
    }

    private func reloadDisplayed() {
        for scope in displayed.keys {
            viewModels[scope]?.reload()
        }
    }
}

/// One scope's list for its popover and window.
@MainActor
public final class ScopeViewModel: ObservableObject {
    public let scope: String
    private unowned let app: AppModel
    @Published public private(set) var cards: [Card] = []
    @Published public private(set) var activity: [Row] = []
    @Published public private(set) var loaded = false
    @Published public var tab: PopoverTab = .prs {
        didSet { selection = PopoverLogic.keep(selection, in: items) }
    }
    @Published public var chips: Chips {
        didSet {
            app.store.chips = chips
            reload()
        }
    }
    @Published public var selection: SelectionItem?
    var seen = SeenTracker()
    /// Per surface, the rows its view last reported inside the visible area.
    private var shownBySurface: [Surface: Set<String>] = [:]
    private var reloads = 0

    init(scope: String, app: AppModel) {
        self.scope = scope
        self.app = app
        self.chips = app.store.chips
    }

    public var items: [SelectionItem] {
        PopoverLogic.items(tab: tab, cards: cards, activity: activity)
    }

    public func reload() {
        reloads += 1
        let current = reloads
        let filter = chips.filter(scope: scope)
        let api = app.api
        Task {
            do {
                async let cards = api.list(filter)
                async let rows = api.activity(filter)
                let (newCards, newRows) = try await (cards, rows)
                guard current == reloads else { return }
                self.cards = newCards
                self.activity = newRows
                self.loaded = true
                self.selection = PopoverLogic.keep(selection, in: items)
            } catch {
                guard current == reloads else { return }
                app.lastError = "\(error)"
            }
        }
    }

    /// A key while the popover or the window has the focus.
    public func press(_ key: Key) {
        switch key {
        case .up, .down:
            selection = PopoverLogic.move(selection, up: key == .up, in: items)
        case .open, .done, .snooze:
            if let action = PopoverLogic.action(for: key, selection: selection, cards: cards, activity: activity) {
                app.perform(action, scope: scope)
            }
        }
    }

    public func perform(_ action: PopoverAction) {
        app.perform(action, scope: scope)
    }

    /// The rows a surface last reported as shown.
    public func shown(_ surface: Surface) -> Set<String> {
        shownBySurface[surface] ?? []
    }

    func clearShown(_ surface: Surface) {
        shownBySurface[surface] = nil
    }

    /// The rows now inside the visible part of one surface's list. Unread
    /// ones not sent in this open period go out as `seen`, only while that
    /// surface is open. Rows the chips hide are not laid out, so they never
    /// arrive here.
    public func rowsShown(_ shown: Set<String>, surface: Surface) {
        shownBySurface[surface] = shown
        guard app.isOpen(surface, scope: scope) else { return }
        let rows = tab == .prs ? cards.flatMap(\.rows) : activity
        let unread = Set(rows.filter(\.unread).map(\.id))
        app.seen(seen.newlySeen(shown: shown, unread: unread))
    }
}
