import Foundation
import GRDB

/// What Sync to NAS last proved about one file, keyed by the NAS mirror
/// root and the file's path under it (the same path it has under its drive
/// root).
public struct NASSyncRecord: Codable, Equatable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        /// The NAS copy was re-read from the NAS and its SHA-256 equals the
        /// drive copy's.
        case verified
        /// A different file already sits at the NAS path. It was never
        /// overwritten.
        case conflict
        /// The file could not be read, written, or verified this time.
        case failed
    }

    public var nasRoot: String
    public var relativePath: String
    public var eventID: UUID?
    public var byteCount: Int64
    /// The drive copy's modification time (`timeIntervalSinceReferenceDate`)
    /// when it was checked, so a changed drive file is checked again.
    public var sourceModifiedAt: Double?
    public var sha256: String?
    /// The NAS copy's hash, when it differs (a conflict).
    public var nasSHA256: String?
    public var state: State
    public var detail: String?
    public var checkedAt: Date
    public var verifiedAt: Date?

    public init(
        nasRoot: String,
        relativePath: String,
        eventID: UUID? = nil,
        byteCount: Int64,
        sourceModifiedAt: Double? = nil,
        sha256: String? = nil,
        nasSHA256: String? = nil,
        state: State,
        detail: String? = nil,
        checkedAt: Date,
        verifiedAt: Date? = nil
    ) {
        self.nasRoot = nasRoot
        self.relativePath = relativePath
        self.eventID = eventID
        self.byteCount = byteCount
        self.sourceModifiedAt = sourceModifiedAt
        self.sha256 = sha256
        self.nasSHA256 = nasSHA256
        self.state = state
        self.detail = detail
        self.checkedAt = checkedAt
        self.verifiedAt = verifiedAt
    }

    public var pathKey: String { NASSyncStore.pathKey(relativePath) }
}

/// The catalog's `nas_sync_files` table: per-file Sync to NAS state. It is
/// what makes a sync resumable (a file already verified at the same size
/// and drive modification time is skipped) and what lets presence say
/// "on NAS, verified <date>" and Take Off Drive insist on a verified copy.
///
/// A table of its own rather than `event_asset_locations`: that table is
/// keyed by catalog assignment and has no hash, while a sync also covers
/// sidecars and `Edited/` files no assignment names, and records hashes.
public final class NASSyncStore: @unchecked Sendable {
    public static let tableName = "nas_sync_files"

    static let schema = """
    CREATE TABLE IF NOT EXISTS nas_sync_files (
        nas_root TEXT NOT NULL,
        path_key TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        event_id TEXT,
        byte_count INTEGER NOT NULL,
        source_modified_at REAL,
        sha256 TEXT,
        nas_sha256 TEXT,
        state TEXT NOT NULL CHECK(state IN ('verified', 'conflict', 'failed')),
        detail TEXT,
        checked_at TEXT NOT NULL,
        verified_at TEXT,
        PRIMARY KEY(nas_root, path_key)
    );
    CREATE INDEX IF NOT EXISTS nas_sync_files_event_id ON nas_sync_files(event_id);
    """

    public let catalogURL: URL

    public init(catalogURL: URL) throws {
        self.catalogURL = catalogURL
        try writer().write { try $0.execute(sql: Self.schema) }
    }

    private func writer() throws -> any DatabaseWriter {
        try CatalogDatabase.writer(for: catalogURL)
    }

    /// Case-folded, so a case-insensitive share and drive agree on a key.
    public static func pathKey(_ relativePath: String) -> String { relativePath.lowercased() }

    static func standardizedRoot(_ root: String) -> String {
        URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
    }

    public func upsert(_ records: [NASSyncRecord]) throws {
        guard !records.isEmpty else { return }
        try writer().write { db in
            for record in records {
                try db.execute(
                    sql: """
                    INSERT INTO nas_sync_files(
                        nas_root, path_key, relative_path, event_id, byte_count, source_modified_at,
                        sha256, nas_sha256, state, detail, checked_at, verified_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(nas_root, path_key) DO UPDATE SET
                        relative_path = excluded.relative_path,
                        event_id = excluded.event_id,
                        byte_count = excluded.byte_count,
                        source_modified_at = excluded.source_modified_at,
                        sha256 = excluded.sha256,
                        nas_sha256 = excluded.nas_sha256,
                        state = excluded.state,
                        detail = excluded.detail,
                        checked_at = excluded.checked_at,
                        verified_at = excluded.verified_at
                    """,
                    arguments: [
                        Self.standardizedRoot(record.nasRoot),
                        record.pathKey,
                        record.relativePath,
                        record.eventID?.uuidString,
                        record.byteCount,
                        record.sourceModifiedAt,
                        record.sha256,
                        record.nasSHA256,
                        record.state.rawValue,
                        record.detail,
                        Self.timestamp(record.checkedAt),
                        record.verifiedAt.map(Self.timestamp),
                    ]
                )
            }
        }
    }

    /// Every record under `nasRoot`, optionally only those whose path starts
    /// with one of `prefixes` (event folder paths), keyed by `pathKey`.
    public func records(nasRoot: String, prefixes: [String]? = nil) throws -> [String: NASSyncRecord] {
        let root = Self.standardizedRoot(nasRoot)
        return try writer().read { db in
            guard try db.tableExists(Self.tableName) else { return [:] }
            var rows: [Row] = []
            if let prefixes {
                for prefix in Set(prefixes.map { Self.pathKey($0) }) {
                    // `substr` rather than LIKE: event names may hold `%`/`_`.
                    rows += try Row.fetchAll(
                        db,
                        sql: "SELECT * FROM nas_sync_files WHERE nas_root = ? AND substr(path_key, 1, ?) = ?",
                        arguments: [root, prefix.count + 1, prefix + "/"]
                    )
                }
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM nas_sync_files WHERE nas_root = ?", arguments: [root])
            }
            var result: [String: NASSyncRecord] = [:]
            for row in rows {
                let record = Self.record(row)
                result[record.pathKey] = record
            }
            return result
        }
    }

    /// `verifiedDates` without creating anything: an absent catalog or a
    /// catalog without the table answers empty. For the presence sweep.
    public static func verifiedDates(catalogURL: URL, nasRoot: String, prefixes: [String]) -> [String: Date] {
        guard FileManager.default.fileExists(atPath: catalogURL.path),
              let writer = try? CatalogDatabase.writer(for: catalogURL),
              (try? writer.read({ try $0.tableExists(tableName) })) == true else { return [:] }
        let store = NASSyncStore(unchecked: catalogURL)
        return (try? store.verifiedDates(nasRoot: nasRoot, prefixes: prefixes)) ?? [:]
    }

    /// `records` without creating anything, for the NAS presence index: an
    /// absent catalog or a catalog without the table answers empty.
    public static func existingRecords(catalogURL: URL, nasRoot: String, prefixes: [String]? = nil) -> [String: NASSyncRecord] {
        guard FileManager.default.fileExists(atPath: catalogURL.path),
              let writer = try? CatalogDatabase.writer(for: catalogURL),
              (try? writer.read({ try $0.tableExists(tableName) })) == true else { return [:] }
        return (try? NASSyncStore(unchecked: catalogURL).records(nasRoot: nasRoot, prefixes: prefixes)) ?? [:]
    }

    private init(unchecked catalogURL: URL) {
        self.catalogURL = catalogURL
    }

    /// `pathKey` → verified date, for the presence sweep.
    public func verifiedDates(nasRoot: String, prefixes: [String]) throws -> [String: Date] {
        try records(nasRoot: nasRoot, prefixes: prefixes).compactMapValues { record in
            record.state == .verified ? record.verifiedAt : nil
        }
    }

    private static func record(_ row: Row) -> NASSyncRecord {
        let eventID: String? = row["event_id"]
        let checked: String = row["checked_at"]
        let verified: String? = row["verified_at"]
        let state: String = row["state"]
        return NASSyncRecord(
            nasRoot: row["nas_root"],
            relativePath: row["relative_path"],
            eventID: eventID.flatMap(UUID.init(uuidString:)),
            byteCount: row["byte_count"],
            sourceModifiedAt: row["source_modified_at"],
            sha256: row["sha256"],
            nasSHA256: row["nas_sha256"],
            state: NASSyncRecord.State(rawValue: state) ?? .failed,
            detail: row["detail"],
            checkedAt: parse(checked) ?? .distantPast,
            verifiedAt: verified.flatMap(parse)
        )
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func parse(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }
}
