// The app's state, fed by the `subscribe` connection, and what the popovers,
// the windows and Settings do through the daemon. Views observe it; nothing
// here touches AppKit, so `swift test` covers it with a fake daemon.
//
// Accounts are keyed by their id (the GitHub user id, numeric, as a
// string); requests carry the login the account has now (DESIGN.md, "Wire format").

import Foundation

/// The accounts whose saved token the daemon is testing after a Save
/// (DESIGN.md, "Add account… and Edit… sheets": the wire has no progress
/// field, so the app counts from the Save answer to the `account_changed`
/// that brings a new `last_test`). A check that never ends stops counting
/// after `limit` seconds.
public struct TokenChecks: Equatable {
    struct Pending: Equatable {
        var before: Int64?
        var since: Int64
    }

    private var pending: [String: Pending] = [:]
    public static let limit: Int64 = 300

    public init() {}

    static func resolved(_ account: Account, before: Int64?) -> Bool {
        guard let at = account.token.lastTest?.at else { return false }
        return at != before
    }

    /// The Save of `account` was answered. `before` is the `last_test.at`
    /// the account had when Save was pressed (nil for a new account).
    public mutating func started(_ account: Account, before: Int64?, now: Int64) {
        if Self.resolved(account, before: before) { return }
        pending[account.id] = Pending(before: before, since: now)
    }

    /// A new value of the account arrived.
    public mutating func update(_ account: Account) {
        guard let entry = pending[account.id], Self.resolved(account, before: entry.before) else { return }
        pending[account.id] = nil
    }

    public mutating func forget(_ id: String) {
        pending[id] = nil
    }

    public func isChecking(_ id: String, now: Int64) -> Bool {
        guard let entry = pending[id] else { return false }
        return now - entry.since < Self.limit
    }
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var accounts: [Account] = []
    @Published public private(set) var keychain: KeychainState = .ok
    @Published public private(set) var dbUnreadable = false
    @Published public private(set) var connected = false
    @Published public private(set) var checks = TokenChecks()
    /// The last request that failed, for the surface that made it.
    @Published public var lastError: String?

    public let api: DaemonAPI
    public let store: UIStateStore
    private let opener: URLOpening
    private let notifier: NotificationPresenting
    private var surfaces = OpenSurfaces()
    private var viewModels: [String: AccountViewModel] = [:]
    /// The accounts some surface shows, open or not: their lists follow
    /// `account_changed`.
    private var displayed: [String: Set<Surface>] = [:]
    private var prompt = KeychainPrompt()
    private let clock: () -> Int64

    /// Asks the app to show an account's popover (a summary notification).
    public var onOpenPopover: ((String) -> Void)?
    /// Asks the app to show Settings.
    public var onOpenSettings: ((SettingsDestination) -> Void)?
    /// Asks the app to show a Keychain dialog.
    public var onKeychainDialog: ((KeychainDialog) -> Void)?
    private var configObservers: [(String, ConfigValue) -> Void] = []
    private var accountObservers: [(Account) -> Void] = []

    /// Called for every `config_changed`.
    public func observeConfig(_ observer: @escaping (String, ConfigValue) -> Void) {
        configObservers.append(observer)
    }

    /// Called for every new value of an account.
    public func observeAccounts(_ observer: @escaping (Account) -> Void) {
        accountObservers.append(observer)
    }

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

    public func account(_ id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    public func viewModel(_ account: String) -> AccountViewModel {
        if let model = viewModels[account] { return model }
        let model = AccountViewModel(account: account, app: self)
        viewModels[account] = model
        return model
    }

    /// Whether a view model is kept for the account (tests).
    func hasViewModel(_ account: String) -> Bool { viewModels[account] != nil }

    public func isChecking(_ account: String) -> Bool {
        checks.isChecking(account, now: now)
    }

    // MARK: - Subscribe

    public func handle(_ event: SubscribeEvent) {
        switch event {
        case .snapshot(let accounts, let keychain, let unreadable):
            let ids = Set(accounts.map(\.id))
            for account in surfaces.openAccounts where !ids.contains(account) {
                surfaces.forget(account)
            }
            // Accounts gone from the snapshot leave no lists behind.
            for id in Set(viewModels.keys).union(displayed.keys) where !ids.contains(id) {
                viewModels[id] = nil
                displayed[id] = nil
                checks.forget(id)
            }
            self.accounts = accounts
            dbUnreadable = unreadable
            for account in accounts {
                checks.update(account)
                accountObservers.forEach { $0(account) }
            }
            keychainChanged(keychain.value ?? .ok)
            reloadDisplayed()
        case .accountChanged(let account):
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index] = account
            } else {
                accounts.append(account)
            }
            checks.update(account)
            accountObservers.forEach { $0(account) }
            if displayed[account.id] != nil {
                viewModels[account.id]?.reload()
            }
        case .accountRemoved(let id):
            accounts.removeAll { $0.id == id }
            surfaces.forget(id)
            checks.forget(id)
            displayed[id] = nil
            viewModels[id] = nil
        case .keychainChanged(let state):
            keychainChanged(state.value ?? .ok)
        case .notify(let notification):
            notifier.present(notification)
        case .configChanged(let key, let value):
            for observer in configObservers { observer(key, value) }
        case .unknown:
            break
        }
    }

    private func keychainChanged(_ state: KeychainState) {
        keychain = state
        if let dialog = prompt.update(state) {
            onKeychainDialog?(dialog)
        }
    }

    /// The connection came back with a snapshot, or went away. On return,
    /// `popover_opened` goes again for every open account (DESIGN.md, "Wire
    /// format").
    public func connectionChanged(_ isConnected: Bool) {
        connected = isConnected
        guard isConnected else { return }
        for id in surfaces.openAccounts {
            guard let login = account(id)?.login else { continue }
            send { try await $0.popoverOpened(login) }
        }
    }

    // MARK: - Surfaces

    /// A surface shows the account's list, open or not (the window keeps
    /// showing while another app has the focus).
    public func surfaceDisplayed(_ surface: Surface, account: String, _ shown: Bool) {
        if !shown { viewModels[account]?.clearShown(surface) }
        if shown {
            let first = displayed[account] == nil
            displayed[account, default: []].insert(surface)
            if first { viewModel(account).reload() }
        } else if var set = displayed[account] {
            set.remove(surface)
            displayed[account] = set.isEmpty ? nil : set
        }
    }

    /// The popover opened, or the window got the focus.
    public func surfaceOpened(_ surface: Surface, account: String) {
        if surfaces.isOpen(surface, account: account) { return }
        if surfaces.opened(surface, account: account), let login = self.account(account)?.login {
            send { try await $0.popoverOpened(login) }
        }
        let model = viewModel(account)
        model.reload()
        if surface == .popover {
            model.clearShown(.popover)
        } else {
            model.rowsShown(model.shown(.window), surface: .window)
        }
    }

    /// The popover closed, or the window closed or lost the focus.
    public func surfaceClosed(_ surface: Surface, account: String) {
        if surface == .popover { viewModels[account]?.clearShown(.popover) }
        if surfaces.closed(surface, account: account) {
            viewModels[account]?.closedAll()
            if let login = self.account(account)?.login {
                send { try await $0.popoverClosed(login) }
            }
        }
    }

    public func isOpen(_ account: String) -> Bool {
        surfaces.isOpen(account)
    }

    public func isOpen(_ surface: Surface, account: String) -> Bool {
        surfaces.isOpen(surface, account: account)
    }

    // MARK: - Actions

    /// The daemon side of a popover action. Section actions stay in the
    /// view model.
    func perform(_ action: PopoverAction, account id: String) {
        let login = account(id)?.login
        switch action {
        case .open(let url):
            open(url)
        case .done(let row, let on):
            change(id) { try await $0.done(row, on: on) }
        case .todo(let row, let on):
            change(id) { try await $0.todo(row, on: on) }
        case .snooze(let pr):
            guard let login else { return }
            change(id) { try await $0.snooze(account: login, pr: pr) }
        case .unsnooze(let pr):
            guard let login else { return }
            change(id) { try await $0.unsnooze(account: login, pr: pr) }
        case .toggleSection, .expand:
            break
        }
    }

    public func refresh(_ account: String?) {
        let login = account.flatMap { self.account($0)?.login }
        if account != nil && login == nil { return }
        send { _ = try await $0.refresh(login) }
    }

    public func reset() {
        send { try await $0.reset() }
    }

    public func openSettings(_ destination: SettingsDestination) {
        onOpenSettings?(destination)
    }

    public func open(_ url: String) {
        if let url = URL(string: url) { opener.open(url) }
    }

    /// A banner button. Settings… goes to the account, Authorize… to its
    /// URL, Retry… and Reset tokens… show the Keychain dialog.
    public func bannerButton(_ button: BannerButton, account: String?) {
        switch button {
        case .settings:
            openSettings(account.map(SettingsDestination.account) ?? .accounts)
        case .authorize(let url):
            open(url)
        case .retry:
            onKeychainDialog?(.unavailable)
        case .resetTokens:
            onKeychainDialog?(.unreadable)
        }
    }

    /// The default button of a Keychain dialog: Retry sends `refresh`, Reset
    /// tokens `token_reset` (DESIGN.md, "When the Keychain cannot be
    /// read"). A Retry whose answer still has a Keychain warning shows the
    /// dialog again; so does a Reset the daemon refused.
    public func keychainAction(_ dialog: KeychainDialog) {
        let api = self.api
        Task {
            switch dialog.state {
            case .unavailable:
                do {
                    let warnings = try await api.refresh(nil)
                    let state = KeychainDialog.state(in: warnings)
                    if state != .ok, let again = prompt.again(state) {
                        keychain = state
                        onKeychainDialog?(again)
                    }
                } catch {
                    lastError = "\(error)"
                    if let again = prompt.again(keychain) { onKeychainDialog?(again) }
                }
            case .unreadable:
                do {
                    try await api.tokenReset()
                } catch {
                    lastError = "\(error)"
                    if let again = prompt.again(keychain) { onKeychainDialog?(again) }
                }
            case .ok:
                break
            }
        }
    }

    /// A clicked notification: an individual one opens its place on the web
    /// without the popover and without touching the dots; a summary opens
    /// the account's popover (DESIGN.md, "macOS notifications").
    public func notificationClicked(type: NotificationType?, account: String, url: String?) {
        if type == .summary {
            onOpenPopover?(account)
        } else if let url, let parsed = URL(string: url) {
            opener.open(parsed)
        }
    }

    /// A Save was answered: Token shows Checking… until the new test.
    public func tokenSaved(_ account: Account, before: Int64?) {
        let current = self.account(account.id) ?? account
        checks.started(current, before: before, now: now)
    }

    func seen(_ rows: [String]) {
        guard !rows.isEmpty else { return }
        send { try await $0.seen(rows) }
    }

    private func change(_ account: String, _ request: @escaping (DaemonAPI) async throws -> Void) {
        let api = self.api
        Task {
            do {
                try await request(api)
                lastError = nil
            } catch {
                lastError = "\(error)"
            }
            viewModels[account]?.reload()
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
        for account in displayed.keys {
            viewModels[account]?.reload()
        }
    }
}

/// One account's lists for its popover and window.
@MainActor
public final class AccountViewModel: ObservableObject {
    public let accountId: String
    private unowned let app: AppModel
    @Published public private(set) var cards: [Card] = []
    @Published public private(set) var snoozed: [Card] = []
    /// The snoozed PRs without the filters: the Snoozed header.
    @Published public private(set) var allSnoozed: [Card] = []
    @Published public private(set) var activity: [Row] = []
    @Published public private(set) var loaded = false
    @Published public var tab: PopoverTab = .prs {
        didSet { selection = PopoverLogic.keep(selection, in: items) }
    }
    @Published public var filter: FilterState {
        didSet {
            guard filter != oldValue else { return }
            app.store.setFilter(filter, account: accountId)
            reload()
        }
    }
    @Published public private(set) var collapsed: [String: Bool]
    /// Sections whose "+ N more PRs" was opened. Not kept (DESIGN.md,
    /// "PRs tab sections").
    @Published public private(set) var expanded: Set<String> = []
    @Published public private(set) var activityOwners: Set<String>
    @Published public var selection: SelectionItem?
    var seen = SeenTracker()
    private var shownBySurface: [Surface: Set<String>] = [:]
    private var reloads = 0

    init(account: String, app: AppModel) {
        accountId = account
        self.app = app
        filter = app.store.filter(account: account)
        collapsed = app.store.collapsed(account: account)
        activityOwners = app.store.activityOwners(account: account)
    }

    public var account: Account? { app.account(accountId) }

    public var sections: [SectionLayout] {
        guard let account else { return [] }
        return PopoverLogic.sections(
            account: account, cards: cards, snoozed: snoozed, allSnoozed: allSnoozed,
            collapsed: collapsed, expanded: expanded, showsEmpty: emptyText != nil
        )
    }

    /// "Nothing needs you" or "Nothing matches" in place of the owner
    /// sections.
    public var emptyText: String? {
        PopoverLogic.emptyText(loaded: loaded, cards: cards, filter: filter)
    }

    public var items: [SelectionItem] {
        PopoverLogic.items(tab: tab, sections: sections, activity: activity)
    }

    public var hints: [KeyHint] {
        PopoverLogic.hints(selection: selection, sections: sections, activity: activity)
    }

    /// The Activity owner buttons that are on, without owners that went away.
    public func isOwnerOn(_ owner: String) -> Bool { activityOwners.contains(owner) }

    public func toggleOwner(_ owner: String) {
        if activityOwners.contains(owner) { activityOwners.remove(owner) } else { activityOwners.insert(owner) }
        app.store.setActivityOwners(activityOwners, account: accountId)
        reload()
    }

    public func reload() {
        guard let account else { return }
        reloads += 1
        let current = reloads
        let filter = self.filter
        let owners = ActivityOwners.arguments(activityOwners, account: account)
        let login = account.login
        let api = app.api
        Task {
            do {
                async let cards = api.list(ListQuery(account: login, todo: filter.todo, filter: filter.segment))
                async let snoozed = api.list(ListQuery(account: login, todo: filter.todo, filter: filter.segment, snoozed: true))
                async let allSnoozed = api.list(ListQuery(account: login, snoozed: true))
                async let rows = api.activity(ActivityQuery(account: login, owners: owners, todo: filter.todo, filter: filter.segment))
                let (newCards, newSnoozed, newAllSnoozed, newRows) = try await (cards, snoozed, allSnoozed, rows)
                guard current == reloads else { return }
                self.cards = newCards
                self.snoozed = newSnoozed
                self.allSnoozed = newAllSnoozed
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
        case .open, .done, .todo, .snooze:
            if let action = PopoverLogic.action(for: key, selection: selection, sections: sections, activity: activity) {
                perform(action)
            }
        }
    }

    public func perform(_ action: PopoverAction) {
        switch action {
        case .toggleSection(let key):
            let section = sections.first { $0.key == key }
            collapsed[key] = !(section?.collapsed ?? false)
            app.store.setCollapsed(collapsed, account: accountId)
            selection = PopoverLogic.keep(selection, in: items)
        case .expand(let key):
            expanded.insert(key)
            if selection == .more(key) {
                selection = .section(key)
            }
        default:
            app.perform(action, account: accountId)
        }
    }

    /// The account is no longer open anywhere: `seen` starts over and the
    /// "+ N more PRs" fold again.
    func closedAll() {
        seen.reset()
        expanded = []
    }

    public func shown(_ surface: Surface) -> Set<String> {
        shownBySurface[surface] ?? []
    }

    func clearShown(_ surface: Surface) {
        shownBySurface[surface] = nil
    }

    /// The rows now inside the visible part of one surface's list. Unread
    /// ones not sent in this open period go out as `seen`, only while that
    /// surface is open. Rows collapsed, folded or filtered out are not laid
    /// out, so they never arrive here.
    public func rowsShown(_ shown: Set<String>, surface: Surface) {
        shownBySurface[surface] = shown
        guard app.isOpen(surface, account: accountId) else { return }
        let rows = tab == .prs ? sections.flatMap(\.cards).flatMap(\.rows) : activity
        let unread = Set(rows.filter(\.unread).map(\.id))
        app.seen(seen.newlySeen(shown: shown, unread: unread))
    }
}
