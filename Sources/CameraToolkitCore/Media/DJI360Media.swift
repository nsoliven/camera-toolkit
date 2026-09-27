import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Opens camera clips with AVFoundation. DJI `.OSV`/`.LRF`, GoPro `.LRV`
/// and Insta360 `.INSV` are ordinary ISO-BMFF (MP4) files, but AVFoundation
/// picks a demuxer by file extension and refuses these ("Cannot Open",
/// -11828) before it looks at a byte. Declaring the MIME type lets it open
/// them read-only like any MP4 — nothing about the file is changed.
public enum CameraVideoAsset {
    /// Extensions that are MP4 containers AVFoundation does not recognize
    /// by name.
    public static let mp4ContainerExtensions: Set<String> = ["osv", "lrf", "lrv", "insv"]

    public static func needsMIMEOverride(_ url: URL) -> Bool {
        mp4ContainerExtensions.contains(url.pathExtension.lowercased())
    }

    public static func asset(for url: URL) -> AVURLAsset {
        guard needsMIMEOverride(url) else { return AVURLAsset(url: url) }
        return AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
    }
}

/// DJI Osmo 360 media. The camera writes each clip as a pair in one folder:
///
/// - `CAM_…_D.OSV` — the original: two HEVC 3840×3840 fisheye streams (one
///   per lens), AAC, DJI metadata tracks, and a 688×344 equirectangular
///   JPEG in `moov/udta/meta/ilst/covr`.
/// - `CAM_…_D.LRF` — a same-stem low-res proxy: one H.264 2048×1024
///   stitched equirectangular stream plus the same cover JPEG.
///
/// The pairing rules (`OrganizeFileClassifier`) already make the LRF a
/// companion of its OSV, so the two move, trash and Apply together. This
/// type answers the playback, thumbnail and face-scan questions: which file
/// to read for a given job. It never writes either file.
public enum DJI360Media {
    /// The dual-fisheye original.
    public static let clipExtensions: Set<String> = ["osv"]
    /// Its stitched low-res proxy.
    public static let proxyExtensions: Set<String> = ["lrf"]

    public static func isClip(_ url: URL) -> Bool {
        clipExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isProxy(_ url: URL) -> Bool {
        proxyExtensions.contains(url.pathExtension.lowercased())
    }

    /// Either half of the pair — what DJI Studio opens.
    public static func isDJI360File(_ url: URL) -> Bool {
        isClip(url) || isProxy(url)
    }

    // MARK: - Proxy lookup

    /// The item's LRF proxy, read from the companions the scan already
    /// paired — no filesystem access, so views may ask.
    public static func proxy(for item: OrganizeItem) -> OrganizeFile? {
        guard clipExtensions.contains(item.primary.fileExtension) else { return nil }
        return item.companions.first {
            proxyExtensions.contains($0.fileExtension) && $0.stem == item.primary.stem
        }
    }

    /// The file a player should open for `item`: the LRF proxy for an OSV
    /// that has one (AVFoundation plays H.264 2048×1024 anywhere; the OSV
    /// only offers one raw fisheye lens), otherwise the primary itself.
    public static func playbackFile(for item: OrganizeItem) -> OrganizeFile {
        proxy(for: item) ?? item.primary
    }

    /// The file the face scanner samples for a video item. The stitched
    /// equirectangular proxy is ~20× less to decode than a 3840² fisheye
    /// stream and shows both lenses, so faces are found across the whole
    /// sphere instead of one hemisphere.
    public static func faceScanFile(for item: OrganizeItem) -> OrganizeFile {
        playbackFile(for: item)
    }

    /// The proxy's name among `names` (one folder's listing): same stem,
    /// an LRF extension, compared case-insensitively. An exact-case match
    /// wins over a case-folded one.
    public static func proxyName(forClipNamed clipName: String, among names: [String]) -> String? {
        let clip = clipName as NSString
        guard clipExtensions.contains(clip.pathExtension.lowercased()) else { return nil }
        let stem = clip.deletingPathExtension
        let candidates = names.filter { name in
            let candidate = name as NSString
            return proxyExtensions.contains(candidate.pathExtension.lowercased())
                && candidate.deletingPathExtension.caseInsensitiveCompare(stem) == .orderedSame
        }
        return candidates.first { ($0 as NSString).deletingPathExtension == stem } ?? candidates.first
    }

    /// The LRF beside the OSV at `clipURL`, for callers that only hold a
    /// URL (the tile loader). Tries the camera's own spellings with a stat
    /// each — enough on case-insensitive volumes — and lists the folder only
    /// when neither exists, for a case-sensitive volume or a renamed file.
    /// Touches the filesystem: call it off the main actor.
    public static func proxyURL(forClipAt clipURL: URL, fileManager: FileManager = .default) -> URL? {
        guard isClip(clipURL) else { return nil }
        let folder = clipURL.deletingLastPathComponent()
        let stem = clipURL.deletingPathExtension().lastPathComponent
        for ext in ["LRF", "lrf"] {
            let candidate = folder.appending(path: "\(stem).\(ext)", directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path),
              let name = proxyName(forClipNamed: clipURL.lastPathComponent, among: names) else { return nil }
        return folder.appending(path: name, directoryHint: .notDirectory)
    }

    // MARK: - Thumbnails

    /// Where a 360 clip's picture can come from, cheapest first at tile
    /// sizes.
    public enum ThumbnailSource: Equatable, Sendable {
        /// The 688×344 equirectangular JPEG in the clip's own `moov` — a
        /// ~50 KB read, no video decode.
        case embeddedCover(URL)
        /// A frame of the stitched LRF proxy (H.264 2048×1024).
        case proxyFrame(URL)
        /// A frame of the OSV's first enabled HEVC track — one fisheye lens.
        /// Last resort: it is the costliest decode and shows half the scene.
        case lensFrame(URL)
    }

    /// Cover art is plenty for a tile; anything larger than it should come
    /// from the proxy's full 2048-px frame so the preview poster isn't an
    /// upscaled thumbnail.
    public static let coverArtLongEdge = 688

    /// The order sources are tried for a decode of `maximumPixelSize`. The
    /// proxy is represented by its lookup and resolved lazily by
    /// `thumbnail(forClipAt:…)`, so a tile the cover satisfies never lists
    /// the folder.
    public enum ThumbnailSourceKind: Equatable, Sendable {
        case embeddedCover, proxyFrame, lensFrame
    }

    public static func thumbnailSourceOrder(maximumPixelSize: Int) -> [ThumbnailSourceKind] {
        maximumPixelSize <= 768
            ? [.embeddedCover, .proxyFrame, .lensFrame]
            : [.proxyFrame, .embeddedCover, .lensFrame]
    }

    /// Tries each source in `thumbnailSourceOrder` until one decodes.
    /// `proxyLookup` runs at most once, and only when the proxy's turn
    /// comes. Injected `load` keeps this testable without real video.
    public static func thumbnail(
        forClipAt clipURL: URL,
        maximumPixelSize: Int,
        proxyLookup: (URL) -> URL? = { proxyURL(forClipAt: $0) },
        load: (ThumbnailSource) -> CGImage?
    ) -> CGImage? {
        var resolvedProxy: URL??
        for kind in thumbnailSourceOrder(maximumPixelSize: maximumPixelSize) {
            let source: ThumbnailSource
            switch kind {
            case .embeddedCover:
                source = .embeddedCover(clipURL)
            case .proxyFrame:
                if resolvedProxy == nil { resolvedProxy = .some(proxyLookup(clipURL)) }
                guard let proxy = resolvedProxy ?? nil else { continue }
                source = .proxyFrame(proxy)
            case .lensFrame:
                source = .lensFrame(clipURL)
            }
            if let image = load(source) { return image }
        }
        return nil
    }
}

/// Reads the cover picture QuickTime-family files carry in
/// `udta/meta/ilst/covr` (DJI writes its equirectangular thumbnail there).
/// Walks top-level box headers with seeks, reads only the bounded `moov`
/// payload, and closes the file before returning.
public enum QuickTimeCoverArtReader {
    static let maximumMovieBoxBytes = QuickTimeCameraReader.maximumMovieBoxBytes

    /// JPEG or PNG bytes of the first cover item, or nil.
    public static func imageData(from url: URL) -> Data? {
        guard let movie = movieBox(of: url) else { return nil }
        return imageData(movieBox: movie)
    }

    public static func image(from url: URL, maximumPixelSize: Int) -> CGImage? {
        guard let data = imageData(from: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Parses a `moov` payload (without its own header).
    public static func imageData(movieBox data: Data) -> Data? {
        let bytes = [UInt8](data)
        for child in QuickTimeCameraReader.boxes(bytes, 0..<bytes.count) {
            switch child.type {
            case "udta":
                for meta in QuickTimeCameraReader.boxes(bytes, child.payload) where meta.type == "meta" {
                    if let image = cover(inMeta: bytes, meta.payload) { return image }
                }
            case "meta":
                if let image = cover(inMeta: bytes, child.payload) { return image }
            default:
                break
            }
        }
        return nil
    }

    private static func cover(inMeta bytes: [UInt8], _ range: Range<Int>) -> Data? {
        var start = range.lowerBound
        // Full box inside `udta` (version+flags word), plain container at
        // the movie level.
        if start + 4 <= range.upperBound, QuickTimeCameraReader.uint32(bytes, start) == 0 { start += 4 }
        let children = QuickTimeCameraReader.boxes(bytes, start..<range.upperBound)
        guard let list = children.first(where: { $0.type == "ilst" }) else { return nil }
        for item in QuickTimeCameraReader.boxes(bytes, list.payload) where item.type == "covr" {
            for data in QuickTimeCameraReader.boxes(bytes, item.payload) where data.type == "data" {
                guard data.payload.count > 8 else { continue }
                let typeIndicator = QuickTimeCameraReader.uint32(bytes, data.payload.lowerBound) & 0x00FF_FFFF
                let image = Data(bytes[(data.payload.lowerBound + 8)..<data.payload.upperBound])
                // 13 = JPEG, 14 = PNG; 0 (implicit) is accepted when the
                // bytes carry an image signature.
                if typeIndicator == 13 || typeIndicator == 14 || typeIndicator == 0, isImage(image) {
                    return image
                }
            }
        }
        return nil
    }

    static func isImage(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8, 0xFF]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    private static func movieBox(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        var offset: UInt64 = 0
        for _ in 0..<QuickTimeCameraReader.maximumTopLevelBoxes {
            guard offset + 8 <= fileSize,
                  (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: 16), header.count >= 8 else { return nil }
            let bytes = [UInt8](header)
            let size32 = UInt64(QuickTimeCameraReader.uint32(bytes, 0))
            var headerLength: UInt64 = 8
            var size = size32
            if size32 == 1 {
                guard bytes.count >= 16 else { return nil }
                size = UInt64(QuickTimeCameraReader.uint32(bytes, 8)) << 32 | UInt64(QuickTimeCameraReader.uint32(bytes, 12))
                headerLength = 16
            } else if size32 == 0 {
                size = fileSize - offset
            }
            guard size >= headerLength else { return nil }
            if QuickTimeCameraReader.fourCC(bytes, 4) == "moov" {
                let payloadLength = size - headerLength
                guard payloadLength <= UInt64(maximumMovieBoxBytes),
                      (try? handle.seek(toOffset: offset + headerLength)) != nil,
                      let payload = try? handle.read(upToCount: Int(payloadLength)) else { return nil }
                return payload
            }
            offset += size
        }
        return nil
    }
}
