// The app's main menu. While the app is a regular app (an account's window or
// Settings is open) the menu bar shows it; while it is an accessory app it
// is not shown but its key equivalents still work. DESIGN.md, "Switching to
// a regular app": the app menu has About Shiibar GH, Settings… (⌘,), Close
// Window (⌘W) and Quit Shiibar GH (⌘Q); Edit has the text commands. AppKit
// gives a key equivalent to the key window's views first, and "if no
// object in the view hierarchy handles the key equivalent, NSApp then sends
// performKeyEquivalent: to the menus in the menu bar" (Apple, Event
// Handling Guide, "Handling Key Events"), which is what makes ⌘V work in a
// text field.

import AppKit

@MainActor
public enum MainMenu {
    /// The app's name on screen (DESIGN.md, "Overview and scope"). The CLI,
    /// the repository, the state directory, the logs and the token's
    /// description keep `shiibar-gh`.
    public nonisolated static let appName = "Shiibar GH"
    public nonisolated static let aboutTitle = "About \(appName)"

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

    /// What the app menu's items do. Quit goes through
    /// `NSApplication.terminate`, the same path as the ⌄ menu's Quit, which
    /// stops the daemon first.
    public struct Actions {
        public var about: () -> Void
        public var settings: () -> Void

        public init(about: @escaping () -> Void, settings: @escaping () -> Void) {
            self.about = about
            self.settings = settings
        }
    }

    public static func make(_ actions: Actions = Actions(about: {}, settings: {})) -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: appName)
        app.addItem(closureItem(aboutTitle, key: "", actions.about))
        app.addItem(.separator())
        app.addItem(closureItem("Settings…", key: ",", actions.settings))
        app.addItem(.separator())
        // To the first responder: the key window answers performClose:, and
        // with nothing to close the item is disabled by menu validation.
        app.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = app
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

    @MainActor
    static func closureItem(_ title: String, key: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(IconMenu.Target.run(_:)), keyEquivalent: key)
        let target = IconMenu.Target(action)
        item.target = target
        item.representedObject = target
        return item
    }
}

/// What makes the app a regular app (DESIGN.md, "Switching to a regular
/// app"): a window of any account, Settings, and the popover `Open in
/// popover` opened (or the popover that replaced it from another account's
/// icon) until no popover shows. Going back to an accessory app while a
/// popover shows can deactivate the app, which closes the popover.
public struct RegularWindows: Equatable {
    private var open: Set<String> = []
    /// `Open in popover` closed a window: the popover it opens keeps the
    /// app regular.
    public private(set) var popoverHold = false

    public init() {}

    public var isRegular: Bool { !open.isEmpty || popoverHold }

    /// True when the app was not regular: switch to regular. Added before
    /// the held popover closes (`Open in window`, Settings from it), the
    /// app stays regular throughout.
    public mutating func opened(_ id: String) -> Bool {
        let was = isRegular
        open.insert(id)
        return !was
    }

    /// True when nothing keeps the app regular any more: back to the
    /// accessory app.
    public mutating func closed(_ id: String) -> Bool {
        guard open.remove(id) != nil else { return false }
        return !isRegular
    }

    /// `Open in popover`: set before its window closes, so the close does
    /// not make the app an accessory app under the popover it opens.
    public mutating func holdPopover() {
        popoverHold = true
    }

    /// The popover closed. `replaced`: another account's icon put its
    /// popover in its place, which keeps holding. True when nothing keeps
    /// the app regular any more.
    public mutating func popoverClosed(replaced: Bool) -> Bool {
        guard popoverHold, !replaced else { return false }
        popoverHold = false
        return !isRegular
    }
}
