import CoreGraphics
import Foundation
import ImageIO
import Vision

/// How a neighbouring pair of stills may link into one burst.
public enum BurstLinkRequirement: Equatable, Sendable {
    /// Gap within the certain-burst band; chains without image analysis.
    case automatic
    /// Longer gap; chains only when the Vision feature prints match.
    case visualCheck
    /// Never chains.
    case separate
}

/// Burst grouping thresholds shared by the scanner, the stacker, and the
/// visual linker. Defaults mirror the standalone Sony Burst Grouper app.
public struct BurstGroupingConfiguration: Equatable, Sendable {
    /// Gaps up to this many seconds chain automatically. Default 1.0 s.
    public var automaticGapSeconds: TimeInterval
    /// Longest gap a visual match can recover. Default 2.0 s.
    public var maximumGapSeconds: TimeInterval
    /// Whether pairs in the recovery band get a Vision feature-print check.
    public var useVisualRecovery: Bool
    /// Highest Apple Vision feature-print distance that still counts as the
    /// same scene. Tuned on full-size Sony A7 V previews. Default 0.48.
    public var maximumVisionDistance: Float
    /// Chains smaller than this split back into singles. Default 2.
    public var minimumGroupSize: Int

    public init(
        automaticGapSeconds: TimeInterval = 1.0,
        maximumGapSeconds: TimeInterval = 2.0,
        useVisualRecovery: Bool = true,
        maximumVisionDistance: Float = 0.48,
        minimumGroupSize: Int = 2
    ) {
        self.automaticGapSeconds = automaticGapSeconds
        self.maximumGapSeconds = maximumGapSeconds
        self.useVisualRecovery = useVisualRecovery
        self.maximumVisionDistance = maximumVisionDistance
        self.minimumGroupSize = minimumGroupSize
    }
}

extension BurstGroupingConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case automaticGapSeconds, maximumGapSeconds, useVisualRecovery
        case maximumVisionDistance, minimumGroupSize
    }

    /// Missing keys fall back to the defaults so persisted JSON stays
    /// readable when the configuration grows new fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BurstGroupingConfiguration()
        automaticGapSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .automaticGapSeconds) ?? defaults.automaticGapSeconds
        maximumGapSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .maximumGapSeconds) ?? defaults.maximumGapSeconds
        useVisualRecovery = try container.decodeIfPresent(Bool.self, forKey: .useVisualRecovery) ?? defaults.useVisualRecovery
        maximumVisionDistance = try container.decodeIfPresent(Float.self, forKey: .maximumVisionDistance) ?? defaults.maximumVisionDistance
        minimumGroupSize = try container.decodeIfPresent(Int.self, forKey: .minimumGroupSize) ?? defaults.minimumGroupSize
    }
}

extension BurstGroupingConfiguration {
    /// `UserDefaults` keys shared by Settings and the scanner.
    public static let visualRecoveryDefaultsKey = "CameraToolkit.organize.burstVisualRecovery"
    public static let maximumGapDefaultsKey = "CameraToolkit.organize.burstMaximumGapSeconds"
    public static let maximumVisionDistanceDefaultsKey = "CameraToolkit.organize.burstMaximumVisionDistance"

    /// The persisted grouping options, or the defaults when untouched.
    public static func resolved(from defaults: UserDefaults = .standard) -> BurstGroupingConfiguration {
        var configuration = BurstGroupingConfiguration()
        if defaults.object(forKey: visualRecoveryDefaultsKey) != nil {
            configuration.useVisualRecovery = defaults.bool(forKey: visualRecoveryDefaultsKey)
        }
        if let gap = defaults.object(forKey: maximumGapDefaultsKey) as? Double, gap > 0 {
            configuration.maximumGapSeconds = gap
        }
        if let distance = defaults.object(forKey: maximumVisionDistanceDefaultsKey) as? Double, distance > 0 {
            configuration.maximumVisionDistance = Float(distance)
        }
        return configuration
    }
}

/// A consecutive stills pair the Vision check cleared to chain.
public struct BurstVisualLink: Hashable, Sendable {
    public var previousPath: String
    public var nextPath: String

    public init(previousPath: String, nextPath: String) {
        self.previousPath = previousPath
        self.nextPath = nextPath
    }

    public init(previous: OrganizeItem, next: OrganizeItem) {
        self.init(previousPath: previous.primary.path, nextPath: next.primary.path)
    }
}

public enum BurstVisualLinkerError: LocalizedError {
    case unreadablePreview(String)
    case noFeaturePrint(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadablePreview(name):
            return "Could not decode a preview image from \(name)."
        case let .noFeaturePrint(name):
            return "Apple Vision produced no feature print for \(name)."
        }
    }
}

/// Apple Vision recovery for burst pairs in the ambiguous gap band.
///
/// Only same-folder consecutive stills whose capture gap falls in
/// `(automaticGapSeconds, maximumGapSeconds]` are fingerprinted — pairs in the
/// automatic band and pairs that can never chain skip image decoding entirely.
/// Fingerprints use the camera's embedded JPEG preview for RAW files, so a
/// scan never decodes full sensor data.
public enum BurstVisualLinker {
    /// Longer edge of the bounded decode Vision fingerprints. Matches the
    /// 512 px the distance threshold was tuned on in Sony Burst Grouper;
    /// larger previews add cost, not signal.
    public static let featurePrintPixelSize = 512

    static let progressPhase = "Comparing burst frames"

    /// Consecutive same-folder still pairs in the recovery band — the only
    /// pairs that ever get fingerprinted. Prefix-trusted folders are skipped
    /// because their grouping is already decided.
    public static func recoveryPairs(
        for items: [OrganizeItem],
        configuration: BurstGroupingConfiguration = BurstGroupingConfiguration()
    ) -> [(previous: OrganizeItem, next: OrganizeItem)] {
        guard configuration.useVisualRecovery else { return [] }
        var pairs: [(previous: OrganizeItem, next: OrganizeItem)] = []
        for sorted in OrganizeStacker.sortedItemsByFolder(items) {
            guard !sorted.contains(where: { $0.burstPrefix != nil }) else { continue }
            for index in sorted.indices.dropFirst() {
                let previous = sorted[index - 1]
                let next = sorted[index]
                if OrganizeStacker.linkRequirement(from: previous, to: next, configuration: configuration) == .visualCheck {
                    pairs.append((previous, next))
                }
            }
        }
        return pairs
    }

    /// Fingerprints the files touched by recovery-band pairs in parallel and
    /// returns the links whose feature-print distance is at most
    /// `maximumVisionDistance`. Files without a readable preview simply never
    /// link, so a failed decode splits rather than merges.
    public static func links(
        for items: [OrganizeItem],
        configuration: BurstGroupingConfiguration = BurstGroupingConfiguration(),
        concurrency: Int = 8,
        progress: (@Sendable (OrganizeScanProgress) -> Void)? = nil
    ) -> Set<BurstVisualLink> {
        let pairs = recoveryPairs(for: items, configuration: configuration)
        guard !pairs.isEmpty else { return [] }

        // Fingerprint each file once even when it appears in several pairs.
        var orderedPaths: [String] = []
        var seen: Set<String> = []
        for pair in pairs {
            for path in [pair.previous.primary.path, pair.next.primary.path] where seen.insert(path).inserted {
                orderedPaths.append(path)
            }
        }

        let paths = orderedPaths
        let total = paths.count
        progress?(OrganizeScanProgress(phase: progressPhase, processed: 0, total: total))
        let results = OrganizeScanner.parallelMap(
            count: total,
            width: concurrency,
            onCompleted: { completed in
                if completed == total || completed % 10 == 0 {
                    progress?(OrganizeScanProgress(phase: progressPhase, processed: completed, total: total))
                }
            },
            transform: { index in
                autoreleasepool {
                    FeaturePrintBox(print: try? featurePrint(forPath: paths[index]))
                }
            }
        )
        var prints: [String: VNFeaturePrintObservation] = [:]
        prints.reserveCapacity(total)
        for (path, result) in zip(paths, results) {
            if let print = result.print { prints[path] = print }
        }

        var links = Set<BurstVisualLink>()
        for pair in pairs {
            guard let first = prints[pair.previous.primary.path],
                  let second = prints[pair.next.primary.path] else { continue }
            var distance: Float = 0
            guard (try? first.computeDistance(&distance, to: second)) != nil else { continue }
            if distance <= configuration.maximumVisionDistance {
                links.insert(BurstVisualLink(previous: pair.previous, next: pair.next))
            }
        }
        return links
    }

    /// Feature-print distance between two files' previews. Small values mean
    /// the same scene; used by `links` and handy for diagnostics.
    public static func featurePrintDistance(from first: URL, to second: URL) throws -> Float {
        let firstPrint = try featurePrint(forPath: first.standardizedFileURL.path)
        let secondPrint = try featurePrint(forPath: second.standardizedFileURL.path)
        var distance: Float = 0
        try firstPrint.computeDistance(&distance, to: secondPrint)
        return distance
    }

    /// VNFeaturePrintObservation is immutable once generated; boxing lets the
    /// bounded parallel map hand results back across worker threads.
    private struct FeaturePrintBox: @unchecked Sendable {
        var print: VNFeaturePrintObservation?
    }

    private static func featurePrint(forPath path: String) throws -> VNFeaturePrintObservation {
        let url = URL(fileURLWithPath: path)
        guard let image = previewImage(for: url, maximumPixelSize: featurePrintPixelSize) else {
            throw BurstVisualLinkerError.unreadablePreview(url.lastPathComponent)
        }
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first else {
            throw BurstVisualLinkerError.noFeaturePrint(url.lastPathComponent)
        }
        return result
    }

    /// A bounded, orientation-applied decode. RAW files decode their largest
    /// embedded JPEG — the same full-size preview the distance threshold was
    /// tuned on — while ordinary photos decode straight through ImageIO. A
    /// RAW without an embedded JPEG falls back to ImageIO's RAW decoder.
    static func previewImage(for url: URL, maximumPixelSize: Int) -> CGImage? {
        if OrganizeFileClassifier.rawExtensions.contains(url.pathExtension.lowercased()),
           let data = try? EmbeddedJPEGPreviewExtractor().jpegData(from: url, preference: .fullSize),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = thumbnail(source: source, maximumPixelSize: maximumPixelSize) {
            return image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(source: source, maximumPixelSize: maximumPixelSize)
    }

    private static func thumbnail(source: CGImageSource, maximumPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
