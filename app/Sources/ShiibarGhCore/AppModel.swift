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
    /// `snooze_return_time`, for "Snooze until Mon 09:00".
    @Published public private(set) var returnTime: String?
    /// The last request that failed, for the surface that made it.
    @Published public var lastError: String?

    public let api: DaemonAPI
    public let store: UIStateStore
    private let opener: URLOpening
    private let notifier: NotificationPresenting
    private let copier: LinkCopying?
    /// How long `account_changed` waits for more of its kind before the
    /// lists are read again: one read per burst (docs/tasks/M5.md, the
    /// request count of review A5).
    public let reloadDelay: TimeInterval
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
        copier: LinkCopying? = nil, reloadDelay: TimeInterval = 0.2,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.api = api
        self.store = store
        self.opener = opener
        self.notifier = notifier
        self.copier = copier
        self.reloadDelay = reloadDelay
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
                viewModels[account.id]?.scheduleReload()
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
        case SnoozeTime.configKey:
            returnTime = value?.stringValue
        default:
            break
        }
    }

    /// The settings the popovers use, at connection.
    public func loadConfig() async {
        for key in [TextSize.configKey, SnoozeTime.configKey] {
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

    /// The next Return time, for "Snooze until Mon 09:00".
    public func nextReturn(timeZone: TimeZone = .current) -> Int64 {
        SnoozeTime.next(returnTime, now: now, timeZone: timeZone)
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
    /// showing while another app has the focus). The window's search is
    /// cleared when it closes.
    /// `opening`: the surface opens right after (`surfaceOpened`), which
    /// reads the lists once `popover_opened` is answered, so nothing is read
    /// here before it.
    public func surfaceDisplayed(_ surface: Surface, account: String, _ shown: Bool, opening: Bool = false) {
        if shown {
            let first = displayed[account] == nil
            displayed[account, default: []].insert(surface)
            if first && !opening { viewModel(account).reload() }
            // A new window decides "+ N more PRs" with the list it reads.
            if surface == .window { viewModel(account).list(.window).opened() }
        } else if var set = displayed[account] {
            if surface == .window { viewModels[account]?.list(.window).clearSearch() }
            set.remove(surface)
            displayed[account] = set.isEmpty ? nil : set
        }
    }

    /// The popover opened, or the window got the focus. The popover decides
    /// "+ N more PRs" again with the list it reads now.
    public func surfaceOpened(_ surface: Surface, account: String) {
        if surfaces.isOpen(surface, account: account) { return }
        let first = surfaces.opened(surface, account: account)
        let model = viewModel(account)
        if surface == .popover { model.list(.popover).opened() }
        if first, let login = self.account(account)?.login {
            openThenReload(account, login: login)
        } else {
            model.reload()
        }
    }

    /// `popover_opened`, and only once it is answered the lists: the daemon
    /// keeps every card of a `list` answered after `popover_opened` until
    /// `popover_closed` (DESIGN.md, "When a card shows and leaves"), so the
    /// cards shown while open never leave under the user. The lists are
    /// read even when `popover_opened` fails.
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

    /// The popover closed, or the window closed or lost the focus: "+ N
    /// more PRs" is decided again; the popover's search is cleared. Rows
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

    /// The daemon side of a popover action. Section actions, reading and
    /// Mark all as read stay in the view model.
    func perform(_ action: PopoverAction, account id: String) {
        let login = account(id)?.login
        switch action {
        case .open(let url, _):
            open(url)
        case .copyLink(let url):
            copier?.copy(url)
        case .snooze(let pr):
            guard let login else { return }
            change(id) { try await $0.snooze(account: login, pr: pr) }
        case .unsnooze(let pr):
            guard let login else { return }
            change(id) { try await $0.unsnooze(account: login, pr: pr) }
        case .toggleSection, .expand, .markAllRead:
            break
        }
    }

    /// `read` for rows the user selected, opened or marked. `failed` runs
    /// when the daemon refused, so the view can drop its local marks.
    func read(_ rows: [String], failed: @escaping () -> Void) {
        guard !rows.isEmpty else { return }
        let api = self.api
        Task {
            do {
                try await api.read(rows)
            } catch {
                lastError = "\(error)"
                failed()
            }
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

/// One account's data, shared by its popover and its window: the daemon's
/// answers kept unfiltered, unread marks sent but not yet in a list, and
/// what is saved per account (the chip, Group by, the sort order, collapsed
/// sections, the Activity owner buttons, Keep on top). What each surface
/// shows is its `SurfaceListModel`.
@MainActor
public final class AccountViewModel: ObservableObject {
    public let accountId: String
    unowned let app: AppModel
    /// The unsnoozed cards as the daemon sent them.
    @Published public private(set) var cards: [Card] = []
    /// The snoozed cards as the daemon sent them.
    @Published public private(set) var snoozed: [Card] = []
    /// The Activity rows as the daemon sent them.
    @Published public private(set) var allActivity: [Row] = []
    @Published public private(set) var loaded = false
    @Published public var options: ListOptions {
        didSet {
            guard options != oldValue else { return }
            app.store.setOptions(options, account: accountId)
            lists.values.forEach { $0.keepSelection() }
        }
    }
    @Published public private(set) var collapsed: [String: Bool]
    @Published public private(set) var activityOwners: Set<String>
    /// Keep on top of the window, kept per account.
    @Published public private(set) var keepOnTop: Bool
    /// Rows sent as `read` that a list may still show unread: they show
    /// read until a list agrees.
    private var pendingRead: Set<String> = []
    private var reloads = 0
    private var scheduled: Task<Void, Never>?
    private var lists: [Surface: SurfaceListModel] = [:]

    init(account: String, app: AppModel) {
        accountId = account
        self.app = app
        options = app.store.options(account: account)
        collapsed = app.store.collapsed(account: account)
        activityOwners = app.store.activityOwners(account: account)
        keepOnTop = app.store.keepOnTop(account: account)
    }

    public var account: Account? { app.account(accountId) }

    /// The popover's or the window's own state: tab, search, selection and
    /// "+ N more PRs".
    public func list(_ surface: Surface) -> SurfaceListModel {
        if let list = lists[surface] { return list }
        let list = SurfaceListModel(data: self, surface: surface)
        lists[surface] = list
        return list
    }

    public var usage: ApiUsage { ApiUsage(account?.rateLimit) }

    // MARK: Activity owner buttons

    public var allOwnersOn: Bool {
        guard let account else { return true }
        return ActivityOwners.allOwnersOn(activityOwners, account: account)
    }

    public func isOwnerOn(_ owner: String) -> Bool {
        !allOwnersOn && activityOwners.contains(owner)
    }

    public func toggleOwner(_ owner: String) {
        if let account {
            // Removed and disabled owners do not count any more.
            activityOwners = ActivityOwners.effective(activityOwners, account: account)
        }
        if activityOwners.contains(owner) { activityOwners.remove(owner) } else { activityOwners.insert(owner) }
        app.store.setActivityOwners(activityOwners, account: accountId)
        lists.values.forEach { $0.keepSelection() }
    }

    /// `All owners` turns every owner button off.
    public func showAllOwners() {
        activityOwners = []
        app.store.setActivityOwners([], account: accountId)
        lists.values.forEach { $0.keepSelection() }
    }

    func setCollapsed(_ key: String, _ value: Bool) {
        collapsed[key] = value
        app.store.setCollapsed(collapsed, account: accountId)
        lists.values.forEach { $0.keepSelection() }
    }

    public func toggleKeepOnTop() {
        keepOnTop.toggle()
        app.store.setKeepOnTop(keepOnTop, account: accountId)
    }

    // MARK: Loading

    /// Read the lists again after a short wait, once for a burst of
    /// `account_changed`.
    public func scheduleReload() {
        scheduled?.cancel()
        let delay = app.reloadDelay
        scheduled = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    public func reload() {
        guard let account else { return }
        scheduled?.cancel()
        scheduled = nil
        reloads += 1
        let current = reloads
        let login = account.login
        let api = app.api
        Task {
            do {
                async let cards = api.list(ListQuery(account: login))
                async let snoozed = api.list(ListQuery(account: login, snoozed: true))
                async let rows = api.activity(ActivityQuery(account: login))
                let (newCards, newSnoozed, newRows) = try await (cards, snoozed, rows)
                guard current == reloads else { return }
                apply(cards: newCards, snoozed: newSnoozed, rows: newRows)
            } catch {
                guard current == reloads else { return }
                app.lastError = "\(error)"
            }
        }
    }

    func apply(cards newCards: [Card], snoozed newSnoozed: [Card], rows newRows: [Row]) {
        // A row the daemon shows read, or no longer has, needs no local mark.
        let unreadNow = Set((newCards + newSnoozed).flatMap(\.rows).filter(\.unread).map(\.id))
            .union(newRows.filter(\.unread).map(\.id))
        pendingRead.formIntersection(unreadNow)
        cards = Self.marked(newCards, read: pendingRead)
        snoozed = Self.marked(newSnoozed, read: pendingRead)
        allActivity = newRows.map { pendingRead.contains($0.id) ? Self.read($0) : $0 }
        loaded = true
        lists.values.forEach { $0.listArrived() }
    }

    static func read(_ row: Row) -> Row {
        var row = row
        row.unread = false
        return row
    }

    static func marked(_ cards: [Card], read ids: Set<String>) -> [Card] {
        guard !ids.isEmpty else { return cards }
        return cards.map { card in
            var card = card
            card.rows = card.rows.map { ids.contains($0.id) ? read($0) : $0 }
            return card
        }
    }

    // MARK: Reading

    func row(_ id: String) -> Row? {
        (cards + snoozed).lazy.flatMap(\.rows).first { $0.id == id } ?? allActivity.first { $0.id == id }
    }

    /// Show the rows read at once and send `read`; a refusal puts them back
    /// with the next list.
    func markRead(_ ids: [String]) {
        let fresh = ids.filter { row($0)?.unread ?? false }
        guard !fresh.isEmpty else { return }
        pendingRead.formUnion(fresh)
        let set = Set(fresh)
        cards = Self.marked(cards, read: set)
        snoozed = Self.marked(snoozed, read: set)
        allActivity = allActivity.map { set.contains($0.id) ? Self.read($0) : $0 }
        app.read(fresh) { [weak self] in
            self?.pendingRead.subtract(fresh)
            self?.reload()
        }
    }
}

/// What one surface (the popover or the window) of an account shows: its
/// tab, its search, its selection and its "+ N more PRs" (DESIGN.md: the
/// popover clears its search when it closes, the window when it closes).
/// The data and the saved choices come from the shared `AccountViewModel`.
@MainActor
public final class SurfaceListModel: ObservableObject {
    public let surface: Surface
    public unowned let data: AccountViewModel
    @Published public var tab: PopoverTab = .prs {
        didSet { keepSelection() }
    }
    /// The search of each tab. Not kept.
    @Published public private(set) var searches: [PopoverTab: String] = [:]
    /// Whether the search field has the keyboard.
    @Published public var searchFocused = false
    /// Sections whose "+ N more PRs" was opened. Not kept (DESIGN.md,
    /// "PRs tab sections").
    @Published public private(set) var expanded: Set<String> = []
    @Published public private(set) var fold = FoldState()
    @Published public private(set) var selection: SelectionItem?
    private var forward: AnyCancellable?

    init(data: AccountViewModel, surface: Surface) {
        self.data = data
        self.surface = surface
        forward = data.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var app: AppModel { data.app }

    // MARK: Derived lists

    public var search: String {
        get { searches[tab] ?? "" }
        set { searches[tab] = newValue }
    }

    public var sections: [SectionLayout] {
        guard let account = data.account else { return [] }
        return Listing.sections(
            account: account, cards: data.cards, snoozed: data.snoozed, options: data.options, search: searches[.prs] ?? "",
            collapsed: data.collapsed, expanded: expanded, fold: fold
        )
    }

    /// "Nothing needs you" or "Nothing matches" in place of the sections
    /// other than Snoozed.
    public var emptyText: String? {
        Listing.emptyText(loaded: data.loaded, cards: data.cards, options: data.options, search: searches[.prs] ?? "")
    }

    /// The Activity rows shown: owner buttons, chip and search applied.
    public var activity: [Row] {
        guard let account = data.account else { return [] }
        return Listing.activity(
            data.allActivity, cards: data.cards, segment: data.options.segment,
            owners: ActivityOwners.effective(data.activityOwners, account: account), search: searches[.activity] ?? ""
        )
    }

    public var activityEmptyText: String? {
        Listing.activityEmptyText(loaded: data.loaded, all: data.allActivity, shown: activity)
    }

    public var items: [SelectionItem] {
        PopoverLogic.items(tab: tab, sections: tab == .prs ? sections : [], activity: tab == .activity ? activity : [])
    }

    public var hints: [KeyHint] {
        PopoverLogic.hints(selection: selection, sections: sections, activity: activity)
    }

    /// The rows ⇧R and Mark all as read send.
    public var rowsToRead: [String] {
        Listing.rowsToRead(tab: tab, sections: tab == .prs ? sections : [], activity: tab == .activity ? activity : [])
    }

    func keepSelection() {
        selection = PopoverLogic.keep(selection, in: items)
    }

    /// A new list arrived.
    func listArrived() {
        fold.update(data.cards)
        keepSelection()
    }

    // MARK: Selection, keys and clicks

    /// Select an item: by ↑↓, a click or a right click. A row is read.
    public func select(_ item: SelectionItem?) {
        selection = item
        if case .row(let id, _)? = item { data.markRead([id]) }
        // Reading the row may take a PR out of the fold.
        fold.update(data.cards)
    }

    /// A double click: select it, then open it.
    public func doubleClick(_ item: SelectionItem) {
        select(item)
        if let action = PopoverLogic.action(for: .open, selection: item, sections: sections, activity: activity) {
            perform(action)
        }
    }

    /// The right-click menu of an item, after selecting (and reading) it.
    public func rightClick(_ item: SelectionItem) -> [MenuEntry?] {
        select(item)
        return PopoverLogic.menu(
            for: item, tab: tab, sections: sections, activity: activity, returnAt: app.nextReturn()
        )
    }

    /// A key while the surface has the focus and the search field does not.
    public func press(_ key: Key) {
        switch key {
        case .up, .down:
            select(PopoverLogic.move(selection, up: key == .up, in: items))
        case .find:
            searchFocused = true
        case .open, .snooze, .markAllRead:
            if let action = PopoverLogic.action(for: key, selection: selection, sections: sections, activity: activity) {
                perform(action)
            }
        }
    }

    /// Esc or ↓ in the search field (DESIGN.md, "Search field"): Esc clears
    /// the text, if any, and both go back to the list. The popover stays.
    public func leaveSearch(clearing: Bool) {
        if clearing { search = "" }
        searchFocused = false
    }

    public func setSearch(_ text: String) {
        search = text
        keepSelection()
    }

    func clearSearch() {
        searches = [:]
        searchFocused = false
        keepSelection()
    }

    public func perform(_ action: PopoverAction) {
        switch action {
        case .toggleSection(let key):
            let section = sections.first { $0.key == key }
            data.setCollapsed(Listing.collapseKey(data.options.groupBy, key), !(section?.collapsed ?? false))
        case .expand(let key):
            expanded.insert(key)
            if selection == .more(key) {
                selection = sections.first { $0.key == key }?.showsHeader == true ? .section(key) : nil
            }
        case .markAllRead:
            data.markRead(rowsToRead)
        case .open(_, let row):
            if let row { data.markRead([row]) }
            app.perform(action, account: data.accountId)
        default:
            app.perform(action, account: data.accountId)
        }
    }

    // MARK: Open and closed

    /// The surface opened: "+ N more PRs" is decided with the next list,
    /// and the search field does not take the keyboard (DESIGN.md, "Search
    /// field"); ⌘F moves there.
    func opened() {
        fold.decideOnNextList()
        searchFocused = false
    }

    /// The popover closed or the window lost the focus: "+ N more PRs" is
    /// decided again and folds again; the popover's search is cleared.
    func closed(clearsSearch: Bool) {
        fold.decide(data.cards)
        expanded = []
        if clearsSearch { clearSearch() }
    }
}
