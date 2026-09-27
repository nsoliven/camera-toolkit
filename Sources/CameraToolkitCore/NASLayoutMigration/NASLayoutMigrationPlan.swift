import Foundation

/// Everything a NAS layout migration would do, computed read-only from a
/// reviewed `NASLayoutMapping` and serializable for review. Executed exactly
/// as reviewed: the executor re-lists every source event folder and refuses
/// when a listing digest differs.
///
/// Identity over SMB is size + modification time (+ an optional sampled
/// SHA-256): file ids are not stable on a network share.
public struct NASLayoutMigrationPlan: Codable, Equatable, Sendable {
    public static let formatName = "camera-toolkit-nas-layout-migration-plan"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var id: UUID
    public var createdAt: Date
    public var supportFolderPath: String
    public var configurationPath: String
    /// Nil when there was no catalog to plan against.
    public var catalogPath: String?
    public var legacyRoot: String
    public var mirrorRoot: String
    public var mappingDigest: String
    /// The reviewed mapping with both roots filled in, so the executor can
    /// re-plan it and prove nothing changed.
    public var mapping: NASLayoutMapping
    public var events: [Event]
    public var conflicts: [Conflict]
    /// Camera folders whose name the table does not know; kept verbatim.
    public var unknownCameras: [UnknownCamera]
    public var leftInPlace: [LeftInPlace]
    /// Folders that could not be listed — their files are not planned, and
    /// the rest of the event migrates without them.
    public var unreadable: [Issue]
    public var refused: [Issue]
    public var blockers: [String]
    /// Things the reviewer should know that do not block the plan.
    public var notes: [String]
    public var catalog: CatalogChanges
    public var fingerprint: Fingerprint
    public var summary: Summary
    /// Per-file mode: every source folder the moves may empty (absolute,
    /// deepest first), removed with `rmdir` once the catalog is committed.
    public var sourceDirectories: [String]?
    /// Per-file mode: what the reviewed CSV asked for.
    public var fileMapping: FileMappingSummary?

    public var isExecutable: Bool { blockers.isEmpty }
    public var allMoves: [Move] { events.flatMap(\.moves) }

    public enum FileKind: String, Codable, Equatable, Sendable {
        case media
        case sidecar
        /// `._NAME` twin; follows its file.
        case appleDouble
        case other
    }

    public struct Move: Codable, Equatable, Hashable, Sendable {
        public var source: String
        public var destination: String
        public var byteCount: Int64
        /// `timeIntervalSinceReferenceDate`.
        public var modifiedAt: Double
        public var kind: FileKind
        /// The destination name carries a `(N)` suffix.
        public var renamed: Bool
        /// For `.appleDouble` twins: the index of their file's move.
        public var companionOf: Int?
    }

    public struct CameraFolder: Codable, Equatable, Sendable {
        public var sourceFolder: String
        public var camera: String
        public var known: Bool
        public var files: Int
    }

    public struct Event: Codable, Equatable, Sendable {
        /// `E0001`, …
        public var id: String
        public var source: String
        public var destination: String
        public var sourcePath: String
        public var destinationPath: String
        public var cameras: [CameraFolder]
        public var moves: [Move]
        /// Source directories (absolute), deepest first — removed with
        /// `rmdir` once emptied; recreated by undo.
        public var sourceDirectories: [String]
        /// Subfolders under a camera folder that are not a media folder,
        /// kept under `Originals/<Camera>/`.
        public var keptSubfolders: [String]
        /// Files placed in the subfolder the catalog event's assignments
        /// name (`eventID` in the mapping), sidecars that followed included.
        public var knownSubfolderFiles: Int
        /// Legacy names two assignments claim; those files stay flat.
        public var ambiguousKnownNames: Int
        public var byteCount: Int64
    }

    public struct Conflict: Codable, Equatable, Sendable {
        public enum Reason: String, Codable, Equatable, Sendable {
            /// A file already sits at the destination.
            case destinationExists
            /// Another planned file takes the destination (two legacy
            /// folders flatten or normalize into one).
            case claimedByAnotherFile
            /// Held with a file of the same base name that collided.
            case travelsWithConflict
        }
        public var source: String
        public var plannedDestination: String
        public var resolvedDestination: String
        public var reason: Reason
        public var existingByteCount: Int64?
    }

    public struct UnknownCamera: Codable, Equatable, Sendable {
        public var path: String
        public var name: String
    }

    public struct LeftInPlace: Codable, Equatable, Sendable {
        public var path: String
        public var reason: String
    }

    public struct Issue: Codable, Equatable, Sendable {
        public var path: String
        public var reason: String
    }

    public struct FacePhotoRewrite: Codable, Equatable, Sendable {
        public var oldPathKey: String
        public var newPathKey: String
        public var newPath: String
        public var newFileName: String
        public var confirmedFaceCount: Int
    }

    public struct SyncRecordRewrite: Codable, Equatable, Sendable {
        public var nasRoot: String
        public var oldPathKey: String
        public var newRelativePath: String
    }

    /// A catalog event renamed in the catalog transaction.
    public struct EventRenameChange: Codable, Equatable, Sendable {
        public enum DriveFolderState: String, Codable, Equatable, Sendable {
            /// No drive folder under the old name: nothing to rename there.
            case absent
            /// A Buffer or private-staging folder has the old name — it must
            /// be renamed with the event (a blocker until it is).
            case present
            /// The drive is not mounted; it could not be checked.
            case offline
        }

        public var eventID: UUID
        public var oldName: String
        public var newName: String
        /// Mirror-root-relative `<year>/<yyyy-MM-dd> <name>`, before and after.
        public var oldMirrorFolder: String
        public var newMirrorFolder: String
        /// The event's drive folder (Buffer or private staging), before and after.
        public var oldDriveFolder: String
        public var newDriveFolder: String
        public var driveFolderState: DriveFolderState
        /// Assignments whose source root lies inside the old drive folder
        /// (adopted drive copies). Reported; their rows are not rewritten.
        public var assignmentsUnderOldDriveFolder: Int
    }

    /// A catalog event whose NAS folder the file mapping fills: its
    /// assignments decide the subfolder under `Originals/<Camera>/` each of
    /// its files lands in, so presence finds them where the app looks.
    public struct AttachedEvent: Codable, Equatable, Sendable {
        public var eventID: UUID
        public var name: String
        public var mirrorFolder: String
        public var assignments: Int
        /// Assignments with exactly one file of that name and size in the event's folder.
        public var matched: Int
        /// Matched files already at the app's path.
        public var alreadyAligned: Int
        /// Matched files moved to the app's path instead of the CSV's.
        public var aligned: Int
        /// Same-name sidecars that followed an aligned file.
        public var followers: Int
        /// Matched files kept at the CSV's path because the app's path
        /// holds a character SMB cannot store portably.
        public var keptNonPortable: Int
        public var unmatched: Int
    }

    public struct FileMappingSummary: Codable, Equatable, Sendable {
        public var digest: String
        public var rows: Int
        public var moves: Int
        /// AppleDouble twins moved that the CSV did not list.
        public var unlistedTwins: Int
        public var stays: Int
        /// Files the CSV sends somewhere other than the app's path, moved to
        /// the app's path for a catalog event (see `catalog.attachedEvents`).
        public var alignedToCatalog: Int
    }

    public struct CatalogChanges: Codable, Equatable, Sendable {
        public var facePhotoRewrites: [FacePhotoRewrite]
        public var orientationCopies: [LayoutMigrationPlan.OrientationCopy]
        public var burstSplitRewrites: [LayoutMigrationPlan.BurstSplitRewrite]
        public var syncRecordRewrites: [SyncRecordRewrite]
        public var tableCounts: [String: Int]
        public var confirmedFaces: Int
        public var markerKey: String
        /// Assignments whose source file is a moved NAS file (their id
        /// changes; presence and Immich rows follow).
        public var assignmentRewrites: [LayoutMigrationPlan.AssignmentRewrite]?
        public var eventRenames: [EventRenameChange]?
        public var attachedEvents: [AttachedEvent]?

        public var isEmpty: Bool {
            facePhotoRewrites.isEmpty && orientationCopies.isEmpty && burstSplitRewrites.isEmpty && syncRecordRewrites.isEmpty
                && (assignmentRewrites ?? []).isEmpty && (eventRenames ?? []).isEmpty
        }
    }

    public struct Fingerprint: Codable, Equatable, Sendable {
        /// SHA-256 of each source event folder's recursive listing (relative
        /// path, kind, size, modification time).
        public var folderListings: [String: String]
        public var catalogDigest: String?
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var events: Int
        public var files: Int
        public var byteCount: Int64
        public var appleDoubleFiles: Int
        public var conflicts: Int
        public var renamedFiles: Int
        public var unknownCameras: Int
        public var keptSubfolders: Int
        public var knownSubfolderFiles: Int
        public var leftInPlace: Int
        public var unreadable: Int
        public var refused: Int
        public var facePhotoRewrites: Int
        public var syncRecordRewrites: Int
        public var foldersListed: Int
    }
}

extension NASLayoutMigrationPlan {
    public func jsonData() throws -> Data {
        try LayoutMigrationPlan.encoder().encode(self)
    }

    public func digest() throws -> String {
        LayoutMigrationHash.sha256(try jsonData())
    }

    public static func read(_ url: URL) throws -> NASLayoutMigrationPlan {
        let plan = try LayoutMigrationPlan.decoder().decode(NASLayoutMigrationPlan.self, from: Data(contentsOf: url))
        guard plan.format == formatName else {
            throw ToolkitError.commandFailed("\(url.lastPathComponent) is not a NAS layout migration plan.")
        }
        guard plan.version == currentVersion else {
            throw ToolkitError.commandFailed("The plan is version \(plan.version); this build reads version \(currentVersion). Make a new plan.")
        }
        return plan
    }

    public func summaryText(detail: Bool = true) -> String {
        let s = summary
        func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
        var lines: [String] = []
        lines.append("NAS layout migration plan \(id.uuidString)")
        lines.append("  legacy root: \(legacyRoot)")
        lines.append("  mirror root: \(mirrorRoot)")
        lines.append("Renames: \(s.files) files, \(bytes(s.byteCount)) across \(s.events) event folders (\(s.appleDoubleFiles) AppleDouble twins); \(s.foldersListed) folders listed")
        lines.append("Conflicts: \(s.conflicts) (renamed with a (N) suffix: \(s.renamedFiles))")
        lines.append("Unknown camera folders (kept verbatim): \(s.unknownCameras)")
        lines.append("Kept subfolders under Originals/<Camera>: \(s.keptSubfolders); files put back in their catalog subfolder: \(s.knownSubfolderFiles)")
        lines.append("Left in place: \(s.leftInPlace); unreadable (skipped, reported): \(s.unreadable); refused: \(s.refused)")
        lines.append("Catalog: \(s.facePhotoRewrites) face photo rows re-keyed, \(s.syncRecordRewrites) sync records, \(catalog.orientationCopies.count) rotation copies, \(catalog.burstSplitRewrites.count) burst splits, \((catalog.assignmentRewrites ?? []).count) assignments re-pointed, \(catalog.confirmedFaces) confirmed faces kept")
        if let file = fileMapping {
            lines.append("File mapping: sha256 \(file.digest); \(file.rows) rows, \(file.moves) to move, \(file.stays) to stay; \(file.unlistedTwins) unlisted AppleDouble twins follow their file; \(file.alignedToCatalog) moved to the catalog event's path instead of the CSV's")
            lines.append("Emptied source folders to rmdir afterwards (only if empty): \((sourceDirectories ?? []).count) candidates")
        }
        for rename in catalog.eventRenames ?? [] {
            lines.append("Catalog event rename: \"\(rename.oldName)\" → \"\(rename.newName)\" (\(rename.eventID.uuidString)); NAS folder \(rename.oldMirrorFolder) → \(rename.newMirrorFolder); drive folder \(rename.driveFolderState.rawValue): \(rename.oldDriveFolder)\(rename.assignmentsUnderOldDriveFolder > 0 ? "; \(rename.assignmentsUnderOldDriveFolder) assignment(s) name a source root inside it (left as they are)" : "")")
        }
        for attached in catalog.attachedEvents ?? [] {
            lines.append("Catalog event \"\(attached.name)\" → \(attached.mirrorFolder): \(attached.assignments) assignments, \(attached.matched) matched (\(attached.alreadyAligned) already at the app's path, \(attached.aligned) moved there, \(attached.followers) sidecars followed, \(attached.keptNonPortable) kept at the CSV path: not SMB-portable), \(attached.unmatched) unmatched")
        }
        for event in events {
            if fileMapping != nil {
                lines.append("  \(event.destination)  ←  \(event.source) — \(event.moves.count) files, \(bytes(event.byteCount))")
                continue
            }
            lines.append("  \(event.source)  →  \(event.destination)")
            for camera in event.cameras {
                lines.append("      \(camera.sourceFolder) → Originals/\(camera.camera)\(camera.known ? "" : " (unknown name, kept)") — \(camera.files) files")
            }
            if detail {
                for kept in event.keptSubfolders.prefix(10) { lines.append("      kept subfolder: \(kept)") }
            }
        }
        if !unknownCameras.isEmpty {
            lines.append("Unknown camera folders:")
            for camera in unknownCameras { lines.append("  \(camera.path)") }
        }
        if !conflicts.isEmpty {
            lines.append("Conflicts:")
            for conflict in conflicts.prefix(30) {
                lines.append("  \(conflict.source) → \((conflict.resolvedDestination as NSString).lastPathComponent) (\(conflict.reason.rawValue))")
            }
            if conflicts.count > 30 { lines.append("  … and \(conflicts.count - 30) more") }
        }
        if !leftInPlace.isEmpty {
            lines.append("Left in place:")
            for item in leftInPlace.prefix(30) { lines.append("  \(item.path) — \(item.reason)") }
            if leftInPlace.count > 30 { lines.append("  … and \(leftInPlace.count - 30) more") }
        }
        if !unreadable.isEmpty {
            lines.append("Unreadable:")
            for item in unreadable.prefix(30) { lines.append("  \(item.path) — \(item.reason)") }
        }
        if !refused.isEmpty {
            lines.append("Refused:")
            for item in refused.prefix(30) { lines.append("  \(item.path) — \(item.reason)") }
        }
        if !notes.isEmpty {
            lines.append("Notes:")
            for note in notes { lines.append("  - \(note)") }
        }
        if blockers.isEmpty {
            lines.append("Executable: yes")
        } else {
            lines.append("NOT EXECUTABLE:")
            for blocker in blockers { lines.append("  - \(blocker)") }
        }
        return lines.joined(separator: "\n")
    }
}

/// The durable record of one NAS layout migration run.
///
/// Folder: `<support>/NAS Layout Migrations/<stamp>-<plan id>/` with
/// `plan.json`, `journal.json`, and an append-only `moves.log`.
public struct NASLayoutMigrationJournal: Codable, Equatable, Sendable {
    public static let formatName = "camera-toolkit-nas-layout-migration-journal"
    public static let currentVersion = 1

    public enum Phase: String, Codable, Equatable, Sendable {
        case prepared
        case moving
        case movesVerified
        case catalogCommitted
        case completed
        case undoing
        case undone
    }

    public struct FailedMove: Codable, Equatable, Sendable {
        public var eventID: String
        public var index: Int
        public var source: String
        public var reason: String
    }

    public struct SampleCheck: Codable, Equatable, Sendable {
        public var path: String
        public var sha256Before: String
        public var sha256After: String?
    }

    public var format: String
    public var version: Int
    public var id: UUID
    public var planID: UUID
    public var planDigest: String
    public var createdAt: Date
    public var updatedAt: Date
    public var phase: Phase
    public var backupID: String?
    public var backupCatalogPath: String?
    public var backupTableCounts: [String: Int]
    public var verifiedEvents: [String]
    /// Moves that failed (a read or rename error) and were skipped; they
    /// stay at their source. Resume tries them again.
    public var failedMoves: [FailedMove]
    public var sampleChecks: [SampleCheck]
    public var createdDirectories: [String]
    public var removedDirectories: [String]
    public var keptDirectories: [LayoutMigrationJournal.KeptDirectory]
    public var catalogCommittedAt: Date?
    public var postCommitCatalogDigest: String?
    public var captureDateBackupPath: String?
    public var captureDateKeysRewritten: Int
    public var undoSafetyBackupID: String?
    public var lastError: String?
    public var notes: [String]

    static func folder(supportFolder: URL) -> URL {
        supportFolder.appendingPathComponent("NAS Layout Migrations", isDirectory: true)
    }

    static func read(_ url: URL) throws -> NASLayoutMigrationJournal {
        let journal = try LayoutMigrationPlan.decoder().decode(NASLayoutMigrationJournal.self, from: Data(contentsOf: url))
        guard journal.format == formatName, journal.version == currentVersion else {
            throw ToolkitError.commandFailed("\(url.lastPathComponent) is not a NAS layout migration journal this build reads.")
        }
        return journal
    }

    static func write(_ journal: NASLayoutMigrationJournal, to url: URL) throws {
        try LayoutMigrationDurable.write(try LayoutMigrationPlan.encoder().encode(journal), to: url)
    }
}
