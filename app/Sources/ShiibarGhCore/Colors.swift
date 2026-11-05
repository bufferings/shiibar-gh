// The palette as AppKit and SwiftUI colors, and which appearance a surface
// uses (DESIGN.md, "UI": the Appearance setting, System following the Mac).

import AppKit
import SwiftUI

extension RGB {
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

extension NSAppearance {
    public var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Shade {
    /// A color that follows the light or dark appearance it is drawn in.
    public var nsColor: NSColor {
        let light = self.light.nsColor
        let dark = self.dark.nsColor
        return NSColor(name: nil) { appearance in appearance.isDark ? dark : light }
    }

    public var color: Color { Color(nsColor: nsColor) }
}

public enum SurfaceAppearance {
    /// Dark or light for the popover, the window and Settings: the setting
    /// when it is Light or Dark, the Mac's own when it is System.
    public static func isDark(setting: AppAppearance, systemDark: Bool) -> Bool {
        switch setting {
        case .system: return systemDark
        case .light: return false
        case .dark: return true
        }
    }

    /// The appearance set on each surface. Set explicitly, never inherited:
    /// a popover inherits from the view it is anchored to, and a status
    /// item's button carries the menu bar's appearance, which macOS picks
    /// for the wallpaper rather than for the app.
    public static func named(dark: Bool) -> NSAppearance.Name {
        dark ? .darkAqua : .aqua
    }
}
