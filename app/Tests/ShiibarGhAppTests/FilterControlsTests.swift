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
    func controls() -> [NSControl] {
        let checkbox = NoFocusCheckbox(checkboxWithTitle: "Unread only", target: nil, action: nil)
        checkbox.refusesFirstResponder = true
        let segmented = NoFocusSegmentedControl(labels: ["Hide", "Show", "Only"], trackingMode: .selectOne, target: nil, action: nil)
        segmented.refusesFirstResponder = true
        let grouping = NoFocusButton(title: PushButton.grouping, target: nil, action: nil)
        grouping.refusesFirstResponder = true
        let reset = NoFocusButton(title: PushButton.reset, target: nil, action: nil)
        reset.refusesFirstResponder = true
        return [checkbox, segmented, grouping, reset]
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
        let items = GroupingSheet.sortItems(ListOptions(sort: .recentlyUpdated)) { chosen.append($0) }.compactMap { $0 }
        XCTAssertEqual(items.map(\.title), ["Recently updated", "Recently added"])
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
            // A push button's frame is wider than what it draws by a margin
            // that depends on the macOS version (up to 7 points), so the
            // edges are compared loosely.
            XCTAssertEqual(grouping.maxX, width - 12, accuracy: 8, "Grouping… at the right end")
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
        XCTAssertEqual(grouping.maxX, 300 - 12, accuracy: 8)

        let full = (long as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width.rounded(.up)
        XCTAssertFalse(FilterSummary.isCut(long, shownWidth: full, k: 1), "all of it shows")
        XCTAssertTrue(FilterSummary.isCut(long, shownWidth: full - 40, k: 1), "cut with …")
        XCTAssertFalse(FilterSummary.isCut(long, shownWidth: 0, k: 1), "not laid out yet")
        XCTAssertTrue(FilterSummary.isCut(long, shownWidth: full, k: 1.5), "a larger text size needs more room")
        XCTAssertEqual(PushButton.reset, "Reset")
        XCTAssertEqual(FilterButton.dotTip, "Unread pull requests are hidden by the filter")
    }

    /// The display mode switch (DESIGN.md, "Compact"): two segments,
    /// `Detailed` at the left and `Compact` at the right with the board's
    /// glyphs (candidate A), their names as tooltips; the current mode is
    /// the selected segment; pressing the other switches, the current one
    /// does nothing. Never the first responder.
    func testTheDisplayModeSwitch() {
        XCTAssertEqual(DisplayMode.allCases.map(\.title), ["Detailed", "Compact"])
        XCTAssertEqual(DisplayMode.detailed.rawValue, 0)
        XCTAssertEqual(DisplayMode.detailed.icon, BoardIcons.compactOff)
        XCTAssertEqual(DisplayMode.compact.icon, BoardIcons.compactOn)
        XCTAssertNotEqual(BoardIcons.compactOff, BoardIcons.compactOn)
        XCTAssertTrue(DisplayMode.compact.image(size: 14).isTemplate)

        var chosen: [DisplayMode] = []
        let coordinator = DisplayModeSwitch.Coordinator()
        coordinator.choose = { chosen.append($0) }
        coordinator.mode = .detailed
        let control = ModeSegmentedControl()
        control.segmentCount = 2
        control.trackingMode = .selectOne
        control.frame = NSRect(x: 0, y: 0, width: 52, height: 22)
        control.selectedSegment = 1
        coordinator.pressed(control)
        XCTAssertEqual(chosen, [.compact], "the other segment switches")
        XCTAssertEqual(control.selectedSegment, 0, "the model decides what shows")
        coordinator.mode = .compact
        control.selectedSegment = 1
        coordinator.pressed(control)
        XCTAssertEqual(chosen, [.compact], "the current mode: nothing")
        XCTAssertEqual(control.segment(at: NSPoint(x: 5, y: 10)), 0, "Detailed at the left: its tooltip")
        XCTAssertEqual(control.segment(at: NSPoint(x: 47, y: 10)), 1)
        XCTAssertNil(control.segment(at: NSPoint(x: 80, y: 10)))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(control)
        XCTAssertFalse(control.acceptsFirstResponder)
        window.makeFirstResponder(control)
        XCTAssertFalse(window.firstResponder === control)
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

        var body: some View {
            SearchRowContent(search: $text, focused: $focused).environment(\.textScale, k)
        }
    }

    static func field(k: CGFloat, width: CGFloat) -> NSRect? {
        let hosting = Probe.host(Host(k: k), width: width)
        var field: NSRect?
        Probe.walk(hosting) { view in
            if let text = view as? NSTextField, text.isEditable { field = text.convert(text.bounds, to: hosting) }
        }
        return field
    }
}

/// The Filter row, and `Reset` and `Grouping…` (NoFocusButtons) in it.
@MainActor
enum FilterRowProbe {
    static func buttons(_ value: FilterRowState, k: CGFloat, width: CGFloat) -> (reset: NSRect?, grouping: NSRect?) {
        let row = FilterRow(value: value, toggle: {}, openGrouping: {}).environment(\.textScale, k)
        let hosting = Probe.host(row, width: width)
        var reset: NSRect?
        var grouping: NSRect?
        Probe.walk(hosting) { view in
            guard let button = view as? NoFocusButton else { return }
            let frame = button.convert(button.bounds, to: hosting)
            if button.title == PushButton.reset { reset = frame }
            if button.title == PushButton.grouping { grouping = frame }
        }
        return (reset, grouping)
    }
}
