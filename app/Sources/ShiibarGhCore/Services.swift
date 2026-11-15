// What the app reaches outside itself, behind protocols so tests use fakes:
// the browser, macOS notifications, the login item and image downloads
// (docs/tasks/M3.md, "How to test"). The UI state kept in UserDefaults goes
// through `UIStateStore`, which tests give a suite of their own.

import Foundation

public protocol URLOpening: AnyObject {
    func open(_ url: URL)
}

public protocol NotificationPresenting: AnyObject {
    /// Ask for permission to show notifications. macOS prompts the first
    /// time only (UNUserNotificationCenter.requestAuthorization).
    func requestAuthorization()
    /// Show it now. Nothing is kept for later (DESIGN.md, "macOS
    /// notifications").
    func present(_ notification: DaemonNotification)
}

public enum LoginItemStatus: Equatable {
    case notRegistered, enabled, requiresApproval, notFound
}

public protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// Copy link: the text goes to the general pasteboard in the app.
public protocol LinkCopying: AnyObject {
    func copy(_ text: String)
}

public protocol ImageLoading: AnyObject, Sendable {
    func load(_ url: URL) async throws -> Data
}

/// The UI state of DESIGN.md, "Saved state", per account: the last tab of
/// the popover and of the window, Group by, Then by and the sort order, the
/// group orders, the collapsed sections and the expanded "+ N more PRs" (by
/// section key), the expanded "+ N more" of the cards (by card id), the
/// expanded row bodies (by row id), the Filter of each tab and whether it
/// is open (per tab), the search text of each tab and of the Dismissed list, Compact,
/// the repositories seen, the window frame and Keep on top.
/// Keys carry the account id (the GitHub user id, numeric, as a string,
/// which does not change with the login). The selection, the scroll
/// positions and whether the Dismissed list is open are not kept.
///
/// Every key starts with `v4.`: 0.4 reads none of the UI state of 0.3 and
/// earlier (DESIGN.md, "Updating from 0.3 and 0.2"), whose keys had no
/// prefix and stay unread. 0.5 reads 0.4's keys as they are and adds seven
/// (`expandedRows.`, `expandedBodies.`, `filters.`, `filtersOpen.`,
/// `searches.`, `compact.`, `popover.height.`), which start from their
/// defaults: nothing expanded, the default Filter closed, no search text,
/// Compact off, the popover's default height ("Updating from 0.4").
public final class UIStateStore {
    private let defaults: UserDefaults
    static let prefix = "v4."
    static let optionsKey = prefix + "options."
    static let groupOrdersKey = prefix + "groupOrders."
    static let repositoriesKey = prefix + "repositories."
    static let collapsedKey = prefix + "collapsed."
    static let expandedKey = prefix + "expanded."
    static let expandedRowsKey = prefix + "expandedRows."
    static let expandedBodiesKey = prefix + "expandedBodies."
    static let filtersKey = prefix + "filters."
    /// The tabs whose `Filter` is open. (`filterOpen.`, one value for the
    /// tabs, was never released and is not read.)
    static let filtersOpenKey = prefix + "filtersOpen."
    static let searchesKey = prefix + "searches."
    static let compactKey = prefix + "compact."
    static let popoverHeightKey = prefix + "popover.height."
    static let tabKey = prefix + "tab."
    static let windowFrameKey = prefix + "window.frame."
    static let keepOnTopKey = prefix + "window.keepOnTop."
    /// Not UI state: whether the Launch at login default was applied once.
    /// Kept from 0.3 so an update does not register the login item again.
    static let didApplyLaunchDefaultKey = "launchAtLogin.didApplyDefault"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func options(account: String) -> ListOptions {
        guard let data = defaults.data(forKey: Self.optionsKey + account),
              let options = try? JSONDecoder().decode(ListOptions.self, from: data)
        else { return ListOptions() }
        return options
    }

    public func setOptions(_ options: ListOptions, account: String) {
        defaults.set(try? JSONEncoder().encode(options), forKey: Self.optionsKey + account)
    }

    public func groupOrders(account: String) -> GroupOrders {
        guard let saved = defaults.dictionary(forKey: Self.groupOrdersKey + account) as? [String: [String]] else { return [:] }
        var out: GroupOrders = [:]
        for (key, order) in saved {
            if let by = GroupBy(rawValue: key) { out[by] = order }
        }
        return out
    }

    public func setGroupOrders(_ orders: GroupOrders, account: String) {
        var saved: [String: [String]] = [:]
        for (by, order) in orders { saved[by.rawValue] = order }
        defaults.set(saved, forKey: Self.groupOrdersKey + account)
    }

    /// The repositories that have had cards, in the order they came.
    public func repositories(account: String) -> [String] {
        defaults.stringArray(forKey: Self.repositoriesKey + account) ?? []
    }

    public func setRepositories(_ names: [String], account: String) {
        defaults.set(names, forKey: Self.repositoriesKey + account)
    }

    public func collapsed(account: String) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.collapsedKey + account) ?? [])
    }

    public func setCollapsed(_ keys: Set<String>, account: String) {
        defaults.set(keys.sorted(), forKey: Self.collapsedKey + account)
    }

    public func expanded(account: String) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.expandedKey + account) ?? [])
    }

    public func setExpanded(_ keys: Set<String>, account: String) {
        defaults.set(keys.sorted(), forKey: Self.expandedKey + account)
    }

    /// Cards whose rows show past the newest three, by card id.
    public func expandedRows(account: String) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.expandedRowsKey + account) ?? [])
    }

    public func setExpandedRows(_ cards: Set<String>, account: String) {
        defaults.set(cards.sorted(), forKey: Self.expandedRowsKey + account)
    }

    /// Rows whose body shows up to 5 lines (`more`), by row id.
    public func expandedBodies(account: String) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.expandedBodiesKey + account) ?? [])
    }

    public func setExpandedBodies(_ rows: Set<String>, account: String) {
        defaults.set(rows.sorted(), forKey: Self.expandedBodiesKey + account)
    }

    /// The Filter of All, Review and Mine (DESIGN.md, "Filter"): the
    /// defaults for an account with none saved.
    public func filters(account: String) -> [ListTab: ListFilter] {
        var saved: [String: ListFilter] = [:]
        if let data = defaults.data(forKey: Self.filtersKey + account),
           let decoded = try? JSONDecoder().decode([String: ListFilter].self, from: data) {
            saved = decoded
        }
        var out: [ListTab: ListFilter] = [:]
        for tab in ListTab.allCases { out[tab] = saved[tab.rawValue] ?? ListFilter() }
        return out
    }

    public func setFilters(_ filters: [ListTab: ListFilter], account: String) {
        var saved: [String: ListFilter] = [:]
        for (tab, filter) in filters { saved[tab.rawValue] = filter }
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.filtersKey + account)
    }

    /// The tabs whose `Filter` is open (DESIGN.md, "Filter"): each closed
    /// unless opened; one value per tab for the popover and the window.
    public func filtersOpen(account: String) -> Set<ListTab> {
        Set((defaults.stringArray(forKey: Self.filtersOpenKey + account) ?? []).compactMap(ListTab.init(rawValue:)))
    }

    public func setFiltersOpen(_ tabs: Set<ListTab>, account: String) {
        defaults.set(tabs.map(\.rawValue).sorted(), forKey: Self.filtersOpenKey + account)
    }

    /// The search text of each tab and of the Dismissed list (DESIGN.md,
    /// "Search field"): none saved reads as empty.
    public func searches(account: String) -> [SearchScope: String] {
        guard let saved = defaults.dictionary(forKey: Self.searchesKey + account) as? [String: String] else { return [:] }
        var out: [SearchScope: String] = [:]
        for (key, text) in saved where !text.isEmpty {
            if let scope = SearchScope(key: key) { out[scope] = text }
        }
        return out
    }

    public func setSearches(_ searches: [SearchScope: String], account: String) {
        var saved: [String: String] = [:]
        for (scope, text) in searches where !text.isEmpty { saved[scope.key] = text }
        defaults.set(saved, forKey: Self.searchesKey + account)
    }

    /// Compact: off unless turned on.
    public func compact(account: String) -> Bool {
        defaults.object(forKey: Self.compactKey + account) as? Bool ?? false
    }

    public func setCompact(_ on: Bool, account: String) {
        defaults.set(on, forKey: Self.compactKey + account)
    }

    /// The popover's height set by dragging its bottom edge, in points; nil
    /// until it is dragged.
    public func popoverHeight(account: String) -> Double? {
        defaults.object(forKey: Self.popoverHeightKey + account) as? Double
    }

    public func setPopoverHeight(_ height: Double, account: String) {
        defaults.set(height, forKey: Self.popoverHeightKey + account)
    }

    /// The tab the popover or the window showed last; All at first.
    public func lastTab(account: String, surface: Surface) -> ListTab {
        defaults.string(forKey: Self.tabKey + surface.rawValue + "." + account).flatMap(ListTab.init(rawValue:)) ?? .all
    }

    public func setLastTab(_ tab: ListTab, account: String, surface: Surface) {
        defaults.set(tab.rawValue, forKey: Self.tabKey + surface.rawValue + "." + account)
    }

    /// The window frame as `NSStringFromRect` writes it.
    public func windowFrame(account: String) -> String? {
        defaults.string(forKey: Self.windowFrameKey + account)
    }

    public func setWindowFrame(_ frame: String, account: String) {
        defaults.set(frame, forKey: Self.windowFrameKey + account)
    }

    /// Keep on top of the account's window: on unless turned off.
    public func keepOnTop(account: String) -> Bool {
        defaults.object(forKey: Self.keepOnTopKey + account) as? Bool ?? true
    }

    public func setKeepOnTop(_ on: Bool, account: String) {
        defaults.set(on, forKey: Self.keepOnTopKey + account)
    }

    public var didApplyLaunchDefault: Bool {
        get { defaults.bool(forKey: Self.didApplyLaunchDefaultKey) }
        set { defaults.set(newValue, forKey: Self.didApplyLaunchDefaultKey) }
    }
}

/// Launch at login follows SMAppService: its status is what Settings shows,
/// and the daemon's `launch_at_login` follows it (docs/tasks/M3.md,
/// "Settings"). The default of DESIGN.md, "Settings" (on) is applied once,
/// on the first launch from an app bundle; after that only the user's
/// choice registers or unregisters.
@MainActor
public final class LaunchAtLogin {
    public static let configKey = "launch_at_login"
    private let service: LoginItemService
    private let api: DaemonAPI
    private let store: UIStateStore

    public init(service: LoginItemService, api: DaemonAPI, store: UIStateStore) {
        self.service = service
        self.api = api
        self.store = store
    }

    public static func isOn(_ status: LoginItemStatus) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    public var status: LoginItemStatus { service.status }

    public var isOn: Bool { Self.isOn(service.status) }

    /// At launch: apply the default once, then make the setting follow.
    public func applyAtLaunch(runningFromBundle: Bool) async {
        if runningFromBundle && !store.didApplyLaunchDefault {
            store.didApplyLaunchDefault = true
            let wanted = (try? await api.configGet(Self.configKey))?.boolValue ?? true
            if wanted && service.status == .notRegistered {
                try? service.register()
            }
        }
        await syncConfig()
    }

    /// The user's choice in Settings.
    public func set(_ on: Bool) async throws {
        defer { Task { await self.syncConfig() } }
        if on {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    /// `launch_at_login` changed, from Settings, the CLI or any client: the
    /// login item follows the change made last (DESIGN.md, "Launch at login
    /// sync"). If macOS refuses, the setting goes back to what macOS has.
    /// Called once the login item may have changed: after a change made
    /// here and after a sync, so Settings shows the status macOS now has.
    public var onStatusChange: (() -> Void)?

    public func configChanged(key: String, value: ConfigValue) async {
        guard key == Self.configKey, let wanted = value.boolValue, wanted != isOn else { return }
        defer { onStatusChange?() }
        do {
            if wanted {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("shiibar-gh: cannot change the login item: %@", String(describing: error))
        }
        await syncConfig()
    }

    /// The login item as macOS has it goes to the setting: at launch, when
    /// Settings opens, and after a change.
    public func syncConfig() async {
        defer { onStatusChange?() }
        let on = isOn
        if (try? await api.configGet(Self.configKey))?.boolValue != on {
            _ = try? await api.configSet(Self.configKey, .bool(on))
        }
    }
}

/// Author avatars, loaded once per URL and kept in memory. A pending load
/// shows the empty circle; a failed one too, and is tried again once
/// `retryAfter` seconds have passed. Only `https` URLs are loaded.
@MainActor
public final class AvatarStore: ObservableObject {
    @Published public private(set) var images: [String: Data] = [:]
    private var loading: Set<String> = []
    private var failedAt: [String: Date] = [:]
    private let loader: ImageLoading
    private let clock: () -> Date
    public let retryAfter: TimeInterval
    /// The URL schemes loaded: https only, except in the measurement mode,
    /// which reads files.
    private let schemes: Set<String>

    public init(
        loader: ImageLoading, schemes: Set<String> = ["https"], retryAfter: TimeInterval = 300,
        clock: @escaping () -> Date = Date.init
    ) {
        self.loader = loader
        self.schemes = schemes
        self.retryAfter = retryAfter
        self.clock = clock
    }

    public func image(for url: String?) -> Data? {
        guard let url else { return nil }
        return images[url]
    }

    public func request(_ url: String?) {
        guard let url, images[url] == nil, !loading.contains(url),
              let parsed = URL(string: url), let scheme = parsed.scheme, schemes.contains(scheme)
        else { return }
        if let failed = failedAt[url], clock().timeIntervalSince(failed) < retryAfter { return }
        loading.insert(url)
        Task {
            do {
                let data = try await loader.load(parsed)
                images[url] = data
                failedAt[url] = nil
            } catch {
                failedAt[url] = clock()
            }
            loading.remove(url)
        }
    }
}

/// Appearance in Settings (DESIGN.md, "Settings" and "UI"): System follows
/// the Mac, Light and Dark fix it. Kept by the daemon as `appearance`.
public enum AppAppearance: String, Equatable, CaseIterable {
    case system, light, dark

    public static let configKey = "appearance"

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// An unknown or missing value follows the Mac.
    public init(_ value: ConfigValue?) {
        self = value?.stringValue.flatMap(AppAppearance.init(rawValue:)) ?? .system
    }
}

/// Applies the appearance at connection and on every `config_changed`.
@MainActor
public final class AppearanceFollower {
    private let api: DaemonAPI
    private let apply: (AppAppearance) -> Void
    public private(set) var current: AppAppearance = .system

    public init(app: AppModel, apply: @escaping (AppAppearance) -> Void) {
        self.api = app.api
        self.apply = apply
        app.observeConfig { [weak self] key, value in
            guard key == AppAppearance.configKey else { return }
            self?.set(AppAppearance(value))
        }
    }

    /// Read the saved value, at start and after a reconnect.
    public func load() async {
        set(AppAppearance(try? await api.configGet(AppAppearance.configKey)))
    }

    private func set(_ appearance: AppAppearance) {
        current = appearance
        apply(appearance)
    }
}
