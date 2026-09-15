import Darwin
import Foundation

public struct VerifiedRemovalPair: Hashable, Sendable {
    /// The working-drive copy that will be moved aside.
    public var driveCopyPath: String
    /// The independent copy that must match byte for byte, usually on the NAS.
    public var referencePath: String
    /// Path inside the removal batch folder.
    public var batchRelativePath: String
    public var byteCount: Int64

    public init(driveCopyPath: String, referencePath: String, batchRelativePath: String, byteCount: Int64) {
        self.driveCopyPath = driveCopyPath
        self.referencePath = referencePath
        self.batchRelativePath = batchRelativePath
        self.byteCount = byteCount
    }
}

public struct VerifiedRemovalReport: Sendable {
    public var checked: [String] = []
    public var moved: [String] = []
    public var missingDriveCopy: [String] = []
    public var missingReference: [String] = []
    public var differ: [String] = []
    public var errors: [String: String] = [:]
    public var movedBytes: Int64 = 0
    public var batchPath: String?

    public init() {}

    public var isSafeToMoveAll: Bool {
        !checked.isEmpty && missingDriveCopy.isEmpty && missingReference.isEmpty && differ.isEmpty && errors.isEmpty
    }
}

/// Takes originals off the working drive only after every one has been
/// re-hashed against its archived copy. Validation completes for the whole
/// set before the first file moves, and files move into a recoverable
/// `_Trash` batch on the same drive rather than being deleted.
public struct VerifiedRemovalService {
    public static let confirmationToken = "REMOVE"

    private struct Identity: Equatable {
        var size: Int64
        var modified: Date?
        var fileNumber: UInt64?
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func moveVerifiedCopiesAside(
        pairs: [VerifiedRemovalPair],
        trashRoot: URL,
        confirmation: String,
        pruneBoundaries: [URL] = [],
        progress: FileOperationProgressHandler? = nil
    ) throws -> VerifiedRemovalReport {
        guard confirmation == Self.confirmationToken else {
            throw ToolkitError.confirmationRequired(expected: Self.confirmationToken, received: confirmation)
        }
        guard trashRoot.standardizedFileURL.pathComponents.contains("_Trash") else {
            throw ToolkitError.trashPathRequired(trashRoot.path)
        }
        guard !pairs.isEmpty else {
            throw ToolkitError.commandFailed("There are no drive copies to take off the drive.")
        }

        var report = VerifiedRemovalReport()
        let totalBytes = pairs.reduce(Int64(0)) { $0 + max($1.byteCount, 0) * 2 }
        var processedBytes: Int64 = 0
        let startedAt = Date()
        var validated: [(pair: VerifiedRemovalPair, identity: Identity)] = []

        for (index, pair) in pairs.enumerated() {
            try PathSafety.validateRelativePath(pair.batchRelativePath)
            guard fileManager.fileExists(atPath: pair.driveCopyPath) else {
                report.missingDriveCopy.append(pair.driveCopyPath)
                continue
            }
            guard fileManager.fileExists(atPath: pair.referencePath) else {
                report.missingReference.append(pair.driveCopyPath)
                continue
            }
            do {
                let driveURL = URL(fileURLWithPath: pair.driveCopyPath)
                let referenceURL = URL(fileURLWithPath: pair.referencePath)
                let driveBefore = try identity(driveURL)
                let referenceBefore = try identity(referenceURL)
                guard driveBefore.size == referenceBefore.size else {
                    report.differ.append(pair.driveCopyPath)
                    continue
                }
                let driveHash = try FileScanner.sha256(driveURL) { count in
                    processedBytes += Int64(count)
                }
                progress?(FileOperationProgress(
                    phase: "Rechecking drive copy",
                    currentPath: driveURL.lastPathComponent,
                    processedFiles: index,
                    totalFiles: pairs.count,
                    processedBytes: processedBytes,
                    totalBytes: totalBytes,
                    bytesPerSecond: Double(processedBytes) / max(Date().timeIntervalSince(startedAt), 0.001)
                ))
                let referenceHash = try FileScanner.sha256(referenceURL) { count in
                    processedBytes += Int64(count)
                }
                progress?(FileOperationProgress(
                    phase: "Rechecking archived copy",
                    currentPath: driveURL.lastPathComponent,
                    processedFiles: index + 1,
                    totalFiles: pairs.count,
                    processedBytes: processedBytes,
                    totalBytes: totalBytes,
                    bytesPerSecond: Double(processedBytes) / max(Date().timeIntervalSince(startedAt), 0.001)
                ))
                let driveAfter = try identity(driveURL)
                let referenceAfter = try identity(referenceURL)
                guard driveBefore == driveAfter, referenceBefore == referenceAfter else {
                    report.errors[pair.driveCopyPath] = "The file changed during verification."
                    continue
                }
                guard driveHash == referenceHash else {
                    report.differ.append(pair.driveCopyPath)
                    continue
                }
                report.checked.append(pair.driveCopyPath)
                validated.append((pair, driveAfter))
            } catch {
                report.errors[pair.driveCopyPath] = error.localizedDescription
            }
        }

        guard validated.count == pairs.count, report.isSafeToMoveAll else {
            return report
        }

        let batch = trashRoot.appendingPathComponent(Self.batchName(Date()), isDirectory: true)
        try fileManager.createDirectory(at: batch, withIntermediateDirectories: true)
        report.batchPath = batch.path

        for item in validated {
            let source = URL(fileURLWithPath: item.pair.driveCopyPath)
            guard try identity(source) == item.identity else {
                report.errors[item.pair.driveCopyPath] = "The drive copy changed after verification."
                return report
            }
            guard VolumeInfo.deviceNumber(for: source) == VolumeInfo.deviceNumber(for: batch) else {
                throw ToolkitError.crossVolumeQuarantine(source.path, batch.path)
            }
        }

        var folders: Set<String> = []
        for (index, item) in validated.enumerated() {
            let destination = batch.appendingPathComponent(item.pair.batchRelativePath)
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try DriveMoveService.renameExclusive(from: item.pair.driveCopyPath, to: destination.path)
                DriveMoveService.moveAppleDoubleIfNeeded(from: item.pair.driveCopyPath, to: destination.path)
                report.moved.append(item.pair.driveCopyPath)
                report.movedBytes += item.pair.byteCount
                folders.insert((item.pair.driveCopyPath as NSString).deletingLastPathComponent)
            } catch {
                report.errors[item.pair.driveCopyPath] = error.localizedDescription
                break
            }
            progress?(FileOperationProgress(
                phase: "Taking off the drive",
                currentPath: destination.lastPathComponent,
                processedFiles: index + 1,
                totalFiles: validated.count,
                processedBytes: report.movedBytes,
                totalBytes: validated.reduce(Int64(0)) { $0 + $1.pair.byteCount }
            ))
        }
        DriveMoveService(fileManager: fileManager).pruneEmptyFolders(folders, boundaries: pruneBoundaries)
        return report
    }

    private func identity(_ url: URL) throws -> Identity {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return Identity(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: attributes[.modificationDate] as? Date,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private static func batchName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }
}
