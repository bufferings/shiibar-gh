// The menu bar icons, the popovers and the always-on-top windows.
//
// AppKit, not MenuBarExtra: the menu bar shows one icon per account and the
// number changes as accounts come and go. NSStatusItem (one per account) with
// NSPopover and NSWindow give the dynamic icons, the marks drawn into the
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
    /// about 90% CPU in that loop (DESIGN.md, "Implementation policy",
    /// "UI": the image is not set again while it is the same).
    private var looks = StatusItemLooks()
    private let popover = NSPopover()
    private var popoverAccount: String?
    private var panels: [String: NSWindow] = [:]
    /// The title of each window: the account's mark and name.
    private var titles: [String: WindowTitle] = [:]
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
        // The dot follows the accent color: `show` sets a new image only if
        // the color it resolves to changed.
        SystemColors.changed
            .sink { [weak self] in DispatchQueue.main.async { self?.update() } }
            .store(in: &cancellables)
        // The popover's width follows the text size at once; a window keeps
        // the size it has (DESIGN.md, "Text size").
        app.$textSize
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] size in
                guard let self, self.popover.isShown, self.popoverAccount != nil else { return }
                // The height stays (DESIGN.md, "Screens": the text size does
                // not change it).
                self.popover.contentSize = NSSize(width: CGFloat(TextSize.width(size)), height: self.popover.contentSize.height)
            }
            .store(in: &cancellables)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        // DESIGN.md, "UI": once a menu (NSMenu) was opened from a
        // `.transient` popover, AppKit no longer closes the popover when the
        // app stops being active, and `popoverShouldClose` is not called;
        // this notification is still sent.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.appResignedActive() } }
            .store(in: &cancellables)
        update()
    }

    /// The app lost the focus: the popover closes, as it would by itself
    /// before a menu was opened in it. The measurement mode's popover
    /// (`.applicationDefined`) stays; a window is not a popover and stays.
    func appResignedActive() {
        guard SurfaceRules.closesPopoverOnResign(shown: popover.isShown, measuring: popover.behavior == .applicationDefined) else { return }
        popover.performClose(nil)
    }

    func applyAppearance(_ name: NSAppearance.Name) {
        surfaceAppearance = NSAppearance(named: name)
        popover.appearance = surfaceAppearance
        for panel in panels.values { panel.appearance = surfaceAppearance }
        update()
    }

    /// The Dock icon and ⌘Tab: the open windows come forward, a minimized
    /// one back from the Dock (DESIGN.md, "Open in window").
    func bringWindowsToFront() {
        for panel in panels.values {
            if panel.isMiniaturized { panel.deminiaturize(nil) }
            panel.orderFront(nil)
        }
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
        // The window's title follows the account's name and color.
        for account in accounts {
            titles[account.id]?.show(login: account.login, color: account.accountColor)
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
                item.button?.sendAction(on: Self.clickEvents)
                watchAppearance(item)
                fallback = item
            }
            if let fallback {
                show(
                    fallback, color: .none, marks: MenuBarMarks(dot: false, triangle: app.dbUnreadable || app.keychain != .ok),
                    label: MenuBarMarks.noAccountsLabel, toolTip: MenuBarMarks.noAccountsToolTip
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
        let dot = MenuBarImage.dotColor(for: appearance)
        let look = StatusItemLook(
            dark: appearance.isDark, color: color, marks: marks, accent: MenuBarImage.components(dot),
            accessibilityLabel: label, toolTip: toolTip
        )
        let change = looks.update(id, to: look)
        guard !change.isEmpty else { return }
        if change.image { button.image = MenuBarImage.make(color: color, marks: marks, appearance: appearance, dot: dot) }
        if change.accessibilityLabel { button.setAccessibilityLabel(label) }
        if change.toolTip { button.toolTip = toolTip }
    }

    private func remove(_ item: NSStatusItem) {
        appearanceWatch[ObjectIdentifier(item)] = nil
        looks.forget(ObjectIdentifier(item))
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

    /// DESIGN.md, "Screens" and "UI": the right button does what the left
    /// one does (the icon has no menu); either acts when released.
    static let clickEvents: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp]

    private func makeItem(_ id: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: MenuBarImage.width)
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: Self.clickEvents)
        item.button?.identifier = NSUserInterfaceItemIdentifier(id)
        items[id] = item
        watchAppearance(item)
        return item
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let id = sender.identifier?.rawValue else { return }
        // The account's window open: it comes to the front with the focus
        // instead of the popover (DESIGN.md, "Screens"); the focus sends
        // `popover_opened` (windowDidBecomeKey).
        if SurfaceRules.surfaceToShow(windowOpen: panels[id] != nil) == .window {
            openWindow(account: id)
            return
        }
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
        let content: AnyView?
        if let account {
            let model = app.viewModel(account)
            let root = PopoverView.root(app: app, model: model, list: model.list(.popover), avatars: avatars, actions: actions(account), surface: .popover)
            popover.contentViewController = SurfaceViewController(root)
            popoverHeights = SurfaceHeight(user: popoverHeight(account: account, near: button))
            popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight(account: account, near: button))
            root.onBottomEdgeDrag = { [weak self] phase, distance in self?.dragBottomEdge(phase, distance: distance) }
            root.onMinimumHeight = { [weak self] minimum in self?.popoverNeeds(minimum) }
            content = nil
        } else {
            var none = actions(nil)
            none.openWindow = nil
            none.menuHasSettings = true
            content = AnyView(NoAccountsView(app: app, actions: none))
            popover.contentSize = NSSize(width: popoverWidth, height: NoAccountsView.height)
        }
        if let content { popover.contentViewController = NSHostingController(rootView: content) }
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

    // MARK: - Popover height

    /// The height the popover opens with: the one dragged last for the
    /// account, else the default, within the screen's visible height.
    private func popoverHeight(account: String, near button: NSView) -> CGFloat {
        let saved = app.store.popoverHeight(account: account).map { CGFloat($0) } ?? Self.popoverHeight
        let visible = button.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? saved
        return min(max(Self.minPopoverHeight, saved), max(Self.minPopoverHeight, visible))
    }

    /// The smallest height dragging leaves (DESIGN.md, "Constants").
    static let minPopoverHeight: CGFloat = SurfaceHeight.floor
    private var dragStartHeight: CGFloat?
    /// The open popover's height: the user's, raised while the content
    /// needs more (the open Filter options, the list's minimum).
    private var popoverHeights = SurfaceHeight(user: SurfaceController.popoverHeight)

    /// The least height for the text size (the open options included,
    /// whether they are open or not): the popover is raised to it (within
    /// the screen), and goes back to the user's height when it is less.
    private func popoverNeeds(_ minimum: CGFloat) {
        guard popover.isShown, popoverAccount != nil, popoverHeights.setMinimum(minimum) else { return }
        resizePopover(to: popoverHeights.shown())
    }

    /// The popover's bottom edge dragged `distance` points down (up when
    /// negative) since the press: the height follows, between 300 points
    /// and the room down to the bottom of the screen's visible part; the
    /// width stays. The height is kept for the account when the drag ends.
    private func dragBottomEdge(_ phase: BottomEdgeResizer.Phase, distance: CGFloat) {
        guard popover.isShown, let account = popoverAccount else { return }
        if phase == .began { dragStartHeight = popover.contentSize.height }
        guard let start = dragStartHeight else { return }
        let height = resizePopover(to: start + distance)
        if phase == .ended {
            dragStartHeight = nil
            popoverHeights.setByUser(height)
            app.store.setPopoverHeight(Double(height), account: account)
        }
    }

    /// Sets the popover's height within its limits; returns the height set.
    @discardableResult
    func resizePopover(to wanted: CGFloat) -> CGFloat {
        let current = popover.contentSize
        var maximum = wanted
        if let window = popover.contentViewController?.view.window, let screen = window.screen {
            // The popover grows downward from the menu bar: the room is down
            // to the bottom of the visible part, less the popover's own frame
            // (its arrow) around the content.
            let chrome = window.frame.height - current.height
            maximum = window.frame.maxY - screen.visibleFrame.minY - chrome
        }
        // Not under what the content needs (the open options, the list's
        // minimum), unless the screen has less room.
        let least = max(Self.minPopoverHeight, popoverHeights.minimum)
        let height = min(max(least, wanted.rounded()), max(Self.minPopoverHeight, maximum.rounded(.down)))
        if height != current.height { popover.contentSize = NSSize(width: current.width, height: height) }
        return height
    }

    /// The measurement mode: the popover stays open until closed in code
    /// (`NSPopoverBehaviorApplicationDefined`, NSPopover.h), not when the
    /// app stops being active.
    func showPopoverForMeasurement(account: String) {
        popover.behavior = .applicationDefined
        showPopover(account: account)
    }

    /// The popover's window while it shows (the measurement mode).
    var popoverWindow: NSWindow? {
        popover.isShown ? popover.contentViewController?.view.window : nil
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

    /// The account's window while it is open (the measurement mode).
    func window(account: String) -> NSWindow? {
        panels[account]
    }

    func openWindow(account: String) {
        popover.performClose(nil)
        if let panel = panels[account] {
            // A minimized window comes back from the Dock (DESIGN.md, "Open
            // in window").
            if panel.isMiniaturized { panel.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        var surface = actions(account)
        surface.openWindow = nil
        let model = app.viewModel(account)
        let panel = Self.makeWindow(width: popoverWidth, height: Self.popoverHeight)
        let root = PopoverView.root(app: app, model: model, list: model.list(.window), avatars: avatars, actions: surface, surface: .window)
        let title = WindowTitle.install(in: panel)
        title.show(login: app.account(account)?.login ?? "", color: app.account(account)?.accountColor ?? .none)
        titles[account] = title
        panel.appearance = surfaceAppearance
        panel.contentViewController = SurfaceViewController(root)
        panel.setContentSize(NSSize(width: popoverWidth, height: Self.popoverHeight))
        // The smallest window (the surface's SwiftUI content no longer sets
        // it, SurfaceRoot).
        panel.contentMinSize = NSSize(width: 300, height: 300)
        panel.identifier = NSUserInterfaceItemIdentifier(account)
        panel.delegate = self
        if let saved = app.store.windowFrame(account: account) {
            panel.setFrame(NSRectFromString(saved), display: false)
        } else {
            panel.center()
        }
        panels[account] = panel
        // Never under the least height for the text size (the open
        // options and the list's minimum): raised when it is less.
        root.onMinimumHeight = { [weak self, weak panel] minimum in
            guard let self, let panel else { return }
            self.window(panel, needs: minimum)
        }
        // Keep on top: the panel floats above normal windows while on
        // (NSWindow.level; .floating is in front of every normal-level
        // window). Applied now and whenever the pin is pressed.
        pinWatch[account] = app.viewModel(account).$keepOnTop.sink { [weak panel] on in
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

    /// DESIGN.md, "Open in window" and "UI": a window with the standard
    /// title bar, which is part 1 of the header: the close, minimize and
    /// zoom buttons and, as its centered title, the account's color mark and
    /// name (`WindowTitle`). The content starts at part 2. The green button
    /// zooms instead of going full screen
    /// (`NSWindowCollectionBehaviorFullScreenNone`, NSWindow.h: "The window
    /// can not be made fullscreen when this bit is set"); the other
    /// collection behaviors stay as 0.6's panel had them (none).
    static func makeWindow(width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenNone)
        return window
    }

    /// The window's least content height: its minimum size, and its
    /// height raised to it (the top edge stays; within the screen's room).
    private func window(_ panel: NSWindow, needs minimum: CGFloat) {
        panel.contentMinSize = NSSize(width: 300, height: minimum)
        let content = panel.contentRect(forFrameRect: panel.frame).height
        guard content < minimum - 0.5 else { return }
        let chrome = panel.frame.height - content
        let room = (panel.screen ?? NSScreen.main).map { panel.frame.maxY - $0.visibleFrame.minY - chrome } ?? minimum
        let height = SurfaceHeight(user: content).raised(to: minimum, room: room)
        guard height > content + 0.5 else { return }
        var frame = panel.frame
        frame.origin.y -= height - content
        frame.size.height += height - content
        panel.setFrame(frame, display: true)
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
            titles[account] = nil
            pinWatch[account] = nil
            onWindowClosed?(account)
        }
    }

    // MARK: - Keys

    /// Whether keys go to a text field: the search field's editor.
    static func isTyping(_ responder: NSResponder?) -> Bool {
        responder is NSText
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
            press, inSearch: inSearch, hasSearchText: !(model?.search.isEmpty ?? true), inDismissed: model?.showingDismissed ?? false,
            hasSelection: model.map { $0.selection != nil || !$0.selectedCards.isEmpty } ?? false,
            confirming: model?.confirmingDismiss != nil
        )
        switch decided {
        case .quit:
            onQuit?()
        case .pass:
            return false
        case .ignore:
            break
        case .answerDismiss(let confirmed):
            model?.answerDismiss(confirmed)
        case .textSize(let change):
            guard model != nil else { return false }
            app.changeTextSize(change)
        case .refresh:
            guard let account else { return false }
            app.refreshByKey(account)
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
    /// focus: the same as ⌘C there (the link of the selected card or row). False when another window has the focus,
    /// or the search field does: the menu's own `copy:` goes on.
    func copyFromMenu() -> Bool {
        pressFromMenu(.copy)
    }

    /// Edit › Select All chosen with the mouse: as ⌘A, every card shown
    /// (DESIGN.md, "Switching to a regular app"); in the search field the
    /// field's own `selectAll:` goes on.
    func selectAllFromMenu() -> Bool {
        pressFromMenu(.selectAll)
    }

    private func pressFromMenu(_ press: Key) -> Bool {
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
        model.press(press)
        return true
    }
}

/// The title of an account's window (DESIGN.md, "Open in window"): in the
/// standard title bar, centered, the account's color mark (a rounded square;
/// none for the color None, without its room) and the account's name, cut
/// with `…` when it does not fit. Neither follows the text size setting.
///
/// AppKit's title is text only: `NSWindow` has `title` and `subtitle`
/// (strings), and its document icon (`representedURL` with
/// `standardWindowButton(.documentIconButton)`) is a proxy with a path menu
/// and drag. A titlebar accessory (NSTitlebarAccessoryViewController.h) is
/// placed under the title bar or beside the buttons, and at the top only
/// with `fullSizeContentView`, without the normal title bar. So the window
/// keeps its standard title bar and buttons, hides only its title text
/// (`titleVisibility`; `title` stays the login, for Mission Control and the
/// Window menu), and this view takes the title's place in the title bar
/// (the close button's superview), centered on the buttons' line. Presses
/// go through it to the title bar, which moves and zooms the window.
@MainActor
final class WindowTitle {
    /// Room kept on either side, past the three buttons (Main.html
    /// `.win2 .tbar .ttl`).
    static let side: CGFloat = 76
    /// Between the mark and the name.
    static let gap: CGFloat = 7

    let stack: PassThroughStack
    let mark: AccountMarkView
    let name: NSTextField
    private var watch: [NSObjectProtocol] = []

    private init() {
        mark = AccountMarkView()
        name = NSTextField(labelWithString: "")
        name.font = NSFont.titleBarFont(ofSize: 0)
        name.lineBreakMode = .byTruncatingTail
        name.cell?.truncatesLastVisibleLine = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack = PassThroughStack(views: [mark, name])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Self.gap
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Puts the title in the window's title bar.
    static func install(in window: NSWindow) -> WindowTitle {
        let title = WindowTitle()
        window.titleVisibility = .hidden
        guard let close = window.standardWindowButton(.closeButton), let bar = close.superview else { return title }
        bar.addSubview(title.stack)
        NSLayoutConstraint.activate([
            title.stack.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            title.stack.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            title.stack.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: side),
            title.stack.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -side),
            title.mark.widthAnchor.constraint(equalToConstant: AccountMarkView.size),
            title.mark.heightAnchor.constraint(equalToConstant: AccountMarkView.size),
        ])
        // The title dims while the window is not key, as AppKit's own.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            title.watch.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak title, weak window] _ in
                MainActor.assumeIsolated { title?.dim(window?.isKeyWindow != true) }
            })
        }
        title.dim(!window.isKeyWindow)
        return title
    }

    func show(login: String, color: AccountColor) {
        if name.stringValue != login {
            name.stringValue = login
            stack.window?.title = login
        }
        mark.color = color
        mark.isHidden = !color.showsDot
    }

    private func dim(_ dimmed: Bool) {
        name.textColor = dimmed ? .tertiaryLabelColor : .labelColor
    }
}

/// A stack the pointer goes through: a press on the title is the title
/// bar's (it moves the window; a double click zooms it).
final class PassThroughStack: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The account color's mark, drawn in the color it resolves to for the
/// view's appearance (DESIGN.md, "Account color": a 10-point square with a
/// 2.5-point radius).
final class AccountMarkView: NSView {
    static let size: CGFloat = 10
    static let radius: CGFloat = 2.5

    var color: AccountColor = .none { didSet { if color != oldValue { needsDisplay = true } } }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

    override func draw(_ dirtyRect: NSRect) {
        guard let fill = color.nsColor else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius).fill()
    }
}
