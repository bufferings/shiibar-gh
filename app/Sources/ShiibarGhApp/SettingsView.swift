// The Settings window: General, Accounts and Watching (docs/design/
// Settings.html, SettingsOwner.html, Sheets.html, Keychain.html; DESIGN.md,
// "Settings" and "Settings rules"). Every value goes straight to the daemon.

import AppKit
import ShiibarGhCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    TabButton(tab: tab, selected: model.tab == tab) {
                        model.tab = tab
                        if tab == .accounts { model.ensureSelection() }
                    }
                }
            }
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .frame(maxWidth: .infinity)
            .background(Palette.settingsTabBar.color)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.settingsTabBarBorder.color).frame(height: 1) }
            if app.dbUnreadable {
                VStack(alignment: .leading) {
                    GroupBox2 {
                        Item {
                            Text(EmptyState.unreadable).frame(maxWidth: .infinity, alignment: .leading)
                            SettingsButton(title: "Reset") { app.reset() }
                        }
                    }
                    Spacer()
                }
                .padding(EdgeInsets(top: 18, leading: 28, bottom: 24, trailing: 28))
            } else {
                switch model.tab {
                case .general:
                    ScrollView { VStack(alignment: .leading, spacing: 14) { GeneralTab(model: model) }.padding(pane) }
                case .accounts:
                    AccountsTab(model: model, app: app)
                case .watching:
                    ScrollView { VStack(alignment: .leading, spacing: 14) { WatchingTab(model: model) }.padding(pane) }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Palette.settingsBackground.color)
        .foregroundColor(Palette.text.color)
        .font(.system(size: 13))
    }

    var pane: EdgeInsets { EdgeInsets(top: 16, leading: 24, bottom: 20, trailing: 24) }
}

struct TabButton: View {
    var tab: SettingsTab
    var selected: Bool
    var action: () -> Void

    var icon: BoardIcon {
        switch tab {
        case .general: return BoardIcons.tabGeneral
        case .accounts: return BoardIcons.tabAccounts
        case .watching: return BoardIcons.tabWatching
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                IconView(icon: icon, size: 18, color: selected ? Palette.settingsTabSelected.color : Palette.strongText.color)
                Text(tab.rawValue).font(.system(size: 11))
            }
            .foregroundColor(selected ? Palette.settingsTabSelected.color : Palette.strongText.color)
            .frame(minWidth: 72)
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Palette.settingsTabSelectedBackground.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// `.gh` and `.group` of the board: every box has a heading.
struct Section2<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.strongText.color).padding(.leading, 4)
            GroupBox2 { content }
        }
    }
}

struct GroupBox2<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.groupBorder.color, lineWidth: 1))
    }
}

/// `.item` of the board: a row with a top border except the first.
struct Item<Content: View>: View {
    var first = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
            .overlay(alignment: .top) {
                if !first { Rectangle().fill(Palette.itemDivider.color).frame(height: 1) }
            }
    }
}

/// Settings rule 1: the label and its one-line description on the left.
struct Label2: View {
    var title: String
    var sub: String?
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold)
            if let sub { Text(sub).font(.system(size: 11)).foregroundColor(Palette.secondary.color) }
            ErrorText(text: error)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Settings rule 1: the right column, 240 points, right aligned.
struct Control<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            content
        }
        .frame(width: 240, alignment: .trailing)
    }
}

/// The label and one control.
struct SettingRow<C: View>: View {
    var title: String
    var sub: String?
    var error: String?
    var first = false
    @ViewBuilder var control: C

    var body: some View {
        Item(first: first) {
            Label2(title: title, sub: sub, error: error)
            Control { control }
        }
    }
}

struct ErrorText: View {
    var text: String?

    var body: some View {
        if let text {
            Text(text).font(.system(size: 11)).foregroundColor(Palette.orangeText.color).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The state text of rule 2: problems and progress only.
struct StateText: View {
    var label: TokenLabel

    var body: some View {
        Text(label.text)
            .font(.system(size: 12))
            .foregroundColor({
                switch label.tone {
                case .good: return Palette.greenText.color
                case .caution: return Palette.caution.color
                case .bad: return Palette.orangeText.color
                case .neutral: return Palette.waiting.color
                }
            }())
            .lineLimit(1)
            .fixedSize()
    }
}

/// The board's `.btn`; `primary` is the blue default button of a sheet.
struct SettingsButton: View {
    var title: String
    var primary = false
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundColor(primary ? Palette.onColor.color : Palette.text.color)
                .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                .background(RoundedRectangle(cornerRadius: 6).fill(primary ? Palette.blueDot.color : Palette.surface.color))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(primary ? Palette.blueDot.color : Palette.controlBorder.color, lineWidth: 1))
                .contentShape(Rectangle())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// A number field saved on Return or when it loses the focus.
struct NumberField: View {
    var key: String
    var unit: String
    @ObservedObject var model: SettingsModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            Text(unit).font(.system(size: 12)).foregroundColor(Palette.secondary.color).frame(minWidth: 32, alignment: .leading)
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

struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section2(title: "Startup") {
            Item(first: true) {
                VStack(alignment: .leading, spacing: 2) {
                    Label2(title: "Launch at login", sub: "Runs in the menu bar after you log in to your Mac", error: model.errors["launch_at_login"])
                    if model.launchStatus == .requiresApproval {
                        Text("Allow shiibar-gh in System Settings › General › Login Items")
                            .font(.system(size: 11)).foregroundColor(Palette.caution.color)
                    }
                }
                Control {
                    if model.launchStatus == .requiresApproval {
                        SettingsButton(title: "Open Login Items…") { MainAppLoginItem().openSystemSettings() }
                    }
                    Toggle("", isOn: Binding(get: { model.launchOn }, set: { model.setLaunch($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
        }
        Section2(title: "Appearance") {
            SettingRow(title: "Appearance", sub: "System follows the appearance setting of your Mac", error: model.errors[AppAppearance.configKey], first: true) {
                Picker("", selection: Binding(
                    get: { AppAppearance(model.config[AppAppearance.configKey]).rawValue },
                    set: { model.set(AppAppearance.configKey, .string($0)) }
                )) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        Section2(title: "Polling") {
            SettingRow(title: "PR status interval", sub: "Shorter means you notice sooner, but uses more API quota", error: model.errors["status_interval_minutes"], first: true) {
                NumberField(key: "status_interval_minutes", unit: "min", model: model)
            }
            SettingRow(title: "Reactions interval", sub: "Shorter means you notice sooner, but uses more API quota", error: model.errors["reactions_interval_minutes"]) {
                NumberField(key: "reactions_interval_minutes", unit: "min", model: model)
            }
        }
        Section2(title: "Snooze") {
            SettingRow(title: "Return time", sub: "All snoozed PRs come back every day at this time", error: model.errors["snooze_return_time"], first: true) {
                DatePicker("", selection: Binding(
                    get: { ReturnTime.date(model.config["snooze_return_time"]?.stringValue, calendar: ReturnTime.calendar) },
                    set: { model.set("snooze_return_time", .string(ReturnTime.text($0, calendar: ReturnTime.calendar))) }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                // The picker reads and writes the time in the same fixed
                // calendar as the conversion.
                .environment(\.calendar, ReturnTime.calendar)
                .environment(\.timeZone, ReturnTime.calendar.timeZone)
                .fixedSize()
            }
        }
    }
}

struct WatchingTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Section2(title: "Watching") {
            SettingRow(title: "Days to keep watching after close", sub: "Reactions are watched this long after a card leaves the list", error: model.errors["keep_watching_days"], first: true) {
                NumberField(key: "keep_watching_days", unit: "days", model: model)
            }
            SettingRow(title: "Days without updates before a PR is dropped", sub: "Other people's open PRs leave the list after this many quiet days", error: model.errors["drop_after_days"]) {
                NumberField(key: "drop_after_days", unit: "days", model: model)
            }
        }
    }
}
