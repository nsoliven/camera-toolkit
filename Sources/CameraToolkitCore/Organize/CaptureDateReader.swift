import Foundation
import ImageIO

/// The camera's own capture time, as written into EXIF.
///
/// Cameras record wall-clock time without a reliable time zone, so the value is
/// interpreted in the Mac's current time zone. That keeps a trip's days aligned
/// with the camera clock the photographer saw, even when file modification
/// times are offset by travel time zones.
public struct CaptureTimestamp: Codable, Equatable, Hashable, Sendable {
    public var original: String
    public var subseconds: String?

    public init(original: String, subseconds: String? = nil) {
        self.original = original
        self.subseconds = subseconds
    }

    public var date: Date? {
        CaptureDateReader.date(exifOriginal: original, subseconds: subseconds)
    }
}

/// Everything one metadata pass learns about a file: the camera's capture
/// time (stills only) and its camera tags.
public struct CaptureMetadata: Equatable, Sendable {
    public var timestamp: CaptureTimestamp?
    public var camera: CameraMetadata?

    public init(timestamp: CaptureTimestamp? = nil, camera: CameraMetadata? = nil) {
        self.timestamp = timestamp
        self.camera = camera
    }
}

public enum CaptureDateReader {
    static let smallHeaderByteCount = 64 * 1_024
    static let largeHeaderByteCount = 256 * 1_024

    static let tiffExtensions: Set<String> = [
        "arw", "dng", "nef", "nrw", "cr2", "orf", "rw2", "pef", "srw", "tif", "tiff"
    ]
    static let imageIOExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "webp"]

    public static func canRead(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return tiffExtensions.contains(ext) || imageIOExtensions.contains(ext)
    }

    public static func captureDate(of url: URL) -> Date? {
        timestamp(of: url)?.date
    }

    /// Reads only a small header block for TIFF-based RAW files. JPEG and HEIC
    /// metadata is read through ImageIO without decoding pixels.
    public static func timestamp(of url: URL) -> CaptureTimestamp? {
        metadata(of: url).timestamp
    }

    /// Whether `metadata(of:)` reads anything for this file — stills the
    /// capture-time reader understands, plus QuickTime-family clips whose
    /// camera tags it reads (clips have no capture time here; their board
    /// time comes from the folder's clock offset).
    public static func canReadMetadata(_ url: URL) -> Bool {
        canRead(url) || QuickTimeCameraReader.canRead(url)
    }

    /// The capture time and camera tags in one pass over the same bytes —
    /// the RAW header block, the ImageIO properties, or a clip's `moov`
    /// box — so learning the camera costs no extra file read.
    public static func metadata(of url: URL) -> CaptureMetadata {
        let ext = url.pathExtension.lowercased()
        if tiffExtensions.contains(ext) {
            let header = headerMetadata(url: url)
            if header.timestamp == nil, ext == "tif" || ext == "tiff" {
                let viaImageIO = imageIOMetadata(url: url)
                return CaptureMetadata(timestamp: viaImageIO.timestamp, camera: header.camera ?? viaImageIO.camera)
            }
            return header
        }
        if imageIOExtensions.contains(ext) {
            return imageIOMetadata(url: url)
        }
        if QuickTimeCameraReader.canRead(url) {
            return CaptureMetadata(timestamp: nil, camera: QuickTimeCameraReader.camera(of: url))
        }
        return CaptureMetadata()
    }

    public static func captureDate(tiffHeader data: Data) -> Date? {
        timestamp(tiffHeader: data)?.date
    }

    private static func headerMetadata(url: URL) -> CaptureMetadata {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return CaptureMetadata() }
        defer { try? handle.close() }
        guard let small = try? handle.read(upToCount: smallHeaderByteCount), small.count >= 8 else {
            return CaptureMetadata()
        }
        let first = metadata(tiffHeader: small)
        if first.timestamp != nil {
            return first
        }
        // Some bodies place the EXIF block farther in. Retry once with a
        // larger bounded header before giving up.
        guard small.count == smallHeaderByteCount,
              (small[0] == 0x49 && small[1] == 0x49) || (small[0] == 0x4d && small[1] == 0x4d),
              (try? handle.seek(toOffset: 0)) != nil,
              let large = try? handle.read(upToCount: largeHeaderByteCount) else {
            return first
        }
        let second = metadata(tiffHeader: large)
        return CaptureMetadata(timestamp: second.timestamp, camera: second.camera ?? first.camera)
    }

    private static func imageIOMetadata(url: URL) -> CaptureMetadata {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            return CaptureMetadata()
        }
        var result = CaptureMetadata()
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let camera = CameraMetadata(
                make: tiff[kCGImagePropertyTIFFMake] as? String,
                model: tiff[kCGImagePropertyTIFFModel] as? String
            )
            result.camera = camera.isEmpty ? nil : camera
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let subseconds = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String
            let timestamp = CaptureTimestamp(original: original, subseconds: subseconds)
            result.timestamp = timestamp.date == nil ? nil : timestamp
        }
        return result
    }

    private struct Entry {
        let tag: Int
        let type: Int
        let count: Int
        let valueField: Int
    }

    static func timestamp(tiffHeader data: Data) -> CaptureTimestamp? {
        metadata(tiffHeader: data).timestamp
    }

    /// The EXIF capture time and the primary IFD's Make (0x010F) and Model
    /// (0x0110) from one TIFF header block.
    static func metadata(tiffHeader data: Data) -> CaptureMetadata {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return CaptureMetadata() }
        let littleEndian: Bool
        switch (bytes[0], bytes[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4d, 0x4d): littleEndian = false
        default: return CaptureMetadata()
        }

        func uint16(at offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            let first = Int(bytes[offset])
            let second = Int(bytes[offset + 1])
            return littleEndian ? first | second << 8 : first << 8 | second
        }

        func uint32(at offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let a = Int(bytes[offset])
            let b = Int(bytes[offset + 1])
            let c = Int(bytes[offset + 2])
            let d = Int(bytes[offset + 3])
            return littleEndian ? a | b << 8 | c << 16 | d << 24 : a << 24 | b << 16 | c << 8 | d
        }

        func entries(at directory: Int) -> [Entry]? {
            guard let count = uint16(at: directory), count <= 4_096 else { return nil }
            return (0..<count).compactMap { index in
                let entry = directory + 2 + index * 12
                guard let tag = uint16(at: entry),
                      let type = uint16(at: entry + 2),
                      let valueCount = uint32(at: entry + 4) else { return nil }
                return Entry(tag: tag, type: type, count: valueCount, valueField: entry + 8)
            }
        }

        func ascii(_ entry: Entry) -> String? {
            guard entry.type == 2, entry.count > 0, entry.count <= 64 else { return nil }
            let start = entry.count <= 4 ? entry.valueField : (uint32(at: entry.valueField) ?? -1)
            guard start >= 0, start + entry.count <= bytes.count else { return nil }
            let characters = bytes[start..<(start + entry.count)].prefix { $0 != 0 }
            return String(bytes: characters, encoding: .ascii)
        }

        guard uint16(at: 2) == 42,
              let firstDirectory = uint32(at: 4),
              let primary = entries(at: firstDirectory) else {
            return CaptureMetadata()
        }
        let camera = CameraMetadata(
            make: primary.first(where: { $0.tag == 0x010F }).flatMap(ascii),
            model: primary.first(where: { $0.tag == 0x0110 }).flatMap(ascii)
        )
        var result = CaptureMetadata(timestamp: nil, camera: camera.isEmpty ? nil : camera)
        guard let exifPointer = primary.first(where: { $0.tag == 0x8769 }),
              let exifDirectory = uint32(at: exifPointer.valueField),
              let exif = entries(at: exifDirectory),
              let original = exif.first(where: { $0.tag == 0x9003 }).flatMap(ascii) else {
            return result
        }
        let subseconds = exif.first(where: { $0.tag == 0x9291 }).flatMap(ascii)
        let timestamp = CaptureTimestamp(original: original, subseconds: subseconds)
        result.timestamp = timestamp.date == nil ? nil : timestamp
        return result
    }

    /// Parses `yyyy:MM:dd HH:mm:ss` without a shared `DateFormatter`, so
    /// parallel header reads never contend on formatter state.
    public static func date(exifOriginal: String, subseconds: String?) -> Date? {
        let digits = exifOriginal.unicodeScalars.split { !CharacterSet.decimalDigits.contains($0) }
            .map { String(String.UnicodeScalarView($0)) }
        guard digits.count >= 6,
              let year = Int(digits[0]), let month = Int(digits[1]), let day = Int(digits[2]),
              let hour = Int(digits[3]), let minute = Int(digits[4]), let second = Int(digits[5]),
              year > 1900, (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = calendar.date(from: components) else { return nil }
        let fraction = subseconds
            .map { $0.filter(\.isNumber) }
            .flatMap { $0.isEmpty ? nil : Double("0." + $0) } ?? 0
        return date.addingTimeInterval(fraction)
    }
}

/// What the cache knows about one unchanged file. `cameraRead` is false
/// for an entry written before the cache carried camera tags (format
/// version 1): its timestamp is good, but its camera still has to be read
/// — once, by the next pass allowed to read headers.
public struct CachedCaptureMetadata: Equatable, Sendable {
    public var timestamp: CaptureTimestamp?
    public var camera: CameraMetadata?
    public var cameraRead: Bool
}

/// A small on-disk cache of capture timestamps and camera tags keyed by
/// path, size, and modification time. Re-opening a large unsorted folder
/// then skips every header read for files that have not changed.
///
/// Format history: version 1 stored timestamps only; version 2 adds the
/// optional `camera` and `cameraRead` fields per entry. Both load — a
/// version-1 entry decodes with `cameraRead` absent and fills its camera
/// lazily on the next read pass — and saves always write version 2.
public final class CaptureDateCache: @unchecked Sendable {
    private struct Entry: Codable {
        var size: Int64
        var modified: Double
        var timestamp: CaptureTimestamp?
        /// Camera tags found in the file; nil when none were written or
        /// they have not been read yet (`cameraRead`).
        var camera: CameraMetadata?
        /// True once the camera tags were read. Absent on version-1
        /// entries and on entries stored through the timestamp-only API.
        var cameraRead: Bool?
    }

    private struct Stored: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    /// The format `save()` writes.
    public static let currentVersion = 2
    /// Formats `init(url:)` accepts; anything else starts empty.
    static let readableVersions: ClosedRange<Int> = 1...2

    public let url: URL?
    /// Test seam — nil in production. When set, `OrganizeScanner.items`
    /// calls it instead of `CaptureDateReader.metadata` for the still
    /// header read a cache miss triggers (the camera then stays unknown),
    /// so a test can observe or park that read. It never fires on a cache
    /// hit, on a `readMissingCaptureDates: false` pass, or for clips.
    public var timestampProbe: (@Sendable (URL) -> CaptureTimestamp?)?
    private let lock = NSLock()
    private var entries: [String: Entry]
    private var isDirty = false

    public init(url: URL?) {
        self.url = url
        if let url,
           let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           Self.readableVersions.contains(stored.version) {
            entries = stored.entries
        } else {
            entries = [:]
        }
    }

    /// Returns `.some(nil)` for a cached "no camera timestamp" result and
    /// `nil` when the file is not cached or has changed.
    public func lookup(path: String, size: Int64, modifiedAt: Date) -> CaptureTimestamp?? {
        lookupMetadata(path: path, size: size, modifiedAt: modifiedAt).map { cached -> CaptureTimestamp? in cached.timestamp }
    }

    /// Everything cached for an unchanged file, or nil when it is not
    /// cached or has changed since.
    public func lookupMetadata(path: String, size: Int64, modifiedAt: Date) -> CachedCaptureMetadata? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path],
              entry.size == size,
              abs(entry.modified - modifiedAt.timeIntervalSinceReferenceDate) < 1 else {
            return nil
        }
        return CachedCaptureMetadata(timestamp: entry.timestamp, camera: entry.camera, cameraRead: entry.cameraRead == true)
    }

    /// Stores a timestamp without camera tags — the camera stays unread.
    public func store(path: String, size: Int64, modifiedAt: Date, timestamp: CaptureTimestamp?) {
        put(path, Entry(size: size, modified: modifiedAt.timeIntervalSinceReferenceDate, timestamp: timestamp))
    }

    /// Stores one full metadata pass — timestamp and camera tags.
    public func store(path: String, size: Int64, modifiedAt: Date, metadata: CaptureMetadata) {
        put(path, Entry(
            size: size,
            modified: modifiedAt.timeIntervalSinceReferenceDate,
            timestamp: metadata.timestamp,
            camera: metadata.camera,
            cameraRead: true
        ))
    }

    /// Moves cached entries to new paths (`old path → new path`) without
    /// re-reading the files: the layout migration renames files, which
    /// keeps their size and modification time. An existing entry at a new
    /// path is left alone. Returns how many entries moved.
    @discardableResult
    public func rekey(_ mapping: [String: String]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var moved = 0
        for (old, new) in mapping where old != new {
            guard let entry = entries[old], entries[new] == nil else { continue }
            entries[new] = entry
            entries[old] = nil
            moved += 1
        }
        if moved > 0 { isDirty = true }
        return moved
    }

    /// Paths with a cached entry.
    public var cachedPaths: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(entries.keys)
    }

    private func put(_ path: String, _ entry: Entry) {
        lock.lock()
        entries[path] = entry
        isDirty = true
        lock.unlock()
    }

    public func save() throws {
        lock.lock()
        guard isDirty, let url else {
            lock.unlock()
            return
        }
        let snapshot = Stored(version: Self.currentVersion, entries: entries)
        isDirty = false
        lock.unlock()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
