// The tab row at every text size (DESIGN.md, "Screens", "Compact",
// "Constants"): the display mode switch scales as a whole with the text,
// and the switch, the Dismissed icon and its count sit centered on the tab
// names' line. Drawn offscreen; no daemon (the socket path names nothing).

import AppKit
@testable import ShiibarGhApp
@testable import ShiibarGhCore
import SwiftUI
import XCTest

@MainActor
final class TabRowTests: XCTestCase {
    final class NoOpener: URLOpening { func open(_ url: URL) {} }
    final class NoNotifier: NotificationPresenting {
        func requestAuthorization() {}
        func present(_ notification: DaemonNotification) {}
    }

    /// The models live as long as the process, as in the app.
    static var kept: [AnyObject] = []

    func list() -> SurfaceListModel {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("no-daemon-\(UUID().uuidString).sock").path
        let app = AppModel(
            api: SocketDaemonAPI(socketPath: socket), store: UIStateStore(defaults: ScratchDefaults()), opener: NoOpener(),
            notifier: NoNotifier()
        )
        let data = app.viewModel("1001")
        let list = data.list(.popover)
        Self.kept += [app, data, list]
        return list
    }

    struct Measure {
        var image: NSBitmapImageRep
        /// Points (the row's top-left origin) of the switch, the Dismissed
        /// icon's square and the count's ink, the tab names' ink.
        var switchFrame: CGRect
        var icon: CGRect
        var count: CGRect
        var tabName: CGRect
        /// Ink boxes in points: Detailed, Compact and Dismissed glyphs.
        var glyphs: [CGRect]
    }

    /// `dark`: the image only, in the dark appearance.
    func measure(k: CGFloat, dark: Bool = false) throws -> Measure {
        let state = Derived<TabRowState>([]) {
            TabRowState(tab: .review, showingDismissed: false, counts: [.all: 6, .review: 4, .mine: 2], compact: false, dismissedCount: 12)
        }
        let width: CGFloat = 460 * k
        let row = TabRow(list: list(), state: state).environment(\.textScale, k).frame(width: width)
            .background(dark ? Palette.background.color : Color.white)
        let host = NSHostingView(rootView: row)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let fitting = host.fittingSize
        host.frame = NSRect(origin: .zero, size: CGSize(width: width, height: fitting.height))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var switchView: ModeSwitchView?
        Probe.walk(host) { if let view = $0 as? ModeSwitchView { switchView = view } }
        let control = try XCTUnwrap(switchView)
        var frame = control.convert(control.bounds, to: host)
        if !host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if dark { return Measure(image: rep, switchFrame: frame, icon: .zero, count: .zero, tabName: .zero, glyphs: []) }
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        func ink(_ region: CGRect) -> CGRect? {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            let x0 = max(0, Int(region.minX * scale)), x1 = min(rep.pixelsWide, Int(region.maxX * scale))
            let y0 = max(0, Int(region.minY * scale)), y1 = min(rep.pixelsHigh, Int(region.maxY * scale))
            guard x0 < x1, y0 < y1 else { return nil }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    // Composited on white: a pixel nothing was drawn on is clear.
                    let mean = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                    let l = mean * c.alphaComponent + (1 - c.alphaComponent)
                    if l < 0.62 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
                }
            }
            guard maxX >= 0 else { return nil }
            return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                          width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        }
        let layout = ModeSwitchLayout(k: k)
        func inner(_ mode: DisplayMode) -> CGRect {
            layout.frame(mode).offsetBy(dx: frame.minX, dy: frame.minY).insetBy(dx: 2 * k, dy: 2 * k)
        }
        let right = CGRect(x: frame.maxX + 1, y: 0, width: width - frame.maxX - 1, height: host.bounds.height - 2)
        let dismissed = try XCTUnwrap(ink(right))
        // The icon is the first 14·k points of the Dismissed ink; the count
        // the rest.
        let iconInk = try XCTUnwrap(ink(CGRect(x: dismissed.minX, y: 0, width: 14 * k, height: host.bounds.height - 2)))
        let countInk = try XCTUnwrap(ink(CGRect(x: dismissed.minX + 14 * k + 1, y: 0, width: width, height: host.bounds.height - 2)))
        // The icon's square: 14·k centered on its ink horizontally; its
        // glyph is placed in the square as the board places it (y 2.8 to
        // 13 of 16), so the square's top is the ink's top less 2.8/16.
        let unit = 14 * k / 16
        let square = CGRect(x: iconInk.minX - 1.8 * unit + 0.7 * unit, y: iconInk.minY - 2.8 * unit + 0.7 * unit, width: 14 * k, height: 14 * k)
        let tabName = try XCTUnwrap(ink(CGRect(x: 0, y: 0, width: 50 * k, height: host.bounds.height - 4)))
        return Measure(
            image: rep, switchFrame: frame, icon: square, count: countInk, tabName: tabName,
            glyphs: [try XCTUnwrap(ink(inner(.detailed))), try XCTUnwrap(ink(inner(.compact))), iconInk]
        )
    }

    func testTheSwitchScalesAsAWholeAndTheRowSharesOneLine() throws {
        var lines: [String] = []
        for k in [CGFloat(0.75), 1, 1.25, 1.5] {
            let m = try measure(k: k)
            let layout = ModeSwitchLayout(k: k)
            XCTAssertEqual(m.switchFrame.size.width, layout.size.width, accuracy: 0.01)
            XCTAssertEqual(m.switchFrame.size.height, 20 * k, accuracy: 0.01, "the switch grows with the text")
            // The icon keeps its proportion to the bezel.
            XCTAssertEqual(layout.icon / layout.size.height, 0.7, accuracy: 0.0001)
            XCTAssertEqual(m.glyphs[0].height / m.switchFrame.height, 13.4 * (14.0 / 16) / 20, accuracy: 0.06, "Detailed")
            // The switch, the Dismissed icon and the count on one line.
            XCTAssertEqual(m.switchFrame.midY, m.icon.midY, accuracy: 0.5, "k \(k)")
            XCTAssertEqual(m.switchFrame.midY, m.count.midY, accuracy: 0.5, "k \(k)")
            lines.append(String(
                format: "k %.2f switch %@ (mid %.2f) icon square mid %.2f, count ink %@ (mid %.2f), tab name ink %@ (mid %.2f); ink Detailed %.2fx%.2f Compact %.2fx%.2f Dismissed %.2fx%.2f; icon/control %.3f",
                k, NSStringFromRect(m.switchFrame), m.switchFrame.midY, m.icon.midY, NSStringFromRect(m.count), m.count.midY,
                NSStringFromRect(m.tabName), m.tabName.midY,
                m.glyphs[0].width, m.glyphs[0].height, m.glyphs[1].width, m.glyphs[1].height, m.glyphs[2].width, m.glyphs[2].height,
                layout.icon / m.switchFrame.height
            ))
            if let out = ProcessInfo.processInfo.environment["TAB_ROW_OUT"] {
                try? m.image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/tab-row-k\(k).png"))
                try? measure(k: k, dark: true).image.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: out + "/tab-row-k\(k)-dark.png"))
                try? lines.joined(separator: "\n").write(toFile: out + "/tab-row.txt", atomically: true, encoding: .utf8)
            }
        }
    }

    /// The switch's values: the sizes by text scale, the segment under a
    /// point, the other segment switches and the current one does nothing,
    /// what assistive apps read, and no keyboard focus.
    func testTheSwitchValues() {
        let one = ModeSwitchLayout(k: 1)
        XCTAssertEqual(one.size, CGSize(width: 51, height: 20), "the board's two 26 × 20 segments, one border shared")
        XCTAssertEqual(one.icon, 14)
        XCTAssertEqual(one.frame(.compact), CGRect(x: 25, y: 0, width: 26, height: 20))
        XCTAssertEqual(ModeSwitchLayout(k: 1.5).size, CGSize(width: 77, height: 30))
        XCTAssertEqual(ModeSwitchLayout(k: 1.5).iconFrame(.detailed), CGRect(x: 9, y: 4.5, width: 21, height: 21))
        XCTAssertEqual(one.mode(at: CGPoint(x: 5, y: 10)), .detailed, "Detailed at the left: its tooltip")
        XCTAssertEqual(one.mode(at: CGPoint(x: 47, y: 10)), .compact)
        XCTAssertNil(one.mode(at: CGPoint(x: 80, y: 10)))

        let view = ModeSwitchView(frame: NSRect(x: 0, y: 0, width: 51, height: 20))
        var chosen: [DisplayMode] = []
        view.choose = { chosen.append($0) }
        view.press(.compact)
        XCTAssertEqual(chosen, [.compact], "the other segment switches")
        XCTAssertEqual(view.mode, .detailed, "the model decides what shows")
        view.mode = .compact
        view.press(.compact)
        XCTAssertEqual(chosen, [.compact], "the current mode: nothing")
        view.layout = ModeSwitchLayout(k: 1.25)
        XCTAssertEqual(view.intrinsicContentSize, ModeSwitchLayout(k: 1.25).size)

        XCTAssertEqual(view.accessibilityRole(), .radioGroup)
        XCTAssertEqual(view.accessibilityLabel(), "Display mode")
        XCTAssertEqual(view.accessibilityValue() as? String, "Compact")
        let segments = (view.accessibilityChildren() ?? []).compactMap { $0 as? ModeSegmentElement }
        XCTAssertEqual(segments.map(\.mode), [.detailed, .compact])
        XCTAssertEqual(segments.map { $0.accessibilityRole() }, [.radioButton, .radioButton])
        XCTAssertEqual(segments.map { $0.accessibilityLabel() }, ["Detailed", "Compact"])
        XCTAssertEqual(segments.map { $0.accessibilityValue() as? Int }, [0, 1])
        XCTAssertTrue(segments[0].accessibilityPerformPress())
        XCTAssertEqual(chosen, [.compact, .detailed], "pressing a segment switches")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(view)
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertFalse(view.canBecomeKeyView)
        window.makeFirstResponder(view)
        XCTAssertFalse(window.firstResponder === view)
    }
}
