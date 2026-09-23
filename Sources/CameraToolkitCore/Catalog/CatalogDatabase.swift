import Foundation
import GRDB
import SQLite3

/// One shared, consistently configured connection per catalog file.
///
/// Every catalog reader and writer in the app goes through `writer(for:)`
/// instead of opening its own connection per call, so the process holds a
/// single writer per file and every connection gets the same pragmas:
///
/// - `journal_mode = WAL` on a local volume: readers never wait on a
///   writer, and a crash mid-write leaves the last committed state intact.
///   A catalog on a network share keeps the rollback journal, because WAL's
///   shared-memory index is not safe over SMB/NFS.
/// - `synchronous = NORMAL` under WAL (durable across an app crash; the
///   rollback journal keeps SQLite's `FULL` default).
/// - a 5 second busy timeout and foreign keys on.
///
/// `checkpointAndCloseAll()` folds the WAL back into the main file; the app
/// calls it at quit, and offline tools call it before handing a candidate
/// catalog to anything that copies files.
public enum CatalogDatabase {
    /// How long a connection waits on another connection's lock before a
    /// statement fails with `SQLITE_BUSY`.
    public static let busyTimeout: TimeInterval = 5

    private final class Entry {
        let writer: any DatabaseWriter
        let fileNumber: UInt64?

        init(writer: any DatabaseWriter, fileNumber: UInt64?) {
            self.writer = writer
            self.fileNumber = fileNumber
        }
    }

    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    private static let lock = NSLock()

    /// The shared connection for the catalog at `url`, opened on first use.
    /// A `DatabasePool` (concurrent readers, one writer) when the file lives
    /// on a local volume, a `DatabaseQueue` on the rollback journal
    /// otherwise. A cached connection is dropped and reopened when the file
    /// it was opened on has been deleted or replaced.
    public static func writer(for url: URL) throws -> any DatabaseWriter {
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        let currentFile = fileNumber(path)
        if let entry = entries[path] {
            if currentFile != nil, currentFile == entry.fileNumber {
                return entry.writer
            }
            entries[path] = nil
            try? entry.writer.close()
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let writer: any DatabaseWriter
        if supportsWAL(at: url) {
            writer = try DatabasePool(path: path, configuration: configuration(wal: true))
        } else {
            writer = try DatabaseQueue(path: path, configuration: configuration(wal: false))
        }
        entries[path] = Entry(writer: writer, fileNumber: fileNumber(path))
        return writer
    }

    /// The configuration every shared catalog connection uses.
    public static func configuration(wal: Bool) -> Configuration {
        var configuration = Configuration()
        configuration.busyMode = .timeout(busyTimeout)
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { database in
            if wal {
                try database.execute(sql: "PRAGMA synchronous = NORMAL")
            } else if !database.configuration.readonly {
                // A catalog moved onto a share may still be flagged WAL
                // from its local life; best effort back to the journal.
                _ = try? String.fetchOne(database, sql: "PRAGMA journal_mode = DELETE")
            }
        }
        return configuration
    }

    /// Applies the shared pragmas to a raw `sqlite3` connection — the
    /// schema bootstrap keeps its own short-lived handle.
    static func configureRawConnection(_ database: OpaquePointer, url: URL) {
        sqlite3_busy_timeout(database, Int32(busyTimeout * 1_000))
        sqlite3_exec(database, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        if supportsWAL(at: url) {
            sqlite3_exec(database, "PRAGMA journal_mode = WAL;", nil, nil, nil)
            sqlite3_exec(database, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
        }
    }

    /// True when the catalog's folder is on a local volume. WAL needs a
    /// shared-memory index that network filesystems cannot provide safely.
    public static func supportsWAL(at url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        let values = try? folder.resourceValues(forKeys: [.volumeIsLocalKey])
        return values?.volumeIsLocal ?? false
    }

    /// Checkpoints the WAL into the main file (`TRUNCATE`, so the `-wal`
    /// file is emptied) and closes the shared connection for `url`. The
    /// next `writer(for:)` reopens it.
    public static func checkpointAndClose(url: URL) {
        let path = url.standardizedFileURL.path
        lock.lock()
        let entry = entries.removeValue(forKey: path)
        lock.unlock()
        guard let entry else { return }
        checkpoint(entry.writer)
        try? entry.writer.close()
    }

    /// `checkpointAndClose` for every open catalog — called at quit.
    public static func checkpointAndCloseAll() {
        lock.lock()
        let open = entries
        entries.removeAll()
        lock.unlock()
        for entry in open.values {
            checkpoint(entry.writer)
            try? entry.writer.close()
        }
    }

    private static func checkpoint(_ writer: any DatabaseWriter) {
        guard writer is DatabasePool else { return }
        try? writer.writeWithoutTransaction { database in
            _ = try database.checkpoint(.truncate)
        }
    }

    private static func fileNumber(_ path: String) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}
