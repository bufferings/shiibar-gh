// The Filter row and the options (docs/design/Main.html, the Filter scenes;
// DESIGN.md, "Screens", "Filter"): under the search row, always (not while
// the Dismissed list shows), the `Filter` tab (icon, name, chevron and the
// accent-colored dot), then, while a setting differs from its default, the
// summary; in All, `Grouping…` at the right end. Nothing in the row changes
// a setting. When open, the tab joins a box under the row with two rows of
// options: the Status buttons, then the Muted and Unread switches with
// `Reset` at the right end. The options, `Reset` and `Grouping…` are drawn
// by the app and never take the keyboard focus, so the keys keep working on
// the list and the search field while they show.
//
// AppKit API used, as declared in the SDK headers (NSControl.h, NSView.h,
// NSResponder.h, NSButton.h): `refusesFirstResponder` (NSControl),
// `acceptsFirstResponder` (NSResponder) and `canBecomeKeyView` (NSView),
// overridden to NO here, and `becomeFirstResponder` (NSResponder) too,
// because `makeFirstResponder:` does not ask `acceptsFirstResponder` before
// it and would otherwise give a control the focus;
// `NSButton(checkboxWithTitle:target:action:)`. A test (ShiibarGhAppTests,
// FilterControlsTests) checks that none of the controls becomes the first
// responder, asked in code or by Tab.

import AppKit
import ShiibarGhCore
import SwiftUI

/// Sizes of the Filter's area at text size 12 (DESIGN.md, "Constants";
/// Main.html `.frow`, `.fopt2`).
enum FilterOptionsLayout {
    /// The list keeps at least this height (times the text scale): the
    /// popover and the window are at least as high as that needs
    /// (`SurfaceHeight`).
    static let listMinimum: CGFloat = 100
    /// The Filter row, without the space under it.
    static let filterRowHeight: CGFloat = 26
    /// Under the closed Filter row, before the list, at every text size,
    /// unless the list starts with a band heading, whose top line then sits
    /// right under the row (`closedRoom`). While open the tab meets the box
    /// instead, and the box's bottom margin is the room before the list.
    static let filterRowBottom: CGFloat = 6

    /// The room under the Filter row as laid out: none while open (the tab
    /// meets the box) or while the list starts with a band.
    static func closedRoom(open: Bool, bandFirst: Bool) -> CGFloat {
        open || bandFirst ? 0 : filterRowBottom
    }
    /// The box's corners, but the top-left one, which the tab above joins
    /// (DESIGN.md, "Filter").
    static let boxRadius: CGFloat = 8
    /// Outside the box: none above (the open tab meets it), at the sides
    /// the cards' inset, below the room before the list. Points at
    /// text size 12; the top and the bottom grow with the text (`scaled`),
    /// the sides stay as the cards' do, so the box lines up with the cards
    /// and the search field at every text size. A scrolled list never comes
    /// up to the box (the list is clipped at its own top).
    static let boxMargin = EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12)

    /// The whole area for a box `box` points high: the box and its margins.
    /// It never shrinks.
    static func areaHeight(box: CGFloat, k: CGFloat) -> CGFloat {
        box + (boxMargin.top + boxMargin.bottom) * k
    }

    /// The whole area for the options of `filter` in a surface `width`
    /// points wide.
    @MainActor
    static func areaHeight(filter: ListFilter, width: CGFloat, k: CGFloat) -> CGFloat {
        areaHeight(box: FilterOptionsGeometry(filter: filter, width: boxWidth(surface: width), k: k).height, k: k)
    }

    /// The box's width in a surface `width` points wide.
    static func boxWidth(surface width: CGFloat) -> CGFloat {
        max(0, width - boxMargin.leading - boxMargin.trailing)
    }

    /// How far opening the options moves the list down: their area, less
    /// the closed row's room under it, which the open row gives up.
    static func openShift(area: CGFloat, bandFirst: Bool) -> CGFloat {
        area - closedRoom(open: false, bandFirst: bandFirst)
    }

    /// The least height of the popover or window (`SurfaceHeight`): the
    /// list's top as laid out (`listTop`) without the options as drawn
    /// (`shownOptions`, 0 while closed), without the room under the row as
    /// laid out (`rowRoom`, `closedRoom`) and without the bands (`bands`),
    /// plus the options' full area (`area`); the list's minimum; the part
    /// under the list (`below`). The same open or closed, with or without
    /// bands, whatever the list starts with.
    static func surfaceMinimum(
        listTop: CGFloat, shownOptions: CGFloat, rowRoom: CGFloat, bands: CGFloat, below: CGFloat, area: CGFloat, k: CGFloat
    ) -> CGFloat {
        SurfaceHeight.minimum(above: listTop - shownOptions - rowRoom - bands + area, below: below, k: k)
    }

    /// The top and the bottom multiplied by `k`, the sides as they are.
    static func scaled(_ insets: EdgeInsets, _ k: CGFloat) -> EdgeInsets {
        EdgeInsets(top: insets.top * k, leading: insets.leading, bottom: insets.bottom * k, trailing: insets.trailing)
    }
}

/// The options area.
struct FilterOptionsState: Equatable {
    var shows: Bool
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
    /// The list starts with a band heading (`SurfaceListModel
    /// .startsWithBand`): closed, the row keeps no room under it.
    var bandFirst = false
}

/// The `Filter` tab (DESIGN.md, "Filter"): the filter icon, `Filter` in
/// semibold, its chevron (right while closed, down while open) and the
/// accent-colored dot when there is one. Open, it is a tab: the cards'
/// ground, a border on its top and sides, rounded top corners, and it
/// reaches down over the options box's top border, so the two read as one
/// shape. Closed, the same parts at the same place without ground or
/// border. Any press on it opens or closes the options; the dot has no
/// action of its own.
struct FilterButton: View {
    /// At text size 12, in proportion to the text size; `Grouping…` beside
    /// it is as tall (DESIGN.md, "Constants").
    static let height: CGFloat = 26
    /// The icon before `Filter`, in a frame as large as `Grouping…`'s.
    static let icon = BoardIcons.filter
    static let iconSize: CGFloat = 13
    /// Inside the tab, at either side (times the text scale).
    static let sidePadding: CGFloat = 10
    /// Between the icon, the name, the chevron and the dot.
    static let spacing: CGFloat = 6

    var open: Bool
    var dot: Bool
    var toggle: () -> Void
    @Environment(\.textScale) var k

    static let dotTip = FilterText.dotTip

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Self.spacing * k) {
                IconView(icon: Self.icon, size: Self.iconSize * k, color: Palette.text.color)
                Text("Filter")
                    .font(.system(size: 12 * k, weight: .semibold))
                    .foregroundColor(Palette.text.color)
                    .fixedSize()
                IconView(icon: open ? BoardIcons.filterOpen : BoardIcons.filterClosed, size: 10 * k, color: Palette.secondary.color)
                if dot {
                    Circle()
                        .fill(Palette.accent.color)
                        .frame(width: 7 * k, height: 7 * k)
                        .frame(height: Self.height * k)
                        .contentShape(Rectangle())
                        .quickHelp(Self.dotTip)
                }
            }
            .padding(.horizontal, Self.sidePadding * k)
            .frame(height: Self.height * k)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background(alignment: .top) {
            if open {
                // Down over the box's 1-point top border, which it meets.
                let height = (Self.height + FilterOptionsLayout.boxMargin.top) * k + 1
                FilterTabShape(radius: FilterOptionsLayout.boxRadius, closed: true)
                    .fill(Palette.surface.color)
                    .frame(height: height)
                    .overlay(FilterTabShape(radius: FilterOptionsLayout.boxRadius, closed: false).stroke(Palette.border.color, lineWidth: 1))
                    .frame(height: height, alignment: .top)
            }
        }
        .accessibilityLabel(dot ? "Filter, unread pull requests hidden" : "Filter")
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// The open `Filter` tab's outline: up the left side, round the top corners
/// and down the right side. `closed` closes it along the bottom for the
/// fill; the border leaves the bottom open, where the tab joins the box.
/// The lines run half a point inside, so a 1-point line covers whole
/// pixels.
struct FilterTabShape: Shape {
    var radius: CGFloat
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        let box = closed ? rect : rect.insetBy(dx: 0.5, dy: 0.5)
        let bottom = rect.maxY
        let r = min(radius, box.width / 2, box.height)
        var path = Path()
        path.move(to: CGPoint(x: box.minX, y: bottom))
        path.addLine(to: CGPoint(x: box.minX, y: box.minY + r))
        path.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY), tangent2End: CGPoint(x: box.minX + r, y: box.minY), radius: r)
        path.addLine(to: CGPoint(x: box.maxX - r, y: box.minY))
        path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY), tangent2End: CGPoint(x: box.maxX, y: box.minY + r), radius: r)
        path.addLine(to: CGPoint(x: box.maxX, y: bottom))
        if closed { path.closeSubpath() }
        return path
    }
}

/// The Filter row of the surface, while it shows. Over what follows it, so
/// the open tab covers the box's top border where they join.
struct FilterRowSlot: View {
    var list: SurfaceListModel
    @ObservedObject var state: Derived<FilterRowState>

    var body: some View {
        if state.value.shows {
            FilterRow(value: state.value, toggle: { [list] in list.toggleFilterOpen() }, openGrouping: { [list] in list.openGrouping() })
                .zIndex(1)
        }
    }
}

/// The Filter row (DESIGN.md, "Filter"; Main.html `.frow`): from the left
/// `Filter`, then the summary, and in All `Grouping…` at the right end with
/// room between. Only the summary gives way when the row is narrow: it is
/// cut with `…` (then, and only then, its tooltip shows all of it). The
/// summary has no action. Closed, the row keeps its room under it unless
/// the list starts with a band, whose top line then sits right under the
/// row; open, the tab reaches down to the box instead.
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
                GroupingButton(press: openGrouping)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .frame(height: FilterOptionsLayout.filterRowHeight * k)
        .padding(EdgeInsets(
            top: 0, leading: 12, bottom: FilterOptionsLayout.closedRoom(open: value.open, bandFirst: value.bandFirst), trailing: 12
        ))
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

/// The options' box with its margins (DESIGN.md, "Filter"): the cards'
/// ground and border, the cards' side inset, square at the top left where
/// the tab joins. Always at its full height: the popover or the window
/// grows instead (`SurfaceHeight`); no line is drawn under it.
struct FilterOptions: View {
    var list: SurfaceListModel
    var state: FilterOptionsState
    @Environment(\.textScale) var k

    var body: some View {
        FilterOptionsControl(
            filter: state.filter, canReset: state.canReset,
            act: { [list] target in
                switch target {
                case .status(let status): list.toggleStatus(status)
                case .muted(let choice): list.setMuteChoice(choice)
                case .unread(let only): list.setUnreadOnly(only)
                case .reset: list.resetFilter()
                }
            }
        )
        .padding(FilterOptionsLayout.scaled(FilterOptionsLayout.boxMargin, k))
    }
}

// MARK: - The options' box

/// Where everything in the options' box goes, at text scale `k` for a box
/// `width` points wide, in the box's flipped coordinates (DESIGN.md,
/// "Filter", "Constants"; Main.html `.fopt2`). Two rows: the heading
/// `Status` and the four Status buttons, which wrap within the column right
/// of the heading when the box is narrow; then the heading `Muted` and its
/// switch, the heading `Unread` and its switch, and `Reset` at the right
/// end, where `Unread` and `Reset` move to a third row (`Unread` under
/// `Muted`) when they do not fit. A control wider than the column right of
/// its heading goes under the heading from the left edge, and `Reset` to a
/// line of its own, so nothing reaches past the box's inner width. The box
/// grows with the lines.
@MainActor
struct FilterOptionsGeometry: Equatable {
    /// What a press on a part does.
    enum Target: Hashable {
        case status(PRStatus)
        case muted(MuteChoice)
        /// `Only` (true) or `All` (false) of Unread: `Unread only`.
        case unread(Bool)
        case reset
    }

    struct Part: Equatable {
        var target: Target
        var title: String
        var frame: CGRect
        var on: Bool
    }

    struct Heading: Equatable {
        var title: String
        var frame: CGRect
    }

    // Points at text size 12, all in proportion to the text size.
    /// From the box's outer edge to the rows, above and below (the 1-point
    /// border included): 6 + 22 + 6 + 22 + 6 = 62 for two rows.
    static let vertical: CGFloat = 6
    /// From the box's outer edge to the rows, at either side.
    static let horizontal: CGFloat = 10
    static let rowHeight: CGFloat = 22
    static let rowGap: CGFloat = 6
    /// The first column, the headings `Status` and `Muted` (and `Unread`
    /// on a third row), so the buttons and the switch line up.
    static let headingWidth: CGFloat = 44
    static let headingSize: CGFloat = 11
    static let fontSize: CGFloat = 12
    static let radius: CGFloat = 7
    /// Inside a Status button or a switch segment, at either side.
    static let padding: CGFloat = 10
    static let chipGap: CGFloat = 4
    /// The ✓ of a Status button that is on, and its room before the name.
    static let check: CGFloat = 9
    static let checkGap: CGFloat = 4
    /// Between the Muted switch and the heading `Unread`, and the least
    /// room before `Reset`.
    static let groupGap: CGFloat = 14
    /// Between the heading `Unread` and its switch on the second row.
    static let headingGap: CGFloat = 6
    /// Around `Reset`'s text: its press area.
    static let resetPadding: CGFloat = 2

    var k: CGFloat
    var headings: [Heading] = []
    var chips: [Part] = []
    var muted: [Part] = []
    var unread: [Part] = []
    var reset: Part
    /// The rows of options: 2, or 3 when Unread and `Reset` move down.
    var rows: Int
    /// The lines the Status buttons take.
    var statusLines: Int
    /// Every line in the box, each `rowHeight` high, `rowGap` apart.
    var lines: Int
    var height: CGFloat

    static func font(_ size: CGFloat, on: Bool) -> NSFont { Ink.font(size, on ? .semibold : .regular) }

    /// A Status button's width: the name, the ✓ when on, the padding.
    static func chipWidth(_ title: String, on: Bool, k: CGFloat) -> CGFloat {
        let text = Ink.width(title, font(fontSize * k, on: on))
        return ((on ? check * k + checkGap * k : 0) + text + 2 * padding * k).rounded(.up)
    }

    static func segmentWidth(_ title: String, on: Bool, k: CGFloat) -> CGFloat {
        (Ink.width(title, font(fontSize * k, on: on)) + 2 * padding * k).rounded(.up)
    }

    /// The segments of a switch from `x` on the row at `y`, each as wide as
    /// its text (semibold when selected), a 1-point line between them.
    private static func segments(_ titles: [(Target, String, Bool)], x: CGFloat, y: CGFloat, k: CGFloat) -> [Part] {
        var x = x
        return titles.map { target, title, on in
            let width = segmentWidth(title, on: on, k: k)
            defer { x += width + 1 }
            return Part(target: target, title: title, frame: CGRect(x: x, y: y, width: width, height: rowHeight * k), on: on)
        }
    }

    init(filter: ListFilter, width: CGFloat, k: CGFloat) {
        self.k = k
        let row = Self.rowHeight * k
        let gap = Self.rowGap * k
        let left = Self.horizontal * k
        let right = width - Self.horizontal * k
        let column = left + Self.headingWidth * k
        let headingFont = Ink.font(Self.headingSize * k)
        func heading(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat? = nil) -> Heading {
            Heading(title: title, frame: CGRect(x: x, y: y, width: width ?? Ink.width(title, headingFont).rounded(.up), height: row))
        }

        var y = Self.vertical * k
        var lines = 1
        func newLine() {
            y += row + gap
            lines += 1
        }
        // Where a control `w` wide starts right of its heading: in the
        // column right of it, or, when it is wider than that column, on a
        // line of its own under the heading from the left edge, so no part
        // ever reaches past the box's inner width.
        func start(_ w: CGFloat) -> CGFloat {
            if column + w <= right { return column }
            newLine()
            return left
        }

        // Row 1: Status, the buttons wrapping within their column.
        headings.append(heading(FilterOption.status.title, x: left, y: y, width: Self.headingWidth * k))
        let statuses = PRStatus.allCases.map { status in (status, filter.shows(status), Self.chipWidth(status.title, on: filter.shows(status), k: k)) }
        let first = start(statuses.map(\.2).max() ?? 0)
        var x = first
        var statusLines = 1
        for (status, on, w) in statuses {
            if x > first, x + w > right {
                x = first
                newLine()
                statusLines += 1
            }
            chips.append(Part(target: .status(status), title: status.title, frame: CGRect(x: x, y: y, width: w, height: row), on: on))
            x += w + Self.chipGap * k
        }
        self.statusLines = statusLines

        // Row 2: Muted, Unread, Reset.
        newLine()
        headings.append(heading(FilterOption.muted.title, x: left, y: y, width: Self.headingWidth * k))
        let mutedChoices = MuteChoice.allCases.map { (Target.muted($0), $0.title, filter.muted == $0) }
        let mutedWidth = mutedChoices.reduce(CGFloat(-1)) { $0 + Self.segmentWidth($1.1, on: $1.2, k: k) + 1 }
        muted = Self.segments(mutedChoices, x: start(mutedWidth), y: y, k: k)
        let resetFont = Ink.font(Self.fontSize * k)
        let resetWidth = (Ink.width(FilterText.reset, resetFont) + 2 * Self.resetPadding * k).rounded(.up)
        let unreadTitle = FilterOption.unread.title
        let unreadChoices: [(Target, String, Bool)] = [(.unread(false), "All", !filter.unreadOnly), (.unread(true), "Only", filter.unreadOnly)]
        let unreadWidth = unreadChoices.reduce(CGFloat(-1)) { $0 + Self.segmentWidth($1.1, on: $1.2, k: k) + 1 }
        let mutedEnd = muted.last?.frame.maxX ?? column
        let unreadHeading = Ink.width(unreadTitle, headingFont).rounded(.up)
        let inline = mutedEnd + Self.groupGap * k + unreadHeading + Self.headingGap * k + unreadWidth + Self.groupGap * k + resetWidth <= right
        if inline {
            let h = heading(unreadTitle, x: mutedEnd + Self.groupGap * k, y: y)
            headings.append(h)
            unread = Self.segments(unreadChoices, x: h.frame.maxX + Self.headingGap * k, y: y, k: k)
            rows = 2
        } else {
            newLine()
            headings.append(heading(unreadTitle, x: left, y: y, width: Self.headingWidth * k))
            unread = Self.segments(unreadChoices, x: start(unreadWidth), y: y, k: k)
            rows = 3
            // `Reset` at the right end of Unread's line, or of a line of
            // its own when it does not fit there.
            if (unread.last?.frame.maxX ?? left) + Self.groupGap * k + resetWidth > right { newLine() }
        }
        reset = Part(target: .reset, title: FilterText.reset, frame: CGRect(x: right - resetWidth, y: y, width: resetWidth, height: row), on: false)
        self.lines = lines
        height = y + row + Self.vertical * k
    }

    /// Every part a press acts on.
    var parts: [Part] { chips + muted + unread + [reset] }

    /// The part under a point, nil elsewhere.
    func target(at point: CGPoint) -> Target? {
        parts.first { $0.frame.contains(point) }?.target
    }

    /// The frame around a switch's segments.
    static func switchFrame(_ segments: [Part]) -> CGRect {
        segments.reduce(CGRect.null) { $0.union($1.frame) }
    }
}

/// The options' box, drawn by the app (Main.html `.fopt2`): standard
/// controls keep their height whatever the text size. Mouse only; it never
/// takes the keyboard focus (DESIGN.md, "Filter"). A press acts when the
/// button is released over the part it went down on. Assistive apps see a
/// group with a check box per Status button, a radio button per switch
/// segment and the `Reset` button, each named so it reads without its
/// heading (`Status: Open, on`, `Muted: Show, selected`).
final class FilterOptionsView: NSView {
    var filter = ListFilter() { didSet { if filter != oldValue { relayout() } } }
    var canReset = false { didSet { if canReset != oldValue { needsDisplay = true; updateAccessibility() } } }
    var k: CGFloat = 1 { didSet { if k != oldValue { relayout() } } }
    var act: (FilterOptionsGeometry.Target) -> Void = { _ in }

    private var pressed: FilterOptionsGeometry.Target? { didSet { if pressed != oldValue { needsDisplay = true } } }
    private var elements: [FilterOptionElement] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Filter options")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override func becomeFirstResponder() -> Bool { false }

    var geometry: FilterOptionsGeometry { FilterOptionsGeometry(filter: filter, width: bounds.width, k: k) }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: geometry.height) }

    private func relayout() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
        updateAccessibility()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    /// A part pressed or picked by an assistive app: `Reset` only while
    /// there is something to reset.
    func press(_ target: FilterOptionsGeometry.Target) {
        if target == .reset, !canReset { return }
        act(target)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let geometry = geometry
        let k = geometry.k
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let outline = Self.boxPath(box, radius: FilterOptionsLayout.boxRadius)
        Palette.surface.nsColor.setFill()
        Self.boxPath(bounds, radius: FilterOptionsLayout.boxRadius).fill()
        Palette.border.nsColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let headingFont = Ink.font(FilterOptionsGeometry.headingSize * k)
        for heading in geometry.headings {
            Ink.drawLine(heading.title, headingFont, Palette.secondary.nsColor, in: heading.frame.insetBy(dx: -0.5, dy: 0))
        }
        let radius = FilterOptionsGeometry.radius * k
        for chip in geometry.chips {
            drawGround(NSBezierPath(roundedRect: chip.frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius), on: chip.on || pressed == chip.target)
            let font = FilterOptionsGeometry.font(FilterOptionsGeometry.fontSize * k, on: chip.on)
            var x = chip.frame.minX + FilterOptionsGeometry.padding * k
            if chip.on {
                let side = FilterOptionsGeometry.check * k
                Shapes.icon(BoardIcons.optionCheck, in: CGRect(x: x, y: chip.frame.midY - side / 2, width: side, height: side), color: Palette.text.nsColor, grid: 10)
                x += side + FilterOptionsGeometry.checkGap * k
            }
            Ink.drawLine(chip.title, font, Palette.text.nsColor, in: CGRect(x: x, y: chip.frame.minY, width: chip.frame.maxX - x, height: chip.frame.height))
        }
        drawSwitch(geometry.muted, k: k)
        drawSwitch(geometry.unread, k: k)
        let reset = geometry.reset
        let color = canReset ? (pressed == .reset ? Palette.text.nsColor : Palette.accent.nsColor) : Palette.tertiary.nsColor
        Ink.drawLine(reset.title, Ink.font(FilterOptionsGeometry.fontSize * k), color, in: reset.frame.insetBy(dx: FilterOptionsGeometry.resetPadding * k, dy: 0).insetBy(dx: -0.5, dy: 0))
    }

    /// A rounded rectangle with a square top-left corner.
    static func boxPath(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.appendArc(from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.appendArc(from: CGPoint(x: rect.maxX, y: rect.maxY), to: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        path.line(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.appendArc(from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        path.close()
        return path
    }

    private func drawGround(_ path: NSBezierPath, on: Bool) {
        (on ? Palette.optionOn : Palette.optionOff).nsColor.setFill()
        path.fill()
        Palette.border.nsColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawSwitch(_ segments: [FilterOptionsGeometry.Part], k: CGFloat) {
        guard !segments.isEmpty else { return }
        let frame = FilterOptionsGeometry.switchFrame(segments)
        let radius = FilterOptionsGeometry.radius * k
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        Palette.optionOff.nsColor.setFill()
        outline.fill()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        for segment in segments where segment.on || pressed == segment.target {
            Palette.optionOn.nsColor.setFill()
            // Over the line on either side, which is drawn again below.
            segment.frame.insetBy(dx: -1, dy: 0).fill()
        }
        Palette.border.nsColor.setFill()
        for segment in segments.dropFirst() {
            CGRect(x: segment.frame.minX - 1, y: frame.minY, width: 1, height: frame.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        Palette.border.nsColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        for segment in segments {
            let font = FilterOptionsGeometry.font(FilterOptionsGeometry.fontSize * k, on: segment.on)
            Ink.drawLine(segment.title, font, Palette.text.nsColor, in: segment.frame.insetBy(dx: FilterOptionsGeometry.padding * k, dy: 0).insetBy(dx: -0.5, dy: 0))
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        pressed = geometry.target(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed, geometry.target(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        press(pressed)
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        let parts = geometry.parts
        if elements.count != parts.count {
            elements = parts.map { FilterOptionElement(target: $0.target, owner: self) }
        }
        for (element, part) in zip(elements, parts) { element.update(part, enabled: part.target != .reset || canReset) }
        setAccessibilityChildren(elements)
    }

    /// The name an assistive app reads for a part, without its heading.
    static func accessibilityName(_ part: FilterOptionsGeometry.Part) -> String {
        switch part.target {
        case .status: return "Status: \(part.title), \(part.on ? "on" : "off")"
        case .muted: return "Muted: \(part.title)" + (part.on ? ", selected" : "")
        case .unread: return "Unread: \(part.title)" + (part.on ? ", selected" : "")
        case .reset: return part.title
        }
    }

    /// The elements as assistive apps see them (tests).
    var accessibilityParts: [FilterOptionElement] { elements }
}

/// One part of `FilterOptionsView` for assistive apps.
final class FilterOptionElement: NSAccessibilityElement {
    let target: FilterOptionsGeometry.Target
    private weak var owner: FilterOptionsView?

    init(target: FilterOptionsGeometry.Target, owner: FilterOptionsView) {
        self.target = target
        self.owner = owner
        super.init()
        switch target {
        case .status: setAccessibilityRole(.checkBox)
        case .muted, .unread: setAccessibilityRole(.radioButton)
        case .reset: setAccessibilityRole(.button)
        }
        setAccessibilityParent(owner)
    }

    func update(_ part: FilterOptionsGeometry.Part, enabled: Bool) {
        setAccessibilityLabel(FilterOptionsView.accessibilityName(part))
        if part.target != .reset { setAccessibilityValue(part.on ? 1 : 0) }
        setAccessibilityEnabled(enabled)
        setAccessibilityFrameInParentSpace(part.frame)
    }

    override func accessibilityPerformPress() -> Bool {
        owner?.press(target)
        return true
    }
}

struct FilterOptionsControl: NSViewRepresentable {
    var filter: ListFilter
    var canReset: Bool
    var act: (FilterOptionsGeometry.Target) -> Void
    @Environment(\.textScale) var k

    func makeNSView(context: Context) -> FilterOptionsView {
        let view = FilterOptionsView(frame: .zero)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        update(view)
        return view
    }

    func updateNSView(_ view: FilterOptionsView, context: Context) {
        update(view)
    }

    private func update(_ view: FilterOptionsView) {
        view.act = act
        view.k = k
        view.filter = filter
        view.canReset = canReset
    }

    /// As wide as offered, as high as its rows at that width.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FilterOptionsView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        return CGSize(width: width, height: FilterOptionsGeometry(filter: filter, width: width, k: k).height)
    }
}

// MARK: - Controls that never take the keyboard focus

/// A checkbox (NSButton) for the mouse only.
final class NoFocusCheckbox: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

/// `Grouping…` (DESIGN.md, "All", "Grouping settings", and "Constants"):
/// as tall as the Filter button beside it (26 points), its text 12 points,
/// both at text size 12 and in proportion to the text size. No border and
/// no ground: secondary-colored text after an icon of three lines, the
/// lower two indented, so it reads quieter than `Filter`. A standard push
/// button's height is fixed, so the app draws this one. Mouse only and an
/// accessibility button.
final class DrawnButton: NSControl {
    var title: String { didSet { if title != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var k: CGFloat = 1 { didSet { if k != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var press: () -> Void = {}
    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }

    /// At text size 12: the Filter button's height.
    static let height: CGFloat = FilterButton.height
    static let fontSize: CGFloat = 12
    /// At either side, before the icon and after the text.
    static let sidePadding: CGFloat = 4
    static let iconSize: CGFloat = 13
    /// Between the icon and the text.
    static let iconGap: CGFloat = 6
    static let icon = BoardIcons.grouping

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override func becomeFirstResponder() -> Bool { false }

    static func size(_ title: String, k: CGFloat) -> CGSize {
        let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize * k)]).width
        return CGSize(width: (width + (2 * sidePadding + iconSize + iconGap) * k).rounded(.up), height: (height * k).rounded())
    }

    override var intrinsicContentSize: NSSize { Self.size(title, k: k) }

    override func accessibilityLabel() -> String? { title }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { press() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The icon's square and the text's origin in the bounds.
    var iconFrame: CGRect {
        let side = Self.iconSize * k
        return CGRect(x: Self.sidePadding * k, y: (bounds.height - side) / 2, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Pressed, the label color: the press shows without a ground.
        let ink = pressed ? Palette.text.nsColor : Palette.secondary.nsColor
        Shapes.icon(Self.icon, in: iconFrame, color: ink)
        let font = NSFont.systemFont(ofSize: Self.fontSize * k)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let size = (title as NSString).size(withAttributes: attributes)
        let origin = CGPoint(x: iconFrame.maxX + Self.iconGap * k, y: (bounds.height - size.height) / 2)
        (title as NSString).draw(at: origin, withAttributes: attributes)
    }
}

/// `Grouping…` at the right end of All's Filter row, which opens the
/// Grouping sheet (DESIGN.md, "All", "Grouping settings").
struct GroupingButton: NSViewRepresentable {
    static let title = "Grouping\u{2026}"
    var press: () -> Void
    @Environment(\.textScale) var k

    func makeNSView(context: Context) -> DrawnButton {
        let button = DrawnButton(title: Self.title)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        update(button)
        return button
    }

    func updateNSView(_ button: DrawnButton, context: Context) {
        update(button)
    }

    private func update(_ button: DrawnButton) {
        button.press = press
        button.k = k
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DrawnButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// A standard checkbox. `press` makes the change and returns the value the
/// box then shows.
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
