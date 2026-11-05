// What the app reaches outside itself, behind protocols so tests use fakes:
// the browser, macOS notifications, the login item and image downloads
// (docs/tasks/M3.md, "How to test"). The UI state kept in UserDefaults goes
// through `UIStateStore`, which tests give a suite of their own.

import Foundation

public protocol URLOpening: AnyObject {
    func open(_ url: URL)
}

public protocol NotificationPresenting: AnyObject {
    /// Ask once for permission to show notifications.
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

public protocol ImageLoading: AnyObject, Sendable {
    func load(_ url: URL) async throws -> Data
}

/// The UI state of DESIGN.md, "Saved state": the chips and the frame of each
/// scope's window.
public final class UIStateStore {
    private let defaults: UserDefaults
    static let chipsKey = "popover.chips"
    static let didApplyLaunchDefaultKey = "launchAtLogin.didApplyDefault"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var chips: Chips {
        get {
            guard let data = defaults.data(forKey: Self.chipsKey),
                  let chips = try? JSONDecoder().decode(Chips.self, from: data)
            else { return Chips() }
            return chips
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.chipsKey)
        }
    }

    /// The window frame as `NSStringFromRect` writes it.
    public func windowFrame(scope: String) -> String? {
        defaults.string(forKey: "window.frame." + scope)
    }

    public func setWindowFrame(_ frame: String, scope: String) {
        defaults.set(frame, forKey: "window.frame." + scope)
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

    public func syncConfig() async {
        let on = isOn
        if (try? await api.configGet(Self.configKey))?.boolValue != on {
            _ = try? await api.configSet(Self.configKey, .bool(on))
        }
    }
}

/// Author avatars, loaded once per URL and kept in memory. A failed or
/// pending load shows the empty circle.
@MainActor
public final class AvatarStore: ObservableObject {
    @Published public private(set) var images: [String: Data] = [:]
    private var loading: Set<String> = []
    private var failed: Set<String> = []
    private let loader: ImageLoading

    public init(loader: ImageLoading) {
        self.loader = loader
    }

    public func image(for url: String?) -> Data? {
        guard let url else { return nil }
        return images[url]
    }

    public func request(_ url: String?) {
        guard let url, images[url] == nil, !loading.contains(url), !failed.contains(url),
              let parsed = URL(string: url), parsed.scheme == "https" || parsed.scheme == "http"
        else { return }
        loading.insert(url)
        Task {
            do {
                let data = try await loader.load(parsed)
                images[url] = data
            } catch {
                failed.insert(url)
            }
            loading.remove(url)
        }
    }
}
