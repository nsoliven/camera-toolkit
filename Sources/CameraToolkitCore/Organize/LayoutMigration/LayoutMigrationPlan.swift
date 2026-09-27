import CryptoKit
import Foundation

/// Everything the `Card Copy` → `Originals/<Camera>` layout migration would
/// do, computed read-only and serializable for review.
///
/// A plan is executed exactly as reviewed: `LayoutMigrationExecutor`
/// re-checks the `fingerprint` (every source file's size, inode and
/// modification time, every legacy folder's listing, and a digest of the
/// catalog rows the plan rewrites) and refuses to start when anything
/// differs.
public struct LayoutMigrationPlan: Codable, Equatable, Sendable {
    public static let formatName = "camera-toolkit-layout-migration-plan"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var id: UUID
    public var createdAt: Date
    public var supportFolderPath: String
    public var configurationPath: String
    public var catalogPath: String
    /// The drive roots scanned: the Buffer and private staging.
    public var driveRoots: [Root]
    /// One legacy `<device>/Card Copy` folder each.
    public var folders: [Folder]
    /// Destinations that were taken, and the `(N)` names that resolve them.
    public var conflicts: [Conflict]
    /// Things the migration leaves exactly where they are.
    public var leftInPlace: [LeftInPlace]
    /// Catalog assignments whose file is nowhere on the drive or source.
    public var missingRows: [MissingRow]
    /// Files the migration refuses to move (other volume, symlink, …).
    public var refused: [Refusal]
    /// Event folders that look like leftovers; reported, never touched.
    public var oddFolders: [OddFolder]
    /// Reasons the plan cannot be executed at all. Empty means executable.
    public var blockers: [String]
    public var catalog: CatalogChanges
    public var stores: StoreChanges
    public var fingerprint: Fingerprint
    public var summary: Summary

    public var isExecutable: Bool { blockers.isEmpty }

    public var allMoves: [Move] { folders.flatMap(\.moves) }

    public struct Root: Codable, Equatable, Sendable {
        public var path: String
        public var policy: EventStoragePolicy
        /// False when the root's volume is not mounted or the folder is
        /// missing; nothing under it was planned.
        public var scanned: Bool
        public var note: String?
    }

    public enum FileKind: String, Codable, Equatable, Sendable {
        /// A camera file: RAW, JPEG/HEIC, video, audio.
        case media
        /// XMP, `.photo-edit`, LRF, XML, THM and other companions.
        case sidecar
        /// `._NAME` twin of a file in the same folder. On exFAT/FAT the
        /// filesystem renames it together with its file; elsewhere the
        /// executor renames it explicitly.
        case appleDouble
        /// `._NAME` twin of a folder inside `Card Copy`; moves to the twin
        /// of the folder's new location.
        case folderAppleDouble
        /// `.DS_Store`.
        case finderMetadata
        /// Anything else found inside `Card Copy`.
        case other
    }

    public struct Move: Codable, Equatable, Hashable, Sendable {
        public var source: String
        public var destination: String
        public var byteCount: Int64
        public var inode: UInt64
        /// `timeIntervalSinceReferenceDate` of the modification time.
        public var modifiedAt: Double
        public var kind: FileKind
        /// True when a catalog assignment points at this file.
        public var catalogKnown: Bool
        /// True when the destination name carries a `(N)` suffix.
        public var renamed: Bool
        /// For `.appleDouble` twins that travel with a file: the index of
        /// that file's move in the same folder.
        public var companionOf: Int?
    }

    public struct Folder: Codable, Equatable, Sendable {
        /// Stable within the plan: `F0001`, `F0002`, …
        public var id: String
        public var policy: EventStoragePolicy
        public var eventFolderPath: String
        /// "Parent / Child" folder breadcrumb (from the folder names).
        public var eventTitle: String
        /// The catalog event occupying `eventFolderPath`, when there is one.
        public var eventID: UUID?
        /// `<event>/<device>` — the legacy device folder.
        public var legacyDeviceFolderPath: String
        /// `<event>/<device>/Card Copy`.
        public var legacyFilesRootPath: String
        /// `<event>/Originals/<Camera>`.
        public var originalsPath: String
        public var cameraFolder: String
        public var deviceID: String
        public var moves: [Move]
        public var byteCount: Int64
        /// Directories under `Card Copy` (relative), so undo can recreate
        /// them and removal knows what to try.
        public var legacyDirectories: [String]
    }

    public struct Conflict: Codable, Equatable, Sendable {
        public enum Reason: String, Codable, Equatable, Sendable {
            /// A file already sits at the destination (a drive already
            /// partly in the new layout).
            case destinationExists
            /// Two legacy folders map to the same `Originals/<Camera>`.
            case claimedByAnotherFile
            /// Held with a file of the same base name that collided.
            case travelsWithConflict
        }
        public var source: String
        public var plannedDestination: String
        public var resolvedDestination: String
        public var reason: Reason
        public var existingByteCount: Int64?
        /// True when the existing file is byte-identical (checked only for
        /// equal sizes). Both are kept either way.
        public var identicalContent: Bool?
    }

    public struct LeftInPlace: Codable, Equatable, Sendable {
        public var path: String
        public var fileCount: Int
        public var byteCount: Int64
        public var reason: String
    }

    public struct MissingRow: Codable, Equatable, Sendable {
        public var eventAssetID: String
        public var eventTitle: String
        public var expectedPath: String
        public var reason: String
    }

    public struct Refusal: Codable, Equatable, Sendable {
        public var path: String
        public var reason: String
    }

    public struct OddFolder: Codable, Equatable, Sendable {
        public var path: String
        public var fileCount: Int
        /// Files that are not `._*` / `.DS_Store`.
        public var mediaFileCount: Int
        public var byteCount: Int64
        public var hasCatalogEvent: Bool
        public var reasons: [String]
    }

    public struct AssignmentRewrite: Codable, Equatable, Sendable {
        public var oldID: String
        public var newID: String
        public var eventID: UUID
        public var oldSourceRootPath: String
        public var newSourceRootPath: String
        public var oldRelativePath: String
        public var newRelativePath: String
        public var destination: String
    }

    public struct FacePhotoRewrite: Codable, Equatable, Sendable {
        public var oldPathKey: String
        public var newPathKey: String
        public var newPath: String
        public var newFileName: String
        public var faceCount: Int
        public var confirmedFaceCount: Int
    }

    /// A face photo row at a stale path whose file identity (name + size +
    /// modification second) is a file the migration renames: its name
    /// follows so the faces keep attaching to the renamed file.
    public struct FaceIdentityRename: Codable, Equatable, Sendable {
        public var pathKey: String
        public var oldFileName: String
        public var newFileName: String
    }

    public struct OrientationCopy: Codable, Equatable, Sendable {
        public var oldKey: String
        public var newKey: String
        public var quarterTurns: Int
    }

    public struct BurstSplitRewrite: Codable, Equatable, Sendable {
        public var id: UUID
        public var oldMemberPathKeys: [String]
        public var newMemberPathKeys: [String]
    }

    public struct CatalogChanges: Codable, Equatable, Sendable {
        public var assignmentRewrites: [AssignmentRewrite]
        public var facePhotoRewrites: [FacePhotoRewrite]
        public var faceIdentityRenames: [FaceIdentityRename]
        public var orientationCopies: [OrientationCopy]
        public var burstSplitRewrites: [BurstSplitRewrite]
        /// Row counts before the rewrite. After it they must be identical,
        /// except `display_orientations`, which grows by the copies.
        public var tableCounts: [String: Int]
        public var confirmedFaces: Int
        /// Confirmed faces on photos the migration moves — by path or by
        /// file identity. After the commit each must still attach to a
        /// file that exists.
        public var confirmedFacesAffected: Int
        /// `app_state` key recording that the catalog is in the new layout.
        public var markerKey: String
    }

    public struct TrashManifestRewrite: Codable, Equatable, Sendable {
        public var manifestPath: String
        /// Original absolute paths inside a legacy `Card Copy`, and their
        /// `Originals` equivalent, so a restore lands in the new layout.
        public var entries: [PathRewrite]
    }

    public struct PathRewrite: Codable, Equatable, Hashable, Sendable {
        public var old: String
        public var new: String

        public init(old: String, new: String) {
            self.old = old
            self.new = new
        }
    }

    public struct StoreChanges: Codable, Equatable, Sendable {
        /// `capture-dates.json` keys (full paths) that move with their file.
        public var captureDatePath: String
        public var captureDateKeys: Int
        public var trashManifests: [TrashManifestRewrite]
        /// Apply journals written before the migration. Their paths name
        /// the legacy layout, so the migration marks them as no longer
        /// undoable (a barrier file, never an edit of the journals).
        public var moveJournalFolderPath: String
        public var moveJournalsSuperseded: Int
    }

    public struct FileStamp: Codable, Equatable, Hashable, Sendable {
        public var path: String
        public var byteCount: Int64
        public var inode: UInt64
        public var modifiedAt: Double
    }

    public struct Fingerprint: Codable, Equatable, Sendable {
        /// SHA-256 of each scanned folder's listing — every entry under the
        /// legacy device folder (relative path, type, size, inode) — keyed by
        /// `legacyDeviceFolderPath`. A file added, removed or replaced since
        /// the plan changes it.
        public var folderListings: [String: String]
        /// Every legacy camera folder found on the scanned roots, so a new
        /// one appearing after the plan is caught.
        public var legacyCameraFolders: [String]
        /// SHA-256 over the catalog rows the migration reads or rewrites.
        public var catalogDigest: String
    }

    public struct EventSummary: Codable, Equatable, Sendable {
        public var eventFolderPath: String
        public var title: String
        public var policy: EventStoragePolicy
        public var cameras: [String]
        public var files: Int
        public var byteCount: Int64
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var events: Int
        public var folders: Int
        public var files: Int
        public var byteCount: Int64
        public var catalogKnownFiles: Int
        public var unknownFilesMoved: Int
        public var appleDoubleFiles: Int
        public var conflicts: Int
        public var renamedFiles: Int
        public var leftInPlace: Int
        public var leftInPlaceFiles: Int
        public var missingRows: Int
        public var refused: Int
        public var oddFolders: Int
        public var assignmentRewrites: Int
        public var facePhotoRewrites: Int
        public var faceIdentityRenames: Int
        public var confirmedFaces: Int
        public var confirmedFacesAffected: Int
        public var burstSplitRewrites: Int
        public var orientationCopies: Int
        public var trashEntriesRewritten: Int
        public var captureDateKeys: Int
        public var moveJournalsSuperseded: Int
        public var perEvent: [EventSummary]
    }
}

extension LayoutMigrationPlan {
    /// ISO 8601 with milliseconds, so a plan read back is equal to the one
    /// written.
    static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: dateStyle) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
        }
        return decoder
    }

    public func jsonData() throws -> Data {
        try Self.encoder().encode(self)
    }

    public static func read(_ url: URL) throws -> LayoutMigrationPlan {
        let plan = try decoder().decode(LayoutMigrationPlan.self, from: Data(contentsOf: url))
        guard plan.format == formatName else {
            throw ToolkitError.commandFailed("\(url.lastPathComponent) is not a layout migration plan.")
        }
        guard plan.version == currentVersion else {
            throw ToolkitError.commandFailed("The plan is version \(plan.version); this build reads version \(currentVersion). Make a new plan.")
        }
        return plan
    }

    /// SHA-256 of the plan's JSON — the identity the journal records, so a
    /// resume or undo can prove it is working from the same plan.
    public func digest() throws -> String {
        LayoutMigrationHash.sha256(try jsonData())
    }

    /// A short human summary for the CLI.
    public func summaryText() -> String {
        let s = summary
        var lines: [String] = []
        func bytes(_ value: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
        }
        lines.append("Layout migration plan \(id.uuidString)")
        lines.append("  created \(ISO8601DateFormatter().string(from: createdAt))")
        for root in driveRoots {
            lines.append("  root [\(root.policy == .buffer ? "Buffer" : "Private")] \(root.path)\(root.scanned ? "" : " — not scanned: \(root.note ?? "offline")")")
        }
        lines.append("Moves: \(s.files) files, \(bytes(s.byteCount)) in \(s.folders) camera folders across \(s.events) event folders")
        lines.append("  catalog-known files: \(s.catalogKnownFiles); unknown files moved along: \(s.unknownFilesMoved); AppleDouble twins: \(s.appleDoubleFiles)")
        lines.append("Conflicts: \(s.conflicts) (renamed with a (N) suffix: \(s.renamedFiles))")
        lines.append("Left in place: \(s.leftInPlace) item(s), \(s.leftInPlaceFiles) file(s)")
        lines.append("Missing catalog rows (reported, never deleted): \(s.missingRows)")
        lines.append("Refused (other volume, symlink, not a file): \(s.refused)")
        lines.append("Odd event folders (reported only): \(s.oddFolders)")
        lines.append("Catalog: \(s.assignmentRewrites) assignment rows rewritten, \(s.facePhotoRewrites) face photo rows re-keyed, \(s.faceIdentityRenames) face identity renames, \(s.burstSplitRewrites) burst splits, \(s.orientationCopies) rotation copies")
        lines.append("Faces: \(s.confirmedFaces) confirmed in total; \(s.confirmedFacesAffected) on files this migration moves")
        lines.append("Stores: \(s.captureDateKeys) capture-date cache keys, \(s.trashEntriesRewritten) trash manifest entries, \(s.moveJournalsSuperseded) older Apply journals become non-undoable")
        if !s.perEvent.isEmpty {
            lines.append("Per event:")
            for event in s.perEvent {
                lines.append("  \(event.policy == .buffer ? "  " : "P ")\(event.title): \(event.files) files, \(bytes(event.byteCount)) — \(event.cameras.joined(separator: ", "))")
            }
        }
        if !oddFolders.isEmpty {
            lines.append("Odd folders:")
            for folder in oddFolders {
                lines.append("  \(folder.path) — \(folder.mediaFileCount) media of \(folder.fileCount) files, \(bytes(folder.byteCount)); \(folder.reasons.joined(separator: "; "))")
            }
        }
        if !conflicts.isEmpty {
            lines.append("Conflicts:")
            for conflict in conflicts.prefix(20) {
                lines.append("  \(conflict.source) → \((conflict.resolvedDestination as NSString).lastPathComponent) (\(conflict.reason.rawValue))")
            }
            if conflicts.count > 20 { lines.append("  … and \(conflicts.count - 20) more") }
        }
        if !blockers.isEmpty {
            lines.append("NOT EXECUTABLE:")
            for blocker in blockers { lines.append("  - \(blocker)") }
        } else {
            lines.append("Executable: yes")
        }
        return lines.joined(separator: "\n")
    }
}

enum LayoutMigrationHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }
}
