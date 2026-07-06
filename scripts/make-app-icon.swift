#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: make-app-icon.swift /path/to/AppIcon.icns\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let workRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CameraToolkitIcon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = workRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for size in sizes {
    let image = drawIcon(size: size.pixels)
    let destination = iconsetURL.appendingPathComponent(size.name)
    try writePNG(image, to: destination)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    fputs("iconutil failed\n", stderr)
    exit(process.terminationStatus)
}

try? FileManager.default.removeItem(at: workRoot)

func drawIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = CGFloat(size) * 0.22
    let background = NSBezierPath(roundedRect: rect.insetBy(dx: CGFloat(size) * 0.05, dy: CGFloat(size) * 0.05), xRadius: radius, yRadius: radius)

    NSGradient(colors: [
        NSColor(red: 0.03, green: 0.24, blue: 0.31, alpha: 1),
        NSColor(red: 0.07, green: 0.56, blue: 0.70, alpha: 1),
        NSColor(red: 0.10, green: 0.42, blue: 0.32, alpha: 1)
    ])?.draw(in: background, angle: 45)

    NSColor.white.withAlphaComponent(0.16).setStroke()
    background.lineWidth = max(1, CGFloat(size) * 0.018)
    background.stroke()

    let center = NSPoint(x: CGFloat(size) * 0.42, y: CGFloat(size) * 0.54)
    let apertureRadius = CGFloat(size) * 0.22
    NSColor.white.withAlphaComponent(0.94).setStroke()
    let outer = NSBezierPath(ovalIn: NSRect(
        x: center.x - apertureRadius,
        y: center.y - apertureRadius,
        width: apertureRadius * 2,
        height: apertureRadius * 2
    ))
    outer.lineWidth = max(2, CGFloat(size) * 0.028)
    outer.stroke()

    NSColor.white.withAlphaComponent(0.9).setFill()
    for index in 0..<6 {
        let angle = CGFloat(index) * (.pi / 3) + .pi / 6
        let petal = NSBezierPath()
        petal.move(to: center)
        petal.line(to: NSPoint(
            x: center.x + cos(angle - 0.18) * apertureRadius * 0.88,
            y: center.y + sin(angle - 0.18) * apertureRadius * 0.88
        ))
        petal.line(to: NSPoint(
            x: center.x + cos(angle + 0.18) * apertureRadius * 0.88,
            y: center.y + sin(angle + 0.18) * apertureRadius * 0.88
        ))
        petal.close()
        petal.fill()
    }

    NSColor(red: 0.02, green: 0.12, blue: 0.15, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(
        x: center.x - apertureRadius * 0.37,
        y: center.y - apertureRadius * 0.37,
        width: apertureRadius * 0.74,
        height: apertureRadius * 0.74
    )).fill()

    let archiveRect = NSRect(
        x: CGFloat(size) * 0.58,
        y: CGFloat(size) * 0.26,
        width: CGFloat(size) * 0.24,
        height: CGFloat(size) * 0.28
    )
    let archive = NSBezierPath(roundedRect: archiveRect, xRadius: CGFloat(size) * 0.035, yRadius: CGFloat(size) * 0.035)
    NSColor(red: 0.05, green: 0.12, blue: 0.14, alpha: 0.94).setFill()
    archive.fill()

    NSColor(red: 0.20, green: 0.90, blue: 0.66, alpha: 1).setStroke()
    archive.lineWidth = max(1, CGFloat(size) * 0.015)
    archive.stroke()

    for row in 0..<3 {
        let y = archiveRect.minY + CGFloat(row + 1) * archiveRect.height / 4
        let line = NSBezierPath()
        line.move(to: NSPoint(x: archiveRect.minX + archiveRect.width * 0.18, y: y))
        line.line(to: NSPoint(x: archiveRect.maxX - archiveRect.width * 0.18, y: y))
        line.lineWidth = max(1, CGFloat(size) * 0.011)
        line.stroke()
    }

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let representation = NSBitmapImageRep(data: tiff),
          let png = representation.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render PNG"])
    }
    try png.write(to: url)
}
