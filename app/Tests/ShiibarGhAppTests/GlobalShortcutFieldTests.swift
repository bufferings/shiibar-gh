// The Global shortcut row of Settings › Accounts › an account (DESIGN.md,
// "Settings › Accounts", "Global shortcut field", "Constants"; Settings.html
// `.gsk`): after Menu bar icon color, the field's texts, its size, the ×.
// A spy registrar: no real hotkey is registered; no window is shown.

import AppKit
@testable import ShiibarGhApp
@testable import ShiibarGhCore
import SwiftUI
import XCTest

@MainActor
final class FieldSpyRegistrar: HotKeyRegistering {
    var onPressed: (UInt32) -> Void = { _ in }
    var live: [UInt32: GlobalShortcut] = [:]

    func register(_ shortcut: GlobalShortcut, id: UInt32) -> Bool {
        live[id] = shortcut
        return true
    }

    func unregister(id: UInt32) { live[id] = nil }
}

@MainActor
final class GlobalShortcutFieldTests: XCTestCase {
    static var kept: [AnyObject] = []

    func center() -> GlobalShortcutCenter {
        let center = GlobalShortcutCenter(store: UIStateStore(defaults: ScratchDefaults()), registrar: FieldSpyRegistrar())
        center.accountsListed(["1001"])
        Self.kept.append(center)
        return center
    }

    /// `Record Shortcut`, `Type shortcut` while recording, the combination
    /// with × once registered; 22 points high, at least 120 wide; the name
    /// `Global shortcut` with the field's text as its value.
    func testTheFieldsTexts() {
        let center = center()
        XCTAssertEqual(GlobalShortcutField.height, 22)
        XCTAssertEqual(GlobalShortcutField.minimumWidth, 120)
        XCTAssertEqual(GlobalShortcutField.radius, 6)
        XCTAssertEqual(GlobalShortcutField.side, 8)
        XCTAssertEqual(GlobalShortcutField.clearSize, 12)
        XCTAssertEqual(GlobalShortcutField.label, "Global shortcut")
        XCTAssertEqual(GlobalShortcutField.clearLabel, "Clear shortcut")
        XCTAssertEqual(SettingsText.shortcutDetail, "Opens this account's popover or window from any app.")
        func fitting() -> CGSize { NSHostingView(rootView: GlobalShortcutField(center: center, account: "1001")).fittingSize }
        XCTAssertEqual(center.fieldText("1001"), "Record Shortcut")
        XCTAssertEqual(fitting().height, 22)
        XCTAssertEqual(fitting().width, 120, "the least width")
        center.fieldClicked("1001")
        XCTAssertEqual(center.fieldText("1001"), "Type shortcut")
        XCTAssertFalse(center.showsClear("1001"))
        center.keyPressed(keyCode: 0x31, modifiers: [.control, .option], keyName: "Space")
        XCTAssertEqual(center.fieldText("1001"), "\u{2303}\u{2325}Space")
        XCTAssertTrue(center.showsClear("1001"))
        XCTAssertEqual(fitting().height, 22)
        XCTAssertGreaterThanOrEqual(fitting().width, 120)
        center.clear("1001")
        XCTAssertEqual(center.fieldText("1001"), "Record Shortcut")
        // A long name widens it, within the right column's 240 points.
        center.fieldClicked("1001")
        center.keyPressed(keyCode: 0x2B, modifiers: [.control, .option, .shift, .command], keyName: String(repeating: "W", count: 40))
        XCTAssertLessThanOrEqual(fitting().width, 240)
    }
}
