// The boards' icons as SwiftUI views, and the header's icon buttons.

import AppKit
import SwiftUI

public enum IconPath {
    /// The icon's outline on its 16 by 16 grid, scaled into `rect`. The
    /// grid's y axis points down, as in SVG; `flipY` turns it for a y-up
    /// AppKit context.
    public static func cgPath(_ icon: BoardIcon, in rect: CGRect, flipY: Bool) -> CGPath {
        let scale = min(rect.width, rect.height) / 16
        func point(_ p: ShiibarGhCore.Point) -> CGPoint {
            let y = flipY ? 16 - p.y : p.y
            return CGPoint(x: rect.minX + p.x * scale, y: rect.minY + y * scale)
        }
        let path = CGMutablePath()
        for element in icon.elements {
            switch element {
            case .circle(let cx, let cy, let r, let dash):
                let center = point(ShiibarGhCore.Point(cx, cy))
                let circle = CGPath(
                    ellipseIn: CGRect(x: center.x - r * scale, y: center.y - r * scale, width: 2 * r * scale, height: 2 * r * scale),
                    transform: nil
                )
                if let dash {
                    path.addPath(circle.copy(dashingWithPhase: 0, lengths: dash.map { $0 * scale }))
                } else {
                    path.addPath(circle)
                }
            case .rect(let x, let y, let width, let height, let radius):
                let origin = point(ShiibarGhCore.Point(x, flipY ? y + height : y))
                path.addRoundedRect(
                    in: CGRect(x: origin.x, y: origin.y, width: width * scale, height: height * scale),
                    cornerWidth: radius * scale, cornerHeight: radius * scale
                )
            case .arc(let cx, let cy, let r, let start, let end):
                // Points along the arc, so the same code serves y-down
                // (SwiftUI) and y-up (menu bar) drawing.
                let steps = 48
                for step in 0...steps {
                    let angle = (start + (end - start) * Double(step) / Double(steps)) * .pi / 180
                    let p = point(ShiibarGhCore.Point(cx + r * cos(angle), cy + r * sin(angle)))
                    if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
            case .path(let d):
                for segment in SVGPath.parse(d) {
                    switch segment {
                    case .move(let p): path.move(to: point(p))
                    case .line(let p): path.addLine(to: point(p))
                    case .curve(let c1, let c2, let p): path.addCurve(to: point(p), control1: point(c1), control2: point(c2))
                    case .close: path.closeSubpath()
                    }
                }
            }
        }
        return path
    }

    /// The icon's filled elements (`BoardIcon.fills`), scaled as
    /// `cgPath`.
    public static func fillPath(_ icon: BoardIcon, in rect: CGRect, flipY: Bool) -> CGPath? {
        guard !icon.fills.isEmpty else { return nil }
        var filled = icon
        filled.elements = icon.fills
        return cgPath(filled, in: rect, flipY: flipY)
    }

    public static func stroke(_ icon: BoardIcon, scale: CGFloat) -> StrokeStyle {
        StrokeStyle(
            lineWidth: icon.lineWidth * scale,
            lineCap: icon.roundCaps ? .round : .butt,
            lineJoin: icon.roundJoins ? .round : .miter
        )
    }
}

/// A board icon stroked in the current foreground color.
public struct IconShape: Shape {
    public var icon: BoardIcon

    public init(icon: BoardIcon) {
        self.icon = icon
    }

    public func path(in rect: CGRect) -> Path {
        Path(IconPath.cgPath(icon, in: rect, flipY: false))
    }
}

public struct IconView: View {
    public var icon: BoardIcon
    public var size: CGFloat
    public var color: Color

    public init(icon: BoardIcon, size: CGFloat, color: Color) {
        self.icon = icon
        self.size = size
        self.color = color
    }

    public var body: some View {
        ZStack {
            IconShape(icon: icon)
                .stroke(color, style: IconPath.stroke(icon, scale: size / 16))
            // The filled elements (the eye's pupil).
            if !icon.fills.isEmpty {
                IconFillShape(icon: icon).fill(color)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The filled elements of a board icon (`BoardIcon.fills`).
public struct IconFillShape: Shape {
    public var icon: BoardIcon

    public init(icon: BoardIcon) {
        self.icon = icon
    }

    public func path(in rect: CGRect) -> Path {
        IconPath.fillPath(icon, in: rect, flipY: false).map { Path($0) } ?? Path()
    }
}

public struct HeaderButton: View {
    /// The button's side at text size 12 (DESIGN.md, "Constants": header
    /// row 2's buttons).
    public static let side: CGFloat = 24
    public var icon: BoardIcon
    public var size: CGFloat
    public var label: String
    /// The tooltip, when it says more than the label (`Refresh (⌘R)`).
    public var help: String?
    /// The ratio of the text size to 12: the button and its icon, strokes
    /// included, follow it unrounded; the hover fill's radius does not.
    public var scale: CGFloat
    public var action: () -> Void

    public init(icon: BoardIcon, size: CGFloat, label: String, help: String? = nil, scale: CGFloat = 1, action: @escaping () -> Void) {
        self.icon = icon
        self.size = size
        self.label = label
        self.help = help
        self.scale = scale
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            IconView(icon: icon, size: size * scale, color: Palette.secondary.color)
                .frame(width: Self.side * scale, height: Self.side * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .quickHelp(help ?? label)
        .accessibilityLabel(label)
    }
}

public struct HoverButtonStyle: ButtonStyle {
    /// The hover fill's corner radius: the same at every text size.
    public static let radius: CGFloat = 6
    @State private var hovering = false
    /// The fill while the pointer is away (the pin's tint while on).
    public var idle: Color
    /// False while the button takes no press (Refresh running): no fill
    /// under the pointer.
    public var active: Bool

    public init(idle: Color = .clear, active: Bool = true) {
        self.idle = idle
        self.active = active
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Palette.secondary.color)
            .background(RoundedRectangle(cornerRadius: Self.radius).fill(active && (hovering || configuration.isPressed) ? Palette.fill.color : idle))
            .onHover { hovering = $0 }
    }
}


/// One item of an icon button's menu. In a list of items, nil is a
/// separator.
public struct IconMenuItem {
    public var title: String
    /// A check mark before the title (the current value of a pop-up).
    public var checked: Bool
    public var enabled: Bool
    public var action: () -> Void

    public init(_ title: String, checked: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.checked = checked
        self.enabled = enabled
        self.action = action
    }
}

/// The ⌄ menu: a header icon button that opens an AppKit menu below the
/// pointer. Not a SwiftUI `Menu`: with `.menuStyle(.borderlessButton)` a
/// Menu draws its label through a pop-up button, which shows Text and Image
/// labels but drops a Shape (a test renders both), so the board's chevron
/// never appeared.
public struct MenuIconButton: View {
    public var icon: BoardIcon
    public var label: String
    public var items: [IconMenuItem?]

    /// The ratio of the text size to 12 (`HeaderButton.scale`).
    public var scale: CGFloat

    public init(icon: BoardIcon, label: String, items: [IconMenuItem?], scale: CGFloat = 1) {
        self.icon = icon
        self.label = label
        self.items = items
        self.scale = scale
    }

    public var body: some View {
        HeaderButton(icon: icon, size: 14, label: label, scale: scale) {
            IconMenu.popUp(items)
        }
    }
}

/// Builds and shows the menu; each item calls its closure.
@MainActor
public enum IconMenu {
    public static func make(_ items: [IconMenuItem?]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            guard let item else {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: item.title, action: #selector(Target.run(_:)), keyEquivalent: "")
            entry.state = item.checked ? .on : .off
            entry.isEnabled = item.enabled
            let target = Target(item.action)
            entry.target = target
            entry.representedObject = target
            menu.addItem(entry)
        }
        return menu
    }

    public static func popUp(_ items: [IconMenuItem?]) {
        // Positioned at the pointer, in screen coordinates (view nil).
        make(items).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    public final class Target: NSObject {
        public var action: () -> Void

        public init(_ action: @escaping () -> Void) {
            self.action = action
        }

        @objc public func run(_ sender: Any?) {
            action()
        }
    }
}

/// The menu bar image of one account (docs/design/MenuBarIcon.html): the
/// glyph in the account color at the image's full height, the dot in the
/// accent color on the arrow's corner and the warning sign (a round-cornered
/// yellow triangle with an exclamation mark) on the lower ring. The marks lie
/// on the glyph, inside its height, and each is cut out of it so it reads on
/// any menu bar.
///
/// The colors are resolved for `appearance`, the status button's effective
/// appearance, inside `performAsCurrentDrawingAppearance` (Apple:
/// NSAppearance.currentDrawing is "the appearance that the system uses for
/// color and asset resolution"). Apple's documentation of
/// NSImage(size:flipped:drawingHandler:) only promises a new drawing when the
/// pixel density or color space changes, not the appearance, so the
/// controller makes a new image when the button turns light or dark (and
/// only then, or when the color or the marks change: `StatusItemLook`).
/// The image is not a template: a template image "should consist of only
/// black and clear colors" (NSImage.isTemplate), which would lose the tint
/// and the dot's accent color.
public enum MenuBarImage {
    public static let width: CGFloat = 26
    public static let height: CGFloat = 18
    /// The warning sign's colors, fixed for both appearances.
    static let warningYellow = CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
    static let warningInk = CGColor(srgbRed: 0.106, green: 0.106, blue: 0.118, alpha: 1)

    /// The accent color of the dot as drawn for `appearance`, in sRGB: the
    /// image is drawn with it, and the status item's look keeps it
    /// (`StatusItemLook.accent`), so the image changes only with it.
    public static func dotColor(for appearance: NSAppearance) -> NSColor {
        var color = NSColor.controlAccentColor
        appearance.performAsCurrentDrawingAppearance {
            color = Palette.accent.nsColor.usingColorSpace(.sRGB) ?? .controlAccentColor
        }
        return color
    }

    public static func components(_ color: NSColor) -> [CGFloat] {
        let c = color.usingColorSpace(.sRGB) ?? color
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }

    public static func make(
        color: AccountColor, marks: MenuBarMarks, appearance: NSAppearance, dot: NSColor? = nil
    ) -> NSImage {
        let dot = (dot ?? dotColor(for: appearance)).cgColor
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var drawn = false
            appearance.performAsCurrentDrawingAppearance {
                drawn = draw(color: color, marks: marks, dark: appearance.isDark, dot: dot)
            }
            return drawn
        }
        image.isTemplate = false
        return image
    }

    private static func draw(color: AccountColor, marks: MenuBarMarks, dark: Bool, dot: CGColor) -> Bool {
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        // None: the color of the other menu bar icons (DESIGN.md, "Account
        // colors": black in light, white in dark).
        let plain: NSColor = dark ? .white : .black
        let tint = (color.nsColor ?? plain).cgColor
        // The picture fills the image's height (17.3 of 18 pt) and sits in
        // the middle of its width.
        let side: CGFloat = 17.5
        let glyph = CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
        let icon = BoardIcons.account
        context.addPath(IconPath.cgPath(icon, in: glyph, flipY: true))
        context.setStrokeColor(tint)
        context.setLineWidth(icon.lineWidth * side / 16)
        context.setLineCap(icon.roundCaps ? .round : .butt)
        context.setLineJoin(icon.roundJoins ? .round : .miter)
        context.strokePath()
        if let fill = IconPath.fillPath(icon, in: glyph, flipY: true) {
            context.addPath(fill)
            context.setFillColor(tint)
            context.fillPath()
        }

        func knockOut(_ path: CGPath) {
            context.saveGState()
            context.setBlendMode(.clear)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }

        // The marks lie on the picture and stay inside its height: the dot
        // on the arrow's corner with its top at the picture's top, the
        // warning sign on the lower ring with its bottom at the picture's
        // bottom.
        let top = glyph.maxY - 0.09, bottom = glyph.minY + 0.09, left = glyph.minX + 0.29
        if marks.dot {
            let radius: CGFloat = 3.6
            let center = CGPoint(x: glyph.minX + 15.03 * side / 16, y: top - radius)
            knockOut(CGPath(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9), transform: nil))
            context.setFillColor(dot)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        }
        if marks.triangle {
            // The warning sign: a triangle drawn with a round line, so its
            // corners are round, in the warning's yellow with a dark
            // exclamation mark, the same on a light and a dark menu bar.
            let scale: CGFloat = 0.9
            var place = CGAffineTransform(translationX: left - 1.06 * scale, y: bottom - 0.5 * scale).scaledBy(x: scale, y: scale)
            let triangle = CGMutablePath()
            triangle.move(to: CGPoint(x: 5, y: 7.49), transform: place)
            triangle.addLine(to: CGPoint(x: 8.04, y: 1.4), transform: place)
            triangle.addLine(to: CGPoint(x: 1.96, y: 1.4), transform: place)
            triangle.closeSubpath()
            knockOut(triangle.copy(strokingWithWidth: 4.8 * scale, lineCap: .round, lineJoin: .round, miterLimit: 1))
            knockOut(triangle)
            context.addPath(triangle)
            context.setFillColor(warningYellow)
            context.setStrokeColor(warningYellow)
            context.setLineWidth(1.8 * scale)
            context.setLineJoin(.round)
            context.drawPath(using: .fillStroke)
            let bar = CGMutablePath()
            bar.move(to: CGPoint(x: 5, y: 6.3), transform: place)
            bar.addLine(to: CGPoint(x: 5, y: 3.6), transform: place)
            context.setFillColor(warningInk)
            context.addPath(bar.copy(strokingWithWidth: 1.2 * scale, lineCap: .round, lineJoin: .round, miterLimit: 1))
            context.fillPath()
            context.addPath(CGPath(ellipseIn: CGRect(x: 5 - 0.65, y: 1.9 - 0.65, width: 1.3, height: 1.3), transform: &place))
            context.fillPath()
        }
        return true
    }
}
