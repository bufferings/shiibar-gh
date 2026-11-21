// The form each account is used in (the popover or the window) and what a
// click on its menu bar icon or its global shortcut does with it (DESIGN.md,
// "Open in window", "Surface form", "`Open in popover`", "Switching to a
// regular app"). The AppKit calls live in the app; the decisions live here
// so tests pin them.

import Foundation

/// The surface an account opens in from its icon, its global shortcut and
/// its notifications. Saved per account; the popover when nothing (or
/// nothing readable) is saved.
public enum SurfaceForm: String, Equatable, Sendable {
    case popover
    case window

    public var surface: Surface {
        switch self {
        case .popover: return .popover
        case .window: return .window
        }
    }
}

/// What a click on an account's menu bar icon (either button) or its global
/// shortcut does (DESIGN.md, "Surface form", the table).
public enum SurfaceToggle: Equatable, Sendable {
    case openPopover
    case closePopover
    case openWindow
    case raiseWindow
    case closeWindow
    case nothing

    /// - Parameters:
    ///   - form: the account's surface form.
    ///   - popoverShownForAccount: the popover shows this account.
    ///   - windowOpen: the account's window is open (minimized included).
    ///   - windowFront: the window is in front (`WindowFront.isFront`),
    ///     read before the press acted on anything.
    ///   - sheetShown: the window shows a sheet (Grouping, a Dismiss
    ///     confirmation).
    ///   - blocked: an app-modal dialog or a menu is open: nothing happens.
    ///
    /// The popover and the window of one account never show together, so
    /// the popover shown for the account closes and the open window follows
    /// the window's rows whatever the saved form says; otherwise the form
    /// decides what opens.
    public static func decide(
        form: SurfaceForm, popoverShownForAccount: Bool, windowOpen: Bool, windowFront: Bool, sheetShown: Bool,
        blocked: Bool = false
    ) -> SurfaceToggle {
        if blocked { return .nothing }
        if popoverShownForAccount { return .closePopover }
        if windowOpen {
            guard windowFront else { return .raiseWindow }
            // A sheet asks for an answer: the window is not closed under it.
            return sheetShown ? .nothing : .closeWindow
        }
        switch form {
        case .popover: return .openPopover
        case .window: return .openWindow
        }
    }

    /// What a clicked notification does: the account's surface opens or
    /// comes to the front, and is never closed (DESIGN.md, "macOS
    /// notifications").
    public static func forNotification(form: SurfaceForm, windowOpen: Bool) -> SurfaceToggle {
        if windowOpen { return .raiseWindow }
        switch form {
        case .popover: return .openPopover
        case .window: return .openWindow
        }
    }
}

/// "The window is in front" (DESIGN.md, "Surface form"): the app is active,
/// the window is key (or its sheet is), it is not minimized, and it is on
/// the current Space. A window kept on top by `Keep on top` is not in front
/// while it is not key.
public enum WindowFront {
    public static func isFront(appActive: Bool, windowKey: Bool, sheetKey: Bool, miniaturized: Bool, onActiveSpace: Bool) -> Bool {
        appActive && (windowKey || sheetKey) && !miniaturized && onActiveSpace
    }
}

/// Whether a state held when the press happened: a press on the menu bar
/// can activate the app and make a window key before the click's action
/// runs. A state gained at or after the press's own time was gained by the
/// press, so it did not hold before it. Times are system uptime seconds
/// (`NSEvent.timestamp`, `GetEventTime`).
public enum StateAtPress {
    public static func held(now: Bool, since: TimeInterval?, pressedAt: TimeInterval?) -> Bool {
        guard now else { return false }
        guard let since, let pressedAt else { return true }
        return since < pressedAt
    }
}

/// The level of Settings and the About panel (DESIGN.md, "Open in
/// window"): floating while any open window (minimized included) has
/// `Keep on top` on, so they open in front of it; normal otherwise.
public enum AuxiliaryLevel: Equatable, Sendable {
    case normal
    case floating

    public static func level(pinnedWindowOpen: Bool) -> AuxiliaryLevel {
        pinnedWindowOpen ? .floating : .normal
    }

    /// `pins`: Keep on top of each open window, by account. `closing`: a
    /// window that is closing (still on screen while it closes) does not
    /// count.
    public static func level(pins: [String: Bool], closing: String? = nil) -> AuxiliaryLevel {
        level(pinnedWindowOpen: pins.contains { $0.key != closing && $0.value })
    }
}

/// What a switch of form carries to the other surface (DESIGN.md, "Surface
/// form"): the tab shown and whether the Dismissed list is open. The search
/// texts are the account's, shared by both. The selection and the scroll
/// position stay behind: the other surface follows its rules for a surface
/// that opens.
public struct SurfaceHandoff: Equatable {
    public var tab: ListTab
    public var dismissed: Bool

    public init(tab: ListTab, dismissed: Bool) {
        self.tab = tab
        self.dismissed = dismissed
    }

    /// Read from the surface being left, before it closes (closing drops
    /// its Dismissed list).
    @MainActor
    public static func read(from list: SurfaceListModel) -> SurfaceHandoff {
        SurfaceHandoff(tab: list.tab, dismissed: list.showingDismissed)
    }

    /// Given to the surface about to open: the tab, remembered as its last
    /// tab, and the Dismissed list.
    @MainActor
    public func apply(to list: SurfaceListModel) {
        list.receive(self)
    }
}

/// The window's frame when it opens (DESIGN.md, "Open in window"): a saved
/// size under the least one is raised to it, the top and left edges
/// staying. Frames are AppKit's (the origin at the bottom left).
public enum WindowMinimum {
    public static func frame(_ frame: CGRect, minimum: CGSize) -> CGRect {
        let width = max(frame.width, minimum.width)
        let height = max(frame.height, minimum.height)
        return CGRect(x: frame.minX, y: frame.maxY - height, width: width, height: height)
    }
}
