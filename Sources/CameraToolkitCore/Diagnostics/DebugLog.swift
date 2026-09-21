import Foundation

/// One JSONL line in `debug.jsonl`. Every field after `level` is optional so
/// a line carries only what was cheap to capture at the call site — no image
/// bytes, no EXIF, no paths beyond a file's basename.
public struct DebugLogEvent: Codable, Sendable {
    public var ts: String
    public var subsystem: DebugSubsystem
    public var event: String
    public var level: DebugLevel
    public var durationMs: Int?
    public var outcome: DebugOutcome?
    public var file: String?
    public var ext: String?
    public var size: Int64?
    public var error: String?
    public var detail: String?

    public init(
        ts: String,
        subsystem: DebugSubsystem,
        event: String,
        level: DebugLevel,
        durationMs: Int? = nil,
        outcome: DebugOutcome? = nil,
        file: String? = nil,
        ext: String? = nil,
        size: Int64? = nil,
        error: String? = nil,
        detail: String? = nil
    ) {
        self.ts = ts
        self.subsystem = subsystem
        self.event = event
        self.level = level
        self.durationMs = durationMs
        self.outcome = outcome
        self.file = file
        self.ext = ext
        self.size = size
        self.error = error
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case ts, subsystem, event, level, outcome, file, ext, size, error, detail
        case durationMs = "duration_ms"
    }
}

public enum DebugSubsystem: String, Codable, Sendable {
    case preview
    case tile
    case trash
    case apply
    case video
}

public enum DebugOutcome: String, Codable, Sendable {
    case ok
    case timeout
    case error
    case cancel
}

public enum DebugLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

/// The debug event stream a coordinator can `tail -F` while diagnosing
/// stalls — separate from the activity log, which records job history.
///
/// Writes are queued on a serial utility queue so logging never blocks the
/// caller, and every failure is swallowed: a full disk or a missing Logs
/// folder must not break preview, trash, or apply work. The file is capped
/// (`maxBytes`): once it grows past the cap the oldest half is trimmed away
/// in place, keeping the same inode so a running `tail` survives the trim.
public final class DebugLog: @unchecked Sendable {
    public static let shared = DebugLog()

    public let url: URL
    private let maxBytes: UInt64
    private let queue = DispatchQueue(label: "CameraToolkit.DebugLog", qos: .utility)
    private let encoder = JSONEncoder()
    /// Formatters are thread-safe; the timestamp is taken at call time so a
    /// queued line keeps the moment it was logged, not when it was written.
    private let formatter = ISO8601DateFormatter()
    private var handle: FileHandle?

    public init(url: URL? = nil, maxBytes: UInt64 = 4 * 1_024 * 1_024) {
        self.url = url ?? Self.defaultURL()
        self.maxBytes = maxBytes
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// `~/Library/Logs/CameraToolkit/debug.jsonl`.
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CameraToolkit/debug.jsonl")
    }

    /// Queue one event line. Returns immediately; the encode and write happen
    /// on the log queue.
    public func log(
        _ event: String,
        subsystem: DebugSubsystem,
        level: DebugLevel = .debug,
        outcome: DebugOutcome? = nil,
        duration: Duration? = nil,
        url: URL? = nil,
        size: Int64? = nil,
        error: String? = nil,
        detail: String? = nil
    ) {
        let entry = DebugLogEvent(
            ts: formatter.string(from: Date()),
            subsystem: subsystem,
            event: event,
            level: level,
            durationMs: duration.map(Self.milliseconds),
            outcome: outcome,
            file: url?.lastPathComponent,
            ext: url?.pathExtension.lowercased(),
            size: size,
            error: error,
            detail: detail
        )
        queue.async { self.write(entry) }
    }

    /// One `stat` for the size field — cheap on a background thread, but not
    /// safe to call on the UI for a file that may live on a stalled volume.
    public static func fileSize(of url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    /// Error text that can't smuggle a path into the log: every Swift error
    /// bridges to NSError, so "domain code" (`NSCocoaErrorDomain 260`,
    /// `NSPOSIXErrorDomain 24`) is all that gets written — enough to
    /// correlate, nothing to identify a file.
    public static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    /// Test/diagnostic hook: returns after every queued line is on disk.
    public func flush() {
        queue.sync {}
    }

    private func write(_ event: DebugLogEvent) {
        do {
            if handle == nil { try open() }
            guard let handle else { return }
            try trimIfNeeded()
            var data = try encoder.encode(event)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            // Swallow, but drop the handle so the next line retries from a
            // fresh open instead of failing against a stale descriptor.
            try? handle?.close()
            handle = nil
        }
    }

    private func open() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        // Read-write, not write-only: trimming reads the tail back before
        // rewriting it, and a O_WRONLY handle can't.
        let handle = try FileHandle(forUpdating: url)
        _ = try handle.seekToEnd()
        self.handle = handle
    }

    /// Keeps the newest half of the file once it passes the cap. The rewrite
    /// happens on the same inode (seek + truncate, not replace) so a running
    /// `tail -f` keeps following it; the partial first line of the kept tail
    /// is dropped so every remaining line still parses.
    private func trimIfNeeded() throws {
        guard let handle else { return }
        let end = try handle.seekToEnd()
        guard end > maxBytes else { return }
        let keepBytes = maxBytes / 2
        let tailStart = end > keepBytes ? end - keepBytes : 0
        _ = try handle.seek(toFileOffset: tailStart)
        var tail = try handle.readToEnd() ?? Data()
        if let newline = tail.firstIndex(of: 0x0A), newline + 1 < tail.endIndex {
            tail = tail.subdata(in: newline + 1 ..< tail.endIndex)
        } else {
            tail = Data()
        }
        _ = try handle.seek(toFileOffset: 0)
        try handle.write(contentsOf: tail)
        try handle.truncate(atOffset: UInt64(tail.count))
        _ = try handle.seekToEnd()
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
