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

extension AccountColor {
    /// DESIGN.md, "Account colors": the macOS system colors, which Apple
    /// documents as adapting to vibrancy and accessibility settings
    /// (NSColor.systemRed, "Returns a color object for red that
    /// automatically adapts to vibrancy and accessibility settings"). None
    /// has no color: the icon takes the menu bar's own and the dot the text
    /// color.
    public var nsColor: NSColor? {
        switch self {
        case .none: return nil
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        }
    }

    /// The dot before the account name: the color, or the text color.
    public var dotColor: Color {
        nsColor.map { Color(nsColor: $0) } ?? Palette.text.color
    }
}

extension Account {
    /// An unknown color reads as None.
    public var accountColor: AccountColor { color.value ?? .none }
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
