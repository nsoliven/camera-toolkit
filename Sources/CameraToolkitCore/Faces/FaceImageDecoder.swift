import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Bounded decodes and pixel-size reads shared by the face pipeline. RAW
/// files read their embedded JPEG — the same preview path the burst linker
/// uses — so detection never decodes sensor data.
public enum FaceImageDecoder {
    /// A bounded, orientation-applied decode for detection. Delegates to the
    /// burst linker's preview path: embedded JPEG for RAW, ImageIO otherwise.
    public static func detectionImage(for url: URL, maximumPixelSize: Int) -> CGImage? {
        BurstVisualLinker.previewImage(for: url, maximumPixelSize: maximumPixelSize)
    }

    /// A clip's representative frame — one second in, unlimited seek
    /// tolerance, track transform applied, the same poster the tile grid
    /// shows — so a video contributes faces without sweeping keyframes.
    public static func posterImage(for url: URL, maximumPixelSize: Int) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
    }

    /// The native pixel size of the image detection actually ran on — for a
    /// RAW that is its embedded JPEG, not the sensor resolution. Read from
    /// image-source properties without decoding pixels.
    public static func pixelSize(of url: URL) -> CGSize? {
        if OrganizeFileClassifier.rawExtensions.contains(url.pathExtension.lowercased()),
           let data = try? EmbeddedJPEGPreviewExtractor().jpegData(from: url, preference: .fullSize),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let size = sourceSize(source) {
            return size
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return sourceSize(source)
    }

    private static func sourceSize(_ source: CGImageSource) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// Encodes decoded images for the sidecar and for stored crops.
public enum FaceImageEncoding {
    /// JPEG bytes at `quality` (0–1).
    public static func jpegData(_ image: CGImage, quality: Double = 0.82) -> Data? {
        encode(image, type: "public.jpeg", options: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    /// Lossless PNG bytes — for fixtures where every pixel must survive.
    public static func pngData(_ image: CGImage) -> Data? {
        encode(image, type: "public.png", options: [:])
    }

    private static func encode(_ image: CGImage, type: String, options: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
