import Darwin
import Foundation
import GRDB

/// What a cached hash is valid for: one path at one size and modification
/// time. Any change to either — an edit, a re-copy, a touch — misses the
/// cache and the file is read again.
public struct DuplicateFileStamp: Hashable, Sendable {
    /// `EventStorageLocations.pathKey` of the file.
    public var pathKey: String
    public var byteCount: Int64
    /// `st_mtimespec` in nanoseconds since 1970 — exact, so a sub-second
    /// rewrite still invalidates.
    public var modifiedNanoseconds: Int64

    public init(pathKey: String, byteCount: Int64, modifiedNanoseconds: Int64) {
        self.pathKey = pathKey
        self.byteCount = byteCount
        self.modifiedNanoseconds = modifiedNanoseconds
    }
}

/// `duplicate-review.sqlite` in the organizer's support folder: the SHA-256
/// of every file the duplicate scan read, and the groups the owner chose to
/// Keep Both.
///
/// A database of its own rather than tables in the catalog, like
/// `job-history.sqlite`: every hash is reproducible from the drive, a scan
/// rewrites thousands of rows at once, and none of that belongs in the
/// catalog's verified backups. Losing the file costs one slower scan and
/// brings Keep Both groups back for review — never a photo or an
/// assignment. It shares the catalog's connection setup (`CatalogDatabase`:
/// WAL on a local volume, one writer per file, checkpointed at quit) and is
/// migrated with a `DatabaseMigrator`, as `JobHistoryStore` is.
///
/// Only the scan trusts these hashes. Resolving a group re-reads both
/// copies from disk before anything moves.
public final class DuplicateReviewStore: @unchecked Sendable {
    public static let fileName = "duplicate-review.sqlite"

    public let url: URL

    /// Opens (creating when missing) and migrates the store.
    public init(url: URL) throws {
        self.url = url
        try Self.migrator.migrate(writer())
    }

    /// `duplicate-review.sqlite` in `folder` — the workspace's support
    /// folder, beside the move journals and the capture-date cache.
    public static func defaultURL(supportFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }

    private func writer() throws -> any DatabaseWriter {
        try CatalogDatabase.writer(for: url)
    }

    // MARK: Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            -- One row per file the scan hashed. A row is only trusted while
            -- the file still has this size and modification time.
            CREATE TABLE file_hashes (
                path_key TEXT PRIMARY KEY NOT NULL,
                byte_count INTEGER NOT NULL,
                modified_ns INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                hashed_at TEXT NOT NULL
            );

            -- Duplicate groups the owner chose to Keep Both. The key is the
            -- content hash plus the owners holding it, so the same photo
            -- turning up in one more event is flagged again.
            CREATE TABLE reviewed_groups (
                group_key TEXT PRIMARY KEY NOT NULL,
                sha256 TEXT NOT NULL,
                reviewed_at TEXT NOT NULL
            );
            """)
        }
        return migrator
    }

    // MARK: Hashes

    /// Cached hashes for the stamps whose size and modification time still
    /// match the row, keyed by path key. Stale rows are simply not returned.
    public func cachedHashes(for stamps: [DuplicateFileStamp]) throws -> [String: String] {
        guard !stamps.isEmpty else { return [:] }
        var wanted: [String: DuplicateFileStamp] = [:]
        for stamp in stamps { wanted[stamp.pathKey] = stamp }
        let keys = Array(wanted.keys)
        return try writer().read { db in
            var found: [String: String] = [:]
            // Bounded IN lists keep each statement under SQLite's variable cap.
            for start in stride(from: 0, to: keys.count, by: 500) {
                let slice = Array(keys[start..<min(start + 500, keys.count)])
                let marks = Array(repeating: "?", count: slice.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT path_key, byte_count, modified_ns, sha256 FROM file_hashes WHERE path_key IN (\(marks))",
                    arguments: StatementArguments(slice)
                )
                for row in rows {
                    let key: String = row["path_key"]
                    guard let stamp = wanted[key],
                          stamp.byteCount == row["byte_count"] as Int64,
                          stamp.modifiedNanoseconds == row["modified_ns"] as Int64 else { continue }
                    found[key] = row["sha256"]
                }
            }
            return found
        }
    }

    /// Records (or refreshes) hashes in one transaction.
    public func storeHashes(_ entries: [(stamp: DuplicateFileStamp, sha256: String)], hashedAt: Date = Date()) throws {
        guard !entries.isEmpty else { return }
        let now = NASSyncStore.timestamp(hashedAt)
        try writer().write { db in
            let statement = try db.cachedStatement(sql: """
            INSERT INTO file_hashes(path_key, byte_count, modified_ns, sha256, hashed_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(path_key) DO UPDATE SET
                byte_count = excluded.byte_count, modified_ns = excluded.modified_ns,
                sha256 = excluded.sha256, hashed_at = excluded.hashed_at
            """)
            for entry in entries {
                try statement.execute(arguments: [
                    entry.stamp.pathKey, entry.stamp.byteCount, entry.stamp.modifiedNanoseconds, entry.sha256, now,
                ])
            }
        }
    }

    // MARK: Keep Both

    public func reviewedGroupKeys() throws -> Set<String> {
        try writer().read { db in
            Set(try String.fetchAll(db, sql: "SELECT group_key FROM reviewed_groups"))
        }
    }

    /// Marks groups reviewed ("Keep Both") so later scans stop flagging them.
    public func markReviewed(_ groups: [DuplicateGroup], at date: Date = Date()) throws {
        guard !groups.isEmpty else { return }
        let now = NASSyncStore.timestamp(date)
        try writer().write { db in
            for group in groups {
                try db.execute(
                    sql: """
                    INSERT INTO reviewed_groups(group_key, sha256, reviewed_at) VALUES (?, ?, ?)
                    ON CONFLICT(group_key) DO UPDATE SET reviewed_at = excluded.reviewed_at
                    """,
                    arguments: [group.id, group.sha256, now]
                )
            }
        }
    }

    /// Flags groups for review again.
    public func clearReviewed(_ groupKeys: [String]) throws {
        guard !groupKeys.isEmpty else { return }
        try writer().write { db in
            for key in groupKeys {
                try db.execute(sql: "DELETE FROM reviewed_groups WHERE group_key = ?", arguments: [key])
            }
        }
    }
}

/// One `lstat` of a file, the facts the duplicate scan and its resolver
/// compare: size, exact modification time, and the device/inode pair that
/// tells two names for one file apart from two copies.
struct DuplicateFileFacts: Hashable, Sendable {
    var byteCount: Int64
    var modifiedNanoseconds: Int64
    /// `device:inode` — equal for a hard link or a case variant of one path.
    var identity: String

    var modifiedAt: Date { Date(timeIntervalSince1970: TimeInterval(modifiedNanoseconds) / 1e9) }

    /// Nil unless `path` is a regular file (a symlink is never followed).
    static func read(_ path: String) -> DuplicateFileFacts? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let nanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return DuplicateFileFacts(
            byteCount: Int64(info.st_size),
            modifiedNanoseconds: nanoseconds,
            identity: "\(info.st_dev):\(info.st_ino)"
        )
    }
}
