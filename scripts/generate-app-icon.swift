#!/usr/bin/env swift
// Generates the app icon's iconset:
//
//   swift scripts/generate-app-icon.swift <output-dir>
//
// writes <output-dir>/AppIcon.iconset/icon_*.png in the standard ten sizes;
// the caller turns it into AppIcon.icns with `iconutil -c icns`. The design
// (the app icon part of docs/DESIGN.md): a pull request mark whose lower right
// node is a cat standing in side view, its back running on into the tail and
// the tail into the arrow, on a dark rounded tile with a blue dot at the upper
// right. This file is the source of truth for the geometry.
// Any failure exits non-zero.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift generate-app-icon.swift <output-dir>\n".utf8))
    exit(1)
}
let iconset = URL(fileURLWithPath: arguments[1], isDirectory: true)
    .appendingPathComponent("AppIcon.iconset", isDirectory: true)

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

let tile = rgb(0x1B1B1E)
let ink = rgb(0xF2F0EC)
// An icon image cannot follow the accent color setting, so the dot is a fixed
// blue close to the default accent color, with a light halo.
let dot = rgb(0x0A84FF)
let halo = rgb(0xFFFFFF, alpha: 0.9)

// At or below this many pixels the dot is too fine to read and is left out.
let dotThreshold = 32

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64), ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func render(_ pixels: Int) -> CGImage {
    let size = CGFloat(pixels)
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        FileHandle.standardError.write(Data("cannot create a \(pixels) px context\n".utf8))
        exit(1)
    }
    // The tile sits inset like other macOS app icons.
    let margin = size * 0.085
    let side = size - 2 * margin
    let rect = CGRect(x: margin, y: margin, width: side, height: side)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: side * 0.224, cornerHeight: side * 0.224, transform: nil))
    context.setFillColor(tile)
    context.fillPath()

    // From here on: the tile's own space, 100 units a side, y down.
    context.translateBy(x: margin, y: size - margin)
    context.scaleBy(x: side / 100, y: -side / 100)

    // The mark is drawn on its own grid (x 11.5...83.5, y 13.5...87, lines 7
    // wide) and placed with its center on the tile's center.
    context.saveGState()
    context.translateBy(x: 50, y: 50)
    context.scaleBy(x: 0.81, y: 0.81)
    context.translateBy(x: -47.5, y: -50.25)
    context.setStrokeColor(ink)
    context.setFillColor(ink)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    // The base branch: two ring nodes joined by a line.
    let lines = CGMutablePath()
    lines.move(to: CGPoint(x: 24, y: 36))
    lines.addLine(to: CGPoint(x: 24, y: 64))
    lines.addEllipse(in: CGRect(x: 15, y: 17, width: 18, height: 18))
    lines.addEllipse(in: CGRect(x: 15, y: 65, width: 18, height: 18))
    // The cat's back runs on into the tail, which rises and turns into the arrow.
    lines.move(to: CGPoint(x: 66, y: 66.5))
    lines.addLine(to: CGPoint(x: 73, y: 66.5))
    lines.addCurve(to: CGPoint(x: 80, y: 57.5), control1: CGPoint(x: 78, y: 66.5), control2: CGPoint(x: 80, y: 62.5))
    lines.addLine(to: CGPoint(x: 80, y: 40))
    lines.addCurve(to: CGPoint(x: 68, y: 26), control1: CGPoint(x: 80, y: 32), control2: CGPoint(x: 76, y: 26))
    lines.addLine(to: CGPoint(x: 56, y: 26))
    lines.move(to: CGPoint(x: 63, y: 17))
    lines.addLine(to: CGPoint(x: 54, y: 26))
    lines.addLine(to: CGPoint(x: 63, y: 35))
    context.addPath(lines)
    context.setLineWidth(7)
    context.strokePath()

    // The cat: a straight body, two legs with round feet, and a head whose ear
    // lines run straight down to the cheeks above a round chin. The cheeks sit
    // on the line of the back, so the head meets the back without a notch.
    let cat = CGMutablePath()
    cat.addRect(CGRect(x: 48, y: 63, width: 29, height: 13))
    for x in [CGFloat(48), 70] {
        cat.addRect(CGRect(x: x, y: 63, width: 7, height: 20.5))
        cat.addEllipse(in: CGRect(x: x, y: 80, width: 7, height: 7))
    }
    context.addPath(cat)
    context.fillPath()
    let head = CGMutablePath()
    head.move(to: CGPoint(x: 42.4, y: 49))
    head.addLine(to: CGPoint(x: 40.8, y: 63))
    // The chin: the lower half of a circle of radius 8.2 around (49, 63).
    head.addCurve(to: CGPoint(x: 49, y: 71.2), control1: CGPoint(x: 40.8, y: 67.53), control2: CGPoint(x: 44.47, y: 71.2))
    head.addCurve(to: CGPoint(x: 57.2, y: 63), control1: CGPoint(x: 53.53, y: 71.2), control2: CGPoint(x: 57.2, y: 67.53))
    head.addLine(to: CGPoint(x: 55.6, y: 49))
    head.addLine(to: CGPoint(x: 50.3, y: 55.7))
    head.addLine(to: CGPoint(x: 47.7, y: 55.7))
    head.closeSubpath()
    context.addPath(head)
    context.setLineWidth(1.2)
    context.drawPath(using: .fillStroke)
    context.restoreGState()

    if pixels > dotThreshold {
        let circle = CGRect(x: 78 - 7, y: 22 - 7, width: 14, height: 14)
        context.setFillColor(dot)
        context.fillEllipse(in: circle)
        context.setStrokeColor(halo)
        context.setLineWidth(7 * 0.22)
        context.strokeEllipse(in: circle)
    }

    guard let image = context.makeImage() else {
        FileHandle.standardError.write(Data("cannot render \(pixels) px\n".utf8))
        exit(1)
    }
    return image
}

do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("cannot create \(iconset.path): \(error)\n".utf8))
    exit(1)
}
for (name, pixels) in sizes {
    let url = iconset.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("cannot write \(url.path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, render(pixels), nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("cannot write \(url.path)\n".utf8))
        exit(1)
    }
}
