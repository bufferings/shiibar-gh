// The controls of the Filter's options, `Reset` and `Grouping…` never take the
// keyboard focus (DESIGN.md, "Filter", "All": they are for the mouse, so the
// keys keep working on the list and the search field). A window that is never shown: a control
// asked to become the first responder refuses, and Tab (the key view loop,
// which Full Keyboard Access walks) never reaches one. A text field in the
// same window does take the focus, so the window does pass it on.

import AppKit
@testable import ShiibarGhApp
import ShiibarGhCore
import SwiftUI
import XCTest

@MainActor
final class FilterControlsTests: XCTestCase {
    func controls() -> [NSView] {
        let checkbox = NoFocusCheckbox(checkboxWithTitle: "Skip", target: nil, action: nil)
        checkbox.refusesFirstResponder = true
        let grouping = DrawnButton(title: GroupingButton.title)
        let options = FilterOptionsView(frame: .zero)
        return [checkbox, grouping, options]
    }

    func testTheOptionsNeverBecomeTheFirstResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let field = NSTextField(frame: NSRect(x: 10, y: 150, width: 200, height: 22))
        window.contentView?.addSubview(field)
        let controls = controls()
        for (i, control) in controls.enumerated() {
            control.frame = NSRect(x: 10, y: 10 + CGFloat(i) * 40, width: 160, height: 24)
            window.contentView?.addSubview(control)
            XCTAssertFalse(control.acceptsFirstResponder, "\(type(of: control))")
            XCTAssertFalse(control.canBecomeKeyView, "\(type(of: control))")
            // `makeFirstResponder:` answers YES when the view refuses (the
            // window takes the focus itself; NSWindow documentation).
            window.makeFirstResponder(control)
            XCTAssertFalse(window.firstResponder === control, "\(type(of: control))")
        }
        XCTAssertTrue(window.makeFirstResponder(field), "the window passes the focus to a field")
        // Tab and ⇧Tab go round the key view loop: never to a control.
        window.recalculateKeyViewLoop()
        for _ in 0..<6 {
            window.selectNextKeyView(nil)
            XCTAssertFalse(controls.contains { $0 === window.firstResponder }, "Tab reached \(String(describing: window.firstResponder))")
        }
        for _ in 0..<6 {
            window.selectPreviousKeyView(nil)
            XCTAssertFalse(controls.contains { $0 === window.firstResponder })
        }
    }

    /// The Grouping sheet's pop-ups take the focus as in 0.5 (DESIGN.md,
    /// "Filter"): the standard pop-up button, nothing refused.
    func testTheGroupingSheetPopUpsTakeTheFocus() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        let sheet = TipPopUpButton(frame: NSRect(x: 10, y: 10, width: 150, height: 24), pullsDown: true)
        sheet.addItem(withTitle: "Repository")
        window.contentView?.addSubview(sheet)
        XCTAssertFalse(sheet.refusesFirstResponder)
        window.makeFirstResponder(sheet)
        XCTAssertTrue(window.firstResponder === sheet, "the sheet's pop-up takes the focus")
    }

    /// Sort in the Grouping sheet: the two orders, the current one checked;
    /// choosing one sets it.
    func testTheGroupingSheetSortMenu() {
        var chosen: [ShiibarGhCore.SortOrder] = []
        let items = GroupingSheet.sortItems(ListOptions(sort: .recentActivity)) { chosen.append($0) }.compactMap { $0 }
        XCTAssertEqual(items.map(\.title), ["Recent activity", "Recently added"])
        XCTAssertEqual(items.map(\.checked), [true, false])
        items[1].action()
        XCTAssertEqual(chosen, [.recentlyAdded])
        let added = GroupingSheet.sortItems(ListOptions(sort: .recentlyAdded)) { _ in }.compactMap { $0 }
        XCTAssertEqual(added.map(\.checked), [false, true])
    }

    /// The search row (DESIGN.md, "Screens"): the search field alone, the
    /// whole width of the row. Its view takes no tab, Filter or Dismissed
    /// state, so the width is the same in every tab.
    func testTheSearchFieldTakesTheWholeRow() {
        for k: CGFloat in [1, 1.5] {
            guard let field = SearchRowProbe.field(k: k, width: 460 * k) else { return XCTFail("no search field") }
            XCTAssertGreaterThanOrEqual(field.minX, 12)
            // The text field sits inside the rounded box (icon and padding
            // at the left), so its right edge is compared loosely.
            XCTAssertEqual(field.maxX, 460 * k - 12 - 8, accuracy: 4, "k \(k): to the right end")
        }
        let narrow = SearchRowProbe.field(k: 1, width: 300)
        XCTAssertEqual(narrow?.maxX ?? 0, 300 - 12 - 8, accuracy: 4)
    }

    /// DESIGN.md, "Constants": `Grouping…` is as tall as the Filter button
    /// (26 points) with 12-point text after its 13-point icon (6 points
    /// between, 4 at either end), and Restore 22 points with 12-point text
    /// and 10 points of room on either side, at text size 12; both in
    /// proportion to the text size.
    func testGroupingAndRestoreFollowTheTextSize() {
        var widths: [CGFloat] = []
        for size in [9, 12, 18] {
            let k = CGFloat(TextSize.ratio(size))
            let grouping = DrawnButton.size(GroupingButton.title, k: k)
            XCTAssertEqual(grouping.height, (26 * k).rounded(), "\(size)")
            let text = (GroupingButton.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12 * k)]).width
            XCTAssertEqual(grouping.width, (text + (8 + 13 + 6) * k).rounded(.up), "\(size)")
            let button = DrawnButton(title: GroupingButton.title)
            button.k = k
            XCTAssertEqual(button.intrinsicContentSize, grouping)
            XCTAssertEqual(button.accessibilityRole(), .button)
            XCTAssertEqual(button.accessibilityLabel(), GroupingButton.title)
            let restore = ListButton.restoreSize(k: k)
            XCTAssertEqual(restore.height, (22 * k).rounded(), "\(size)")
            let restoreText = Ink.width("Restore", Ink.font(12 * k))
            XCTAssertEqual(restore.width, (restoreText + 20 * k).rounded(.up), "\(size)")
            widths.append(grouping.width)
        }
        XCTAssertEqual(widths, widths.sorted(), "wider with a larger text")
        // As tall as the Filter button beside it, as laid out.
        for size in [9, 12, 18] {
            let k = CGFloat(TextSize.ratio(size))
            let filter = NSHostingView(rootView: FilterButton(open: false, dot: false, toggle: {}).environment(\.textScale, k)).fittingSize
            XCTAssertEqual(DrawnButton.size(GroupingButton.title, k: k).height, filter.height, accuracy: 0.5, "\(size)")
        }
        // Pressing it runs its action, by the mouse or by an assistive app.
        var pressed = 0
        let button = DrawnButton(title: GroupingButton.title)
        button.press = { pressed += 1 }
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(pressed, 1)
    }

    /// The Filter row (DESIGN.md, "Filter"): `Filter` and the summary at
    /// the left, in All `Grouping…` at the right end, no `Reset`. When
    /// narrow, only the summary gives way: `Grouping…` keeps its size and
    /// stays inside; the tooltip only while the summary is cut.
    func testTheFilterRow() {
        let long = "Open · Draft · Merged · Muted only · Unread only"
        func row(_ summary: String?, grouping: Bool) -> FilterRowState {
            FilterRowState(shows: true, open: false, dot: true, summary: summary, showsGrouping: grouping)
        }
        for k: CGFloat in [1, 1.5] {
            let width = 460 * k
            let all = FilterRowProbe.buttons(row("Muted shown", grouping: true), k: k, width: width)
            guard let grouping = all.grouping else { return XCTFail("k \(k): \(all)") }
            XCTAssertNil(all.reset, "Reset is not in the row")
            XCTAssertEqual(grouping.maxX, width - 12, accuracy: 1, "Grouping… at the right end")
            XCTAssertLessThanOrEqual(grouping.maxX, width)
            let review = FilterRowProbe.buttons(row("Muted shown", grouping: false), k: k, width: width)
            XCTAssertNil(review.grouping)
            XCTAssertNil(review.reset)
            let defaults = FilterRowProbe.buttons(row(nil, grouping: true), k: k, width: width)
            XCTAssertEqual(defaults.grouping?.maxX ?? 0, grouping.maxX, accuracy: 0.5)
        }
        // The narrowest window (300 points), the long summary: Grouping…
        // whole and inside.
        let wide = FilterRowProbe.buttons(row(long, grouping: true), k: 1, width: 460)
        let narrow = FilterRowProbe.buttons(row(long, grouping: true), k: 1, width: 300)
        guard let grouping = narrow.grouping else { return XCTFail("\(narrow)") }
        XCTAssertEqual(grouping.width, wide.grouping?.width ?? 0, accuracy: 0.5, "Grouping… is not cut")
        XCTAssertLessThanOrEqual(grouping.maxX, 300)
        XCTAssertEqual(grouping.maxX, 300 - 12, accuracy: 1)

        let full = (long as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width.rounded(.up)
        XCTAssertFalse(FilterSummary.isCut(long, shownWidth: full, k: 1), "all of it shows")
        XCTAssertTrue(FilterSummary.isCut(long, shownWidth: full - 40, k: 1), "cut with …")
        XCTAssertFalse(FilterSummary.isCut(long, shownWidth: 0, k: 1), "not laid out yet")
        XCTAssertTrue(FilterSummary.isCut(long, shownWidth: full, k: 1.5), "a larger text size needs more room")
        XCTAssertEqual(FilterText.reset, "Reset")
        XCTAssertEqual(FilterButton.dotTip, "Unread pull requests are hidden by the filter")
    }

    /// The `Filter` tab's icon is the board's drawn one, as large as
    /// `Grouping…`'s, and the tab is as tall as the row (26 points at text
    /// size 12), open or closed, with the same width, so the summary does
    /// not move.
    func testTheFilterTab() {
        XCTAssertEqual(FilterButton.icon, BoardIcons.filter)
        XCTAssertEqual(FilterButton.iconSize, DrawnButton.iconSize)
        XCTAssertEqual(BoardIcons.filter.lineWidth, BoardIcons.grouping.lineWidth)
        for k: CGFloat in [0.75, 1, 1.5] {
            let open = NSHostingView(rootView: FilterButton(open: true, dot: false, toggle: {}).environment(\.textScale, k)).fittingSize
            let closed = NSHostingView(rootView: FilterButton(open: false, dot: false, toggle: {}).environment(\.textScale, k)).fittingSize
            XCTAssertEqual(open.height, 26 * k, accuracy: 0.5, "k \(k)")
            XCTAssertEqual(open, closed, "k \(k): the same place open or closed")
        }
        // Open, the row gives up its room under it: the tab reaches the box.
        let openRow = NSHostingView(rootView: FilterRow(value: FilterRowState(shows: true, open: true, dot: false, summary: nil, showsGrouping: false),
                                                        toggle: {}, openGrouping: {}).environment(\.textScale, 1)).fittingSize
        let closedRow = NSHostingView(rootView: FilterRow(value: FilterRowState(shows: true, open: false, dot: false, summary: nil, showsGrouping: false),
                                                          toggle: {}, openGrouping: {}).environment(\.textScale, 1)).fittingSize
        XCTAssertEqual(openRow.height, 26, accuracy: 0.5)
        XCTAssertEqual(closedRow.height, 32, accuracy: 0.5)
    }

    /// `Grouping…` has no border and no ground: only its icon and its text
    /// in the secondary color are drawn.
    func testGroupingHasNoBorderAndNoGround() throws {
        for dark in [false, true] {
            let button = DrawnButton(title: GroupingButton.title)
            button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
            button.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let rep = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / button.bounds.width
            // The corners and the edges' middles are empty (no border, no
            // ground); the icon and the text are drawn.
            for (x, y) in [(0, 0), (rep.pixelsWide - 1, 0), (0, rep.pixelsHigh - 1), (rep.pixelsWide / 2, 0), (rep.pixelsWide / 2, rep.pixelsHigh - 1)] {
                XCTAssertEqual(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0, 0, accuracy: 0.01, "dark \(dark) (\(x), \(y))")
            }
            let icon = button.iconFrame
            let inked = (Int(icon.minX * scale)..<Int(icon.maxX * scale)).contains { x in
                (rep.colorAt(x: x, y: Int(icon.midY * scale))?.alphaComponent ?? 0) > 0.2
            }
            XCTAssertTrue(inked, "dark \(dark): the icon")
            XCTAssertEqual(DrawnButton.icon, BoardIcons.grouping)
        }
    }

    /// The display mode switch (DESIGN.md, "Compact"): two segments,
    /// `Detailed` at the left and `Compact` at the right with the board's
    /// glyphs (Main.html); the rest of the switch is in TabRowTests.
    func testTheDisplayModes() {
        XCTAssertEqual(DisplayMode.allCases.map(\.title), ["Detailed", "Compact"])
        XCTAssertEqual(DisplayMode.detailed.rawValue, 0)
        XCTAssertEqual(DisplayMode.detailed.icon, BoardIcons.compactOff)
        XCTAssertEqual(DisplayMode.compact.icon, BoardIcons.compactOn)
        XCTAssertNotEqual(BoardIcons.compactOff, BoardIcons.compactOn)
    }
}

/// Lays a view out at a width in a window that is never shown.
@MainActor
enum Probe {
    static func host<V: View>(_ view: V, width: CGFloat) -> NSHostingView<some View> {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 80), styleMask: [.borderless], backing: .buffered, defer: true)
        let hosting = NSHostingView(rootView: view.frame(width: width))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 80)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    static func walk(_ view: NSView, _ visit: (NSView) -> Void) {
        visit(view)
        view.subviews.forEach { walk($0, visit) }
    }
}

/// The search row, and the search field (an NSTextField) in it.
@MainActor
enum SearchRowProbe {
    struct Host: View {
        var k: CGFloat
        @FocusState var focused: Bool
        @State var text = ""

        init(k: CGFloat, text: String = "") {
            self.k = k
            _text = State(initialValue: text)
        }

        var body: some View {
            SearchRowContent(search: $text, focused: $focused).environment(\.textScale, k)
        }
    }

    static func field(k: CGFloat, width: CGFloat, text: String = "") -> NSRect? {
        let hosting = Probe.host(Host(k: k, text: text), width: width)
        var field: NSRect?
        Probe.walk(hosting) { view in
            if let text = view as? NSTextField, text.isEditable { field = text.convert(text.bounds, to: hosting) }
        }
        return field
    }
}

/// The Filter row, and `Grouping…` and any options' box in it.
@MainActor
enum FilterRowProbe {
    static func buttons(_ value: FilterRowState, k: CGFloat, width: CGFloat) -> (reset: NSRect?, grouping: NSRect?) {
        let row = FilterRow(value: value, toggle: {}, openGrouping: {}).environment(\.textScale, k)
        let hosting = Probe.host(row, width: width)
        var reset: NSRect?
        var grouping: NSRect?
        Probe.walk(hosting) { view in
            if let button = view as? DrawnButton, button.title == GroupingButton.title {
                grouping = button.convert(button.bounds, to: hosting)
            }
            if let options = view as? FilterOptionsView { reset = options.convert(options.geometry.reset.frame, to: hosting) }
        }
        return (reset, grouping)
    }
}
