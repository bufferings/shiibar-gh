// `Filter` in the operation row and its options (docs/design/Main.html, the
// Filter scenes; DESIGN.md, "Filter"): the word, the chevron, the blue dot
// and the summary; when open, one option a line between the operation row
// and the list. The options are standard AppKit controls that never take
// the keyboard focus, so the keys keep working on the list and the search
// field while the options show.
//
// AppKit API used, as declared in the SDK headers (NSControl.h, NSView.h,
// NSResponder.h, NSSegmentedControl.h, NSButton.h): `refusesFirstResponder`
// (NSControl), `acceptsFirstResponder` (NSResponder) and `canBecomeKeyView`
// (NSView), overridden to NO here, and `becomeFirstResponder` (NSResponder)
// too: `makeFirstResponder:` does not ask `acceptsFirstResponder` before it
// (the test below saw a control take the focus that way);
// `NSSegmentedControl(labels:trackingMode:target:action:)` with
// `.selectOne`; `NSButton(checkboxWithTitle:target:action:)`. A test
// (ShiibarGhAppTests, FilterControlsTests) checks that none of them becomes
// the first responder, asked in code or by Tab.

import AppKit
import ShiibarGhCore
import SwiftUI

/// Sizes of the Filter's area at text size 12 (DESIGN.md, "Constants";
/// Main.html `.fo`, `.fopts`).
enum FilterOptionsLayout {
    /// The list keeps at least this height while the options show.
    static let listMinimum: CGFloat = 100
    /// The search field gives way down to this width.
    static let searchMinimum: CGFloat = 140
    /// One option line.
    static let rowHeight: CGFloat = 27
    /// Under the last line, before the border.
    static let bottomPadding: CGFloat = 6
    /// Below the border, before the list.
    static let gap: CGFloat = 6
    /// The pop-up buttons of All's lines.
    static let popUpWidth: CGFloat = 150
}

/// The options area.
struct FilterOptionsState: Equatable {
    var shows: Bool
    var tab: ListTab
    var filter: ListFilter
    var options: ListOptions
}

/// `Filter`, its chevron (right while closed, down while open), the blue
/// dot and the summary (Main.html `.flt`). Any press on it opens or closes
/// the options; the dot and the summary have no action of their own. The
/// summary takes its own width and is cut with `…` when the row runs out;
/// then its tooltip shows all of it.
struct FilterButton: View {
    var open: Bool
    var dot: Bool
    var summary: String?
    var toggle: () -> Void
    @Environment(\.textScale) var k
    @State private var summaryShown: CGFloat = 0

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
                if let summary {
                    Text(summary)
                        .font(.system(size: 11 * k))
                        .foregroundColor(Palette.secondary.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: SummaryWidthKey.self, value: geometry.size.width)
                        })
                        .onPreferenceChange(SummaryWidthKey.self) { summaryShown = $0 }
                        .quickHelp(ifAny: cut(summary) ? summary : nil)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 24 * k)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(dot ? "Filter, unread pull requests hidden" : "Filter")
        .accessibilityValue(summary ?? "")
        .accessibilityAddTraits(open ? .isSelected : [])
    }

    /// The summary is shown narrower than it is.
    private func cut(_ summary: String) -> Bool {
        Self.isCut(summary, shownWidth: summaryShown, k: k)
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
    var model: AccountViewModel
    @ObservedObject var state: Derived<FilterOptionsState>
    @Environment(\.textScale) var k

    var body: some View {
        if state.value.shows {
            FilterOptions(list: list, model: model, state: state.value)
        }
    }
}

/// One option a line, the name at the left and the control at the right
/// (Main.html `.fopts`, `.fo`): Muted, Status and Unread in every tab, then
/// Group by, Then by and Sort in All. Scrolls inside when the surface is
/// short (the list keeps its minimum height).
struct FilterOptions: View {
    var list: SurfaceListModel
    var model: AccountViewModel
    var state: FilterOptionsState
    @Environment(\.textScale) var k

    var body: some View {
        let lines = state.tab == .all ? 6 : 3
        let height = CGFloat(lines) * FilterOptionsLayout.rowHeight * k + FilterOptionsLayout.bottomPadding
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                line("Muted") { mutedControl }
                line("Status") { statusControl }
                line("Unread") {
                    CheckBox(title: "Unread only", on: state.filter.unreadOnly) { [list] in
                        list.setUnreadOnly(!list.filter.unreadOnly)
                        return list.filter.unreadOnly
                    }
                }
                if state.tab == .all {
                    let options = state.options
                    line("Group by") {
                        PullDown(
                            title: options.groupBy.title, toolTip: nil, accessibilityName: "Group by",
                            minWidth: FilterOptionsLayout.popUpWidth, refusesFocus: true, items: groupByItems(options)
                        )
                    }
                    line("Then by") {
                        PullDown(
                            title: options.thenByTitle, toolTip: nil, accessibilityName: "Then by", enabled: options.groupBy != .none,
                            minWidth: FilterOptionsLayout.popUpWidth, refusesFocus: true, items: thenByItems(options)
                        )
                    }
                    line("Sort") {
                        PullDown(
                            title: options.sort.title, toolTip: nil, accessibilityName: "Sort", minWidth: FilterOptionsLayout.popUpWidth, refusesFocus: true,
                            items: SortOrder.allCases.map { order in
                                IconMenuItem(order.title, checked: order == options.sort) { [model] in model.setSort(order) }
                            }
                        )
                    }
                }
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

    /// The five values, the current one checked, then `Grouping…`.
    private func groupByItems(_ options: ListOptions) -> [IconMenuItem?] {
        var items: [IconMenuItem?] = GroupBy.allCases.map { value in
            IconMenuItem(value.title, checked: value == options.groupBy) { [model] in model.setGroupBy(value) }
        }
        items.append(nil)
        items.append(IconMenuItem("Grouping…") { [list] in list.showsGrouping = true })
        return items
    }

    /// The same values without Group by's.
    private func thenByItems(_ options: ListOptions) -> [IconMenuItem?] {
        options.thenByChoices.map { value in
            IconMenuItem(value.title, checked: value == options.thenBy) { [model] in model.setThenBy(value) }
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
