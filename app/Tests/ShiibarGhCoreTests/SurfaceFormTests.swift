// The surface form of each account and what its menu bar icon, its global
// shortcut and its notifications do (DESIGN.md, "Open in window", "Surface
// form", "`Open in popover`", "Switching to a regular app", "macOS
// notifications", "Saving state"). No window, no daemon; injected
// UserDefaults.

import Foundation
@testable import ShiibarGhCore
import XCTest

final class SurfaceToggleTests: XCTestCase {
    func decide(
        _ form: SurfaceForm, popover: Bool = false, open: Bool = false, front: Bool = false, sheet: Bool = false, blocked: Bool = false
    ) -> SurfaceToggle {
        SurfaceToggle.decide(form: form, popoverShownForAccount: popover, windowOpen: open, windowFront: front, sheetShown: sheet, blocked: blocked)
    }

    /// The table of "Surface form".
    func testTheTable() {
        // The popover form opens and closes the popover; another account's
        // popover showing counts as closed here (it is replaced).
        XCTAssertEqual(decide(.popover), .openPopover)
        XCTAssertEqual(decide(.popover, popover: true), .closePopover)
        // The window form.
        XCTAssertEqual(decide(.window), .openWindow, "closed: opened")
        XCTAssertEqual(decide(.window, open: true), .raiseWindow, "open, not in front: brought to the front")
        XCTAssertEqual(decide(.window, open: true, front: true), .closeWindow, "in front: closed")
        XCTAssertEqual(decide(.window, open: true, front: true, sheet: true), .nothing, "a sheet asks for an answer")
        XCTAssertEqual(decide(.window, open: true, sheet: true), .raiseWindow, "with a sheet, not in front: brought to the front")
    }

    /// A modal dialog or an open menu: nothing, whatever the state.
    func testNothingWhileADialogOrAMenuIsOpen() {
        for form in [SurfaceForm.popover, .window] {
            for open in [false, true] {
                for front in [false, true] {
                    XCTAssertEqual(decide(form, popover: form == .popover && open, open: form == .window && open, front: front, blocked: true), .nothing)
                }
            }
        }
    }

    /// The popover and the window of one account never show together: the
    /// one showing decides, whatever the saved form says.
    func testWhatShowsDecidesOverTheForm() {
        XCTAssertEqual(decide(.window, popover: true), .closePopover)
        XCTAssertEqual(decide(.popover, open: true, front: true), .closeWindow)
        XCTAssertEqual(decide(.popover, open: true), .raiseWindow)
    }

    /// A clicked notification opens or brings to the front, never closes.
    func testANotificationNeverCloses() {
        XCTAssertEqual(SurfaceToggle.forNotification(form: .popover, windowOpen: false), .openPopover)
        XCTAssertEqual(SurfaceToggle.forNotification(form: .window, windowOpen: false), .openWindow)
        XCTAssertEqual(SurfaceToggle.forNotification(form: .window, windowOpen: true), .raiseWindow, "in front or not: never closed")
    }

    /// In front: the app active, the window (or its sheet) key, not
    /// minimized, on the current Space; any one failing is not in front.
    func testInFront() {
        XCTAssertTrue(WindowFront.isFront(appActive: true, windowKey: true, sheetKey: false, miniaturized: false, onActiveSpace: true))
        XCTAssertFalse(WindowFront.isFront(appActive: false, windowKey: true, sheetKey: false, miniaturized: false, onActiveSpace: true), "another app")
        XCTAssertFalse(
            WindowFront.isFront(appActive: true, windowKey: false, sheetKey: false, miniaturized: false, onActiveSpace: true),
            "another window of the app is key (Settings), or Keep on top only keeps it above"
        )
        XCTAssertFalse(WindowFront.isFront(appActive: true, windowKey: true, sheetKey: false, miniaturized: true, onActiveSpace: true), "minimized")
        XCTAssertFalse(WindowFront.isFront(appActive: true, windowKey: true, sheetKey: false, miniaturized: false, onActiveSpace: false), "another Space")
        XCTAssertTrue(
            WindowFront.isFront(appActive: true, windowKey: false, sheetKey: true, miniaturized: false, onActiveSpace: true),
            "a key sheet counts as the window"
        )
    }

    /// A state gained at or after the press was gained by it.
    func testTheStateBeforeThePress() {
        XCTAssertFalse(StateAtPress.held(now: false, since: nil, pressedAt: 10))
        XCTAssertTrue(StateAtPress.held(now: true, since: nil, pressedAt: 10), "no time known: as it is now")
        XCTAssertTrue(StateAtPress.held(now: true, since: 9, pressedAt: 10))
        XCTAssertFalse(StateAtPress.held(now: true, since: 10, pressedAt: 10))
        XCTAssertFalse(StateAtPress.held(now: true, since: 10.2, pressedAt: 10))
        XCTAssertTrue(StateAtPress.held(now: true, since: 10.2, pressedAt: nil), "no press time (a hotkey): as it is now")
    }

    /// Settings and the About panel float while any open window, minimized
    /// ones included, has Keep on top on; the window closing does not count.
    func testTheLevelOfSettingsAndAbout() {
        XCTAssertEqual(AuxiliaryLevel.level(pinnedWindowOpen: true), .floating)
        XCTAssertEqual(AuxiliaryLevel.level(pinnedWindowOpen: false), .normal)
        XCTAssertEqual(AuxiliaryLevel.level(pins: [:]), .normal, "no window (the popover form)")
        XCTAssertEqual(AuxiliaryLevel.level(pins: ["1001": false]), .normal, "a window without the pin")
        XCTAssertEqual(AuxiliaryLevel.level(pins: ["1001": true]), .floating)
        XCTAssertEqual(AuxiliaryLevel.level(pins: ["1001": false, "1002": true]), .floating, "another account's pinned window")
        XCTAssertEqual(AuxiliaryLevel.level(pins: ["1001": true], closing: "1001"), .normal, "the pinned window closing")
        XCTAssertEqual(AuxiliaryLevel.level(pins: ["1001": true, "1002": true], closing: "1001"), .floating)
    }

    /// A saved size under the least one opens at it, the top and left edges
    /// staying (AppKit's frames: the origin at the bottom left).
    func testASmallSavedSizeOpensAtTheLeastSize() {
        let least = CGSize(width: 300, height: 359)
        XCTAssertEqual(
            WindowMinimum.frame(CGRect(x: 100, y: 500, width: 200, height: 250), minimum: least),
            CGRect(x: 100, y: 391, width: 300, height: 359)
        )
        XCTAssertEqual(WindowMinimum.frame(CGRect(x: 100, y: 500, width: 500, height: 700), minimum: least), CGRect(x: 100, y: 500, width: 500, height: 700))
        XCTAssertEqual(
            WindowMinimum.frame(CGRect(x: 10, y: 20, width: 600, height: 100), minimum: least),
            CGRect(x: 10, y: -239, width: 600, height: 359), "the height only"
        )
    }
}

final class RegularHoldTests: XCTestCase {
    /// `Open in popover`: the app stays regular until that popover closes;
    /// replaced by another account's popover, the hold goes on; with no
    /// popover left, it ends.
    func testThePopoverOpenInPopoverOpened() {
        var regular = RegularWindows()
        XCTAssertTrue(regular.opened("window:1001"))
        regular.holdPopover()
        XCTAssertFalse(regular.closed("window:1001"), "the window closed: still regular")
        XCTAssertTrue(regular.isRegular)
        XCTAssertFalse(regular.popoverClosed(replaced: true), "another account's popover took its place")
        XCTAssertTrue(regular.isRegular)
        XCTAssertTrue(regular.popoverClosed(replaced: false), "no popover: back to the accessory app")
        XCTAssertFalse(regular.isRegular)
        XCTAssertFalse(regular.popoverClosed(replaced: false), "nothing held any more")
    }

    /// Another window or Settings keeps the app regular after the popover
    /// closes.
    func testAnotherWindowOrSettingsKeepsItRegular() {
        var regular = RegularWindows()
        _ = regular.opened("window:1001")
        _ = regular.opened("settings")
        regular.holdPopover()
        _ = regular.closed("window:1001")
        XCTAssertFalse(regular.popoverClosed(replaced: false), "Settings is open")
        XCTAssertTrue(regular.isRegular)
        XCTAssertTrue(regular.closed("settings"))
    }

    /// From the held popover, `Open in window` and Settings add their
    /// window first: the app never goes through the accessory app.
    func testOpenInWindowAndSettingsFromTheHeldPopover() {
        for next in ["window:1001", "settings"] {
            var regular = RegularWindows()
            _ = regular.opened("window:1001")
            regular.holdPopover()
            _ = regular.closed("window:1001")
            XCTAssertFalse(regular.opened(next), "\(next): regular already, no switch")
            XCTAssertFalse(regular.popoverClosed(replaced: false), "\(next): the popover closes, still regular")
            XCTAssertTrue(regular.isRegular)
        }
    }

    /// Any other close goes back to the accessory app at once.
    func testOtherClosesEndAtOnce() {
        var regular = RegularWindows()
        _ = regular.opened("window:1001")
        XCTAssertTrue(regular.closed("window:1001"))
        XCTAssertFalse(regular.popoverClosed(replaced: false), "an ordinary popover holds nothing")
    }
}

@MainActor
final class SurfaceFormModelTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var api: FakeAPI!
    var model: AppModel!

    override func setUp() async throws {
        (defaults, suite) = testDefaults()
        api = FakeAPI()
        model = AppModel(api: api, store: UIStateStore(defaults: defaults), opener: FakeOpener(), notifier: FakeNotifier(), clock: { T0 })
        model.handle(.snapshot(accounts: [sampleAccount(), Account(id: "200001", login: "example-user")], keychain: .known(.ok), dbUnreadable: false))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// The popover unless the window is saved; per account; an unreadable
    /// value reads as the popover.
    func testTheFormIsSavedPerAccount() {
        let store = UIStateStore(defaults: defaults)
        XCTAssertEqual(store.surfaceForm(account: "1000001"), .popover, "nothing saved")
        store.setSurfaceForm(.window, account: "1000001")
        XCTAssertEqual(store.surfaceForm(account: "1000001"), .window)
        XCTAssertEqual(store.surfaceForm(account: "200001"), .popover, "the other account's stays")
        XCTAssertEqual(defaults.string(forKey: "v4.form.1000001"), "window")
        defaults.set("sheet", forKey: "v4.form.200001")
        XCTAssertEqual(store.surfaceForm(account: "200001"), .popover, "unreadable")
        defaults.set(3, forKey: "v4.form.200001")
        XCTAssertEqual(store.surfaceForm(account: "200001"), .popover, "not a string")
        store.setSurfaceForm(.popover, account: "1000001")
        XCTAssertEqual(defaults.string(forKey: "v4.form.1000001"), "popover")
    }

    /// Closing a surface does not change the form: only `Open in window`
    /// and `Open in popover` do.
    func testClosingKeepsTheForm() {
        model.store.setSurfaceForm(.window, account: "1000001")
        model.surfaceDisplayed(.window, account: "1000001", true, opening: true)
        model.surfaceOpened(.window, account: "1000001")
        model.surfaceClosed(.window, account: "1000001")
        model.surfaceDisplayed(.window, account: "1000001", false)
        XCTAssertEqual(model.store.surfaceForm(account: "1000001"), .window)
    }

    /// `account_removed` deletes the form and the global shortcut; an
    /// account missing from a snapshot (the database unreadable) keeps them.
    func testOnlyARemovedAccountLosesItsFormAndShortcut() {
        let store = model.store
        let shortcut = GlobalShortcut(keyCode: 0x31, modifiers: [.control, .option], keyName: "Space")
        for account in ["1000001", "200001"] {
            store.setSurfaceForm(.window, account: account)
            store.setShortcut(shortcut, account: account)
        }
        var removed: [String] = []
        model.onAccountRemoved = { removed.append($0) }
        model.handle(.snapshot(accounts: [], keychain: .known(.ok), dbUnreadable: true))
        XCTAssertEqual(store.surfaceForm(account: "1000001"), .window, "unreadable: kept")
        XCTAssertEqual(store.shortcut(account: "1000001"), shortcut)
        XCTAssertEqual(removed, [])
        model.handle(.snapshot(accounts: [sampleAccount(), Account(id: "200001", login: "example-user")], keychain: .known(.ok), dbUnreadable: false))
        model.handle(.accountRemoved("1000001"))
        XCTAssertEqual(removed, ["1000001"])
        XCTAssertEqual(store.surfaceForm(account: "1000001"), .popover)
        XCTAssertNil(store.shortcut(account: "1000001"))
        XCTAssertNil(defaults.object(forKey: "v4.form.1000001"))
        XCTAssertNil(defaults.object(forKey: "v4.shortcut.1000001"))
        XCTAssertEqual(store.surfaceForm(account: "200001"), .window, "the other account's stay")
        XCTAssertEqual(store.shortcut(account: "200001"), shortcut)
    }

    /// A notification shows the surface of the account's form; the open
    /// window when there is one.
    func testANotificationFollowsTheForm() {
        var shown: [String] = []
        model.onShowAccount = { shown.append("\($0) \($1)") }
        model.notificationClicked(type: .summary, account: "1000001", url: nil)
        XCTAssertEqual(shown.last, "1000001 popover")
        model.store.setSurfaceForm(.window, account: "1000001")
        model.notificationClicked(type: .summary, account: "1000001", url: nil)
        XCTAssertEqual(shown.last, "1000001 window", "the window form, closed: the window opens")
        model.notificationClicked(type: .single, account: "1000001", url: nil, pr: "example-org/api#402")
        XCTAssertEqual(shown.last, "1000001 window")
        model.notificationClicked(type: .summary, account: "200001", url: nil)
        XCTAssertEqual(shown.last, "200001 popover", "each account its own form")
    }

    // MARK: Switching the form

    func cards() async -> AccountViewModel {
        api.cards = sampleCards()
        let data = model.viewModel("1000001")
        data.reload()
        await settle()
        return data
    }

    /// The tab, the Dismissed list and the search text go to the other
    /// surface; the tab is kept as its last tab; the selection stays behind.
    func testTheSwitchCarriesTheTabTheDismissedListAndTheSearch() async {
        let data = await cards()
        for (from, to) in [(Surface.popover, Surface.window), (.window, .popover)] {
            for tab in ListTab.allCases {
                for dismissed in [false, true] {
                    let source = data.list(from)
                    let target = data.list(to)
                    model.surfaceDisplayed(from, account: "1000001", true, opening: true)
                    model.surfaceOpened(from, account: "1000001")
                    source.openTab(tab)
                    source.setSearch("api")
                    if dismissed { source.openDismissedList() }
                    let handoff = SurfaceHandoff.read(from: source)
                    // The source closes (a popover ends; a window closes).
                    model.surfaceClosed(from, account: "1000001")
                    if from == .window { model.surfaceDisplayed(.window, account: "1000001", false) }
                    model.surfaceDisplayed(from, account: "1000001", false)
                    XCTAssertFalse(source.showingDismissed, "closing drops the source's Dismissed list")
                    handoff.apply(to: target)
                    model.surfaceDisplayed(to, account: "1000001", true, opening: true)
                    model.surfaceOpened(to, account: "1000001")
                    XCTAssertEqual(target.tab, tab, "\(from) → \(to)")
                    XCTAssertEqual(target.showingDismissed, dismissed, "\(from) → \(to) \(tab)")
                    XCTAssertEqual(model.store.lastTab(account: "1000001", surface: to), tab, "kept as the last tab")
                    XCTAssertEqual(target.data.search(.tab(tab)), "api", "the account's search text")
                    XCTAssertNil(target.selection, "no selection carried")
                    if dismissed { target.closeDismissedList() }
                    model.surfaceClosed(to, account: "1000001")
                    if to == .window { model.surfaceDisplayed(.window, account: "1000001", false) }
                    model.surfaceDisplayed(to, account: "1000001", false)
                    source.setSearch("")
                }
            }
        }
    }

    /// The selection of the source is not carried.
    func testTheSelectionStaysBehind() async {
        let data = await cards()
        let popover = data.list(.popover)
        model.surfaceDisplayed(.popover, account: "1000001", true, opening: true)
        popover.openTab(.review)
        popover.select(.header(card: "T1"))
        let handoff = SurfaceHandoff.read(from: popover)
        XCTAssertEqual(handoff, SurfaceHandoff(tab: .review, dismissed: false))
        model.surfaceClosed(.popover, account: "1000001")
        model.surfaceDisplayed(.popover, account: "1000001", false)
        let window = data.list(.window)
        handoff.apply(to: window)
        model.surfaceDisplayed(.window, account: "1000001", true, opening: true)
        XCTAssertEqual(window.tab, .review)
        XCTAssertNil(window.selection)
        XCTAssertTrue(window.selectedCards.isEmpty)
    }
}

extension FilterModelTests {
    /// A switch of form is a close: a card `Unread only` kept after it was
    /// read does not show on the other surface.
    func testASwitchOfFormDropsTheCardsUnreadOnlyKept() async {
        let list = await unreadOnly()
        list.select(.row(id: "u1", card: "U1"))
        await settle()
        list.select(.header(card: "U2"))
        await settle()
        XCTAssertEqual(list.lingering, ["U1"])
        let handoff = SurfaceHandoff.read(from: list)
        model.surfaceClosed(.popover, account: "1000001")
        show(.popover, false)
        let window = list.data.list(.window)
        handoff.apply(to: window)
        show(.window, true)
        XCTAssertEqual(window.tab, .review)
        XCTAssertFalse(ids(window).contains("U1"), "read before the switch: not shown")
        XCTAssertEqual(window.lingering, [])
    }
}
