import CryptoKit
import Darwin
import Foundation

/// Streaming reads, writes and renames for NAS work. Every byte goes through
/// one bounded buffer; reads of NAS files ask for `F_NOCACHE` so a
/// verification re-read comes from the share, not this Mac's unified buffer
/// cache. (A NAS's own RAM cache — ZFS ARC — cannot be bypassed from a
/// client; a server-side re-read is the most a client can ask for.)
public enum NASFileIO {
    public static let chunkSize = 4 * 1024 * 1024

    /// Test seam for the exclusive rename: nil calls `renamex_np`.
    nonisolated(unsafe) static var renameExclusivePrimitive: ((String, String) -> Int32)?
    /// Test seam: corrupts or fails a verification read. Receives the path;
    /// returning a hash replaces the real one.
    nonisolated(unsafe) static var verificationHashOverride: ((String) -> String?)?

    static func open(_ path: String, _ flags: Int32, _ mode: mode_t = 0) throws -> Int32 {
        let descriptor = Darwin.open(path, flags | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw DirectoryListing.posix(errno, "open", path) }
        return descriptor
    }

    /// SHA-256 of a file, read with `F_NOCACHE` when `uncached`.
    public static func sha256(
        _ path: String,
        uncached: Bool,
        expectedByteCount: Int64? = nil,
        progress: (Int) -> Void = { _ in }
    ) throws -> String {
        if let override = verificationHashOverride, uncached, let replaced = override(path) { return replaced }
        let descriptor = try open(path, O_RDONLY)
        defer { Darwin.close(descriptor) }
        if uncached { _ = fcntl(descriptor, F_NOCACHE, 1) }
        var hasher = SHA256()
        var total: Int64 = 0
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = Darwin.read(descriptor, buffer, chunkSize)
            if count < 0 {
                if errno == EINTR { continue }
                throw DirectoryListing.posix(errno, "read", path)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            total += Int64(count)
            progress(count)
        }
        if let expectedByteCount, total != expectedByteCount {
            throw ToolkitError.commandFailed("Short read of \(path): \(total) of \(expectedByteCount) bytes.")
        }
        return hex(hasher.finalize())
    }

    /// Streams `source` into a new file at `destination` (created
    /// exclusively — never an existing file), hashing the bytes as they
    /// pass, then flushes it to stable storage. Returns the source's
    /// SHA-256. A short read throws. `willFlush` runs once every byte is
    /// written, just before the flush to stable storage — so a caller can
    /// time the flush separately from the copy.
    public static func copyNew(
        from source: String,
        to destination: String,
        expectedByteCount: Int64,
        progress: (Int) -> Void = { _ in },
        willFlush: () -> Void = {}
    ) throws -> String {
        let input = try open(source, O_RDONLY)
        defer { Darwin.close(input) }
        _ = fcntl(input, F_NOCACHE, 1)
        let output = try open(destination, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        var closed = false
        defer { if !closed { Darwin.close(output) } }
        _ = fcntl(output, F_NOCACHE, 1)
        var hasher = SHA256()
        var total: Int64 = 0
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = Darwin.read(input, buffer, chunkSize)
            if count < 0 {
                if errno == EINTR { continue }
                throw DirectoryListing.posix(errno, "read", source)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            var written = 0
            while written < count {
                let result = Darwin.write(output, buffer.advanced(by: written), count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw DirectoryListing.posix(errno, "write", destination)
                }
                written += result
            }
            total += Int64(count)
            progress(count)
        }
        guard total == expectedByteCount else {
            throw ToolkitError.commandFailed(
                "Copy stopped early for \((source as NSString).lastPathComponent): \(total) of \(expectedByteCount) bytes. The drive may have disconnected."
            )
        }
        willFlush()
        // F_FULLFSYNC where the filesystem has it (SMB may not); fsync
        // always, so the share has the bytes before the rename names them.
        _ = fcntl(output, F_FULLFSYNC)
        guard Darwin.fsync(output) == 0 else { throw DirectoryListing.posix(errno, "flush", destination) }
        closed = true
        guard Darwin.close(output) == 0 else { throw DirectoryListing.posix(errno, "close", destination) }
        return hex(hasher.finalize())
    }

    /// Renames without ever replacing an existing file: `renamex_np` with
    /// `RENAME_EXCL`, and where the filesystem does not support that (SMB
    /// often answers `ENOTSUP`), a check that the destination is free, then
    /// a plain rename. The check-then-rename window is the best an SMB
    /// client can do; callers hold the destination folder alone (the app
    /// quit, one job at a time).
    public static func renameExclusive(from source: String, to destination: String) throws {
        let result = renameExclusivePrimitive.map { $0(source, destination) }
            ?? renamex_np(source, destination, UInt32(RENAME_EXCL))
        if result == 0 { return }
        let code = errno
        switch code {
        case ENOTSUP, EINVAL:
            var info = stat()
            guard lstat(destination, &info) != 0 else {
                throw ToolkitError.commandFailed("A file already exists at \(destination). Nothing was replaced.")
            }
            guard Darwin.rename(source, destination) == 0 else {
                throw DirectoryListing.posix(errno, "rename", source)
            }
        case EEXIST:
            throw ToolkitError.commandFailed("A file already exists at \(destination). Nothing was replaced.")
        default:
            throw DirectoryListing.posix(code, "rename", source)
        }
    }

    /// `mkdir -p`; returns the folders it created, outermost first.
    @discardableResult
    public static func makeDirectories(_ path: String) throws -> [String] {
        var missing: [String] = []
        var current = path
        var info = stat()
        while lstat(current, &info) != 0 {
            missing.append(current)
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw ToolkitError.commandFailed("\(current) is not a folder; cannot create \(path).")
        }
        var made: [String] = []
        for directory in missing.reversed() {
            guard mkdir(directory, 0o755) == 0 || errno == EEXIST else {
                throw DirectoryListing.posix(errno, "create", directory)
            }
            made.append(directory)
        }
        return made
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
