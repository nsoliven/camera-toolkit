import Foundation

public struct ArchivePlanner {
    private let scanner: FileScanner
    private let fileManager: FileManager

    public init(scanner: FileScanner = FileScanner(), fileManager: FileManager = .default) {
        self.scanner = scanner
        self.fileManager = fileManager
    }

    public func planCopy(
        source: URL,
        destination: URL,
        excludes: [String] = DefaultExcludes.all,
        progress: FileOperationProgressHandler? = nil
    ) throws -> CopyPlan {
        let sourceFiles = try scanner.scan(root: source, excludes: excludes, hashing: true) { update in
            progress?(update.withPhase("Hashing source"))
        }
        let destinationFiles: [FileRecord]

        if FileManager.default.fileExists(atPath: destination.path) {
            destinationFiles = try scanner.scan(root: destination, excludes: excludes, hashing: true) { update in
                progress?(update.withPhase("Hashing destination"))
            }
        } else {
            destinationFiles = []
            progress?(
                FileOperationProgress(
                    phase: "Destination missing",
                    processedFiles: sourceFiles.count,
                    totalFiles: sourceFiles.count,
                    processedBytes: sourceFiles.reduce(0) { $0 + $1.size },
                    totalBytes: sourceFiles.reduce(0) { $0 + $1.size }
                )
            )
        }

        let destinationByPath = Dictionary(uniqueKeysWithValues: destinationFiles.map { ($0.path, $0) })
        var plan = CopyPlan()

        for file in sourceFiles {
            guard let existing = destinationByPath[file.path] else {
                plan.new.append(file)
                continue
            }

            if existing.sha256 == file.sha256 {
                plan.existing.append(file)
            } else {
                plan.conflicts.append(file)
            }
        }

        return plan
    }

    /// Plans only an explicitly selected set of source files.
    ///
    /// This is the event-import fast path: it preserves checksum verification
    /// without hashing unrelated photos from the rest of a multi-event card.
    public func planCopy(
        source: URL,
        destination: URL,
        files: [FileRecord],
        progress: FileOperationProgressHandler? = nil
    ) throws -> CopyPlan {
        var plan = CopyPlan()
        let selected = files.sorted { $0.path < $1.path }
        let totalBytes = selected.reduce(Int64(0)) { $0 + ($1.size * 2) }
        var processedBytes: Int64 = 0
        let startedAt = Date()
        var progressLimiter = FileOperationProgressLimiter()

        for (index, file) in selected.enumerated() {
            try PathSafety.validateRelativePath(file.path)
            let sourceURL = source.appendingPathComponent(file.path)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw ToolkitError.pathNotFound(sourceURL.path)
            }

            let sourceHash: String
            if let existingHash = file.sha256 {
                sourceHash = existingHash
                processedBytes += file.size
            } else {
                sourceHash = try FileScanner.sha256(sourceURL) { chunkBytes in
                    processedBytes += Int64(chunkBytes)
                    if progressLimiter.shouldEmit() {
                        progress?(FileOperationProgress(
                            phase: "Verifying camera file",
                            currentPath: file.path,
                            processedFiles: index,
                            totalFiles: selected.count,
                            processedBytes: processedBytes,
                            totalBytes: totalBytes,
                            bytesPerSecond: Self.rate(bytes: processedBytes, since: startedAt)
                        ))
                    }
                }
            }
            let record = FileRecord(
                path: file.path,
                size: file.size,
                modifiedAt: file.modifiedAt,
                sha256: sourceHash
            )
            let destinationURL = destination.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let destinationHash = try FileScanner.sha256(destinationURL) { chunkBytes in
                    processedBytes += Int64(chunkBytes)
                    if progressLimiter.shouldEmit() {
                        progress?(FileOperationProgress(
                            phase: "Verifying buffer file",
                            currentPath: file.path,
                            processedFiles: index,
                            totalFiles: selected.count,
                            processedBytes: processedBytes,
                            totalBytes: totalBytes,
                            bytesPerSecond: Self.rate(bytes: processedBytes, since: startedAt)
                        ))
                    }
                }
                if destinationHash == sourceHash {
                    plan.existing.append(record)
                } else {
                    plan.conflicts.append(record)
                }
            } else {
                processedBytes += file.size
                plan.new.append(record)
            }

            progress?(
                FileOperationProgress(
                    phase: "Verifying selected files",
                    currentPath: file.path,
                    processedFiles: index + 1,
                    totalFiles: selected.count,
                    processedBytes: processedBytes,
                    totalBytes: totalBytes,
                    bytesPerSecond: Self.rate(bytes: processedBytes, since: startedAt)
                )
            )
        }

        return plan
    }

    private static func rate(bytes: Int64, since date: Date) -> Double {
        let elapsed = max(Date().timeIntervalSince(date), 0.001)
        return Double(bytes) / elapsed
    }

    /// Quickly previews an explicitly selected import using file metadata only.
    ///
    /// Matching paths and sizes are reported as present but remain unverified
    /// (`sha256 == nil`). The copy operation performs the real checksum pass.
    public func planCopyMetadata(
        source: URL,
        destination: URL,
        files: [FileRecord],
        progress: FileOperationProgressHandler? = nil
    ) throws -> CopyPlan {
        var plan = CopyPlan()
        let selected = files.sorted { $0.path < $1.path }
        let totalBytes = selected.reduce(Int64(0)) { $0 + $1.size }
        var processedBytes: Int64 = 0

        for (index, file) in selected.enumerated() {
            try PathSafety.validateRelativePath(file.path)
            let sourceURL = source.appendingPathComponent(file.path)
            let sourceValues = try sourceURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            )
            guard sourceValues.isRegularFile == true else {
                throw ToolkitError.pathNotFound(sourceURL.path)
            }

            let sourceSize = Int64(sourceValues.fileSize ?? Int(file.size))
            let record = FileRecord(
                path: file.path,
                size: sourceSize,
                modifiedAt: sourceValues.contentModificationDate ?? file.modifiedAt
            )
            let destinationURL = destination.appendingPathComponent(file.path)
            if fileManager.fileExists(atPath: destinationURL.path) {
                let destinationValues = try destinationURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if destinationValues.isRegularFile == true,
                   Int64(destinationValues.fileSize ?? -1) == sourceSize {
                    plan.existing.append(record)
                } else {
                    plan.conflicts.append(record)
                }
            } else {
                plan.new.append(record)
            }

            processedBytes += sourceSize
            progress?(
                FileOperationProgress(
                    phase: "Reading file metadata",
                    currentPath: file.path,
                    processedFiles: index + 1,
                    totalFiles: selected.count,
                    processedBytes: processedBytes,
                    totalBytes: totalBytes
                )
            )
        }

        return plan
    }
}

public struct LocalCheckService {
    private let scanner: FileScanner

    public init(scanner: FileScanner = FileScanner()) {
        self.scanner = scanner
    }

    public func check(
        source: URL,
        destination: URL,
        excludes: [String] = DefaultExcludes.all,
        progress: FileOperationProgressHandler? = nil
    ) throws -> CheckReport {
        let sourceFiles = try scanner.scan(root: source, excludes: excludes, hashing: true) { update in
            progress?(update.withPhase("Checking source"))
        }
        let destinationFiles: [FileRecord]
        if FileManager.default.fileExists(atPath: destination.path) {
            destinationFiles = try scanner.scan(root: destination, excludes: excludes, hashing: true) { update in
                progress?(update.withPhase("Checking destination"))
            }
        } else {
            destinationFiles = []
        }

        let sourceByPath = Dictionary(uniqueKeysWithValues: sourceFiles.map { ($0.path, $0) })
        let destinationByPath = Dictionary(uniqueKeysWithValues: destinationFiles.map { ($0.path, $0) })
        var report = CheckReport()

        for sourceFile in sourceFiles {
            guard let destinationFile = destinationByPath[sourceFile.path] else {
                report.sourceOnly.append(sourceFile.path)
                continue
            }

            if sourceFile.sha256 == destinationFile.sha256 {
                report.match.append(sourceFile.path)
            } else {
                report.differ.append(sourceFile.path)
            }
        }

        for destinationFile in destinationFiles where sourceByPath[destinationFile.path] == nil {
            report.destinationOnly.append(destinationFile.path)
        }

        report.match.sort()
        report.sourceOnly.sort()
        report.destinationOnly.sort()
        report.differ.sort()
        return report
    }
}
