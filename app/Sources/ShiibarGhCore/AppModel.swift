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
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
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
        for key in [TextSize.configKey, DismissedText.keepDaysKey, DismissedText.autoDismissKey] {
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
    /// showing while another app has the focus). The window's search and
    /// Dismissed list go when it closes.
    /// `opening`: the surface opens right after (`surfaceOpened`), which
    /// reads the lists once `popover_opened` is answered, so nothing is read
    /// here before it.
    public func surfaceDisplayed(_ surface: Surface, account: String, _ shown: Bool, opening: Bool = false) {
        if shown {
            let first = displayed[account] == nil
            displayed[account, default: []].insert(surface)
            if first && !opening { viewModel(account).reload() }
        } else if var set = displayed[account] {
            if surface == .window { viewModels[account]?.list(.window).windowClosed() }
            set.remove(surface)
            displayed[account] = set.isEmpty ? nil : set
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
        viewModels[account]?.list(surface).closed(clearsSearch: surface == .popover)
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
    /// opens the account's popover on its last tab; an individual one shows
    /// the account (the window in front if it is open, else the popover),
    /// opens the tab of the PR's placement (All without one) and selects the
    /// card, unfolding it. Rows are not read.
    public func notificationClicked(type: NotificationType?, account: String, url: String?, pr: String? = nil) {
        guard self.account(account) != nil else { return }
        if type == .summary {
            onOpenPopover?(account)
            return
        }
        let surface: Surface = displayed[account]?.contains(.window) == true ? .window : .popover
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
/// group orders, the collapsed and expanded sections, Keep on top). What
/// each surface shows is its `SurfaceListModel`.
@MainActor
public final class AccountViewModel: ObservableObject {
    public let accountId: String
    unowned let app: AppModel
    /// The cards shown: the daemon's, with the local operations applied.
    @Published public private(set) var cards: [Card] = []
    @Published public private(set) var loaded = false
    @Published public private(set) var options: ListOptions
    @Published public private(set) var groupOrders: GroupOrders
    /// The repositories that have had cards (the Repository group order).
    @Published public private(set) var repositories: [String]
    @Published public private(set) var collapsed: Set<String>
    @Published public private(set) var expanded: Set<String>
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
        keepOnTop = app.store.keepOnTop(account: account)
    }

    public var account: Account? { app.account(accountId) }

    /// The popover's or the window's own state: tab, Dismissed list,
    /// search, selection and expanded rows.
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

    private func recompute() {
        let users = mutes?.users ?? []
        cards = pending.reduce(received) { $1.change.apply($0, mutedUsers: users) }
    }

    // MARK: Local operations

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
        Task {
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

/// What one surface (the popover or the window) of an account shows: its
/// tab, whether the Dismissed list is open, its searches, its selection and
/// its expanded rows (DESIGN.md, "Open in window": the popover and the
/// window keep these apart). The data and the saved choices come from the
/// shared `AccountViewModel`.
@MainActor
public final class SurfaceListModel: ObservableObject {
    public let surface: Surface
    public unowned let data: AccountViewModel
    /// The last tab, kept per surface (DESIGN.md, "Tabs").
    @Published public private(set) var tab: ListTab
    @Published public private(set) var showingDismissed = false
    /// The search of each tab. Not kept.
    @Published public private(set) var searches: [ListTab: String] = [:]
    /// The Dismissed list's own search, gone when the list closes.
    @Published public private(set) var dismissedSearch = ""
    /// Whether the search field has the keyboard.
    @Published public var searchFocused = false
    @Published public private(set) var selection: SelectionItem?
    /// Cards whose rows show past the newest three. Not kept.
    @Published public private(set) var expandedRows: Set<String> = []
    /// The Grouping sheet shows.
    @Published public var showsGrouping = false
    /// The text selected in this surface's cards and rows, read and cleared
    /// here (DESIGN.md, "What a press does"). The app sets it.
    public var textSelection: TextSelecting?
    /// The card being dragged by its grip, while a drag is on.
    @Published public private(set) var dragging: String?
    /// Where the dragged card would land, for the insertion line.
    @Published public private(set) var dropTarget: DropTarget?
    private var forward: AnyCancellable?

    init(data: AccountViewModel, surface: Surface) {
        self.data = data
        self.surface = surface
        tab = data.app.store.lastTab(account: data.accountId, surface: surface)
        forward = data.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var app: AppModel { data.app }

    /// `auto_dismiss_after_days`, for the tooltip of `Dismissed in N days`.
    public var autoDismissDays: Int64 { app.autoDismissDays }

    // MARK: Derived lists

    /// The search of what shows: the tab's, or the Dismissed list's.
    public var search: String {
        showingDismissed ? dismissedSearch : searches[tab] ?? ""
    }

    public var sections: [SectionLayout] {
        guard let account = data.account, !showingDismissed else { return [] }
        return Listing.sections(
            tab: tab, cards: data.cards, account: account, options: data.options, orders: data.groupOrders,
            repositories: data.repositories,
            folding: Listing.Folding(collapsed: data.collapsed, expanded: data.expanded, search: search)
        )
    }

    /// The Dismissed list after its search.
    public var dismissedCards: [Card] {
        Listing.search(Listing.dismissed(data.cards), dismissedSearch)
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
            ? ListView(tab: nil, dismissed: dismissedCards, expandedRows: expandedRows, cards: data.cards)
            : ListView(tab: tab, sections: sections, expandedRows: expandedRows, cards: data.cards)
    }

    /// The text in place of an empty list.
    public var emptyText: String? {
        Listing.emptyText(loaded: data.loaded, tab: showingDismissed ? nil : tab, cards: data.cards, search: search)
    }

    public var items: [SelectionItem] {
        PopoverLogic.items(view)
    }

    public var hints: [KeyHint] {
        PopoverLogic.hints(selection: selection, view: view)
    }

    /// The rows ⇧R and Mark all as read send.
    public var rowsToRead: [String] {
        showingDismissed ? [] : Listing.rowsToRead(tab: tab, cards: data.cards, search: search)
    }

    func keepSelection() {
        let kept = PopoverLogic.keep(selection, in: items)
        if kept != selection { selection = kept }
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
        textSelection?.clearSelection()
        keepSelection()
    }

    public func openDismissedList() {
        guard !showingDismissed else { return }
        showingDismissed = true
        searchFocused = false
        textSelection?.clearSelection()
        selection = nil
    }

    /// ← or Esc: back to the tab; the list's search goes.
    public func closeDismissedList() {
        guard showingDismissed else { return }
        showingDismissed = false
        dismissedSearch = ""
        searchFocused = false
        textSelection?.clearSelection()
        selection = nil
    }

    // MARK: Selection, keys and clicks

    /// Select an item: by ↑↓, a click or a right click. A row is read.
    /// Selecting another item clears the selected text (DESIGN.md, "What a
    /// press does").
    public func select(_ item: SelectionItem?) {
        if item != selection { textSelection?.clearSelection() }
        selection = item
        if case .row(let id, _)? = item { data.markRead([id]) }
    }

    /// The right-click menu of an item, after selecting (and reading) it.
    /// `Copy` shows only while text stays selected.
    public func rightClick(_ item: SelectionItem) -> [MenuEntry?] {
        select(item)
        if case .row = item, data.mutes == nil { data.loadMutes() }
        return PopoverLogic.menu(
            for: item, view: view, hasTextSelection: textSelection?.selectedText != nil,
            login: data.account?.login ?? "", mutedUsers: data.mutes?.users ?? []
        )
    }

    /// A key while the surface has the focus and the search field does not.
    public func press(_ key: Key) {
        switch key {
        case .up, .down:
            select(PopoverLogic.move(selection, up: key == .up, in: items))
        case .find:
            searchFocused = true
        case .copy:
            if let text = textSelection?.selectedText {
                app.copy(text)
            } else if let link = PopoverLogic.link(for: selection, view: view) {
                app.copy(link)
            }
        case .tab(let next):
            openTab(next)
        case .back:
            closeDismissedList()
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

    public func setSearch(_ text: String) {
        if showingDismissed {
            dismissedSearch = text
        } else {
            searches[tab] = text
        }
        keepSelection()
    }

    func clearSearches() {
        searches = [:]
        dismissedSearch = ""
        searchFocused = false
        keepSelection()
    }

    public func perform(_ action: PopoverAction) {
        switch action {
        case .open(let url, let read):
            if let read { data.markRead([read]) }
            app.open(url)
        case .copyLink(let text), .copyText(let text):
            app.copy(text)
        case .copySelectedText:
            if let text = textSelection?.selectedText { app.copy(text) }
        case .place(let move):
            data.place(move)
        case .dismiss(let card):
            data.dismiss(card)
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
            expandedRows.insert(card)
            if selection == .moreRows(card: card) { selection = .header(card: card) }
        case .showInTab(let card):
            if let pr = data.cards.first(where: { $0.id == card })?.pr { reveal(pr: pr) }
        case .markAllRead:
            data.markRead(rowsToRead)
        }
    }

    /// Show the PR's card: its tab (All without a placement), no search,
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
        searches[tab] = nil
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
                textSelection?.clearSelection()
                selection = .header(card: card.id)
                return
            }
            guard let parent = sections.first(where: { !$0.isLeaf && $0.matching.contains { $0.id == card.id } }) else { return }
            data.setCollapsed(parent.key, false)
        }
    }

    // MARK: Drag and drop

    /// A drag started at a card's grip.
    public func beginDrag(_ card: String) {
        dragging = card
        dropTarget = nil
    }

    /// The pointer of a card drag moved over `zone`: where it would land,
    /// nil when it cannot (the line goes and the drop is refused).
    @discardableResult
    public func dragOver(_ zone: DropZone) -> DropTarget? {
        guard dragging != nil else { return nil }
        let target = CardDrop.target(zone, sections: sections)
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
    public func drop(_ zone: DropZone) -> Bool {
        defer {
            dragging = nil
            dropTarget = nil
        }
        guard let id = dragging, let card = data.cards.first(where: { $0.id == id }),
              let target = CardDrop.target(zone, sections: sections) else { return false }
        if let move = CardDrop.move(card, to: target, cards: data.cards) { data.place(move) }
        return true
    }

    /// The drag ended without a drop here (released elsewhere, or Esc).
    public func endDrag() {
        dragging = nil
        dropTarget = nil
    }

    // MARK: Open and closed

    /// The surface opened: the search field does not take the keyboard
    /// (DESIGN.md, "Search field"); ⌘F moves there.
    func opened() {
        searchFocused = false
    }

    /// The popover closed, or the window lost the focus: a card's rows show
    /// the newest three again. The popover also drops its searches, its
    /// selected text and the Dismissed list.
    func closed(clearsSearch: Bool) {
        expandedRows = []
        if clearsSearch {
            showingDismissed = false
            clearSearches()
            textSelection?.clearSelection()
        }
        keepSelection()
    }

    /// The window closed: its searches and the Dismissed list go.
    func windowClosed() {
        showingDismissed = false
        clearSearches()
        textSelection?.clearSelection()
    }
}
