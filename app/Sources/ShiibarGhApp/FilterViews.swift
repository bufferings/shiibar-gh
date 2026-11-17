// The Filter row and the options (docs/design/Main.html, the Filter scenes;
// DESIGN.md, "Screens", "Filter"): under the search row, always (not while
// the Dismissed list shows), `Filter` with its chevron and the accent-colored dot,
// then, while a setting differs from its default, the summary; in All,
// `Grouping…` at the right end. Nothing in the row changes a setting. When
// open, one option a line between the row and the list, and `Reset` under
// them at the right end. The options, `Reset` and `Grouping…`
// are standard AppKit controls that never take the keyboard focus, so the
// keys keep working on the list and the search field while they show.
//
// AppKit API used, as declared in the SDK headers (NSControl.h, NSView.h,
// NSResponder.h, NSSegmentedControl.h, NSButton.h): `refusesFirstResponder`
// (NSControl), `acceptsFirstResponder` (NSResponder) and `canBecomeKeyView`
// (NSView), overridden to NO here, and `becomeFirstResponder` (NSResponder)
// too: `makeFirstResponder:` does not ask `acceptsFirstResponder` before it
// (the test below saw a control take the focus that way);
// `NSSegmentedControl(labels:trackingMode:target:action:)` with
// `.selectOne`; `NSButton(checkboxWithTitle:target:action:)`;
// `NSButton(title:target:action:)` ("Creates a standard push button with
// the provided title", NSButton.h) for `Grouping…` and `Reset`. A test
// (ShiibarGhAppTests, FilterControlsTests) checks that none of them becomes
// the first responder, asked in code or by Tab.

import AppKit
import ShiibarGhCore
import SwiftUI

/// Sizes of the Filter's area at text size 12 (DESIGN.md, "Constants";
/// Main.html `.frow`, `.fo`, `.fopts`).
enum FilterOptionsLayout {
    /// The list keeps at least this height (times the text scale): the
    /// popover and the window are at least as high as that needs
    /// (`SurfaceHeight`).
    static let listMinimum: CGFloat = 100
    /// The Filter row, without the space under it.
    static let filterRowHeight: CGFloat = 24
    /// Under the Filter row, before the options or the list.
    static let filterRowBottom: CGFloat = 6
    /// One option line.
    static let rowHeight: CGFloat = 27
    /// The line of `Reset`, under the options.
    static let resetHeight: CGFloat = 28
    /// The box the options sit in (Main.html `.fopts`; DESIGN.md,
    /// "Filter"): the cards' background and border, rounded, with the
    /// cards' side inset. Points at text size 12. The heights grow with the
    /// text (`scaled`); the sides and the corners stay as the cards' do,
    /// so the box lines up with the cards and the search field at every
    /// text size, as the options' sides always did.
    static let boxRadius: CGFloat = 8
    /// Outside the box: above (under the Filter row), at the sides, below
    /// (before the list). Below it 6, the closed Filter row's own room
    /// under it: the list starts as far below the fixed part whether the
    /// options are open or closed, and a scrolled list never comes up to
    /// the box (the list is clipped at its own top).
    static let boxMargin = EdgeInsets(top: 2, leading: 12, bottom: 6, trailing: 12)
    /// Inside the box, around the option lines and `Reset`.
    static let boxPadding = EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 10)

    /// The lines' height inside the box (without its padding) for `lines`
    /// option lines at the text scale `k`.
    static func contentHeight(lines: Int, k: CGFloat) -> CGFloat {
        (CGFloat(lines) * rowHeight + resetHeight) * k
    }

    /// The whole area: the box with its padding, its 1-point border and
    /// its margins. It never shrinks.
    static func areaHeight(lines: Int, k: CGFloat) -> CGFloat {
        contentHeight(lines: lines, k: k) + (boxPadding.top + boxPadding.bottom + boxMargin.top + boxMargin.bottom) * k + 2
    }

    /// The least height of the popover or window (`SurfaceHeight`): the
    /// list's top as laid out (`listTop`) without the options as drawn
    /// (`shownOptions`, 0 while closed) and without the bands (`bands`),
    /// plus the options' full area; the list's minimum; the part under the
    /// list (`below`). The same open or closed, with or without bands: only
    /// the text size changes it.
    static func surfaceMinimum(listTop: CGFloat, shownOptions: CGFloat, bands: CGFloat, below: CGFloat, lines: Int, k: CGFloat) -> CGFloat {
        SurfaceHeight.minimum(above: listTop - shownOptions - bands + areaHeight(lines: lines, k: k), below: below, k: k)
    }

    /// The top and the bottom multiplied by `k`, the sides as they are.
    static func scaled(_ insets: EdgeInsets, _ k: CGFloat) -> EdgeInsets {
        EdgeInsets(top: insets.top * k, leading: insets.leading, bottom: insets.bottom * k, trailing: insets.trailing)
    }
}

/// The options area.
struct FilterOptionsState: Equatable {
    var shows: Bool
    var lines: [FilterOption]
    var filter: ListFilter
    /// `Reset` enabled: a setting differs from its default.
    var canReset: Bool
}

/// The Filter row: shown, and its parts.
struct FilterRowState: Equatable {
    /// Not while the Dismissed list shows.
    var shows: Bool
    var open: Bool
    var dot: Bool
    /// The summary; nil while every setting is the default.
    var summary: String?
    /// `Grouping…` at the right end (All).
    var showsGrouping: Bool
}

/// `Filter`, its chevron (right while closed, down while open) and the accent-colored
/// dot when there is one (Main.html `.flt`). Any press on it opens or closes
/// the options; the dot has no action of its own.
struct FilterButton: View {
    var open: Bool
    var dot: Bool
    var toggle: () -> Void
    @Environment(\.textScale) var k

    static let dotTip = FilterText.dotTip

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Text("Filter")
                    .font(.system(size: 12 * k))
                    .foregroundColor(Palette.text.color)
                    .fixedSize()
                IconView(icon: open ? BoardIcons.filterOpen : BoardIcons.filterClosed, size: 10 * k, color: Palette.secondary.color)
                if dot {
                    Circle()
                        .fill(Palette.accent.color)
                        .frame(width: 7 * k, height: 7 * k)
                        .frame(height: 24 * k)
                        .contentShape(Rectangle())
                        .quickHelp(Self.dotTip)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 24 * k)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(dot ? "Filter, unread pull requests hidden" : "Filter")
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// The Filter row of the surface, while it shows.
struct FilterRowSlot: View {
    var list: SurfaceListModel
    @ObservedObject var state: Derived<FilterRowState>

    var body: some View {
        if state.value.shows {
            FilterRow(value: state.value, toggle: { [list] in list.toggleFilterOpen() }, openGrouping: { [list] in list.openGrouping() })
        }
    }
}

/// The Filter row (DESIGN.md, "Filter"; Main.html `.frow`): from the left
/// `Filter`, then the summary, and in All `Grouping…` at the right end with
/// room between. Only the summary gives way when the row is narrow: it is
/// cut with `…` (then, and only then, its tooltip shows all of it). The
/// summary has no action.
struct FilterRow: View {
    var value: FilterRowState
    var toggle: () -> Void
    var openGrouping: () -> Void
    @Environment(\.textScale) var k

    var body: some View {
        HStack(spacing: 8) {
            FilterButton(open: value.open, dot: value.dot, toggle: toggle)
                .fixedSize()
                .layoutPriority(1)
            if let summary = value.summary {
                FilterSummary(summary: summary)
            }
            // With the spacing on both sides: at least 16 points before
            // `Grouping…`.
            Spacer(minLength: 0)
            if value.showsGrouping {
                PushButton(title: PushButton.grouping, press: openGrouping)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .frame(height: FilterOptionsLayout.filterRowHeight * k)
        .padding(EdgeInsets(top: 0, leading: 12, bottom: FilterOptionsLayout.filterRowBottom, trailing: 12))
    }
}

/// The summary, cut with `…` when it does not fit.
struct FilterSummary: View {
    var summary: String
    @Environment(\.textScale) var k
    @State private var shownWidth: CGFloat = 0

    var body: some View {
        Text(summary)
            .font(.system(size: 11 * k))
            .foregroundColor(Palette.secondary.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: SummaryWidthKey.self, value: geometry.size.width)
            })
            .onPreferenceChange(SummaryWidthKey.self) { shownWidth = $0 }
            .quickHelp(ifAny: Self.isCut(summary, shownWidth: shownWidth, k: k) ? summary : nil)
    }

    /// Whether a summary laid out `shownWidth` points wide is cut short at
    /// text scale `k` (then, and only then, its tooltip shows it all).
    static func isCut(_ summary: String, shownWidth: CGFloat, k: CGFloat) -> Bool {
        let full = (summary as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11 * k)]).width
        return shownWidth > 0 && shownWidth + 0.5 < full.rounded(.up)
    }
}

private struct SummaryWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The options while `Filter` is open and the Dismissed list does not show.
struct FilterOptionsSlot: View {
    var list: SurfaceListModel
    @ObservedObject var state: Derived<FilterOptionsState>

    var body: some View {
        if state.value.shows {
            FilterOptions(list: list, state: state.value)
        }
    }
}

/// One option a line, the name at the left and the control at the right
/// (Main.html `.fopts`, `.fo`): Status, Muted and Unread, in every tab;
/// under them `Reset` at the right end, disabled while every setting is the
/// default (the area keeps its height). All of it sits in a rounded box with
/// the cards' background and border, so it reads as one region apart from
/// the list; no line is drawn under it. Always at its full height: the
/// popover or the window grows instead (`SurfaceHeight`).
struct FilterOptions: View {
    var list: SurfaceListModel
    var state: FilterOptionsState
    @Environment(\.textScale) var k

    var body: some View {
        let height = FilterOptionsLayout.contentHeight(lines: state.lines.count, k: k)
        let padding = FilterOptionsLayout.scaled(FilterOptionsLayout.boxPadding, k)
        let box = RoundedRectangle(cornerRadius: FilterOptionsLayout.boxRadius)
        VStack(spacing: 0) {
            ForEach(state.lines, id: \.self) { option in
                line(option.title) { control(option) }
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                PushButton(title: PushButton.reset, enabled: state.canReset) { [list] in list.resetFilter() }
                    .fixedSize()
            }
            .frame(height: FilterOptionsLayout.resetHeight * k)
        }
        .padding(EdgeInsets(top: 0, leading: padding.leading, bottom: 0, trailing: padding.trailing))
        .frame(height: height)
        .padding(EdgeInsets(top: padding.top, leading: 0, bottom: padding.bottom, trailing: 0))
        // The 1-point border inside the box's frame.
        .padding(1)
        .background(box.fill(Palette.surface.color))
        .overlay(box.strokeBorder(Palette.border.color, lineWidth: 1))
        .padding(FilterOptionsLayout.scaled(FilterOptionsLayout.boxMargin, k))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func line<Control: View>(_ name: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(name)
                .font(.system(size: 12 * k))
                .foregroundColor(Palette.text.color)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            control()
        }
        .frame(height: FilterOptionsLayout.rowHeight * k)
    }

    @ViewBuilder
    private func control(_ option: FilterOption) -> some View {
        switch option {
        case .status: statusControl
        case .muted: mutedControl
        case .unread:
            CheckBox(title: "Unread only", on: state.filter.unreadOnly) { [list] in
                list.setUnreadOnly(!list.filter.unreadOnly)
                return list.filter.unreadOnly
            }
        }
    }

    private var mutedControl: some View {
        let choices = MuteChoice.allCases
        return Segmented(
            labels: choices.map(\.title), selected: choices.firstIndex(of: state.filter.muted) ?? 0, name: "Muted"
        ) { [list] index in
            list.setMuteChoice(choices[index])
            return choices.firstIndex(of: list.filter.muted) ?? 0
        }
    }

    private var statusControl: some View {
        HStack(spacing: 12) {
            ForEach(PRStatus.allCases, id: \.self) { status in
                CheckBox(title: status.title, on: state.filter.shows(status)) { [list] in
                    list.toggleStatus(status)
                    return list.filter.shows(status)
                }
            }
        }
    }
}

// MARK: - Controls that never take the keyboard focus

/// A checkbox (NSButton) for the mouse only.
final class NoFocusCheckbox: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

/// A segmented control (NSSegmentedControl) for the mouse only.
final class NoFocusSegmentedControl: NSSegmentedControl {
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

/// A push button (NSButton) for the mouse only.
final class NoFocusButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

/// A standard small push button, mouse only like the Filter's options:
/// `Grouping…` at the right end of All's Filter row, which opens the
/// Grouping sheet (DESIGN.md, "All", "Grouping settings"), and `Reset`
/// under the Filter's options (DESIGN.md, "Filter"), disabled while there
/// is nothing to reset.
struct PushButton: NSViewRepresentable {
    static let grouping = "Grouping\u{2026}"
    static let reset = FilterText.reset
    var title: String
    var enabled = true
    var press: () -> Void
    @Environment(\.textScale) var k

    final class Coordinator: NSObject {
        var press: () -> Void = {}

        @objc func pressed(_ sender: NSButton) { press() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NoFocusButton {
        let button = NoFocusButton(title: title, target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        button.refusesFirstResponder = true
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        update(button, context: context)
        return button
    }

    func updateNSView(_ button: NoFocusButton, context: Context) {
        update(button, context: context)
    }

    private func update(_ button: NoFocusButton, context: Context) {
        context.coordinator.press = press
        let font = NSFont.systemFont(ofSize: 11 * k)
        if button.font != font { button.font = font }
        if button.title != title { button.title = title }
        if button.isEnabled != enabled { button.isEnabled = enabled }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NoFocusButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// A standard checkbox. `press` makes the change and returns the value the
/// box then shows (the last status on stays on: the box goes back).
struct CheckBox: NSViewRepresentable {
    var title: String
    var on: Bool
    var press: () -> Bool
    @Environment(\.textScale) var k

    final class Coordinator: NSObject {
        var press: () -> Bool = { false }

        @objc func pressed(_ sender: NSButton) {
            sender.state = press() ? .on : .off
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NoFocusCheckbox {
        let button = NoFocusCheckbox(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        button.refusesFirstResponder = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        update(button, context: context)
        return button
    }

    func updateNSView(_ button: NoFocusCheckbox, context: Context) {
        update(button, context: context)
    }

    private func update(_ button: NoFocusCheckbox, context: Context) {
        context.coordinator.press = press
        let font = NSFont.systemFont(ofSize: 12 * k)
        if button.font != font { button.font = font }
        if button.title != title { button.title = title }
        let state: NSControl.StateValue = on ? .on : .off
        if button.state != state { button.state = state }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NoFocusCheckbox, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// A standard segmented control, one of its segments selected. `press`
/// makes the change and returns the segment then selected.
struct Segmented: NSViewRepresentable {
    var labels: [String]
    var selected: Int
    var name: String
    var press: (Int) -> Int
    @Environment(\.textScale) var k

    final class Coordinator: NSObject {
        var press: (Int) -> Int = { $0 }

        @objc func pressed(_ sender: NSSegmentedControl) {
            sender.selectedSegment = press(sender.selectedSegment)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NoFocusSegmentedControl {
        let control = NoFocusSegmentedControl(
            labels: labels, trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.pressed(_:))
        )
        control.refusesFirstResponder = true
        control.controlSize = .small
        control.setAccessibilityLabel(name)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        update(control, context: context)
        return control
    }

    func updateNSView(_ control: NoFocusSegmentedControl, context: Context) {
        update(control, context: context)
    }

    private func update(_ control: NoFocusSegmentedControl, context: Context) {
        context.coordinator.press = press
        let font = NSFont.systemFont(ofSize: 11 * k)
        if control.font != font { control.font = font }
        if control.selectedSegment != selected { control.selectedSegment = selected }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NoFocusSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

// MARK: - Detailed and Compact

/// The display mode of the cards (DESIGN.md, "Compact"): `Detailed` at the
/// left, `Compact` at the right, a two-segment switch with one icon each
/// (BoardIcons `compactOff`, `compactOn`). The current mode is the selected
/// segment; the other one switches; the current one does nothing. The
/// names are the segments' tooltips, shown after 0.4 seconds (QuickTip).
/// Mouse only, like the Filter's options.
enum DisplayMode: Int, CaseIterable {
    case detailed = 0, compact = 1

    var title: String { self == .detailed ? "Detailed" : "Compact" }
    var icon: BoardIcon { self == .detailed ? BoardIcons.compactOff : BoardIcons.compactOn }
}

/// The switch's size at a text scale `k` (text size / 12): the board's
/// `.dmode .dseg` (26 × 20 points, a 1-point border, 6-point corners, the
/// 14-point icon) multiplied by `k` as a whole, so the icons keep their
/// proportion to the bezel at every text size (DESIGN.md, "Screens",
/// "Constants"). The two segments share the border between them.
struct ModeSwitchLayout: Equatable {
    var k: CGFloat

    var segment: CGSize { CGSize(width: 26 * k, height: 20 * k) }
    var size: CGSize { CGSize(width: segment.width * 2 - 1, height: segment.height) }
    var icon: CGFloat { 14 * k }
    var radius: CGFloat { 6 * k }

    /// The frame of a segment in the switch's (flipped) bounds.
    func frame(_ mode: DisplayMode) -> CGRect {
        CGRect(x: CGFloat(mode.rawValue) * (segment.width - 1), y: 0, width: segment.width, height: segment.height)
    }

    /// The icon's square, centered in its segment.
    func iconFrame(_ mode: DisplayMode) -> CGRect {
        let box = frame(mode)
        return CGRect(x: box.midX - icon / 2, y: box.midY - icon / 2, width: icon, height: icon)
    }

    /// The segment under a point, nil outside.
    func mode(at point: CGPoint) -> DisplayMode? {
        guard CGRect(origin: .zero, size: size).contains(point) else { return nil }
        return point.x < size.width / 2 ? .detailed : .compact
    }
}

/// The switch, drawn by the app (Main.html `.dmode`): a standard
/// segmented control keeps its height whatever the text size, so its icons
/// would crowd its bezel at large sizes. It never takes the keyboard focus
/// (DESIGN.md, "Filter"); assistive apps see a radio group of two radio
/// buttons named after the modes.
final class ModeSwitchView: NSView {
    var mode: DisplayMode = .detailed {
        didSet { if mode != oldValue { needsDisplay = true; updateAccessibility() } }
    }
    var layout = ModeSwitchLayout(k: 1) {
        didSet { if layout != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true; updateAccessibility() } }
    }
    /// The other segment was pressed: the mode to switch to.
    var choose: (DisplayMode) -> Void = { _ in }

    private let tipOwner = QuickTip.Owner()
    private var tipArea: NSTrackingArea?
    private var tipMode: DisplayMode?
    private var pressed: DisplayMode?
    private lazy var segments: [ModeSegmentElement] = DisplayMode.allCases.map { ModeSegmentElement(mode: $0, owner: self) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Display mode")
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
    override var intrinsicContentSize: NSSize { layout.size }

    /// The other segment switches; the current one does nothing.
    func press(_ next: DisplayMode) {
        if next != mode { choose(next) }
    }

    override func draw(_ dirtyRect: NSRect) {
        // The selected segment last: its border covers the shared one.
        for mode in DisplayMode.allCases.sorted(by: { a, _ in a != self.mode }) {
            draw(mode, on: mode == self.mode)
        }
    }

    private func draw(_ mode: DisplayMode, on: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let box = layout.frame(mode).insetBy(dx: 0.5, dy: 0.5)
        let r = layout.radius
        let path = CGMutablePath()
        let left = mode == .detailed
        // Rounded at the outer corners only.
        path.move(to: CGPoint(x: box.midX, y: box.minY))
        if left {
            path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
            path.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
            path.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY), tangent2End: CGPoint(x: box.minX, y: box.minY), radius: r)
            path.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY), tangent2End: CGPoint(x: box.maxX, y: box.minY), radius: r)
        } else {
            path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY), tangent2End: CGPoint(x: box.maxX, y: box.maxY), radius: r)
            path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.minX, y: box.maxY), radius: r)
            path.addLine(to: CGPoint(x: box.minX, y: box.maxY))
            path.addLine(to: CGPoint(x: box.minX, y: box.minY))
        }
        path.closeSubpath()
        let fill = on ? Palette.selection.nsColor : Palette.surface.nsColor
        let stroke = on ? Palette.accentLine.nsColor : Palette.border.nsColor
        let ink = on ? Palette.accent.nsColor : Palette.secondary.nsColor
        context.addPath(path)
        context.setFillColor(fill.cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        Shapes.icon(mode.icon, in: layout.iconFrame(mode), color: ink)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        tipMode = nil
        QuickTip.cancel(owner: tipOwner)
        pressed = layout.mode(at: convert(event.locationInWindow, from: nil))
    }

    /// As a segmented control: the segment pressed acts when the button is
    /// released over it.
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed, layout.mode(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        press(pressed)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tipArea { removeTrackingArea(tipArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tipArea = area
    }

    private func followTip(_ event: NSEvent) {
        let mode = layout.mode(at: convert(event.locationInWindow, from: nil))
        guard mode != tipMode else { return }
        tipMode = mode
        if let mode {
            QuickTip.schedule(mode.title, owner: tipOwner, appearance: effectiveAppearance)
        } else {
            QuickTip.cancel(owner: tipOwner)
        }
    }

    override func mouseEntered(with event: NSEvent) { followTip(event) }
    override func mouseMoved(with event: NSEvent) { followTip(event) }

    override func mouseExited(with event: NSEvent) {
        tipMode = nil
        QuickTip.cancel(owner: tipOwner)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { QuickTip.cancel(owner: tipOwner) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        setAccessibilityValue(mode.title)
        setAccessibilityChildren(segments)
        for element in segments { element.update() }
    }
}

/// One segment of `ModeSwitchView` for assistive apps: a radio button named
/// after its mode, on while it is the current one; pressing it switches.
final class ModeSegmentElement: NSAccessibilityElement {
    let mode: DisplayMode
    private weak var owner: ModeSwitchView?

    init(mode: DisplayMode, owner: ModeSwitchView) {
        self.mode = mode
        self.owner = owner
        super.init()
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(mode.title)
        setAccessibilityParent(owner)
    }

    func update() {
        guard let owner else { return }
        setAccessibilityValue(owner.mode == mode ? 1 : 0)
        setAccessibilityFrameInParentSpace(owner.layout.frame(mode))
    }

    override func accessibilityPerformPress() -> Bool {
        owner?.press(mode)
        return true
    }
}

struct DisplayModeSwitch: NSViewRepresentable {
    var mode: DisplayMode
    /// The other segment was pressed: the mode to switch to.
    var choose: (DisplayMode) -> Void
    @Environment(\.textScale) var k

    func makeNSView(context: Context) -> ModeSwitchView {
        let view = ModeSwitchView(frame: .zero)
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        update(view)
        return view
    }

    func updateNSView(_ view: ModeSwitchView, context: Context) {
        update(view)
    }

    private func update(_ view: ModeSwitchView) {
        view.choose = choose
        view.layout = ModeSwitchLayout(k: k)
        view.mode = mode
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ModeSwitchView, context: Context) -> CGSize? {
        ModeSwitchLayout(k: k).size
    }
}
