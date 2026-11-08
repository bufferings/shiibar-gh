// The popover of one account, also the content of its window
// (docs/design/Main.html, Activity.html, Keychain.html, Sheets.html).

import AppKit
import ShiibarGhCore
import SwiftUI

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
    @ObservedObject var avatars: AvatarStore
    var actions: SurfaceActions
    var surface: Surface

    var account: Account? { app.account(model.accountId) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: Int64(context.date.timeIntervalSince1970))
        }
        .frame(minWidth: 400, minHeight: 300)
        .background(Palette.background.color)
        .foregroundColor(Palette.text.color)
        .font(.system(size: 13))
    }

    @ViewBuilder
    func content(now: Int64) -> some View {
        VStack(spacing: 0) {
            Header(
                login: account?.login ?? "", color: account?.accountColor ?? .none,
                updated: app.dbUnreadable ? nil : RelativeTime.updated(account?.updatedAt, now: now),
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
                Tabs(tab: $model.tab)
                if model.tab == .prs {
                    FilterRow(filter: $model.filter)
                } else if let account {
                    OwnerButtons(account: account, model: model)
                }
                ListArea(app: app, model: model, avatars: avatars, now: now, surface: surface)
                UsageRow(bars: UsageBar.bars(account?.rateLimit))
                KeyHints(hints: model.hints)
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
    var actions: SurfaceActions
    var refresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    AccountDot(color: color)
                    Text(login).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                }
                if let updated {
                    Text(updated).font(.system(size: 11)).foregroundColor(Palette.secondary.color)
                }
            }
            Spacer(minLength: 0)
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

/// The yellow banner: one line per warning, each with its button
/// (DESIGN.md, "Showing warnings").
struct BannerView: View {
    var lines: [BannerLine]
    var press: (BannerButton) -> Void

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .center, spacing: 8) {
                        IconView(icon: BoardIcons.warning, size: 14, color: Palette.bannerText.color)
                        Text(line.text).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let button = line.button {
                            SettingsButton(title: button.title) { press(button) }
                        }
                    }
                }
            }
            .font(.system(size: 12))
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

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundColor(Palette.secondary.color)
            }
            SettingsButton(title: button, action: action)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Tabs and the filter row

struct Tabs: View {
    @Binding var tab: PopoverTab

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
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundColor(on ? Palette.text.color : Palette.secondary.color)
                .padding(EdgeInsets(top: 4, leading: 10, bottom: 6, trailing: 10))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(on ? Palette.text.color : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Todo (a push-in button) and the segment, both standard macOS controls
/// whose on state takes the system accent color (DESIGN.md, "Screens").
struct FilterRow: View {
    @Binding var filter: FilterState

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $filter.todo) { Text("Todo") }
                .toggleStyle(.button)
                .controlSize(.small)
                .fixedSize()
            Picker("", selection: $filter.segment) {
                ForEach(PrFilter.allCases, id: \.self) { Text(FilterState.title($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .font(.system(size: 11))
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }
}

/// Activity: one push-in button per owner; none on is every owner.
struct OwnerButtons: View {
    var account: Account
    @ObservedObject var model: AccountViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ActivityOwners.buttons(account)) { owner in
                    Toggle(isOn: Binding(
                        get: { model.isOwnerOn(owner.id) },
                        set: { _ in model.toggleOwner(owner.id) }
                    )) { Text(owner.displayName) }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        }
    }
}

/// The API usage line: two thin bars (DESIGN.md, "Rate limits").
struct UsageRow: View {
    var bars: [UsageBar]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                if index > 0 { Spacer().frame(width: 10) }
                Text(bar.label).fontWeight(.semibold).foregroundColor(Palette.strongText.color)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.usageTrack.color)
                        Capsule().fill(bar.warn ? Palette.usageWarn.color : Palette.usageFill.color)
                            .frame(width: geometry.size.width * bar.fraction)
                    }
                }
                .frame(width: 64, height: 5)
                Text(bar.text)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundColor(Palette.waiting.color)
        .lineLimit(1)
        .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .overlay(alignment: .top) { Rectangle().fill(Palette.border.color).frame(height: 1) }
    }
}

struct KeyHints: View {
    var hints: [KeyHint]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 3) {
                    Text(hint.key)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Palette.strongText.color)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Palette.tint.color))
                    Text(hint.text)
                }
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundColor(Palette.secondary.color)
        .padding(EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16))
        .overlay(alignment: .top) { Rectangle().fill(Palette.border.color).frame(height: 1) }
    }
}

// MARK: - The list

struct RowFrames: PreferenceKey {
    static var defaultValue: [String: ClosedRange<Double>] = [:]

    static func reduce(value: inout [String: ClosedRange<Double>], nextValue: () -> [String: ClosedRange<Double>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct ListArea: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: AccountViewModel
    @ObservedObject var avatars: AvatarStore
    var now: Int64
    var surface: Surface

    var body: some View {
        GeometryReader { outer in
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
                .coordinateSpace(name: "list")
                .onPreferenceChange(RowFrames.self) { frames in
                    model.rowsShown(Visibility.shown(frames: frames, viewport: 0 ... Double(outer.size.height)), surface: surface)
                }
                .onChange(of: model.selection) { _, selection in
                    if let selection {
                        withAnimation(.easeOut(duration: 0.1)) { reader.scrollTo(selection.id) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    var prs: some View {
        if let empty = model.emptyText {
            EmptyList(text: empty)
        }
        // Without cards the owner sections are not there at all, so the
        // selection cannot land on them (PopoverLogic.sections).
        ForEach(model.sections) { section in
            SectionHeaderView(section: section, model: model)
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
        if model.activity.isEmpty && model.loaded {
            EmptyList(text: EmptyState.activity)
        } else {
            let account = model.account
            VStack(spacing: 0) {
                ForEach(model.activity) { row in
                    RowView(
                        row: row, model: model, now: now, showsPR: true, card: nil,
                        ownerName: account?.owner(row.owner)?.displayName ?? ""
                    )
                }
            }
            .background(Palette.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border.color, lineWidth: 1))
            .padding(.horizontal, 12)
        }
    }
}

/// A section header (Main.html `.sec`): the name, the red Todo count, the PR
/// count and the chevron. Pressing it folds the section.
struct SectionHeaderView: View {
    var section: SectionLayout
    @ObservedObject var model: AccountViewModel

    var body: some View {
        let selected = model.selection == .section(section.key)
        Button { model.perform(.toggleSection(section.key)) } label: {
            HStack(spacing: 8) {
                Text(section.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(section.collapsed ? Palette.secondary.color : Palette.text.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let todo = section.todoCount {
                    Text("\(todo)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Palette.onColor.color)
                        .padding(.horizontal, 6)
                        .frame(height: 15)
                        .background(Capsule().fill(Palette.badge.color))
                }
                Text(section.detail).font(.system(size: 11)).foregroundColor(Palette.secondary.color)
                IconView(icon: section.collapsed ? BoardIcons.sectionClosed : BoardIcons.sectionOpen, size: 12, color: Palette.faded.color)
                    .frame(width: 14, height: 14)
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 14))
            .contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Palette.blueDot.color : .clear, lineWidth: 1.5).padding(.horizontal, 8))
        }
        .buttonStyle(.plain)
        .id(SelectionItem.section(section.key).id)
    }
}

/// "+ 2 more PRs" (Main.html `.empty`): pressing it shows the rest.
struct MoreRow: View {
    var text: String
    var section: String
    @ObservedObject var model: AccountViewModel

    var body: some View {
        let selected = model.selection == .more(section)
        Button { model.perform(.expand(section)) } label: {
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Palette.faded.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))
                .contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Palette.blueDot.color : .clear, lineWidth: 1.5).padding(.horizontal, 6))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .id(SelectionItem.more(section).id)
    }
}

struct EmptyList: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Palette.secondary.color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }
}

struct CardView: View {
    var card: Card
    @ObservedObject var model: AccountViewModel
    @ObservedObject var avatars: AvatarStore
    var now: Int64

    var stateBar: Color? {
        switch card.stateLabel.value {
        case .mergeable: return Palette.green.color
        case .draft: return Palette.gray.color
        case .merged: return Palette.purple.color
        case .closed: return Palette.badge.color
        default: return nil
        }
    }

    var finished: Bool {
        card.stateLabel.value == .merged || card.stateLabel.value == .closed
    }

    var body: some View {
        let selected = model.selection == .header(card: card.id)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    StateLabelView(label: card.stateLabel)
                    LinkText(text: Warnings.prLabel(card.pr), url: card.url, model: model)
                    Spacer(minLength: 0)
                    if !finished {
                        StatusIcons(card: card, model: model)
                    }
                }
                .padding(.horizontal, 4)
                Button { model.perform(.open(card.url)) } label: {
                    HStack(spacing: 7) {
                        Avatar(data: avatars.image(for: card.authorAvatarUrl))
                            .onAppear { avatars.request(card.authorAvatarUrl) }
                        Text(card.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HStack(spacing: 6) {
                    LinkText(text: "\(card.base) ← \(card.head)", url: card.url, model: model)
                    Spacer(minLength: 0)
                    // A snoozed card looks like any other; its clock unsnoozes
                    // (DESIGN.md, "Snooze").
                    Button { model.perform(card.snoozed ? .unsnooze(pr: card.pr) : .snooze(pr: card.pr)) } label: {
                        IconView(icon: BoardIcons.clock, size: 13, color: Palette.snoozeIcon.color)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(card.snoozed ? "Unsnooze" : "Snooze")
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
            .padding(EdgeInsets(top: 5, leading: 10, bottom: 4, trailing: 10))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Palette.blueDot.color : .clear, lineWidth: 1.5).padding(2))
            .id(SelectionItem.header(card: card.id).id)
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
}

struct LinkText: View {
    var text: String
    var url: String
    var model: AccountViewModel

    var body: some View {
        Button { model.perform(.open(url)) } label: {
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(Palette.secondary.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.plain)
    }
}

struct StateLabelView: View {
    var label: Lenient<StateLabel>

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
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(foreground)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(background))
                .fixedSize()
        }
    }
}

struct StatusIcons: View {
    var card: Card
    var model: AccountViewModel

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
        Button { model.perform(.open(url)) } label: {
            StatusIcon(look: value.0)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .help("\(axis): \(value.1)")
        .accessibilityLabel("\(axis): \(value.1)")
    }
}

struct Avatar: View {
    var data: Data?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Circle().fill(Palette.avatarFill.color).overlay(Circle().stroke(Palette.avatarBorder.color, lineWidth: 1))
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(Circle())
    }
}

struct RowView: View {
    var row: Row
    @ObservedObject var model: AccountViewModel
    var now: Int64
    var showsPR: Bool
    var card: String?
    /// Activity: the owner column (Activity.html `.own`).
    var ownerName: String? = nil

    var body: some View {
        let p = RowPresentation(row, now: now)
        let selected = model.selection == .row(id: row.id, card: card)
        let toDo = p.style == .toDo
        let textColor = p.dimmed ? Palette.faded.color : Palette.text.color
        Button { model.perform(.open(row.url)) } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(p.unreadDot ? Palette.blueDot.color : .clear)
                    .frame(width: 7, height: 7)
                    .padding(.top, 6)
                if let ownerName {
                    Text(ownerName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Palette.ownerTagText.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 5)
                        .frame(width: 80, height: 15)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Palette.ownerTag.color))
                        .padding(.top, 2)
                }
                if p.hasCheckbox {
                    Checkbox(on: row.done) {
                        model.perform(.done(row: row.id, on: !row.done))
                    }
                    .opacity(p.dimmed ? 0.5 : 1)
                    .padding(.top, 1)
                } else {
                    RowIconView(icon: BoardIcons.row(row.kind))
                        .opacity(p.dimmed ? 0.5 : 1)
                        .padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(p.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(p.dimmed ? Palette.faded.color : (toDo ? Palette.orangeText.color : Palette.strongText.color))
                            .lineLimit(1)
                        if let counts = p.counts {
                            Text(counts).font(.system(size: 12))
                        }
                        Text(p.meta)
                            .font(.system(size: 11))
                            .foregroundColor(Palette.secondary.color)
                            .lineLimit(1)
                    }
                    if let body = p.body {
                        Text(body)
                            .font(.system(size: 12))
                            .foregroundColor(textColor)
                            .lineLimit(p.bodyLines)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if showsPR {
                        Text("\(Warnings.prLabel(row.pr)) · \(row.prTitle)")
                            .font(.system(size: 11))
                            .foregroundColor(Palette.secondary.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(toDo ? Palette.orangeRow.color : Palette.surface.color)
            .overlay(alignment: .top) { Rectangle().fill(Palette.rowDivider.color).frame(height: 1) }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Palette.blueDot.color : .clear, lineWidth: 1.5).padding(1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(SelectionItem.row(id: row.id, card: card).id)
        .background(
            GeometryReader { geometry in
                let frame = geometry.frame(in: .named("list"))
                Color.clear.preference(key: RowFrames.self, value: [row.id: Double(frame.minY) ... Double(max(frame.minY, frame.maxY))])
            }
        )
    }
}

struct Checkbox: View {
    var on: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(on ? Palette.green.color : Palette.surface.color)
                RoundedRectangle(cornerRadius: 5)
                    .stroke(on ? Palette.green.color : Palette.controlBorder.color, lineWidth: 1.5)
                if on {
                    IconView(icon: BoardIcons.checkbox, size: 12, color: Palette.onColor.color)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Not done" : "Done")
        .accessibilityLabel(on ? "Not done" : "Done")
    }
}

struct RowIconView: View {
    var icon: RowIcon

    var body: some View {
        let (background, foreground): (Color, Color) = {
            switch icon.tone {
            case .action: return (Palette.orangeIconBackground.color, Palette.orangeIcon.color)
            case .info: return (Palette.infoIconBackground.color, Palette.infoIcon.color)
            case .ok: return (Palette.greenBackground.color, Palette.greenText.color)
            case .merged: return (Palette.purpleBackground.color, Palette.purpleText.color)
            case .closed: return (Palette.orangeIconBackground.color, Palette.orangeText.color)
            }
        }()
        IconView(icon: icon.icon, size: 11, color: foreground)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(background))
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
