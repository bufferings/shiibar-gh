// Colors of the boards, as sRGB hex values, each with a dark variant: the
// app follows the macOS light and dark appearance, and the boards are light
// only (DESIGN.md, "UI"). The dark values keep the boards' roles (text,
// secondary text, status colors) on dark surfaces and are
// checked by the owner on the device.
//
// Account colors are macOS system colors (Colors.swift), not listed here.

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

public enum Palette {
    /// The popover background, the same for every account (DESIGN.md,
    /// "Account colors"), and the shades drawn on it (Main.html).
    public static let background = Shade(0xF3F4F8, 0x1E1F23)
    public static let border = Shade(0xE3E3E6, 0x34353A)
    public static let tint = Shade(0xECECEF, 0x2C2D32)
    public static let hover = Shade(0xF4F4F6, 0x26272B)
    /// The board's `.tg.on` and `.seg`: the on state of a toggle button
    /// follows the macOS accent color in the app (DESIGN.md, "Screens").
    public static let segmentTrack = Shade(0xE4E4E8, 0x3A3A3F)
    /// A selected header, row or "+ N more PRs" (Main.html `.sel`).
    public static let selection = Shade(0xDCE7F7, 0x1F3A5C)
    /// The `Review requested` mark (Main.html `.rq`), with `orangeText`.
    public static let reviewMark = Shade(0xFBE3D6, 0x4A2E20)
    /// A read row's kind icon (Main.html `.ev.rd .ki`).
    public static let readIcon = Shade(0x9A9AA0, 0x6A6A70)
    public static let sidebar = Shade(0xF0F0F2, 0x252528)

    // Fixed colors of the boards, light first.
    public static let text = Shade(0x1D1D1F, 0xECECEE)
    public static let secondary = Shade(0x5E5E64, 0xA1A1A8)
    public static let faded = Shade(0x8A8A90, 0x76767C)
    public static let link = Shade(0x0A5FC2, 0x4C9BFF)
    public static let blueDot = Shade(0x0A66D6, 0x3D8BFF)
    public static let badge = Shade(0xC7420D, 0xE0582A)
    public static let orangeText = Shade(0xA0390A, 0xF08A5D)
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
    public static let caution = Shade(0x8A5A00, 0xE6B04D)
    public static let surface = Shade(0xFFFFFF, 0x2B2B2F)
    public static let controlBorder = Shade(0xC9C9CE, 0x55555B)
    public static let strongText = Shade(0x3A3A3F, 0xD0D0D5)
    public static let draftText = Shade(0x4A4A50, 0xC4C4CA)
    public static let rowDivider = Shade(0xF0F0F2, 0x38383D)
    /// The band heading of a section or a first-level group (Main.html
    /// `.band`).
    public static let band = Shade(0xE4E5EA, 0x2E2F35)
    /// The placement tag in All (Main.html `.tag`).
    public static let tagBorder = Shade(0x9DB9E4, 0x3A5A86)
    public static let tagBackground = Shade(0xEEF3FB, 0x1C2B40)
    public static let tagText = Shade(0x0A4FA6, 0x8CBBFF)
    /// The outlined `Assigned` and `Muted` marks (Main.html `.mk`).
    public static let markBorder = Shade(0xB8B8BE, 0x5A5A60)
    /// A muted card (Main.html `.card.muted`): the title, the other text,
    /// the kind icons, and the ring of a muted unread row.
    public static let mutedTitle = Shade(0x8A8A90, 0x7E7E84)
    public static let mutedText = Shade(0x9A9AA0, 0x74747A)
    public static let mutedIcon = Shade(0xAEAEB4, 0x626268)
    /// The grip ⋮⋮ (Main.html `.grip`).
    public static let grip = Shade(0xA6A6AC, 0x6E6E74)
    /// The usage bar (Main.html `.apibar`).
    public static let usageTrack = Shade(0xDCDCE0, 0x3E3F44)
    public static let usageFill = Shade(0x8A8A90, 0x9A9AA0)
    public static let usageWarnFill = Shade(0xC98A00, 0xE6B04D)
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
