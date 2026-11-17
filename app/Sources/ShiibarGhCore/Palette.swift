// The fixed colors of the boards, as sRGB hex values, each with a dark
// variant: the app follows the macOS light and dark appearance (DESIGN.md,
// "UI"). Every other color follows the system colors and the accent color
// (Colors.swift), as do the account colors.

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
    // The fixed colors, light first: GitHub's state colors and the marks
    // drawn in them, the yellow of a usage warning, the texts of a status in
    // Settings, white on a filled mark, and the search match. They read the
    // same in every accent color. The grounds, the lines, the text grays,
    // the selection and the accent color are system colors (Colors.swift).

    /// The `Review requested` mark (Main.html `.rq`), with `orangeText`.
    public static let reviewMark = Shade(0xFBE3D6, 0x4A2E20)
    /// The state colors of a card (Main.html `.st`, `.sbar`) and the ✓ and
    /// × of its status icons.
    public static let badge = Shade(0xC7420D, 0xE0582A)
    public static let orangeText = Shade(0xA0390A, 0xF08A5D)
    public static let orangeIconBackground = Shade(0xFCE9DC, 0x4A2E20)
    public static let green = Shade(0x1F8A3E, 0x2FA352)
    public static let greenText = Shade(0x1F6E35, 0x5CCB7E)
    public static let purple = Shade(0x6F42C1, 0x9B72E6)
    public static let purpleText = Shade(0x5A2CA0, 0xC3A6F5)
    public static let purpleBackground = Shade(0xEDE6FA, 0x352A4A)
    public static let gray = Shade(0x9A9AA0, 0x7C7C82)
    /// The `Draft` label (Main.html `.st` of a draft).
    public static let draftBackground = Shade(0xECECEF, 0x2C2D32)
    public static let draftText = Shade(0x4A4A50, 0xC4C4CA)
    /// A status that needs attention in Settings and the API usage at 80%
    /// or more (Main.html `.api.w`).
    public static let caution = Shade(0x8A5A00, 0xE6B04D)
    public static let usageWarnFill = Shade(0xE0A526, 0x9A6E10)
    public static let usageWarnText = Shade(0x6B4E00, 0xF2D37A)
    /// Text and marks on a filled ground (a state label, the ✓ and × discs,
    /// the primary button).
    public static let onColor = Shade(0xFFFFFF, 0xFFFFFF)
    /// The background of what the search matched (DESIGN.md, "Showing what
    /// matched"; the color of shiibar-cc's search matches): #FFD500 at
    /// 0.45 in light and 0.28 in dark, the same on selected and muted cards.
    public static let searchMatch = RGB(hex: 0xFFD500)
    public static let searchMatchAlpha = (light: 0.45, dark: 0.28)
}
