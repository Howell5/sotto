#!/usr/bin/env swift

import AppKit
import Foundation

private let canvasSize: CGFloat = 1_024
private let ink = NSColor(
    calibratedRed: 0x1D / 255,
    green: 0x1E / 255,
    blue: 0x1C / 255,
    alpha: 1
)
private let sage = NSColor(
    calibratedRed: 0x9E / 255,
    green: 0xC3 / 255,
    blue: 0x9A / 255,
    alpha: 1
)

private enum AssetError: Error {
    case bitmapCreation
    case pngEncoding
    case iconutilFailed(Int32)
}

private func iconPNG(size: Int, transparentBackground: Bool = false) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw AssetError.bitmapCreation
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    let scale = CGFloat(size) / canvasSize
    context.scaleBy(x: scale, y: scale)

    if transparentBackground {
        context.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
    } else {
        context.setFillColor(ink.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
    }

    let mark = CGMutablePath()
    mark.move(to: CGPoint(x: 724, y: 294))
    mark.addCurve(
        to: CGPoint(x: 318, y: 349),
        control1: CGPoint(x: 621, y: 202),
        control2: CGPoint(x: 400, y: 211)
    )
    mark.addCurve(
        to: CGPoint(x: 511, y: 509),
        control1: CGPoint(x: 245, y: 456),
        control2: CGPoint(x: 375, y: 482)
    )
    mark.addCurve(
        to: CGPoint(x: 706, y: 675),
        control1: CGPoint(x: 653, y: 538),
        control2: CGPoint(x: 781, y: 566)
    )
    mark.addCurve(
        to: CGPoint(x: 298, y: 731),
        control1: CGPoint(x: 625, y: 817),
        control2: CGPoint(x: 398, y: 824)
    )

    context.addPath(mark)
    context.setStrokeColor((transparentBackground ? NSColor.black : sage).cgColor)
    context.setLineWidth(146)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw AssetError.pngEncoding
    }
    return png
}

private func writePNG(size: Int, to url: URL, transparentBackground: Bool = false) throws {
    try iconPNG(size: size, transparentBackground: transparentBackground).write(to: url)
}

private let projectRoot = URL(
    fileURLWithPath: CommandLine.arguments.dropFirst().first
        ?? FileManager.default.currentDirectoryPath,
    isDirectory: true
)
private let assets = projectRoot.appending(path: "Packaging/Assets", directoryHint: .isDirectory)
private let iconset = assets.appending(path: "AppIcon.iconset", directoryHint: .isDirectory)
private let manager = FileManager.default

try manager.createDirectory(at: assets, withIntermediateDirectories: true)
if manager.fileExists(atPath: iconset.path) {
    try manager.removeItem(at: iconset)
}
try manager.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1_024)
]

for (filename, size) in variants {
    try writePNG(size: size, to: iconset.appending(path: filename))
}

try writePNG(
    size: 1_024,
    to: assets.appending(path: "SottoIcon-1024.png")
)
try writePNG(
    size: 36,
    to: assets.appending(path: "SottoMenuBarTemplate.png"),
    transparentBackground: true
)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns",
    "-o", assets.appending(path: "AppIcon.icns").path,
    iconset.path
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    throw AssetError.iconutilFailed(iconutil.terminationStatus)
}

print("Generated Sotto brand assets in \(assets.path)")
