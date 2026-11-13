// The popover of one account, also the content of its window
// (docs/design/Main.html, Keychain.html, MenuBarIcon.html): the header,
// the banners, the tab row, the search row, the list (CardViews.swift), the
// key hints and the Grouping sheet.
//
// Sizes are the boards' points at text size 12, multiplied by
// `textScale` (DESIGN.md, "Text size"): the fonts are fixed point sizes
// (`.system(size:)`), so the app scales the numbers itself instead of using
// Dynamic Type, which macOS SwiftUI does not apply to fixed sizes.

import AppKit
import ShiibarGhCore
import SwiftUI

/// The ratio of `text_size` to 12.
struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

/// What the surface around the list does for it.
struct SurfaceActions {
    var openWindow: (() -> Void)?
    var openSettings: (SettingsDestination) -> Void
    var about: () -> Void
    var quit: () -> Void

    /// The ⌄ menu (DESIGN.md, "Screens"); nil is a separator.
    var menuItems: [IconMenuItem?] {
        [
            IconMenuItem("About shiibar-gh", action: about),
            IconMenuItem("Settings…") { openSettings(.general) },
            nil,
            IconMenuItem("Quit shiibar-gh", action: quit),
        ]
    }
}

struct PopoverView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: AccountViewModel
    /// This surface's own tab, search, selection and expanded rows.
    @ObservedObject var list: SurfaceListModel
    @ObservedObject var avatars: AvatarStore
    var actions: SurfaceActions
    var surface: Surface

    var account: Account? { app.account(model.accountId) }

    var body: some View {
        let k = CGFloat(TextSize.ratio(app.textSize))
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: Int64(context.date.timeIntervalSince1970))
        }
        .frame(minWidth: 300, minHeight: 300)
        .background(Palette.background.color)
        .foregroundColor(Palette.text.color)
        .font(.system(size: 13 * k))
        .environment(\.textScale, k)
    }

    @ViewBuilder
    func content(now: Int64) -> some View {
        VStack(spacing: 0) {
            Header(
                login: account?.login ?? "", color: account?.accountColor ?? .none,
                updated: app.dbUnreadable ? nil : RelativeTime.updated(account?.updatedAt, now: now),
                usage: model.usage, model: model, surface: surface, refreshing: app.refreshing.contains(model.accountId),
                actions: actions, refresh: { app.refresh(model.accountId) }
            )
            switch SurfaceRules.content(account: account, dbUnreadable: app.dbUnreadable) {
            case .unreadable:
                CenteredMessage(title: EmptyState.unreadable, button: "Reset") { app.reset() }
            case .noOwners:
                BannerView(lines: Warnings.banner(account?.warnings ?? [], now: now)) { app.bannerButton($0, account: model.accountId) }
                CenteredMessage(title: EmptyState.noOwnersTitle, detail: EmptyState.noOwnersDetail, button: "Settings") {
                    actions.openSettings(.account(model.accountId))
                }
            case .list:
                BannerView(lines: Warnings.banner(account?.warnings ?? [], now: now)) { app.bannerButton($0, account: model.accountId) }
                if let failure = model.failure {
                    FailureBand(text: failure)
                }
                TabRow(list: list)
                SearchRow(list: list, model: model)
                if list.showingDismissed {
                    DismissedHeading(list: list, keepDays: app.keepDays)
                }
                ListArea(model: list, avatars: avatars, now: now)
                KeyHints(hints: list.hints)
            }
        }
        .overlay {
            if list.showsGrouping {
                GroupingSheet(model: model) { list.showsGrouping = false }
            }
        }
    }
}

// MARK: - Header

/// The account color's dot (Main.html `.adot`).
struct AccountDot: View {
    var color: AccountColor
    var size: CGFloat = 10

    var body: some View {
        Circle().fill(color.dotColor).frame(width: size, height: size)
    }
}

struct Header: View {
    var login: String
    var color: AccountColor
    var updated: String?
    var usage: ApiUsage
    @ObservedObject var model: AccountViewModel
    var surface: Surface
    var refreshing: Bool
    var actions: SurfaceActions
    var refresh: () -> Void
    @Environment(\.textScale) var k

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    AccountDot(color: color, size: 10 * k)
                    Text(login).font(.system(size: 14 * k, weight: .semibold)).lineLimit(1)
                }
                if let updated {
                    // "Updated 1 min ago · API ▬ 1,240 / 5,000" (DESIGN.md,
                    // "Rate limits").
                    HStack(spacing: 0) {
                        Text(updated + " · ").foregroundColor(Palette.secondary.color)
                        UsageView(usage: usage)
                    }
                    .font(.system(size: 11 * k))
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if surface == .window {
                PinButton(on: model.keepOnTop) { model.toggleKeepOnTop() }
            }
            if let openWindow = actions.openWindow {
                HeaderButton(icon: BoardIcons.window, size: 15, label: "Open in window", action: openWindow)
            }
            if refreshing {
                RefreshProgress()
            } else {
                HeaderButton(icon: BoardIcons.refresh, size: 16, label: "Refresh", action: refresh)
            }
            HeaderButton(icon: BoardIcons.settings, size: 16, label: "Settings") { actions.openSettings(.general) }
            MenuIconButton(icon: BoardIcons.chevron, label: "More", items: actions.menuItems)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 10))
    }
}

/// `API`, the thin bar and `1,240 / 5,000` (Main.html `.api`); `API –`
/// before any value. The hover names both APIs.
struct UsageView: View {
    var usage: ApiUsage
    @Environment(\.textScale) var k

    var body: some View {
        let color = usage.warn ? Palette.caution.color : Palette.secondary.color
        HStack(spacing: 0) {
            Text("API")
            if let fraction = usage.fraction, let numbers = usage.numbers {
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.usageTrack.color)
                    Capsule()
                        .fill(usage.warn ? Palette.usageWarnFill.color : Palette.usageFill.color)
                        .frame(width: 36 * k * CGFloat(fraction))
                }
                .frame(width: 36 * k, height: 4 * k)
                .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 5))
                Text(numbers)
            } else {
                Text(" \u{2013}")
            }
        }
        .fontWeight(usage.warn ? .semibold : .regular)
        .foregroundColor(color)
        .help(usage.tooltip ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usage.text)
    }
}

/// Refresh in progress (Main.html `.iconbtn.busy`): a gray circle with a
/// turning blue arc, in place of the button until the answer.
struct RefreshProgress: View {
    @State private var turning = false

    var body: some View {
        ZStack {
            IconView(icon: BoardIcons.progressTrack, size: 16, color: Palette.usageTrack.color)
            IconView(icon: BoardIcons.progressArc, size: 16, color: Palette.blueDot.color)
                .rotationEffect(.degrees(turning ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: turning)
        }
        .frame(width: 24, height: 24)
        .onAppear { turning = true }
        .help("Refreshing")
        .accessibilityLabel("Refreshing")
    }
}

/// Keep on top (Main.html `.pin`): filled blue while on, outlined while off.
struct PinButton: View {
    var on: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Group {
                if on {
                    IconShape(icon: BoardIcons.pin).fill(Palette.settingsTabSelected.color)
                } else {
                    IconView(icon: BoardIcons.pin, size: 14, color: Palette.botIcon.color)
                }
            }
            .frame(width: 14, height: 14)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Palette.settingsTabSelectedBackground.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Keep on top")
        .accessibilityLabel("Keep on top")
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// The yellow banner: one line per warning, each with its button
/// (DESIGN.md, "Showing warnings").
struct BannerView: View {
    var lines: [BannerLine]
    var press: (BannerButton) -> Void
    @Environment(\.textScale) var k

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .center, spacing: 8) {
                        IconView(icon: BoardIcons.warning, size: 14 * k, color: Palette.bannerText.color)
                        Text(line.text).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let button = line.button {
                            SettingsButton(title: button.title) { press(button) }
                        }
                    }
                }
            }
            .font(.system(size: 12 * k))
            .foregroundColor(Palette.bannerText.color)
            .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.bannerBackground.color))
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 0, trailing: 12))
        }
    }
}

/// `Couldn't dismiss: daemon not running` (Main.html `.fail`): set apart
/// from the yellow warning band, below it.
struct FailureBand: View {
    var text: String
    @Environment(\.textScale) var k

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            IconView(icon: BoardIcons.failure, size: 14 * k, color: Palette.orangeText.color)
            Text(text).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12 * k))
        .foregroundColor(Palette.orangeText.color)
        .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.orangeIconBackground.color))
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 0, trailing: 12))
        .accessibilityElement(children: .combine)
    }
}

struct CenteredMessage: View {
    var title: String
    var detail: String?
    var button: String
    var action: () -> Void
    @Environment(\.textScale) var k

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Text(title).font(.system(size: 13 * k, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 12 * k)).foregroundColor(Palette.secondary.color)
            }
            SettingsButton(title: button, action: action)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Tabs and the search row

/// All | Review | Mine with their unread counts, and the Dismissed button
/// at the right end (Main.html `.ptabs`).
struct TabRow: View {
    @ObservedObject var list: SurfaceListModel
    @Environment(\.textScale) var k

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(ListTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
            dismissedButton
                .padding(.bottom, 3)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 0, trailing: 12))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border.color).frame(height: 1) }
    }

    func tabButton(_ tab: ListTab) -> some View {
        // No tab is underlined while the Dismissed list shows.
        let on = tab == list.tab && !list.showingDismissed
        let count = list.unreadCount(tab)
        return Button { list.openTab(tab) } label: {
            HStack(spacing: 5 * k) {
                Text(tab.title)
                    .font(.system(size: 12 * k, weight: on ? .semibold : .regular))
                    .foregroundColor(on ? Palette.text.color : Palette.secondary.color)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10 * k, weight: .bold))
                        .foregroundColor(Palette.blueDot.color)
                }
            }
            .padding(EdgeInsets(top: 4 * k, leading: 10, bottom: 6 * k, trailing: 10))
            .overlay(alignment: .bottom) {
                Rectangle().fill(on ? Palette.text.color : .clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "\(tab.title), \(count) unread" : tab.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    var dismissedButton: some View {
        let open = list.showingDismissed
        let count = list.dismissedCount
        let color = open ? Palette.settingsTabSelected.color : Palette.botIcon.color
        return Button { open ? list.closeDismissedList() : list.openDismissedList() } label: {
            HStack(spacing: 4) {
                IconView(icon: BoardIcons.dismissedBox, size: 14 * k, color: color)
                if count > 0 {
                    Text("\(count)").font(.system(size: 11 * k)).foregroundColor(color)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 22 * k)
            .background(RoundedRectangle(cornerRadius: 6).fill(open ? Palette.settingsTabSelectedBackground.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dismissed")
        .accessibilityLabel(count > 0 ? "Dismissed, \(count)" : "Dismissed")
    }
}

/// The search field (the only part that grows), then in All the Group by,
/// Then by and sort pop-up buttons showing their values.
struct SearchRow: View {
    @ObservedObject var list: SurfaceListModel
    @ObservedObject var model: AccountViewModel
    @FocusState private var focused: Bool
    @Environment(\.textScale) var k

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                IconView(icon: BoardIcons.search, size: 13 * k, color: Palette.waiting.color)
                TextField("Search", text: Binding(get: { list.search }, set: { list.setSearch($0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12 * k))
                    .focused($focused)
                    .accessibilityLabel("Search")
            }
            .padding(.horizontal, 8)
            .frame(height: 24 * k)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.controlBorder.color, lineWidth: 1))
            .frame(maxWidth: .infinity)
            if list.tab == .all && !list.showingDismissed {
                let options = model.options
                PullDown(title: options.groupBy.title, toolTip: "Group by", items: groupByItems(options))
                PullDown(title: options.thenByTitle, toolTip: "Then by", enabled: options.groupBy != .none, items: thenByItems(options))
                PullDown(title: options.sort.title, toolTip: "Sort", items: SortOrder.allCases.map { order in
                    IconMenuItem(order.title, checked: order == options.sort) { model.setSort(order) }
                })
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .onChange(of: list.searchFocused) { _, value in if focused != value { focused = value } }
        .onChange(of: focused) { _, value in if list.searchFocused != value { list.searchFocused = value } }
    }

    /// The five values, the current one checked, then `Grouping…`.
    func groupByItems(_ options: ListOptions) -> [IconMenuItem?] {
        var items: [IconMenuItem?] = GroupBy.allCases.map { value in
            IconMenuItem(value.title, checked: value == options.groupBy) { model.setGroupBy(value) }
        }
        items.append(nil)
        items.append(IconMenuItem("Grouping…") { list.showsGrouping = true })
        return items
    }

    /// The same values without Group by's.
    func thenByItems(_ options: ListOptions) -> [IconMenuItem?] {
        options.thenByChoices.map { value in
            IconMenuItem(value.title, checked: value == options.thenBy) { model.setThenBy(value) }
        }
    }
}

/// A standard pull-down pop-up button whose title is the current value
/// (NSPopUpButton with `pullsDown`: the first item is the title and the rest
/// are the menu). A pull-down, so that Group by can end with `Grouping…`
/// and Then by can read `Then by` while it is None.
struct PullDown: NSViewRepresentable {
    var title: String
    var toolTip: String
    var enabled = true
    var items: [IconMenuItem?]
    @Environment(\.textScale) var k

    final class Coordinator {
        var targets: [IconMenu.Target] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        update(button, context: context)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        update(button, context: context)
    }

    private func update(_ button: NSPopUpButton, context: Context) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        var targets: [IconMenu.Target] = []
        for item in items {
            guard let item else {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: item.title, action: #selector(IconMenu.Target.run(_:)), keyEquivalent: "")
            let target = IconMenu.Target(item.action)
            entry.target = target
            entry.state = item.checked ? .on : .off
            entry.isEnabled = item.enabled
            targets.append(target)
            menu.addItem(entry)
        }
        context.coordinator.targets = targets
        button.menu = menu
        button.font = .systemFont(ofSize: 11 * k)
        button.isEnabled = enabled
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// `← Dismissed`, the PR count and the note (Main.html `.dhead`).
struct DismissedHeading: View {
    @ObservedObject var list: SurfaceListModel
    var keepDays: Int64
    @Environment(\.textScale) var k

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { list.closeDismissedList() } label: {
                    Text("\u{2190}").font(.system(size: 13 * k)).foregroundColor(Palette.strongText.color)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle())
                .accessibilityLabel("Back")
                Text("Dismissed").font(.system(size: 12 * k, weight: .semibold))
                Text(list.dismissedCount == 1 ? "1 PR" : "\(list.dismissedCount) PRs")
                    .font(.system(size: 11 * k)).foregroundColor(Palette.secondary.color)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 2, leading: 12, bottom: 4, trailing: 14))
            Text(DismissedText.note(keepDays: keepDays))
                .font(.system(size: 11 * k))
                .foregroundColor(Palette.waiting.color)
                .padding(EdgeInsets(top: 2, leading: 16, bottom: 8, trailing: 16))
        }
    }
}

/// The hint line: wraps to a second line when it does not fit (DESIGN.md,
/// "Keyboard").
struct KeyHints: View {
    var hints: [KeyHint]
    @Environment(\.textScale) var k

    var body: some View {
        FlowLayout(spacing: 9, lineSpacing: 2) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 3) {
                    Text(hint.key)
                        .font(.system(size: 11 * k, design: .monospaced))
                        .foregroundColor(Palette.strongText.color)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Palette.tint.color))
                    Text(hint.text)
                }
                .fixedSize()
            }
        }
        .font(.system(size: 11 * k))
        .foregroundColor(Palette.secondary.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 6, leading: 14, bottom: 8, trailing: 12))
        .overlay(alignment: .top) { Rectangle().fill(Palette.border.color).frame(height: 1) }
    }
}

/// Lays its views out in rows, wrapping to the next row when the width runs
/// out (the SwiftUI `Layout` protocol, macOS 13 and later).
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func rows(_ width: CGFloat, _ subviews: Subviews) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((index, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let rows = rows(width, subviews)
        let height = rows.map { $0.map(\.1.height).max() ?? 0 }.reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        let used = rows.map { row in row.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            let height = row.map(\.1.height).max() ?? 0
            for (index, size) in row {
                subviews[index].place(at: CGPoint(x: x, y: y + (height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + lineSpacing
        }
    }
}

// MARK: - Grouping sheet

/// The Grouping sheet (Main.html `.gsheet`): Group by and Then by, then the
/// order of each chosen value's groups, changed by dragging a row. Shown
/// inside the popover or the window; Done closes it.
struct GroupingSheet: View {
    @ObservedObject var model: AccountViewModel
    var done: () -> Void
    @Environment(\.textScale) var k

    var body: some View {
        let options = model.options
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(alignment: .leading, spacing: 10) {
                Text("Grouping").font(.system(size: 13 * k, weight: .semibold))
                HStack(spacing: 8) {
                    Text("Group by").font(.system(size: 11 * k, weight: .semibold)).foregroundColor(Palette.strongText.color)
                    PullDown(title: options.groupBy.title, toolTip: "Group by", items: GroupBy.allCases.map { value in
                        IconMenuItem(value.title, checked: value == options.groupBy) { model.setGroupBy(value) }
                    })
                    Text("Then by").font(.system(size: 11 * k, weight: .semibold)).foregroundColor(Palette.strongText.color)
                    PullDown(
                        title: options.thenByTitle, toolTip: "Then by", enabled: options.groupBy != .none,
                        items: options.thenByChoices.map { value in
                            IconMenuItem(value.title, checked: value == options.thenBy) { model.setThenBy(value) }
                        }
                    )
                    Spacer(minLength: 0)
                }
                ForEach([options.groupBy, options.thenBy].filter { $0 != .none }, id: \.self) { by in
                    Text("Order of " + by.title).font(.system(size: 11 * k, weight: .semibold)).foregroundColor(Palette.strongText.color)
                    GroupOrderList(model: model, by: by)
                }
                HStack {
                    Spacer()
                    SettingsButton(title: "Done", action: done)
                }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Palette.settingsBackground.color)
                    .shadow(color: .black.opacity(0.22), radius: 15, y: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.settingsTabBarBorder.color, lineWidth: 1))
            .padding(EdgeInsets(top: 118, leading: 20, bottom: 20, trailing: 20))
        }
    }
}

/// One group order, its rows moved by dragging (List `onMove`).
struct GroupOrderList: View {
    @ObservedObject var model: AccountViewModel
    var by: GroupBy
    @Environment(\.textScale) var k

    var body: some View {
        let groups = model.groups(by)
        List {
            ForEach(groups) { group in
                HStack(spacing: 8) {
                    Text("\u{2261}").foregroundColor(Palette.grip.color)
                    Text(group.title).lineLimit(1)
                }
                .font(.system(size: 12 * k))
            }
            .onMove { source, destination in model.moveGroups(by, from: source, to: destination) }
        }
        .listStyle(.plain)
        .frame(height: min(CGFloat(groups.count), 6) * 24 * k + 4)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.groupBorder.color, lineWidth: 1))
    }
}

// MARK: - No accounts

/// The popover of the shiibar-gh icon while there is no account
/// (MenuBarIcon.html), or the unreadable state.
struct NoAccountsView: View {
    static let height: CGFloat = 200
    @ObservedObject var app: AppModel
    var actions: SurfaceActions

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                MenuIconButton(icon: BoardIcons.chevron, label: "More", items: actions.menuItems)
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 10))
            switch SurfaceRules.noAccountsContent(dbUnreadable: app.dbUnreadable) {
            case .unreadable:
                CenteredMessage(title: EmptyState.unreadable, button: "Reset") { app.reset() }
            case .noAccounts:
                if let dialog = KeychainDialog.for(app.keychain) {
                    BannerView(lines: [BannerLine.keychain(dialog)]) { app.bannerButton($0, account: nil) }
                }
                CenteredMessage(title: EmptyState.noAccountsTitle, detail: EmptyState.noAccountsDetail, button: "Add account…") {
                    actions.openSettings(.addAccount)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .background(Palette.background.color)
        .foregroundColor(Palette.text.color)
    }
}
