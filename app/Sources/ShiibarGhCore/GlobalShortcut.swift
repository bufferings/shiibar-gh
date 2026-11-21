// The global shortcut of each account (DESIGN.md, "Open in window", "Global
// shortcut"; "Settings › Accounts", "Global shortcut field"): which key
// combinations can be registered, how one is shown and saved, and the
// recording of the Settings field with the registrations behind it. The
// system registration (Carbon `RegisterEventHotKey`) and the key capture
// live in the app; tests give `GlobalShortcutCenter` a spy registrar.

import Combine
import Foundation

/// The modifier keys of a shortcut: any combination of ⌃, ⌥, ⇧ and ⌘.
public struct ShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)

    public static let all: ShortcutModifiers = [.control, .option, .shift, .command]

    /// The symbols in the order ⌃ ⌥ ⇧ ⌘.
    public var symbols: String {
        var out = ""
        if contains(.control) { out += "\u{2303}" }
        if contains(.option) { out += "\u{2325}" }
        if contains(.shift) { out += "\u{21E7}" }
        if contains(.command) { out += "\u{2318}" }
        return out
    }
}

/// A recorded key combination: the virtual key code (`kVK_*`, what the
/// system matches, whatever the keyboard layout), the modifiers, and the
/// key's name as the layout typed it when it was recorded.
public struct GlobalShortcut: Equatable, Hashable, Sendable {
    public let keyCode: UInt16
    public let modifiers: ShortcutModifiers
    public let keyName: String

    public init(keyCode: UInt16, modifiers: ShortcutModifiers, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.all)
        self.keyName = keyName
    }

    /// The modifier symbols then the key's name: `⌃⌥Space`, `⇧⌘K`.
    public var displayString: String { modifiers.symbols + keyName }

    public var validation: GlobalShortcutValidation {
        GlobalShortcutValidation.validate(keyCode: keyCode, modifiers: modifiers)
    }

    /// The same combination for the system: the key code and the
    /// modifiers. The name is not compared (it depends on the layout at the
    /// time of recording).
    public func sameCombination(as other: GlobalShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

/// A combination without ⌃, ⌥ or ⌘ (no modifier, or ⇧ alone) is allowed on
/// a function key (F1–F20) only: on another key it could stop that key's
/// typing in every app.
public enum GlobalShortcutValidation: Equatable, Sendable {
    case valid
    case needsModifier

    public static func validate(keyCode: UInt16, modifiers: ShortcutModifiers) -> GlobalShortcutValidation {
        if !modifiers.intersection([.control, .option, .command]).isEmpty { return .valid }
        return ShortcutKeys.isFunctionKey(keyCode) ? .valid : .needsModifier
    }
}

/// The line under the field.
public enum GlobalShortcutHint: Equatable, Sendable {
    /// A combination that cannot be registered was pressed; recording goes on.
    case addModifier
    /// Another account in the list saved the same combination, or the
    /// system refused it.
    case alreadyInUse

    public var text: String {
        switch self {
        case .addModifier: return "Add \u{2303}, \u{2325}, or \u{2318} to the shortcut"
        case .alreadyInUse: return "This shortcut is already in use"
        }
    }
}

/// Virtual key codes (`kVK_*`, HIToolbox `Events.h`) and the keys' names.
public enum ShortcutKeys {
    public static let escape: UInt16 = 0x35

    /// F1–F20 in order (`kVK_F1` … `kVK_F20`).
    public static let functionKeys: [UInt16] = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]

    public static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeys.contains(keyCode)
    }

    /// The keys that type no character: `Space`, F1–F20, and the symbols
    /// menus show for the others.
    private static let fixedNames: [UInt16: String] = {
        var names: [UInt16: String] = [
            0x31: "Space",
            0x24: "\u{21A9}",  // Return
            0x4C: "\u{2324}",  // keypad Enter
            0x30: "\u{21E5}",  // Tab
            0x33: "\u{232B}",  // Delete
            0x75: "\u{2326}",  // Forward Delete
            0x7B: "\u{2190}",  // Left Arrow
            0x7C: "\u{2192}",  // Right Arrow
            0x7E: "\u{2191}",  // Up Arrow
            0x7D: "\u{2193}",  // Down Arrow
            0x73: "\u{2196}",  // Home
            0x77: "\u{2198}",  // End
            0x74: "\u{21DE}",  // Page Up
            0x79: "\u{21DF}",  // Page Down
            0x47: "\u{2327}",  // keypad Clear
        ]
        for (index, code) in functionKeys.enumerated() {
            names[code] = "F\(index + 1)"
        }
        return names
    }()

    /// The name to save for a pressed key: a fixed name for the keys above,
    /// else the character the keyboard layout types for the key without
    /// modifiers, uppercased. Nil when the key has neither (no character,
    /// a control character, or AppKit's private-use function-key
    /// characters): such a key is not recorded.
    public static func keyName(keyCode: UInt16, characters: String?) -> String? {
        if let fixed = fixedNames[keyCode] { return fixed }
        guard let characters else { return nil }
        let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !trimmed.unicodeScalars.contains(where: { (0xE000...0xF8FF).contains($0.value) })
        else { return nil }
        return trimmed.uppercased()
    }
}

/// The saved form: a JSON string,
/// `{"keyCode":40,"keyName":"K","modifiers":["shift","command"]}`. A value
/// that does not decode, or decodes to a combination that cannot be
/// registered, reads as none.
public enum GlobalShortcutCodec {
    private struct Stored: Codable {
        let keyCode: UInt16
        let modifiers: [String]
        let keyName: String
    }

    private static let modifierNames: [(ShortcutModifiers, String)] = [
        (.control, "control"), (.option, "option"), (.shift, "shift"), (.command, "command"),
    ]

    public static func encode(_ shortcut: GlobalShortcut) -> String {
        let stored = Stored(
            keyCode: shortcut.keyCode,
            modifiers: modifierNames.filter { shortcut.modifiers.contains($0.0) }.map(\.1),
            keyName: shortcut.keyName
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(stored)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// `raw` is the UserDefaults object as read, of any type.
    public static func decode(_ raw: Any?) -> GlobalShortcut? {
        guard let string = raw as? String,
              let stored = try? JSONDecoder().decode(Stored.self, from: Data(string.utf8)),
              !stored.keyName.isEmpty
        else { return nil }
        var modifiers: ShortcutModifiers = []
        for name in stored.modifiers {
            guard let modifier = modifierNames.first(where: { $0.1 == name })?.0 else { return nil }
            modifiers.insert(modifier)
        }
        let shortcut = GlobalShortcut(keyCode: stored.keyCode, modifiers: modifiers, keyName: stored.keyName)
        return shortcut.validation == .valid ? shortcut : nil
    }
}

/// Registers system-wide hotkeys, one per id. The app's registrar uses
/// Carbon `RegisterEventHotKey`; tests use a spy.
@MainActor
public protocol HotKeyRegistering: AnyObject {
    /// Called on the main actor with the id of the pressed hotkey.
    var onPressed: (UInt32) -> Void { get set }
    /// False when the system refuses it (nothing is registered then).
    func register(_ shortcut: GlobalShortcut, id: UInt32) -> Bool
    func unregister(id: UInt32)
}

/// The global shortcuts of the accounts and the Settings field's recording
/// (DESIGN.md, "Global shortcut", "Global shortcut field"):
///
/// - Only the accounts in the account list (the one the daemon sent) are
///   registered. An account that leaves the list (an unreadable database
///   included) is unregistered and keeps its value; it is registered again
///   when it comes back. Only `account_removed` deletes the value.
/// - A registration that fails keeps the saved value, unregistered: the
///   field shows `Record Shortcut`.
/// - While a field records, every registration of the app is suspended; when
///   recording ends, the others are registered again, and the recording
///   account gets its new combination or, cancelled or refused, its
///   previous one.
/// - A combination saved by another account in the list (the key code and
///   the modifiers), registered or not, is refused before registering, so
///   the order of registration never changes the outcome.
@MainActor
public final class GlobalShortcutCenter: ObservableObject {
    public static let recordText = "Record Shortcut"
    public static let recordingText = "Type shortcut"

    /// The account whose field records.
    @Published public private(set) var recording: String?
    /// The line under each account's field.
    @Published public private(set) var hints: [String: GlobalShortcutHint] = [:]
    /// What each field shows: the combination registered, or suspended
    /// while a field records.
    @Published public private(set) var active: [String: GlobalShortcut] = [:]
    /// Registered with the system now.
    public private(set) var registered: Set<String> = []
    private var listed: [String] = []
    private var ids: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private let store: UIStateStore
    private let registrar: HotKeyRegistering
    /// False in the measurement mode: nothing is registered.
    private let enabled: Bool

    /// A registered shortcut was pressed: the account's.
    public var onPressed: ((String) -> Void)?

    public init(store: UIStateStore, registrar: HotKeyRegistering, enabled: Bool = true) {
        self.store = store
        self.registrar = registrar
        self.enabled = enabled
        registrar.onPressed = { [weak self] id in
            guard let self, self.recording == nil, let account = self.ids.first(where: { $0.value == id })?.key else { return }
            self.onPressed?(account)
        }
    }

    public func id(of account: String) -> UInt32 {
        if let id = ids[account] { return id }
        let id = nextID
        nextID += 1
        ids[account] = id
        return id
    }

    // MARK: - The field

    public func fieldText(_ account: String) -> String {
        if recording == account { return Self.recordingText }
        return active[account]?.displayString ?? Self.recordText
    }

    public func showsClear(_ account: String) -> Bool {
        recording != account && active[account] != nil
    }

    public func isRecording(_ account: String) -> Bool {
        recording == account
    }

    // MARK: - The account list

    /// The account list the daemon sent (empty while the database cannot
    /// be read). Accounts that came are registered, accounts that left are
    /// unregistered; their values stay.
    public func accountsListed(_ accounts: [String]) {
        guard enabled else { return }
        let before = Set(listed)
        listed = accounts
        let now = Set(accounts)
        for account in before.subtracting(now) {
            if recording == account { abandonRecording() }
            unregister(account)
            active[account] = nil
        }
        guard recording == nil else {
            // Registered once recording ends.
            for account in accounts where !before.contains(account) {
                if let saved = store.shortcut(account: account) { active[account] = saved }
            }
            return
        }
        for account in accounts where !before.contains(account) {
            guard let saved = store.shortcut(account: account) else { continue }
            active[account] = register(saved, account: account) ? saved : nil
        }
    }

    /// `account_removed`: unregistered and forgotten (the saved value is
    /// deleted with the account's other values, `UIStateStore`).
    public func accountRemoved(_ account: String) {
        if recording == account { abandonRecording() }
        unregister(account)
        active[account] = nil
        hints[account] = nil
        listed.removeAll { $0 == account }
    }

    // MARK: - Recording

    /// A press on the field: recording starts; every registration is
    /// suspended. A field recording for another account is cancelled first
    /// (the press is outside it).
    public func fieldClicked(_ account: String) {
        guard enabled, recording != account else { return }
        if recording != nil { abandonRecording() }
        recording = account
        hints[account] = nil
        for other in registered { registrar.unregister(id: id(of: other)) }
        registered = []
    }

    /// A key pressed while recording. `keyName` is nil for a key without a
    /// name (`ShortcutKeys.keyName`), which is not recorded.
    public func keyPressed(keyCode: UInt16, modifiers: ShortcutModifiers, keyName: String?) {
        guard let account = recording else { return }
        if keyCode == ShortcutKeys.escape {
            abandonRecording()
            return
        }
        guard let keyName else { return }
        let candidate = GlobalShortcut(keyCode: keyCode, modifiers: modifiers, keyName: keyName)
        guard candidate.validation == .valid else {
            hints[account] = .addModifier
            return
        }
        let taken = listed.contains { other in
            other != account && store.shortcut(account: other).map { $0.sameCombination(as: candidate) } == true
        }
        if taken {
            hints[account] = .alreadyInUse
            endRecording()
            return
        }
        recording = nil
        if register(candidate, account: account) {
            store.setShortcut(candidate, account: account)
            active[account] = candidate
            hints[account] = nil
            restore(except: account)
        } else {
            hints[account] = .alreadyInUse
            restore(except: nil)
        }
    }

    /// Esc, a press outside the field, Settings no longer key or closed,
    /// another account selected: recording stops; the previous
    /// registrations come back.
    public func abandonRecording() {
        guard let account = recording else { return }
        hints[account] = nil
        endRecording()
    }

    /// Settings selected another row (an account, an owner, or none):
    /// a field recording for any other account is cancelled, so no
    /// registration stays suspended while its field is gone.
    public func selectionChanged(to account: String?) {
        guard let recording, recording != account else { return }
        abandonRecording()
    }

    /// The × button: unregistered and deleted.
    public func clear(_ account: String) {
        guard recording != account else { return }
        unregister(account)
        active[account] = nil
        hints[account] = nil
        store.setShortcut(nil, account: account)
    }

    /// Every registration goes (the app quits).
    public func unregisterAll() {
        for account in registered { registrar.unregister(id: id(of: account)) }
        registered = []
    }

    // MARK: - Registrations

    private func endRecording() {
        recording = nil
        restore(except: nil)
    }

    /// Registers again what recording suspended: the accounts of the list
    /// with a combination shown, except `skip` (registered already). One
    /// that cannot be registered again shows as unregistered.
    private func restore(except skip: String?) {
        for account in listed where account != skip && !registered.contains(account) {
            guard let shortcut = active[account] else { continue }
            if !register(shortcut, account: account) { active[account] = nil }
        }
    }

    private func register(_ shortcut: GlobalShortcut, account: String) -> Bool {
        guard enabled else { return false }
        unregister(account)
        guard registrar.register(shortcut, id: id(of: account)) else { return false }
        registered.insert(account)
        return true
    }

    private func unregister(_ account: String) {
        guard registered.remove(account) != nil else { return }
        registrar.unregister(id: id(of: account))
    }
}
