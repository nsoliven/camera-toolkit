import Darwin
import Foundation

/// A quick NAS speed check's measurements.
public struct NASSpeedTestResult: Sendable, Equatable, Codable {
    public var bytes: Int64
    /// Writing every byte plus the close — no fsync, like a sync's copy.
    public var writeSeconds: Double
    /// Reading it back with the client cache bypassed.
    public var readSeconds: Double
    /// One small file: create + write + close, then open + read + close.
    public var smallWriteSeconds: Double
    public var smallReadSeconds: Double
    public var finishedAt: Date

    public init(bytes: Int64, writeSeconds: Double, readSeconds: Double, smallWriteSeconds: Double, smallReadSeconds: Double, finishedAt: Date) {
        self.bytes = bytes
        self.writeSeconds = writeSeconds
        self.readSeconds = readSeconds
        self.smallWriteSeconds = smallWriteSeconds
        self.smallReadSeconds = smallReadSeconds
        self.finishedAt = finishedAt
    }

    public var writeMegabytesPerSecond: Double? { NASSpeedTestMath.megabytesPerSecond(bytes: bytes, seconds: writeSeconds) }
    public var readMegabytesPerSecond: Double? { NASSpeedTestMath.megabytesPerSecond(bytes: bytes, seconds: readSeconds) }
    public var smallWriteMilliseconds: Double { smallWriteSeconds * 1000 }
    public var smallReadMilliseconds: Double { smallReadSeconds * 1000 }
}

public enum NASSpeedTestMath {
    /// Decimal megabytes per second (1 MB = 1,000,000 bytes, like Finder).
    public static func megabytesPerSecond(bytes: Int64, seconds: Double) -> Double? {
        guard bytes > 0, seconds > 0, seconds.isFinite else { return nil }
        return Double(bytes) / seconds / 1_000_000
    }

    /// "75 MB/s"; one decimal below 10.
    public static func rateLabel(_ megabytesPerSecond: Double) -> String {
        megabytesPerSecond < 10
            ? String(format: "%.1f MB/s", megabytesPerSecond)
            : "\(Int(megabytesPerSecond.rounded())) MB/s"
    }

    /// "4 ms"; one decimal below 10.
    public static func latencyLabel(milliseconds: Double) -> String {
        milliseconds < 10 ? String(format: "%.1f ms", milliseconds) : "\(Int(milliseconds.rounded())) ms"
    }

    /// "just now", "5 min ago", "2 h ago".
    public static func ageLabel(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }
}

/// Writes about 64 MB of random bytes to a hidden temp file on the NAS
/// root, reads it back, and deletes it; then the same for one small file.
/// Both files are named `.CameraToolkit-nettest-<UUID>` and nothing else is
/// ever created or removed.
public struct NASSpeedTester: Sendable {
    public static let fileNamePrefix = ".CameraToolkit-nettest-"

    public var chunkBytes: Int
    public var chunkCount: Int
    public var smallFileBytes: Int

    public init(chunkBytes: Int = 8 * 1024 * 1024, chunkCount: Int = 8, smallFileBytes: Int = 4096) {
        self.chunkBytes = chunkBytes
        self.chunkCount = chunkCount
        self.smallFileBytes = smallFileBytes
    }

    public var totalBytes: Int64 { Int64(chunkBytes) * Int64(chunkCount) }

    public static func fileName(for id: UUID = UUID()) -> String {
        fileNamePrefix + id.uuidString
    }

    /// Exactly `.CameraToolkit-nettest-` followed by a canonical uppercase
    /// UUID — nothing looser, so cleanup can never match a user's file.
    public static func isTestFileName(_ name: String) -> Bool {
        guard name.hasPrefix(fileNamePrefix) else { return false }
        let rest = name.dropFirst(fileNamePrefix.count)
        guard rest.count == 36, let id = UUID(uuidString: String(rest)) else { return false }
        return id.uuidString == rest
    }

    /// Removes test files a crash or a dropped share left at the top level
    /// of `root`: regular files whose name matches exactly. Returns the
    /// names removed. Never descends, never follows links.
    @discardableResult
    public static func removeStaleTestFiles(in root: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var removed: [String] = []
        for name in names where isTestFileName(name) {
            let path = root.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            if unlink(path) == 0 { removed.append(name) }
        }
        return removed
    }

    public func run(root: URL, now: @Sendable () -> Date = Date.init) throws -> NASSpeedTestResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolkitError.commandFailed("The NAS folder \(root.path) is not available.")
        }
        var chunk = [UInt8](repeating: 0, count: chunkBytes)
        chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }

        let large = root.appendingPathComponent(Self.fileName())
        defer { unlink(large.path) }
        let writeSeconds = try timeWrite(to: large.path) { fd in
            for index in 0..<chunkCount {
                // A different first word per chunk: no two chunks are equal.
                withUnsafeBytes(of: UInt64(index).bigEndian) { word in
                    for offset in 0..<min(8, chunk.count) { chunk[offset] = word[offset] }
                }
                try Self.writeAll(fd: fd, bytes: chunk)
            }
        }
        let readSeconds = try timeRead(from: large.path, expected: totalBytes)
        unlink(large.path)

        let small = root.appendingPathComponent(Self.fileName())
        defer { unlink(small.path) }
        let smallBytes = Array(chunk.prefix(max(1, min(smallFileBytes, chunk.count))))
        let smallWrite = try timeWrite(to: small.path) { fd in try Self.writeAll(fd: fd, bytes: smallBytes) }
        let smallRead = try timeRead(from: small.path, expected: Int64(smallBytes.count))

        return NASSpeedTestResult(
            bytes: totalBytes,
            writeSeconds: writeSeconds,
            readSeconds: readSeconds,
            smallWriteSeconds: smallWrite,
            smallReadSeconds: smallRead,
            finishedAt: now()
        )
    }

    private func timeWrite(to path: String, body: (Int32) throws -> Void) throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        // O_EXCL: a name collision fails instead of touching another file.
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.posixError("create", path) }
        do {
            try body(fd)
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw Self.posixError("close", path) }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private func timeRead(from path: String, expected: Int64) throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.posixError("open", path) }
        defer { close(fd) }
        // Bypass the client's cache so the bytes come back over the wire.
        _ = fcntl(fd, F_NOCACHE, 1)
        var buffer = [UInt8](repeating: 0, count: max(chunkBytes, 4096))
        var total: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.posixError("read", path)
            }
            if count == 0 { break }
            total += Int64(count)
        }
        guard total == expected else {
            throw ToolkitError.commandFailed("The NAS speed test read back \(total) of \(expected) bytes.")
        }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private static func writeAll(fd: Int32, bytes: [UInt8]) throws {
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write", "")
                }
                offset += written
            }
        }
    }

    private static func posixError(_ operation: String, _ path: String) -> Error {
        let reason = String(cString: strerror(errno))
        return ToolkitError.commandFailed("NAS speed test could not \(operation)\(path.isEmpty ? "" : " \((path as NSString).lastPathComponent)"): \(reason).")
    }
}
