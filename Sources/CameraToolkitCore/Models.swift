import Foundation

public enum ToolkitError: Error, Equatable, LocalizedError {
    case pathNotFound(String)
    case notDirectory(String)
    case unsafeRelativePath(String)
    case trashPathRequired(String)
    case crossVolumeQuarantine(String, String)
    case confirmationRequired(expected: String, received: String)
    case rcloneSubcommandNotAllowed(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .pathNotFound(let path):
            "Path not found: \(path)"
        case .notDirectory(let path):
            "Expected a directory: \(path)"
        case .unsafeRelativePath(let path):
            "Unsafe relative path: \(path)"
        case .trashPathRequired(let path):
            "Trash root must contain a _Trash component: \(path)"
        case .crossVolumeQuarantine(let a, let b):
            "Refusing to move files aside across volumes: \(a) and \(b)"
        case .confirmationRequired(let expected, let received):
            "Expected confirmation \(expected), received \(received)"
        case .rcloneSubcommandNotAllowed(let subcommand):
            "rclone subcommand is not allowed: \(subcommand)"
        case .commandFailed(let message):
            message
        }
    }
}

public enum TransferLocation: String, Codable, CaseIterable, Sendable {
    case card
    case drive
    case nas
    case mac
    case immich
}

public struct DeviceProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var archiveFolder: String
    public var cardVolumeHints: [String]
    public var cardMarkers: [String]

    public init(
        id: String,
        label: String,
        archiveFolder: String,
        cardVolumeHints: [String] = [],
        cardMarkers: [String] = []
    ) {
        self.id = id
        self.label = label
        self.archiveFolder = archiveFolder
        self.cardVolumeHints = cardVolumeHints
        self.cardMarkers = cardMarkers
    }
}

public struct FileRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var size: Int64
    public var modifiedAt: Date
    public var sha256: String?

    public init(path: String, size: Int64, modifiedAt: Date, sha256: String? = nil) {
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
    }
}

public struct CopyPlan: Codable, Equatable, Sendable {
    public var new: [FileRecord]
    public var existing: [FileRecord]
    public var conflicts: [FileRecord]

    public init(new: [FileRecord] = [], existing: [FileRecord] = [], conflicts: [FileRecord] = []) {
        self.new = new
        self.existing = existing
        self.conflicts = conflicts
    }

    public var newBytes: Int64 {
        new.reduce(0) { $0 + $1.size }
    }

    public var isEmpty: Bool {
        new.isEmpty && conflicts.isEmpty
    }
}

public struct CheckReport: Codable, Equatable, Sendable {
    public var match: [String]
    public var sourceOnly: [String]
    public var destinationOnly: [String]
    public var differ: [String]
    public var errors: [String]

    public init(
        match: [String] = [],
        sourceOnly: [String] = [],
        destinationOnly: [String] = [],
        differ: [String] = [],
        errors: [String] = []
    ) {
        self.match = match
        self.sourceOnly = sourceOnly
        self.destinationOnly = destinationOnly
        self.differ = differ
        self.errors = errors
    }

    public var ok: Bool {
        sourceOnly.isEmpty && differ.isEmpty && errors.isEmpty
    }
}

public struct FreeUpReport: Codable, Equatable, Sendable {
    public var scannedAt: Date
    public var safe: [String]
    public var notOnArchive: [String]
    public var differ: [String]
    public var errors: [String]
    public var moved: [String]
    public var moveFailures: [String: String]
    public var freedBytes: Int64
    public var trashBatch: String?
    public var junkRemoved: Int

    public init(
        scannedAt: Date = Date(),
        safe: [String] = [],
        notOnArchive: [String] = [],
        differ: [String] = [],
        errors: [String] = [],
        moved: [String] = [],
        moveFailures: [String: String] = [:],
        freedBytes: Int64 = 0,
        trashBatch: String? = nil,
        junkRemoved: Int = 0
    ) {
        self.scannedAt = scannedAt
        self.safe = safe
        self.notOnArchive = notOnArchive
        self.differ = differ
        self.errors = errors
        self.moved = moved
        self.moveFailures = moveFailures
        self.freedBytes = freedBytes
        self.trashBatch = trashBatch
        self.junkRemoved = junkRemoved
    }
}

public enum JobState: String, Codable, Sendable {
    case queued
    case running
    case done
    case failed
    case cancelled
}

public enum JobAction: String, Codable, CaseIterable, Sendable {
    case previewFiles
    case prepareTestData
    case ingestCard
    case syncBuffer
    case freeUp
    case checkout
    case checkinExports
    case immichScan
    case verifyManifest
    case diskSpeed
    case networkSpeed
}

public struct JobSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var action: JobAction
    public var state: JobState
    public var progress: Double
    public var note: String
    public var detail: String
    public var command: String
    public var sourcePath: String?
    public var destinationPath: String?
    public var currentPath: String?
    public var processedFiles: Int
    public var totalFiles: Int
    public var processedBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double
    public var createdAt: Date
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        action: JobAction,
        state: JobState = .queued,
        progress: Double = 0,
        note: String = "",
        detail: String = "",
        command: String = "",
        sourcePath: String? = nil,
        destinationPath: String? = nil,
        currentPath: String? = nil,
        processedFiles: Int = 0,
        totalFiles: Int = 0,
        processedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        bytesPerSecond: Double = 0,
        createdAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.action = action
        self.state = state
        self.progress = progress
        self.note = note
        self.detail = detail
        self.command = command
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.currentPath = currentPath
        self.processedFiles = processedFiles
        self.totalFiles = totalFiles
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }
}

public struct DiskSpeedReport: Codable, Equatable, Sendable {
    public var path: String
    public var bytes: Int64
    public var writeBytesPerSecond: Double
    public var readBytesPerSecond: Double

    public init(path: String, bytes: Int64, writeBytesPerSecond: Double, readBytesPerSecond: Double) {
        self.path = path
        self.bytes = bytes
        self.writeBytesPerSecond = writeBytesPerSecond
        self.readBytesPerSecond = readBytesPerSecond
    }
}
