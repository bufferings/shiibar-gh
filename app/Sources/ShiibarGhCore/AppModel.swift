// The app's state, fed by the `subscribe` connection, and what the popovers,
// the windows and Settings do through the daemon. Views observe it; nothing
// here touches AppKit, so `swift test` covers it with a fake daemon.
//
// Accounts are keyed by their id (the GitHub user id, numeric, as a
// string); requests carry the login the account has now (DESIGN.md, "Wire format").

import Combine
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
    /// `text_size`: the body text of the popovers and windows.
    @Published public private(set) var textSize = TextSize.base
    /// `dismissed_keep_days`: the m of the Dismissed list's note and of a
    /// Dismiss shown before the daemon answers.
    /// `confirm_dismiss`: the × on a card asks first (DESIGN.md,
    /// "Confirming ×").
    @Published public private(set) var confirmDismiss = true
    @Published public private(set) var keepDays = DismissedText.defaultKeepDays
    /// `auto_dismiss_after_days`: the n of the tooltip of `Dismissed in N
    /// days`.
    @Published public private(set) var autoDismissDays = DismissedText.defaultAutoDismissDays
    /// Accounts whose Refresh waits for its answer (DESIGN.md, "Showing
    /// what an operation did": progress until the reply).
    @Published public private(set) var refreshing: Set<String> = []
    /// The last request that failed, for the surface that made it.
    @Published public var lastError: String?

    public let api: DaemonAPI
    public let store: UIStateStore
    private let opener: URLOpening
    private let notifier: NotificationPresenting
    private let copier: LinkCopying?
    /// How long the failure band of a local operation stays.
    public let failureDuration: TimeInterval
    private var surfaces = OpenSurfaces()
    private var viewModels: [String: AccountViewModel] = [:]
    /// The accounts some surface shows, open or not: their lists follow
    /// `account_changed`.
    private var displayed: [String: Set<Surface>] = [:]
    private var prompt = KeychainPrompt()
    private let clock: () -> Int64
    /// The clock, the timer and the length of `Unread only`'s wait
    /// (`UnreadLinger`).
    public let linger: LingerTiming

    /// Asks the app to show an account's popover (a summary notification).
    public var onOpenPopover: ((String) -> Void)?
    /// Asks the app to show an account on a surface: the window brought to
    /// the front, or the popover opened (an individual notification).
    public var onShowAccount: ((String, Surface) -> Void)?
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
        copier: LinkCopying? = nil, failureDuration: TimeInterval = OperationFailure.duration,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        linger: LingerTiming = LingerTiming()
    ) {
        self.linger = linger
        self.api = api
        self.store = store
        self.opener = opener
        self.notifier = notifier
        self.copier = copier
        self.failureDuration = failureDuration
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
            // No wait: the list is read again at once, and once more after
            // it for the changes that came meanwhile (DESIGN.md, "Showing
            // what an operation did").
            if displayed[account.id] != nil {
                viewModels[account.id]?.reload()
            }
            // Mutes made elsewhere (Settings, the CLI) come with it too: the
            // menus and the local mute changes read them.
            if let model = viewModels[account.id], model.mutes != nil {
                model.loadMutes()
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
            configChanged(key, value)
            for observer in configObservers { observer(key, value) }
        case .unknown:
            break
        }
    }

    private func configChanged(_ key: String, _ value: ConfigValue?) {
        switch key {
        case TextSize.configKey:
            textSize = TextSize.clamp(value?.intValue ?? value?.stringValue.flatMap { Int64($0) })
        case DismissedText.confirmKey:
            if let on = value?.boolValue { confirmDismiss = on }
        case DismissedText.keepDaysKey:
            if let days = value?.intValue, days >= 1 { keepDays = days }
        case DismissedText.autoDismissKey:
            if let days = value?.intValue, days >= 0 { autoDismissDays = days }
        default:
            break
        }
    }

    /// The settings the popovers use, at connection.
    public func loadConfig() async {
        for key in [TextSize.configKey, DismissedText.keepDaysKey, DismissedText.autoDismissKey, DismissedText.confirmKey] {
            if let value = try? await api.configGet(key) { configChanged(key, value) }
        }
    }

    /// ⌘=, ⌘+, ⌘− and ⌘0: `config_set` with the new size; nothing at the
    /// ends of the range. The size shows once the daemon answers or sends
    /// `config_changed`.
    public func changeTextSize(_ change: TextSize.Change) {
        guard let wanted = TextSize.next(textSize, change) else { return }
        let api = self.api
        Task {
            do {
                let value = try await api.configSet(TextSize.configKey, .int(Int64(wanted)))
                configChanged(TextSize.configKey, value)
            } catch {
                lastError = "\(error)"
            }
        }
    }

    /// `Don't ask again` of the × confirmation: the setting goes off, here
    /// at once and in the daemon (Settings turns it on again).
    public func stopConfirmingDismiss() {
        confirmDismiss = false
        let api = self.api
        Task {
            do {
                let value = try await api.configSet(DismissedText.confirmKey, .bool(false))
                configChanged(DismissedText.confirmKey, value)
            } catch {
                lastError = "\(error)"
            }
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
        Task { await loadConfig() }
        for id in surfaces.openAccounts {
            guard let login = account(id)?.login else { continue }
            openThenReload(id, login: login)
        }
    }

    // MARK: - Surfaces

    /// A surface shows the account's list, open or not (the window keeps
    /// showing while another app has the focus). The window's Dismissed
    /// list goes when it closes; the search text stays (the account's).
    /// `opening`: the surface opens right after (`surfaceOpened`), which
    /// reads the lists once `popover_opened` is answered, so nothing is read
    /// here before it.
    public func surfaceDisplayed(_ surface: Surface, account: String, _ shown: Bool, opening: Bool = false) {
        if shown {
            let first = displayed[account] == nil
            let again = displayed[account]?.contains(surface) != true
            displayed[account, default: []].insert(surface)
            if again { viewModels[account]?.list(surface).shown() }
            if first && !opening { viewModel(account).reload() }
        } else if var set = displayed[account] {
            if surface == .window { viewModels[account]?.list(.window).windowClosed() }
            set.remove(surface)
            displayed[account] = set.isEmpty ? nil : set
            // Not shown now: it keeps no card `Unread only` kept.
            viewModels[account]?.list(surface).updateLinger()
        }
    }

    public func isDisplayed(_ surface: Surface, account: String) -> Bool {
        displayed[account]?.contains(surface) ?? false
    }

    /// The popover opened, or the window got the focus.
    public func surfaceOpened(_ surface: Surface, account: String) {
        if surfaces.isOpen(surface, account: account) { return }
        let first = surfaces.opened(surface, account: account)
        let model = viewModel(account)
        model.list(surface).opened()
        // A row's menu reads Mute or Unmute @actor from them.
        model.loadMutes()
        if first, let login = self.account(account)?.login {
            openThenReload(account, login: login)
        } else {
            model.reload()
        }
    }

    /// `popover_opened`, then the list: the daemon holds the automatic
    /// Dismiss and the removal from the Dismissed list while open
    /// (DESIGN.md, "Dismiss"). The list is read even when
    /// `popover_opened` fails.
    private func openThenReload(_ account: String, login: String) {
        let api = self.api
        Task {
            do {
                try await api.popoverOpened(login)
            } catch {
                lastError = "\(error)"
            }
            viewModels[account]?.reload()
        }
    }

    /// The popover closed, or the window closed or lost the focus. Rows
    /// stay unread (DESIGN.md, "How unread clears").
    public func surfaceClosed(_ surface: Surface, account: String) {
        guard surfaces.isOpen(surface, account: account) else { return }
        viewModels[account]?.list(surface).closed(ends: surface == .popover)
        if surfaces.closed(surface, account: account), let login = self.account(account)?.login {
            send { try await $0.popoverClosed(login) }
        }
    }

    public func isOpen(_ account: String) -> Bool {
        surfaces.isOpen(account)
    }

    public func isOpen(_ surface: Surface, account: String) -> Bool {
        surfaces.isOpen(surface, account: account)
    }

    // MARK: - Actions

    public func copy(_ text: String) {
        copier?.copy(text)
    }

    /// Refresh asks GitHub: the button shows progress until the answer.
    public func refresh(_ account: String?) {
        let login = account.flatMap { self.account($0)?.login }
        if account != nil && login == nil { return }
        if let account { refreshing.insert(account) }
        let api = self.api
        Task {
            do {
                _ = try await api.refresh(login)
            } catch {
                lastError = "\(error)"
            }
            if let account { refreshing.remove(account) }
        }
    }

    /// ⌘R (DESIGN.md, "Keyboard"): the header's Refresh, except while the
    /// account's refresh is still running (the button shows its progress).
    public func refreshByKey(_ account: String) {
        guard !refreshing.contains(account) else { return }
        refresh(account)
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

    /// A clicked notification (DESIGN.md, "macOS notifications"): a summary
    /// opens the account's popover on its last tab (the window in front
    /// instead while it is open); an individual one shows
    /// the account (the window in front if it is open, else the popover),
    /// opens the tab of the PR's placement (All without one) and selects the
    /// card, unfolding it. Rows are not read.
    public func notificationClicked(type: NotificationType?, account: String, url: String?, pr: String? = nil) {
        guard self.account(account) != nil else { return }
        let surface = SurfaceRules.surfaceToShow(windowOpen: displayed[account]?.contains(.window) == true)
        if type == .summary {
            // The last tab; the window in front when it is open, as a click
            // on the menu bar icon (DESIGN.md, "macOS notifications").
            if surface == .window { onShowAccount?(account, .window) } else { onOpenPopover?(account) }
            return
        }
        onShowAccount?(account, surface)
        if let pr { viewModel(account).list(surface).reveal(pr: pr) }
    }

    /// A Save was answered: Token shows Checking… until the new test.
    public func tokenSaved(_ account: Account, before: Int64?) {
        let current = self.account(account.id) ?? account
        checks.started(current, before: before, now: now)
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

/// One account's data, shared by its popover and its window: the daemon's
/// cards with the local operations still on their way applied over them,
/// and what is saved per account (Group by, Then by, the sort order, the
/// group orders, the collapsed and expanded sections, the expanded rows of
/// the cards, the expanded row bodies, the Filters, the search texts,
/// Compact, Keep on top).
/// What each
/// surface shows is its `SurfaceListModel`.
@MainActor
public final class AccountViewModel: ObservableObject {
    public let accountId: String
    unowned let app: AppModel
    /// The cards shown: the daemon's, with the local operations applied.
    /// A change shows first in the cards `Unread only` keeps, then in the
    /// selection (`SurfaceListModel.updateLinger`).
    @Published public private(set) var cards: [Card] = [] {
        didSet {
            revision += 1
            lists.values.forEach { $0.updateLinger() }
        }
    }
    @Published public private(set) var loaded = false
    @Published public private(set) var options: ListOptions { didSet { revision += 1 } }
    @Published public private(set) var groupOrders: GroupOrders { didSet { revision += 1 } }
    /// The repositories that have had cards (the Repository group order).
    @Published public private(set) var repositories: [String] { didSet { revision += 1 } }
    @Published public private(set) var collapsed: Set<String> { didSet { revision += 1 } }
    @Published public private(set) var expanded: Set<String> { didSet { revision += 1 } }
    /// The Filter of each tab (DESIGN.md, "Filter"): the account's, shared
    /// by the popover and the window.
    @Published public private(set) var filters: [ListTab: ListFilter] { didSet { revision += 1 } }
    /// The tabs whose `Filter` is open (DESIGN.md, "Filter"): per tab,
    /// shared by the popover and the window.
    @Published public private(set) var filtersOpen: Set<ListTab>
    /// The search text of each tab and of the Dismissed list (DESIGN.md,
    /// "Search field"): kept like the Filter, shared by the popover and the
    /// window.
    @Published public private(set) var searches: [SearchScope: String]
    /// Compact (DESIGN.md, "Compact"): the cards of the tabs show their
    /// heading only. The account's, shared by the popover and the window.
    @Published public private(set) var compact: Bool
    /// Cards whose rows show past the newest three, until `Show less`
    /// (DESIGN.md, "Rows in a card").
    @Published public private(set) var expandedRows: Set<String>
    /// Rows whose body shows up to 5 lines, until `less` (DESIGN.md, "Row
    /// body").
    @Published public private(set) var expandedBodies: Set<String>
    /// Counts the changes of what the sections are made of, so a surface
    /// works its sections out once per change, not once per view.
    public private(set) var revision = 0
    /// Keep on top of the window, kept per account.
    @Published public private(set) var keepOnTop: Bool
    /// The account's mutes, read once a menu or Settings needs them.
    @Published public private(set) var mutes: Mutes?
    /// `Couldn't <verb>: <reason>` of the last local operation the daemon
    /// refused; gone at the next operation or after a while.
    @Published public private(set) var failure: String?
    private var failureTimer: Task<Void, Never>?

    /// The cards as the daemon sent them last.
    private var received: [Card] = []
    struct Pending {
        var id: Int
        var change: LocalChange
        /// Answered: dropped once a list started after this one arrives.
        var dropAfter: Int?
    }
    private var pending: [Pending] = []
    private var nextChange = 0
    /// Lists asked for so far, and whether one is on its way.
    private var listsStarted = 0
    private var reading = false
    private var readAgain = false
    private var lists: [Surface: SurfaceListModel] = [:]

    init(account: String, app: AppModel) {
        accountId = account
        self.app = app
        options = app.store.options(account: account)
        groupOrders = app.store.groupOrders(account: account)
        repositories = app.store.repositories(account: account)
        collapsed = app.store.collapsed(account: account)
        expanded = app.store.expanded(account: account)
        filters = app.store.filters(account: account)
        filtersOpen = app.store.filtersOpen(account: account)
        searches = app.store.searches(account: account)
        compact = app.store.compact(account: account)
        expandedRows = app.store.expandedRows(account: account)
        expandedBodies = app.store.expandedBodies(account: account)
        keepOnTop = app.store.keepOnTop(account: account)
    }

    public var account: Account? { app.account(accountId) }

    /// The popover's or the window's own state: tab, Dismissed list and
    /// selection.
    public func list(_ surface: Surface) -> SurfaceListModel {
        if let list = lists[surface] { return list }
        let list = SurfaceListModel(data: self, surface: surface)
        lists[surface] = list
        return list
    }

    public var usage: ApiUsage { ApiUsage(account?.rateLimit) }

    private func surfacesKeepSelection() {
        lists.values.forEach { $0.keepSelection() }
    }

    // MARK: Saved choices

    public func setGroupBy(_ value: GroupBy) {
        var next = options
        next.setGroupBy(value)
        setOptions(next)
    }

    public func setThenBy(_ value: GroupBy) {
        var next = options
        next.setThenBy(value)
        setOptions(next)
    }

    public func setSort(_ value: SortOrder) {
        var next = options
        next.sort = value
        setOptions(next)
    }

    private func setOptions(_ next: ListOptions) {
        guard next != options else { return }
        options = next
        app.store.setOptions(next, account: accountId)
        surfacesKeepSelection()
    }

    /// The groups of a Group by value in the user's order, for the
    /// Grouping sheet.
    public func groups(_ by: GroupBy) -> [GroupItem] {
        guard let account else { return [] }
        return Listing.orderedGroups(by, account: account, repositories: repositories, orders: groupOrders)
    }

    /// The Grouping sheet moved a group.
    public func moveGroups(_ by: GroupBy, from source: IndexSet, to destination: Int) {
        var keys = groups(by).map(\.key)
        let moving = source.sorted().map { keys[$0] }
        let insertAt = destination - source.filter { $0 < destination }.count
        keys.removeAll { moving.contains($0) }
        keys.insert(contentsOf: moving, at: max(0, min(insertAt, keys.count)))
        groupOrders[by] = keys
        if by == .repository { repositories = keys; app.store.setRepositories(keys, account: accountId) }
        app.store.setGroupOrders(groupOrders, account: accountId)
        surfacesKeepSelection()
    }

    func setCollapsed(_ key: String, _ value: Bool) {
        guard collapsed.contains(key) != value else { return }
        if value { collapsed.insert(key) } else { collapsed.remove(key) }
        app.store.setCollapsed(collapsed, account: accountId)
        surfacesKeepSelection()
    }

    func setExpanded(_ key: String, _ value: Bool) {
        guard expanded.contains(key) != value else { return }
        if value { expanded.insert(key) } else { expanded.remove(key) }
        app.store.setExpanded(expanded, account: accountId)
        surfacesKeepSelection()
    }

    /// The Filter of a tab.
    public func filter(_ tab: ListTab) -> ListFilter {
        filters[tab] ?? ListFilter()
    }

    /// A change of a tab's Filter: shown at once; the cards it hides leave
    /// the selection, and the cards `Unread only` kept on that tab go
    /// (DESIGN.md, "Filter", "Selection").
    public func setFilter(_ filter: ListFilter, tab: ListTab) {
        guard self.filter(tab) != filter else { return }
        filters[tab] = filter
        app.store.setFilters(filters, account: accountId)
        lists.values.forEach { $0.filterChanged(tab) }
    }

    /// Whether a tab's `Filter` is open.
    public func filterOpen(_ tab: ListTab) -> Bool {
        filtersOpen.contains(tab)
    }

    public func setFilterOpen(_ open: Bool, tab: ListTab) {
        guard filterOpen(tab) != open else { return }
        if open { filtersOpen.insert(tab) } else { filtersOpen.remove(tab) }
        app.store.setFiltersOpen(filtersOpen, account: accountId)
    }

    /// The search text of a tab or of the Dismissed list.
    public func search(_ scope: SearchScope) -> String {
        searches[scope] ?? ""
    }

    /// A change of a search text, typed on either surface or cleared: both
    /// show it, and keep their selection among what it shows.
    public func setSearch(_ text: String, _ scope: SearchScope) {
        guard search(scope) != text else { return }
        searches[scope] = text.isEmpty ? nil : text
        app.store.setSearches(searches, account: accountId)
        surfacesKeepSelection()
    }

    /// The Compact toggle. Turning it on moves a selected row, `+ N more`,
    /// `Older activity on GitHub` or `Show less` of a card to the card's
    /// heading (DESIGN.md, "Compact").
    public func setCompact(_ on: Bool) {
        guard compact != on else { return }
        compact = on
        app.store.setCompact(on, account: accountId)
        lists.values.forEach { $0.compactChanged() }
    }

    func setRowsExpanded(_ card: String, _ value: Bool) {
        guard expandedRows.contains(card) != value else { return }
        if value { expandedRows.insert(card) } else { expandedRows.remove(card) }
        app.store.setExpandedRows(expandedRows, account: accountId)
        lists.values.forEach { $0.rowsChanged() }
    }

    func setBodyExpanded(_ row: String, _ value: Bool) {
        guard expandedBodies.contains(row) != value else { return }
        if value { expandedBodies.insert(row) } else { expandedBodies.remove(row) }
        app.store.setExpandedBodies(expandedBodies, account: accountId)
    }

    /// The expansions of cards and rows gone from the list are forgotten
    /// (DESIGN.md, "Rows in a card", "Row body").
    private func forgetGone(_ cards: [Card]) {
        let cardIds = Set(cards.map(\.id))
        let rows = expandedRows.intersection(cardIds)
        if rows != expandedRows {
            expandedRows = rows
            app.store.setExpandedRows(rows, account: accountId)
            lists.values.forEach { $0.rowsChanged() }
        }
        let rowIds = Set(cards.lazy.flatMap(\.rows).map(\.id))
        let bodies = expandedBodies.intersection(rowIds)
        if bodies != expandedBodies {
            expandedBodies = bodies
            app.store.setExpandedBodies(bodies, account: accountId)
        }
    }

    public func toggleKeepOnTop() {
        keepOnTop.toggle()
        app.store.setKeepOnTop(keepOnTop, account: accountId)
    }

    // MARK: Loading

    /// Read the list now; one asked for while another is on its way runs
    /// once after it.
    public func reload() {
        guard let account else { return }
        if reading {
            readAgain = true
            return
        }
        reading = true
        listsStarted += 1
        let number = listsStarted
        let api = app.api
        let login = account.login
        Task {
            do {
                let cards = try await api.list(.app(login))
                arrived(cards, number: number)
            } catch {
                app.lastError = "\(error)"
            }
            reading = false
            if readAgain {
                readAgain = false
                reload()
            }
        }
    }

    func arrived(_ cards: [Card], number: Int) {
        received = cards
        forgetGone(cards)
        pending.removeAll { $0.dropAfter.map { number > $0 } ?? false }
        let known = Listing.knownRepositories(repositories, cards: cards)
        if known != repositories {
            repositories = known
            app.store.setRepositories(known, account: accountId)
        }
        recompute()
        loaded = true
        lists.values.forEach { $0.listArrived() }
    }

    /// The mutes the local mute changes start from: the list read, or what
    /// the cards tell before it is read.
    private var mutesNow: Mutes { mutes ?? Mutes.inferred(from: received) }

    private func recompute() {
        var mutes = mutesNow
        var next = received
        for item in pending { next = item.change.apply(next, mutes: &mutes) }
        cards = next
    }

    // MARK: Local operations

    /// The last operation sent: the next one waits for it to be answered.
    private var sending: Task<Void, Never>?

    /// Sends an operation after the ones before it, so the daemon gets the
    /// requests of the account in the order of the operations (DESIGN.md,
    /// "Showing what an operation did"). Each request opens its own
    /// connection: sent at once, a later one could reach the daemon first
    /// and leave it in another state than the one shown. What shows is
    /// changed at once, before this.
    private func send(_ body: @escaping @MainActor () async -> Void) {
        let previous = sending
        sending = Task {
            await previous?.value
            await body()
        }
    }

    /// Show `change` at once and send `request`; a refusal (or no daemon)
    /// takes it back and shows the failure band (DESIGN.md, "Showing what
    /// an operation did").
    private func run(_ change: LocalChange, _ request: @escaping (DaemonAPI) async throws -> Void) {
        clearFailure()
        let id = nextChange
        nextChange += 1
        pending.append(Pending(id: id, change: change))
        recompute()
        surfacesKeepSelection()
        let api = app.api
        send { [self] in
            do {
                try await request(api)
                if let index = pending.firstIndex(where: { $0.id == id }) { pending[index].dropAfter = listsStarted }
            } catch {
                pending.removeAll { $0.id == id }
                recompute()
                surfacesKeepSelection()
                showFailure(OperationFailure.text(change.verb, error))
            }
            reload()
        }
    }

    /// Several local operations of one action (a key, the multi-card menu
    /// or a drag of several selected cards): shown at once, sent one after another
    /// in order, after the operations before them; a refused one alone is taken back, and one failure band
    /// shows for the action. `failed` gets the cards taken back.
    func runAll(_ items: [(card: String, change: LocalChange, request: (DaemonAPI) async throws -> Void)], failed: @escaping ([String]) -> Void) {
        guard !items.isEmpty else { return }
        clearFailure()
        var ids: [Int] = []
        for item in items {
            ids.append(nextChange)
            pending.append(Pending(id: nextChange, change: item.change))
            nextChange += 1
        }
        recompute()
        surfacesKeepSelection()
        let api = app.api
        send { [self] in
            var refused: [String] = []
            var firstError: (OperationVerb, Error)?
            for (item, id) in zip(items, ids) {
                do {
                    try await item.request(api)
                    if let index = pending.firstIndex(where: { $0.id == id }) { pending[index].dropAfter = listsStarted }
                } catch {
                    pending.removeAll { $0.id == id }
                    refused.append(item.card)
                    if firstError == nil { firstError = (item.change.verb, error) }
                }
            }
            if let (verb, error) = firstError {
                recompute()
                surfacesKeepSelection()
                showFailure(OperationFailure.text(verb, error))
                failed(refused)
            }
            reload()
        }
    }

    /// `place` for several moves, in order.
    func placeAll(_ moves: [PlaceMove], failed: @escaping ([String]) -> Void) {
        guard let login = account?.login else { return }
        var items: [(card: String, change: LocalChange, request: (DaemonAPI) async throws -> Void)] = []
        for move in moves {
            guard let pr = pr(move.card) else { continue }
            var position = move.position
            if case .before(let other) = move.position {
                guard let otherPR = self.pr(other) else { continue }
                position = .before(otherPR)
            }
            let target = move.target
            items.append((move.card, .place(move), { try await $0.place(account: login, pr: pr, target: target, position: position) }))
        }
        runAll(items, failed: failed)
    }

    /// Dismiss several cards, in order.
    func dismissAll(_ cards: [String], failed: @escaping ([String]) -> Void) {
        guard let login = account?.login else { return }
        let now = app.now
        var items: [(card: String, change: LocalChange, request: (DaemonAPI) async throws -> Void)] = []
        for card in cards {
            guard let pr = pr(card) else { continue }
            items.append((card, .dismiss(card: card, at: now, expiresAt: now + app.keepDays * 86_400), { try await $0.dismiss(account: login, pr: pr) }))
        }
        runAll(items, failed: failed)
    }

    private func pr(_ card: String) -> String? {
        cards.first { $0.id == card }?.pr
    }

    public func place(_ move: PlaceMove) {
        guard let login = account?.login, let pr = pr(move.card) else { return }
        var position = move.position
        if case .before(let other) = move.position {
            guard let otherPR = self.pr(other) else { return }
            position = .before(otherPR)
        }
        let target = move.target
        run(.place(move)) { try await $0.place(account: login, pr: pr, target: target, position: position) }
    }

    public func dismiss(_ card: String) {
        guard let login = account?.login, let pr = pr(card) else { return }
        let now = app.now
        run(.dismiss(card: card, at: now, expiresAt: now + app.keepDays * 86_400)) { try await $0.dismiss(account: login, pr: pr) }
    }

    public func restore(_ card: String) {
        guard let login = account?.login, let pr = pr(card) else { return }
        run(.restore(card: card)) { try await $0.restore(account: login, pr: pr) }
    }

    public func mute(_ kind: MuteKind, _ name: String, on: Bool) {
        guard let login = account?.login else { return }
        run(on ? .mute(kind, name) : .unmute(kind, name)) { [weak self] api in
            let mutes = on
                ? try await api.mute(account: login, kind: kind, name: name)
                : try await api.unmute(account: login, kind: kind, name: name)
            self?.mutes = mutes
        }
    }

    /// Read the account's mutes (menus and Settings).
    public func loadMutes() {
        guard let login = account?.login else { return }
        let api = app.api
        Task {
            if let mutes = try? await api.mutes(account: login) {
                self.mutes = mutes
                recompute()
            }
        }
    }

    func row(_ id: String) -> Row? {
        cards.lazy.flatMap(\.rows).first { $0.id == id }
    }

    /// Show the rows read at once and send `read`.
    func markRead(_ ids: [String]) {
        let fresh = ids.filter { row($0)?.unread ?? false }
        guard !fresh.isEmpty else { return }
        run(.read(Set(fresh))) { try await $0.read(fresh) }
    }

    // MARK: Failure band

    private func showFailure(_ text: String) {
        failure = text
        failureTimer?.cancel()
        let duration = app.failureDuration
        failureTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.failure = nil
        }
    }

    private func clearFailure() {
        failureTimer?.cancel()
        failureTimer = nil
        if failure != nil { failure = nil }
    }
}

/// The clock and the timer of `Unread only`'s wait (DESIGN.md, "Filter"),
/// and its length: tests give their own, so no test waits.
public struct LingerTiming {
    /// Seconds a card read under `Unread only` stays once not selected.
    public var duration: Double
    /// Seconds, any origin, never going back.
    public var now: () -> Double
    /// Calls the function once, after about that many seconds, on the main
    /// actor.
    public var schedule: (Double, @escaping @MainActor () -> Void) -> Void

    public init(
        duration: Double = UnreadLinger.standardDuration,
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping (Double, @escaping @MainActor () -> Void) -> Void = { delay, fire in
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { MainActor.assumeIsolated { fire() } }
        }
    ) {
        self.duration = duration
        self.now = now
        self.schedule = schedule
    }

    /// The development switch of the wait (docs/tasks/M8.md): the
    /// environment variable `SHIIBAR_GH_UNREAD_ONLY_SECONDS`, a number of
    /// seconds above 0; else the standard 5.
    public static func duration(environment: [String: String]) -> Double {
        guard let text = environment[environmentKey], let value = Double(text), value > 0, value.isFinite else {
            return UnreadLinger.standardDuration
        }
        return value
    }

    public static let environmentKey = "SHIIBAR_GH_UNREAD_ONLY_SECONDS"
}
