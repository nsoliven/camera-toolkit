#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: make-app-icon.swift /path/to/source.png /path/to/AppIcon.icns\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let sourceImage = NSImage(contentsOf: sourceURL),
      let sourceCGImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Could not read icon source at \(sourceURL.path)\n", stderr)
    exit(1)
}

guard sourceCGImage.width == sourceCGImage.height, sourceCGImage.width >= 1024 else {
    fputs("Icon source must be a square image at least 1024 pixels wide\n", stderr)
    exit(1)
}

let workRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CameraToolkitIcon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = workRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workRoot) }

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
    let destination = iconsetURL.appendingPathComponent(size.name)
    try writePNG(sourceCGImage, pixels: size.pixels, to: destination)
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

func writePNG(_ source: CGImage, pixels: Int, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw NSError(domain: "Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create icon canvas"])
    }

    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))

    guard let resized = context.makeImage() else {
        throw NSError(domain: "Icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not resize icon"])
    }

    let representation = NSBitmapImageRep(cgImage: resized)
    guard let png = representation.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode icon PNG"])
    }
    try png.write(to: url)
}
