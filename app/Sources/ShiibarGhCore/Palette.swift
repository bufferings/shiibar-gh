// Colors of the boards, as sRGB hex values. The scope colors are the six of
// DESIGN.md, "Overview and scope": the boards' three (gray #F3F4F8, green
// #EAF4F0, beige #F7F1E3) and three more of the same lightness. Each comes
// with the shades the popover draws with it: the border of cards and tabs,
// the tint of controls, and the hover color (docs/design/Main.html for gray,
// PublicScope.html for beige).

import Foundation

public struct RGB: Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }
}

public struct ScopeTheme: Equatable {
    public var background: RGB
    public var border: RGB
    public var tint: RGB
    public var hover: RGB
    /// The swatch outline in Settings and the menu bar board.
    public var swatchBorder: RGB
}

public enum Palette {
    public static func theme(_ color: ScopeColor) -> ScopeTheme {
        switch color {
        case .gray:
            return ScopeTheme(background: RGB(hex: 0xF3F4F8), border: RGB(hex: 0xE3E3E6), tint: RGB(hex: 0xECECEF), hover: RGB(hex: 0xF4F4F6), swatchBorder: RGB(hex: 0xD6D6DA))
        case .green:
            return ScopeTheme(background: RGB(hex: 0xEAF4F0), border: RGB(hex: 0xD3E4DC), tint: RGB(hex: 0xDCEBE4), hover: RGB(hex: 0xF2F8F5), swatchBorder: RGB(hex: 0xC9DDD4))
        case .blue:
            return ScopeTheme(background: RGB(hex: 0xEAF0F9), border: RGB(hex: 0xD4DEEE), tint: RGB(hex: 0xDDE6F3), hover: RGB(hex: 0xF3F6FB), swatchBorder: RGB(hex: 0xC8D5EA))
        case .purple:
            return ScopeTheme(background: RGB(hex: 0xF1EEF8), border: RGB(hex: 0xDFD8EC), tint: RGB(hex: 0xE6E0F2), hover: RGB(hex: 0xF6F4FB), swatchBorder: RGB(hex: 0xD6CDE8))
        case .pink:
            return ScopeTheme(background: RGB(hex: 0xF8EEF0), border: RGB(hex: 0xECD8DC), tint: RGB(hex: 0xF1E1E4), hover: RGB(hex: 0xFBF5F6), swatchBorder: RGB(hex: 0xE6CDD2))
        case .beige:
            return ScopeTheme(background: RGB(hex: 0xF7F1E3), border: RGB(hex: 0xE6DCC6), tint: RGB(hex: 0xEDE4D0), hover: RGB(hex: 0xFAF6EC), swatchBorder: RGB(hex: 0xE6DCC6))
        }
    }

    /// The color of a scope, gray when the daemon sent none or one this build
    /// does not know.
    public static func color(of scope: Scope) -> ScopeColor {
        scope.color?.value ?? (scope.isPublic ? .beige : .gray)
    }

    public static func title(_ color: ScopeColor) -> String {
        color.rawValue.capitalizedFirst
    }

    // Fixed colors of the boards.
    public static let text = RGB(hex: 0x1D1D1F)
    public static let secondary = RGB(hex: 0x5E5E64)
    public static let faded = RGB(hex: 0x8A8A90)
    public static let link = RGB(hex: 0x0A5FC2)
    public static let blueDot = RGB(hex: 0x0A66D6)
    public static let badge = RGB(hex: 0xC7420D)
    public static let orangeText = RGB(hex: 0xA0390A)
    public static let orangeRow = RGB(hex: 0xFFF8F3)
    public static let orangeIcon = RGB(hex: 0xA8410B)
    public static let orangeIconBackground = RGB(hex: 0xFCE9DC)
    public static let green = RGB(hex: 0x1F8A3E)
    public static let greenText = RGB(hex: 0x1F6E35)
    public static let greenBackground = RGB(hex: 0xE2F2E6)
    public static let purple = RGB(hex: 0x6F42C1)
    public static let purpleText = RGB(hex: 0x5A2CA0)
    public static let purpleBackground = RGB(hex: 0xEDE6FA)
    public static let gray = RGB(hex: 0x9A9AA0)
    public static let waiting = RGB(hex: 0x6E6E76)
    public static let infoIcon = RGB(hex: 0x0A5FC2)
    public static let infoIconBackground = RGB(hex: 0xE4EEFB)
    public static let botIcon = RGB(hex: 0x55555B)
    public static let bannerBackground = RGB(hex: 0xFFF4D6)
    public static let bannerText = RGB(hex: 0x6B4E00)
    public static let publicName = RGB(hex: 0x7A5A00)
    public static let caution = RGB(hex: 0x8A5A00)
    public static let white = RGB(hex: 0xFFFFFF)
    public static let controlBorder = RGB(hex: 0xC9C9CE)
}
