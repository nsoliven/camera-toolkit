import Darwin
import Foundation

public struct StorageBenchmarkMeasurement: Equatable, Sendable {
    public var bytes: Int64
    public var duration: TimeInterval
    public var bytesPerSecond: Double

    public init(bytes: Int64, duration: TimeInterval, bytesPerSecond: Double) {
        self.bytes = bytes
        self.duration = duration
        self.bytesPerSecond = bytesPerSecond
    }
}

public struct StorageBenchmarkResult: Equatable, Sendable {
    public var read: StorageBenchmarkMeasurement
    public var write: StorageBenchmarkMeasurement?
    public var sampledFileCount: Int
    public var completedAt: Date

    public init(
        read: StorageBenchmarkMeasurement,
        write: StorageBenchmarkMeasurement? = nil,
        sampledFileCount: Int,
        completedAt: Date = Date()
    ) {
        self.read = read
        self.write = write
        self.sampledFileCount = sampledFileCount
        self.completedAt = completedAt
    }
}

/// The device end of a write test: one synchronous write+flush quantum per
/// call. The production sink writes through an `F_NOCACHE` descriptor and
/// fsyncs every chunk; tests substitute a fake to simulate device latency or
/// a stall without touching real storage.
public protocol SpeedTestDeviceSink: AnyObject, Sendable {
    /// Write the chunk and push it at the device (write + flush). Returns
    /// only once the device accepted the bytes — that wait is the measured
    /// time and the interval the watchdog bounds.
    func writeChunk(_ bytes: UnsafeRawBufferPointer) throws
    /// Release the descriptor. Never throws; must tolerate being called once
    /// after an aborted run.
    func close()
}

/// Runs bounded sequential storage checks without loading the sample into RAM.
/// Camera/card sources use `benchmarkReadOnly`; writable destinations use a
/// unique temporary file that is written in bounded, uncached chunks, flushed
/// after every chunk, read back, and removed.
///
/// Write and read work run on a private queue under a watchdog instead of on
/// the caller's thread: a bus-powered enclosure can park a `write` or `fsync`
/// call in ways Swift task cancellation cannot interrupt, so the caller polls
/// for progress and abandons the run — reporting a stopped drive rather than
/// hanging — when no chunk completes for `stallTimeout` seconds.
public struct StorageBenchmarkService: @unchecked Sendable {
    public static let defaultSampleByteCount: Int64 = 256 * 1024 * 1024
    public static let temporaryFilePrefix = ".CameraToolkit-SpeedTest-"
    /// One supervised write+flush quantum — small enough that a stall is
    /// detected quickly and no single flush has to push hundreds of MB.
    public static let writeChunkByteCount: Int64 = 8 * 1024 * 1024
    /// Abort a test that has not moved bytes to the device for this long.
    public static let defaultStallTimeout: TimeInterval = 15

    private let fileManager: FileManager
    private let sinkFactory: @Sendable (URL, Int64) throws -> any SpeedTestDeviceSink
    private let uptime: @Sendable () -> TimeInterval
    private let stallTimeout: TimeInterval
    private let supervisor: RunSupervisor

    /// `sinkFactory` and `uptime` are test seams — production callers use the
    /// defaults, which write real files and read the real clock.
    public init(
        fileManager: FileManager = .default,
        sinkFactory: (@Sendable (URL, Int64) throws -> any SpeedTestDeviceSink)? = nil,
        uptime: (@Sendable () -> TimeInterval)? = nil,
        stallTimeout: TimeInterval = StorageBenchmarkService.defaultStallTimeout
    ) {
        self.fileManager = fileManager
        self.sinkFactory = sinkFactory ?? { url, byteCount in
            try UncachedSpeedTestSink(
                url: url,
                byteCount: byteCount,
                gentle: Self.needsGentleWrites(in: url.deletingLastPathComponent())
            )
        }
        let uptime = uptime ?? { ProcessInfo.processInfo.systemUptime }
        self.uptime = uptime
        self.stallTimeout = stallTimeout
        self.supervisor = RunSupervisor(
            stallTimeout: stallTimeout,
            uptime: uptime,
            queueLabel: "CameraToolkit.StorageBenchmark.io",
            stalledError: { Self.stalledDriveError() },
            missingResultError: {
                ToolkitError.commandFailed("The storage speed test did not produce a result.")
            }
        )
    }

    public func benchmarkReadOnly(
        searchRoots: [URL],
        byteLimit: Int64 = Self.defaultSampleByteCount,
        progress: FileOperationProgressHandler? = nil
    ) throws -> StorageBenchmarkResult {
        guard byteLimit > 0 else {
            throw ToolkitError.commandFailed("The speed-test sample size must be greater than zero.")
        }

        progress?(FileOperationProgress(phase: "Finding existing media to read"))
        let samples = try sampleFiles(searchRoots: searchRoots, byteLimit: byteLimit)
        guard !samples.isEmpty else {
            throw ToolkitError.commandFailed(
                "No readable files were found. Camera sources stay read-only, so Camera Toolkit will not create a speed-test file there."
            )
        }

        let availableBytes = samples.reduce(Int64(0)) { $0 + $1.size }
        let bytesToRead = min(byteLimit, availableBytes)
        let measurement = try supervisor.run { monitor in
            try self.read(
                samples: samples,
                byteLimit: bytesToRead,
                progressOffset: 0,
                progressTotal: bytesToRead,
                phase: "Testing source read speed",
                monitor: monitor,
                progress: progress
            )
        }
        return StorageBenchmarkResult(
            read: measurement,
            sampledFileCount: samples.count
        )
    }

    public func benchmarkReadWrite(
        directory: URL,
        byteCount: Int64 = Self.defaultSampleByteCount,
        progress: FileOperationProgressHandler? = nil
    ) throws -> StorageBenchmarkResult {
        guard byteCount > 0 else {
            throw ToolkitError.commandFailed("The speed-test sample size must be greater than zero.")
        }

        let temporaryURL = directory.appendingPathComponent(
            "\(Self.temporaryFilePrefix)\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var operationError: Error?
        var result: StorageBenchmarkResult?

        do {
            // Preflight runs inside supervision too — on a dead mount even a
            // stat can block, and Stop must never hang.
            let writeMeasurement = try supervisor.run { monitor in
                try FileScanner(fileManager: self.fileManager).assertDirectory(directory)
                try self.requireFreeSpace(for: byteCount, at: directory)
                let sink = try self.sinkFactory(temporaryURL, byteCount)
                return try self.writeTemporaryFile(
                    sink: sink,
                    to: temporaryURL,
                    byteCount: byteCount,
                    monitor: monitor,
                    progress: progress
                )
            }
            let readMeasurement = try supervisor.run { monitor in
                try self.read(
                    samples: [(url: temporaryURL, size: byteCount)],
                    byteLimit: byteCount,
                    progressOffset: byteCount,
                    progressTotal: byteCount * 2,
                    phase: "Testing destination read speed",
                    monitor: monitor,
                    progress: progress
                )
            }
            result = StorageBenchmarkResult(
                read: readMeasurement,
                write: writeMeasurement,
                sampledFileCount: 1
            )
        } catch {
            operationError = error
        }

        // Cleanup is bounded for the same reason the I/O is supervised.
        if let cleanupError = removeTemporaryFile(at: temporaryURL) {
            throw cleanupError
        }
        if let operationError {
            throw operationError
        }
        guard let result else {
            throw ToolkitError.commandFailed("The storage speed test did not produce a result.")
        }
        return result
    }

    /// Deletes leftover `.CameraToolkit-SpeedTest-*.tmp` and
    /// `.CameraToolkit-Stability-*.tmp` files — and any `._` AppleDouble
    /// twins — sitting directly inside each folder. Only names with an
    /// exact known prefix are touched; everything else is left alone and
    /// folders that cannot be listed are skipped. Returns the removed
    /// paths. Called once per app launch so an interrupted test cannot
    /// litter.
    ///
    /// A twin is probed by name rather than awaited from the listing:
    /// `._*` entries are filtered out of directory enumeration on
    /// filesystems that present them synthetically, even though the file
    /// itself is real and would otherwise be left behind.
    @discardableResult
    public func removeStaleTemporaryFiles(in directories: [URL]) -> [URL] {
        var removed: [URL] = []
        for directory in directories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
                continue
            }
            for name in names where Self.isTemporaryFileName(name) {
                for candidate in [name, "._" + name] {
                    let url = directory.appendingPathComponent(candidate)
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                          !isDirectory.boolValue else {
                        continue
                    }
                    if (try? fileManager.removeItem(at: url)) != nil {
                        removed.append(url)
                    }
                }
            }
        }
        return removed
    }

    /// `.CameraToolkit-SpeedTest-*.tmp` / `.CameraToolkit-Stability-*.tmp`,
    /// or the `._` twin of such a name.
    private static func isTemporaryFileName(_ name: String) -> Bool {
        func isMatch(_ candidate: some StringProtocol) -> Bool {
            (candidate.hasPrefix(temporaryFilePrefix)
                || candidate.hasPrefix(StabilityTestService.temporaryFilePrefix))
                && candidate.hasSuffix(".tmp")
        }
        if isMatch(name) { return true }
        if name.hasPrefix("._") { return isMatch(name.dropFirst(2)) }
        return false
    }

    /// Removes the temp file and any `._` AppleDouble twin. Runs off-thread
    /// with a bound: on a dead mount even unlink can block, and an aborted
    /// test must report instead of hanging.
    private func removeTemporaryFile(at url: URL) -> Error? {
        let twin = url.deletingLastPathComponent()
            .appendingPathComponent("._\(url.lastPathComponent)", isDirectory: false)
        let monitor = RunLivenessMonitor<Void>(startedAt: uptime())
        DispatchQueue(label: "CameraToolkit.StorageBenchmark.cleanup", qos: .userInitiated).async {
            monitor.finish(Result(catching: {
                for candidate in [url, twin]
                where self.fileManager.fileExists(atPath: candidate.path) {
                    try self.fileManager.removeItem(at: candidate)
                }
            }))
        }
        guard monitor.waitFinished(timeout: stallTimeout), let outcome = monitor.result() else {
            return Self.stalledDriveError()
        }
        if case let .failure(error) = outcome {
            return ToolkitError.commandFailed(
                "The speed test stopped, but its temporary file could not be removed: \(url.path). \(error.localizedDescription)"
            )
        }
        return nil
    }

    /// Plain-words failure for a test that stopped moving bytes to the device.
    private static func stalledDriveError() -> ToolkitError {
        .commandFailed(
            "The drive stopped responding — no data reached it for a while, so the speed test was abandoned and its temporary file removed. This can mean an overheating or underpowered enclosure or cable, or a drive that dropped off the bus. Unplug it, let it settle, reconnect it, and try again."
        )
    }

    private func sampleFiles(
        searchRoots: [URL],
        byteLimit: Int64
    ) throws -> [(url: URL, size: Int64)] {
        var samples: [(url: URL, size: Int64)] = []
        var discoveredBytes: Int64 = 0
        var seen: Set<String> = []
        var seenFiles: Set<String> = []

        for root in searchRoots.map(\.standardizedFileURL) where seen.insert(root.path).inserted {
            try Task.checkCancellation()
            let values = try? root.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            if values?.isRegularFile == true, values?.isSymbolicLink != true {
                let size = Int64(values?.fileSize ?? 0)
                if size > 0, seenFiles.insert(root.path).inserted {
                    samples.append((root, size))
                    discoveredBytes += size
                }
                if discoveredBytes >= byteLimit { break }
                continue
            }
            guard values?.isDirectory == true,
                  let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: nil
                  ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                try Task.checkCancellation()
                if fileURL.lastPathComponent.hasPrefix(Self.temporaryFilePrefix) { continue }
                let fileValues = try? fileURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ])
                guard fileValues?.isRegularFile == true,
                      fileValues?.isSymbolicLink != true else {
                    continue
                }
                let size = Int64(fileValues?.fileSize ?? 0)
                guard size > 0 else { continue }
                guard seenFiles.insert(fileURL.standardizedFileURL.path).inserted else { continue }
                samples.append((fileURL, size))
                discoveredBytes += size
                if discoveredBytes >= byteLimit { break }
            }
            if discoveredBytes >= byteLimit { break }
        }
        return samples
    }

    /// Writes `byteCount` in bounded chunks, flushing after each one so the
    /// reported rate is the pace the device accepts data — never page-cache
    /// speed — and so no single flush has to push hundreds of MB. The final
    /// measurement includes the last flush. Runs on the supervised worker.
    private func writeTemporaryFile(
        sink: any SpeedTestDeviceSink,
        to url: URL,
        byteCount: Int64,
        monitor: RunLivenessMonitor<StorageBenchmarkMeasurement>,
        progress: FileOperationProgressHandler?
    ) throws -> StorageBenchmarkMeasurement {
        defer { sink.close() }

        let chunkSize = Int(min(Self.writeChunkByteCount, byteCount))
        var buffer = [UInt8](repeating: 0, count: max(chunkSize, 1))
        buffer.withUnsafeMutableBytes { rawBuffer in
            if let address = rawBuffer.baseAddress {
                arc4random_buf(address, rawBuffer.count)
            }
        }

        let startedAt = uptime()
        var processed: Int64 = 0
        var limiter = FileOperationProgressLimiter()
        while processed < byteCount {
            if monitor.shouldStop { throw CancellationError() }
            let requested = Int(min(Int64(buffer.count), byteCount - processed))
            try buffer.withUnsafeBytes { rawBuffer in
                try sink.writeChunk(UnsafeRawBufferPointer(rebasing: rawBuffer.prefix(requested)))
            }
            processed += Int64(requested)
            monitor.markChunkCompleted(at: uptime())
            if limiter.shouldEmit(force: processed == byteCount) {
                let elapsed = max(uptime() - startedAt, 0.001)
                progress?(FileOperationProgress(
                    phase: "Testing destination write speed",
                    currentPath: url.deletingLastPathComponent().path,
                    processedBytes: processed,
                    totalBytes: byteCount * 2,
                    bytesPerSecond: Double(processed) / elapsed
                ))
            }
        }
        let duration = max(uptime() - startedAt, 0.001)
        return StorageBenchmarkMeasurement(
            bytes: processed,
            duration: duration,
            bytesPerSecond: Double(processed) / duration
        )
    }

    private func read(
        samples: [(url: URL, size: Int64)],
        byteLimit: Int64,
        progressOffset: Int64,
        progressTotal: Int64,
        phase: String,
        monitor: RunLivenessMonitor<StorageBenchmarkMeasurement>,
        progress: FileOperationProgressHandler?
    ) throws -> StorageBenchmarkMeasurement {
        let startedAt = uptime()
        var totalRead: Int64 = 0
        var limiter = FileOperationProgressLimiter()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024 * 1024)

        for sample in samples where totalRead < byteLimit {
            if monitor.shouldStop { throw CancellationError() }
            let descriptor = try openDescriptor(sample.url, flags: O_RDONLY | O_NOFOLLOW)
            guard Darwin.fcntl(descriptor, F_NOCACHE, 1) == 0 else {
                Darwin.close(descriptor)
                throw Self.posixError(operation: "disable the file cache for", url: sample.url)
            }
            do {
                while totalRead < byteLimit {
                    if monitor.shouldStop { throw CancellationError() }
                    let requested = Int(min(Int64(buffer.count), byteLimit - totalRead))
                    let count = buffer.withUnsafeMutableBytes { rawBuffer in
                        Darwin.read(descriptor, rawBuffer.baseAddress, requested)
                    }
                    if count < 0, errno == EINTR { continue }
                    guard count >= 0 else {
                        throw Self.posixError(operation: "read speed-test data from", url: sample.url)
                    }
                    guard count > 0 else { break }
                    totalRead += Int64(count)
                    monitor.markChunkCompleted(at: uptime())
                    if limiter.shouldEmit(force: totalRead == byteLimit) {
                        let elapsed = max(uptime() - startedAt, 0.001)
                        progress?(FileOperationProgress(
                            phase: phase,
                            currentPath: sample.url.path,
                            processedBytes: progressOffset + totalRead,
                            totalBytes: progressTotal,
                            bytesPerSecond: Double(totalRead) / elapsed
                        ))
                    }
                }
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            Darwin.close(descriptor)
        }

        guard totalRead > 0 else {
            throw ToolkitError.commandFailed("The speed test could not read any sample bytes.")
        }
        let duration = max(uptime() - startedAt, 0.001)
        return StorageBenchmarkMeasurement(
            bytes: totalRead,
            duration: duration,
            bytesPerSecond: Double(totalRead) / duration
        )
    }

    private func requireFreeSpace(for byteCount: Int64, at directory: URL) throws {
        let attributes = try fileManager.attributesOfFileSystem(forPath: directory.path)
        let freeBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let safetyReserve: Int64 = 256 * 1024 * 1024
        guard freeBytes >= byteCount + safetyReserve else {
            throw ToolkitError.commandFailed(
                "Not enough free space for a temporary speed test. Keep at least \(byteCount + safetyReserve) bytes available."
            )
        }
    }

    private func openDescriptor(
        _ url: URL,
        flags: Int32,
        permissions: mode_t = 0
    ) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            if flags & O_CREAT != 0 {
                return Darwin.open(path, flags, permissions)
            }
            return Darwin.open(path, flags)
        }
        guard descriptor >= 0 else {
            throw Self.posixError(operation: "open", url: url)
        }
        return descriptor
    }

    static func posixError(operation: String, url: URL) -> ToolkitError {
        let code = errno
        return .commandFailed(
            "Could not \(operation) \(url.path): \(String(cString: strerror(code))) (errno \(code))"
        )
    }
}

extension StorageBenchmarkService {
    /// exFAT and FAT volumes get uncached writes with no preallocation and
    /// no `fsync`. On the owner's USB NVMe Buffer (exFAT through fskit) an
    /// `fsync` of the speed-test file knocked the enclosure off the bus
    /// twice, and `ftruncate` there zero-fills the whole file up front.
    static func needsGentleWrites(in directory: URL) -> Bool {
        var info = Darwin.statfs()
        guard directory.withUnsafeFileSystemRepresentation({ path in
            path.map { statfs($0, &info) == 0 } ?? false
        }) else { return false }
        let type = withUnsafeBytes(of: info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ["exfat", "msdos"].contains(type.lowercased())
    }
}

/// The production write sink: an `O_EXCL` temporary file opened uncached
/// (`F_NOCACHE`). Normally it is preallocated when the filesystem allows it
/// (`F_PREALLOCATE`, falling back to `ftruncate`, then to nothing) and each
/// `writeChunk` ends in `fsync`, so it returns only once the device accepted
/// the bytes. A `gentle` sink (exFAT/FAT) skips both and relies on the
/// uncached writes alone.
private final class UncachedSpeedTestSink: SpeedTestDeviceSink, @unchecked Sendable {
    private let url: URL
    private let gentle: Bool
    private var descriptor: Int32 = -1

    init(url: URL, byteCount: Int64, gentle: Bool = false) throws {
        self.url = url
        self.gentle = gentle
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw StorageBenchmarkService.posixError(operation: "open", url: url)
        }
        self.descriptor = descriptor
        guard Darwin.fcntl(descriptor, F_NOCACHE, 1) == 0 else {
            let error = StorageBenchmarkService.posixError(
                operation: "disable the file cache for", url: url
            )
            Darwin.close(descriptor)
            self.descriptor = -1
            throw error
        }
        if !gentle {
            preallocate(byteCount)
        }
    }

    /// Best-effort preallocation so the write loop measures streaming into
    /// real blocks instead of filesystem allocation. Unsupported on some
    /// filesystems (fskit exFAT) — every step ignores failure.
    private func preallocate(_ byteCount: Int64) {
        var store = fstore_t()
        store.fst_flags = UInt32(F_ALLOCATECONTIG) | UInt32(F_ALLOCATEALL)
        store.fst_posmode = F_PEOFPOSMODE
        store.fst_offset = 0
        store.fst_length = off_t(byteCount)
        store.fst_bytesalloc = 0
        _ = Darwin.fcntl(descriptor, F_PREALLOCATE, &store)
        _ = Darwin.ftruncate(descriptor, off_t(byteCount))
    }

    func writeChunk(_ bytes: UnsafeRawBufferPointer) throws {
        guard descriptor >= 0 else { return }
        if let address = bytes.baseAddress {
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, address.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw StorageBenchmarkService.posixError(
                        operation: "write speed-test data to", url: url
                    )
                }
                offset += written
            }
        }
        guard !gentle else { return }
        guard Darwin.fsync(descriptor) == 0 else {
            throw StorageBenchmarkService.posixError(
                operation: "flush speed-test data on", url: url
            )
        }
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}
