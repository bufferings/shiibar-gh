// What the icons, the global shortcuts, the notifications and the header's
// `Open in window` / `Open in popover` do, in order (DESIGN.md, "Surface
// form", "`Open in popover`", "Switching to a regular app", "macOS
// notifications"), with a fake host in place of AppKit. No window, no menu
// bar, no real hotkey; injected UserDefaults.

import Foundation
@testable import ShiibarGhCore
import XCTest

/// Records every call in order; its state is set by each test.
@MainActor
final class FakeSurfaceHost: SurfaceHosting {
    var log: [String] = []
    var popoverShown = false
    var popoverAccount: String?
    var blocked = false
    var windows: [String: WindowFacts] = [:]
    /// False: the popover cannot show (no icon).
    var canPresent = true

    func windowFacts(_ account: String) -> WindowFacts? {
        log.append("read \(account)")
        return windows[account]
    }

    func presentPopover(_ account: String) -> Bool {
        log.append("present popover \(account)")
        guard canPresent else { return false }
        popoverShown = true
        popoverAccount = account
        return true
    }

    func closePopover() {
        log.append("close popover")
        popoverShown = false
        popoverAccount = nil
    }

    func presentWindow(_ account: String) {
        log.append("present window \(account)")
        windows[account] = windows[account] ?? WindowFacts(appActive: true, key: true)
    }

    func closeWindow(_ account: String) {
        log.append("close window \(account)")
        windows[account] = nil
    }

    func windowWillShow(_ account: String) { log.append("regular window \(account)") }
    func holdPopover() { log.append("hold") }
    func popoverHoldEnded() { log.append("hold ended") }

    /// The calls that change something (the reads left out).
    var moves: [String] { log.filter { !$0.hasPrefix("read") } }
}

@MainActor
final class SurfaceDirectorTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var api: FakeAPI!
    var model: AppModel!
    var host: FakeSurfaceHost!
    var director: SurfaceDirector!
    let a = "3407303"
    let b = "583231"

    override func setUp() async throws {
        (defaults, suite) = testDefaults()
        api = FakeAPI()
        model = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: FakeNotifier(), clock: { T0 })
        model.handle(.snapshot(accounts: [sampleAccount(), Account(id: b, login: "example-user")], keychain: .known(.ok), dbUnreadable: false))
        host = FakeSurfaceHost()
        director = SurfaceDirector(app: model)
        director.host = host
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    let front = WindowFacts(appActive: true, key: true)

    // MARK: The icon and the shortcut

    func testThePopoverForm() {
        director.toggle(account: a, pressedAt: nil)
        XCTAssertEqual(host.moves, ["present popover \(a)"])
        director.toggle(account: a, pressedAt: nil)
        XCTAssertEqual(host.moves.last, "close popover")
        // Another account's popover shows: this account's replaces it.
        host.popoverShown = true
        host.popoverAccount = b
        host.log = []
        director.toggle(account: a, pressedAt: nil)
        XCTAssertEqual(host.moves, ["present popover \(a)"])
    }

    func testTheWindowForm() {
        model.store.setSurfaceForm(.window, account: a)
        director.toggle(account: a, pressedAt: nil)
        XCTAssertEqual(host.moves, ["regular window \(a)", "present window \(a)"], "closed: opened")
        host.windows[a] = WindowFacts(appActive: false, key: true)
        host.log = []
        director.toggle(account: a, pressedAt: nil)
        XCTAssertEqual(host.moves, ["regular window \(a)", "present window \(a)"], "another app in front: brought to the front")
        host.windows[a] = front
        host.log = []
        director.toggle(account: a, pressedAt: nil)
        XCTAssertEqual(host.moves, ["close window \(a)"], "in front: closed")
    }

    /// Everything is read before anything moves.
    func testTheStateIsReadFirst() {
        model.store.setSurfaceForm(.window, account: a)
        host.windows[a] = front
        director.toggle(account: a, pressedAt: nil)
        XCTAssertEqual(host.log, ["read \(a)", "close window \(a)"])
    }

    /// A sheet in the window in front (the Grouping sheet, a Dismiss
    /// confirmation, an AppKit sheet): nothing.
    func testASheetKeepsTheWindowInFront() {
        model.store.setSurfaceForm(.window, account: a)
        host.windows[a] = front
        let list = model.viewModel(a).list(.window)
        list.showsGrouping = true
        director.toggle(account: a, pressedAt: nil)
        XCTAssertEqual(host.moves, [])
        list.showsGrouping = false
        host.windows[a] = WindowFacts(appActive: true, key: false, sheetKey: true, attachedSheet: true)
        director.toggle(account: a, pressedAt: nil)
        XCTAssertEqual(host.moves, [], "a key sheet counts as the window: in front, not closed")
    }

    func testNothingWhileBlocked() {
        host.blocked = true
        director.toggle(account: a, pressedAt: nil)
        model.store.setSurfaceForm(.window, account: a)
        host.windows[a] = front
        director.toggle(account: a, pressedAt: nil)
        XCTAssertEqual(host.moves, [])
    }

    /// A key window gained by the press itself does not count.
    func testTheStateBeforeThePress() {
        model.store.setSurfaceForm(.window, account: a)
        host.windows[a] = WindowFacts(appActive: true, becameActiveAt: 5, key: true, becameKeyAt: 10.5)
        director.toggle(account: a, pressedAt: 10)
        XCTAssertEqual(host.moves, ["regular window \(a)", "present window \(a)"])
        host.log = []
        host.windows[a] = WindowFacts(appActive: true, becameActiveAt: 5, key: true, becameKeyAt: 9)
        director.toggle(account: a, pressedAt: 10)
        XCTAssertEqual(host.moves, ["close window \(a)"])
    }

    /// The pressed shortcut's id names the account and goes the icon's way.
    func testAShortcutActsAsTheIcon() {
        let spy = SpyRegistrar()
        let shortcuts = GlobalShortcutCenter(store: model.store, registrar: spy)
        model.store.setShortcut(GlobalShortcut(keyCode: 0x31, modifiers: [.control, .option], keyName: "Space"), account: a)
        shortcuts.accountsListed([a, b])
        director.attach(shortcuts)
        spy.press(shortcuts.id(of: a))
        XCTAssertEqual(host.moves, ["present popover \(a)"])
        model.store.setSurfaceForm(.window, account: a)
        host.popoverShown = false
        host.popoverAccount = nil
        host.log = []
        spy.press(shortcuts.id(of: a))
        XCTAssertEqual(host.moves, ["regular window \(a)", "present window \(a)"])
    }

    // MARK: Opening

    /// Opening or raising a window closes the popover, whichever account's;
    /// the window is a regular reason first.
    func testAWindowClosesAnyPopover() {
        for shown in [a, b] {
            host.popoverShown = true
            host.popoverAccount = shown
            host.log = []
            director.openWindow(account: a)
            XCTAssertEqual(host.moves, ["regular window \(a)", "close popover", "present window \(a)"], shown)
        }
    }

    /// No popover for an account whose window is open.
    func testNoPopoverWhileTheWindowIsOpen() {
        host.windows[a] = front
        XCTAssertFalse(director.showPopover(account: a))
        director.toggle(account: a, pressedAt: nil)
        XCTAssertFalse(host.moves.contains("present popover \(a)"))
        XCTAssertTrue(director.showPopover(account: b), "another account's opens")
    }

    /// A notification opens or brings to the front, never closes.
    func testANotificationNeverCloses() {
        director.showForNotification(account: a)
        XCTAssertEqual(host.moves, ["present popover \(a)"])
        director.showForNotification(account: a)
        XCTAssertEqual(host.moves, ["present popover \(a)"], "shown already: stays")
        model.store.setSurfaceForm(.window, account: b)
        host.log = []
        director.showForNotification(account: b)
        XCTAssertEqual(host.moves, ["regular window \(b)", "close popover", "present window \(b)"])
        host.log = []
        director.showForNotification(account: b)
        XCTAssertEqual(host.moves, ["regular window \(b)", "present window \(b)"], "in front: not closed")
    }

    // MARK: Switching the form

    func testOpenInPopoverInOrder() async {
        api.cards = sampleCards()
        model.viewModel(a).reload()
        await settle()
        host.windows[a] = front
        let window = model.viewModel(a).list(.window)
        window.openTab(.mine)
        window.openDismissedList()
        director.openInPopover(account: a)
        XCTAssertEqual(host.moves, ["hold", "close window \(a)", "present popover \(a)"])
        XCTAssertEqual(model.store.surfaceForm(account: a), .popover)
        let popover = model.viewModel(a).list(.popover)
        XCTAssertEqual(popover.tab, .mine, "carried before it shows")
        XCTAssertTrue(popover.showingDismissed)
        XCTAssertEqual(model.store.lastTab(account: a, surface: .popover), .mine)
    }

    func testOpenInPopoverReleasesTheHoldWhenNoPopoverShows() {
        host.windows[a] = front
        host.canPresent = false
        director.openInPopover(account: a)
        XCTAssertEqual(host.moves, ["hold", "close window \(a)", "present popover \(a)", "hold ended"])
    }

    func testOpenInWindowCarriesTheTab() {
        let popover = model.viewModel(a).list(.popover)
        popover.openTab(.review)
        host.popoverShown = true
        host.popoverAccount = a
        director.openInWindow(account: a)
        XCTAssertEqual(model.store.surfaceForm(account: a), .window)
        XCTAssertEqual(model.viewModel(a).list(.window).tab, .review)
        XCTAssertEqual(model.store.lastTab(account: a, surface: .window), .review)
        XCTAssertEqual(host.moves, ["regular window \(a)", "close popover", "present window \(a)"])
    }

    // MARK: Closing the popover

    /// Closed, the popover ends a Dismiss or `Dismiss all` confirmation as
    /// `Cancel` does (nothing dismissed) and closes the Grouping sheet.
    func testClosingThePopoverEndsItsSheets() async {
        api.cards = sampleCards()
        model.viewModel(a).reload()
        await settle()
        let popover = model.viewModel(a).list(.popover)
        model.surfaceDisplayed(.popover, account: a, true, opening: true)
        model.surfaceOpened(.popover, account: a)
        let card = popover.sections.flatMap(\.cards).first!
        popover.perform(.confirmDismiss(card: card.id))
        XCTAssertNotNil(popover.confirmingDismiss)
        api.clearCalls()
        model.surfaceClosed(.popover, account: a)
        model.surfaceDisplayed(.popover, account: a, false)
        XCTAssertNil(popover.confirmingDismiss)
        await settle()
        XCTAssertFalse(api.calls.contains { $0.hasPrefix("dismiss") }, "nothing dismissed")
        popover.openTab(.all)
        model.surfaceDisplayed(.popover, account: a, true, opening: true)
        model.surfaceOpened(.popover, account: a)
        popover.openGrouping()
        XCTAssertTrue(popover.showsGrouping)
        model.surfaceClosed(.popover, account: a)
        model.surfaceDisplayed(.popover, account: a, false)
        XCTAssertFalse(popover.showsGrouping)
    }
}
