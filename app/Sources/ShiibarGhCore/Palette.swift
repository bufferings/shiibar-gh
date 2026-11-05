// Colors of the boards, as sRGB hex values, each with a dark variant: the
// app follows the macOS light and dark appearance, and the boards are light
// only (DESIGN.md, "UI"). The dark values keep the boards' roles (text,
// secondary text, orange to-do rows, status colors) on dark surfaces and are
// checked by the owner on the device.
//
// The scope colors are the six of DESIGN.md, "Overview and scope": the
// boards' three (gray #F3F4F8, green #EAF4F0, beige #F7F1E3) and three more
// of the same lightness. Each comes with the shades the popover draws with
// it: the border of cards and tabs, the tint of controls, and the hover color
// (docs/design/Main.html for gray, PublicScope.html for beige).

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

/// One color in the light and the dark appearance.
public struct Shade: Equatable {
    public var light: RGB
    public var dark: RGB

    public init(_ light: UInt32, _ dark: UInt32) {
        self.light = RGB(hex: light)
        self.dark = RGB(hex: dark)
    }

    public func resolve(dark isDark: Bool) -> RGB {
        isDark ? dark : light
    }
}

public struct ScopeTheme: Equatable {
    public var background: Shade
    public var border: Shade
    public var tint: Shade
    public var hover: Shade
    /// The swatch outline in Settings and the menu bar board.
    public var swatchBorder: Shade
}

public enum Palette {
    public static func theme(_ color: ScopeColor) -> ScopeTheme {
        switch color {
        case .gray:
            return ScopeTheme(background: Shade(0xF3F4F8, 0x1E1F23), border: Shade(0xE3E3E6, 0x34353A), tint: Shade(0xECECEF, 0x2C2D32), hover: Shade(0xF4F4F6, 0x26272B), swatchBorder: Shade(0xD6D6DA, 0x45464C))
        case .green:
            return ScopeTheme(background: Shade(0xEAF4F0, 0x17241F), border: Shade(0xD3E4DC, 0x2A3D35), tint: Shade(0xDCEBE4, 0x22342C), hover: Shade(0xF2F8F5, 0x1C2B25), swatchBorder: Shade(0xC9DDD4, 0x3A5247))
        case .blue:
            return ScopeTheme(background: Shade(0xEAF0F9, 0x18202D), border: Shade(0xD4DEEE, 0x2B3850), tint: Shade(0xDDE6F3, 0x233047), hover: Shade(0xF3F6FB, 0x1C2636), swatchBorder: Shade(0xC8D5EA, 0x3B4C6B))
        case .purple:
            return ScopeTheme(background: Shade(0xF1EEF8, 0x211C2D), border: Shade(0xDFD8EC, 0x3A3150), tint: Shade(0xE6E0F2, 0x2E2742), hover: Shade(0xF6F4FB, 0x262036), swatchBorder: Shade(0xD6CDE8, 0x4C4066))
        case .pink:
            return ScopeTheme(background: Shade(0xF8EEF0, 0x2B1C20), border: Shade(0xECD8DC, 0x4A3036), tint: Shade(0xF1E1E4, 0x3B272C), hover: Shade(0xFBF5F6, 0x322126), swatchBorder: Shade(0xE6CDD2, 0x5E3F46))
        case .beige:
            return ScopeTheme(background: Shade(0xF7F1E3, 0x29241A), border: Shade(0xE6DCC6, 0x453C2B), tint: Shade(0xEDE4D0, 0x383022), hover: Shade(0xFAF6EC, 0x30291E), swatchBorder: Shade(0xE6DCC6, 0x574C37))
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

    // Fixed colors of the boards, light first.
    public static let text = Shade(0x1D1D1F, 0xECECEE)
    public static let secondary = Shade(0x5E5E64, 0xA1A1A8)
    public static let faded = Shade(0x8A8A90, 0x76767C)
    public static let link = Shade(0x0A5FC2, 0x4C9BFF)
    public static let blueDot = Shade(0x0A66D6, 0x3D8BFF)
    public static let badge = Shade(0xC7420D, 0xE0582A)
    public static let orangeText = Shade(0xA0390A, 0xF08A5D)
    public static let orangeRow = Shade(0xFFF8F3, 0x3A2A22)
    public static let orangeIcon = Shade(0xA8410B, 0xF39A6B)
    public static let orangeIconBackground = Shade(0xFCE9DC, 0x4A2E20)
    public static let green = Shade(0x1F8A3E, 0x2FA352)
    public static let greenText = Shade(0x1F6E35, 0x5CCB7E)
    public static let greenBackground = Shade(0xE2F2E6, 0x1F3A28)
    public static let purple = Shade(0x6F42C1, 0x9B72E6)
    public static let purpleText = Shade(0x5A2CA0, 0xC3A6F5)
    public static let purpleBackground = Shade(0xEDE6FA, 0x352A4A)
    public static let gray = Shade(0x9A9AA0, 0x7C7C82)
    public static let waiting = Shade(0x6E6E76, 0x9A9AA2)
    public static let infoIcon = Shade(0x0A5FC2, 0x6AA8FF)
    public static let infoIconBackground = Shade(0xE4EEFB, 0x1F3047)
    public static let botIcon = Shade(0x55555B, 0xB4B4BA)
    public static let bannerBackground = Shade(0xFFF4D6, 0x3D3418)
    public static let bannerText = Shade(0x6B4E00, 0xF2D37A)
    public static let publicName = Shade(0x7A5A00, 0xE3C26A)
    public static let caution = Shade(0x8A5A00, 0xE6B04D)
    public static let surface = Shade(0xFFFFFF, 0x2B2B2F)
    public static let controlBorder = Shade(0xC9C9CE, 0x55555B)
    public static let strongText = Shade(0x3A3A3F, 0xD0D0D5)
    public static let draftText = Shade(0x4A4A50, 0xC4C4CA)
    public static let rowDivider = Shade(0xF0F0F2, 0x38383D)
    public static let snoozeIcon = Shade(0xB0B0B6, 0x7C7C82)
    public static let avatarFill = Shade(0xEBEBEB, 0x3A3A3F)
    public static let avatarBorder = Shade(0xD9D9D9, 0x4A4A50)
    public static let onColor = Shade(0xFFFFFF, 0xFFFFFF)
    public static let settingsBackground = Shade(0xF6F6F7, 0x1E1E20)
    public static let settingsTabBar = Shade(0xEDEDF0, 0x2A2A2D)
    public static let settingsTabBarBorder = Shade(0xD6D6DA, 0x3F3F44)
    public static let settingsTabSelected = Shade(0x0A4FA6, 0x7DB4FF)
    public static let settingsTabSelectedBackground = Shade(0xDCE7F7, 0x1F3A5C)
    public static let groupBorder = Shade(0xE3E3E6, 0x3A3A3F)
    public static let itemDivider = Shade(0xECECEF, 0x343438)
}
