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
        IconShape(icon: icon)
            .stroke(color, style: IconPath.stroke(icon, scale: size / 16))
            .frame(width: size, height: size)
    }
}

public struct HeaderButton: View {
    public var icon: BoardIcon
    public var size: CGFloat
    public var label: String
    public var action: () -> Void

    public init(icon: BoardIcon, size: CGFloat, label: String, action: @escaping () -> Void) {
        self.icon = icon
        self.size = size
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            IconView(icon: icon, size: size, color: Palette.botIcon.color)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

public struct HoverButtonStyle: ButtonStyle {
    @State private var hovering = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Palette.botIcon.color)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering || configuration.isPressed ? Palette.tint.color : .clear))
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

    public init(icon: BoardIcon, label: String, items: [IconMenuItem?]) {
        self.icon = icon
        self.label = label
        self.items = items
    }

    public var body: some View {
        HeaderButton(icon: icon, size: 14, label: label) {
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
        let action: () -> Void

        public init(_ action: @escaping () -> Void) {
            self.action = action
        }

        @objc public func run(_ sender: Any?) {
            action()
        }
    }
}

/// The menu bar image of one account (docs/design/MenuBarIcon.html): the
/// placeholder glyph in the account color, the blue dot at the top right and
/// the triangle at the bottom left, each cut out of the glyph so it reads on
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
/// and the blue dot.
public enum MenuBarImage {
    public static let width: CGFloat = 26
    public static let height: CGFloat = 22

    public static func make(color: AccountColor, marks: MenuBarMarks, appearance: NSAppearance) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var drawn = false
            appearance.performAsCurrentDrawingAppearance {
                drawn = draw(color: color, marks: marks, dark: appearance.isDark)
            }
            return drawn
        }
        image.isTemplate = false
        return image
    }

    private static func draw(color: AccountColor, marks: MenuBarMarks, dark: Bool) -> Bool {
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        // None: the color of the other menu bar icons (DESIGN.md, "Account
        // colors": black in light, white in dark).
        let plain: NSColor = dark ? .white : .black
        let tint = (color.nsColor ?? plain).cgColor
        let glyph = CGRect(x: 3, y: 3, width: 16, height: 16)
        let icon = BoardIcons.account
        context.addPath(IconPath.cgPath(icon, in: glyph, flipY: true))
        context.setStrokeColor(tint)
        context.setLineWidth(icon.lineWidth)
        context.setLineCap(icon.roundCaps ? .round : .butt)
        context.setLineJoin(icon.roundJoins ? .round : .miter)
        context.strokePath()

        func knockOut(_ path: CGPath) {
            context.saveGState()
            context.setBlendMode(.clear)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }

        if marks.dot {
            let center = CGPoint(x: 20, y: height - 4.5)
            knockOut(CGPath(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10), transform: nil))
            context.setFillColor(Palette.blueDot.nsColor.cgColor)
            context.fillEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
        }
        if marks.triangle {
            // M5 .5 9.5 9.5 H.5z of the board, at the bottom left.
            let triangle = CGMutablePath()
            triangle.move(to: CGPoint(x: 5, y: 9.5))
            triangle.addLine(to: CGPoint(x: 9.5, y: 0.5))
            triangle.addLine(to: CGPoint(x: 0.5, y: 0.5))
            triangle.closeSubpath()
            knockOut(triangle.copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 1))
            context.addPath(triangle)
            context.setFillColor(tint)
            context.fillPath()
        }
        return true
    }
}
