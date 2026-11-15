// The window moves by its header and its title strip (DESIGN.md, "Open in
// window"), also by the press that brings it forward.

import AppKit
@testable import ShiibarGhApp
import XCTest

@MainActor
final class WindowDragTests: XCTestCase {
    func testTheDragAreaMovesTheWindowFromTheFirstPress() {
        let view = WindowDragView(frame: NSRect(x: 10, y: 20, width: 100, height: 40))
        XCTAssertTrue(view.mouseDownCanMoveWindow)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil), "a window out of focus moves too")
    }

    func testTheDragAreaTakesPressesInsideItOnly() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let view = WindowDragView(frame: NSRect(x: 10, y: 20, width: 100, height: 40))
        parent.addSubview(view)
        XCTAssertTrue(view.hitTest(NSPoint(x: 50, y: 30)) === view)
        XCTAssertNil(view.hitTest(NSPoint(x: 200, y: 30)))
    }
}

/// The measurement and demo modes keep their UI state in memory.
@MainActor
final class ScratchDefaultsTests: XCTestCase {
    func testValuesStayInMemory() {
        let defaults = ScratchDefaults()
        defaults.set(true, forKey: "v4.compact.1")
        defaults.set(["a"], forKey: "v4.expanded.1")
        defaults.set(712.0, forKey: "v4.popover.height.1")
        XCTAssertEqual(defaults.object(forKey: "v4.compact.1") as? Bool, true)
        XCTAssertEqual(defaults.stringArray(forKey: "v4.expanded.1"), ["a"])
        XCTAssertEqual(defaults.object(forKey: "v4.popover.height.1") as? Double, 712)
        XCTAssertNil(ScratchDefaults().object(forKey: "v4.compact.1"), "a new one starts empty")
    }
}

/// The three status icons of a card: every look draws something, the None
/// dash too (a non-finished card's three slots are never empty).
@MainActor
final class StatusIconTests: XCTestCase {
    func drawnPixels(_ look: StatusLook) -> Int {
        let size = 28
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        Shapes.status(look, in: CGRect(x: 0, y: 0, width: 14, height: 14), k: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        return (0..<(size * size)).filter { bytes[$0 * 4 + 3] > 0 }.count
    }

    func testEveryLookDrawsAndNoneIsTheSmallest() {
        let ok = drawnPixels(.ok)
        let bad = drawnPixels(.bad)
        let waiting = drawnPixels(.waiting)
        let none = drawnPixels(.empty)
        XCTAssertGreaterThan(ok, 0)
        XCTAssertGreaterThan(bad, 0)
        XCTAssertGreaterThan(waiting, 0, "the clock")
        XCTAssertGreaterThan(none, 0, "the dash: the slot is not empty")
        XCTAssertLessThan(none, waiting, "a short dash, smaller than the clock")
    }
}
