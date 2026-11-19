// The colors of a GitHub label on a card (DESIGN.md, "Card", "GitHub
// labels", and "Constants": the label color calculation, light and dark).
// Pure functions of the label's `color` and, in dark, of the card's ground,
// so tests can check every value. Compositing with an opacity and mixing in
// white work on the gamma-encoded sRGB values (0 to 255); only the relative
// luminance Y uses linear values (WCAG 2 relative luminance and contrast
// ratio).

import Foundation

/// An sRGB color as components from 0 to 255, gamma-encoded. Not rounded:
/// the composited and mixed values keep their fractions.
public struct LabelRGB: Equatable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
    }

    public static let white = LabelRGB(255, 255, 255)
    public static let black = LabelRGB(0, 0, 0)

    /// `self` with `color` laid over it at `alpha`.
    public func under(_ color: LabelRGB, alpha: Double) -> LabelRGB {
        LabelRGB(
            r * (1 - alpha) + color.r * alpha, g * (1 - alpha) + color.g * alpha, b * (1 - alpha) + color.b * alpha
        )
    }

    /// Each component moved toward 255 by `t`: c + (255 − c) × t.
    public func mixedWithWhite(_ t: Double) -> LabelRGB {
        LabelRGB(r + (255 - r) * t, g + (255 - g) * t, b + (255 - b) * t)
    }

    /// The relative luminance Y.
    public var luminance: Double {
        func linear(_ c: Double) -> Double {
            let v = c / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// The contrast ratio of two colors: (the lighter Y + 0.05) / (the
    /// darker Y + 0.05).
    public func contrast(_ other: LabelRGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// How one label is drawn: its ground, its text, and its 1-point outline
/// (a color laid over the ground at an opacity), if any.
public struct LabelLook: Equatable, Hashable {
    public var ground: LabelRGB
    public var text: LabelRGB
    public var outline: LabelRGB?
    public var outlineAlpha: Double

    public init(ground: LabelRGB, text: LabelRGB, outline: LabelRGB? = nil, outlineAlpha: Double = 0) {
        self.ground = ground
        self.text = text
        self.outline = outline
        self.outlineAlpha = outlineAlpha
    }
}

public enum LabelColors {
    /// The contrast the label text reaches with its ground.
    public static let minimumContrast = 4.5
    /// The color of a label whose `color` is not six hexadecimal digits.
    public static let fallback: UInt32 = 0x6E7781
    /// Light: a label lighter than this Y gets the outline.
    public static let outlineLuminance = 0.6
    /// Light: the outline is black at this opacity.
    public static let lightOutlineAlpha = 0.15
    /// Dark: the label color over the card's ground for the label's ground.
    public static let darkGroundAlpha = 0.18
    /// Dark: the outline is the label color at this opacity.
    public static let darkOutlineAlpha = 0.4
    /// Dark: the steps of white mixed into the text, 0, 0.05, …, 1.
    public static let whiteSteps = 20
    /// A muted card draws its labels at this opacity (as its avatars).
    public static let mutedOpacity = 0.6

    /// `color` as GitHub gives it: six hexadecimal digits, either case;
    /// anything else is `fallback`.
    public static func parse(_ color: String) -> LabelRGB {
        let digits = Array(color.utf8)
        guard digits.count == 6, digits.allSatisfy({ isHexDigit($0) }), let value = UInt32(color, radix: 16) else {
            return LabelRGB(hex: fallback)
        }
        return LabelRGB(hex: value)
    }

    private static func isHexDigit(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }

    /// Light: the ground is the label color; the text is white when white
    /// reaches the contrast with it, black otherwise; a label with Y over
    /// 0.6 gets an outline of black at 0.15.
    public static func light(_ color: String) -> LabelLook {
        let ground = parse(color)
        let text = LabelRGB.white.contrast(ground) >= minimumContrast ? LabelRGB.white : LabelRGB.black
        let outlined = ground.luminance > outlineLuminance
        return LabelLook(
            ground: ground, text: text, outline: outlined ? .black : nil, outlineAlpha: outlined ? lightOutlineAlpha : 0
        )
    }

    /// Dark, over `card` (the ground of a card that is not selected): the
    /// ground is the label color at 0.18 over the card; the outline is the
    /// label color at 0.4; the text is the label color mixed with the least
    /// white (in steps of 0.05) that reaches the contrast with the ground.
    public static func dark(_ color: String, card: LabelRGB) -> LabelLook {
        let label = parse(color)
        let ground = card.under(label, alpha: darkGroundAlpha)
        let text = label.mixedWithWhite(darkWhite(label, ground: ground))
        return LabelLook(ground: ground, text: text, outline: label, outlineAlpha: darkOutlineAlpha)
    }

    /// The t of a dark label's text: the least of 0, 0.05, …, 1 at which the
    /// label color mixed with white reaches the contrast with `ground`.
    /// White (t = 1) reaches it on any dark label ground.
    public static func darkWhite(_ label: LabelRGB, ground: LabelRGB) -> Double {
        for step in 0...whiteSteps {
            let t = Double(step) / Double(whiteSteps)
            if label.mixedWithWhite(t).contrast(ground) >= minimumContrast { return t }
        }
        return 1
    }
}

/// `show_labels` (DESIGN.md, "Settings"): the cards show the GitHub labels
/// and the search looks at their names. One value for every account, on
/// by default; the labels are fetched whatever it says.
public enum ShowLabels {
    public static let configKey = "show_labels"
    public static let defaultValue = true
    public static let title = "Show labels"
    public static let detail = "Labels of the pull request on each card"

    /// The value of a setting read or changed: anything but a Boolean is
    /// the default.
    public static func value(_ config: ConfigValue?) -> Bool {
        config?.boolValue ?? defaultValue
    }
}
