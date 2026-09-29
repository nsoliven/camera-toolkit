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

    /// Test seam: what `copyNew` calls to close its output. Nil calls
    /// `Darwin.close`. A test uses it to make a close fail the way smbfs
    /// does — the descriptor is gone and `errno` says why.
    nonisolated(unsafe) static var closePrimitive: ((Int32) -> Int32)?

    /// A failure a dropped or re-established SMB session can cause and a
    /// fresh attempt does not repeat: `EBADF`, `ENOTCONN`, `EIO`, `ESTALE`,
    /// `ETIMEDOUT`, `ECONNRESET` while writing, flushing or closing the
    /// destination — or a descriptor that stopped being the one this copy
    /// opened. The temporary is removed by path and the file tried once
    /// more from a fresh open; the retry is verified like any other copy.
    public struct TransientIOError: LocalizedError, Equatable, Sendable {
        public var operation: String
        public var path: String
        public var code: Int32
        public var detail: String?

        public var errorDescription: String? {
            let base = "Could not \(operation) \(path): \(String(cString: strerror(code)))"
            return detail.map { "\(base) (\($0))" } ?? base
        }
    }

    public static func isTransient(_ code: Int32) -> Bool {
        [EBADF, ENOTCONN, EIO, ESTALE, ETIMEDOUT, ECONNRESET].contains(code)
    }

    /// The error for a failed operation on the destination: transient when
    /// the SMB session may have caused it, else a plain failure.
    static func failure(_ code: Int32, _ operation: String, _ path: String) -> Error {
        isTransient(code)
            ? TransientIOError(operation: operation, path: path, code: code)
            : DirectoryListing.posix(code, operation, path)
    }

    /// The path the kernel reports for an open descriptor (`F_GETPATH`);
    /// nil when the descriptor is not open or the filesystem cannot say.
    static func path(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Whether a descriptor a copy opened still is that file: compared with
    /// the path the kernel gave right after the open, so symlinks and
    /// `/private` aliases never matter.
    struct DescriptorOwnership {
        let descriptor: Int32
        let expectedPath: String?
        let label: String

        init(_ descriptor: Int32, label: String) {
            self.descriptor = descriptor
            self.expectedPath = NASFileIO.path(of: descriptor)
            self.label = label
        }

        /// Nil while the descriptor is still ours (or the filesystem cannot
        /// say, so nothing is claimed); else why it is not.
        func loss() -> String? {
            guard let expectedPath else { return nil }
            let now = NASFileIO.path(of: descriptor)
            if now == expectedPath { return nil }
            if now == nil {
                return errno == EBADF ? "descriptor \(descriptor) (\(label)) is not open" : nil
            }
            return "descriptor \(descriptor) (\(label)) now names another file"
        }
    }

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

    /// How `copyNew` treats caches and durability. `.fast` is what Sync to
    /// NAS uses; `.legacy` is the engine before it (kept for benchmarks and
    /// as a switch of last resort).
    public struct CopyOptions: Sendable, Equatable {
        /// `F_FULLFSYNC` + `fsync` on every file before it is closed. Over
        /// SMB each becomes an SMB2 FLUSH, which a ZFS server answers with
        /// a ZIL commit — on a pool without a SLOG, a synchronous write to
        /// the data disks per file.
        public var flushEachFile: Bool
        /// `F_NOCACHE` on the destination. On smbfs this turns off
        /// write-behind, so every chunk is a synchronous round trip.
        public var uncachedWrite: Bool
        /// `F_NOCACHE` on the source (the drive). Off in `.fast`: in the
        /// benchmark (150 files, 4 transfers, 3 runs each) it made no
        /// measurable difference either way, and the NAS, not the drive,
        /// is the bottleneck.
        public var uncachedSourceRead: Bool

        public init(flushEachFile: Bool, uncachedWrite: Bool, uncachedSourceRead: Bool) {
            self.flushEachFile = flushEachFile
            self.uncachedWrite = uncachedWrite
            self.uncachedSourceRead = uncachedSourceRead
        }

        public static let fast = CopyOptions(flushEachFile: false, uncachedWrite: false, uncachedSourceRead: false)
        public static let legacy = CopyOptions(flushEachFile: true, uncachedWrite: true, uncachedSourceRead: true)
    }

    public struct CopyResult: Sendable, Equatable {
        /// SHA-256 of the bytes read from the source (and written).
        public var sha256: String
        /// Seconds spent reading and writing.
        public var copySeconds: Double
        /// Seconds spent in `F_FULLFSYNC`/`fsync` (zero without a flush).
        public var flushSeconds: Double
    }

    /// Test seam: told about every cache or durability call `copyNew`
    /// issues — "F_NOCACHE source", "F_NOCACHE destination", "F_FULLFSYNC",
    /// "fsync" — so a test can prove the sync copy path issues no flush.
    nonisolated(unsafe) static var copyCallObserver: (@Sendable (String) -> Void)?

    /// Streams `source` into a new file at `destination` (created
    /// exclusively — never an existing file), hashing the bytes as they
    /// pass. Returns the source's SHA-256. A short read throws.
    ///
    /// With `.fast` options the bytes are *not* flushed to stable storage
    /// here: the NAS commits them with its next transaction group (ZFS: at
    /// most ~5 s later). A power loss on the NAS inside that window can
    /// lose the file, which is safe because nothing is recorded as
    /// verified until its SHA-256 has been checked after the write, the
    /// temporary name only becomes the real name after that check, and a
    /// drive copy is never removed without a verified NAS copy (Take Off
    /// Drive re-hashes the NAS copy again). The SSH verifier also asks the
    /// NAS to commit (`sync`) once per batch before it hashes.
    ///
    /// `willFlush` runs once every byte is written, just before the flush —
    /// only when `options.flushEachFile` asks for one — so a caller can
    /// time and show the flush on its own.
    public static func copyNew(
        from source: String,
        to destination: String,
        expectedByteCount: Int64,
        options: CopyOptions = .fast,
        clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        progress: (Int) -> Void = { _ in },
        willFlush: () -> Void = {}
    ) throws -> CopyResult {
        let observer = copyCallObserver
        let started = clock()
        let input = try open(source, O_RDONLY)
        // A descriptor that stopped being ours is never closed: closing its
        // number would close somebody else's file.
        var ownsInput = true
        defer { if ownsInput { Darwin.close(input) } }
        let inputOwnership = DescriptorOwnership(input, label: "drive copy")
        if options.uncachedSourceRead {
            observer?("F_NOCACHE source")
            _ = fcntl(input, F_NOCACHE, 1)
        }
        let output = try open(destination, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        var ownsOutput = true
        defer { if ownsOutput { Darwin.close(output) } }
        let outputOwnership = DescriptorOwnership(output, label: "NAS temporary")
        /// Throws, touching neither descriptor, when one of them is no
        /// longer the file this copy opened. Checked before every chunk, so
        /// a descriptor lost mid-copy stops the writes at the next chunk.
        func requireOwnership() throws {
            if let lost = inputOwnership.loss() {
                ownsInput = false
                observer?("descriptor lost: \(lost)")
                throw TransientIOError(operation: "read", path: source, code: EBADF, detail: lost)
            }
            if let lost = outputOwnership.loss() {
                ownsOutput = false
                observer?("descriptor lost: \(lost)")
                throw TransientIOError(operation: "write", path: destination, code: EBADF, detail: lost)
            }
        }
        if options.uncachedWrite {
            observer?("F_NOCACHE destination")
            _ = fcntl(output, F_NOCACHE, 1)
        }
        var hasher = SHA256()
        var total: Int64 = 0
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            try requireOwnership()
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
                    let code = errno
                    if code == EINTR { continue }
                    throw failure(code, "write", destination)
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
        try requireOwnership()
        let copied = clock()
        var flushed = copied
        if options.flushEachFile {
            willFlush()
            // F_FULLFSYNC where the filesystem has it (SMB may not); fsync
            // always, so the share has the bytes before the rename names them.
            observer?("F_FULLFSYNC")
            _ = fcntl(output, F_FULLFSYNC)
            observer?("fsync")
            guard Darwin.fsync(output) == 0 else { throw failure(errno, "flush", destination) }
            flushed = clock()
        }
        try requireOwnership()
        // close() still reports a failed write-behind on smbfs. The
        // descriptor is gone whatever it answers, so it is never closed twice.
        ownsOutput = false
        let closeResult = closePrimitive?(output) ?? Darwin.close(output)
        guard closeResult == 0 else { throw failure(errno, "close", destination) }
        let end = clock()
        return CopyResult(
            sha256: hex(hasher.finalize()),
            copySeconds: (copied - started) + (end - flushed),
            flushSeconds: flushed - copied
        )
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
