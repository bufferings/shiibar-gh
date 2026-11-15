// The Filter row and the options (docs/design/Main.html, the Filter scenes;
// DESIGN.md, "Screens", "Filter"): under the search row, always (not while
// the Dismissed list shows), `Filter` with its chevron and the blue dot,
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
    /// The list keeps at least this height while the options show.
    static let listMinimum: CGFloat = 100
    /// The Filter row, without the space under it.
    static let filterRowHeight: CGFloat = 24
    /// Under the Filter row, before the options or the list.
    static let filterRowBottom: CGFloat = 6
    /// One option line.
    static let rowHeight: CGFloat = 27
    /// The line of `Reset`, under the options.
    static let resetHeight: CGFloat = 28
    /// Under the last line, before the border.
    static let bottomPadding: CGFloat = 6
    /// Below the border, before the list.
    static let gap: CGFloat = 6
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

/// `Filter`, its chevron (right while closed, down while open) and the blue
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
                IconView(icon: open ? BoardIcons.filterOpen : BoardIcons.filterClosed, size: 10 * k, color: Palette.waiting.color)
                if dot {
                    Circle()
                        .fill(Palette.blueDot.color)
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
/// default (the area keeps its height). Scrolls inside when the surface is
/// short (the list keeps its minimum height).
struct FilterOptions: View {
    var list: SurfaceListModel
    var state: FilterOptionsState
    @Environment(\.textScale) var k

    var body: some View {
        let height = (CGFloat(state.lines.count) * FilterOptionsLayout.rowHeight + FilterOptionsLayout.resetHeight) * k
            + FilterOptionsLayout.bottomPadding
        ScrollView(.vertical) {
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
            .padding(EdgeInsets(top: 0, leading: 16, bottom: FilterOptionsLayout.bottomPadding, trailing: 14))
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: height)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border.color).frame(height: 1) }
        .padding(.bottom, FilterOptionsLayout.gap)
    }

    private func line<Control: View>(_ name: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(name)
                .font(.system(size: 12 * k))
                .foregroundColor(Palette.strongText.color)
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
/// left, `Compact` at the right, a standard segmented control with one icon
/// each (BoardIcons `compactOff`, `compactOn`). The current mode is the
/// selected segment; the other one switches; the current one does nothing.
/// The names are the segments' tooltips, shown after 0.4 seconds
/// (QuickTip). Mouse only, like the Filter's options.
enum DisplayMode: Int, CaseIterable {
    case detailed = 0, compact = 1

    var title: String { self == .detailed ? "Detailed" : "Compact" }
    var icon: BoardIcon { self == .detailed ? BoardIcons.compactOff : BoardIcons.compactOn }

    /// The template image of the segment: the board's strokes, which the
    /// control colors as it colors its own images.
    func image(size: CGFloat) -> NSImage {
        let icon = self.icon
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(IconPath.cgPath(icon, in: rect, flipY: true))
            context.setLineWidth(icon.lineWidth * size / 16)
            context.setLineCap(icon.roundCaps ? .round : .butt)
            context.setLineJoin(icon.roundJoins ? .round : .miter)
            context.setStrokeColor(NSColor.black.cgColor)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = title
        return image
    }
}

/// The segmented control, with a tooltip for the segment under the pointer.
final class ModeSegmentedControl: NSSegmentedControl {
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override func becomeFirstResponder() -> Bool { false }

    private let tipOwner = QuickTip.Owner()
    private var tipArea: NSTrackingArea?
    private var tipSegment: Int?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tipArea { removeTrackingArea(tipArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tipArea = area
    }

    /// The segment at a point: the segments share the width equally.
    func segment(at point: NSPoint) -> Int? {
        guard segmentCount > 0, bounds.contains(point) else { return nil }
        return min(segmentCount - 1, max(0, Int(point.x / (bounds.width / CGFloat(segmentCount)))))
    }

    private func followTip(_ event: NSEvent) {
        let segment = segment(at: convert(event.locationInWindow, from: nil))
        guard segment != tipSegment else { return }
        tipSegment = segment
        if let segment, let mode = DisplayMode(rawValue: segment) {
            QuickTip.schedule(mode.title, owner: tipOwner, appearance: effectiveAppearance)
        } else {
            QuickTip.cancel(owner: tipOwner)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        followTip(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        followTip(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        tipSegment = nil
        QuickTip.cancel(owner: tipOwner)
    }

    override func mouseDown(with event: NSEvent) {
        tipSegment = nil
        QuickTip.cancel(owner: tipOwner)
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { QuickTip.cancel(owner: tipOwner) }
    }
}

struct DisplayModeSwitch: NSViewRepresentable {
    var mode: DisplayMode
    /// The other segment was pressed: the mode to switch to.
    var choose: (DisplayMode) -> Void
    @Environment(\.textScale) var k

    final class Coordinator: NSObject {
        var choose: (DisplayMode) -> Void = { _ in }
        var mode: DisplayMode = .detailed

        @objc func pressed(_ sender: NSSegmentedControl) {
            if let next = DisplayMode(rawValue: sender.selectedSegment), next != mode { choose(next) }
            // The model decides; until it does, the current mode shows.
            sender.selectedSegment = mode.rawValue
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ModeSegmentedControl {
        let control = ModeSegmentedControl()
        control.segmentCount = DisplayMode.allCases.count
        control.trackingMode = .selectOne
        control.controlSize = .small
        control.refusesFirstResponder = true
        control.target = context.coordinator
        control.action = #selector(Coordinator.pressed(_:))
        control.setAccessibilityLabel("Display mode")
        for mode in DisplayMode.allCases {
            control.setLabel("", forSegment: mode.rawValue)
            control.setToolTip(nil, forSegment: mode.rawValue)
        }
        control.setContentHuggingPriority(.required, for: .horizontal)
        update(control, context: context)
        return control
    }

    func updateNSView(_ control: ModeSegmentedControl, context: Context) {
        update(control, context: context)
    }

    private func update(_ control: ModeSegmentedControl, context: Context) {
        context.coordinator.choose = choose
        context.coordinator.mode = mode
        let size = (14 * k).rounded()
        if control.image(forSegment: 0)?.size.width != size {
            for mode in DisplayMode.allCases {
                control.setImage(mode.image(size: size), forSegment: mode.rawValue)
                control.setImageScaling(.scaleNone, forSegment: mode.rawValue)
                control.setWidth(size + 12, forSegment: mode.rawValue)
            }
        }
        if control.selectedSegment != mode.rawValue { control.selectedSegment = mode.rawValue }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ModeSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}
