// The app's main menu, which the menu bar never shows (an LSUIElement app)
// but which carries the text editing key equivalents. AppKit gives a key
// equivalent to the key window's views first, and "if no object in the view
// hierarchy handles the key equivalent, NSApp then sends
// performKeyEquivalent: to the menus in the menu bar" (Apple, Event Handling
// Guide, "Handling Key Events"). Text fields do not handle ⌘V themselves, so
// without an Edit menu ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z do nothing in Settings.
//
// There is no Quit item: ⌘Q quits only from the popover and the focused
// window (DESIGN.md, "Screens"), which the app's key monitor handles.

import AppKit

public enum MainMenu {
    public struct EditItem: Equatable {
        public var title: String
        public var key: String
        public var shift: Bool
        public var action: String
    }

    /// The standard text editing commands, sent to the first responder.
    public static let editItems: [EditItem] = [
        EditItem(title: "Undo", key: "z", shift: false, action: "undo:"),
        EditItem(title: "Redo", key: "z", shift: true, action: "redo:"),
        EditItem(title: "Cut", key: "x", shift: false, action: "cut:"),
        EditItem(title: "Copy", key: "c", shift: false, action: "copy:"),
        EditItem(title: "Paste", key: "v", shift: false, action: "paste:"),
        EditItem(title: "Select All", key: "a", shift: false, action: "selectAll:"),
    ]

    public static func make() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "shiibar-gh")
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (index, item) in editItems.enumerated() {
            if index == 2 { edit.addItem(.separator()) }
            let entry = NSMenuItem(title: item.title, action: NSSelectorFromString(item.action), keyEquivalent: item.key)
            entry.keyEquivalentModifierMask = item.shift ? [.command, .shift] : [.command]
            // No target: the action goes to the first responder, such as
            // the focused text field.
            entry.target = nil
            edit.addItem(entry)
        }
        editItem.submenu = edit
        menu.addItem(editItem)
        return menu
    }
}
