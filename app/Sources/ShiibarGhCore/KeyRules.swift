// What a key does while the popover or a window has the focus (DESIGN.md,
// "Keyboard" and "Search field"), without AppKit: the app reads the key
// code, the characters and the modifiers from the NSEvent and does what
// `KeyRules.decide` returns.

import Foundation

public enum KeyModifier: Hashable {
    case command, shift, option, control
}

/// One key press. `characters` is `charactersIgnoringModifiers`, which keeps
/// the effect of Shift: ⇧R reads "R" and ⌘+ (Shift-= on a US keyboard) "+".
public struct KeyPress: Equatable {
    public var keyCode: UInt16
    public var characters: String
    public var modifiers: Set<KeyModifier>

    public init(keyCode: UInt16 = 0, characters: String = "", modifiers: Set<KeyModifier> = []) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
    }

    // Virtual key codes of the keys the popover reads (Carbon `kVK_*`).
    public static let escape: UInt16 = 53
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
    public static let returnKey: UInt16 = 36
    public static let enter: UInt16 = 76
    /// ⌫ (`kVK_Delete`).
    public static let delete: UInt16 = 51
}

public enum KeyInput: Equatable {
    case key(Key)
    /// Esc or ↓ in the search field: back to the list, Esc clearing the
    /// text if there is any.
    case leaveSearch(clearing: Bool)
    case textSize(TextSize.Change)
    case quit
    /// Not ours: the field types it, or the system handles it (Esc in a tab
    /// closes the popover).
    case pass
}

public enum KeyRules {
    /// `inDismissed`: the Dismissed list shows, where Esc goes back to the
    /// tab.
    public static func decide(_ press: KeyPress, inSearch: Bool, hasSearchText: Bool, inDismissed: Bool = false) -> KeyInput {
        let mods = press.modifiers
        let chars = press.characters
        if mods == [.command] && chars == "q" { return .quit }
        // ⌘C copies the field's own text in the search field.
        if mods == [.command] && chars == "c" { return inSearch ? .pass : .key(.copy) }
        // ⌘ keys work in the search field too.
        if mods == [.command] || mods == [.command, .shift] {
            switch chars {
            case "=", "+": return .textSize(.larger)
            case "-": return .textSize(.smaller)
            case "0": return .textSize(.reset)
            case "f" where mods == [.command]: return .key(.find)
            case "1" where mods == [.command]: return .key(.tab(.all))
            case "2" where mods == [.command]: return .key(.tab(.review))
            case "3" where mods == [.command]: return .key(.tab(.mine))
            default: return .pass
            }
        }
        if inSearch {
            // Only Esc and ↓ leave; ⇧R, D, T, W and ⌫ are text.
            guard mods.isEmpty else { return .pass }
            switch press.keyCode {
            case KeyPress.escape: return .leaveSearch(clearing: hasSearchText)
            case KeyPress.downArrow: return .leaveSearch(clearing: false)
            default: return .pass
            }
        }
        if mods == [.shift] {
            return chars.lowercased() == "r" ? .key(.markAllRead) : .pass
        }
        if mods == [.option] {
            switch press.keyCode {
            case KeyPress.upArrow: return .key(.reorder(up: true))
            case KeyPress.downArrow: return .key(.reorder(up: false))
            default: return .pass
            }
        }
        guard mods.isEmpty else { return .pass }
        switch press.keyCode {
        case KeyPress.upArrow: return .key(.up)
        case KeyPress.downArrow: return .key(.down)
        case KeyPress.returnKey, KeyPress.enter: return .key(.open)
        case KeyPress.delete: return .key(.delete)
        case KeyPress.escape: return inDismissed ? .key(.back) : .pass
        default:
            switch chars.lowercased() {
            case "d": return .key(.moveTo(.doing))
            case "t": return .key(.moveTo(.todo))
            case "w": return .key(.moveTo(.waiting))
            default: return .pass
            }
        }
    }
}
