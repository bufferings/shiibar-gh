// The popover of one scope, also the content of its window
// (docs/design/Main.html, MainSnoozed.html and PublicScope.html).

import AppKit
import ShiibarGhCore
import SwiftUI

/// What the surface around the list does for it.
struct SurfaceActions {
    var openWindow: (() -> Void)?
    var openSettings: (SettingsDestination) -> Void
    var about: () -> Void
    var quit: () -> Void
}

struct PopoverView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: ScopeViewModel
    @ObservedObject var avatars: AvatarStore
    var actions: SurfaceActions
    var surface: Surface

    var scope: Scope? { app.scope(model.scope) }

    var theme: ScopeTheme {
        Palette.theme(scope.map(Palette.color(of:)) ?? .gray)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: Int64(context.date.timeIntervalSince1970))
        }
        .frame(minWidth: 360, minHeight: 300)
        .background(theme.background.color)
        .foregroundColor(Palette.text.color)
        .font(.system(size: 13))
    }

    @ViewBuilder
    func content(now: Int64) -> some View {
        VStack(spacing: 0) {
            Header(
                name: scope?.name ?? model.scope, isPublic: scope?.isPublic ?? false,
                updated: app.dbUnreadable ? nil : RelativeTime.updated(scope?.updatedAt, now: now),
                theme: theme, actions: actions, refresh: { app.refresh(model.scope) }
            )
            switch SurfaceRules.content(scope: scope, dbUnreadable: app.dbUnreadable) {
            case .unreadable:
                CenteredMessage(title: EmptyState.unreadable, button: "Reset") { app.reset() }
            case .noToken:
                CenteredMessage(title: EmptyState.noToken, button: "Settings") {
                    actions.openSettings(SurfaceRules.noTokenSettings)
                }
            case .list:
                if let scope {
                    let lines = Warnings.banner(scope, now: now)
                    if !lines.isEmpty {
                        Banner(lines: lines.map(\.text)) { actions.openSettings(SurfaceRules.bannerSettings) }
                    }
                }
                Tabs(tab: $model.tab, theme: theme)
                ChipBar(chips: $model.chips)
                ListArea(app: app, model: model, avatars: avatars, theme: theme, now: now, surface: surface)
                KeyHints(theme: theme)
            }
        }
    }
}

// MARK: - Header

struct Header: View {
    var name: String
    var isPublic: Bool
    var updated: String?
    var theme: ScopeTheme
    var actions: SurfaceActions
    var refresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isPublic ? Palette.publicName.color : Palette.text.color)
                    Text("shiibar-gh").font(.system(size: 11)).foregroundColor(Palette.secondary.color)
                }
                if let updated {
                    Text(updated).font(.system(size: 11)).foregroundColor(Palette.secondary.color)
                }
            }
            Spacer(minLength: 0)
            if let openWindow = actions.openWindow {
                HeaderButton(icon: BoardIcons.window, size: 15, label: "Open in window", theme: theme, action: openWindow)
            }
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle(theme: theme))
            .help("Refresh")
            HeaderButton(icon: BoardIcons.gear, size: 16, label: "Settings", theme: theme) { actions.openSettings(SurfaceRules.headerSettings) }
            Menu {
                Button("About shiibar-gh", action: actions.about)
                Button("Settings…") { actions.openSettings(SurfaceRules.headerSettings) }
                Divider()
                Button("Quit shiibar-gh", action: actions.quit)
            } label: {
                IconView(icon: BoardIcons.chevron, size: 14, color: Palette.botIcon.color)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 24, height: 24)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 10))
    }
}

struct HeaderButton: View {
    var icon: BoardIcon
    var size: CGFloat
    var label: String
    var theme: ScopeTheme
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            IconView(icon: icon, size: size, color: Palette.botIcon.color)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(theme: theme))
        .help(label)
        .accessibilityLabel(label)
    }
}

struct HoverButtonStyle: ButtonStyle {
    var theme: ScopeTheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Palette.botIcon.color)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering || configuration.isPressed ? theme.tint.color : .clear))
            .onHover { hovering = $0 }
    }
}

struct Banner: View {
    var lines: [String]
    var settings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            IconView(icon: BoardIcons.warning, size: 14, color: Palette.bannerText.color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Settings", action: settings)
                .buttonStyle(.plain)
                .foregroundColor(Palette.link.color)
        }
        .font(.system(size: 12))
        .foregroundColor(Palette.bannerText.color)
        .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.bannerBackground.color))
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 0, trailing: 12))
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

// MARK: - Tabs and chips

struct Tabs: View {
    @Binding var tab: PopoverTab
    var theme: ScopeTheme

    var body: some View {
        HStack(spacing: 2) {
            tabButton("PRs", .prs)
            tabButton("Activity", .activity)
            Spacer()
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 0, trailing: 12))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border.color).frame(height: 1) }
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

struct ChipBar: View {
    @Binding var chips: Chips

    var body: some View {
        HStack(spacing: 8) {
            Chip(title: "Needs action", on: chips.needsAction, action: true) { chips.needsAction.toggle() }
            HStack(spacing: 0) {
                Chip(title: "My PRs", on: chips.author == .mine, corners: .left) { chips.pick(.mine) }
                Chip(title: "Others' PRs", on: chips.author == .others, corners: .right) { chips.pick(.others) }
            }
            Spacer(minLength: 0)
            Chip(title: "Show snoozed", on: chips.showSnoozed) { chips.showSnoozed.toggle() }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }
}

struct Chip: View {
    enum Corners { case both, left, right }
    var title: String
    var on: Bool
    var action = false
    var corners: Corners = .both
    var tap: () -> Void

    var body: some View {
        let fill: Color = on ? (action ? Palette.badge.color : Palette.text.color) : .white
        let border: Color = action ? Palette.badge.color : (on ? Palette.text.color : Palette.controlBorder.color)
        let text: Color = on ? .white : (action ? Palette.orangeText.color : Color(white: 0.23))
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: corners == .right ? 0 : 12, bottomLeadingRadius: corners == .right ? 0 : 12,
            bottomTrailingRadius: corners == .left ? 0 : 12, topTrailingRadius: corners == .left ? 0 : 12
        )
        Button(action: tap) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(text)
                .padding(EdgeInsets(top: 3, leading: 9, bottom: 3, trailing: 9))
                .background(shape.fill(fill))
                .overlay(shape.stroke(border, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

struct KeyHints: View {
    var theme: ScopeTheme

    var body: some View {
        HStack(spacing: 10) {
            hint("↑↓", "Move")
            hint("⏎", "Open")
            hint("D", "Done")
            hint("S", "Snooze")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundColor(Palette.secondary.color)
        .padding(EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16))
        .overlay(alignment: .top) { Rectangle().fill(theme.border.color).frame(height: 1) }
    }

    func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(white: 0.23))
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 3).fill(theme.tint.color))
            Text(text)
        }
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
    @ObservedObject var model: ScopeViewModel
    @ObservedObject var avatars: AvatarStore
    var theme: ScopeTheme
    var now: Int64
    var surface: Surface

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 0) {
                        if model.tab == .prs {
                            if model.cards.isEmpty && model.loaded {
                                EmptyList(text: EmptyState.cards(filtered: model.chips.narrows))
                            }
                            ForEach(model.cards) { card in
                                CardView(
                                    card: card, model: model, avatars: avatars, theme: theme, now: now
                                )
                            }
                        } else {
                            if model.activity.isEmpty && model.loaded {
                                EmptyList(text: EmptyState.activity)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(model.activity) { row in
                                        RowView(row: row, model: model, theme: theme, now: now, showsPR: true, card: nil)
                                    }
                                }
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border.color, lineWidth: 1))
                                .padding(.horizontal, 12)
                            }
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
    @ObservedObject var model: ScopeViewModel
    @ObservedObject var avatars: AvatarStore
    var theme: ScopeTheme
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

    /// docs/design/MainSnoozed.html: a snoozed card is faded except "Snoozed
    /// until …" and Unsnooze.
    var faded: Double { card.snoozed ? 0.55 : 1 }

    var body: some View {
        let selected = model.selection == .header(card: card.id)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    StateLabelView(label: card.stateLabel, theme: theme)
                    LinkText(text: Warnings.prLabel(card.pr), url: card.url, model: model)
                    Spacer(minLength: 0)
                    if !finished {
                        StatusIcons(card: card, model: model, theme: theme)
                    }
                }
                .padding(.horizontal, 4)
                .opacity(faded)
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
                .opacity(faded)
                HStack(spacing: 6) {
                    LinkText(text: "\(card.base) ← \(card.head)", url: card.url, model: model)
                        .opacity(faded)
                    Spacer(minLength: 0)
                    if card.snoozed {
                        HStack(spacing: 4) {
                            if let until = card.snoozedUntil {
                                Text(SurfaceRules.snoozedUntil(until))
                                    .font(.system(size: 11))
                                    .foregroundColor(Palette.text.color)
                            }
                            Button("Unsnooze") { model.perform(.unsnooze(pr: card.pr)) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundColor(Palette.link.color)
                        }
                    } else {
                        Button { model.perform(.snooze(pr: card.pr)) } label: {
                            IconView(icon: BoardIcons.clock, size: 13, color: Color(white: 0.7))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Snooze")
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
            .padding(EdgeInsets(top: 5, leading: 10, bottom: 4, trailing: 10))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Palette.blueDot.color : .clear, lineWidth: 1.5).padding(2))
            .id(SelectionItem.header(card: card.id).id)
            VStack(spacing: 0) {
                ForEach(card.rows) { row in
                    RowView(row: row, model: model, theme: theme, now: now, showsPR: false, card: card.id)
                }
            }
            .opacity(faded)
        }
        .background(Color.white)
        .overlay(alignment: .leading) {
            if let stateBar { Rectangle().fill(stateBar).frame(width: 4).opacity(faded) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.border.color, lineWidth: 1))
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))
    }
}

struct LinkText: View {
    var text: String
    var url: String
    var model: ScopeViewModel

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
    var theme: ScopeTheme

    var body: some View {
        let style: (String, Color, Color)? = {
            switch label.value {
            case .mergeable: return ("Mergeable", Palette.green.color, .white)
            case .draft: return ("Draft", theme.tint.color, Color(white: 0.29))
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
    var model: ScopeViewModel
    var theme: ScopeTheme

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
        .buttonStyle(HoverButtonStyle(theme: theme))
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
                Circle().fill(Color(white: 0.92)).overlay(Circle().stroke(Color(white: 0.85), lineWidth: 1))
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(Circle())
    }
}

struct RowView: View {
    var row: Row
    @ObservedObject var model: ScopeViewModel
    var theme: ScopeTheme
    var now: Int64
    var showsPR: Bool
    var card: String?

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
                if p.hasCheckbox {
                    Checkbox(on: row.done) {
                        model.perform(row.done ? .undone(row: row.id) : .done(row: row.id))
                    }
                    .opacity(p.dimmed ? 0.5 : 1)
                    .padding(.top, 1)
                } else {
                    RowIconView(icon: BoardIcons.row(row.kind), theme: theme)
                        .opacity(p.dimmed ? 0.5 : 1)
                        .padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(p.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(p.dimmed ? Palette.faded.color : (toDo ? Palette.orangeText.color : Color(white: 0.23)))
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
            .background(toDo ? Palette.orangeRow.color : Color.white)
            .overlay(alignment: .top) { Rectangle().fill(Color(white: 0.94)).frame(height: 1) }
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
                    .fill(on ? Palette.green.color : Color.white)
                RoundedRectangle(cornerRadius: 5)
                    .stroke(on ? Palette.green.color : Palette.controlBorder.color, lineWidth: 1.5)
                if on {
                    IconView(icon: BoardIcons.checkbox, size: 12, color: .white)
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
    var theme: ScopeTheme

    var body: some View {
        let (background, foreground): (Color, Color) = {
            switch icon.tone {
            case .action: return (Palette.orangeIconBackground.color, Palette.orangeIcon.color)
            case .info: return (Palette.infoIconBackground.color, Palette.infoIcon.color)
            case .ok: return (Palette.greenBackground.color, Palette.greenText.color)
            case .bot: return (theme.tint.color, Palette.botIcon.color)
            case .merged: return (Palette.purpleBackground.color, Palette.purpleText.color)
            case .closed: return (Palette.orangeIconBackground.color, Palette.orangeText.color)
            }
        }()
        IconView(icon: icon.icon, size: 11, color: foreground)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(background))
    }
}

/// The board's `.btn`.
struct SettingsButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(Palette.text.color)
                .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.controlBorder.color, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The popover while no scope icon shows (DESIGN.md, "Screens"), or the
/// unreadable state when the database cannot be read.
struct NoScopesView: View {
    @ObservedObject var app: AppModel
    var actions: SurfaceActions

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("shiibar-gh").font(.system(size: 14, weight: .semibold))
                Spacer()
                Menu {
                    Button("About shiibar-gh", action: actions.about)
                    Button("Settings…") { actions.openSettings(SurfaceRules.headerSettings) }
                    Divider()
                    Button("Quit shiibar-gh", action: actions.quit)
                } label: {
                    IconView(icon: BoardIcons.chevron, size: 14, color: Palette.botIcon.color)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 10))
            switch SurfaceRules.noScopeContent(dbUnreadable: app.dbUnreadable) {
            case .unreadable:
                CenteredMessage(title: EmptyState.unreadable, button: "Reset") { app.reset() }
            case .noScopes:
                CenteredMessage(title: EmptyState.noScopesTitle, detail: EmptyState.noScopesDetail, button: "Settings") {
                    actions.openSettings(SurfaceRules.noScopesSettings)
                }
            }
        }
        .frame(width: 300, height: 180)
        .background(Palette.theme(.gray).background.color)
        .foregroundColor(Palette.text.color)
    }
}
