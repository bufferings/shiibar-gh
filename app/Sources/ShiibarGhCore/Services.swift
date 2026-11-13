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
/// section key), the repositories seen, the window frame and Keep on top.
/// Keys carry the account id (the GitHub user id, numeric, as a string,
/// which does not change with the login). The search, the selected text and
/// whether the Dismissed list is open are not kept.
///
/// Every key starts with `v4.`: 0.4 reads none of the UI state of 0.3 and
/// earlier (DESIGN.md, "Updating from 0.3 and 0.2"), whose keys had no
/// prefix and stay unread.
public final class UIStateStore {
    private let defaults: UserDefaults
    static let prefix = "v4."
    static let optionsKey = prefix + "options."
    static let groupOrdersKey = prefix + "groupOrders."
    static let repositoriesKey = prefix + "repositories."
    static let collapsedKey = prefix + "collapsed."
    static let expandedKey = prefix + "expanded."
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

    public init(loader: ImageLoading, retryAfter: TimeInterval = 300, clock: @escaping () -> Date = Date.init) {
        self.loader = loader
        self.retryAfter = retryAfter
        self.clock = clock
    }

    public func image(for url: String?) -> Data? {
        guard let url else { return nil }
        return images[url]
    }

    public func request(_ url: String?) {
        guard let url, images[url] == nil, !loading.contains(url),
              let parsed = URL(string: url), parsed.scheme == "https"
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
