// The menu bar icons, the popovers and the always-on-top windows.
//
// AppKit, not MenuBarExtra: the menu bar shows one icon per account and the
// number changes as accounts come and go. NSStatusItem (one per account) with
// NSPopover and NSPanel give the dynamic icons, the marks drawn into the
// image, and key handling through an event monitor (DESIGN.md, "UI").

import AppKit
import Combine
import ShiibarGhCore
import SwiftUI

@MainActor
final class SurfaceController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private let app: AppModel
    private let avatars: AvatarStore
    private let actions: (String?) -> SurfaceActions
    private var items: [String: NSStatusItem] = [:]
    private var order: [String] = []
    private var fallback: NSStatusItem?
    private var appearanceWatch: [ObjectIdentifier: NSKeyValueObservation] = [:]
    /// What each status button shows now: an image, a label or a tooltip is
    /// set again only when it changes (`StatusItemUpdate`). Setting the
    /// image on every update redrew the button, which changed its
    /// effective appearance, which called `update()` again: 0.3.0 spent
    /// about 90% CPU in that loop (docs/tasks/M6.md, "CPU").
    private var looks: [ObjectIdentifier: StatusItemLook] = [:]
    private let popover = NSPopover()
    private var popoverAccount: String?
    private var panels: [String: NSPanel] = [:]
    private var keyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    /// Keep on top of each window follows its account's value.
    private var pinWatch: [String: AnyCancellable] = [:]
    private var surfaceAppearance = NSAppearance(named: .aqua)
    var onWindowOpened: ((String) -> Void)?
    var onWindowClosed: ((String) -> Void)?
    /// Called on ⌘Q while a surface has the focus.
    var onQuit: (() -> Void)?

    /// 460 points at text size 12, in proportion to the text size.
    var popoverWidth: CGFloat { CGFloat(TextSize.width(app.textSize)) }
    static let popoverHeight: CGFloat = 620

    init(app: AppModel, avatars: AvatarStore, actions: @escaping (String?) -> SurfaceActions) {
        self.app = app
        self.avatars = avatars
        self.actions = actions
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        app.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
            .store(in: &cancellables)
        // The popover's width follows the text size at once; a window keeps
        // the size it has (DESIGN.md, "Text size").
        app.$textSize
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] size in
                guard let self, self.popover.isShown, self.popoverAccount != nil else { return }
                self.popover.contentSize = NSSize(width: CGFloat(TextSize.width(size)), height: Self.popoverHeight)
            }
            .store(in: &cancellables)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        update()
    }

    func applyAppearance(_ name: NSAppearance.Name) {
        surfaceAppearance = NSAppearance(named: name)
        popover.appearance = surfaceAppearance
        for panel in panels.values { panel.appearance = surfaceAppearance }
        update()
    }

    func bringWindowsToFront() {
        for panel in panels.values { panel.orderFront(nil) }
    }

    // MARK: - Menu bar

    private func update() {
        let accounts = app.dbUnreadable ? [] : app.accounts
        let ids = accounts.map(\.id)
        for id in items.keys where !ids.contains(id) {
            if let item = items.removeValue(forKey: id) { remove(item) }
            if popoverAccount == id { popover.performClose(nil) }
        }
        for id in panels.keys where !ids.contains(id) {
            panels[id]?.close()
        }
        if ids != order {
            // Recreate in order so the icons keep the order of the accounts.
            for id in order { if let item = items.removeValue(forKey: id) { remove(item) } }
            order = ids
        }
        // The rightmost icon is created first.
        for account in accounts.reversed() {
            let item = items[account.id] ?? makeItem(account.id)
            show(
                item, color: account.accountColor, marks: MenuBarMarks(account),
                label: MenuBarMarks.accessibilityLabel(account), toolTip: account.login
            )
        }
        if SurfaceRules.showsAppIcon(accounts) {
            if fallback == nil {
                let item = NSStatusBar.system.statusItem(withLength: MenuBarImage.width)
                item.button?.target = self
                item.button?.action = #selector(clickedFallback(_:))
                watchAppearance(item)
                fallback = item
            }
            if let fallback {
                show(
                    fallback, color: .none, marks: MenuBarMarks(dot: false, triangle: app.dbUnreadable || app.keychain != .ok),
                    label: MenuBarMarks.noAccountsLabel, toolTip: "shiibar-gh"
                )
            }
        } else if let fallback {
            remove(fallback)
            self.fallback = nil
            if popoverAccount == nil { popover.performClose(nil) }
        }
    }

    /// Sets on the button only what changed since the last time.
    private func show(_ item: NSStatusItem, color: AccountColor, marks: MenuBarMarks, label: String, toolTip: String) {
        guard let button = item.button else { return }
        let id = ObjectIdentifier(item)
        let appearance = button.effectiveAppearance
        let look = StatusItemLook(dark: appearance.isDark, color: color, marks: marks, accessibilityLabel: label, toolTip: toolTip)
        let change = StatusItemUpdate(from: looks[id], to: look)
        guard !change.isEmpty else { return }
        looks[id] = look
        if change.image { button.image = MenuBarImage.make(color: color, marks: marks, appearance: appearance) }
        if change.accessibilityLabel { button.setAccessibilityLabel(label) }
        if change.toolTip { button.toolTip = toolTip }
    }

    private func remove(_ item: NSStatusItem) {
        appearanceWatch[ObjectIdentifier(item)] = nil
        looks[ObjectIdentifier(item)] = nil
        NSStatusBar.system.removeStatusItem(item)
    }

    /// A new image when the menu bar turns light or dark: `show` sets it
    /// only if the button's appearance is now the other one.
    private func watchAppearance(_ item: NSStatusItem) {
        guard let button = item.button else { return }
        appearanceWatch[ObjectIdentifier(item)] = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.update() }
        }
    }

    private func makeItem(_ id: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: MenuBarImage.width)
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.identifier = NSUserInterfaceItemIdentifier(id)
        items[id] = item
        watchAppearance(item)
        return item
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let id = sender.identifier?.rawValue else { return }
        toggle(account: id, from: sender)
    }

    @objc private func clickedFallback(_ sender: NSStatusBarButton) {
        toggle(account: nil, from: sender)
    }

    // MARK: - Popover

    func showPopover(account: String) {
        guard let button = items[account]?.button else { return }
        if popover.isShown && popoverAccount == account { return }
        toggle(account: account, from: button)
    }

    private func toggle(account: String?, from button: NSStatusBarButton) {
        if popover.isShown {
            let same = popoverAccount == account
            popover.performClose(nil)
            if same { return }
        }
        popoverAccount = account
        let content: AnyView
        if let account {
            let model = app.viewModel(account)
            content = AnyView(PopoverView(app: app, model: model, list: model.list(.popover), avatars: avatars, actions: actions(account), surface: .popover))
            popover.contentSize = NSSize(width: popoverWidth, height: Self.popoverHeight)
        } else {
            var none = actions(nil)
            none.openWindow = nil
            content = AnyView(NoAccountsView(app: app, actions: none))
            popover.contentSize = NSSize(width: popoverWidth, height: NoAccountsView.height)
        }
        popover.contentViewController = NSHostingController(rootView: content)
        popover.appearance = surfaceAppearance
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // The search field does not take the keyboard when the popover
        // opens (DESIGN.md, "Search field"); ⌘F moves there.
        let window = popover.contentViewController?.view.window
        DispatchQueue.main.async { window?.makeFirstResponder(nil) }
        if let account {
            app.surfaceDisplayed(.popover, account: account, true, opening: true)
            app.surfaceOpened(.popover, account: account)
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let account = popoverAccount {
                app.surfaceClosed(.popover, account: account)
                app.surfaceDisplayed(.popover, account: account, false)
            }
            popoverAccount = nil
            popover.contentViewController = nil
        }
    }

    // MARK: - Window

    func openWindow(account: String) {
        popover.performClose(nil)
        if let panel = panels[account] {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        var surface = actions(account)
        surface.openWindow = nil
        let model = app.viewModel(account)
        let view = PopoverView(app: app, model: model, list: model.list(.window), avatars: avatars, actions: surface, surface: .window)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: popoverWidth, height: Self.popoverHeight),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.title = app.account(account)?.login ?? ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.appearance = surfaceAppearance
        panel.contentViewController = NSHostingController(rootView: view)
        panel.setContentSize(NSSize(width: popoverWidth, height: Self.popoverHeight))
        panel.identifier = NSUserInterfaceItemIdentifier(account)
        panel.delegate = self
        if let saved = app.store.windowFrame(account: account) {
            panel.setFrame(NSRectFromString(saved), display: false)
        } else {
            panel.center()
        }
        panels[account] = panel
        // Keep on top: the panel floats above normal windows while on
        // (NSWindow.level; .floating is in front of every normal-level
        // window). Applied now and whenever the pin is pressed.
        pinWatch[account] = app.viewModel(account).$keepOnTop.sink { [weak panel] on in
            panel?.isFloatingPanel = on
            panel?.level = on ? .floating : .normal
        }
        onWindowOpened?(account)
        // The window becomes key at once below, and `surfaceOpened` reads
        // the lists after `popover_opened`.
        app.surfaceDisplayed(.window, account: account, true, opening: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak panel] in panel?.makeFirstResponder(nil) }
    }

    private func account(of notification: Notification) -> String? {
        (notification.object as? NSWindow)?.identifier?.rawValue
    }

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let account = account(of: notification), panels[account] != nil {
                app.surfaceOpened(.window, account: account)
            }
        }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let account = account(of: notification), panels[account] != nil {
                app.surfaceClosed(.window, account: account)
            }
        }
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated { saveFrame(notification) }
    }

    nonisolated func windowDidResize(_ notification: Notification) {
        MainActor.assumeIsolated { saveFrame(notification) }
    }

    private func saveFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let account = account(of: notification), panels[account] != nil else { return }
        app.store.setWindowFrame(NSStringFromRect(window.frame), account: account)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let account = account(of: notification), panels[account] != nil else { return }
            app.surfaceClosed(.window, account: account)
            app.surfaceDisplayed(.window, account: account, false)
            panels[account] = nil
            pinWatch[account] = nil
            onWindowClosed?(account)
        }
    }

    // MARK: - Keys

    /// Whether keys go to a text field: the search field's editor, not the
    /// selectable text of cards and rows (which takes the focus when pressed
    /// but types nothing).
    static func isTyping(_ responder: NSResponder?) -> Bool {
        responder is NSText && !(responder is SelectableTextView)
    }

    /// The keys while the popover or a window has the focus: what each does
    /// is `KeyRules.decide` (ShiibarGhCore); this reads the NSEvent and
    /// carries the answer out.
    private func handleKey(_ event: NSEvent) -> Bool {
        let key = NSApp.keyWindow
        let account: String?
        let surface: Surface
        if popover.isShown, key === popover.contentViewController?.view.window {
            account = popoverAccount
            surface = .popover
        } else if let window = key, let id = window.identifier?.rawValue, panels[id] === window {
            account = id
            surface = .window
        } else {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Set<KeyModifier> = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let press = KeyPress(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "", modifiers: modifiers)
        let model = account.map { app.viewModel($0).list(surface) }
        let inSearch = (model?.searchFocused ?? false) || Self.isTyping(key?.firstResponder)
        let decided = KeyRules.decide(
            press, inSearch: inSearch, hasSearchText: !(model?.search.isEmpty ?? true), inDismissed: model?.showingDismissed ?? false
        )
        switch decided {
        case .quit:
            onQuit?()
        case .pass:
            return false
        case .textSize(let change):
            guard model != nil else { return false }
            app.changeTextSize(change)
        case .key(let key):
            guard let model else { return false }
            model.press(key)
        case .leaveSearch(let clearing):
            guard let model else { return false }
            model.leaveSearch(clearing: clearing)
            key?.makeFirstResponder(nil)
        }
        return true
    }

    /// Edit › Copy chosen with the mouse while a popover or window has the
    /// focus: the same as ⌘C there (the selected text, else the link of
    /// the selected card or row). False when another window has the focus,
    /// or the search field does: the menu's own `copy:` goes on.
    func copyFromMenu() -> Bool {
        let key = NSApp.keyWindow
        let model: SurfaceListModel
        if popover.isShown, key === popover.contentViewController?.view.window, let account = popoverAccount {
            model = app.viewModel(account).list(.popover)
        } else if let window = key, let id = window.identifier?.rawValue, panels[id] === window {
            model = app.viewModel(id).list(.window)
        } else {
            return false
        }
        if model.searchFocused || Self.isTyping(key?.firstResponder) { return false }
        model.press(.copy)
        return true
    }
}
