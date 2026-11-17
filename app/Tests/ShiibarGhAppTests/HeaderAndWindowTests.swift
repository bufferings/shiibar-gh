// The header and the window's shape (DESIGN.md, "Screens", "Open in window",
// "Account color", "UI"): the band with the account's mark and name, the row
// with Refresh, Open in window (the pin in the window), Settings and ⌄ in
// that order; the window's standard title bar with the mark and the name as
// its title. No window is shown.

import AppKit
@testable import ShiibarGhApp
@testable import ShiibarGhCore
import SwiftUI
import XCTest

@MainActor
final class HeaderAndWindowTests: XCTestCase {
    func header(_ surface: Surface) -> Header {
        var actions = SurfaceActions(openWindow: {}, openSettings: { _ in }, about: {}, quit: {})
        if surface == .window { actions.openWindow = nil }
        return Header(
            login: "example-user", color: .red, updated: "Updated 1 min ago", usage: ApiUsage(nil), keepOnTop: true,
            toggleKeepOnTop: {}, surface: surface, refreshing: false, actions: actions, refresh: {}
        )
    }

    func testTheButtonsOfThePopoverAndTheWindow() {
        XCTAssertEqual(Header.buttons(surface: .popover, canOpenWindow: true), [.refresh, .openWindow, .settings, .more])
        XCTAssertEqual(Header.buttons(surface: .window, canOpenWindow: false), [.refresh, .pin, .settings, .more])
        XCTAssertEqual(Header.refreshHelp, "Refresh (\u{2318}R)")
        // The header lays them out without trouble at both widths.
        _ = Probe.host(header(.popover), width: 460)
        _ = Probe.host(header(.window), width: 300)
    }

    /// The window: the standard title bar with its three buttons, the
    /// account's login as `title`, the green button zooming instead of
    /// going full screen, the content starting under the title bar.
    func testTheWindowsShape() throws {
        let window = SurfaceController.makeWindow(width: 460, height: 620)
        XCTAssertEqual(window.styleMask, [.titled, .closable, .miniaturizable, .resizable])
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
        XCTAssertNotNil(window.standardWindowButton(.zoomButton))
        XCTAssertNil(window.toolbar)
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenNone))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces), "Spaces as in 0.6")
        XCTAssertFalse(window.isVisible, "never shown")
        XCTAssertLessThan(window.contentLayoutRect.height, window.frame.height, "the content starts under the title bar")
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).height, window.contentLayoutRect.height)

        let title = WindowTitle.install(in: window)
        title.show(login: "example-user", color: .red)
        XCTAssertEqual(window.title, "example-user", "Mission Control and the Window menu")
        XCTAssertEqual(window.titleVisibility, .hidden, "the mark and the name take the title's place")
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertTrue(title.stack.superview === close.superview, "in the title bar")
        XCTAssertFalse(title.mark.isHidden)
        XCTAssertEqual(title.mark.color, .red)
        XCTAssertEqual(title.name.stringValue, "example-user")
        XCTAssertEqual(title.name.lineBreakMode, .byTruncatingTail, "a long name is cut with …")
        XCTAssertNil(title.stack.hitTest(NSPoint(x: 1, y: 1)), "presses go to the title bar")
        title.show(login: "example-user", color: .none)
        XCTAssertTrue(title.mark.isHidden, "None: the name alone")
        close.superview?.layoutSubtreeIfNeeded()
        let bar = try XCTUnwrap(close.superview)
        let frame = title.stack.convert(title.stack.bounds, to: bar)
        XCTAssertEqual(frame.midX, bar.bounds.midX, accuracy: 1, "centered")
        let closeFrame = close.convert(close.bounds, to: bar)
        XCTAssertEqual(frame.midY, closeFrame.midY, accuracy: 1, "on the buttons' line")
        title.show(login: String(repeating: "a-very-long-login-", count: 20), color: .blue)
        bar.layoutSubtreeIfNeeded()
        let long = title.stack.convert(title.stack.bounds, to: bar)
        XCTAssertGreaterThanOrEqual(long.minX, WindowTitle.side - 1, "clear of the buttons")
        XCTAssertLessThanOrEqual(long.maxX, bar.bounds.width - WindowTitle.side + 1)
    }

    /// The account's mark is a rounded square (DESIGN.md, "Account color").
    func testTheMarkIsASquare() {
        XCTAssertEqual(AccountMarkView.size, 10)
        XCTAssertEqual(AccountMarkView.radius, 2.5)
        XCTAssertEqual(AccountMark.size, 10)
        XCTAssertEqual(AccountMark.radius, 2.5)
        XCTAssertEqual(SettingsText.colorDetail, "Tints this account's icon and the square next to its name.")
    }

    /// Draws a view offscreen and returns the horizontal extent of what
    /// differs from the band's own color at mid height, in points.
    func drawnExtent<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> (min: CGFloat, max: CGFloat, rep: NSBitmapImageRep)? {
        let hosting = NSHostingView(rootView: view.frame(width: width, height: height))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / width
        let y = rep.pixelsHigh / 2
        guard let background = rep.colorAt(x: 1, y: y) else { return nil }
        let differs = (0..<rep.pixelsWide).filter { x in
            guard let c = rep.colorAt(x: x, y: y) else { return false }
            return abs(c.redComponent - background.redComponent) + abs(c.greenComponent - background.greenComponent)
                + abs(c.blueComponent - background.blueComponent) > 0.15
        }
        guard let first = differs.first, let last = differs.last else { return nil }
        return (CGFloat(first) / scale, CGFloat(last + 1) / scale, rep)
    }

    /// Part 1 of the popover's header: the mark and the name centered, the
    /// name alone for None, a long name cut inside the band's sides; 34
    /// points at text size 12, in proportion.
    func testTheBandCentersTheMarkAndTheName() throws {
        for k: CGFloat in [0.75, 1, 1.5] {
            let band = AccountBand(login: "example-user", color: .red).environment(\.textScale, k)
            XCTAssertEqual(NSHostingView(rootView: band.frame(width: 460)).fittingSize.height, 34 * k, accuracy: 0.5, "k \(k)")
        }
        let width: CGFloat = 460
        let marked = try XCTUnwrap(drawnExtent(AccountBand(login: "example-user", color: .red), width: width, height: 34))
        XCTAssertEqual((marked.min + marked.max) / 2, width / 2, accuracy: 2, "the mark and the name centered")
        let scale = CGFloat(marked.rep.pixelsWide) / width
        let markPixel = try XCTUnwrap(marked.rep.colorAt(x: Int((marked.min + 4) * scale), y: marked.rep.pixelsHigh / 2))
        XCTAssertGreaterThan(markPixel.redComponent, markPixel.blueComponent + 0.3, "the red square first")
        let plain = try XCTUnwrap(drawnExtent(AccountBand(login: "example-user", color: .none), width: width, height: 34))
        XCTAssertEqual((plain.min + plain.max) / 2, width / 2, accuracy: 2, "the name alone, centered")
        XCTAssertEqual((marked.max - marked.min) - (plain.max - plain.min), 10 + 8, accuracy: 2, "no room kept for the mark")
        let long = try XCTUnwrap(drawnExtent(AccountBand(login: String(repeating: "a-very-long-login-", count: 10), color: .red), width: 300, height: 34))
        XCTAssertGreaterThanOrEqual(long.min, 16 - 1, "cut inside the band's sides")
        XCTAssertLessThanOrEqual(long.max, 300 - 16 + 1)
    }

    /// The popover's header is the band and the row; the window's the row
    /// only (its title bar is the band).
    func testThePopoverHasTheBandAndTheWindowTheRowOnly() {
        for k: CGFloat in [0.75, 1, 1.5] {
            let popover = NSHostingView(rootView: header(.popover).environment(\.textScale, k).frame(width: 460)).fittingSize.height
            let window = NSHostingView(rootView: header(.window).environment(\.textScale, k).frame(width: 460)).fittingSize.height
            XCTAssertEqual(popover - window, 34 * k, accuracy: 0.5, "k \(k)")
            // The row is as tall as its 24-point buttons: the 11-point
            // `Updated …` line is lower up to text size 18.
            let line = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 11 * k))
            XCTAssertLessThan(line, 24)
            XCTAssertEqual(window, Header.rowInsets.top + 24, accuracy: 0.5, "k \(k)")
        }
        XCTAssertEqual(Header.rowInsets, EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 10))
    }

    /// DESIGN.md, "Screens" and "UI": the menu bar icon acts on either
    /// button's release, so a right click opens the popover too.
    func testTheStatusItemActsOnBothButtons() {
        XCTAssertEqual(SurfaceController.clickEvents, [.leftMouseUp, .rightMouseUp])
    }

    /// DESIGN.md, "Open in window": a minimized window comes back only on the
    /// Dock icon (and its own account's icon, which opens it); ⌘Tab and other
    /// activations leave it in the Dock and bring the others forward.
    func testOnlyTheDockAndTheOwnIconRestoreAMinimizedWindow() {
        XCTAssertEqual(SurfaceController.front(minimized: true, restoring: true), .restore)
        XCTAssertEqual(SurfaceController.front(minimized: true, restoring: false), .leave)
        XCTAssertEqual(SurfaceController.front(minimized: false, restoring: false), .order)
        XCTAssertEqual(SurfaceController.front(minimized: false, restoring: true), .order)
    }

    /// ⌘R through the surface's key handling: Refresh in the list, the
    /// search field and the Dismissed list; nothing while the Grouping sheet
    /// or the × confirmation shows (DESIGN.md, "Keyboard").
    func testCommandRThroughTheSurfacesKeys() {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("no-daemon-\(UUID().uuidString).sock").path
        let app = AppModel(
            api: SocketDaemonAPI(socketPath: socket), store: UIStateStore(defaults: ScratchDefaults()), opener: FilterBoxTests.NoOpener(),
            notifier: FilterBoxTests.NoNotifier()
        )
        let data = app.viewModel("1001")
        Self.kept += [app, data]
        let r = ShiibarGhCore.KeyPress(characters: "r", modifiers: [.command])
        for surface in [Surface.popover, .window] {
            let list = data.list(surface)
            Self.kept.append(list)
            XCTAssertEqual(SurfaceController.decide(r, model: list, typing: false), .refresh, "\(surface)")
            XCTAssertEqual(SurfaceController.decide(r, model: list, typing: true), .refresh, "\(surface): the search field")
            list.showsGrouping = true
            XCTAssertEqual(SurfaceController.decide(r, model: list, typing: false), .ignore, "\(surface): the Grouping sheet")
            XCTAssertEqual(SurfaceController.decide(r, model: list, typing: true), .ignore)
            list.showsGrouping = false
        }
        XCTAssertEqual(SurfaceController.decide(r, model: nil, typing: false), .refresh, "no account: the handler does nothing with it")
    }

    static var kept: [AnyObject] = []

    /// DESIGN.md, "Minimum height": the least height the surface reports
    /// for text sizes 9, 12 and 18 (the Filter's options open, no band), laid
    /// out offscreen: the popover with the header's band, the window's
    /// content with the row only (the title bar is the band). The values
    /// match the measurement mode's (`SHIIBAR_GH_PERF_SNAPSHOT`).
    func testTheLeastHeights() async throws {
        let want: [Int: (popover: CGFloat, window: CGFloat)] = [9: (339, 313), 12: (426, 392), 18: (598, 547)]
        for (size, heights) in want.sorted(by: { $0.key < $1.key }) {
            for surface in [Surface.popover, .window] {
                let socket = FileManager.default.temporaryDirectory.appendingPathComponent("no-daemon-\(UUID().uuidString).sock").path
                let app = AppModel(
                    api: SocketDaemonAPI(socketPath: socket), store: UIStateStore(defaults: ScratchDefaults()),
                    opener: FilterBoxTests.NoOpener(), notifier: FilterBoxTests.NoNotifier()
                )
                app.handle(.configChanged(key: TextSize.configKey, value: .int(Int64(size))))
                let data = app.viewModel("1001")
                let list = data.list(surface)
                Self.kept += [app, data, list]
                var actions = SurfaceActions(openWindow: {}, openSettings: { _ in }, about: {}, quit: {})
                if surface == .window { actions.openWindow = nil }
                let root = PopoverView.root(
                    app: app, model: data, list: list, avatars: AvatarStore(loader: DismissedBandPressTests.PixelImages()),
                    actions: actions, surface: surface
                )
                var reported: CGFloat?
                root.onMinimumHeight = { reported = $0 }
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 900), styleMask: [.borderless], backing: .buffered, defer: true)
                window.contentView = root
                root.frame = NSRect(x: 0, y: 0, width: 460, height: 900)
                list.openTab(.all)
                if !list.filterOpen { list.toggleFilterOpen() }
                for _ in 0..<100 where reported == nil {
                    root.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                let expected = surface == .popover ? heights.popover : heights.window
                XCTAssertEqual(try XCTUnwrap(reported, "\(size) \(surface)"), expected, accuracy: 0.5, "\(size) \(surface)")
                XCTAssertFalse(window.isVisible)
            }
        }
    }
}

