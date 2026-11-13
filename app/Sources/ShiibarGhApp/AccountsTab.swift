// Settings › Accounts: the sidebar of accounts and owners, the account pane
// with its Muted lists, the owner pane with its two tabs, and the sheets (Settings.html,
// SettingsOwner.html, Sheets.html, Keychain.html; DESIGN.md, "Settings ›
// Accounts" and "Settings rules").

import AppKit
import ShiibarGhCore
import SwiftUI

enum AccountsSheet: Identifiable {
    case addAccount
    case editToken(String)
    case addOwner(String)
    case copy(account: String, owner: String)

    var id: String {
        switch self {
        case .addAccount: return "add"
        case .editToken(let id): return "token:" + id
        case .addOwner(let id): return "owner:" + id
        case .copy(let account, let owner): return "copy:\(account):\(owner)"
        }
    }
}

struct AccountsTab: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var app: AppModel
    @State private var sheet: AccountsSheet?

    var body: some View {
        VStack(spacing: 0) {
            if let dialog = KeychainDialog.for(app.keychain) {
                BannerView(lines: [BannerLine.keychain(dialog)]) { app.bannerButton($0, account: nil) }
                .padding(.bottom, 8)
            }
            HStack(spacing: 0) {
                Sidebar(model: model, app: app) { sheet = .addAccount }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let owner = model.selectedOwner, let account = model.selectedAccount {
                            OwnerPane(model: model, app: app, account: account, owner: owner) {
                                sheet = .copy(account: account.id, owner: owner.id)
                            }
                        } else if let account = model.selectedAccount {
                            AccountPane(model: model, app: app, account: account) { sheet = $0 }
                        } else {
                            // No account: the message and Add account… on
                            // the right (DESIGN.md, "Settings › Accounts").
                            VStack(spacing: 10) {
                                Text(EmptyState.noAccountsTitle).font(.system(size: 13, weight: .semibold))
                                SettingsButton(title: "Add account…", enabled: model.canAddAccount) { sheet = .addAccount }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                    }
                    .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .addAccount:
                TokenSheet(model: TokenSheetModel(mode: .add, app: app), app: app) { self.sheet = nil }
            case .editToken(let id):
                TokenSheet(model: TokenSheetModel(mode: .edit(id), app: app), app: app) { self.sheet = nil }
            case .addOwner(let id):
                AddOwnerSheet(model: AddOwnerModel(account: id, app: app)) { self.sheet = nil }
            case .copy(let account, let owner):
                CopySheet(settings: model, app: app, accountId: account, ownerId: owner) { self.sheet = nil }
            }
        }
        .onReceive(app.$accounts) { _ in model.ensureSelection() }
        .onReceive(model.$requestedSheet) { request in
            guard request == .addAccount else { return }
            model.requestedSheet = nil
            if model.canAddAccount { sheet = .addAccount }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var app: AppModel
    var addAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(app.accounts) { account in
                        row(selected: model.selection == .account(account.id), indent: false) {
                            AccountDot(color: account.accountColor)
                            Text(account.login).lineLimit(1)
                        } action: { model.select(.account(account.id)) }
                        ForEach(account.owners) { owner in
                            row(selected: model.selection == .owner(account: account.id, owner: owner.id), indent: true) {
                                Text(owner.displayName).lineLimit(1)
                            } action: { model.select(.owner(account: account.id, owner: owner.id)) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: addAccount) {
                Text("Add account…").font(.system(size: 12)).frame(maxWidth: .infinity)
            }
            .disabled(!model.canAddAccount)
        }
        .padding(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))
        .frame(width: 170)
        .frame(maxHeight: .infinity)
        .background(Palette.sidebar.color)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.groupBorder.color).frame(width: 1) }
    }

    func row<Label: View>(selected: Bool, indent: Bool, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { label() }
                .font(.system(size: 12, weight: selected && !indent ? .semibold : .regular))
                .foregroundColor(selected ? Palette.settingsTabSelected.color : (indent ? Palette.strongText.color : Palette.text.color))
                .padding(EdgeInsets(top: 6, leading: indent ? 26 : 8, bottom: 6, trailing: 8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.settingsTabSelectedBackground.color : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Account pane

struct AccountPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var app: AppModel
    var account: Account
    var open: (AccountsSheet) -> Void
    @State private var confirmRemove = false

    var body: some View {
        Section2(title: "Account") {
            // Redrawn every few seconds so Checking… also goes away when the
            // check runs out of time (TokenChecks.limit) without an event.
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                let checking = app.isChecking(account.id)
                let label = TokenState.label(account: account, keychain: app.keychain, checking: checking, now: app.now)
                Item(first: true) {
                    Label2(title: "Token", sub: TokenState.expiry(account))
                    Control {
                        if let label { StateText(label: label) }
                        if TokenState.canEdit(keychain: app.keychain) {
                            SettingsButton(title: "Edit…", enabled: !checking) { open(.editToken(account.id)) }
                        }
                    }
                }
            }
            SettingRow(title: "Menu bar icon color", sub: SettingsText.colorDetail, error: model.errors["color:" + account.id]) {
                Picker("", selection: Binding(get: { account.accountColor }, set: { model.setColor(account, $0) })) {
                    ForEach(AccountColor.allCases, id: \.self) { color in
                        Label {
                            Text(color.title)
                        } icon: {
                            Image(nsImage: Swatch.image(color))
                        }
                        .tag(color)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        Section2(title: "Owners") {
            ForEach(Array(account.owners.enumerated()), id: \.element.id) { index, owner in
                Button { model.select(.owner(account: account.id, owner: owner.id)) } label: {
                    Item(first: index == 0) {
                        Label2(title: owner.displayName, sub: owner.kindTitle)
                        Control { Text("\u{203A}").foregroundColor(Palette.waiting.color) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                SettingsButton(title: "Add owner…") { open(.addOwner(account.id)) }
            }
            .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
            .overlay(alignment: .top) {
                if !account.owners.isEmpty { Rectangle().fill(Palette.itemDivider.color).frame(height: 1) }
            }
        }
        Section2(title: "Muted") {
            MutedRow(model: model, account: account, kind: .repo, title: "Repositories", detail: SettingsText.mutedReposDetail, first: true)
            MutedRow(model: model, account: account, kind: .user, title: "Users", detail: SettingsText.mutedUsersDetail)
            MutedRow(model: model, account: account, kind: .pr, title: "Pull requests", detail: SettingsText.mutedPullRequestsDetail)
        }
        Section2(title: "Remove") {
            SettingRow(title: "Remove this account", sub: SettingsText.removeAccountDetail, error: model.errors["account:" + account.id], first: true) {
                SettingsButton(title: "Remove…", enabled: model.canRemoveAccount) { confirmRemove = true }
            }
        }
        .alert(SettingsText.removeAccountTitle(account.login), isPresented: $confirmRemove) {
            Button("Remove") { model.removeAccount(account) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SettingsText.removeAccountDetail)
        }
    }
}

/// The color sample of the Menu bar icon color popup.
enum Swatch {
    static func image(_ color: AccountColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            if let fill = color.nsColor {
                fill.setFill()
                path.fill()
            }
            NSColor.black.withAlphaComponent(0.12).setStroke()
            path.stroke()
            return true
        }
        return image
    }
}

// MARK: - Owner pane

struct OwnerPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var app: AppModel
    var account: Account
    var owner: Owner
    var copy: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        HStack {
            Spacer()
            Picker("", selection: $model.ownerTab) {
                ForEach(OwnerTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
        }
        .padding(.bottom, 4)
        ErrorText(text: model.errors["owner:" + owner.id])
        switch model.ownerTab {
        case .owner:
            Section2(title: "Owner") {
                SettingRow(title: "Enabled", sub: SettingsText.enabledDetail, first: true) {
                    Toggle("", isOn: Binding(get: { owner.enabled }, set: { model.setOwnerEnabled(owner, of: account, $0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            Section2(title: "Remove") {
                SettingRow(title: "Remove this owner", sub: SettingsText.removeOwnerDetail, first: true) {
                    SettingsButton(title: "Remove…") { confirmRemove = true }
                }
            }
            .alert(SettingsText.removeOwnerTitle(owner.displayName), isPresented: $confirmRemove) {
                Button("Remove") { model.removeOwner(owner, of: account) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(SettingsText.removeOwnerDetail)
            }
        case .notifications:
            Section2(title: "Notifications") {
                SettingRow(title: SettingsText.notifyTitle(owner.displayName), sub: SettingsText.notifyDetail, first: true) {
                    Toggle("", isOn: Binding(get: { owner.notify }, set: { model.setOwnerNotify(owner, of: account, $0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                SettingRow(title: "Skip draft pull requests", sub: SettingsText.skipDraftsDetail) {
                    Toggle("", isOn: Binding(get: { owner.skipDrafts }, set: { model.setSkipDrafts(owner, of: account, $0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            Section2(title: "Events") {
                EventTable(cells: { model.cell(owner.id, $0) }, editable: true) { kind, column, on in
                    model.setEvent(owner, of: account, kind, column, on)
                }
                .padding(EdgeInsets(top: 4, leading: 10, bottom: 8, trailing: 10))
                ErrorText(text: model.errors["events:" + owner.id]).padding(.horizontal, 14)
                SettingRow(title: "Copy table from another owner", sub: SettingsText.copyDetail) {
                    SettingsButton(title: "Copy…", enabled: !model.otherOwners(of: owner.id, in: account).isEmpty, action: copy)
                }
            }
        }
    }
}

/// The event table: List and Notify per kind, grouped. Checkboxes
/// only here (rule 2). Read only in the Copy sheet.
struct EventTable: View {
    var cells: (EventKind) -> EventCell
    var editable: Bool
    var set: (EventKind, EventColumn, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Event").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(EventColumn.allCases, id: \.self) { column in
                    Text(column.rawValue.capitalized).frame(width: 56)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Palette.secondary.color)
            .padding(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.groupBorder.color).frame(height: 1) }
            ForEach(SettingsText.eventGroups, id: \.0) { group, kinds in
                Text(group)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.strongText.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 7, leading: 6, bottom: 4, trailing: 6))
                    .background(Palette.settingsBackground.color.opacity(0.5))
                ForEach(kinds, id: \.self) { kind in
                    let cell = cells(kind)
                    HStack {
                        Text(SettingsText.eventTitle(kind)).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(EventColumn.allCases, id: \.self) { column in
                            mark(cell, kind, column).frame(width: 56)
                        }
                    }
                    .font(.system(size: 12))
                    .padding(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                    .overlay(alignment: .top) { Rectangle().fill(Palette.rowDivider.color).frame(height: 1) }
                }
            }
        }
    }

    @ViewBuilder
    func mark(_ cell: EventCell, _ kind: EventKind, _ column: EventColumn) -> some View {
        let on = cell.value(column)
        if editable {
            Toggle("", isOn: Binding(get: { on }, set: { set(kind, column, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!SettingsModel.cellEnabled(cell, column))
        } else {
            Text(on ? "\u{2713}" : "\u{2013}")
                .fontWeight(on ? .semibold : .regular)
                .foregroundColor(on ? Palette.blueDot.color : Palette.faded.color)
        }
    }
}

/// A Muted list (Settings.html, rule 4): the label and its description on
/// the left; on the right a framed list, below it a field with `Add`
/// (Enter adds too) and − for the selected row.
struct MutedRow: View {
    @ObservedObject var model: SettingsModel
    var account: Account
    var kind: MuteKind
    var title: String
    var detail: String
    var first = false
    @State private var selected: String?
    @State private var name = ""

    var body: some View {
        let entries = model.mutes(kind, of: account.id)
        let canAdd = model.canAddMute(kind, name, of: account.id)
        Item(first: first) {
            Label2(title: title, sub: detail, error: model.errors[SettingsModel.muteErrorKey(kind, account.id)])
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 6) {
                VStack(spacing: 0) {
                    ForEach(entries, id: \.self) { entry in
                        Text(entry)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                            .background(selected == entry ? Palette.settingsTabSelectedBackground.color : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = entry }
                            .overlay(alignment: .top) {
                                if entry != entries.first { Rectangle().fill(Palette.rowDivider.color).frame(height: 1) }
                            }
                    }
                }
                .frame(minHeight: 22, alignment: .top)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surface.color))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.groupBorder.color, lineWidth: 1))
                HStack(spacing: 4) {
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit(add)
                        .accessibilityLabel("Add to " + title)
                    SettingsButton(title: "Add", enabled: canAdd, action: add)
                    SettingsButton(title: "\u{2212}", enabled: selected.map(entries.contains) ?? false) {
                        if let selected {
                            model.removeMute(kind, selected, of: account)
                            self.selected = nil
                        }
                    }
                    .accessibilityLabel("Remove")
                }
            }
            .frame(width: 240)
        }
    }

    /// The field keeps the text until the daemon takes it.
    func add() {
        let sent = name
        model.addMute(kind, name, of: account) {
            if name == sent { name = "" }
        }
    }
}

// MARK: - Sheets

/// Add account and Edit… (Sheets.html). The field always shows dots; the
/// app never knows the saved token or its length.
struct TokenSheet: View {
    @StateObject var model: TokenSheetModel
    @ObservedObject var app: AppModel
    var close: () -> Void

    init(model: TokenSheetModel, app: AppModel, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.app = app
        self.close = close
    }

    var isAdd: Bool { model.mode == .add }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.system(size: 13, weight: .semibold))
            Text(isAdd
                 ? "One classic token per account. The token's owner becomes the account. It reads notifications, pull requests and checks in every owner you add."
                 : "One classic token for this account. It reads notifications, pull requests and checks in every owner.")
                .font(.system(size: 11)).foregroundColor(Palette.secondary.color).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Label2(title: "1. Create a token on GitHub", sub: "Opens GitHub with the scopes filled in: repo, notifications, read:org.")
                    SettingsButton(title: "Create token…") { app.open(CreateTokenURL.classic) }
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 6, trailing: 12))
                Text(SettingsText.ssoNote).font(.system(size: 11)).foregroundColor(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(EdgeInsets(top: 0, leading: 12, bottom: 10, trailing: 12))
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.groupBorder.color, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text("2. Paste the token and test it").font(.system(size: 12, weight: .semibold))
                Text(isAdd
                     ? "The field always shows dots. Test checks the token without saving it."
                     : "The field always shows dots. From Edit…, it holds the saved token; Test checks it as is, or paste a new one to replace it.")
                    .font(.system(size: 11)).foregroundColor(Palette.secondary.color).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                SecureField("", text: $model.token, prompt: Text(model.placeholder))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.test() }
                SettingsButton(title: model.testing ? "Checking…" : "Test", enabled: model.canTest) { model.test() }
            }
            // The result list is there from the start, names faint until a
            // test fills it, so the sheet keeps its height (Sheets.html).
            VStack(spacing: 0) {
                ForEach(Array(model.resultRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        switch row {
                        case .placeholder(let label):
                            Text(label).foregroundColor(Palette.faded.color).frame(maxWidth: .infinity, alignment: .leading)
                        case .result(let line):
                            Text(line.label).frame(maxWidth: .infinity, alignment: .leading)
                            Text(line.text).foregroundColor(tone(line.tone))
                            if let url = line.authorize {
                                SettingsButton(title: "Authorize…") { app.open(url) }
                            }
                        }
                    }
                    .font(.system(size: 12))
                    .frame(minHeight: 22)
                    .padding(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                    .overlay(alignment: .top) { Rectangle().fill(Palette.rowDivider.color).frame(height: 1) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surface.color))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.groupBorder.color, lineWidth: 1))
            ErrorText(text: model.error)
            HStack(spacing: 8) {
                if model.showsSaveLater {
                    Text(SettingsText.saveLater).font(.system(size: 11)).foregroundColor(Palette.secondary.color)
                }
                Spacer()
                SettingsButton(title: "Cancel") {
                    model.cancel()
                    close()
                }
                SettingsButton(title: model.saving ? "Saving…" : "Save", primary: true, enabled: model.canSave) {
                    model.save { saved in if saved { close() } }
                }
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(width: 520)
        .background(Palette.settingsBackground.color)
    }

    func tone(_ tone: TestResultLine.Tone) -> Color {
        switch tone {
        case .good: return Palette.greenText.color
        case .bad: return Palette.orangeText.color
        case .caution: return Palette.caution.color
        case .neutral: return Palette.waiting.color
        }
    }
}

/// Add owner (Sheets.html).
struct AddOwnerSheet: View {
    @StateObject var model: AddOwnerModel
    var close: () -> Void

    init(model: AddOwnerModel, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.close = close
    }

    var body: some View {
        let typed = model.name.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 12) {
            Text(SettingsText.addOwnerTitle(model.account?.login ?? "")).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Owner").font(.system(size: 12, weight: .semibold))
                Text("The login of an organization or a personal account.").font(.system(size: 11)).foregroundColor(Palette.secondary.color)
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.add(done: close) }
                ErrorText(text: model.error)
            }
            Text(SettingsText.addOwnerNote(typed))
                .font(.system(size: 11)).foregroundColor(Palette.secondary.color).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SettingsButton(title: "Add Public instead", enabled: model.canAddPublic) { model.addPublic(done: close) }
                Spacer()
                SettingsButton(title: "Cancel", action: close)
                SettingsButton(title: model.busy ? "Adding…" : "Add", primary: true, enabled: model.canAdd) { model.add(done: close) }
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(width: 440)
        .background(Palette.settingsBackground.color)
    }
}

/// Copy table to … (SettingsOwner.html): the other owner's table read
/// only, and Copy.
struct CopySheet: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var app: AppModel
    var accountId: String
    var ownerId: String
    var close: () -> Void
    @State private var from: String?
    @State private var table: [String: EventCell] = [:]
    @State private var copying = false

    var body: some View {
        let account = app.account(accountId)
        let owner = account?.owner(ownerId)
        let others = account.map { settings.otherOwners(of: ownerId, in: $0) } ?? []
        let source = others.first { $0.id == from }
        VStack(alignment: .leading, spacing: 12) {
            Text(SettingsText.copyTitle(owner?.displayName ?? "")).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 12) {
                Label2(title: "Copy from", sub: source.map { "\($0.displayName)'s table:" })
                Control {
                    Picker("", selection: $from) {
                        ForEach(others) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            EventTable(cells: { table[$0.rawValue] ?? EventCell(list: false, notify: false) }, editable: false) { _, _, _ in }
                .padding(EdgeInsets(top: 2, leading: 8, bottom: 6, trailing: 8))
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surface.color))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.groupBorder.color, lineWidth: 1))
            Text(SettingsText.copyNote(owner?.displayName ?? "")).font(.system(size: 12)).foregroundColor(Palette.secondary.color)
            ErrorText(text: settings.errors["events:" + ownerId])
            HStack(spacing: 8) {
                Spacer()
                SettingsButton(title: "Cancel", action: close)
                SettingsButton(title: "Copy", primary: true, enabled: source != nil && owner != nil && !copying) {
                    guard let source, let owner, let account else { return }
                    copying = true
                    settings.copyTable(from: source, to: owner, of: account) { done in
                        copying = false
                        if done { close() }
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(width: 540)
        .background(Palette.settingsBackground.color)
        .onAppear { if from == nil { from = others.first?.id } }
        .onChange(of: from) { _, id in load(id) }
        .task { load(from ?? others.first?.id) }
    }

    func load(_ id: String?) {
        guard let id, let account = app.account(accountId), let source = account.owner(id) else { return }
        Task {
            if let read = await settings.readTable(source, of: account) { table = read }
        }
    }
}
