// Settings without a screen: the values Settings shows and what its
// controls send (docs/design/Settings.html). Values go through `config_get`
// and `config_set`, scopes through `scope_*`, tokens through `token_set` and
// `token_test`. `settings_status` is read again while the window is open and
// on every `scope_changed`, because the daemon does not push it. A value the
// daemon refuses is not kept: the error shows and the saved value returns.
// A pasted token is handed to `token_set` on Save and not kept.

import Foundation

public enum SettingsTab: String, CaseIterable {
    case general = "General", scopes = "Scopes", notifications = "Notifications", watching = "Watching"
}

@MainActor
public final class SettingsModel: ObservableObject {
    public let app: AppModel
    public let launch: LaunchAtLogin?
    @Published public var tab: SettingsTab = .general
    @Published public var status = SettingsStatus()
    @Published public var config: [String: ConfigValue] = [:]
    @Published public var errors: [String: String] = [:]
    @Published public var launchOn = false
    @Published public var launchStatus: LoginItemStatus = .notRegistered
    /// Token targets showing the paste field.
    @Published public var entering: Set<String> = []
    /// Token targets with a test running.
    @Published public var testing: Set<String> = []
    /// The owner type picked when a scope was added, for its Create token.
    public var addedTypes: [String: OwnerType] = [:]
    private var timer: Timer?

    public static let keys = [
        "launch_at_login", "status_interval_minutes", "reactions_interval_minutes", "graphql_cost_cap",
        "notify_activity", "notify_state", "notify_reactions", "snooze_return_time", "bot_comments",
        "include_team_requests", "keep_watching_days", "drop_after_days",
    ]

    public init(app: AppModel, launch: LaunchAtLogin?) {
        self.app = app
        self.launch = launch
        app.onScopesChanged = { [weak self] in
            guard let self, self.isOpen else { return }
            self.reloadStatus()
        }
    }

    public func windowOpened() {
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadStatus() }
        }
    }

    public func windowClosed() {
        timer?.invalidate()
        timer = nil
    }

    public var isOpen: Bool { timer != nil }

    public func reload() {
        reloadStatus()
        refreshLaunch()
        let api = app.api
        Task {
            for key in Self.keys {
                if let value = try? await api.configGet(key) {
                    config[key] = value
                }
            }
        }
    }

    public func reloadStatus() {
        let api = app.api
        Task {
            if let status = try? await api.settingsStatus() {
                self.status = status
            }
        }
    }

    public func refreshLaunch() {
        guard let launch else { return }
        launchStatus = launch.status
        launchOn = launch.isOn
    }

    public func setLaunch(_ on: Bool) {
        guard let launch else { return }
        Task {
            do {
                try await launch.set(on)
                errors["launch_at_login"] = nil
            } catch {
                errors["launch_at_login"] = "\(error.localizedDescription)"
            }
            refreshLaunch()
        }
    }

    /// Save a value; an invalid one is refused by the daemon and the field
    /// returns to the saved value with the error under it.
    public func set(_ key: String, _ value: ConfigValue) {
        let api = app.api
        Task {
            do {
                config[key] = try await api.configSet(key, value)
                errors[key] = nil
            } catch {
                errors[key] = "\(error)"
                if let saved = try? await api.configGet(key) { config[key] = saved }
            }
        }
    }

    public func token(_ target: String) -> TokenStatus? {
        status.tokens.first { $0.target.caseInsensitiveCompare(target) == .orderedSame }
    }

    public func saveToken(_ target: String, _ token: String, done: @escaping (Bool) -> Void) {
        let api = app.api
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                try await api.tokenSet(target, token: trimmed)
                errors["token:" + target] = nil
                entering.remove(target)
                done(true)
                test(target)
            } catch {
                errors["token:" + target] = "\(error)"
                done(false)
            }
        }
    }

    public func test(_ target: String) {
        let api = app.api
        testing.insert(target)
        Task {
            do {
                _ = try await api.tokenTest(target)
                errors["test:" + target] = nil
            } catch {
                errors["test:" + target] = "\(error)"
            }
            testing.remove(target)
            reloadStatus()
        }
    }

    public func addScope(owner: String, type: OwnerType, done: @escaping (String?) -> Void) {
        let api = app.api
        let name = type == .public ? "public" : owner.trimmingCharacters(in: .whitespaces)
        let before = Set(app.scopes.map(\.id))
        Task {
            do {
                let scopes = try await api.scopeAdd(name)
                errors["add"] = nil
                // The new scope is the one that was not there: its id is
                // opaque and not compared with the login typed in.
                guard let added = scopes.first(where: { !before.contains($0.id) })?.id else {
                    reloadStatus()
                    done(nil)
                    return
                }
                addedTypes[added] = type
                entering.insert(added)
                reloadStatus()
                done(added)
            } catch {
                errors["add"] = "\(error)"
                done(nil)
            }
        }
    }

    public func removeScope(_ id: String) {
        let api = app.api
        Task {
            do {
                _ = try await api.scopeRemove(id)
                errors["scope:" + id] = nil
            } catch {
                errors["scope:" + id] = "\(error)"
            }
            reloadStatus()
        }
    }

    public func scopeRequest(_ id: String, _ request: @escaping (DaemonAPI) async throws -> Void) {
        let api = app.api
        Task {
            do {
                try await request(api)
                errors["scope:" + id] = nil
            } catch {
                errors["scope:" + id] = "\(error)"
            }
        }
    }
}

