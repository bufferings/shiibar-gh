// The palette as AppKit and SwiftUI colors, and which appearance a surface
// uses (DESIGN.md, "UI": the Appearance setting, System following the Mac).
//
// The grounds, the lines, the text grays, the selection and the accent
// color are system colors (DESIGN.md, "Colors"), resolved for the
// appearance they are drawn in, with the same expressions as shiibar-cc's
// surfaces. The SDK's NSColor.h describes `labelColor` as the "foreground
// color for static text", `secondaryLabelColor` for "secondary static
// text", `separatorColor` as "used for separators between sections of
// content", and `controlAccentColor` as "a dynamic color that reflects the
// user's current preferred accent color" which "automatically updates when
// the accent color preference changes" (checked in the macOS SDK headers,
// 2026-11-17).

import AppKit
import SwiftUI

extension RGB {
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

/// A color role in AppKit and in SwiftUI. Roles that follow the accent
/// color give SwiftUI `Color.accentColor`, which SwiftUI keeps current
/// itself; the others wrap the AppKit color, resolved when drawn.
public struct Tone: Equatable {
    public let nsColor: NSColor
    public let color: Color

    public init(_ nsColor: NSColor, swiftUI: Color? = nil) {
        self.nsColor = nsColor
        color = swiftUI ?? Color(nsColor: nsColor)
    }

    /// A color that is `light` in the light appearance and `dark` in the
    /// dark one, each worked out when the color is resolved.
    public init(light: @escaping () -> NSColor, dark: @escaping () -> NSColor) {
        self.init(NSColor(name: nil) { appearance in appearance.isDark ? dark() : light() })
    }

    public static func == (lhs: Tone, rhs: Tone) -> Bool { lhs.nsColor == rhs.nsColor }

    /// The color as drawn in the light or dark appearance, in sRGB (tests
    /// and the menu bar image's key).
    public func resolved(dark: Bool) -> NSColor {
        var color = NSColor.clear
        NSAppearance(named: SurfaceAppearance.named(dark: dark))?.performAsCurrentDrawingAppearance {
            color = nsColor.usingColorSpace(.sRGB) ?? nsColor
        }
        return color
    }
}

extension Palette {
    // MARK: Grounds and lines

    /// The list's ground in the popover and the window: a shade off the
    /// system backgrounds, so the cards stand out on light and on dark
    /// (shiibar-cc's list ground).
    public static let background = Tone(
        light: { NSColor.controlBackgroundColor.blended(withFraction: lightGroundGray, of: .systemGray) ?? .windowBackgroundColor },
        dark: { darkGround }
    )
    /// The share of gray in the light ground: enough that the ground is
    /// visibly off the white cards, light enough that the gray heading
    /// bands stand out from it.
    public static let lightGroundGray: CGFloat = 0.05
    private static var darkGround: NSColor {
        NSColor.windowBackgroundColor.blended(withFraction: 0.3, of: .black) ?? .windowBackgroundColor
    }
    /// A card, and the fields and boxes on the list's ground: the control
    /// background on light; on dark, white at 0.07 over the ground, made
    /// opaque because the card's text is drawn into an image of its own
    /// (shiibar-cc draws the same veil translucent).
    public static let surface = Tone(
        light: { .controlBackgroundColor },
        dark: { over(darkGround, white: 0.07) }
    )

    /// White at `white` alpha composited over `ground` in sRGB, as the
    /// translucent veil would draw (`blended(withFraction:of:)` mixes in
    /// another space and comes out lighter).
    private static func over(_ ground: NSColor, white: CGFloat) -> NSColor {
        guard let g = ground.usingColorSpace(.sRGB) else { return ground }
        func mix(_ c: CGFloat) -> CGFloat { c * (1 - white) + white }
        return NSColor(srgbRed: mix(g.redComponent), green: mix(g.greenComponent), blue: mix(g.blueComponent), alpha: 1)
    }
    /// The ground of Settings and of the sheets.
    public static let settingsBackground = Tone(.windowBackgroundColor)
    /// Every border and dividing line.
    public static let border = Tone(.separatorColor)

    // MARK: Text and icons

    public static let text = Tone(.labelColor)
    public static let secondary = Tone(.secondaryLabelColor)
    public static let tertiary = Tone(.tertiaryLabelColor)
    public static let quaternary = Tone(.quaternaryLabelColor)
    /// The search field's placeholder, and its clear button.
    public static let placeholder = Tone(.placeholderTextColor)

    // MARK: Fills

    /// A section's or a group's band heading: a light gray veil, lighter on
    /// light (the list's ground there is lighter too).
    public static let band = Tone(NSColor(name: nil) { appearance in
        NSColor.systemGray.withAlphaComponent(appearance.isDark ? bandAlpha.dark : bandAlpha.light)
    })
    /// The band's opacity of system gray on light and on dark.
    public static let bandAlpha: (light: CGFloat, dark: CGFloat) = (0.09, 0.12)
    /// The ground of a Filter option button or switch segment that is off,
    /// and of one that is on (selected), over the options' box: black on
    /// light, white on dark, at these opacities. On and off differ by at
    /// least 0.10 in either appearance, so the state reads without color.
    public static let optionOff = Tone(NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.04)
    })
    public static let optionOn = Tone(NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.14)
    })
    /// A hovered icon button and a key chip of the key hints.
    public static let fill = Tone(NSColor(name: nil) { _ in NSColor.systemGray.withAlphaComponent(0.16) })

    // MARK: Accent color

    /// The unread marks, the tab counts, the open Dismissed button, the
    /// selected display mode, text buttons (`more`), a drop target, the
    /// primary button.
    public static let accent = Tone(NSColor(name: nil) { _ in .controlAccentColor }, swiftUI: .accentColor)
    /// The border of the selected display mode.
    public static let accentLine = Tone(
        NSColor(name: nil) { _ in NSColor.controlAccentColor.withAlphaComponent(0.5) }, swiftUI: Color.accentColor.opacity(0.5)
    )
    /// A selection while the list has the keys, and the ground of an "on"
    /// button: a pale accent tint (shiibar-cc's selected card).
    public static let selection = Tone(
        NSColor(name: nil) { _ in NSColor.controlAccentColor.withAlphaComponent(0.16) }, swiftUI: Color.accentColor.opacity(0.16)
    )
    /// A selection while the list does not have the keys (the search field
    /// has them, or the window is not key): a pale neutral gray, slightly
    /// denser on dark (shiibar-cc's inactive selection).
    public static let inactiveSelection = Tone(NSColor(name: nil) { appearance in
        NSColor.systemGray.withAlphaComponent(appearance.isDark ? 0.26 : 0.18)
    })

    // MARK: Bands

    /// The warning band: a light system yellow veil under label-colored
    /// text.
    public static let warningBand = Tone(NSColor(name: nil) { _ in NSColor.systemYellow.withAlphaComponent(0.18) })
    /// The failure band of an operation: the same with system red, set
    /// apart from the warning band.
    public static let failureBand = Tone(NSColor(name: nil) { _ in NSColor.systemRed.withAlphaComponent(0.14) })

    /// `searchMatch` with its alpha for the appearance it is drawn in.
    public static let searchMatchColor: NSColor = {
        let rgb = searchMatch
        let light = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: searchMatchAlpha.light)
        let dark = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: searchMatchAlpha.dark)
        return NSColor(name: nil) { appearance in appearance.isDark ? dark : light }
    }()
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

    /// Whether the account name has its dot before it (the popover's and
    /// the window's header, the account list of Settings): every color but
    /// None, which has neither the dot nor its room (DESIGN.md, "Account
    /// color").
    public var showsDot: Bool { self != .none }

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
