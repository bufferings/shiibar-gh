import AppKit
@testable import ShiibarGhCore
import SwiftUI
import XCTest

@MainActor
final class MenuButtonTests: XCTestCase {
    /// Pixels that differ from the background in a 40 by 40 rendering.
    func inked(_ view: some View, dark: Bool) -> Int {
        let background = Palette.background
        let host = NSHostingView(rootView: view.frame(width: 40, height: 40).background(background.color))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        host.appearance = NSAppearance(named: SurfaceAppearance.named(dark: dark))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        let base = background.resolve(dark: dark)
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - base.red) + abs(c.greenComponent - base.green) + abs(c.blueComponent - base.blue) > 0.15 {
                    count += 1
                }
            }
        }
        return count
    }

    func testTheChevronButtonIsDrawnInLightAndDark() {
        let button = MenuIconButton(icon: BoardIcons.chevron, label: "More", items: [])
        for dark in [false, true] {
            XCTAssertGreaterThan(inked(button, dark: dark), 10, "dark=\(dark)")
        }
    }

    func testTheMenuRunsTheChosenItem() {
        var ran: [String] = []
        let menu = IconMenu.make([
            IconMenuItem("About shiibar-gh") { ran.append("about") },
            nil,
            IconMenuItem("Quit shiibar-gh") { ran.append("quit") },
        ])
        XCTAssertEqual(menu.items.map(\.title), ["About shiibar-gh", "", "Quit shiibar-gh"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        menu.performActionForItem(at: 2)
        XCTAssertEqual(ran, ["quit"])
    }
}
