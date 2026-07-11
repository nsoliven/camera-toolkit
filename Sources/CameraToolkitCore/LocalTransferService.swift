import Foundation

public struct LocalCopyResult: Codable, Equatable, Sendable {
    public var copied: [String]
    public var skippedIdentical: [String]
    public var conflicts: [String]

    public init(copied: [String] = [], skippedIdentical: [String] = [], conflicts: [String] = []) {
        self.copied = copied
        self.skippedIdentical = skippedIdentical
        self.conflicts = conflicts
    }
}

public struct LocalTransferService {
    private let scanner: FileScanner
    private let fileManager: FileManager

    public init(scanner: FileScanner = FileScanner(), fileManager: FileManager = .default) {
        self.scanner = scanner
        self.fileManager = fileManager
    }

    public func copyImmutable(
        source: URL,
        destination: URL,
        excludes: [String] = DefaultExcludes.all,
        progress: FileOperationProgressHandler? = nil
    ) throws -> LocalCopyResult {
        let sourceFiles = try scanner.scan(root: source, excludes: excludes, hashing: true) { update in
            progress?(update.withPhase("Hashing source"))
        }
        return try copyFiles(source: source, destination: destination, files: sourceFiles, progress: progress)
    }

    public func copyFiles(
        source: URL,
        destination: URL,
        files: [FileRecord],
        progress: FileOperationProgressHandler? = nil
    ) throws -> LocalCopyResult {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var result = LocalCopyResult()
        let sourceFiles = files.sorted { $0.path < $1.path }
        let totalFiles = sourceFiles.count
        let totalBytes = sourceFiles.reduce(Int64(0)) { $0 + $1.size }
        let startedAt = Date()
        var processedFiles = 0
        var processedBytes: Int64 = 0
        var progressLimiter = FileOperationProgressLimiter()

        for sourceFile in sourceFiles {
            try PathSafety.validateRelativePath(sourceFile.path)
            let sourceURL = source.appendingPathComponent(sourceFile.path)
            let destinationURL = destination.appendingPathComponent(sourceFile.path)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw ToolkitError.pathNotFound(sourceURL.path)
            }
            let sourceHash: String
            if let existingHash = sourceFile.sha256 {
                sourceHash = existingHash
            } else {
                sourceHash = try FileScanner.sha256(sourceURL)
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                let destinationHash = try FileScanner.sha256(destinationURL)
                if destinationHash == sourceHash {
                    result.skippedIdentical.append(sourceFile.path)
                } else {
                    result.conflicts.append(sourceFile.path)
                }
                processedFiles += 1
                processedBytes += sourceFile.size
                if progressLimiter.shouldEmit(force: processedFiles == totalFiles) {
                    progress?(
                        FileOperationProgress(
                        phase: "Comparing existing file",
                        currentPath: sourceFile.path,
                        processedFiles: processedFiles,
                        totalFiles: totalFiles,
                        processedBytes: processedBytes,
                        totalBytes: totalBytes,
                        bytesPerSecond: Self.rate(bytes: processedBytes, since: startedAt)
                        )
                    )
                }
                continue
            }

            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try copyFile(from: sourceURL, to: destinationURL) { copiedChunk in
                processedBytes += Int64(copiedChunk)
                if progressLimiter.shouldEmit() {
                    progress?(
                        FileOperationProgress(
                        phase: "Copying",
                        currentPath: sourceFile.path,
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
            result.copied.append(sourceFile.path)
            if progressLimiter.shouldEmit(force: processedFiles == totalFiles) {
                progress?(
                    FileOperationProgress(
                    phase: "Copying",
                    currentPath: sourceFile.path,
                    processedFiles: processedFiles,
                    totalFiles: totalFiles,
                    processedBytes: processedBytes,
                    totalBytes: totalBytes,
                    bytesPerSecond: Self.rate(bytes: processedBytes, since: startedAt)
                    )
                )
            }
        }

        result.copied.sort()
        result.skippedIdentical.sort()
        result.conflicts.sort()
        return result
    }

    private func copyFile(from source: URL, to destination: URL, progress: (Int) -> Void) throws {
        let temporaryURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).cttmp-\(UUID().uuidString)")
        try? fileManager.removeItem(at: temporaryURL)

        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw ToolkitError.commandFailed("Could not create temporary copy file at \(temporaryURL.path)")
        }
        do {
            try StreamingFileIO.copyBytes(from: source, to: temporaryURL, progress: progress)
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func rate(bytes: Int64, since date: Date) -> Double {
        let elapsed = max(Date().timeIntervalSince(date), 0.001)
        return Double(bytes) / elapsed
    }
}
