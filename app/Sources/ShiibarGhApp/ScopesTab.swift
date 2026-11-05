// Settings › Scopes: the notifications token, every scope with its token,
// test results, Enabled, Notifications, color and Remove, and Add scope
// (docs/design/Settings.html; DESIGN.md, "Adding a scope and registering a
// token in Settings"). Pieces the board does not show (adding a scope, the
// token entry, the Remove confirmation, the colors) are made of the
// board's `.group`, `.item`, `.sub` and `.btn`.

import AppKit
import ShiibarGhCore
import SwiftUI

struct ScopesTab: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var app: AppModel
    @State private var adding = false

    var body: some View {
        NotificationsTokenSection(model: model, app: app)
        Section2(title: "Scopes") {
            if app.scopes.isEmpty {
                Item(first: true) {
                    Text("No scopes yet").foregroundColor(Palette.secondary.color)
                }
            }
            ForEach(Array(app.scopes.enumerated()), id: \.element.id) { index, scope in
                ScopeItems(scope: scope, first: index == 0, model: model, app: app)
            }
        }
        if adding {
            AddScopeSection(model: model) { adding = false }
        }
        HStack {
            Text("In GitHub notification settings, \u{201C}On GitHub\u{201D} must be on for conversations you participate in")
                .font(.system(size: 11)).foregroundColor(Palette.secondary.color)
            Spacer()
            if !adding {
                SettingsButton(title: "Add scope") { adding = true }
            }
        }
    }
}

struct TokenLabelView: View {
    var label: TokenLabel

    var body: some View {
        Text(label.text)
            .font(.system(size: 12))
            .foregroundColor({
                switch label.tone {
                case .good: return Palette.greenText.color
                case .caution: return Palette.caution.color
                case .bad: return Palette.orangeText.color
                case .neutral: return Palette.secondary.color
                }
            }())
            .fixedSize()
    }
}

struct NotificationsTokenSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var app: AppModel

    var body: some View {
        let status = model.token("notifications")
        let warnings = TokenState.notificationsWarnings(app.scopes)
        let label = TokenState.label(status: status, warnings: warnings, now: app.now)
        let registered = status?.registered ?? false
        Section2(title: "Notifications token (classic PAT)") {
            Item(first: true) {
                // Unregistered: the label on the right already says No token.
                Label2(title: registered ? TokenState.masked : "classic PAT", sub: classicSub(status))
                TokenLabelView(label: label)
            }
            if registered, showsSSO(status, warnings) {
                Item {
                    Label2(title: "SSO authorization required", sub: "Shown only when GitHub reports that this token needs SSO authorization")
                    Button("Authorize") { app.open(status?.ssoUrls.first ?? CreateTokenURL.tokenSettings) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Palette.caution.color)
                }
            }
            if let last = status?.lastTest, registered {
                TestResults(results: last.results)
            }
            if !registered || model.entering.contains("notifications") {
                TokenEntry(target: "notifications", createURL: CreateTokenURL.classic, hint: nil, registered: registered, model: model, app: app)
            } else {
                Item {
                    Spacer()
                    ErrorText(text: model.errors["test:notifications"])
                    Button("Create token") { app.open(CreateTokenURL.classic) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Palette.link.color)
                    SettingsButton(title: model.testing.contains("notifications") ? "Testing…" : "Test again") { model.test("notifications") }
                    SettingsButton(title: "Replace") { model.entering.insert("notifications") }
                }
            }
        }
    }

    func classicSub(_ status: TokenStatus?) -> String? {
        guard let status, status.registered else { return "Scopes: notifications, read:org" }
        var parts: [String] = []
        if let scopes = status.scopes { parts.append("Scopes: " + scopes.joined(separator: ", ")) }
        if let expires = status.expiresAt { parts.append("Expires " + RelativeTime.date(expires)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func showsSSO(_ status: TokenStatus?, _ warnings: [Warning]) -> Bool {
        !(status?.ssoUrls.isEmpty ?? true) || app.scopes.flatMap(\.warnings).contains {
            $0.kind.value == .ssoRequired && $0.token?.value == .notifications
        }
    }
}

struct ScopeItems: View {
    var scope: Scope
    var first: Bool
    @ObservedObject var model: SettingsModel
    @ObservedObject var app: AppModel
    @State private var confirmingRemove = false

    var body: some View {
        let status = TokenState.status(of: scope, in: model.status.tokens)
        let label = TokenState.label(status: status, warnings: TokenState.scopeWarnings(scope), now: app.now)
        let registered = status?.registered ?? false
        let type = model.addedTypes[scope.id] ?? CreateTokenURL.ownerType(of: scope)
        Item(first: first) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(sub(status)).font(.system(size: 11)).foregroundColor(Palette.secondary.color)
                ErrorText(text: model.errors["scope:" + scope.id])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TokenLabelView(label: label)
            Toggle("Enabled", isOn: Binding(get: { scope.enabled }, set: { on in
                model.scopeRequest(scope.id) { on ? try await $0.scopeEnable(scope.id) : try await $0.scopeDisable(scope.id) }
            }))
            .toggleStyle(.checkbox).font(.system(size: 11)).foregroundColor(Palette.secondary.color)
            Toggle("Notifications", isOn: Binding(get: { scope.notify }, set: { on in
                model.scopeRequest(scope.id) { try await $0.scopeNotify(scope.id, on: on) }
            }))
            .toggleStyle(.checkbox).font(.system(size: 11)).foregroundColor(Palette.secondary.color)
        }
        if let last = status?.lastTest, registered {
            TestResults(results: last.results)
        }
        if !registered || model.entering.contains(scope.id) {
            TokenEntry(
                target: scope.id, createURL: CreateTokenURL.fineGrained(owner: scope.name, type: type),
                hint: CreateTokenURL.repositoryAccessHint(type), registered: registered, model: model, app: app
            )
        }
        Item {
            ColorChoice(selected: Palette.color(of: scope)) { color in
                model.scopeRequest(scope.id) { try await $0.scopeColor(scope.id, color) }
            }
            Spacer()
            ErrorText(text: model.errors["test:" + scope.id])
            if registered && !model.entering.contains(scope.id) {
                SettingsButton(title: model.testing.contains(scope.id) ? "Testing…" : "Test again") { model.test(scope.id) }
                SettingsButton(title: "Replace") { model.entering.insert(scope.id) }
            }
            SettingsButton(title: "Remove") { confirmingRemove = true }
        }
        if confirmingRemove {
            Item(vertical: true) {
                Text(ScopeText.removeTitle(scope.name)).font(.system(size: 13, weight: .semibold))
                Text(ScopeText.removeDetail(scope.name))
                    .font(.system(size: 11)).foregroundColor(Palette.secondary.color)
                HStack {
                    Spacer()
                    SettingsButton(title: "Cancel") { confirmingRemove = false }
                    SettingsButton(title: "Remove") {
                        confirmingRemove = false
                        model.removeScope(scope.id)
                    }
                }
            }
        }
    }

    var title: String {
        scope.kind?.value == .org ? "\(scope.name) (organization)" : scope.name
    }

    func sub(_ status: TokenStatus?) -> String {
        let registered = status?.registered ?? false
        var parts = [registered ? "fine-grained PAT " + TokenState.masked : "fine-grained PAT"]
        if registered, let expires = status?.expiresAt {
            parts.append("Expires " + RelativeTime.date(expires))
        }
        if scope.isPublic {
            parts.append("Public repositories")
            parts.append("PRs you\u{2019}re involved in on public repositories")
        }
        return parts.joined(separator: " · ")
    }
}

struct TestResults: View {
    var results: [TestResult]

    var body: some View {
        Item(vertical: true) {
            Text("Test fetch results").font(.system(size: 11)).foregroundColor(Palette.secondary.color)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                    let text = TokenState.resultText(result)
                    HStack(spacing: 0) {
                        Text(text.status).foregroundColor({
                            switch text.tone {
                            case .good: return Palette.greenText.color
                            case .bad: return Palette.orangeText.color
                            default: return Palette.secondary.color
                            }
                        }())
                        Text(" · " + result.item)
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }
}

/// Create token, the Repository access hint, the paste field and Save. The
/// field is cleared once Save hands the token to the daemon.
struct TokenEntry: View {
    var target: String
    var createURL: String
    var hint: String?
    /// A token is saved: Cancel goes back to it.
    var registered = false
    @ObservedObject var model: SettingsModel
    @ObservedObject var app: AppModel
    @State private var token = ""

    var body: some View {
        Item(vertical: true) {
            HStack(spacing: 8) {
                Button("Create token") { app.open(createURL) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Palette.link.color)
                if let hint {
                    Text(hint).font(.system(size: 11)).foregroundColor(Palette.secondary.color)
                }
            }
            HStack(spacing: 8) {
                SecureField("Paste the token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                SettingsButton(title: "Save", action: save)
                if registered {
                    SettingsButton(title: "Cancel") {
                        token = ""
                        model.entering.remove(target)
                    }
                }
            }
            ErrorText(text: model.errors["token:" + target])
        }
    }

    func save() {
        let value = token
        token = ""
        model.saveToken(target, value) { _ in }
    }
}

struct ColorChoice: View {
    var selected: ScopeColor
    var choose: (ScopeColor) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("Color").font(.system(size: 11)).foregroundColor(Palette.secondary.color)
            ForEach(ScopeColor.allCases, id: \.self) { color in
                let theme = Palette.theme(color)
                Button { choose(color) } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.background.color)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.swatchBorder.color, lineWidth: 1))
                        .frame(width: 16, height: 16)
                        .padding(2)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(color == selected ? Palette.blueDot.color : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help(Palette.title(color))
                .accessibilityLabel(Palette.title(color))
            }
        }
    }
}

struct AddScopeSection: View {
    @ObservedObject var model: SettingsModel
    var finished: () -> Void
    @State private var owner = ""
    @State private var type: OwnerType = .organization

    var body: some View {
        Section2(title: "Add scope") {
            Item(first: true) {
                Picker("", selection: $type) {
                    ForEach(OwnerType.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
                Spacer()
            }
            Item {
                if type == .public {
                    Label2(title: "Public", sub: "PRs you\u{2019}re involved in on public repositories of owners you have not added")
                } else {
                    TextField(type == .organization ? "Organization login" : "Account login", text: $owner)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                }
                SettingsButton(title: "Cancel", action: finished)
                SettingsButton(title: "Add", action: add)
            }
            if let error = model.errors["add"] {
                Item { ErrorText(text: error) }
            }
        }
    }

    func add() {
        guard type == .public || !owner.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.addScope(owner: owner, type: type) { added in
            if added != nil { finished() }
        }
    }
}
