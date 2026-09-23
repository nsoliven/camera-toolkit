import AppKit
import CameraToolkitCore
import ImageIO
import SwiftUI

/// Spinner text that names what the file actually is — a PNG reads as
/// "PNG", a RAW reads its embedded JPEG — so a stalled read on screen says
/// something truthful about the file it's stuck on.
enum PreviewLoadMessage {
    static func title(for url: URL?) -> String {
        guard let ext = url?.pathExtension.lowercased(), !ext.isEmpty else {
            return "Reading preview…"
        }
        if OrganizeFileClassifier.rawExtensions.contains(ext) {
            return "Reading embedded JPEG…"
        }
        switch ext {
        case "jpg", "jpeg": return "Reading JPEG…"
        case "png": return "Reading PNG…"
        case "heic", "heif": return "Reading HEIC…"
        case "tif", "tiff": return "Reading TIFF…"
        case "webp": return "Reading WebP…"
        default:
            return OrganizeFileClassifier.videoExtensions.contains(ext)
                ? "Reading video frame…"
                : "Reading preview…"
        }
    }
}

enum PreviewImageDecoder {
    static func cgImage(data: Data, maximumPixelSize: Int) -> CGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return cgImage(source: source, maximumPixelSize: maximumPixelSize)
        }
    }

    static func cgImage(url: URL, maximumPixelSize: Int) -> CGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return cgImage(source: source, maximumPixelSize: maximumPixelSize)
        }
    }

    static func image(data: Data, maximumPixelSize: Int) -> NSImage? {
        guard let image = cgImage(data: data, maximumPixelSize: maximumPixelSize) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func cgImage(source: CGImageSource, maximumPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

enum PhotomatorLauncher {
    static func open(_ url: URL) {
        open([url])
    }

    static func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let app = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.pixelmatorteam.pixelmator.touch.x.photo"
        ) else {
            urls.forEach { NSWorkspace.shared.open($0) }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
    }
}
