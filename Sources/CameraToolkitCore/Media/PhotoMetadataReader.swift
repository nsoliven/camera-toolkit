import Foundation
import ImageIO

/// Camera and exposure metadata for one still frame, shown in the burst
/// preview's inspector.
///
/// Everything is read through ImageIO properties — no pixels are decoded,
/// so this is safe to run on a background queue the moment a frame is
/// selected. TIFF-based RAW files that expose no EXIF of their own fall
/// back to the embedded JPEG preview's metadata, the same bytes the tile
/// decoder already relies on.
public struct PhotoMetadata: Equatable, Sendable {
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var exposureSeconds: Double?
    public var fNumber: Double?
    public var iso: Int?
    public var focalLengthMillimeters: Double?
    public var focalLength35mmMillimeters: Double?
    public var capturedAt: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init() {}

    /// Whether any camera/EXIF field was found at all — used to decide if a
    /// RAW's embedded preview is worth consulting.
    public var hasCameraFields: Bool {
        cameraMake != nil || cameraModel != nil
            || exposureSeconds != nil || fNumber != nil || iso != nil
            || focalLengthMillimeters != nil
    }

    /// "Sony ILCE-7RM5" — the make prefix is dropped when the model already
    /// starts with it ("SONY ILCE-7RM5" stays "ILCE-7RM5"-style).
    public var cameraDisplay: String? {
        let make = cameraMake?.trimmingCharacters(in: .whitespaces)
        let model = cameraModel?.trimmingCharacters(in: .whitespaces)
        switch (make, model) {
        case let (make?, model?):
            if model.lowercased().hasPrefix(make.lowercased()) { return model }
            return "\(make) \(model)"
        case (nil, let model?):
            return model
        case (let make?, nil):
            return make
        case (nil, nil):
            return nil
        }
    }

    /// "1/250 s", or "0.8 s" once exposures lengthen past a third of a
    /// second.
    public var shutterDisplay: String? {
        guard let exposureSeconds, exposureSeconds > 0 else { return nil }
        if exposureSeconds >= 1.0 / 3.0 {
            let text = String(format: "%.1f", exposureSeconds)
            return "\(text) s"
        }
        let denominator = Int((1.0 / exposureSeconds).rounded())
        return denominator > 0 ? "1/\(denominator) s" : nil
    }

    /// "f/2.8".
    public var apertureDisplay: String? {
        guard let fNumber, fNumber > 0 else { return nil }
        return "f/\(Self.trimmed(fNumber))"
    }

    /// "ISO 400".
    public var isoDisplay: String? {
        iso.map { "ISO \($0)" }
    }

    /// "85 mm", plus the 35 mm equivalent in parentheses when present.
    public var focalDisplay: String? {
        guard let focalLengthMillimeters, focalLengthMillimeters > 0 else { return nil }
        var text = "\(Self.trimmed(focalLengthMillimeters)) mm"
        if let equivalent = focalLength35mmMillimeters, equivalent > 0 {
            text += " (\(Self.trimmed(equivalent)) mm eq.)"
        }
        return text
    }

    /// "6000 × 4000".
    public var dimensionsDisplay: String? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    private static func trimmed(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    /// Fields present in `other` fill gaps here without overwriting — the
    /// container's own values stay authoritative.
    func merged(with other: PhotoMetadata) -> PhotoMetadata {
        var copy = self
        copy.cameraMake = cameraMake ?? other.cameraMake
        copy.cameraModel = cameraModel ?? other.cameraModel
        copy.lens = lens ?? other.lens
        copy.exposureSeconds = exposureSeconds ?? other.exposureSeconds
        copy.fNumber = fNumber ?? other.fNumber
        copy.iso = iso ?? other.iso
        copy.focalLengthMillimeters = focalLengthMillimeters ?? other.focalLengthMillimeters
        copy.focalLength35mmMillimeters = focalLength35mmMillimeters ?? other.focalLength35mmMillimeters
        copy.capturedAt = capturedAt ?? other.capturedAt
        copy.pixelWidth = pixelWidth ?? other.pixelWidth
        copy.pixelHeight = pixelHeight ?? other.pixelHeight
        return copy
    }
}

public enum PhotoMetadataReader {
    /// Reads metadata for a still. Non-image files produce an empty result —
    /// callers show the file's own fields instead.
    public static func metadata(for url: URL) -> PhotoMetadata {
        var metadata = PhotoMetadata()
        if let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) {
            metadata = read(source)
        }
        // TIFF-based RAW containers that ImageIO can't fully parse still
        // carry a full EXIF block in their embedded JPEG preview.
        if !metadata.hasCameraFields,
           OrganizeFileClassifier.rawExtensions.contains(url.pathExtension.lowercased()),
           let data = try? EmbeddedJPEGPreviewExtractor().jpegData(from: url, preference: .fullSize),
           let source = CGImageSourceCreateWithData(data as CFData, nil) {
            metadata = metadata.merged(with: read(source))
        }
        return metadata
    }

    private static func read(_ source: CGImageSource) -> PhotoMetadata {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options)
                as? [CFString: Any] else {
            return PhotoMetadata()
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let exifAux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]

        var metadata = PhotoMetadata()
        metadata.cameraMake = tiff?[kCGImagePropertyTIFFMake] as? String
        metadata.cameraModel = tiff?[kCGImagePropertyTIFFModel] as? String
        metadata.lens = exifAux?[kCGImagePropertyExifAuxLensModel] as? String
        metadata.exposureSeconds = double(exif?[kCGImagePropertyExifExposureTime])
            ?? exif?[kCGImagePropertyExifShutterSpeedValue]
                .flatMap(double)
                .map { pow(2.0, -$0) }
        metadata.fNumber = double(exif?[kCGImagePropertyExifFNumber])
            ?? exif?[kCGImagePropertyExifApertureValue]
                .flatMap(double)
                .map { pow(sqrt(2.0), $0) }
        metadata.iso = int(exif?[kCGImagePropertyExifISOSpeedRatings])
            ?? int(exif?["ISOSpeed" as CFString])
        metadata.focalLengthMillimeters = double(exif?[kCGImagePropertyExifFocalLength])
        metadata.focalLength35mmMillimeters = double(exif?[kCGImagePropertyExifFocalLenIn35mmFilm])
        if let original = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            let subseconds = exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String
            metadata.capturedAt = CaptureDateReader.date(exifOriginal: original, subseconds: subseconds)
        }
        metadata.pixelWidth = int(properties[kCGImagePropertyPixelWidth])
        metadata.pixelHeight = int(properties[kCGImagePropertyPixelHeight])
        return metadata
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let number as NSNumber: return number.doubleValue
        default: return nil
        }
    }

    /// ISO arrives as either a scalar or a one-element array depending on
    /// the EXIF writer.
    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as Double: return Int(number)
        case let number as NSNumber: return number.intValue
        case let array as [Any]: return array.first.flatMap(int)
        default: return nil
        }
    }
}
