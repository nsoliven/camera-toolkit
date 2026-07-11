import CryptoKit
import Foundation

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

        for file in files {
            let digest = try Self.sha256(file.url) { chunkBytes in
                processedBytes += Int64(chunkBytes)
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
            processedFiles += 1
            records.append(FileRecord(path: file.path, size: file.size, modifiedAt: file.modifiedAt, sha256: digest))
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
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
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
