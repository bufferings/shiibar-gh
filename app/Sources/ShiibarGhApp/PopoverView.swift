// The popover of one account, also the content of its window
// (docs/design/Main.html, Activity.html, Keychain.html, Sheets.html).
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
    /// This surface's own tab, search, selection and fold.
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
                usage: model.usage, model: model, surface: surface,
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
                Tabs(tab: $list.tab)
                if list.tab == .prs {
                    ChipRow(model: model)
                } else if let account {
                    OwnerButtons(account: account, model: model)
                }
                SearchRow(model: list)
                ListArea(app: app, model: list, avatars: avatars, now: now)
                KeyHints(hints: list.hints)
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
                    // "Updated 1 min ago · API 25%" (DESIGN.md, "Rate limits").
                    HStack(spacing: 0) {
                        Text(updated + " · ").foregroundColor(Palette.secondary.color)
                        Text(usage.text)
                            .fontWeight(usage.warn ? .semibold : .regular)
                            .foregroundColor(usage.warn ? Palette.caution.color : Palette.secondary.color)
                            .help(usage.tooltip ?? "")
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
            HeaderButton(icon: BoardIcons.refresh, size: 16, label: "Refresh", action: refresh)
            HeaderButton(icon: BoardIcons.settings, size: 16, label: "Settings") { actions.openSettings(.general) }
            MenuIconButton(icon: BoardIcons.chevron, label: "More", items: actions.menuItems)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 10))
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

// MARK: - Tabs and the filter rows

struct Tabs: View {
    @Binding var tab: PopoverTab
    @Environment(\.textScale) var k

    var body: some View {
        HStack(spacing: 2) {
            tabButton("PRs", .prs)
            tabButton("Activity", .activity)
            Spacer()
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 0, trailing: 12))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border.color).frame(height: 1) }
    }

    func tabButton(_ title: String, _ value: PopoverTab) -> some View {
        let on = tab == value
        return Button { tab = value } label: {
            Text(title)
                .font(.system(size: 12 * k, weight: on ? .semibold : .regular))
                .foregroundColor(on ? Palette.text.color : Palette.secondary.color)
                .padding(EdgeInsets(top: 4 * k, leading: 10, bottom: 6 * k, trailing: 10))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(on ? Palette.text.color : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A push-in button, the standard macOS control whose on state takes the
/// system accent color (DESIGN.md, "Screens"), as wide as its text.
struct ChipButton: View {
    var title: String
    var on: Bool
    var press: () -> Void
    @Environment(\.textScale) var k

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { _ in press() })) {
            Text(title).font(.system(size: 11 * k))
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }
}

/// Row 1 of the PRs tab: All, Authored by me, Assigned to me, Review
/// requested; one is always on. Left-aligned; it does not stretch.
struct ChipRow: View {
    @ObservedObject var model: AccountViewModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PrFilter.allCases, id: \.self) { segment in
                ChipButton(title: ListOptions.title(segment), on: model.options.segment == segment) {
                    model.options.segment = segment
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 0, trailing: 12))
    }
}

/// Activity: `All owners`, then one button per owner; several can be on.
struct OwnerButtons: View {
    var account: Account
    @ObservedObject var model: AccountViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ChipButton(title: "All owners", on: model.allOwnersOn) { model.showAllOwners() }
                ForEach(ActivityOwners.buttons(account)) { owner in
                    ChipButton(title: owner.displayName, on: model.isOwnerOn(owner.id)) { model.toggleOwner(owner.id) }
                }
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 0, trailing: 12))
        }
    }
}

/// Row 2: the search field (the only part that grows), then Group by and
/// the sort order on the PRs tab, as pop-up buttons showing their value.
struct SearchRow: View {
    @ObservedObject var model: SurfaceListModel
    @FocusState private var focused: Bool
    @Environment(\.textScale) var k

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                IconView(icon: BoardIcons.search, size: 13 * k, color: Palette.waiting.color)
                TextField("Search", text: Binding(get: { model.search }, set: { model.setSearch($0) }))
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
            if model.tab == .prs {
                Picker("Group by", selection: Binding(get: { model.data.options.groupBy }, set: { model.data.options.groupBy = $0 })) {
                    ForEach(GroupBy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Group by")
                Picker("Sort", selection: Binding(get: { model.data.options.sort }, set: { model.data.options.sort = $0 })) {
                    ForEach(SortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Sort")
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .onChange(of: model.searchFocused) { _, value in if focused != value { focused = value } }
        .onChange(of: focused) { _, value in if model.searchFocused != value { model.searchFocused = value } }
    }
}

struct KeyHints: View {
    var hints: [KeyHint]
    @Environment(\.textScale) var k

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 3) {
                    Text(hint.key)
                        .font(.system(size: 11 * k, design: .monospaced))
                        .foregroundColor(Palette.strongText.color)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Palette.tint.color))
                    Text(hint.text)
                }
            }
            Spacer()
        }
        .font(.system(size: 11 * k))
        .foregroundColor(Palette.secondary.color)
        .lineLimit(1)
        .padding(EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16))
        .overlay(alignment: .top) { Rectangle().fill(Palette.border.color).frame(height: 1) }
    }
}

// MARK: - The list

struct ListArea: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: SurfaceListModel
    @ObservedObject var avatars: AvatarStore
    var now: Int64

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(spacing: 0) {
                    if model.tab == .prs {
                        prs
                    } else {
                        activity
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: model.selection) { _, selection in
                if let selection {
                    withAnimation(.easeOut(duration: 0.1)) { reader.scrollTo(selection.id) }
                }
            }
        }
    }

    @ViewBuilder
    var prs: some View {
        if let empty = model.emptyText {
            EmptyList(text: empty)
        }
        ForEach(model.sections) { section in
            if section.showsHeader {
                SectionHeaderView(section: section, model: model)
            }
            ForEach(section.cards) { card in
                CardView(card: card, model: model, avatars: avatars, now: now)
            }
            if let more = section.moreText {
                MoreRow(text: more, section: section.key, model: model)
            }
        }
    }

    @ViewBuilder
    var activity: some View {
        let rows = model.activity
        if let empty = model.activityEmptyText {
            EmptyList(text: empty)
        } else if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    RowView(row: row, model: model, now: now, showsPR: true, card: nil)
                }
            }
            .background(Palette.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border.color, lineWidth: 1))
            .padding(.horizontal, 12)
        }
    }
}

/// A section header (Main.html `.sec`): the name, the red count of PRs
/// waiting for your review, the PR count and the chevron. Pressing it folds
/// the section.
struct SectionHeaderView: View {
    var section: SectionLayout
    @ObservedObject var model: SurfaceListModel
    @Environment(\.textScale) var k

    var body: some View {
        let selected = model.selection == .section(section.key)
        Button { model.perform(.toggleSection(section.key)) } label: {
            HStack(spacing: 8) {
                Text(section.title)
                    .font(.system(size: 12 * k, weight: .semibold))
                    .foregroundColor(section.collapsed ? Palette.secondary.color : Palette.text.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let count = section.reviewCount {
                    Text("\(count)")
                        .font(.system(size: 10 * k, weight: .bold))
                        .foregroundColor(Palette.onColor.color)
                        .padding(.horizontal, 6 * k)
                        .frame(height: 15 * k)
                        .background(Capsule().fill(Palette.badge.color))
                }
                Text(section.detail).font(.system(size: 11 * k)).foregroundColor(Palette.secondary.color)
                IconView(icon: section.collapsed ? BoardIcons.sectionClosed : BoardIcons.sectionOpen, size: 12 * k, color: Palette.faded.color)
                    .frame(width: 14 * k, height: 14 * k)
            }
            .padding(EdgeInsets(top: 10 * k, leading: 16, bottom: 6 * k, trailing: 14))
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.selection.color : .clear).padding(.horizontal, 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(SelectionItem.section(section.key).id)
    }
}

/// "+ 2 more PRs": pressing it shows the rest.
struct MoreRow: View {
    var text: String
    var section: String
    @ObservedObject var model: SurfaceListModel
    @Environment(\.textScale) var k

    var body: some View {
        let selected = model.selection == .more(section)
        Button { model.perform(.expand(section)) } label: {
            Text(text)
                .font(.system(size: 12 * k))
                .foregroundColor(Palette.waiting.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 2 * k, leading: 12, bottom: 2 * k, trailing: 12))
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.selection.color : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))
        .id(SelectionItem.more(section).id)
    }
}

struct EmptyList: View {
    var text: String
    @Environment(\.textScale) var k

    var body: some View {
        Text(text)
            .font(.system(size: 12 * k))
            .foregroundColor(Palette.faded.color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40 * k)
    }
}

extension View {
    /// Click selects, double-click opens, right-click selects and shows the
    /// menu (DESIGN.md, "What a press does"). Buttons inside (the status
    /// icons, the clock) keep their own click.
    func pressable(_ item: SelectionItem, model: SurfaceListModel) -> some View {
        self
            .contentShape(Rectangle())
            .onTapGesture { model.select(item) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.doubleClick(item) })
            .overlay(RightClickArea(
                menu: { model.rightClick(item) },
                perform: { model.perform($0) }
            ))
    }
}

struct CardView: View {
    var card: Card
    @ObservedObject var model: SurfaceListModel
    @ObservedObject var avatars: AvatarStore
    var now: Int64
    @Environment(\.textScale) var k

    var stateBar: Color? {
        switch card.stateLabel.value {
        case .mergeable: return Palette.green.color
        case .draft: return Palette.gray.color
        case .merged: return Palette.purple.color
        case .closed: return Palette.badge.color
        default: return nil
        }
    }

    var body: some View {
        let item = SelectionItem.header(card: card.id)
        let selected = model.selection == item
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3 * k) {
                HStack(spacing: 7) {
                    StateLabelView(label: card.stateLabel)
                    Text(Warnings.prLabel(card.pr))
                        .font(.system(size: 11 * k))
                        .foregroundColor(Palette.secondary.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if card.awaitingReview {
                        ReviewRequestedMark()
                    }
                    Spacer(minLength: 0)
                    if !card.isFinished {
                        StatusIcons(card: card, model: model)
                    }
                }
                HStack(spacing: 6) {
                    Avatar(data: avatars.image(for: card.authorAvatarUrl))
                        .onAppear { avatars.request(card.authorAvatarUrl) }
                    Text(card.title)
                        .font(.system(size: 12 * k, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                // Line 3; the times wrap to a fourth line rather than shorten.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        branches
                        Spacer(minLength: 0)
                        times
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        branches
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            times
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 6 * k, leading: 12, bottom: 5 * k, trailing: 10))
            .background(selected ? Palette.selection.color : .clear)
            .pressable(item, model: model)
            .id(item.id)
            VStack(spacing: 0) {
                ForEach(card.rows) { row in
                    RowView(row: row, model: model, now: now, showsPR: false, card: card.id)
                }
            }
        }
        .background(Palette.surface.color)
        .overlay(alignment: .leading) {
            if let stateBar { Rectangle().fill(stateBar).frame(width: 4) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border.color, lineWidth: 1))
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))
    }

    var branches: some View {
        Text("\(card.base) \u{2190} \(card.head)")
            .font(.system(size: 11 * k))
            .foregroundColor(Palette.secondary.color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    var times: some View {
        HStack(spacing: 4) {
            Text(CardText.times(card, now: now))
                .font(.system(size: 11 * k))
                .foregroundColor(Palette.waiting.color)
                .lineLimit(1)
                .fixedSize()
                .help(CardText.exactTimes(card))
            // A snoozed card looks like any other; its clock unsnoozes
            // (DESIGN.md, "Snooze").
            Button { model.perform(card.snoozed ? .unsnooze(pr: card.pr) : .snooze(pr: card.pr)) } label: {
                IconView(icon: BoardIcons.clock, size: 14 * k, color: Palette.snoozeIcon.color)
                    .frame(width: 18 * k, height: 18 * k)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(card.snoozed ? "Unsnooze" : "Snooze")
            .accessibilityLabel(card.snoozed ? "Unsnooze" : "Snooze")
        }
    }
}

/// `Review requested` (Main.html `.rq`): light orange with dark orange text,
/// while the PR waits for your review.
struct ReviewRequestedMark: View {
    @Environment(\.textScale) var k

    var body: some View {
        Text(CardText.reviewRequestedMark)
            .font(.system(size: 10 * k, weight: .bold))
            .foregroundColor(Palette.orangeText.color)
            .padding(.horizontal, 6 * k)
            .frame(height: 16 * k)
            .background(RoundedRectangle(cornerRadius: 4).fill(Palette.reviewMark.color))
            .fixedSize()
    }
}

struct StateLabelView: View {
    var label: Lenient<StateLabel>
    @Environment(\.textScale) var k

    var body: some View {
        let style: (String, Color, Color)? = {
            switch label.value {
            case .mergeable: return ("Mergeable", Palette.green.color, Palette.onColor.color)
            case .draft: return ("Draft", Palette.tint.color, Palette.draftText.color)
            case .merged: return ("Merged", Palette.purpleBackground.color, Palette.purpleText.color)
            case .closed: return ("Closed", Palette.orangeIconBackground.color, Palette.orangeText.color)
            case .open, nil: return nil
            }
        }()
        if let (text, background, foreground) = style {
            Text(text)
                .font(.system(size: 10 * k, weight: .semibold))
                .foregroundColor(foreground)
                .padding(.horizontal, 6 * k)
                .frame(height: 16 * k)
                .background(RoundedRectangle(cornerRadius: 4).fill(background))
                .fixedSize()
        }
    }
}

struct StatusIcons: View {
    var card: Card
    var model: SurfaceListModel
    @Environment(\.textScale) var k

    var body: some View {
        HStack(spacing: 2) {
            slot(review, "Review", card.links.review)
            slot(checks, "Checks", card.links.checks)
            slot(base, "Base", card.links.base)
        }
    }

    var review: (StatusIcon.Look, String) {
        switch card.review.value {
        case .approved: return (.ok, "Approved")
        case .reviewRequired: return (.waiting, "Review required")
        case .changesRequested: return (.bad, "Changes requested")
        case .some(.none), nil: return (.empty, "None")
        }
    }

    var checks: (StatusIcon.Look, String) {
        switch card.checks.value {
        case .passed: return (.ok, "Passed")
        case .inProgress: return (.waiting, "In progress")
        case .failed: return (.bad, "Failed")
        case .some(.none), nil: return (.empty, "None")
        }
    }

    var base: (StatusIcon.Look, String) {
        switch card.baseStatus.value {
        case .upToDate: return (.ok, "Up to date")
        case .behind: return (.waiting, "Behind")
        case .conflicts: return (.bad, "Conflicts")
        case .some(.none), nil: return (.empty, "None")
        }
    }

    func slot(_ value: (StatusIcon.Look, String), _ axis: String, _ url: String) -> some View {
        Button { model.perform(.open(url, read: nil)) } label: {
            StatusIcon(look: value.0)
                .scaleEffect(k)
                .frame(width: 20 * k, height: 20 * k)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .help("\(axis): \(value.1)")
        .accessibilityLabel("\(axis): \(value.1)")
    }
}

struct Avatar: View {
    var data: Data?
    @Environment(\.textScale) var k

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Circle().fill(Palette.avatarFill.color).overlay(Circle().stroke(Palette.avatarBorder.color, lineWidth: 1))
            }
        }
        .frame(width: 16 * k, height: 16 * k)
        .clipShape(Circle())
    }
}

struct RowView: View {
    var row: Row
    @ObservedObject var model: SurfaceListModel
    var now: Int64
    var showsPR: Bool
    var card: String?
    @Environment(\.textScale) var k

    var body: some View {
        let p = RowPresentation(row, now: now)
        let item = SelectionItem.row(id: row.id, card: card)
        let selected = model.selection == item
        let textColor = p.dimmed ? Palette.waiting.color : Palette.text.color
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(p.unreadDot ? Palette.blueDot.color : .clear)
                .frame(width: 7 * k, height: 7 * k)
                .padding(.top, 6 * k)
            IconView(icon: BoardIcons.row(row.kind), size: 14 * k, color: p.dimmed ? Palette.readIcon.color : Palette.botIcon.color)
                .padding(.top, 2 * k)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(p.label)
                        .font(.system(size: 11 * k, weight: .semibold))
                        .foregroundColor(p.dimmed ? Palette.waiting.color : Palette.strongText.color)
                        .lineLimit(1)
                    if let counts = p.counts {
                        Text(counts).font(.system(size: 12 * k))
                    }
                    Text(p.meta)
                        .font(.system(size: 11 * k))
                        .foregroundColor(Palette.secondary.color)
                        .lineLimit(1)
                }
                if let body = p.body {
                    Text(body)
                        .font(.system(size: 12 * k))
                        .foregroundColor(textColor)
                        .lineLimit(p.bodyLines)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showsPR {
                    Text("\(Warnings.prLabel(row.pr)) · \(row.prTitle)")
                        .font(.system(size: 11 * k))
                        .foregroundColor(Palette.secondary.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 5 * k, leading: 14, bottom: 6 * k, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Palette.selection.color : Palette.surface.color)
        .overlay(alignment: .top) { Rectangle().fill(Palette.rowDivider.color).frame(height: 1) }
        .pressable(item, model: model)
        .id(item.id)
    }
}

/// Catches the right click (and the Control click) over an item, and only
/// that: other clicks pass through to the SwiftUI views below (NSView
/// `hitTest(_:)`, which the window uses to find the view for a mouse-down).
/// The item is selected (a row read) before the menu shows.
struct RightClickArea: NSViewRepresentable {
    var menu: () -> [MenuEntry?]
    var perform: (PopoverAction) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.handler = self
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.handler = self
    }

    final class CatcherView: NSView {
        var handler: RightClickArea?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isMenuClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isMenuClick ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            show(event)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { show(event) } else { super.mouseDown(with: event) }
        }

        private func show(_ event: NSEvent) {
            guard let handler else { return }
            let entries = handler.menu()
            guard !entries.isEmpty else { return }
            let perform = handler.perform
            let items: [IconMenuItem?] = entries.map { entry in
                entry.map { entry in IconMenuItem(entry.title) { perform(entry.action) } }
            }
            NSMenu.popUpContextMenu(IconMenu.make(items), with: event, for: self)
        }
    }
}

/// The popover of the shiibar-gh icon while there is no account
/// (DESIGN.md, "First run, failure and empty"), or the unreadable state.
struct NoAccountsView: View {
    @ObservedObject var app: AppModel
    var actions: SurfaceActions

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("shiibar-gh").font(.system(size: 14, weight: .semibold))
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
                CenteredMessage(title: EmptyState.noAccountsTitle, detail: EmptyState.noAccountsDetail, button: "Settings") {
                    actions.openSettings(.accounts)
                }
            }
        }
        .frame(width: 300, height: 200)
        .background(Palette.background.color)
        .foregroundColor(Palette.text.color)
    }
}
