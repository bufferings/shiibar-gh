import AppKit
@testable import ShiibarGhCore
import SwiftUI
import XCTest

@MainActor
final class AppearanceRenderTests: XCTestCase {
    func testTheSettingDecidesAndSystemFollowsTheMac() {
        let cases: [(AppAppearance, Bool, Bool)] = [
            (.system, false, false), (.system, true, true),
            (.light, true, false), (.light, false, false),
            (.dark, false, true), (.dark, true, true),
        ]
        for (setting, system, dark) in cases {
            XCTAssertEqual(SurfaceAppearance.isDark(setting: setting, systemDark: system), dark, "\(setting) \(system)")
        }
        XCTAssertEqual(SurfaceAppearance.named(dark: true), .darkAqua)
        XCTAssertEqual(SurfaceAppearance.named(dark: false), .aqua)
    }

    /// The palette colors drawn by SwiftUI take the appearance of the view
    /// that hosts them, so setting it on a surface turns its content dark.
    func testAHostedViewDrawsThePaletteForItsAppearance() throws {
        for dark in [false, true] {
            let view = NSHostingView(rootView: Rectangle().fill(Palette.background.color).frame(width: 20, height: 20))
            view.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            view.appearance = NSAppearance(named: SurfaceAppearance.named(dark: dark))
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let pixel = try XCTUnwrap(rep.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
            let want = Palette.background.resolve(dark: dark)
            XCTAssertEqual(pixel.redComponent, want.red, accuracy: 0.03, "dark=\(dark)")
            XCTAssertEqual(pixel.greenComponent, want.green, accuracy: 0.03, "dark=\(dark)")
            XCTAssertEqual(pixel.blueComponent, want.blue, accuracy: 0.03, "dark=\(dark)")
        }
    }
}
