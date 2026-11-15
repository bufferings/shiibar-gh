// The controls of the Filter's options and `Grouping…` never take the
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
        let grouping = NoFocusButton(title: GroupingButton.title, target: nil, action: nil)
        grouping.refusesFirstResponder = true
        return [checkbox, segmented, grouping]
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

    /// The search field is 200 points wide at text size 12 (and scales with
    /// it): the same in every tab, with no summary or a long one, with
    /// `Grouping…` or without, and while the Dismissed list shows (only the
    /// search field then). `Filter` and `Grouping…` sit to its right;
    /// `Grouping…` at the right end.
    func testTheSearchFieldWidthIsFixed() {
        let long = "Open · Draft · Merged · Muted only · Unread only"
        func state(_ tab: ListTab, summary: String?, dismissed: Bool = false) -> OperationRowState {
            OperationRowState(
                search: "", tab: tab, showingDismissed: dismissed, focused: false, filterOpen: false, summary: dismissed ? nil : summary,
                dot: false, showsGrouping: tab == .all && !dismissed
            )
        }
        let states = [
            state(.all, summary: nil), state(.all, summary: long), state(.all, summary: "Unread only"),
            state(.review, summary: nil), state(.review, summary: long), state(.mine, summary: "Muted shown"),
            state(.review, summary: long, dismissed: true),
        ]
        for k: CGFloat in [1, 1.5] {
            var widths: [CGFloat] = []
            for value in states {
                let frames = OperationRowProbe.frames(value, k: k)
                guard let field = frames.field else { return XCTFail("no search field") }
                widths.append(field.width)
                XCTAssertLessThan(field.maxX, 12 + 200 * k + 0.5, "inside its 200 points")
                if let grouping = frames.grouping {
                    XCTAssertTrue(value.showsGrouping)
                    XCTAssertEqual(grouping.maxX, 460 * k - 12, accuracy: 1, "at the right end")
                    XCTAssertGreaterThan(grouping.minX, field.maxX)
                } else {
                    XCTAssertFalse(value.showsGrouping)
                }
            }
            XCTAssertGreaterThan(widths[0], 150 * k, "most of the 200 points")
            XCTAssertTrue(widths.allSatisfy { abs($0 - widths[0]) < 0.5 }, "k \(k): \(widths)")
        }
        // The narrowest window (300 points): everything stays inside, the
        // search field gives way.
        let narrow = OperationRowProbe.frames(state(.all, summary: long), k: 1, width: 300)
        XCTAssertEqual(narrow.grouping?.maxX ?? 0, 300 - 12, accuracy: 1)
        XCTAssertGreaterThan(narrow.field?.width ?? 0, 40)
        XCTAssertGreaterThanOrEqual(narrow.field?.minX ?? -1, 12)
    }

    /// The summary's tooltip only while it is cut short.
    func testTheSummaryTooltipOnlyWhenCut() {
        let summary = "Open · Draft · Merged · Muted only · Unread only"
        let full = (summary as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width.rounded(.up)
        XCTAssertFalse(FilterButton.isCut(summary, shownWidth: full, k: 1), "all of it shows")
        XCTAssertTrue(FilterButton.isCut(summary, shownWidth: full - 40, k: 1), "cut with …")
        XCTAssertFalse(FilterButton.isCut(summary, shownWidth: 0, k: 1), "not laid out yet")
        XCTAssertTrue(FilterButton.isCut(summary, shownWidth: full, k: 1.5), "a larger text size needs more room")
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

/// Lays the operation row out at the popover's width (460 points at text
/// size 12, scaled with it), in a window that is
/// never shown, and finds the search field (an NSTextField) and
/// `Grouping…` (a NoFocusButton) in it.
@MainActor
enum OperationRowProbe {
    struct Host: View {
        var value: OperationRowState
        var k: CGFloat
        var width: CGFloat
        @FocusState var focused: Bool
        @State var text = ""

        var body: some View {
            OperationRowContent(value: value, search: $text, focused: $focused, toggleFilter: {}, openGrouping: {})
                .environment(\.textScale, k)
                .frame(width: width)
        }
    }

    static func frames(_ value: OperationRowState, k: CGFloat, width: CGFloat? = nil) -> (field: NSRect?, grouping: NSRect?) {
        let width = width ?? 460 * k
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 80), styleMask: [.borderless], backing: .buffered, defer: true)
        let hosting = NSHostingView(rootView: Host(value: value, k: k, width: width))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 80)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        var field: NSRect?
        var grouping: NSRect?
        func walk(_ view: NSView) {
            if let text = view as? NSTextField, text.isEditable { field = text.convert(text.bounds, to: hosting) }
            if let button = view as? NoFocusButton { grouping = button.convert(button.bounds, to: hosting) }
            view.subviews.forEach(walk)
        }
        walk(hosting)
        return (field, grouping)
    }
}
