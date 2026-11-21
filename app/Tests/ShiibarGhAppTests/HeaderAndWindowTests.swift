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
    func header(_ surface: Surface, refreshing: Bool = false, usage: ApiUsage = ApiUsage(nil)) -> Header {
        var actions = SurfaceActions(openWindow: {}, openSettings: { _ in }, about: {}, quit: {})
        if surface == .window {
            actions.openWindow = nil
            actions.openPopover = {}
        }
        return Header(
            login: "example-user", color: .red, updated: "Updated 1 min ago", usage: usage, keepOnTop: true,
            toggleKeepOnTop: {}, surface: surface, refreshing: refreshing, actions: actions, refresh: {}
        )
    }

    /// DESIGN.md, "Screens", "Open in window": the popover has Refresh,
    /// Open in window, Settings, ⌄; the window Refresh, Open in popover,
    /// the pin, Settings, ⌄.
    func testTheButtonsOfThePopoverAndTheWindow() {
        XCTAssertEqual(Header.buttons(surface: .popover, canOpenWindow: true), [.refresh, .openWindow, .settings, .more])
        XCTAssertEqual(Header.buttons(surface: .window, canOpenWindow: false), [.refresh, .openPopover, .pin, .settings, .more])
        XCTAssertEqual(Header.refreshHelp, "Refresh (\u{2318}R)")
        // The header lays them out without trouble at both widths.
        _ = Probe.host(header(.popover), width: 460)
        _ = Probe.host(header(.window), width: 300)
    }

    /// The `Open in popover` icon: the rounded square, the menu bar's line
    /// and the arrow up (DESIGN.md, "Constants"), stroked 1.5, round caps
    /// and joins.
    func testTheOpenInPopoverIcon() {
        let icon = BoardIcons.openInPopover
        XCTAssertEqual(icon.elements, [
            .rect(x: 2, y: 2.5, width: 12, height: 11, radius: 2.2), .path("M2 5.6h12"), .path("M8 11.6V8M6.1 9.7 8 7.8l1.9 1.9"),
        ])
        XCTAssertEqual(icon.lineWidth, 1.5)
        XCTAssertTrue(icon.roundCaps)
        XCTAssertTrue(icon.roundJoins)
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
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces), "not on every Space")
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace), "comes to the current Space")
        XCTAssertFalse(window.collectionBehavior.contains(.managed), "nothing else set")
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

    /// DESIGN.md, "Constants", "Header row 2's buttons": 24 points at
    /// text size 12 with the icons at 16, 15, 15, 16, 14 and 14 points,
    /// each times the ratio unrounded (18 at 9, 36 at 18); the hover fill's
    /// radius and the gap between the buttons stay.
    func testTheHeaderButtonsFollowTheTextSize() {
        XCTAssertEqual(HeaderButton.side, 24)
        XCTAssertEqual(HoverButtonStyle.radius, 6)
        XCTAssertEqual(Header.buttonGap, 6)
        for size in [9, 10, 12, 18] {
            let k = CGFloat(TextSize.ratio(size))
            let views: [(String, AnyView)] = [
                ("Refresh", AnyView(RefreshButton(refreshing: false, scale: k, action: {}))),
                ("Refreshing", AnyView(RefreshButton(refreshing: true, scale: k, action: {}))),
                ("Open in window", AnyView(HeaderButton(icon: BoardIcons.window, size: 15, label: "Open in window", scale: k) {})),
                ("Open in popover", AnyView(HeaderButton(icon: BoardIcons.openInPopover, size: 15, label: "Open in popover", scale: k) {})),
                ("pin on", AnyView(PinButton(on: true, scale: k, toggle: {}))),
                ("pin off", AnyView(PinButton(on: false, scale: k, toggle: {}))),
                ("Settings", AnyView(HeaderButton(icon: BoardIcons.settings, size: 16, label: "Settings", scale: k) {})),
                ("More", AnyView(MenuIconButton(icon: BoardIcons.chevron, label: "More", items: [], scale: k))),
            ]
            for (name, view) in views {
                let fitting = NSHostingView(rootView: view).fittingSize
                XCTAssertEqual(fitting.width, 24 * k, accuracy: 0.01, "\(name) at \(size)")
                XCTAssertEqual(fitting.height, 24 * k, accuracy: 0.01, "\(name) at \(size)")
            }
            // The icons, strokes included: drawn at their size times k.
            for (icon, points) in [(BoardIcons.refresh, 16.0), (BoardIcons.window, 15), (BoardIcons.openInPopover, 15), (BoardIcons.settings, 16), (BoardIcons.chevron, 14), (BoardIcons.pin, 14)] {
                XCTAssertEqual(IconPath.stroke(icon, scale: points * k / 16).lineWidth, icon.lineWidth * points * k / 16, accuracy: 0.0001)
            }
        }
        XCTAssertEqual(NSHostingView(rootView: HeaderButton(icon: BoardIcons.window, size: 15, label: "x", scale: 0.75) {}).fittingSize.width, 18)
        XCTAssertEqual(NSHostingView(rootView: HeaderButton(icon: BoardIcons.window, size: 15, label: "x", scale: 1.5) {}).fittingSize.width, 36)
    }

    /// DESIGN.md, "Screens": the five buttons keep 24k × 24k and sit 6
    /// points apart at the right end; short of room, the API usage goes as
    /// a whole before `Updated …` is cut; the bar is never cut.
    func testTheButtonsFitAt18InTheNarrowestWindow() {
        let k: CGFloat = 1.5
        let inner = 300 - Header.rowInsets.leading - Header.rowInsets.trailing
        let value = ApiUsage(RateLimit(graphql: Limit(used: 4000, limit: 5000)))
        let updated = Ink.width("Updated 1 min ago", Ink.font(11 * k))
        let usage = Ink.width("Updated 1 min ago · ", Ink.font(11 * k)) + UsageView.width(value, k: k)
        let fit = HeaderRowFit.fit(width: inner, k: k, buttons: 5, updated: updated, usage: usage)
        XCTAssertEqual(fit.buttons.count, 5)
        for button in fit.buttons {
            XCTAssertEqual(button.width, 36)
            XCTAssertEqual(button.height, 36)
        }
        for (left, right) in zip(fit.buttons, fit.buttons.dropFirst()) { XCTAssertEqual(right.minX - left.maxX, 6) }
        XCTAssertEqual(fit.buttons.last?.maxX, inner, "at the right end")
        XCTAssertGreaterThanOrEqual(fit.buttons.first?.minX ?? -1, 0, "all five inside the row")
        XCTAssertFalse(fit.showsUsage, "no room for the usage at 300 points")
        XCTAssertLessThanOrEqual(fit.updatedWidth + 12, fit.buttons.first!.minX + 0.001, "Updated … never under the buttons")
        // Across widths: the usage shows whole or not at all, and `Updated …`
        // is cut only once the usage is gone.
        var sawBoth = false, sawCut = false, sawWhole = false
        for width in stride(from: CGFloat(150), through: 700, by: 1) {
            let fit = HeaderRowFit.fit(width: width, k: k, buttons: 5, updated: updated, usage: usage)
            let room = fit.buttons.first!.minX - 12
            if fit.showsUsage {
                sawBoth = true
                XCTAssertEqual(fit.updatedWidth, usage, "\(width): the whole usage")
                XCTAssertLessThanOrEqual(usage, room + 0.001, "\(width): the bar fits whole")
            } else {
                XCTAssertGreaterThan(usage.rounded(.up) + 2, room, "\(width): the usage went only for lack of room")
                XCTAssertLessThanOrEqual(fit.updatedWidth, max(0, room) + 0.001, "\(width)")
                if fit.updatedWidth < updated.rounded(.up) { sawCut = true } else { sawWhole = true }
            }
        }
        XCTAssertTrue(sawBoth && sawCut && sawWhole, "every case met")
        // Laid out at 300 points the header is one row.
        let host = NSHostingView(rootView: header(.window, usage: value).environment(\.textScale, k).frame(width: 300))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, Header.rowInsets.top + 24 * k, accuracy: 0.5)
    }

    /// With room, the usage shows.
    func testTheUsageShowsWhenThereIsRoom() {
        let updated = Ink.width("Updated 1 min ago", Ink.font(11))
        let usage = Ink.width("Updated 1 min ago · ", Ink.font(11)) + UsageView.width(ApiUsage(nil), k: 1)
        let fit = HeaderRowFit.fit(width: 460 - 26, k: 1, buttons: 4, updated: updated, usage: usage)
        XCTAssertTrue(fit.showsUsage)
        XCTAssertEqual(fit.buttons.map(\.width), [24, 24, 24, 24])
    }

    /// The Settings rows under Account: Token, Menu bar icon color, Global
    /// shortcut; the shortcut's message is the center's hint, in the place
    /// of the row's error line.
    func testTheGlobalShortcutRow() {
        XCTAssertEqual(AccountPane.AccountRow.allCases, [.token, .color, .shortcut])
        XCTAssertEqual(AccountPane.AccountRow.allCases.map(\.title), ["Token", "Menu bar icon color", "Global shortcut"])
        let center = GlobalShortcutCenter(store: UIStateStore(defaults: ScratchDefaults()), registrar: FieldSpyRegistrar())
        Self.kept.append(center)
        center.accountsListed(["1001"])
        XCTAssertNil(AccountPane.message(.shortcut, account: "1001", errors: [:], shortcuts: center))
        center.fieldClicked("1001")
        center.keyPressed(keyCode: 0x28, modifiers: [], keyName: "K")
        XCTAssertEqual(AccountPane.message(.shortcut, account: "1001", errors: [:], shortcuts: center), "Add \u{2303}, \u{2325}, or \u{2318} to the shortcut")
        XCTAssertEqual(AccountPane.message(.color, account: "1001", errors: ["color:1001": "x"], shortcuts: center), "x")
        XCTAssertNil(AccountPane.message(.token, account: "1001", errors: ["color:1001": "x"], shortcuts: center))
        center.abandonRecording()
    }

    /// Settings and the About panel take the level of the pinned windows:
    /// floating while one is open, normal when none is or it is closing.
    /// The windows are never shown.
    func testSettingsAndAboutFollowThePins() {
        let settings = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let about = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let auxiliary = AuxiliaryWindows()
        auxiliary.settings = settings
        auxiliary.apply(pins: ["1001": true], closing: nil)
        XCTAssertEqual(settings.level, .floating, "Settings opened with a pinned window")
        auxiliary.about = about
        auxiliary.apply(pins: ["1001": true], closing: nil)
        XCTAssertEqual(about.level, .floating, "About shown")
        auxiliary.apply(pins: ["1001": false], closing: nil)
        XCTAssertEqual(settings.level, .normal, "the pin turned off")
        XCTAssertEqual(about.level, .normal)
        auxiliary.apply(pins: ["1001": false, "1002": true], closing: nil)
        XCTAssertEqual(settings.level, .floating, "another account's pinned window")
        auxiliary.apply(pins: ["1001": false, "1002": true], closing: "1002")
        XCTAssertEqual(settings.level, .normal, "the pinned window closing")
        XCTAssertFalse(settings.isVisible)
    }

    /// Refresh while it runs: the icon turns clockwise once a second at an
    /// even speed; not with Reduce Motion; upright when it is over; 40%
    /// opacity and `Refreshing…`.
    func testRefreshTurnsWhileItRuns() throws {
        XCTAssertEqual(RefreshButton.period, 1)
        XCTAssertEqual(RefreshButton.opacityWhileRefreshing, 0.4)
        XCTAssertEqual(RefreshButton.helpWhileRefreshing, "Refreshing\u{2026}")
        XCTAssertEqual(RefreshButton.angle(elapsed: 0, refreshing: true, reduceMotion: false), 0)
        XCTAssertEqual(RefreshButton.angle(elapsed: 0.25, refreshing: true, reduceMotion: false), 90, accuracy: 0.001, "clockwise")
        XCTAssertEqual(RefreshButton.angle(elapsed: 0.5, refreshing: true, reduceMotion: false), 180, accuracy: 0.001)
        XCTAssertEqual(RefreshButton.angle(elapsed: 1.75, refreshing: true, reduceMotion: false), 270, accuracy: 0.001, "even speed")
        XCTAssertEqual(RefreshButton.angle(elapsed: 3, refreshing: true, reduceMotion: false), 0, accuracy: 0.001)
        XCTAssertEqual(RefreshButton.angle(elapsed: 0.3, refreshing: true, reduceMotion: true), 0, "Reduce Motion: no turn")
        XCTAssertEqual(RefreshButton.angle(elapsed: 0.3, refreshing: false, reduceMotion: false), 0, "over: upright")
        // A press does nothing while it runs.
        var pressed = 0
        RefreshButton.press(refreshing: true) { pressed += 1 }
        XCTAssertEqual(pressed, 0)
        RefreshButton.press(refreshing: false) { pressed += 1 }
        XCTAssertEqual(pressed, 1)
        // Drawn: the icon at 40% while it runs.
        func ink(_ refreshing: Bool) throws -> CGFloat {
            let host = NSHostingView(rootView: RefreshButton(refreshing: refreshing, scale: 1, action: {}))
            host.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
            host.appearance = NSAppearance(named: .aqua)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            var most: CGFloat = 0
            for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh { most = max(most, rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) } }
            return most
        }
        let idle = try ink(false), running = try ink(true)
        XCTAssertGreaterThan(idle, 0.3)
        XCTAssertEqual(running / idle, 0.4, accuracy: 0.08, "40% opacity")
    }

    /// The header's Refresh goes through the same check as ⌘R: a second
    /// one does not start while one runs.
    func testTheHeaderRefreshDoesNotStartTwice() {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("no-daemon-\(UUID().uuidString).sock").path
        let app = AppModel(
            api: SocketDaemonAPI(socketPath: socket), store: UIStateStore(defaults: ScratchDefaults()), opener: FilterBoxTests.NoOpener(),
            notifier: FilterBoxTests.NoNotifier()
        )
        Self.kept.append(app)
        app.handle(.snapshot(accounts: [Account(id: "1001", login: "example-user")], keychain: .known(.ok), dbUnreadable: false))
        app.refreshAnswerDelay = 5
        app.refreshIfIdle("1001")
        XCTAssertEqual(app.refreshing, ["1001"])
        app.refreshIfIdle("1001")
        XCTAssertEqual(app.refreshing, ["1001"])
    }

    /// ⌘R does nothing while the account's Refresh runs.
    func testCommandRDoesNothingWhileRefreshing() async throws {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("no-daemon-\(UUID().uuidString).sock").path
        let app = AppModel(
            api: SocketDaemonAPI(socketPath: socket), store: UIStateStore(defaults: ScratchDefaults()), opener: FilterBoxTests.NoOpener(),
            notifier: FilterBoxTests.NoNotifier()
        )
        Self.kept.append(app)
        app.handle(.snapshot(accounts: [Account(id: "1001", login: "example-user")], keychain: .known(.ok), dbUnreadable: false))
        app.refreshAnswerDelay = 0.3
        app.refreshByKey("1001")
        XCTAssertEqual(app.refreshing, ["1001"])
        app.refreshByKey("1001")
        XCTAssertEqual(app.refreshing, ["1001"], "still the one running")
        for _ in 0..<100 where !app.refreshing.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(app.refreshing, [], "over once the held answer shows")
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
    /// name alone for None, a long name cut inside the band's sides.
    func testTheBandCentersTheMarkAndTheName() throws {
        let h = AccountBand.height
        let width: CGFloat = 460
        let marked = try XCTUnwrap(drawnExtent(AccountBand(login: "example-user", color: .red), width: width, height: h))
        XCTAssertEqual((marked.min + marked.max) / 2, width / 2, accuracy: 2, "the mark and the name centered")
        let scale = CGFloat(marked.rep.pixelsWide) / width
        let markPixel = try XCTUnwrap(marked.rep.colorAt(x: Int((marked.min + 4) * scale), y: marked.rep.pixelsHigh / 2))
        XCTAssertGreaterThan(markPixel.redComponent, markPixel.blueComponent + 0.3, "the red square first")
        let plain = try XCTUnwrap(drawnExtent(AccountBand(login: "example-user", color: .none), width: width, height: h))
        XCTAssertEqual((plain.min + plain.max) / 2, width / 2, accuracy: 2, "the name alone, centered")
        XCTAssertEqual((marked.max - marked.min) - (plain.max - plain.min), 10 + WindowTitle.gap, accuracy: 2, "no room kept for the mark")
        let long = try XCTUnwrap(drawnExtent(AccountBand(login: String(repeating: "a-very-long-login-", count: 10), color: .red), width: 300, height: h))
        XCTAssertGreaterThanOrEqual(long.min, 16 - 1, "cut inside the band's sides")
        XCTAssertLessThanOrEqual(long.max, 300 - 16 + 1)
    }

    /// The popover's band looks like the window's title bar: as high as the
    /// standard title bar of the window's style (a real window's frame less
    /// its content), the title bar font, the window title's 10-point square
    /// and spacing; none of it follows the text size.
    func testTheBandIsTheWindowsTitleBar() throws {
        let window = SurfaceController.makeWindow(width: 460, height: 620)
        XCTAssertFalse(window.isVisible)
        let bar = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(bar, 0)
        XCTAssertEqual(AccountBand.height, bar, accuracy: 0.01)
        XCTAssertEqual(WindowTitle.barHeight, bar, accuracy: 0.01)
        let title = WindowTitle.install(in: window)
        XCTAssertEqual(AccountBand.font, title.name.font)
        XCTAssertEqual(AccountBand.font, NSFont.titleBarFont(ofSize: 0))
        XCTAssertEqual(AccountBand.gap, title.stack.spacing)
        XCTAssertEqual(AccountMark.size, AccountMarkView.size)
        XCTAssertEqual(AccountMark.radius, AccountMarkView.radius)
        var heights: [CGFloat] = []
        var extents: [CGFloat] = []
        for k: CGFloat in [0.75, 1, 1.5] {
            let band = AccountBand(login: "example-user", color: .red).environment(\.textScale, k)
            heights.append(NSHostingView(rootView: band.frame(width: 460)).fittingSize.height)
            let drawn = try XCTUnwrap(drawnExtent(band, width: 460, height: AccountBand.height))
            extents.append(drawn.max - drawn.min)
        }
        for height in heights {
            XCTAssertEqual(height, bar, accuracy: 0.5, "the same at every text size")
        }
        XCTAssertEqual(extents.max()! - extents.min()!, 0, accuracy: 1, "the mark and the name keep their size")
    }

    /// The popover's header is the band and the row; the window's the row
    /// only (its title bar is the band).
    func testThePopoverHasTheBandAndTheWindowTheRowOnly() {
        for k: CGFloat in [0.75, 1, 1.5] {
            let popover = NSHostingView(rootView: header(.popover).environment(\.textScale, k).frame(width: 460)).fittingSize.height
            let window = NSHostingView(rootView: header(.window).environment(\.textScale, k).frame(width: 460)).fittingSize.height
            XCTAssertEqual(popover - window, AccountBand.height, accuracy: 0.5, "k \(k): the band does not follow the text size")
            // The row is as tall as its buttons, 24 points times k: the
            // 11-point `Updated …` line is lower at every text size.
            let line = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 11 * k))
            XCTAssertLessThan(line, 24 * k)
            XCTAssertEqual(window, Header.rowInsets.top + 24 * k, accuracy: 0.5, "k \(k)")
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
    /// out offscreen at the popover's width for the text size: the popover
    /// with the header's band, the window's content with the row only (the
    /// title bar is the band). The fixed part, the Filter row (24), the
    /// options' area (2 + 62 + 6), the list's minimum (100) and the key
    /// hints, never under 300: at 9 both come to less than 300.
    func testTheLeastHeights() async throws {
        // The popover: the window's content and the band, which does not
        // follow the text size.
        let band = AccountBand.height
        let want: [Int: (popover: CGFloat, window: CGFloat)] = [
            9: (300, 300), 12: (327 + band, 327), 18: (465 + band, 465),
        ]
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
                // As wide as the popover at this text size.
                let width = CGFloat(TextSize.width(size))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: true)
                window.contentView = root
                root.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                list.openTab(.all)
                if !list.filterOpen { list.toggleFilterOpen() }
                for _ in 0..<100 where reported == nil {
                    root.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                let expected = surface == .popover ? heights.popover : heights.window
                // The least height differs by up to 1 pt between macOS versions.
                XCTAssertEqual(try XCTUnwrap(reported, "\(size) \(surface)"), expected, accuracy: 1, "\(size) \(surface)")
                XCTAssertFalse(window.isVisible)
            }
        }
    }
}

