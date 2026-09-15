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
        let ext = url.pathExtension.lowercased()
        if tiffExtensions.contains(ext) {
            if let timestamp = headerTimestamp(url: url) {
                return timestamp
            }
            if ext == "tif" || ext == "tiff" {
                return imageIOTimestamp(url: url)
            }
            return nil
        }
        if imageIOExtensions.contains(ext) {
            return imageIOTimestamp(url: url)
        }
        return nil
    }

    public static func captureDate(tiffHeader data: Data) -> Date? {
        timestamp(tiffHeader: data)?.date
    }

    private static func headerTimestamp(url: URL) -> CaptureTimestamp? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let small = try? handle.read(upToCount: smallHeaderByteCount), small.count >= 8 else {
            return nil
        }
        if let timestamp = timestamp(tiffHeader: small) {
            return timestamp
        }
        // Some bodies place the EXIF block farther in. Retry once with a
        // larger bounded header before giving up.
        guard small.count == smallHeaderByteCount,
              (small[0] == 0x49 && small[1] == 0x49) || (small[0] == 0x4d && small[1] == 0x4d),
              (try? handle.seek(toOffset: 0)) != nil,
              let large = try? handle.read(upToCount: largeHeaderByteCount) else {
            return nil
        }
        return timestamp(tiffHeader: large)
    }

    private static func imageIOTimestamp(url: URL) -> CaptureTimestamp? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return nil
        }
        let subseconds = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String
        let timestamp = CaptureTimestamp(original: original, subseconds: subseconds)
        return timestamp.date == nil ? nil : timestamp
    }

    private struct Entry {
        let tag: Int
        let type: Int
        let count: Int
        let valueField: Int
    }

    static func timestamp(tiffHeader data: Data) -> CaptureTimestamp? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        let littleEndian: Bool
        switch (bytes[0], bytes[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4d, 0x4d): littleEndian = false
        default: return nil
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
              let primary = entries(at: firstDirectory),
              let exifPointer = primary.first(where: { $0.tag == 0x8769 }),
              let exifDirectory = uint32(at: exifPointer.valueField),
              let exif = entries(at: exifDirectory),
              let original = exif.first(where: { $0.tag == 0x9003 }).flatMap(ascii) else {
            return nil
        }
        let subseconds = exif.first(where: { $0.tag == 0x9291 }).flatMap(ascii)
        let timestamp = CaptureTimestamp(original: original, subseconds: subseconds)
        return timestamp.date == nil ? nil : timestamp
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

/// A small on-disk cache of capture timestamps keyed by path, size, and
/// modification time. Re-opening a large unsorted folder then skips every
/// header read for files that have not changed.
public final class CaptureDateCache: @unchecked Sendable {
    private struct Entry: Codable {
        var size: Int64
        var modified: Double
        var timestamp: CaptureTimestamp?
    }

    private struct Stored: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    public let url: URL?
    private let lock = NSLock()
    private var entries: [String: Entry]
    private var isDirty = false

    public init(url: URL?) {
        self.url = url
        if let url,
           let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           stored.version == 1 {
            entries = stored.entries
        } else {
            entries = [:]
        }
    }

    /// Returns `.some(nil)` for a cached "no camera timestamp" result and
    /// `nil` when the file is not cached or has changed.
    public func lookup(path: String, size: Int64, modifiedAt: Date) -> CaptureTimestamp?? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path],
              entry.size == size,
              abs(entry.modified - modifiedAt.timeIntervalSinceReferenceDate) < 1 else {
            return nil
        }
        return .some(entry.timestamp)
    }

    public func store(path: String, size: Int64, modifiedAt: Date, timestamp: CaptureTimestamp?) {
        lock.lock()
        entries[path] = Entry(size: size, modified: modifiedAt.timeIntervalSinceReferenceDate, timestamp: timestamp)
        isDirty = true
        lock.unlock()
    }

    public func save() throws {
        lock.lock()
        guard isDirty, let url else {
            lock.unlock()
            return
        }
        let snapshot = Stored(version: 1, entries: entries)
        isDirty = false
        lock.unlock()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
