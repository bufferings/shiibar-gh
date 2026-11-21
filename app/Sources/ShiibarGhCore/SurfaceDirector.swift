// What the menu bar icons, the global shortcuts, the notifications and the
// header's `Open in window` / `Open in popover` do with the popover and the
// windows, in which order (DESIGN.md, "Surface form", "`Open in popover`",
// "Switching to a regular app", "macOS notifications"). The AppKit calls
// are the host's (`SurfaceController`); the order and the decisions are
// here, so tests run them with a fake host.

import Foundation

/// The state of an open window, read before anything moves.
public struct WindowFacts: Equatable {
    public var appActive: Bool
    /// When the app last became active (system uptime), if known.
    public var becameActiveAt: TimeInterval?
    public var key: Bool
    /// When the window last became key (system uptime), if known.
    public var becameKeyAt: TimeInterval?
    public var sheetKey: Bool
    public var miniaturized: Bool
    public var onActiveSpace: Bool
    /// An AppKit sheet is attached to the window.
    public var attachedSheet: Bool

    public init(
        appActive: Bool, becameActiveAt: TimeInterval? = nil, key: Bool, becameKeyAt: TimeInterval? = nil, sheetKey: Bool = false,
        miniaturized: Bool = false, onActiveSpace: Bool = true, attachedSheet: Bool = false
    ) {
        self.appActive = appActive
        self.becameActiveAt = becameActiveAt
        self.key = key
        self.becameKeyAt = becameKeyAt
        self.sheetKey = sheetKey
        self.miniaturized = miniaturized
        self.onActiveSpace = onActiveSpace
        self.attachedSheet = attachedSheet
    }

    /// In front as it was when the press happened (`StateAtPress`).
    public func front(pressedAt: TimeInterval?) -> Bool {
        WindowFront.isFront(
            appActive: StateAtPress.held(now: appActive, since: becameActiveAt, pressedAt: pressedAt),
            windowKey: StateAtPress.held(now: key, since: becameKeyAt, pressedAt: pressedAt),
            sheetKey: sheetKey, miniaturized: miniaturized, onActiveSpace: onActiveSpace
        )
    }
}

/// The AppKit side of the surfaces.
@MainActor
public protocol SurfaceHosting: AnyObject {
    /// The popover shows (any account's, or the one without an account).
    var popoverShown: Bool { get }
    /// The account the popover shows; nil while none or without an account.
    var popoverAccount: String? { get }
    /// An app-modal dialog or a menu is open.
    var blocked: Bool { get }
    /// The account's window, nil while it is not open (minimized is open).
    func windowFacts(_ account: String) -> WindowFacts?
    /// Shows the account's popover from its icon, replacing one that shows;
    /// false when it could not (no icon).
    func presentPopover(_ account: String) -> Bool
    func closePopover()
    /// Opens the account's window, or brings it to the front with the
    /// focus (back from the Dock, to the current Space).
    func presentWindow(_ account: String)
    func closeWindow(_ account: String)
    /// The window is a reason for the app to be regular.
    func windowWillShow(_ account: String)
    /// `Open in popover`: the popover it opens keeps the app regular.
    func holdPopover()
    /// The held popover did not show: the hold ends.
    func popoverHoldEnded()
}

@MainActor
public final class SurfaceDirector {
    public let app: AppModel
    public weak var host: SurfaceHosting?

    public init(app: AppModel) {
        self.app = app
    }

    /// The global shortcuts act as the icons do.
    public func attach(_ shortcuts: GlobalShortcutCenter) {
        shortcuts.onPressed = { [weak self] account in self?.toggle(account: account, pressedAt: nil) }
    }

    /// The account's menu bar icon or its global shortcut (the table of
    /// "Surface form"). Everything is read first, before anything moves.
    public func toggle(account: String, pressedAt: TimeInterval?) {
        guard let host else { return }
        let facts = host.windowFacts(account)
        let list = app.viewModel(account).list(.window)
        let sheet = facts != nil && (list.showsGrouping || list.confirmingDismiss != nil || facts?.attachedSheet == true)
        let action = SurfaceToggle.decide(
            form: app.store.surfaceForm(account: account), popoverShownForAccount: host.popoverShown && host.popoverAccount == account,
            windowOpen: facts != nil, windowFront: facts?.front(pressedAt: pressedAt) ?? false, sheetShown: sheet, blocked: host.blocked
        )
        perform(action, account: account)
    }

    /// A clicked notification: opens or brings to the front, never closes.
    public func showForNotification(account: String) {
        guard let host else { return }
        perform(SurfaceToggle.forNotification(form: app.store.surfaceForm(account: account), windowOpen: host.windowFacts(account) != nil), account: account)
    }

    func perform(_ action: SurfaceToggle, account: String) {
        switch action {
        case .openPopover: showPopover(account: account)
        case .closePopover: host?.closePopover()
        case .openWindow, .raiseWindow: openWindow(account: account)
        case .closeWindow: host?.closeWindow(account)
        case .nothing: break
        }
    }

    /// Opens the account's popover; nothing while it shows already or while
    /// the account's window is open (the two never show together).
    @discardableResult
    public func showPopover(account: String) -> Bool {
        guard let host, host.windowFacts(account) == nil else { return false }
        if host.popoverShown && host.popoverAccount == account { return true }
        return host.presentPopover(account)
    }

    /// Opens the account's window in front, or brings it to the front; the
    /// popover closes, whichever account's it is. The window becomes a
    /// reason to stay regular before the popover closes. The form does not
    /// change.
    public func openWindow(account: String) {
        guard let host else { return }
        host.windowWillShow(account)
        if host.popoverShown { host.closePopover() }
        host.presentWindow(account)
    }

    /// `Open in window`: the form becomes the window; the window opens on
    /// the tab the popover showed, with its Dismissed list if it was open.
    public func openInWindow(account: String) {
        guard let host else { return }
        let handoff = SurfaceHandoff.read(from: app.viewModel(account).list(.popover))
        app.store.setSurfaceForm(.window, account: account)
        if host.windowFacts(account) == nil { handoff.apply(to: app.viewModel(account).list(.window)) }
        openWindow(account: account)
    }

    /// `Open in popover`: the form becomes the popover; the hold is set
    /// before the window closes, the tab and the Dismissed list are carried,
    /// the popover opens; if it did not, the hold ends.
    public func openInPopover(account: String) {
        guard let host, host.windowFacts(account) != nil else { return }
        let handoff = SurfaceHandoff.read(from: app.viewModel(account).list(.window))
        app.store.setSurfaceForm(.popover, account: account)
        host.holdPopover()
        host.closeWindow(account)
        handoff.apply(to: app.viewModel(account).list(.popover))
        if !showPopover(account: account) || !(host.popoverShown && host.popoverAccount == account) { host.popoverHoldEnded() }
    }
}
