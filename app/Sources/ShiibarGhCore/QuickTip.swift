// Every tooltip of the surfaces: the icon buttons, the pop-up buttons, the
// tab row's toggles, and the avatar, the times and `Dismissed in N days`
// drawn in a card (DESIGN.md, "Screens": all after about 0.4 s, sooner than
// macOS's standard; 0.4.0 showed them later).
//
// AppKit's own tooltips (`NSView.toolTip`) and SwiftUI's `.help` have no
// public setting for their delay: NSView.h declares `toolTip` and
// `addToolTipRect:owner:userData:` only, and the user default some apps
// set for it is not in the SDK headers or Apple's documentation, so it is
// not used here. They show this small window instead, after `delay`, with
// a timer of their own: nothing runs until the pointer rests on a part with
// a tooltip, so scrolling costs nothing more.
//
// API used, as declared in the SDK headers: `NSEvent.mouseLocation` (the
// pointer in screen coordinates, NSEvent.h), `CGWindowLevelForKey` with
// `kCGHelpWindowLevelKey` (the level of help windows, CGWindowLevel.h),
// `NSFont.toolTipsFont(ofSize:)` (NSFont.h), and a local event monitor
// (`addLocalMonitorForEvents`, NSEvent.h) that hides the tip on a press, a
// scroll or a key.

import AppKit
import SwiftUI

@MainActor
public enum QuickTip {
    /// From resting on the button to the tip.
    public static let delay: TimeInterval = 0.4

    /// Who asked for the tip: a later request or a cancel from someone else
    /// does not touch it.
    public final class Owner {
        public init() {}
    }

    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var timer: Timer?
    private static weak var owner: Owner?
    private static var monitor: Any?

    /// Shows `text` near the pointer after `delay`, unless cancelled.
    public static func schedule(_ text: String, owner: Owner, appearance: NSAppearance?) {
        cancel()
        self.owner = owner
        pending = (text, appearance)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { showPending() }
        }
    }

    /// What the running timer shows: kept here, not captured by the timer's
    /// `@Sendable` closure (an `NSAppearance` is not Sendable).
    private static var pending: (text: String, appearance: NSAppearance?)?

    private static func showPending() {
        guard let pending else { return }
        self.pending = nil
        show(pending.text, appearance: pending.appearance, at: nil)
    }

    /// Hides the tip (and stops a pending one) of `owner`, or any with nil.
    public static func cancel(owner: Owner? = nil) {
        if let owner, owner !== self.owner { return }
        timer?.invalidate()
        timer = nil
        pending = nil
        self.owner = nil
        bubbleOwner = nil
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// `text` at once, right of `rect` (screen coordinates), for `seconds`:
    /// `Copied` after the chain icon is pressed.
    public static func bubble(_ text: String, beside rect: NSRect, seconds: TimeInterval, appearance: NSAppearance?) {
        cancel()
        let owner = Owner()
        bubbleOwner = owner
        self.owner = owner
        // Kept while it shows (`owner` is weak).
        show(text, appearance: appearance, at: NSPoint(x: rect.maxX + 4, y: rect.midY))
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            // The timer is the bubble's own: a later tip or cancel stops it.
            MainActor.assumeIsolated { cancel(owner: bubbleOwner) }
        }
    }

    private static var bubbleOwner: Owner?

    /// Whether a tip shows now (tests).
    public static var isShown: Bool { panel?.isVisible == true }

    /// `at`: the left middle of the tip (a bubble); nil below and right of
    /// the pointer (a tooltip).
    private static func show(_ text: String, appearance: NSAppearance?, at point: NSPoint? = nil) {
        timer = nil
        let panel = self.panel ?? makePanel()
        guard let label else { return }
        panel.appearance = appearance
        label.stringValue = text
        let size = label.fittingSize
        let content = NSSize(width: ceil(size.width) + 12, height: ceil(size.height) + 6)
        label.frame = NSRect(x: 6, y: 3, width: ceil(size.width), height: ceil(size.height))
        // Below and right of the pointer, as AppKit's tips are, inside the
        // screen the pointer is on.
        let mouse = point ?? NSEvent.mouseLocation
        var origin = point.map { NSPoint(x: $0.x, y: $0.y - content.height / 2) } ?? NSPoint(x: mouse.x + 2, y: mouse.y - 22 - content.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame {
            origin.x = min(max(screen.minX, origin.x), screen.maxX - content.width)
            if origin.y < screen.minY { origin.y = mouse.y + 8 }
        }
        panel.setFrame(NSRect(origin: origin, size: content), display: true)
        panel.orderFront(nil)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
            ) { event in
                MainActor.assumeIsolated { cancel() }
                return event
            }
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.helpWindow)))
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 4
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .windowBackgroundColor
        box.contentViewMargins = .zero
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        box.contentView?.addSubview(label)
        panel.contentView = box
        self.panel = panel
        self.label = label
        return panel
    }
}

/// `.quickHelp(text)`: the icon buttons' tooltip (QuickTip), shown sooner
/// than `.help`; the text is also the element's accessibility help.
private struct QuickHelp: ViewModifier {
    var text: String
    @State private var owner = QuickTip.Owner()

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside {
                    QuickTip.schedule(text, owner: owner, appearance: NSApp.keyWindow?.effectiveAppearance)
                } else {
                    QuickTip.cancel(owner: owner)
                }
            }
            .onDisappear { QuickTip.cancel(owner: owner) }
            .accessibilityHint(text)
    }
}

extension View {
    public func quickHelp(_ text: String) -> some View {
        modifier(QuickHelp(text: text))
    }
}
