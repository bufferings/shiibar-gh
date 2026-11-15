// The popover of one account, also the content of its window
// (docs/design/Main.html, Keychain.html, MenuBarIcon.html): the header,
// the banners, the tab row, the operation row (the search field and
// `Filter`), the Filter's options (FilterViews.swift), the list
// (CardViews.swift), the key hints and the Grouping sheet.
//
// Sizes are the boards' points at text size 12, multiplied by
// `textScale` (DESIGN.md, "Text size"): the fonts are fixed point sizes
// (`.system(size:)`), so the app scales the numbers itself instead of using
// Dynamic Type, which macOS SwiftUI does not apply to fixed sizes.

import AppKit
import Combine
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

/// A value the surface shows, worked out from the models and published
/// only when it changes. A change of the models (a dismiss, a new list, the
/// time of the last update) draws again only the parts whose values changed,
/// not every view of the surface (DESIGN.md, "Speed of operation").
@MainActor
final class Derived<Value: Equatable>: ObservableObject {
    @Published private(set) var value: Value
    private let compute: () -> Value
    private var watch: AnyCancellable?

    init(_ triggers: [AnyPublisher<Void, Never>], _ compute: @escaping () -> Value) {
        self.compute = compute
        value = compute()
        watch = Publishers.MergeMany(triggers).sink { [weak self] in
            guard let self else { return }
            DerivedFlush.mark(ObjectIdentifier(self)) { [weak self] in self?.update() }
        }
    }

    func update() {
        let next = compute()
        if next != value { value = next }
    }
}

/// Works the marked values out again once per run loop pass, after the
/// models changed (they publish before they change) and before SwiftUI
/// updates its views (a main run loop observer of order -1, below SwiftUI's
/// and the list's 0; see ListTable.swift).
@MainActor
enum DerivedFlush {
    private static var pending: [ObjectIdentifier: () -> Void] = [:]
    private static var observer: CFRunLoopObserver?

    static func mark(_ id: ObjectIdentifier, _ update: @escaping () -> Void) {
        pending[id] = update
        if observer == nil {
            observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, -1) { _, _ in
                MainActor.assumeIsolated { flush() }
            }
            if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    static func flush() {
        while !pending.isEmpty {
            let updates = pending.values
            pending = [:]
            for update in updates { update() }
        }
    }
}

/// The header, the banners and what the surface shows below them.
struct SurfaceTop: Equatable {
    var k: CGFloat
    var account: Account?
    var dbUnreadable: Bool
    var usage: ApiUsage
    var failure: String?
    var refreshing: Bool
    var keepOnTop: Bool
    var keepDays: Int64
}

/// The tab row.
struct TabRowState: Equatable {
    var tab: ListTab
    var showingDismissed: Bool
    var counts: [ListTab: Int]
    var compact: Bool
    var dismissedCount: Int
}

/// The operation row: the search field and `Filter`.
struct OperationRowState: Equatable {
    var search: String
    var tab: ListTab
    var showingDismissed: Bool
    var focused: Bool
    var filterOpen: Bool
    var summary: String?
    var dot: Bool

    /// `Filter` shows (not in the Dismissed list).
    var showsFilter: Bool { !showingDismissed }
}

/// The `← Dismissed` heading: shown, and the count.
struct DismissedHeadingState: Equatable {
    var showing: Bool
    var count: Int
}

/// The derived values of one surface.
@MainActor
final class SurfaceState {
    let top: Derived<SurfaceTop>
    let tabs: Derived<TabRowState>
    let search: Derived<OperationRowState>
    let options: Derived<FilterOptionsState>
    let dismissed: Derived<DismissedHeadingState>
    let grouping: Derived<Bool>

    init(app: AppModel, model: AccountViewModel, list: SurfaceListModel) {
        let appChanges = app.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        let modelChanges = model.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        let listChanges = list.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        top = Derived([appChanges, modelChanges]) { [unowned app, unowned model] in
            SurfaceTop(
                k: CGFloat(TextSize.ratio(app.textSize)), account: app.account(model.accountId), dbUnreadable: app.dbUnreadable,
                usage: model.usage, failure: model.failure, refreshing: app.refreshing.contains(model.accountId),
                keepOnTop: model.keepOnTop, keepDays: app.keepDays
            )
        }
        // The list forwards its account's changes.
        tabs = Derived([listChanges]) { [unowned list] in
            TabRowState(
                tab: list.tab, showingDismissed: list.showingDismissed,
                counts: Dictionary(uniqueKeysWithValues: ListTab.allCases.map { ($0, list.unreadCount($0)) }),
                compact: list.compact, dismissedCount: list.dismissedCount
            )
        }
        search = Derived([listChanges]) { [unowned list] in
            OperationRowState(
                search: list.search, tab: list.tab, showingDismissed: list.showingDismissed, focused: list.searchFocused,
                filterOpen: list.filterOpen, summary: list.showsFilter ? list.filter.summary : nil,
                dot: list.showsFilter && list.filterDot
            )
        }
        options = Derived([listChanges]) { [unowned list, unowned model] in
            FilterOptionsState(
                shows: list.showsFilterOptions, tab: list.tab, filter: list.filter, options: model.options
            )
        }
        dismissed = Derived([listChanges]) { [unowned list] in
            DismissedHeadingState(showing: list.showingDismissed, count: list.showingDismissed ? list.dismissedCount : 0)
        }
        grouping = Derived([listChanges]) { [unowned list] in list.showsGrouping }
    }
}

struct PopoverView: View {
    var app: AppModel
    var model: AccountViewModel
    /// This surface's own tab, search, selection and expanded
    /// rows. Not observed here: the parts that show them follow derived
    /// values (`SurfaceState`), so a change draws only the parts it changes.
    var list: SurfaceListModel
    var avatars: AvatarStore
    var actions: SurfaceActions
    var surface: Surface
    var state: SurfaceState
    @ObservedObject var top: Derived<SurfaceTop>

    init(
        app: AppModel, model: AccountViewModel, list: SurfaceListModel, avatars: AvatarStore, actions: SurfaceActions, surface: Surface,
        state: SurfaceState
    ) {
        self.app = app
        self.model = model
        self.list = list
        self.avatars = avatars
        self.actions = actions
        self.surface = surface
        self.state = state
        top = state.top
    }

    var body: some View {
        let k = top.value.k
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
        let value = top.value
        let account = value.account
        VStack(spacing: 0) {
            Header(
                login: account?.login ?? "", color: account?.accountColor ?? .none,
                updated: value.dbUnreadable ? nil : RelativeTime.updated(account?.updatedAt, now: now),
                usage: value.usage, keepOnTop: value.keepOnTop, toggleKeepOnTop: { [model] in model.toggleKeepOnTop() },
                surface: surface, refreshing: value.refreshing, actions: actions, refresh: { [app, model] in app.refresh(model.accountId) }
            )
            .background {
                ZStack {
                    // The window moves by its whole header (DESIGN.md,
                    // "Open in window"), not only by the thin title strip.
                    if surface == .window { WindowDragArea() }
                    SurfaceAnchor(content: CardContext.of(list, avatars: avatars).content, part: .header)
                }
            }
            switch SurfaceRules.content(account: account, dbUnreadable: value.dbUnreadable) {
            case .unreadable:
                CenteredMessage(title: EmptyState.unreadable, button: "Reset") { app.reset() }
            case .noOwners:
                BannerView(lines: Warnings.banner(account?.warnings ?? [], now: now)) { app.bannerButton($0, account: model.accountId) }
                CenteredMessage(title: EmptyState.noOwnersTitle, detail: EmptyState.noOwnersDetail, button: "Settings") {
                    actions.openSettings(.account(model.accountId))
                }
            case .list:
                BannerView(lines: Warnings.banner(account?.warnings ?? [], now: now)) { app.bannerButton($0, account: model.accountId) }
                if let failure = value.failure {
                    FailureBand(text: failure)
                }
                TabRow(list: list, state: state.tabs)
                OperationRow(list: list, state: state.search)
                // The options take their height when there is room; the
                // list keeps its minimum, and the options scroll inside
                // (DESIGN.md, "Filter").
                FilterOptionsSlot(list: list, model: model, state: state.options)
                    .layoutPriority(1)
                DismissedHeadingSlot(list: list, state: state.dismissed, keepDays: value.keepDays)
                ListSlot(content: CardContext.of(list, avatars: avatars).content, now: now)
                    .frame(minHeight: FilterOptionsLayout.listMinimum * value.k)
                KeyHintsSlot(chrome: list.chrome)
                    .background(SurfaceAnchor(content: CardContext.of(list, avatars: avatars).content, part: .hints))
            }
        }
    }

    /// The root of the surface: this view, the list (ListTable.swift) and
    /// the Grouping sheet over both.
    static func root(
        app: AppModel, model: AccountViewModel, list: SurfaceListModel, avatars: AvatarStore, actions: SurfaceActions, surface: Surface
    ) -> SurfaceRoot {
        let state = SurfaceState(app: app, model: model, list: list)
        return SurfaceRoot(
            content: PopoverView(app: app, model: model, list: list, avatars: avatars, actions: actions, surface: surface, state: state),
            overlay: GroupingOverlay(top: state.top, grouping: state.grouping, list: list, model: model),
            list: CardContext.of(list, avatars: avatars).content
        )
    }
}

/// The Grouping sheet, over the list too, with the surface's text size.
struct GroupingOverlay: View {
    @ObservedObject var top: Derived<SurfaceTop>
    @ObservedObject var grouping: Derived<Bool>
    var list: SurfaceListModel
    var model: AccountViewModel

    var body: some View {
        let k = top.value.k
        if grouping.value {
            GroupingSheet(model: model) { list.showsGrouping = false }
                .foregroundColor(Palette.text.color)
                .font(.system(size: 13 * k))
                .environment(\.textScale, k)
        }
    }
}

// MARK: - Header

/// Behind the window's header: a press on its empty parts and its texts
/// (not on its buttons, which are in front) moves the window, as the title
/// bar does (`performWindowDragWithEvent:`, NSWindow.h, macOS 10.11: "Starts
/// a window drag based on the specified mouse-down event").
final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    /// The press that brings the window forward moves it too: while
    /// another app or window has the focus, the first press reaches the
    /// view (NSView.h, `acceptsFirstMouse:`; the hosting view, which took
    /// the title strip before, does not take a first press, so a window
    /// out of focus did not move from there: the same in 0.4.0).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }

    func updateNSView(_ view: WindowDragView, context: Context) {}
}

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
    var keepOnTop: Bool
    var toggleKeepOnTop: () -> Void
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
                    // "Updated 1 min ago · API [25%]" (DESIGN.md, "Rate
                    // limits").
                    HStack(spacing: 0) {
                        Text(updated + " · ").foregroundColor(Palette.secondary.color)
                        UsageView(usage: usage)
                    }
                    .font(.system(size: 11 * k))
                    .lineLimit(1)
                }
            }
            // A press on the texts goes to what is behind them: in the
            // window, the drag area that moves it.
            .allowsHitTesting(false)
            Spacer(minLength: 0)
            if surface == .window {
                PinButton(on: keepOnTop, toggle: toggleKeepOnTop)
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

/// `API` and one bar with the percentage inside, like a battery (Main.html
/// `.api` and `.batt`): the higher usage rate of GraphQL and REST. No
/// numbers and no tooltip; `API –` before any value (DESIGN.md, "Rate
/// limits").
struct UsageView: View {
    var usage: ApiUsage
    @Environment(\.textScale) var k

    var body: some View {
        HStack(spacing: 0) {
            Text("API")
                .fontWeight(usage.warn ? .semibold : .regular)
                .foregroundColor(usage.warn ? Palette.caution.color : Palette.secondary.color)
            if let fraction = usage.fraction, let percent = usage.percent {
                ZStack(alignment: .leading) {
                    Rectangle().fill(Palette.usageTrack.color)
                    Rectangle()
                        .fill(usage.warn ? Palette.usageWarnFill.color : Palette.usageFill.color)
                        .frame(width: 40 * k * CGFloat(fraction))
                    Text(percent)
                        .font(.system(size: 9 * k, weight: .bold))
                        .foregroundColor(usage.warn ? Palette.usageWarnText.color : Palette.text.color)
                        .frame(width: 40 * k)
                }
                .frame(width: 40 * k, height: 12 * k)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(.leading, 5)
            } else {
                Text(" \u{2013}").foregroundColor(Palette.secondary.color)
            }
        }
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
        .quickHelp("Refreshing")
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
        .quickHelp("Keep on top")
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

/// All | Review | Mine with their unread counts, and at the right end the
/// display mode switch (`Detailed` and `Compact`, icons, their names in the
/// tooltips) and the Dismissed button (Main.html `.ptabs`; DESIGN.md,
/// "Screens", "Compact").
struct TabRow: View {
    var list: SurfaceListModel
    @ObservedObject var state: Derived<TabRowState>
    @Environment(\.textScale) var k

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(ListTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
            compactButton
                .padding(.bottom, 3)
            dismissedButton
                .padding(.bottom, 3)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 0, trailing: 12))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border.color).frame(height: 1) }
    }

    func tabButton(_ tab: ListTab) -> some View {
        // No tab is underlined while the Dismissed list shows.
        let value = state.value
        let on = tab == value.tab && !value.showingDismissed
        let count = value.counts[tab] ?? 0
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

    /// Detailed and Compact (DESIGN.md, "Compact"): the display mode as a
    /// two-segment switch (FilterViews.swift, `DisplayModeSwitch`).
    var compactButton: some View {
        DisplayModeSwitch(mode: state.value.compact ? .compact : .detailed) { [list] mode in
            if (mode == .compact) != list.compact { list.toggleCompact() }
        }
    }

    var dismissedButton: some View {
        let open = state.value.showingDismissed
        let count = state.value.dismissedCount
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
        .quickHelp("Dismissed")
        .accessibilityLabel(count > 0 ? "Dismissed, \(count)" : "Dismissed")
    }
}

/// The search field, which takes the room left (at least 140 points at
/// text size 12), then `Filter` (FilterViews.swift); the search field only
/// while the Dismissed list shows (DESIGN.md, "Screens").
struct OperationRow: View {
    var list: SurfaceListModel
    @ObservedObject var state: Derived<OperationRowState>
    @FocusState private var focused: Bool
    @Environment(\.textScale) var k

    var body: some View {
        let value = state.value
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
            .frame(minWidth: FilterOptionsLayout.searchMinimum * k, maxWidth: .infinity)
            if value.showsFilter {
                FilterButton(open: value.filterOpen, dot: value.dot, summary: value.summary) { list.toggleFilterOpen() }
                    .layoutPriority(1)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .onChange(of: state.value.focused) { _, value in if focused != value { focused = value } }
        .onChange(of: focused) { _, value in if list.searchFocused != value { list.searchFocused = value } }
    }
}

/// A standard pull-down pop-up button whose title is the current value
/// (NSPopUpButton with `pullsDown`: the first item is the title and the rest
/// are the menu). A pull-down, so that Group by can end with `Grouping…`.
/// In the Filter's options it never takes the keyboard focus
/// (`refusesFocus`); in the Grouping sheet it does, as in 0.5 (DESIGN.md,
/// "Filter").
struct PullDown: NSViewRepresentable {
    var title: String
    /// nil: no tooltip (the Filter's rows have names).
    var toolTip: String?
    var accessibilityName: String
    var enabled = true
    /// The narrowest it gets, at text size 12.
    var minWidth: CGFloat = 0
    /// Mouse only (the Filter's options).
    var refusesFocus: Bool
    var items: [IconMenuItem?]

    init(
        title: String, toolTip: String?, accessibilityName: String? = nil, enabled: Bool = true, minWidth: CGFloat = 0,
        refusesFocus: Bool = false, items: [IconMenuItem?]
    ) {
        self.title = title
        self.toolTip = toolTip
        self.accessibilityName = accessibilityName ?? toolTip ?? title
        self.enabled = enabled
        self.minWidth = minWidth
        self.refusesFocus = refusesFocus
        self.items = items
    }
    @Environment(\.textScale) var k

    final class Coordinator {
        var targets: [IconMenu.Target] = []
        /// What the menu shows: it is made again only when this changes.
        var shown: [String] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TipPopUpButton {
        let button = TipPopUpButton(frame: .zero, pullsDown: true)
        button.controlSize = .small
        button.refusesFocus = refusesFocus
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        update(button, context: context)
        return button
    }

    func updateNSView(_ button: TipPopUpButton, context: Context) {
        update(button, context: context)
    }

    private func update(_ button: TipPopUpButton, context: Context) {
        let coordinator = context.coordinator
        let shown = [title, "\(enabled)", "\(k)"] + items.map { item in
            item.map { "\($0.title)|\($0.checked)|\($0.enabled)" } ?? "-"
        }
        if shown == coordinator.shown {
            // The same menu: only the actions are new.
            for (target, item) in zip(coordinator.targets, items.compactMap { $0 }) { target.action = item.action }
            return
        }
        coordinator.shown = shown
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
        coordinator.targets = targets
        button.menu = menu
        button.font = .systemFont(ofSize: 11 * k)
        button.isEnabled = enabled
        button.help = toolTip
        button.setAccessibilityLabel(accessibilityName)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TipPopUpButton, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        return CGSize(width: max(size.width, minWidth * k), height: size.height)
    }
}

/// A pop-up button whose tooltip `QuickTip` shows (DESIGN.md, "Screens":
/// every tooltip after about 0.4 s; AppKit's `toolTip` has no setting for
/// its delay).
final class TipPopUpButton: NSPopUpButton {
    var help: String?

    /// Mouse only (the Filter's options): the keys stay with the list and
    /// the search field (DESIGN.md, "Filter"), Full Keyboard Access or not.
    /// Off, the standard pop-up button (the Grouping sheet).
    var refusesFocus = false {
        didSet { refusesFirstResponder = refusesFocus }
    }

    override var acceptsFirstResponder: Bool { refusesFocus ? false : super.acceptsFirstResponder }
    override var canBecomeKeyView: Bool { refusesFocus ? false : super.canBecomeKeyView }
    override func becomeFirstResponder() -> Bool { refusesFocus ? false : super.becomeFirstResponder() }
    private let tipOwner = QuickTip.Owner()
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if let help { QuickTip.schedule(help, owner: tipOwner, appearance: effectiveAppearance) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        QuickTip.cancel(owner: tipOwner)
    }

    override func mouseDown(with event: NSEvent) {
        QuickTip.cancel(owner: tipOwner)
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { QuickTip.cancel(owner: tipOwner) }
    }
}

/// `← Dismissed`, the PR count and the note (Main.html `.dhead`).
struct DismissedHeading: View {
    var list: SurfaceListModel
    var count: Int
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
                Text(count == 1 ? "1 PR" : "\(count) PRs")
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

/// The parts below observe the surface themselves.
struct DismissedHeadingSlot: View {
    var list: SurfaceListModel
    @ObservedObject var state: Derived<DismissedHeadingState>
    var keepDays: Int64

    var body: some View {
        if state.value.showing {
            DismissedHeading(list: list, count: state.value.count, keepDays: keepDays)
        }
    }
}

struct KeyHintsSlot: View {
    @ObservedObject var chrome: SurfaceChrome

    var body: some View {
        KeyHints(hints: chrome.hints)
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
