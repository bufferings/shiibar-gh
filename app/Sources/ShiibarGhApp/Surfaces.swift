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
    private let popover = NSPopover()
    private var popoverAccount: String?
    private var panels: [String: NSPanel] = [:]
    private var keyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var surfaceAppearance = NSAppearance(named: .aqua)
    var onWindowOpened: ((String) -> Void)?
    var onWindowClosed: ((String) -> Void)?
    /// Called on ⌘Q while a surface has the focus.
    var onQuit: (() -> Void)?

    static let popoverWidth: CGFloat = 460

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
            draw(item, color: account.accountColor, marks: MenuBarMarks(account))
            item.button?.setAccessibilityLabel(accessibility(account))
            item.button?.toolTip = account.login
        }
        if SurfaceRules.showsAppIcon(accounts) {
            if fallback == nil {
                let item = NSStatusBar.system.statusItem(withLength: MenuBarImage.width)
                item.button?.target = self
                item.button?.action = #selector(clickedFallback(_:))
                item.button?.toolTip = "shiibar-gh"
                watchAppearance(item)
                fallback = item
            }
            if let fallback {
                draw(fallback, color: .none, marks: MenuBarMarks(count: 0, dot: false, triangle: app.dbUnreadable || app.keychain != .ok))
            }
        } else if let fallback {
            remove(fallback)
            self.fallback = nil
            if popoverAccount == nil { popover.performClose(nil) }
        }
    }

    private func draw(_ item: NSStatusItem, color: AccountColor, marks: MenuBarMarks) {
        guard let button = item.button else { return }
        button.image = MenuBarImage.make(color: color, marks: marks, appearance: button.effectiveAppearance)
    }

    private func remove(_ item: NSStatusItem) {
        appearanceWatch[ObjectIdentifier(item)] = nil
        NSStatusBar.system.removeStatusItem(item)
    }

    /// A new image whenever the menu bar turns light or dark.
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

    private func accessibility(_ account: Account) -> String {
        var parts = [account.login]
        if account.unread { parts.append("unread") }
        if account.todoCount > 0 { parts.append("\(account.todoCount) Todo") }
        if Warnings.hasTriangle(account) { parts.append("warning") }
        return parts.joined(separator: ", ")
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
            content = AnyView(PopoverView(app: app, model: app.viewModel(account), avatars: avatars, actions: actions(account), surface: .popover))
            popover.contentSize = NSSize(width: Self.popoverWidth, height: 620)
        } else {
            var none = actions(nil)
            none.openWindow = nil
            content = AnyView(NoAccountsView(app: app, actions: none))
            popover.contentSize = NSSize(width: 300, height: 200)
        }
        popover.contentViewController = NSHostingController(rootView: content)
        popover.appearance = surfaceAppearance
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if let account {
            app.surfaceDisplayed(.popover, account: account, true)
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
        let view = PopoverView(app: app, model: app.viewModel(account), avatars: avatars, actions: surface, surface: .window)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.popoverWidth, height: 620),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.title = app.account(account)?.login ?? ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.appearance = surfaceAppearance
        panel.contentViewController = NSHostingController(rootView: view)
        panel.setContentSize(NSSize(width: Self.popoverWidth, height: 620))
        panel.identifier = NSUserInterfaceItemIdentifier(account)
        panel.delegate = self
        if let saved = app.store.windowFrame(account: account) {
            panel.setFrame(NSRectFromString(saved), display: false)
        } else {
            panel.center()
        }
        panels[account] = panel
        onWindowOpened?(account)
        app.surfaceDisplayed(.window, account: account, true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
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
            onWindowClosed?(account)
        }
    }

    // MARK: - Keys

    /// ↑↓, ⏎, T, D and S while the popover or a window has the focus, and ⌘Q.
    /// Keys typed into a text field are left alone.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = NSApp.keyWindow
        let account: String?
        if popover.isShown, key === popover.contentViewController?.view.window {
            account = popoverAccount
        } else if let window = key, let id = window.identifier?.rawValue, panels[id] === window {
            account = id
        } else {
            return false
        }
        if flags == .command, event.charactersIgnoringModifiers == "q" {
            onQuit?()
            return true
        }
        if key?.firstResponder is NSText { return false }
        guard let account, flags.subtracting([.numericPad, .function]).isEmpty else { return false }
        let model = app.viewModel(account)
        switch event.keyCode {
        case 126: model.press(.up)
        case 125: model.press(.down)
        case 36, 76: model.press(.open)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "d": model.press(.done)
            case "t": model.press(.todo)
            case "s": model.press(.snooze)
            default: return false
            }
        }
        return true
    }
}
