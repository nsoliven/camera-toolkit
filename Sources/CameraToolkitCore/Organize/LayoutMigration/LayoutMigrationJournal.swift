import Darwin
import Foundation

/// The durable record of one layout migration run, written before the
/// first rename and after every proven boundary. With the plan copy beside
/// it and the filesystem itself (every planned file is either at its source
/// or at its destination, identified by inode), it lets a crashed run
/// resume or be undone.
///
/// Folder: `<support>/Layout Migrations/<stamp>-<plan id>/`
/// - `plan.json` — the reviewed plan, byte for byte
/// - `journal.json` — this record
/// - `moves.log` — one line per completed rename, appended and fsynced
/// - `capture-dates.before.json`, `trash-<n>.manifest.json` — the stores as
///   they were before the migration rewrote them
public struct LayoutMigrationJournal: Codable, Equatable, Sendable {
    public static let formatName = "camera-toolkit-layout-migration-journal"
    public static let currentVersion = 1

    public enum Phase: String, Codable, Equatable, Sendable {
        /// Backup verified, journal written; nothing renamed yet.
        case prepared
        /// Renames in progress; `verifiedFolders` are proven.
        case moving
        /// Every planned file proven at its destination; catalog untouched.
        case movesVerified
        /// The catalog transaction committed and verified.
        case catalogCommitted
        /// Capture-date cache, trash manifests and the journal barrier done.
        case storesRewritten
        /// Emptied legacy folders removed. Finished.
        case completed
        /// An undo is running (or was interrupted; run it again).
        case undoing
        /// Everything renamed back and the catalog restored.
        case undone
    }

    public struct ManifestBackup: Codable, Equatable, Sendable {
        public var manifestPath: String
        public var backupPath: String
        /// SHA-256 of what the migration wrote, so undo only restores a
        /// manifest nobody changed since.
        public var writtenSHA256: String
    }

    public struct KeptDirectory: Codable, Equatable, Sendable {
        public var path: String
        public var reason: String
    }

    public var format: String
    public var version: Int
    public var id: UUID
    public var planID: UUID
    public var planDigest: String
    public var createdAt: Date
    public var updatedAt: Date
    public var phase: Phase
    public var backupID: String
    public var backupCatalogPath: String
    public var backupTableCounts: [String: Int]
    public var verifiedFolders: [String]
    /// Directories this run created, in creation order.
    public var createdDirectories: [String]
    /// Legacy directories removed because they were empty, in removal order.
    public var removedDirectories: [String]
    public var keptDirectories: [KeptDirectory]
    public var catalogCommittedAt: Date?
    public var postCommitCatalogDigest: String?
    public var captureDateBackupPath: String?
    public var captureDateKeysRewritten: Int
    public var trashManifestBackups: [ManifestBackup]
    public var barrierPath: String?
    public var undoSafetyBackupID: String?
    public var lastError: String?
    public var notes: [String]

    static func folder(supportFolder: URL) -> URL {
        supportFolder.appendingPathComponent("Layout Migrations", isDirectory: true)
    }

    static func read(_ url: URL) throws -> LayoutMigrationJournal {
        let journal = try LayoutMigrationPlan.decoder().decode(LayoutMigrationJournal.self, from: Data(contentsOf: url))
        guard journal.format == formatName, journal.version == currentVersion else {
            throw ToolkitError.commandFailed("\(url.lastPathComponent) is not a layout migration journal this build reads.")
        }
        return journal
    }

    /// Temp file, `F_FULLFSYNC`, rename over, fsync the folder: after a
    /// crash the journal is the old version or the new one, never torn.
    static func write(_ journal: LayoutMigrationJournal, to url: URL) throws {
        try LayoutMigrationDurable.write(try LayoutMigrationPlan.encoder().encode(journal), to: url)
    }
}

enum LayoutMigrationDurable {
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw ToolkitError.commandFailed("Could not write \(temporary.path).")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw ToolkitError.commandFailed("Could not replace \(url.lastPathComponent): \(String(cString: strerror(code)))")
        }
        syncDirectory(url.deletingLastPathComponent())
    }

    static func syncDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fcntl(descriptor, F_FULLFSYNC)
        close(descriptor)
    }

    /// Writes `data` to a new file only — never over an existing one.
    static func writeNew(_ data: Data, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ToolkitError.commandFailed("\(url.path) already exists; nothing was replaced.")
        }
        try write(data, to: url)
    }
}

/// Append-only `moves.log`: one `done\t<folder id>\t<move index>` line per
/// rename. Advisory — resume trusts the filesystem (inode at source or
/// destination) — but it makes a crashed run's progress readable.
final class LayoutMigrationMoveLog {
    private let handle: FileHandle
    private var pending = 0

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func append(_ line: String) {
        try? handle.write(contentsOf: Data((line + "\n").utf8))
        pending += 1
        if pending >= 64 { sync() }
    }

    func sync() {
        _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
        pending = 0
    }

    deinit {
        sync()
        try? handle.close()
    }
}

/// `flock` on `<Layout Migrations>/.lock`, so two migration processes never
/// run at once. Released when the value goes away (or the process dies).
final class LayoutMigrationLock {
    private let descriptor: Int32

    init(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent(".lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw ToolkitError.commandFailed("Could not open the migration lock at \(path).")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ToolkitError.commandFailed("Another layout migration is running (\(path) is locked).")
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
