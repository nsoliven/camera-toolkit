import Foundation

public struct SourceCleanupReport: Equatable, Sendable {
    public var checked: [String] = []
    public var removed: [String] = []
    public var missingSource: [String] = []
    public var missingBuffer: [String] = []
    public var differ: [String] = []
    public var errors: [String: String] = [:]
    public var removedBytes: Int64 = 0

    public init() {}

    public var isSafeToRemoveAll: Bool {
        !checked.isEmpty
            && missingSource.isEmpty
            && missingBuffer.isEmpty
            && differ.isEmpty
            && errors.isEmpty
    }
}

/// Permanently removes an explicit set of camera files only after every one is
/// re-hashed against its Buffer copy. Validation completes for the whole set
/// before the first source file is removed.
public struct SourceCleanupService {
    public static let confirmationToken = "REMOVE"

    private struct FileIdentity: Equatable {
        var size: Int64
        var modificationDate: Date?
        var systemFileNumber: UInt64?
    }

    private struct ValidatedFile {
        var relativePath: String
        var size: Int64
        var sourceURL: URL
        var sourceIdentity: FileIdentity
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func removeVerifiedFiles(
        sourceRoot: URL,
        bufferRoot: URL,
        files: [FileRecord],
        confirmation: String,
        progress: FileOperationProgressHandler? = nil
    ) throws -> SourceCleanupReport {
        guard confirmation == Self.confirmationToken else {
            throw ToolkitError.confirmationRequired(
                expected: Self.confirmationToken,
                received: confirmation
            )
        }

        try FileScanner(fileManager: fileManager).assertDirectory(sourceRoot)
        try FileScanner(fileManager: fileManager).assertDirectory(bufferRoot)
        guard sourceRoot.standardizedFileURL != bufferRoot.standardizedFileURL else {
            throw ToolkitError.commandFailed("Camera source and Buffer must be different folders.")
        }

        var uniqueFiles: [String: FileRecord] = [:]
        for file in files {
            try PathSafety.validateRelativePath(file.path)
            uniqueFiles[file.path] = file
        }
        let selected = uniqueFiles.values.sorted { $0.path < $1.path }
        guard !selected.isEmpty else {
            throw ToolkitError.commandFailed("There are no verified camera files to remove.")
        }

        let totalBytes = selected.reduce(Int64(0)) { partial, file in
            partial + max(file.size, 0) * 2
        }
        let startedAt = Date()
        var processedBytes: Int64 = 0
        var validated: [ValidatedFile] = []
        var report = SourceCleanupReport()

        for (index, file) in selected.enumerated() {
            let sourceURL = sourceRoot.appendingPathComponent(file.path)
            let bufferURL = bufferRoot.appendingPathComponent(file.path)

            guard fileManager.fileExists(atPath: sourceURL.path) else {
                report.missingSource.append(file.path)
                continue
            }
            guard fileManager.fileExists(atPath: bufferURL.path) else {
                report.missingBuffer.append(file.path)
                continue
            }

            do {
                let sourceBefore = try identity(of: sourceURL)
                let bufferBefore = try identity(of: bufferURL)
                guard sourceBefore.size == file.size, bufferBefore.size == file.size else {
                    report.differ.append(file.path)
                    continue
                }

                let sourceHash = try FileScanner.sha256(sourceURL) { chunkBytes in
                    processedBytes += Int64(chunkBytes)
                    progress?(FileOperationProgress(
                        phase: "Rechecking camera file",
                        currentPath: file.path,
                        processedFiles: index,
                        totalFiles: selected.count,
                        processedBytes: processedBytes,
                        totalBytes: totalBytes,
                        bytesPerSecond: Self.rate(bytes: processedBytes, since: startedAt)
                    ))
                }
                let bufferHash = try FileScanner.sha256(bufferURL) { chunkBytes in
                    processedBytes += Int64(chunkBytes)
                    progress?(FileOperationProgress(
                        phase: "Rechecking Buffer copy",
                        currentPath: file.path,
                        processedFiles: index,
                        totalFiles: selected.count,
                        processedBytes: processedBytes,
                        totalBytes: totalBytes,
                        bytesPerSecond: Self.rate(bytes: processedBytes, since: startedAt)
                    ))
                }

                let sourceAfter = try identity(of: sourceURL)
                let bufferAfter = try identity(of: bufferURL)
                guard sourceBefore == sourceAfter, bufferBefore == bufferAfter else {
                    report.errors[file.path] = "The camera file or Buffer copy changed during verification."
                    continue
                }
                guard sourceHash == bufferHash else {
                    report.differ.append(file.path)
                    continue
                }

                report.checked.append(file.path)
                validated.append(ValidatedFile(
                    relativePath: file.path,
                    size: file.size,
                    sourceURL: sourceURL,
                    sourceIdentity: sourceAfter
                ))
                progress?(FileOperationProgress(
                    phase: "Ready to remove from camera",
                    currentPath: file.path,
                    processedFiles: index + 1,
                    totalFiles: selected.count,
                    processedBytes: processedBytes,
                    totalBytes: totalBytes,
                    bytesPerSecond: Self.rate(bytes: processedBytes, since: startedAt)
                ))
            } catch {
                report.errors[file.path] = error.localizedDescription
            }
        }

        report.checked.sort()
        report.missingSource.sort()
        report.missingBuffer.sort()
        report.differ.sort()

        // Never partially remove a set that failed validation.
        guard validated.count == selected.count, report.isSafeToRemoveAll else {
            return report
        }

        // Recheck every source identity as one final preflight before removing
        // the first file, which keeps validation failures all-or-nothing.
        for file in validated {
            guard try identity(of: file.sourceURL) == file.sourceIdentity else {
                report.errors[file.relativePath] = "The camera file changed after verification."
                return report
            }
        }

        for file in validated {
            do {
                try fileManager.removeItem(at: file.sourceURL)
                report.removed.append(file.relativePath)
                report.removedBytes += file.size
            } catch {
                report.errors[file.relativePath] = error.localizedDescription
                break
            }
        }
        report.removed.sort()
        return report
    }

    private func identity(of url: URL) throws -> FileIdentity {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return FileIdentity(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date,
            systemFileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private static func rate(bytes: Int64, since date: Date) -> Double {
        let elapsed = max(Date().timeIntervalSince(date), 0.001)
        return Double(bytes) / elapsed
    }
}
