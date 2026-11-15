// The controls of the Filter's options never take the keyboard focus
// (DESIGN.md, "Filter": they are for the mouse, so the keys keep working on
// the list and the search field). A window that is never shown: a control
// asked to become the first responder refuses, and Tab (the key view loop,
// which Full Keyboard Access walks) never reaches one. A text field in the
// same window does take the focus, so the window does pass it on.

import AppKit
@testable import ShiibarGhApp
import ShiibarGhCore
import XCTest

@MainActor
final class FilterControlsTests: XCTestCase {
    func controls() -> [NSControl] {
        let checkbox = NoFocusCheckbox(checkboxWithTitle: "Unread only", target: nil, action: nil)
        checkbox.refusesFirstResponder = true
        let segmented = NoFocusSegmentedControl(labels: ["Hide", "Show", "Only"], trackingMode: .selectOne, target: nil, action: nil)
        segmented.refusesFirstResponder = true
        let popUp = TipPopUpButton(frame: .zero, pullsDown: true)
        popUp.refusesFocus = true
        popUp.addItem(withTitle: "Repository")
        return [checkbox, segmented, popUp]
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

    /// The Grouping sheet's pop-ups take the focus as in 0.5; the same
    /// button in the Filter's options does not (DESIGN.md, "Filter").
    func testTheGroupingSheetPopUpsTakeTheFocus() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        let sheet = TipPopUpButton(frame: NSRect(x: 10, y: 10, width: 150, height: 24), pullsDown: true)
        sheet.addItem(withTitle: "Repository")
        let options = TipPopUpButton(frame: NSRect(x: 10, y: 50, width: 150, height: 24), pullsDown: true)
        options.addItem(withTitle: "Repository")
        options.refusesFocus = true
        window.contentView?.addSubview(sheet)
        window.contentView?.addSubview(options)
        XCTAssertFalse(sheet.refusesFocus, "the default: the sheet's")
        XCTAssertFalse(sheet.refusesFirstResponder)
        window.makeFirstResponder(sheet)
        XCTAssertTrue(window.firstResponder === sheet, "the sheet's pop-up takes the focus")
        window.makeFirstResponder(options)
        XCTAssertFalse(window.firstResponder === options, "the options' pop-up does not")
        XCTAssertFalse(options.acceptsFirstResponder)
        XCTAssertFalse(options.canBecomeKeyView)
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
