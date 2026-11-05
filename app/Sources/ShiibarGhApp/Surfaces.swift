// The menu bar icons, the popover and the always-on-top windows.
//
// AppKit, not MenuBarExtra: the menu bar shows one icon per scope and the
// number changes as scopes come and go, and Apple's MenuBarExtra
// documentation describes one scene per item without a way to make items
// from data. NSStatusItem (one per scope) with NSPopover and NSPanel give
// the dynamic icons, the badge drawn into the image, and key handling
// through an event monitor (DESIGN.md, "UI").

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
    private let popover = NSPopover()
    private var popoverScope: String?
    private var panels: [String: NSPanel] = [:]
    private var keyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    /// The appearance of the popover and the windows, set explicitly (see
    /// SurfaceAppearance.named).
    private var surfaceAppearance = NSAppearance(named: .aqua)
    /// A scope's window opened or closed: the app is a regular app while one
    /// exists.
    var onWindowOpened: ((String) -> Void)?
    var onWindowClosed: ((String) -> Void)?
    /// Called on ⌘Q while a surface has the focus.
    var onQuit: (() -> Void)?

    init(app: AppModel, avatars: AvatarStore, actions: @escaping (String?) -> SurfaceActions) {
        self.app = app
        self.avatars = avatars
        self.actions = actions
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        app.$scopes
            .receive(on: RunLoop.main)
            .sink { [weak self] scopes in self?.update(scopes) }
            .store(in: &cancellables)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        update([])
    }

    /// Light or dark for the popover and every window, from the
    /// Appearance setting and the Mac (AppDelegate).
    func applyAppearance(_ name: NSAppearance.Name) {
        surfaceAppearance = NSAppearance(named: name)
        popover.appearance = surfaceAppearance
        for panel in panels.values { panel.appearance = surfaceAppearance }
        update(app.scopes)
    }

    /// The Dock icon or ⌘Tab: the open windows come to the front.
    func bringWindowsToFront() {
        for panel in panels.values { panel.orderFront(nil) }
    }

    // MARK: - Menu bar


    private func update(_ scopes: [Scope]) {
        let shown = scopes.filter(\.enabled)
        let ids = shown.map(\.id)
        for id in items.keys where !ids.contains(id) {
            if let item = items.removeValue(forKey: id) {
                NSStatusBar.system.removeStatusItem(item)
            }
            if popoverScope == id { popover.performClose(nil) }
        }
        // A removed or disabled scope has no window either.
        for id in panels.keys where !ids.contains(id) {
            panels[id]?.close()
        }
        if ids != order {
            // Recreate in order so the icons keep the order of the scopes.
            for id in order { if let item = items.removeValue(forKey: id) { NSStatusBar.system.removeStatusItem(item) } }
            order = ids
        }
        for scope in shown.reversed() {
            let item = items[scope.id] ?? makeItem(scope.id)
            item.button?.image = MenuBarImage.make(
                icon: BoardIcons.scope(scope), badge: scope.badge, dot: scope.dot,
                triangle: Warnings.hasTriangle(scope) || app.dbUnreadable
            )
            item.button?.setAccessibilityLabel(accessibility(scope))
            item.button?.toolTip = scope.name
        }
        if SurfaceRules.showsAppIcon(scopes) {
            if fallback == nil {
                let item = NSStatusBar.system.statusItem(withLength: MenuBarImage.width)
                item.button?.target = self
                item.button?.action = #selector(clickedFallback(_:))
                item.button?.toolTip = "shiibar-gh"
                fallback = item
            }
            fallback?.button?.image = MenuBarImage.make(icon: BoardIcons.app, badge: 0, dot: false, triangle: app.dbUnreadable)
        } else if let fallback {
            NSStatusBar.system.removeStatusItem(fallback)
            self.fallback = nil
            if popoverScope == nil { popover.performClose(nil) }
        }
    }

    private func makeItem(_ id: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: MenuBarImage.width)
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.identifier = NSUserInterfaceItemIdentifier(id)
        items[id] = item
        return item
    }

    private func accessibility(_ scope: Scope) -> String {
        var parts = [scope.name]
        if scope.badge > 0 { parts.append("\(scope.badge) need action") }
        if scope.dot { parts.append("unread") }
        if Warnings.hasTriangle(scope) { parts.append("warning") }
        return parts.joined(separator: ", ")
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let id = sender.identifier?.rawValue else { return }
        toggle(scope: id, from: sender)
    }

    @objc private func clickedFallback(_ sender: NSStatusBarButton) {
        toggle(scope: nil, from: sender)
    }

    // MARK: - Popover

    func showPopover(scope: String) {
        guard let button = items[scope]?.button else { return }
        if popover.isShown && popoverScope == scope { return }
        toggle(scope: scope, from: button)
    }

    private func toggle(scope: String?, from button: NSStatusBarButton) {
        if popover.isShown {
            let same = popoverScope == scope
            popover.performClose(nil)
            if same { return }
        }
        popoverScope = scope
        let content: AnyView
        if let scope {
            content = AnyView(PopoverView(app: app, model: app.viewModel(scope), avatars: avatars, actions: actions(scope), surface: .popover))
            popover.contentSize = NSSize(width: 400, height: 620)
        } else {
            var noScope = actions(nil)
            noScope.openWindow = nil
            content = AnyView(NoScopesView(app: app, actions: noScope))
            popover.contentSize = NSSize(width: 300, height: 180)
        }
        popover.contentViewController = NSHostingController(rootView: content)
        popover.appearance = surfaceAppearance
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if let scope {
            app.surfaceDisplayed(.popover, scope: scope, true)
            app.surfaceOpened(.popover, scope: scope)
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let scope = popoverScope {
                app.surfaceClosed(.popover, scope: scope)
                app.surfaceDisplayed(.popover, scope: scope, false)
            }
            popoverScope = nil
            popover.contentViewController = nil
        }
    }

    // MARK: - Window

    func openWindow(scope: String) {
        popover.performClose(nil)
        if let panel = panels[scope] {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        var surface = actions(scope)
        surface.openWindow = nil
        let view = PopoverView(app: app, model: app.viewModel(scope), avatars: avatars, actions: surface, surface: .window)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 620),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.title = app.scope(scope)?.name ?? scope
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.appearance = surfaceAppearance
        panel.contentViewController = NSHostingController(rootView: view)
        panel.setContentSize(NSSize(width: 400, height: 620))
        panel.identifier = NSUserInterfaceItemIdentifier(scope)
        panel.delegate = self
        if let saved = app.store.windowFrame(scope: scope) {
            panel.setFrame(NSRectFromString(saved), display: false)
        } else {
            panel.center()
        }
        panels[scope] = panel
        onWindowOpened?(scope)
        app.surfaceDisplayed(.window, scope: scope, true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func scope(of notification: Notification) -> String? {
        (notification.object as? NSWindow)?.identifier?.rawValue
    }

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let scope = scope(of: notification), panels[scope] != nil {
                app.surfaceOpened(.window, scope: scope)
            }
        }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let scope = scope(of: notification), panels[scope] != nil {
                app.surfaceClosed(.window, scope: scope)
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
        guard let window = notification.object as? NSWindow, let scope = scope(of: notification), panels[scope] != nil else { return }
        app.store.setWindowFrame(NSStringFromRect(window.frame), scope: scope)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let scope = scope(of: notification), panels[scope] != nil else { return }
            app.surfaceClosed(.window, scope: scope)
            app.surfaceDisplayed(.window, scope: scope, false)
            panels[scope] = nil
            onWindowClosed?(scope)
        }
    }

    // MARK: - Keys

    /// ↑↓, ⏎, D and S while the popover or a window has the focus, and ⌘Q.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = NSApp.keyWindow
        let scope: String?
        if popover.isShown, key === popover.contentViewController?.view.window {
            scope = popoverScope
        } else if let window = key, let id = window.identifier?.rawValue, panels[id] === window {
            scope = id
        } else {
            return false
        }
        if flags == .command, event.charactersIgnoringModifiers == "q" {
            onQuit?()
            return true
        }
        guard let scope, flags.subtracting([.numericPad, .function]).isEmpty else { return false }
        let model = app.viewModel(scope)
        switch event.keyCode {
        case 126: model.press(.up)
        case 125: model.press(.down)
        case 36, 76: model.press(.open)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "d": model.press(.done)
            case "s": model.press(.snooze)
            default: return false
            }
        }
        return true
    }
}
