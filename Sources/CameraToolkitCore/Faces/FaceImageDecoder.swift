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

    /// A bounded decode for the pet detector, stood upright: a RAW's
    /// embedded JPEG turned by the camera's rotation, read in the one walk
    /// of the file that fetches the JPEG. Ordinary photos — and RAWs ImageIO
    /// decodes itself — are already upright, so their turn is 0. Nil when
    /// nothing could be read or the turn could not be applied.
    public static func uprightDetectionImage(for url: URL, maximumPixelSize: Int) -> UprightDetectionImage? {
        if OrganizeFileClassifier.rawExtensions.contains(url.pathExtension.lowercased()),
           let preview = try? EmbeddedJPEGPreviewExtractor().preview(from: url, preference: .fullSize),
           let source = CGImageSourceCreateWithData(preview.data as CFData, nil),
           let decoded = BurstVisualLinker.thumbnail(source: source, maximumPixelSize: maximumPixelSize) {
            let turns = DisplayRotation.normalized(preview.cameraQuarterTurns)
            let upright = DisplayRotation.rotate(decoded, quarterTurnsCW: turns)
            // `rotate` hands back its input when a bitmap cannot be made;
            // detecting on that would store boxes in the wrong space.
            guard turns == 0 || upright !== decoded else { return nil }
            return UprightDetectionImage(
                image: upright,
                storedPixelSize: sourceSize(source) ?? CGSize(width: decoded.width, height: decoded.height),
                cameraTurns: turns
            )
        }
        guard let image = detectionImage(for: url, maximumPixelSize: maximumPixelSize) else { return nil }
        return UprightDetectionImage(
            image: image,
            storedPixelSize: pixelSize(of: url) ?? CGSize(width: image.width, height: image.height),
            cameraTurns: 0
        )
    }

    /// The camera's rotation of a RAW, from the smallest useful preview so a
    /// NAS file costs one short read: 0 for a RAW with no embedded JPEG
    /// (ImageIO decodes those upright), nil when the file cannot be read.
    /// Blocking I/O — call it off the main actor.
    public static func cameraQuarterTurns(for url: URL) -> Int? {
        do {
            let preview = try EmbeddedJPEGPreviewExtractor().preview(from: url, preference: .thumbnail)
            return DisplayRotation.normalized(preview?.cameraQuarterTurns ?? 0)
        } catch {
            return nil
        }
    }

    /// A clip's representative frame — one second in, unlimited seek
    /// tolerance, track transform applied, the same poster the tile grid
    /// shows — so a video contributes faces without sweeping keyframes.
    public static func posterImage(for url: URL, maximumPixelSize: Int) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: CameraVideoAsset.asset(for: url))
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

/// A picture ready for the pet detector, and what turns the detector's
/// boxes back into the stored space.
public struct UprightDetectionImage {
    public var image: CGImage
    /// Native pixel size of the unturned picture — the space stored boxes
    /// and the size floor are measured in.
    public var storedPixelSize: CGSize
    /// Quarter-turns clockwise that were applied to reach `image`.
    public var cameraTurns: Int
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
