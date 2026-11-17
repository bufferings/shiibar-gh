import AppKit
@testable import ShiibarGhCore
import XCTest

/// The menu bar image drawn into a bitmap for the light and the dark menu
/// bar: the glyph takes the account's system color resolved for that
/// appearance, None takes black or white, the dot takes the accent color it
/// is given, and the marks are cut out of the glyph.
@MainActor
final class MenuBarImageTests: XCTestCase {
    func render(_ image: NSImage, dark: Bool) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 52, pixelsHigh: 44, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = NSSize(width: MenuBarImage.width, height: MenuBarImage.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: MenuBarImage.width, height: MenuBarImage.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The opaque pixels' colors in sRGB.
    func inks(_ rep: NSBitmapImageRep) -> [NSColor] {
        var out: [NSColor] = []
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.95, let s = c.usingColorSpace(.sRGB) { out.append(s) }
            }
        }
        return out
    }

    func close(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < 0.12
    }

    func resolved(_ color: NSColor, dark: Bool) -> NSColor {
        var out = color
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB)!
        }
        return out
    }

    func testTheGlyphTakesTheSystemColorOfTheAppearance() throws {
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let image = MenuBarImage.make(color: .red, marks: MenuBarMarks(dot: false, triangle: false), appearance: appearance)
            XCTAssertFalse(image.isTemplate, "a template would lose the tint")
            let inks = inks(try render(image, dark: dark))
            XCTAssertGreaterThan(inks.count, 20)
            let red = resolved(.systemRed, dark: dark)
            XCTAssertTrue(inks.allSatisfy { close($0, red) }, "dark=\(dark)")
        }
    }

    func testNoneIsBlackInLightAndWhiteInDark() throws {
        for dark in [false, true] {
            let image = MenuBarImage.make(color: .none, marks: MenuBarMarks(dot: false, triangle: false), appearance: NSAppearance(named: dark ? .darkAqua : .aqua)!)
            let want: NSColor = dark ? .white : .black
            let inks = inks(try render(image, dark: dark))
            XCTAssertGreaterThan(inks.count, 20)
            XCTAssertTrue(inks.allSatisfy { close($0, want.usingColorSpace(.sRGB)!) }, "dark=\(dark)")
        }
    }

    func testTheMarksAreDrawn() throws {
        let appearance = NSAppearance(named: .aqua)!
        let plain = inks(try render(MenuBarImage.make(color: .blue, marks: MenuBarMarks(dot: false, triangle: false), appearance: appearance), dark: false))
        let marked = inks(try render(MenuBarImage.make(color: .blue, marks: MenuBarMarks(dot: true, triangle: true), appearance: appearance), dark: false))
        let dot = Palette.accent.resolved(dark: false)
        XCTAssertFalse(plain.contains { close($0, dot) && !close($0, resolved(.systemBlue, dark: false)) })
        XCTAssertFalse(marked.contains { close($0, .black.usingColorSpace(.sRGB)!) }, "no number in the menu bar text color")
        XCTAssertGreaterThan(marked.count, plain.count, "the dot and the triangle add ink")
    }

    /// The dot is drawn in the accent color the image is made with (the
    /// status item's look keeps the same color).
    func testTheDotTakesTheAccentColorGiven() throws {
        let appearance = NSAppearance(named: .aqua)!
        let purple = NSColor(srgbRed: 0.584, green: 0.239, blue: 0.588, alpha: 1)
        let orange = NSColor(srgbRed: 0.969, green: 0.510, blue: 0.106, alpha: 1)
        for dot in [purple, orange] {
            let image = MenuBarImage.make(color: .none, marks: MenuBarMarks(dot: true, triangle: false), appearance: appearance, dot: dot)
            let inks = inks(try render(image, dark: false))
            XCTAssertGreaterThan(inks.filter { close($0, dot) }.count, 10, "\(dot)")
        }
        XCTAssertEqual(MenuBarImage.components(purple).count, 4)
    }
}
