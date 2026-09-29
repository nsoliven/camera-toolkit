import Foundation
import GRDB

/// The undo history on disk: one small SQLite file (`undo-history.sqlite`
/// beside the move journals), one row per entry. An entry that owns a drive
/// rename or a Trash batch stores only a reference — the move journal, the
/// batch manifest — and the files themselves stay where the journal says;
/// an entry that changed catalog rows only (a sort, an event edit, a face
/// row) stores what it needs to swap them back. Rows in memory only
/// (`UndoAction.session`) are not written, and an entry whose payload is
/// larger than `maximumPayloadBytes` (a face junk with thousands of
/// crops) stays in memory for this run instead of bloating the file.
///
/// This is separate from the catalog on purpose: restoring or replacing
/// `catalog.sqlite` never has to carry stale undo steps along.
public final class UndoHistoryStore: @unchecked Sendable {
    public static let fileName = "undo-history.sqlite"
    public static let maximumPayloadBytes = 8 * 1024 * 1024

    public let url: URL
    private let lock = NSLock()
    private var queue: DatabaseQueue?

    public init(url: URL) {
        self.url = url
    }

    private func database() throws -> DatabaseQueue {
        lock.lock()
        defer { lock.unlock() }
        if let queue { return queue }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let opened = try DatabaseQueue(path: url.path)
        try opened.write { database in
            try database.execute(sql: """
            CREATE TABLE IF NOT EXISTS undo_entries (
                stack TEXT NOT NULL,
                position INTEGER NOT NULL,
                id TEXT NOT NULL,
                created_at REAL NOT NULL,
                title TEXT NOT NULL,
                detail TEXT,
                payload BLOB NOT NULL,
                PRIMARY KEY(stack, position)
            );
            """)
        }
        queue = opened
        return opened
    }

    /// Replaces what is stored with `history`, in one transaction.
    public func save(_ history: UndoHistory) throws {
        let encoder = JSONEncoder()
        var rows: [(stack: String, position: Int, entry: UndoEntry, payload: Data)] = []
        for (name, entries) in [("undo", history.undoStack), ("redo", history.redoStack)] {
            for (position, entry) in entries.enumerated() where entry.action.isPersistent {
                guard let payload = try? encoder.encode(entry.action),
                      payload.count <= Self.maximumPayloadBytes else { continue }
                rows.append((name, position, entry, payload))
            }
        }
        try database().write { database in
            try database.execute(sql: "DELETE FROM undo_entries")
            for row in rows {
                try database.execute(
                    sql: """
                    INSERT INTO undo_entries(stack, position, id, created_at, title, detail, payload)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        row.stack, row.position, row.entry.id.uuidString,
                        row.entry.createdAt.timeIntervalSince1970, row.entry.title, row.entry.detail, row.payload,
                    ]
                )
            }
        }
    }

    /// What was stored, oldest first. Rows that no longer decode are
    /// skipped — an entry from a newer build is simply not offered.
    public func load() throws -> UndoHistory {
        let decoder = JSONDecoder()
        let rows = try database().read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM undo_entries ORDER BY stack, position")
        }
        var undo: [UndoEntry] = []
        var redo: [UndoEntry] = []
        for row in rows {
            let payload: Data = row["payload"]
            guard let idText: String = row["id"], let id = UUID(uuidString: idText),
                  let action = try? decoder.decode(UndoAction.self, from: payload) else { continue }
            let entry = UndoEntry(
                id: id,
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                title: row["title"],
                detail: row["detail"],
                action: action
            )
            if (row["stack"] as String) == "undo" { undo.append(entry) } else { redo.append(entry) }
        }
        return UndoHistory(undoStack: undo, redoStack: redo)
    }

    /// Closes the file (tests remove the folder afterwards).
    public func close() {
        lock.lock()
        queue = nil
        lock.unlock()
    }
}
