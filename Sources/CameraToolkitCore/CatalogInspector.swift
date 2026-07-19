import Foundation
import GRDB

public struct CatalogObject: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: String
    public var sql: String

    public init(name: String, kind: String, sql: String) {
        self.name = name
        self.kind = kind
        self.sql = sql
    }
}

public struct CatalogQueryResult: Equatable, Sendable {
    public var columns: [String]
    public var rows: [[String]]

    public init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }
}

public enum CatalogAssetLocation: String, CaseIterable, Equatable, Sendable {
    case source
    case buffer
    case archive
}

public enum CatalogPresenceState: Int, Equatable, Sendable {
    case unknown = 0
    case present = 1
    case missing = 2
    case unavailable = 3
}

public struct CatalogPresenceObservation: Equatable, Sendable {
    public var eventAssetID: String
    public var location: CatalogAssetLocation
    public var state: CatalogPresenceState
    public var checkedAt: Date

    public init(
        eventAssetID: String,
        location: CatalogAssetLocation,
        state: CatalogPresenceState,
        checkedAt: Date = Date()
    ) {
        self.eventAssetID = eventAssetID
        self.location = location
        self.state = state
        self.checkedAt = checkedAt
    }
}

public struct CatalogEventAsset: Equatable, Sendable {
    public var id: String
    public var assignment: PhotoEventAssignment
    public var sourcePresence: CatalogPresenceObservation?
    public var bufferPresence: CatalogPresenceObservation?
    public var archivePresence: CatalogPresenceObservation?

    public init(
        id: String,
        assignment: PhotoEventAssignment,
        sourcePresence: CatalogPresenceObservation? = nil,
        bufferPresence: CatalogPresenceObservation? = nil,
        archivePresence: CatalogPresenceObservation? = nil
    ) {
        self.id = id
        self.assignment = assignment
        self.sourcePresence = sourcePresence
        self.bufferPresence = bufferPresence
        self.archivePresence = archivePresence
    }
}

public struct ImmichCatalogStatus: Equatable, Sendable {
    public var eventAssetID: String
    public var status: String
    public var immichAssetID: String?
    public var checksumSHA1: String?
    public var isTrashed: Bool
    public var checkedAt: Date

    public init(
        eventAssetID: String,
        status: String,
        immichAssetID: String? = nil,
        checksumSHA1: String? = nil,
        isTrashed: Bool = false,
        checkedAt: Date = Date()
    ) {
        self.eventAssetID = eventAssetID
        self.status = status
        self.immichAssetID = immichAssetID
        self.checksumSHA1 = checksumSHA1
        self.isTrashed = isTrashed
        self.checkedAt = checkedAt
    }
}

/// Bounded catalog access backed by GRDB. Arbitrary inspector SQL stays
/// read-only; the explicit write methods persist only Camera Toolkit's own
/// presence and Immich cache records.
public struct CatalogInspector: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func objects() throws -> [CatalogObject] {
        try read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT name, type, COALESCE(sql, '') AS sql
                FROM sqlite_schema
                WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
                ORDER BY type, name COLLATE NOCASE
                """
            )
            return rows.map {
                CatalogObject(
                    name: $0["name"],
                    kind: $0["type"],
                    sql: $0["sql"]
                )
            }
        }
    }

    public func rows(in object: String, limit: Int = 200) throws -> CatalogQueryResult {
        let boundedLimit = min(max(limit, 1), 1_000)
        return try query("SELECT * FROM \(Self.quotedIdentifier(object)) LIMIT \(boundedLimit)")
    }

    public func query(_ sql: String, rowLimit: Int = 500) throws -> CatalogQueryResult {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isReadOnlyQuery(trimmed) else {
            throw ToolkitError.commandFailed("The in-app SQL inspector is read-only. Use SELECT, WITH, PRAGMA, or EXPLAIN.")
        }
        let boundedLimit = min(max(rowLimit, 1), 2_000)

        return try read { database in
            let statement = try database.makeStatement(sql: trimmed)
            let columns = statement.columnNames
            let cursor = try Row.fetchCursor(statement)
            var rows: [[String]] = []
            rows.reserveCapacity(boundedLimit)
            while rows.count < boundedLimit, let row = try cursor.next() {
                rows.append(row.map { _, value in Self.displayValue(value) })
            }
            return CatalogQueryResult(columns: columns, rows: rows)
        }
    }

    public func eventAssets(eventID: UUID) throws -> [CatalogEventAsset] {
        try read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT a.id, a.source_root_path, a.relative_path, a.byte_count,
                       a.modified_at, a.device_id,
                       CASE WHEN a.immich_upload_override IN (0, 1)
                            THEN CAST(a.immich_upload_override AS INTEGER)
                            ELSE NULL END AS immich_upload_override,
                       source.state AS source_state, source.checked_at AS source_checked_at,
                       buffer.state AS buffer_state, buffer.checked_at AS buffer_checked_at,
                       archive.state AS archive_state, archive.checked_at AS archive_checked_at
                FROM event_assets a
                LEFT JOIN event_asset_locations source
                  ON source.event_asset_id = a.id AND source.location = 'source'
                LEFT JOIN event_asset_locations buffer
                  ON buffer.event_asset_id = a.id AND buffer.location = 'buffer'
                LEFT JOIN event_asset_locations archive
                  ON archive.event_asset_id = a.id AND archive.location = 'archive'
                WHERE a.event_id = ?
                ORDER BY a.relative_path COLLATE NOCASE
                """,
                arguments: [eventID.uuidString]
            )
            let formatter = Self.isoFormatter()
            return rows.compactMap { row in
                let id: String = row["id"]
                let modifiedAt: String = row["modified_at"]
                guard let date = formatter.date(from: modifiedAt) else { return nil }
                let overrideValue: Int64? = row["immich_upload_override"]
                let assignment = PhotoEventAssignment(
                    sourceRootPath: row["source_root_path"],
                    relativePath: row["relative_path"],
                    fileSize: row["byte_count"],
                    modifiedAt: date,
                    eventID: eventID,
                    deviceID: Self.nonempty(row["device_id"] as String?),
                    immichUploadOverride: overrideValue.map { $0 != 0 }
                )
                return CatalogEventAsset(
                    id: id,
                    assignment: assignment,
                    sourcePresence: Self.presence(row: row, id: id, location: .source, formatter: formatter),
                    bufferPresence: Self.presence(row: row, id: id, location: .buffer, formatter: formatter),
                    archivePresence: Self.presence(row: row, id: id, location: .archive, formatter: formatter)
                )
            }
        }
    }

    public func savePresenceObservations(_ observations: [CatalogPresenceObservation]) throws {
        guard !observations.isEmpty else { return }
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        let formatter = Self.isoFormatter()
        try queue.write { database in
            for observation in observations {
                try database.execute(
                    sql: """
                    INSERT INTO event_asset_locations(event_asset_id, location, state, checked_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(event_asset_id, location) DO UPDATE SET
                        state = excluded.state,
                        checked_at = excluded.checked_at
                    """,
                    arguments: [
                        observation.eventAssetID,
                        observation.location.rawValue,
                        observation.state.rawValue,
                        formatter.string(from: observation.checkedAt)
                    ]
                )
            }
        }
    }

    public func immichStatuses(eventID: UUID) throws -> [String: ImmichCatalogStatus] {
        try read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT i.event_asset_id, i.status, i.immich_asset_id, i.checksum_sha1,
                       i.is_trashed, i.checked_at
                FROM immich_assets i
                JOIN event_assets a ON a.id = i.event_asset_id
                WHERE a.event_id = ?
                """,
                arguments: [eventID.uuidString]
            )
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let id: String = row["event_asset_id"]
                let checkedString: String = row["checked_at"]
                return (
                    id,
                    ImmichCatalogStatus(
                        eventAssetID: id,
                        status: row["status"],
                        immichAssetID: Self.nonempty(row["immich_asset_id"] as String?),
                        checksumSHA1: Self.nonempty(row["checksum_sha1"] as String?),
                        isTrashed: (row["is_trashed"] as Int64) != 0,
                        checkedAt: formatter.date(from: checkedString) ?? .distantPast
                    )
                )
            })
        }
    }

    public func saveImmichStatuses(_ statuses: [ImmichCatalogStatus]) throws {
        guard !statuses.isEmpty else { return }
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try queue.write { database in
            for status in statuses {
                try database.execute(
                    sql: """
                    INSERT INTO immich_assets(
                        event_asset_id, status, immich_asset_id, checksum_sha1,
                        is_trashed, checked_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(event_asset_id) DO UPDATE SET
                        status = excluded.status,
                        immich_asset_id = excluded.immich_asset_id,
                        checksum_sha1 = excluded.checksum_sha1,
                        is_trashed = excluded.is_trashed,
                        checked_at = excluded.checked_at
                    """,
                    arguments: [
                        status.eventAssetID,
                        status.status,
                        status.immichAssetID,
                        status.checksumSHA1,
                        status.isTrashed ? 1 : 0,
                        formatter.string(from: status.checkedAt)
                    ]
                )
            }
        }
    }

    public static func isReadOnlyQuery(_ sql: String) -> Bool {
        let first = sql
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first?
            .uppercased() ?? ""
        return ["SELECT", "WITH", "PRAGMA", "EXPLAIN"].contains(first)
    }

    private func read<T>(_ body: (Database) throws -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolkitError.commandFailed("The catalog does not exist yet. Prepare the Photo List first.")
        }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(2.5)
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return try queue.read(body)
    }

    private static func quotedIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func displayValue(_ value: DatabaseValue) -> String {
        switch value.storage {
        case .null: "NULL"
        case .int64(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): value
        case .blob(let value): "BLOB · \(value.count) bytes"
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func presence(
        row: Row,
        id: String,
        location: CatalogAssetLocation,
        formatter: ISO8601DateFormatter
    ) -> CatalogPresenceObservation? {
        let stateValue: Int64? = row["\(location.rawValue)_state"]
        let checkedAtValue: String? = row["\(location.rawValue)_checked_at"]
        guard let stateValue,
              let state = CatalogPresenceState(rawValue: Int(stateValue)),
              let checkedAtValue,
              let checkedAt = formatter.date(from: checkedAtValue)
        else { return nil }
        return CatalogPresenceObservation(
            eventAssetID: id,
            location: location,
            state: state,
            checkedAt: checkedAt
        )
    }

    private static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
