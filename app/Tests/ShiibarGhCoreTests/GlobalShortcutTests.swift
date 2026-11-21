// The global shortcuts (DESIGN.md, "Global shortcut", "Global shortcut
// field", "Saving state"): which combinations can be registered, how they
// read and are saved, and the recording with the registrations behind it.
// A spy registrar stands in for Carbon: no real hotkey is registered.

import Foundation
@testable import ShiibarGhCore
import XCTest

/// Records the registrations; `refuse` makes the system refuse the next
/// registrations of these combinations.
@MainActor
final class SpyRegistrar: HotKeyRegistering {
    var onPressed: (UInt32) -> Void = { _ in }
    private(set) var live: [UInt32: GlobalShortcut] = [:]
    private(set) var log: [String] = []
    var refuse: Set<String> = []

    func register(_ shortcut: GlobalShortcut, id: UInt32) -> Bool {
        log.append("register \(id) \(shortcut.displayString)")
        if refuse.contains(shortcut.displayString) { return false }
        // The system refuses the same combination twice in one app.
        if live.values.contains(where: { $0.sameCombination(as: shortcut) }) { return false }
        live[id] = shortcut
        return true
    }

    func unregister(id: UInt32) {
        log.append("unregister \(id)")
        live[id] = nil
    }

    func press(_ id: UInt32) { onPressed(id) }
}

final class GlobalShortcutValueTests: XCTestCase {
    let space: UInt16 = 0x31
    let k: UInt16 = 0x28
    let f5: UInt16 = 0x60

    func testWhatCanBeRegistered() {
        XCTAssertEqual(GlobalShortcutValidation.validate(keyCode: k, modifiers: []), .needsModifier, "no modifier")
        XCTAssertEqual(GlobalShortcutValidation.validate(keyCode: k, modifiers: [.shift]), .needsModifier, "⇧ alone")
        for modifier in [ShortcutModifiers.control, .option, .command] {
            XCTAssertEqual(GlobalShortcutValidation.validate(keyCode: k, modifiers: [modifier]), .valid)
            XCTAssertEqual(GlobalShortcutValidation.validate(keyCode: k, modifiers: [modifier, .shift]), .valid)
        }
        for key in ShortcutKeys.functionKeys {
            XCTAssertEqual(GlobalShortcutValidation.validate(keyCode: key, modifiers: []), .valid, "F1–F20 alone")
            XCTAssertEqual(GlobalShortcutValidation.validate(keyCode: key, modifiers: [.shift]), .valid)
        }
        XCTAssertEqual(ShortcutKeys.functionKeys.count, 20)
        // Keys past F20 and the other non-character keys need a modifier.
        XCTAssertEqual(GlobalShortcutValidation.validate(keyCode: 0x72, modifiers: []), .needsModifier, "Help")
        XCTAssertEqual(GlobalShortcutValidation.validate(keyCode: 0x7B, modifiers: [.shift]), .needsModifier, "←")
    }

    func testHowItReads() {
        XCTAssertEqual(GlobalShortcut(keyCode: space, modifiers: [.option, .control], keyName: "Space").displayString, "\u{2303}\u{2325}Space")
        XCTAssertEqual(GlobalShortcut(keyCode: k, modifiers: [.command, .shift], keyName: "K").displayString, "\u{21E7}\u{2318}K")
        XCTAssertEqual(
            GlobalShortcut(keyCode: k, modifiers: [.command, .shift, .option, .control], keyName: "K").displayString,
            "\u{2303}\u{2325}\u{21E7}\u{2318}K", "⌃⌥⇧⌘"
        )
        XCTAssertEqual(GlobalShortcut(keyCode: f5, modifiers: [], keyName: "F5").displayString, "F5")
        XCTAssertEqual(ShortcutKeys.keyName(keyCode: space, characters: " "), "Space")
        XCTAssertEqual(ShortcutKeys.keyName(keyCode: f5, characters: "\u{F708}"), "F5")
        XCTAssertEqual(ShortcutKeys.keyName(keyCode: 0x7E, characters: "\u{F700}"), "\u{2191}", "the menu's symbol")
        XCTAssertEqual(ShortcutKeys.keyName(keyCode: 0x24, characters: "\r"), "\u{21A9}")
        XCTAssertEqual(ShortcutKeys.keyName(keyCode: k, characters: "k"), "K", "the layout's character, uppercased")
        XCTAssertEqual(ShortcutKeys.keyName(keyCode: 0x1E, characters: "ü"), "Ü")
        XCTAssertNil(ShortcutKeys.keyName(keyCode: 0x72, characters: "\u{F746}"), "no name: not recorded")
        XCTAssertNil(ShortcutKeys.keyName(keyCode: 0x0A, characters: nil))
        XCTAssertNil(ShortcutKeys.keyName(keyCode: 0x0A, characters: "\u{1B}"))
    }

    func testTheSavedForm() {
        let shortcut = GlobalShortcut(keyCode: k, modifiers: [.shift, .command], keyName: "K")
        let text = GlobalShortcutCodec.encode(shortcut)
        XCTAssertEqual(text, #"{"keyCode":40,"keyName":"K","modifiers":["shift","command"]}"#)
        XCTAssertEqual(GlobalShortcutCodec.decode(text), shortcut)
        XCTAssertNil(GlobalShortcutCodec.decode(nil))
        XCTAssertNil(GlobalShortcutCodec.decode(42))
        XCTAssertNil(GlobalShortcutCodec.decode("not json"))
        XCTAssertNil(GlobalShortcutCodec.decode(#"{"keyCode":40,"keyName":"","modifiers":["command"]}"#), "no name")
        XCTAssertNil(GlobalShortcutCodec.decode(#"{"keyCode":40,"keyName":"K","modifiers":["hyper"]}"#), "an unknown modifier")
        XCTAssertNil(GlobalShortcutCodec.decode(#"{"keyCode":40,"keyName":"K","modifiers":["shift"]}"#), "cannot be registered")
        XCTAssertNotNil(GlobalShortcutCodec.decode(#"{"keyCode":96,"keyName":"F5","modifiers":[]}"#))
    }

    func testTheSameCombinationIgnoresTheName() {
        let a = GlobalShortcut(keyCode: k, modifiers: [.command], keyName: "K")
        XCTAssertTrue(a.sameCombination(as: GlobalShortcut(keyCode: k, modifiers: [.command], keyName: "Q")))
        XCTAssertFalse(a.sameCombination(as: GlobalShortcut(keyCode: k, modifiers: [.command, .shift], keyName: "K")))
        XCTAssertFalse(a.sameCombination(as: GlobalShortcut(keyCode: 0x0C, modifiers: [.command], keyName: "K")))
    }

    func testTheHints() {
        XCTAssertEqual(GlobalShortcutHint.addModifier.text, "Add \u{2303}, \u{2325}, or \u{2318} to the shortcut")
        XCTAssertEqual(GlobalShortcutHint.alreadyInUse.text, "This shortcut is already in use")
    }
}

@MainActor
final class GlobalShortcutCenterTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var store: UIStateStore!
    var spy: SpyRegistrar!

    let ctrlOptSpace = GlobalShortcut(keyCode: 0x31, modifiers: [.control, .option], keyName: "Space")
    let cmdShiftK = GlobalShortcut(keyCode: 0x28, modifiers: [.command, .shift], keyName: "K")

    override func setUp() async throws {
        (defaults, suite) = testDefaults()
        store = UIStateStore(defaults: defaults)
        spy = SpyRegistrar()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func center(_ accounts: [String] = ["a", "b"]) -> GlobalShortcutCenter {
        let center = GlobalShortcutCenter(store: store, registrar: spy)
        center.accountsListed(accounts)
        return center
    }

    func press(_ center: GlobalShortcutCenter, _ shortcut: GlobalShortcut) {
        center.keyPressed(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, keyName: shortcut.keyName)
    }

    /// At launch, the saved values of the listed accounts are registered;
    /// one the system refuses keeps its value and reads `Record Shortcut`.
    func testLaunch() {
        store.setShortcut(ctrlOptSpace, account: "a")
        store.setShortcut(cmdShiftK, account: "b")
        spy.refuse = [cmdShiftK.displayString]
        let center = center()
        XCTAssertEqual(Set(spy.live.values), [ctrlOptSpace])
        XCTAssertEqual(center.fieldText("a"), "\u{2303}\u{2325}Space")
        XCTAssertTrue(center.showsClear("a"))
        XCTAssertEqual(center.fieldText("b"), "Record Shortcut", "refused at launch")
        XCTAssertFalse(center.showsClear("b"))
        XCTAssertEqual(store.shortcut(account: "b"), cmdShiftK, "the value stays")
        XCTAssertEqual(center.fieldText("c"), "Record Shortcut", "none saved")
    }

    /// Recording suspends every registration; a valid combination is
    /// registered and saved, and the others come back.
    func testRecordingASuccess() {
        store.setShortcut(cmdShiftK, account: "b")
        let center = center()
        center.fieldClicked("a")
        XCTAssertEqual(center.fieldText("a"), "Type shortcut")
        XCTAssertFalse(center.showsClear("a"), "no × while recording")
        XCTAssertTrue(spy.live.isEmpty, "every registration suspended")
        XCTAssertEqual(center.fieldText("b"), "\u{21E7}\u{2318}K", "the others still read their combination")
        press(center, ctrlOptSpace)
        XCTAssertNil(center.recording)
        XCTAssertEqual(store.shortcut(account: "a"), ctrlOptSpace)
        XCTAssertEqual(spy.live[center.id(of: "a")], ctrlOptSpace)
        XCTAssertEqual(spy.live[center.id(of: "b")], cmdShiftK, "back")
        XCTAssertNil(center.hints["a"])
        XCTAssertTrue(center.showsClear("a"))
    }

    /// Without ⌃, ⌥ or ⌘ (but F1–F20): the hint, still recording.
    func testAModifierIsNeeded() {
        let center = center()
        center.fieldClicked("a")
        center.keyPressed(keyCode: 0x28, modifiers: [], keyName: "K")
        XCTAssertEqual(center.hints["a"], .addModifier)
        XCTAssertEqual(center.recording, "a")
        center.keyPressed(keyCode: 0x28, modifiers: [.shift], keyName: "K")
        XCTAssertEqual(center.recording, "a")
        XCTAssertTrue(spy.live.isEmpty)
        center.keyPressed(keyCode: 0x60, modifiers: [], keyName: "F5")
        XCTAssertNil(center.recording)
        XCTAssertNil(center.hints["a"], "a success clears it")
        XCTAssertEqual(store.shortcut(account: "a")?.displayString, "F5")
    }

    /// Another listed account's saved combination (key code and modifiers,
    /// whatever the name, registered or not) is refused before registering:
    /// recording ends, the previous value and registration stay.
    func testAnotherAccountsCombinationIsRefused() {
        store.setShortcut(cmdShiftK, account: "a")
        store.setShortcut(ctrlOptSpace, account: "b")
        // b's registration fails at launch: its saved value still counts.
        spy.refuse = [ctrlOptSpace.displayString]
        let center = center()
        spy.refuse = []
        XCTAssertNil(spy.live[center.id(of: "b")])
        center.fieldClicked("a")
        center.keyPressed(keyCode: 0x31, modifiers: [.option, .control], keyName: "Leertaste")
        XCTAssertNil(center.recording)
        XCTAssertEqual(center.hints["a"], .alreadyInUse)
        XCTAssertEqual(store.shortcut(account: "a"), cmdShiftK, "the previous value")
        XCTAssertEqual(spy.live[center.id(of: "a")], cmdShiftK, "and its registration")
        XCTAssertEqual(center.fieldText("a"), "\u{21E7}\u{2318}K")
        // The next recording clears the line.
        center.fieldClicked("a")
        XCTAssertNil(center.hints["a"])
    }

    /// The order of registration does not matter: the same refusal either
    /// way round.
    func testTheRefusalDoesNotDependOnTheOrder() {
        for order in [["a", "b"], ["b", "a"]] {
            let (defaults, suite) = testDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = UIStateStore(defaults: defaults)
            store.setShortcut(ctrlOptSpace, account: "a")
            let center = GlobalShortcutCenter(store: store, registrar: SpyRegistrar())
            center.accountsListed(order)
            center.fieldClicked("b")
            press(center, ctrlOptSpace)
            XCTAssertEqual(center.hints["b"], .alreadyInUse, "\(order)")
            XCTAssertNil(store.shortcut(account: "b"))
        }
    }

    /// An account not in the list does not count: its saved value is not
    /// compared.
    func testAnAccountOutOfTheListDoesNotCount() {
        store.setShortcut(ctrlOptSpace, account: "gone")
        let center = center(["a"])
        center.fieldClicked("a")
        press(center, ctrlOptSpace)
        XCTAssertNil(center.hints["a"])
        XCTAssertEqual(store.shortcut(account: "a"), ctrlOptSpace)
    }

    /// The system refuses: the same line, the previous value kept.
    func testTheSystemRefuses() {
        store.setShortcut(cmdShiftK, account: "a")
        let center = center()
        spy.refuse = [ctrlOptSpace.displayString]
        center.fieldClicked("a")
        press(center, ctrlOptSpace)
        XCTAssertEqual(center.hints["a"], .alreadyInUse)
        XCTAssertNil(center.recording)
        XCTAssertEqual(store.shortcut(account: "a"), cmdShiftK)
        XCTAssertEqual(spy.live[center.id(of: "a")], cmdShiftK)
    }

    /// Esc (with or without modifiers), a press outside, Settings no longer
    /// key: recording stops, the line goes, the registrations come back.
    func testCancelling() {
        store.setShortcut(cmdShiftK, account: "a")
        store.setShortcut(ctrlOptSpace, account: "b")
        let center = center()
        for escape in [ShortcutModifiers(), [.command]] {
            center.fieldClicked("a")
            center.keyPressed(keyCode: 0x28, modifiers: [], keyName: "K")
            XCTAssertEqual(center.hints["a"], .addModifier)
            center.keyPressed(keyCode: ShortcutKeys.escape, modifiers: escape, keyName: nil)
            XCTAssertNil(center.recording)
            XCTAssertNil(center.hints["a"], "a cancel clears it")
            XCTAssertEqual(Set(spy.live.values), [cmdShiftK, ctrlOptSpace])
        }
        center.fieldClicked("a")
        center.abandonRecording()
        XCTAssertNil(center.recording)
        XCTAssertEqual(store.shortcut(account: "a"), cmdShiftK)
        XCTAssertEqual(Set(spy.live.values), [cmdShiftK, ctrlOptSpace])
        // A press on another account's field ends the first recording.
        center.fieldClicked("a")
        center.fieldClicked("b")
        XCTAssertEqual(center.recording, "b")
        XCTAssertTrue(spy.live.isEmpty)
        center.abandonRecording()
        XCTAssertEqual(Set(spy.live.values), [cmdShiftK, ctrlOptSpace])
    }

    /// A key without a name is not recorded.
    func testAKeyWithoutANameIsIgnored() {
        let center = center()
        center.fieldClicked("a")
        center.keyPressed(keyCode: 0x72, modifiers: [.command], keyName: nil)
        XCTAssertEqual(center.recording, "a")
        XCTAssertNil(store.shortcut(account: "a"))
    }

    /// × unregisters and deletes.
    func testClear() {
        store.setShortcut(cmdShiftK, account: "a")
        let center = center()
        center.clear("a")
        XCTAssertNil(store.shortcut(account: "a"))
        XCTAssertTrue(spy.live.isEmpty)
        XCTAssertEqual(center.fieldText("a"), "Record Shortcut")
        XCTAssertFalse(center.showsClear("a"))
    }

    /// Only the listed accounts are registered: one that leaves the list is
    /// unregistered and keeps its value, and is registered when it comes
    /// back; `account_removed` deletes.
    func testTheAccountList() {
        store.setShortcut(cmdShiftK, account: "a")
        store.setShortcut(ctrlOptSpace, account: "b")
        let center = center(["a"])
        XCTAssertEqual(Set(spy.live.values), [cmdShiftK], "b is not listed")
        center.accountsListed([])
        XCTAssertTrue(spy.live.isEmpty, "the database unreadable: none listed")
        XCTAssertEqual(store.shortcut(account: "a"), cmdShiftK, "the value stays")
        center.accountsListed(["a", "b"])
        XCTAssertEqual(Set(spy.live.values), [cmdShiftK, ctrlOptSpace])
        center.accountRemoved("a")
        store.forgetRemovedAccount("a")
        XCTAssertEqual(Set(spy.live.values), [ctrlOptSpace])
        XCTAssertNil(store.shortcut(account: "a"))
        XCTAssertEqual(center.fieldText("a"), "Record Shortcut")
    }

    /// An account that comes while a field records is registered when the
    /// recording ends.
    func testAnAccountComingWhileRecording() {
        store.setShortcut(ctrlOptSpace, account: "b")
        let center = center(["a"])
        center.fieldClicked("a")
        center.accountsListed(["a", "b"])
        XCTAssertTrue(spy.live.isEmpty)
        center.abandonRecording()
        XCTAssertEqual(Set(spy.live.values), [ctrlOptSpace])
    }

    /// A combination that cannot be registered again after recording
    /// shows as unregistered.
    func testOneThatCannotComeBack() {
        store.setShortcut(cmdShiftK, account: "b")
        let center = center()
        center.fieldClicked("a")
        spy.refuse = [cmdShiftK.displayString]
        center.abandonRecording()
        XCTAssertEqual(center.fieldText("b"), "Record Shortcut")
        XCTAssertEqual(store.shortcut(account: "b"), cmdShiftK, "the value stays")
    }

    /// The pressed hotkey's id names the account; nothing while recording.
    func testThePressedIdNamesTheAccount() {
        store.setShortcut(cmdShiftK, account: "a")
        store.setShortcut(ctrlOptSpace, account: "b")
        let center = center()
        var pressed: [String] = []
        center.onPressed = { pressed.append($0) }
        spy.press(center.id(of: "b"))
        spy.press(center.id(of: "a"))
        spy.press(999)
        XCTAssertEqual(pressed, ["b", "a"])
        XCTAssertNotEqual(center.id(of: "a"), center.id(of: "b"))
        center.fieldClicked("a")
        spy.press(center.id(of: "b"))
        XCTAssertEqual(pressed, ["b", "a"], "recording: nothing")
    }

    /// The measurement mode registers nothing.
    func testTheMeasurementModeRegistersNothing() {
        store.setShortcut(cmdShiftK, account: "a")
        let center = GlobalShortcutCenter(store: store, registrar: spy, enabled: false)
        center.accountsListed(["a"])
        center.fieldClicked("a")
        XCTAssertTrue(spy.log.isEmpty)
    }

    /// Quitting: nothing stays registered.
    func testQuitting() {
        store.setShortcut(cmdShiftK, account: "a")
        store.setShortcut(ctrlOptSpace, account: "b")
        let center = center()
        center.unregisterAll()
        XCTAssertTrue(spy.live.isEmpty)
    }
}

extension GlobalShortcutCenterTests {
    /// Settings selected another account (or an owner): the recording ends
    /// and the registrations come back; selecting the recording account
    /// keeps it.
    func testSelectingAnotherRowCancelsTheRecording() {
        store.setShortcut(cmdShiftK, account: "a")
        store.setShortcut(ctrlOptSpace, account: "b")
        let center = center()
        center.fieldClicked("a")
        center.selectionChanged(to: "a")
        XCTAssertEqual(center.recording, "a", "the same account: still recording")
        XCTAssertTrue(spy.live.isEmpty)
        center.selectionChanged(to: "b")
        XCTAssertNil(center.recording)
        XCTAssertEqual(Set(spy.live.values), [cmdShiftK, ctrlOptSpace], "nothing left suspended")
        center.fieldClicked("b")
        center.selectionChanged(to: nil)
        XCTAssertNil(center.recording, "an owner selected")
        XCTAssertEqual(Set(spy.live.values), [cmdShiftK, ctrlOptSpace])
    }
}
