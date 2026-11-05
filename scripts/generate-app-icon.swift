#!/usr/bin/env swift
// Generates the app icon's iconset:
//
//   swift scripts/generate-app-icon.swift <output-dir>
//
// writes <output-dir>/AppIcon.iconset/icon_*.png in the standard ten sizes;
// the caller turns it into AppIcon.icns with `iconutil -c icns`. The design
// is a placeholder (docs/tasks/M3.md): the globe of Public's menu bar icon
// (docs/design/MenuBarIcon.html) on a rounded tile in the beige of Public.
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

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1
    )
}

let tile = rgb(0xF7F1E3)
let tileEdge = rgb(0xE6DCC6)
let ink = rgb(0x1D1D1F)

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
    context.addPath(CGPath(roundedRect: rect.insetBy(dx: size * 0.004, dy: size * 0.004), cornerWidth: side * 0.22, cornerHeight: side * 0.22, transform: nil))
    context.setStrokeColor(tileEdge)
    context.setLineWidth(max(1, size * 0.008))
    context.strokePath()

    // The globe on the board's 16 by 16 grid, y down, scaled into the tile.
    let grid = side * 0.62 / 16
    let origin = CGPoint(x: margin + (side - 16 * grid) / 2, y: margin + (side - 16 * grid) / 2)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * grid, y: origin.y + (16 - y) * grid)
    }
    let globe = CGMutablePath()
    globe.addEllipse(in: CGRect(x: origin.x + 1.5 * grid, y: origin.y + 1.5 * grid, width: 13 * grid, height: 13 * grid))
    globe.move(to: p(1.5, 8))
    globe.addLine(to: p(14.5, 8))
    // M8 1.5c2.2 2 2.2 11 0 13 and its mirror.
    for sign in [CGFloat(1), -1] {
        globe.move(to: p(8, 1.5))
        globe.addCurve(to: p(8, 14.5), control1: p(8 + sign * 2.2, 3.5), control2: p(8 + sign * 2.2, 12.5))
    }
    context.addPath(globe)
    context.setStrokeColor(ink)
    context.setLineWidth(1.5 * grid * (pixels <= 32 ? 1.3 : 1))
    context.setLineCap(.round)
    context.strokePath()

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
