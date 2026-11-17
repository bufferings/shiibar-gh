// The boards' icons and colors in AppKit and SwiftUI.

import AppKit
import Combine
import ShiibarGhCore
import SwiftUI

/// The generation of the system colors. The list's lines and controls keep
/// images drawn with resolved colors (ListCells.swift, `LineView.DrawKey`),
/// and an accent color change resolves the same appearance to other colors:
/// each change counts here, the lines take the count and the accent color
/// itself into their key, and every view of the app's windows is drawn
/// again. Apple documents `systemColorsDidChangeNotification` as "sent when
/// the system colors have changed, such as through a system control panel
/// interface" (developer.apple.com, NSColor, checked 2026-11-17); the page
/// does not name the accent color, so a line configured again (a minute's
/// tick, a reload) also compares the accent color it was drawn with. The
/// light and dark switch (`NSApp.effectiveAppearance`, observed as
/// AppDelegate.swift does) is counted as well, though each view also hears
/// of it itself.
@MainActor
enum SystemColors {
    private(set) static var epoch = 0

    /// The accent color now, as sRGB components (a key, not a color to draw).
    static var accent: [CGFloat] {
        let color = Palette.accent.resolved(dark: false)
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    }
    static let changed = PassthroughSubject<Void, Never>()
    private static var observers: [Any] = []

    /// Starts watching (once, at launch).
    static func watch() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { bump() } })
        observers.append(NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { bump() }
        })
    }

    /// A change: the next drawing resolves the colors again.
    static func bump() {
        epoch += 1
        changed.send()
        for window in NSApp.windows {
            if let view = window.contentView?.superview ?? window.contentView { redraw(view) }
        }
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews { redraw(subview) }
    }
}
