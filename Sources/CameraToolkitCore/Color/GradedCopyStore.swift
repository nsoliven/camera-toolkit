import Foundation
import GRDB

/// One graded copy and the original it was made from, both as paths under
/// the NAS root (the paths Immich lists them by). Send to Immich writes one
/// for every copy it makes or finds, so each later check knows which album
/// photo the copy stands in for.
public struct GradedCopyRecord: Codable, Equatable, Sendable {
    public var eventID: UUID
    public var originalRelativePath: String
    public var gradedRelativePath: String
    /// The original's identity (`FaceIndexStore.fileKey`), as tagged in the copy.
    public var sourceKey: String
    public var recordedAt: Date
    /// Filled when read: Sync to NAS (or the NAS render itself) verified a
    /// file at `gradedRelativePath`. A copy still only on the drive is not
    /// waited for.
    public var isOnNAS: Bool

    public init(eventID: UUID, originalRelativePath: String, gradedRelativePath: String, sourceKey: String, recordedAt: Date = Date(), isOnNAS: Bool = false) {
        self.eventID = eventID
        self.originalRelativePath = originalRelativePath
        self.gradedRelativePath = gradedRelativePath
        self.sourceKey = sourceKey
        self.recordedAt = recordedAt
        self.isOnNAS = isOnNAS
    }

    public var originalKey: String { NASSyncStore.pathKey(originalRelativePath) }
    public var gradedKey: String { NASSyncStore.pathKey(gradedRelativePath) }
}

/// The catalog's `graded_copies` table. Rows are bookkeeping only: nothing
/// here touches a file, and removing a row never removes a copy.
public final class GradedCopyStore: @unchecked Sendable {
    public static let tableName = "graded_copies"

    static let schema = """
    CREATE TABLE IF NOT EXISTS graded_copies (
        graded_key TEXT PRIMARY KEY,
        original_key TEXT NOT NULL,
        event_id TEXT NOT NULL,
        record TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS graded_copies_event_id ON graded_copies(event_id);
    """

    public let catalogURL: URL

    public init(catalogURL: URL) throws {
        self.catalogURL = catalogURL
        try CatalogDatabase.writer(for: catalogURL).write { try $0.execute(sql: Self.schema) }
    }

    public func save(_ records: [GradedCopyRecord]) throws {
        guard !records.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try CatalogDatabase.writer(for: catalogURL).write { database in
            for record in records {
                var stored = record
                stored.isOnNAS = false
                try database.execute(
                    sql: """
                    INSERT INTO graded_copies(graded_key, original_key, event_id, record) VALUES (?, ?, ?, ?)
                    ON CONFLICT(graded_key) DO UPDATE SET original_key = excluded.original_key, event_id = excluded.event_id, record = excluded.record
                    """,
                    arguments: [record.gradedKey, record.originalKey, record.eventID.uuidString, String(decoding: try encoder.encode(stored), as: UTF8.self)]
                )
            }
        }
    }

    /// The records of these events (all with nil), each marked with whether
    /// a verified NAS file is at its copy's path.
    public func records(eventIDs: Set<UUID>? = nil) throws -> [GradedCopyRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try CatalogDatabase.writer(for: catalogURL).read { database in
            var records: [GradedCopyRecord] = []
            for row in try Row.fetchAll(database, sql: "SELECT event_id, record FROM graded_copies") {
                if let eventIDs {
                    guard let id = UUID(uuidString: row["event_id"]), eventIDs.contains(id) else { continue }
                }
                if let record = try? decoder.decode(GradedCopyRecord.self, from: Data((row["record"] as String).utf8)) {
                    records.append(record)
                }
            }
            guard !records.isEmpty, try database.tableExists(NASSyncStore.tableName) else { return records }
            var verified: Set<String> = []
            let keys = records.map(\.gradedKey)
            for start in stride(from: 0, to: keys.count, by: 500) {
                let batch = Array(keys[start..<min(start + 500, keys.count)])
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                for row in try Row.fetchAll(
                    database,
                    sql: "SELECT path_key FROM \(NASSyncStore.tableName) WHERE state = 'verified' AND path_key IN (\(marks))",
                    arguments: StatementArguments(batch)
                ) {
                    verified.insert(row["path_key"])
                }
            }
            return records.map { record in
                var marked = record
                marked.isOnNAS = verified.contains(record.gradedKey)
                return marked
            }
        }
    }

    /// The records of these events, or none when the catalog cannot be read.
    public static func existingRecords(catalogURL: URL, eventIDs: Set<UUID>?) -> [GradedCopyRecord] {
        guard FileManager.default.fileExists(atPath: catalogURL.path) else { return [] }
        return (try? GradedCopyStore(catalogURL: catalogURL).records(eventIDs: eventIDs)) ?? []
    }
}

/// A copy rendered straight into the NAS event's `Edited/Rec709`: re-read
/// from the NAS whole (a short read or a size change fails it), then written
/// down in `nas_sync_files` as verified, the way Sync records a file it
/// copied, so Sync never copies it again, catch-up never takes it for a
/// leftover, and NAS renames carry it with its event.
public enum GradedNASRecorder {
    public static func record(
        copyAt url: URL,
        eventID: UUID,
        locations: EventStorageLocations,
        store: NASSyncStore?,
        hasher: (String, Int64) throws -> String = { try NASFileIO.sha256($0, uncached: true, expectedByteCount: $1) },
        now: Date = Date()
    ) throws -> NASSyncRecord {
        guard let relative = locations.nasRelativePath(url.path) else {
            throw ToolkitError.commandFailed("\(url.lastPathComponent) is not under the NAS root.")
        }
        guard let entry = LayoutMigrationDisk.lstatEntry(url.path), entry.kind == .file, entry.size > 0 else {
            throw ToolkitError.commandFailed("\(url.lastPathComponent) is not on the NAS after its rename.")
        }
        let sha = try hasher(url.path, entry.size)
        guard let after = LayoutMigrationDisk.lstatEntry(url.path), after.size == entry.size else {
            throw ToolkitError.commandFailed("\(url.lastPathComponent) changed size while it was checked.")
        }
        let record = NASSyncRecord(
            nasRoot: locations.nasRoot.path,
            relativePath: relative,
            eventID: eventID,
            byteCount: entry.size,
            sourceModifiedAt: after.modifiedAt,
            sha256: sha,
            state: .verified,
            detail: "Graded copy rendered on the NAS",
            checkedAt: now,
            verifiedAt: now
        )
        try store?.upsert([record])
        return record
    }
}
