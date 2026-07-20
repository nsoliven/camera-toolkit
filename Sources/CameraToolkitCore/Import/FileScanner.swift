import CryptoKit
import Darwin
import Foundation

struct FileOperationProgressLimiter {
    private var lastEmission = 0.0
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 0.1) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldEmit(force: Bool = false) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastEmission >= minimumInterval else { return false }
        lastEmission = now
        return true
    }
}

enum StreamingFileIO {
    static func readChunks(
        from url: URL,
        chunkSize: Int = 1024 * 1024,
        _ body: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        let descriptor = try openDescriptor(url, flags: O_RDONLY)
        defer { Darwin.close(descriptor) }

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw posixError(operation: "read", url: url)
            }
            guard count > 0 else { return }
            try buffer.withUnsafeBytes { rawBuffer in
                try body(UnsafeRawBufferPointer(start: rawBuffer.baseAddress, count: count))
            }
        }
    }

    static func copyBytes(
        from source: URL,
        to destination: URL,
        chunkSize: Int = 4 * 1024 * 1024,
        expectedByteCount: Int64? = nil,
        progress: (Int) -> Void
    ) throws {
        let input = try openDescriptor(source, flags: O_RDONLY)
        defer { Darwin.close(input) }
        let output = try openDescriptor(destination, flags: O_WRONLY | O_TRUNC)
        defer { Darwin.close(output) }

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var totalCopied: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(input, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw posixError(operation: "read", url: source)
            }
            guard count > 0 else {
                if let expectedByteCount, totalCopied != expectedByteCount {
                    throw ToolkitError.commandFailed(
                        "Copy stopped early for \(source.lastPathComponent): expected \(expectedByteCount) bytes but received \(totalCopied). The source drive may have disconnected."
                    )
                }
                guard Darwin.fsync(output) == 0 else {
                    throw posixError(operation: "finish writing", url: destination)
                }
                return
            }

            try buffer.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < count {
                    let written = Darwin.write(output, baseAddress.advanced(by: offset), count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else {
                        throw posixError(operation: "write", url: destination)
                    }
                    offset += written
                }
            }
            totalCopied += Int64(count)
            progress(count)
        }
    }

    private static func openDescriptor(_ url: URL, flags: Int32) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, flags)
        }
        guard descriptor >= 0 else {
            throw posixError(operation: "open", url: url)
        }
        return descriptor
    }

    private static func posixError(operation: String, url: URL) -> ToolkitError {
        let code = errno
        let message = String(cString: strerror(code))
        return .commandFailed("Could not \(operation) \(url.path): \(message) (errno \(code))")
    }
}

public struct FileOperationProgress: Sendable {
    public var phase: String
    public var currentPath: String?
    public var processedFiles: Int
    public var totalFiles: Int
    public var processedBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double

    public init(
        phase: String,
        currentPath: String? = nil,
        processedFiles: Int = 0,
        totalFiles: Int = 0,
        processedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        bytesPerSecond: Double = 0
    ) {
        self.phase = phase
        self.currentPath = currentPath
        self.processedFiles = processedFiles
        self.totalFiles = totalFiles
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fractionComplete: Double {
        guard totalBytes > 0 else {
            guard totalFiles > 0 else { return 0 }
            return Double(processedFiles) / Double(totalFiles)
        }
        return min(max(Double(processedBytes) / Double(totalBytes), 0), 1)
    }

    public func withPhase(_ phase: String) -> FileOperationProgress {
        FileOperationProgress(
            phase: phase,
            currentPath: currentPath,
            processedFiles: processedFiles,
            totalFiles: totalFiles,
            processedBytes: processedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: bytesPerSecond
        )
    }
}

public typealias FileOperationProgressHandler = @Sendable (FileOperationProgress) -> Void

public struct FileScanner {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(
        root: URL,
        excludes: [String] = DefaultExcludes.all,
        hashing: Bool = false,
        progress: FileOperationProgressHandler? = nil
    ) throws -> [FileRecord] {
        try assertDirectory(root)

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [],
            errorHandler: nil
        ) else {
            return []
        }

        struct PendingFile {
            var url: URL
            var path: String
            var size: Int64
            var modifiedAt: Date
        }

        let discoveryStartedAt = Date()
        var files: [PendingFile] = []
        var discoveredBytes: Int64 = 0

        for case let url as URL in enumerator {
            let relativePath = Self.relativePath(for: url, under: root)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])

            if values.isDirectory == true {
                if ExclusionMatcher.isExcluded(relativePath, excludes: excludes) ||
                    ExclusionMatcher.isExcluded(relativePath + "/**", excludes: excludes) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true else {
                continue
            }

            if ExclusionMatcher.isExcluded(relativePath, excludes: excludes) {
                continue
            }

            let size = Int64(values.fileSize ?? 0)
            let modifiedAt = values.contentModificationDate ?? .distantPast
            files.append(PendingFile(url: url, path: relativePath, size: size, modifiedAt: modifiedAt))
            discoveredBytes += size

            if files.count == 1 || files.count.isMultiple(of: 25) {
                progress?(
                    FileOperationProgress(
                        phase: "Discovering files",
                        currentPath: relativePath,
                        processedFiles: files.count,
                        processedBytes: discoveredBytes,
                        bytesPerSecond: Self.rate(bytes: discoveredBytes, since: discoveryStartedAt)
                    )
                )
            }
        }

        files.sort { $0.path < $1.path }
        let totalFiles = files.count
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }

        guard hashing else {
            progress?(
                FileOperationProgress(
                    phase: "Scanned metadata",
                    processedFiles: totalFiles,
                    totalFiles: totalFiles,
                    processedBytes: totalBytes,
                    totalBytes: totalBytes
                )
            )
            return files.map {
                FileRecord(path: $0.path, size: $0.size, modifiedAt: $0.modifiedAt)
            }
        }

        let startedAt = Date()
        var records: [FileRecord] = []
        var processedFiles = 0
        var processedBytes: Int64 = 0
        var progressLimiter = FileOperationProgressLimiter()

        for file in files {
            let digest = try Self.sha256(file.url) { chunkBytes in
                processedBytes += Int64(chunkBytes)
                if progressLimiter.shouldEmit() {
                    progress?(
                    FileOperationProgress(
                        phase: "Hashing",
                        currentPath: file.path,
                        processedFiles: processedFiles,
                        totalFiles: totalFiles,
                        processedBytes: processedBytes,
                        totalBytes: totalBytes,
                        bytesPerSecond: Self.rate(bytes: processedBytes, since: startedAt)
                    )
                    )
                }
            }
            processedFiles += 1
            records.append(FileRecord(path: file.path, size: file.size, modifiedAt: file.modifiedAt, sha256: digest))
            if progressLimiter.shouldEmit(force: processedFiles == totalFiles) {
                progress?(
                FileOperationProgress(
                    phase: "Hashing",
                    currentPath: file.path,
                    processedFiles: processedFiles,
                    totalFiles: totalFiles,
                    processedBytes: processedBytes,
                    totalBytes: totalBytes,
                    bytesPerSecond: Self.rate(bytes: processedBytes, since: startedAt)
                )
                )
            }
        }

        return records.sorted { $0.path < $1.path }
    }

    public func assertDirectory(_ url: URL) throws {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ToolkitError.pathNotFound(url.path)
        }
        guard isDirectory.boolValue else {
            throw ToolkitError.notDirectory(url.path)
        }
    }

    public static func sha256(_ url: URL, progress: ((Int) -> Void)? = nil) throws -> String {
        var hasher = SHA256()
        try StreamingFileIO.readChunks(from: url) { chunk in
            hasher.update(bufferPointer: chunk)
            progress?(chunk.count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func relativePath(for url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        var relative = String(filePath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative.replacingOccurrences(of: "\\", with: "/")
    }

    private static func rate(bytes: Int64, since date: Date) -> Double {
        let elapsed = max(Date().timeIntervalSince(date), 0.001)
        return Double(bytes) / elapsed
    }
}
