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

/// Runs bounded sequential storage checks without loading the sample into RAM.
/// Camera/card sources use `benchmarkReadOnly`; writable destinations use a
/// unique temporary file that is flushed, read uncached, and removed.
public struct StorageBenchmarkService: @unchecked Sendable {
    public static let defaultSampleByteCount: Int64 = 512 * 1024 * 1024
    public static let temporaryFilePrefix = ".CameraToolkit-SpeedTest-"

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
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
        let measurement = try read(
            samples: samples,
            byteLimit: bytesToRead,
            progressOffset: 0,
            progressTotal: bytesToRead,
            phase: "Testing source read speed",
            progress: progress
        )
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
        try FileScanner(fileManager: fileManager).assertDirectory(directory)
        try requireFreeSpace(for: byteCount, at: directory)

        let temporaryURL = directory.appendingPathComponent(
            "\(Self.temporaryFilePrefix)\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var operationError: Error?
        var result: StorageBenchmarkResult?

        do {
            let writeMeasurement = try writeTemporaryFile(
                to: temporaryURL,
                byteCount: byteCount,
                progress: progress
            )
            let readMeasurement = try read(
                samples: [(url: temporaryURL, size: byteCount)],
                byteLimit: byteCount,
                progressOffset: byteCount,
                progressTotal: byteCount * 2,
                phase: "Testing destination read speed",
                progress: progress
            )
            result = StorageBenchmarkResult(
                read: readMeasurement,
                write: writeMeasurement,
                sampledFileCount: 1
            )
        } catch {
            operationError = error
        }

        do {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try fileManager.removeItem(at: temporaryURL)
            }
        } catch {
            throw ToolkitError.commandFailed(
                "The speed test stopped, but its temporary file could not be removed: \(temporaryURL.path). \(error.localizedDescription)"
            )
        }

        if let operationError {
            throw operationError
        }
        guard let result else {
            throw ToolkitError.commandFailed("The storage speed test did not produce a result.")
        }
        return result
    }

    private func sampleFiles(
        searchRoots: [URL],
        byteLimit: Int64
    ) throws -> [(url: URL, size: Int64)] {
        var samples: [(url: URL, size: Int64)] = []
        var discoveredBytes: Int64 = 0
        var seen: Set<String> = []

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
                if size > 0 {
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
                samples.append((fileURL, size))
                discoveredBytes += size
                if discoveredBytes >= byteLimit { break }
            }
            if discoveredBytes >= byteLimit { break }
        }
        return samples
    }

    private func writeTemporaryFile(
        to url: URL,
        byteCount: Int64,
        progress: FileOperationProgressHandler?
    ) throws -> StorageBenchmarkMeasurement {
        let descriptor = try openDescriptor(
            url,
            flags: O_CREAT | O_EXCL | O_WRONLY,
            permissions: S_IRUSR | S_IWUSR
        )
        defer { Darwin.close(descriptor) }
        guard Darwin.fcntl(descriptor, F_NOCACHE, 1) == 0 else {
            throw Self.posixError(operation: "disable the file cache for", url: url)
        }

        let chunkSize = Int(min(Int64(4 * 1024 * 1024), byteCount))
        var buffer = [UInt8](repeating: 0, count: max(chunkSize, 1))
        buffer.withUnsafeMutableBytes { rawBuffer in
            if let address = rawBuffer.baseAddress {
                arc4random_buf(address, rawBuffer.count)
            }
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        var processed: Int64 = 0
        var limiter = FileOperationProgressLimiter()
        while processed < byteCount {
            try Task.checkCancellation()
            let requested = Int(min(Int64(buffer.count), byteCount - processed))
            try buffer.withUnsafeBytes { rawBuffer in
                guard let address = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < requested {
                    let written = Darwin.write(
                        descriptor,
                        address.advanced(by: offset),
                        requested - offset
                    )
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else {
                        throw Self.posixError(operation: "write speed-test data to", url: url)
                    }
                    offset += written
                }
            }
            processed += Int64(requested)
            if limiter.shouldEmit(force: processed == byteCount) {
                let elapsed = max(ProcessInfo.processInfo.systemUptime - startedAt, 0.001)
                progress?(FileOperationProgress(
                    phase: "Testing destination write speed",
                    currentPath: url.deletingLastPathComponent().path,
                    processedBytes: processed,
                    totalBytes: byteCount * 2,
                    bytesPerSecond: Double(processed) / elapsed
                ))
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw Self.posixError(operation: "flush speed-test data on", url: url)
        }
        let duration = max(ProcessInfo.processInfo.systemUptime - startedAt, 0.001)
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
        progress: FileOperationProgressHandler?
    ) throws -> StorageBenchmarkMeasurement {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var totalRead: Int64 = 0
        var limiter = FileOperationProgressLimiter()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024 * 1024)

        for sample in samples where totalRead < byteLimit {
            try Task.checkCancellation()
            let descriptor = try openDescriptor(sample.url, flags: O_RDONLY | O_NOFOLLOW)
            guard Darwin.fcntl(descriptor, F_NOCACHE, 1) == 0 else {
                Darwin.close(descriptor)
                throw Self.posixError(operation: "disable the file cache for", url: sample.url)
            }
            do {
                while totalRead < byteLimit {
                    try Task.checkCancellation()
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
                    if limiter.shouldEmit(force: totalRead == byteLimit) {
                        let elapsed = max(ProcessInfo.processInfo.systemUptime - startedAt, 0.001)
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
        let duration = max(ProcessInfo.processInfo.systemUptime - startedAt, 0.001)
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

    private static func posixError(operation: String, url: URL) -> ToolkitError {
        let code = errno
        return .commandFailed(
            "Could not \(operation) \(url.path): \(String(cString: strerror(code))) (errno \(code))"
        )
    }
}
