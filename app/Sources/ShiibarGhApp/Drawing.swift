// The boards' icons and colors in AppKit and SwiftUI.

import AppKit
import ShiibarGhCore
import SwiftUI

extension RGB {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Shade {
    /// A color that follows the light or dark appearance it is drawn in.
    var nsColor: NSColor {
        let light = self.light.nsColor
        let dark = self.dark.nsColor
        return NSColor(name: nil) { appearance in appearance.isDark ? dark : light }
    }

    var color: Color { Color(nsColor: nsColor) }
}

enum IconPath {
    /// The icon's outline on its 16 by 16 grid, scaled into `rect`. The
    /// grid's y axis points down, as in SVG; `flipY` turns it for a y-up
    /// AppKit context.
    static func cgPath(_ icon: BoardIcon, in rect: CGRect, flipY: Bool) -> CGPath {
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

    static func stroke(_ icon: BoardIcon, scale: CGFloat) -> StrokeStyle {
        StrokeStyle(
            lineWidth: icon.lineWidth * scale,
            lineCap: icon.roundCaps ? .round : .butt,
            lineJoin: icon.roundJoins ? .round : .miter
        )
    }
}

/// A board icon stroked in the current foreground color.
struct IconShape: Shape {
    var icon: BoardIcon

    func path(in rect: CGRect) -> Path {
        Path(IconPath.cgPath(icon, in: rect, flipY: false))
    }
}

struct IconView: View {
    var icon: BoardIcon
    var size: CGFloat
    var color: Color

    var body: some View {
        IconShape(icon: icon)
            .stroke(color, style: IconPath.stroke(icon, scale: size / 16))
            .frame(width: size, height: size)
    }
}

/// The status icons: a filled ✓ or ×, or the dashed circle (DESIGN.md, "The
/// three status icons").
struct StatusIcon: View {
    enum Look { case ok, bad, waiting, empty }
    var look: Look

    var body: some View {
        ZStack {
            switch look {
            case .ok:
                Circle().fill(Palette.green.color).frame(width: 12.25, height: 12.25)
                IconView(icon: BoardIcons.checkMark, size: 14, color: Palette.onColor.color)
            case .bad:
                Circle().fill(Palette.badge.color).frame(width: 12.25, height: 12.25)
                IconView(icon: BoardIcons.crossMark, size: 14, color: Palette.onColor.color)
            case .waiting:
                IconView(icon: BoardIcons.dashedCircle, size: 14, color: Palette.waiting.color)
            case .empty:
                Color.clear
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// The menu bar image of one scope (docs/design/MenuBarIcon.html): the
/// owner glyph in a 22 point slot, the red badge at the top right, the blue
/// dot at the top right, or at the bottom right next to a badge, and the
/// triangle at the bottom left (`MenuBarMarks`).
enum MenuBarImage {
    static let width: CGFloat = 26
    static let height: CGFloat = 22

    static func make(icon: BoardIcon, badge: Int, dot: Bool, triangle: Bool) -> NSImage {
        let marks = MenuBarMarks(badge: badge, dot: dot, triangle: triangle)
        let plain = marks.plain
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let foreground: NSColor = plain ? .black : (dark ? .white : NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
            let barColor: NSColor = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(srgbRed: 0.914, green: 0.914, blue: 0.925, alpha: 1)
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let glyph = CGRect(x: 3, y: 3, width: 16, height: 16)
            context.addPath(IconPath.cgPath(icon, in: glyph, flipY: true))
            context.setStrokeColor(foreground.cgColor)
            context.setLineWidth(icon.lineWidth)
            context.setLineCap(icon.roundCaps ? .round : .butt)
            context.setLineJoin(icon.roundJoins ? .round : .miter)
            context.strokePath()

            if let text = marks.badge {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: NSColor.white,
                ]
                let size = (text as NSString).size(withAttributes: attributes)
                let pillWidth = max(14, size.width + 8)
                let pill = CGRect(x: min(width - pillWidth, 22 + 5 - pillWidth), y: height - 14 + 3 - 1.5, width: pillWidth, height: 14)
                let halo = NSBezierPath(roundedRect: pill.insetBy(dx: -1.5, dy: -1.5), xRadius: 8.5, yRadius: 8.5)
                barColor.setFill()
                halo.fill()
                Palette.badge.nsColor.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
                (text as NSString).draw(
                    at: CGPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2),
                    withAttributes: attributes
                )
            }
            if let place = marks.dot {
                let center = place == .topRight
                    ? CGPoint(x: 22 - 1 - 3.5, y: height - 3.5)
                    : CGPoint(x: 22 - 1 - 3.5, y: 3.5)
                barColor.setFill()
                NSBezierPath(ovalIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)).fill()
                Palette.blueDot.nsColor.setFill()
                NSBezierPath(ovalIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)).fill()
            }
            if triangle {
                let frame = CGRect(x: 0, y: 0, width: 10, height: 10)
                let outline = IconPath.cgPath(BoardIcons.warning, in: frame, flipY: true)
                context.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 1), cornerWidth: 2, cornerHeight: 2, transform: nil))
                context.setFillColor(barColor.cgColor)
                context.fillPath()
                context.addPath(outline)
                context.setStrokeColor(NSColor(srgbRed: 0.85, green: 0.55, blue: 0, alpha: 1).cgColor)
                context.setLineWidth(1.3)
                context.setLineJoin(.round)
                context.setLineCap(.round)
                context.strokePath()
            }
            return true
        }
        // A plain glyph takes the menu bar's own color.
        image.isTemplate = plain
        return image
    }
}
