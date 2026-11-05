// The Settings window: General, Scopes, Notifications and Watching
// (docs/design/Settings.html). Values go through `config_get` and
// `config_set`, scopes through `scope_*`, tokens through `token_set` and
// `token_test`; what Settings shows comes from `settings_status`, read again
// while the window is open and on every `scope_changed`. A pasted token is
// handed to `token_set` on Save and dropped.

import AppKit
import ShiibarGhCore
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general = "General", scopes = "Scopes", notifications = "Notifications", watching = "Watching"
}

@MainActor
final class SettingsModel: ObservableObject {
    let app: AppModel
    let launch: LaunchAtLogin?
    @Published var tab: SettingsTab = .general
    @Published var status = SettingsStatus()
    @Published var config: [String: ConfigValue] = [:]
    @Published var errors: [String: String] = [:]
    @Published var launchOn = false
    @Published var launchStatus: LoginItemStatus = .notRegistered
    /// Token targets showing the paste field.
    @Published var entering: Set<String> = []
    /// Token targets with a test running.
    @Published var testing: Set<String> = []
    /// The owner type picked when a scope was added, for its Create token.
    var addedTypes: [String: OwnerType] = [:]
    private var timer: Timer?

    static let keys = [
        "launch_at_login", "status_interval_minutes", "reactions_interval_minutes", "graphql_cost_cap",
        "notify_activity", "notify_state", "notify_reactions", "snooze_return_time", "bot_comments",
        "include_team_requests", "keep_watching_days", "drop_after_days",
    ]

    init(app: AppModel, launch: LaunchAtLogin?) {
        self.app = app
        self.launch = launch
    }

    func windowOpened() {
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadStatus() }
        }
    }

    func windowClosed() {
        timer?.invalidate()
        timer = nil
    }

    var isOpen: Bool { timer != nil }

    func reload() {
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

    func reloadStatus() {
        let api = app.api
        Task {
            if let status = try? await api.settingsStatus() {
                self.status = status
            }
        }
    }

    func refreshLaunch() {
        guard let launch else { return }
        launchStatus = launch.status
        launchOn = launch.isOn
    }

    func setLaunch(_ on: Bool) {
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
    func set(_ key: String, _ value: ConfigValue) {
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

    func token(_ target: String) -> TokenStatus? {
        status.tokens.first { $0.target.caseInsensitiveCompare(target) == .orderedSame }
    }

    func saveToken(_ target: String, _ token: String, done: @escaping (Bool) -> Void) {
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

    func test(_ target: String) {
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

    func addScope(owner: String, type: OwnerType, done: @escaping (String?) -> Void) {
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

    func removeScope(_ id: String) {
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

    func scopeRequest(_ id: String, _ request: @escaping (DaemonAPI) async throws -> Void) {
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

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    TabButton(tab: tab, selected: model.tab == tab) { model.tab = tab }
                }
            }
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .frame(maxWidth: .infinity)
            .background(Color(.sRGB, red: 0.929, green: 0.929, blue: 0.941))
            .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.84)).frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if app.dbUnreadable {
                        Group {
                            GroupBox2 {
                                Item {
                                    Text(EmptyState.unreadable).frame(maxWidth: .infinity, alignment: .leading)
                                    SettingsButton(title: "Reset") { app.reset() }
                                }
                            }
                        }
                    } else {
                        switch model.tab {
                        case .general: GeneralTab(model: model)
                        case .scopes: ScopesTab(model: model, app: app)
                        case .notifications: NotificationsTab(model: model)
                        case .watching: WatchingTab(model: model)
                        }
                    }
                }
                .padding(EdgeInsets(top: 18, leading: 28, bottom: 24, trailing: 28))
            }
        }
        .frame(minWidth: 720, minHeight: 600)
        .background(Color(.sRGB, red: 0.965, green: 0.965, blue: 0.969))
        .foregroundColor(Palette.text.color)
        .font(.system(size: 13))
    }
}

struct TabButton: View {
    var tab: SettingsTab
    var selected: Bool
    var action: () -> Void

    var icon: BoardIcon {
        switch tab {
        case .general: return BoardIcons.gear
        case .scopes: return BoardIcon([.circle(cx: 5.5, cy: 8, r: 3, dash: nil), .path("M8.5 8h6M12.5 8v2.5M14.5 8v2")], lineWidth: 1.3)
        case .notifications: return BoardIcon([.path("M4 11V7a4 4 0 0 1 8 0v4l1.5 1.5h-11z"), .path("M6.5 14h3")], lineWidth: 1.3, roundJoins: true)
        case .watching: return BoardIcon([.circle(cx: 7, cy: 7, r: 4.5, dash: nil), .path("M10.5 10.5l3.5 3.5")], lineWidth: 1.3)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                if tab == .notifications {
                    Image(systemName: "bell").font(.system(size: 14))
                } else {
                    IconView(icon: icon, size: 18, color: selected ? Color(.sRGB, red: 0.04, green: 0.31, blue: 0.65) : Color(white: 0.23))
                }
                Text(tab.rawValue).font(.system(size: 11))
            }
            .foregroundColor(selected ? Color(.sRGB, red: 0.04, green: 0.31, blue: 0.65) : Color(white: 0.23))
            .frame(minWidth: 72)
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color(.sRGB, red: 0.863, green: 0.906, blue: 0.969) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// `.gh` and `.group` of the board.
struct Section2<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Color(white: 0.23)).padding(.leading, 4)
            GroupBox2 { content }
        }
    }
}

struct GroupBox2<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.89), lineWidth: 1))
    }
}

/// `.item` of the board: a row with a top border except the first.
struct Item<Content: View>: View {
    var first = false
    var vertical = false
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if vertical {
                VStack(alignment: .leading, spacing: 6) { content }
            } else {
                HStack(spacing: 12) { content }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Color(white: 0.926)).frame(height: 1) }
        }
    }
}

struct Label2: View {
    var title: String
    var sub: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let sub { Text(sub).font(.system(size: 11)).foregroundColor(Palette.secondary.color) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ErrorText: View {
    var text: String?

    var body: some View {
        if let text {
            Text(text).font(.system(size: 11)).foregroundColor(Palette.orangeText.color)
        }
    }
}

/// A number field saved on Return or when it loses the focus.
struct NumberField: View {
    var key: String
    var unit: String
    var width: CGFloat = 64
    @ObservedObject var model: SettingsModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            Text(unit).font(.system(size: 12)).foregroundColor(Palette.secondary.color).frame(minWidth: 44, alignment: .leading)
        }
        .onAppear { text = model.config[key]?.intValue.map(String.init) ?? "" }
        .onChange(of: model.config[key]) { _, value in text = value?.intValue.map(String.init) ?? "" }
    }

    func commit() {
        guard let number = Int64(text.trimmingCharacters(in: .whitespaces)) else {
            model.errors[key] = "Enter a whole number"
            text = model.config[key]?.intValue.map(String.init) ?? ""
            return
        }
        if model.config[key]?.intValue != number {
            model.set(key, .int(number))
        }
    }
}

struct ToggleItem: View {
    var key: String
    var title: String
    var sub: String?
    var first = false
    @ObservedObject var model: SettingsModel

    var body: some View {
        Item(first: first) {
            VStack(alignment: .leading, spacing: 2) {
                Label2(title: title, sub: sub)
                ErrorText(text: model.errors[key])
            }
            Toggle("", isOn: Binding(
                get: { model.config[key]?.boolValue ?? false },
                set: { model.set(key, .bool($0)) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
        }
    }
}

struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    func numberText(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    var body: some View {
        let usage = model.status.apiUsage
        Section2(title: "Startup") {
            Item(first: true) {
                VStack(alignment: .leading, spacing: 2) {
                    Label2(title: "Launch at login", sub: "Runs in the menu bar after you log in to your Mac")
                    if model.launchStatus == .requiresApproval {
                        HStack(spacing: 6) {
                            Text("Allow shiibar-gh in System Settings › General › Login Items")
                                .font(.system(size: 11)).foregroundColor(Palette.caution.color)
                            Button("Open Login Items") { model.launch?.openSystemSettingsLoginItems() }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Palette.link.color)
                        }
                    }
                    ErrorText(text: model.errors["launch_at_login"])
                }
                Toggle("", isOn: Binding(get: { model.launchOn }, set: { model.setLaunch($0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
        }
        Section2(title: "Polling") {
            Item(first: true) {
                Label2(title: "Notifications API interval", sub: "Follows the interval GitHub specifies")
                Text(usage.notificationsPollInterval.map { "\($0) sec" } ?? "—")
                    .font(.system(size: 12)).foregroundColor(Palette.secondary.color).frame(minWidth: 44, alignment: .leading)
            }
            numberItem("status_interval_minutes", "PR status interval", "Shorter means you notice sooner, but uses more API quota", "min")
            numberItem("reactions_interval_minutes", "Reactions interval", "Shorter means you notice sooner, but uses more API quota", "min")
            numberItem("graphql_cost_cap", "GraphQL cost cap (last hour)", "Warns at 80% of the cap. At the cap, polling stops until the shown resume time", "points", width: 80)
        }
        Section2(title: "API usage") {
            Item(first: true) {
                Label2(title: "REST remaining")
                Text("\(numberText(usage.restRemaining)) / \(numberText(usage.restLimit))")
            }
            Item {
                Label2(title: "GraphQL remaining", sub: "Shared with your other tools")
                Text("\(numberText(usage.graphqlRemaining)) / \(numberText(usage.graphqlLimit))")
            }
            Item {
                Label2(title: "Cost per poll")
                Text(numberText(usage.costPerPoll))
            }
        }
    }

    func numberItem(_ key: String, _ title: String, _ sub: String, _ unit: String, width: CGFloat = 64) -> some View {
        Item {
            VStack(alignment: .leading, spacing: 2) {
                Label2(title: title, sub: sub)
                ErrorText(text: model.errors[key])
            }
            NumberField(key: key, unit: unit, width: width, model: model)
        }
    }
}

struct NotificationsTab: View {
    @ObservedObject var model: SettingsModel
    @State private var returnTime = Date()

    var body: some View {
        Section2(title: "macOS notifications") {
            ToggleItem(key: "notify_activity", title: "Review requests, mentions, comments on my PRs, and replies in threads I commented in or was mentioned in", first: true, model: model)
            ToggleItem(key: "notify_state", title: "State changes on my PRs", sub: "Checks failed, conflicts, changes requested, removed from merge queue, mergeable", model: model)
            ToggleItem(key: "notify_reactions", title: "Reactions to my comments", sub: "Reactions on the same comment are grouped into one", model: model)
        }
        Section2(title: "Snooze") {
            Item(first: true) {
                VStack(alignment: .leading, spacing: 2) {
                    Label2(title: "Return time", sub: "All snoozed PRs come back every day at this time")
                    ErrorText(text: model.errors["snooze_return_time"])
                }
                DatePicker("", selection: Binding(
                    get: { Self.date(model.config["snooze_return_time"]?.stringValue) },
                    set: { model.set("snooze_return_time", .string(Self.text($0))) }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .frame(width: 90)
            }
        }
        Section2(title: "Bot comments") {
            Item(first: true) {
                VStack(alignment: .leading, spacing: 2) {
                    Label2(title: "Comments written by bots (CI, coverage, etc.)", sub: "\u{201C}List only\u{201D} shows them in the list without a notification")
                    ErrorText(text: model.errors["bot_comments"])
                }
                Picker("", selection: Binding(
                    get: { model.config["bot_comments"]?.stringValue ?? "list_only" },
                    set: { model.set("bot_comments", .string($0)) }
                )) {
                    Text("Notify").tag("notify")
                    Text("List only").tag("list_only")
                    Text("Hide").tag("hide")
                }
                .labelsHidden()
                .frame(width: 140)
            }
        }
        Text("Types you turn off still appear in the list. macOS settings such as Focus still apply.")
            .font(.system(size: 11)).foregroundColor(Palette.secondary.color).padding(.horizontal, 4)
    }

    /// `HH:MM` as a time today, in a fixed calendar so the picker shows it.
    static func date(_ text: String?) -> Date {
        let parts = (text ?? "09:00").split(separator: ":").compactMap { Int($0) }
        var components = DateComponents()
        components.hour = parts.first ?? 9
        components.minute = parts.count > 1 ? parts[1] : 0
        return Calendar.current.date(from: components) ?? Date()
    }

    static func text(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

struct WatchingTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section2(title: "Review requests") {
            ToggleItem(key: "include_team_requests", title: "Include requests to my teams", sub: "When off, only requests addressed to me are shown", first: true, model: model)
        }
        Section2(title: "Reaction watching") {
            Item(first: true) {
                VStack(alignment: .leading, spacing: 2) {
                    Label2(title: "Days to keep watching after close")
                    ErrorText(text: model.errors["keep_watching_days"])
                }
                NumberField(key: "keep_watching_days", unit: "days", model: model)
            }
            Item {
                VStack(alignment: .leading, spacing: 2) {
                    Label2(title: "Days without updates before a PR is dropped")
                    ErrorText(text: model.errors["drop_after_days"])
                }
                NumberField(key: "drop_after_days", unit: "days", model: model)
            }
        }
        Text("Wider ranges miss less but use more API quota. Check Cost per poll in General.")
            .font(.system(size: 11)).foregroundColor(Palette.secondary.color).padding(.horizontal, 4)
    }
}

extension LaunchAtLogin {
    func openSystemSettingsLoginItems() {
        MainAppLoginItem().openSystemSettings()
    }
}
