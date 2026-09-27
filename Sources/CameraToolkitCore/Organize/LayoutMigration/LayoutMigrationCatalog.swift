import Foundation
import GRDB

/// The catalog rows the layout migration reads and rewrites, read in one
/// transaction so the plan and its digest describe one consistent state.
///
/// Path-keyed stores in the catalog, and how the migration treats them:
///
/// - `event_assets` — `id` is `CatalogStore.eventAssetID`, built from
///   `source_root_path` + `relative_path`. Rows adopted from a legacy
///   `Card Copy` (their source root *is* the drive folder) get the new
///   root; rows whose drive copy is implied (source root is where the file
///   was imported from) change only when the file is renamed with `(N)`.
///   A changed id moves its `event_asset_locations` and `immich_assets`
///   children with it.
/// - `face_photos.path_key` / `path` / `file_name` and `faces.photo_id` —
///   re-keyed when the photo row's path is a moved file; a row at a stale
///   path whose file identity is a renamed file follows the new name.
/// - `display_orientations.file_key` — name + size + mtime, so only a
///   `(N)` rename needs a copy under the new name.
/// - `burst_splits.member_path_keys` — lowercased paths, rewritten.
/// - `file_instances` / `assets` — relative to a storage location, never a
///   `Card Copy` path the app writes; untouched and counted.
public enum LayoutMigrationCatalog {
    /// Tables whose row counts the commit re-checks.
    public static let countedTables = [
        "events", "event_assets", "event_asset_locations", "immich_assets",
        "face_photos", "faces", "people", "face_templates", "face_rejections",
        "display_orientations", "burst_splits", "file_instances", "assets",
    ]

    public static let markerKey = "layoutMigration"

    public struct FacePhotoRow: Equatable, Sendable {
        public var pathKey: String
        public var path: String
        public var fileName: String
        public var byteCount: Int64
        public var modifiedAt: Date
        public var faceCount: Int
        public var confirmedFaceCount: Int

        public var fileKey: String {
            FaceIndexStore.fileKey(fileName: fileName, byteCount: byteCount, modifiedAt: modifiedAt)
        }
    }

    public struct Snapshot: Sendable {
        public var ownsState: Bool
        public var state: CatalogOwnedState
        public var facePhotos: [FacePhotoRow]
        public var tableCounts: [String: Int]
        public var confirmedFaces: Int
        public var digest: String
    }

    /// Opens `catalogURL` read-only and reads a snapshot. Nothing is written.
    public static func snapshot(catalogURL: URL) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            throw ToolkitError.commandFailed("There is no catalog at \(catalogURL.path).")
        }
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: catalogURL.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { try snapshot(database: $0) }
    }

    public static func snapshot(database: Database) throws -> Snapshot {
        let owns = try CatalogStateStore.ownsState(database)
        let state = owns ? try CatalogStateStore.load(database) : CatalogOwnedState()
        var counts: [String: Int] = [:]
        for table in countedTables where try database.tableExists(table) {
            counts[table] = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
        }
        var photos: [FacePhotoRow] = []
        var confirmed = 0
        if try database.tableExists("face_photos"), try database.tableExists("faces") {
            let confirmedByPhoto = Dictionary(uniqueKeysWithValues: try Row.fetchAll(
                database,
                sql: "SELECT photo_id, COUNT(*) AS n FROM faces WHERE state = 'confirmed' GROUP BY photo_id"
            ).map { (($0["photo_id"] as String), ($0["n"] as Int)) })
            let totalByPhoto = Dictionary(uniqueKeysWithValues: try Row.fetchAll(
                database,
                sql: "SELECT photo_id, COUNT(*) AS n FROM faces GROUP BY photo_id"
            ).map { (($0["photo_id"] as String), ($0["n"] as Int)) })
            confirmed = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM faces WHERE state = 'confirmed'") ?? 0
            for row in try Row.fetchAll(
                database,
                sql: "SELECT path_key, path, file_name, byte_count, modified_at FROM face_photos ORDER BY path_key"
            ) {
                let key: String = row["path_key"]
                let modified: String = row["modified_at"]
                photos.append(FacePhotoRow(
                    pathKey: key,
                    path: row["path"],
                    fileName: row["file_name"],
                    byteCount: row["byte_count"],
                    modifiedAt: FaceIndexStore.parseTimestamp(modified) ?? .distantPast,
                    faceCount: totalByPhoto[key] ?? 0,
                    confirmedFaceCount: confirmedByPhoto[key] ?? 0
                ))
            }
        }
        return Snapshot(
            ownsState: owns,
            state: state,
            facePhotos: photos,
            tableCounts: counts,
            confirmedFaces: confirmed,
            digest: try digest(database: database)
        )
    }

    /// SHA-256 over every row the migration reads to plan or rewrites:
    /// events, assignment identities and paths, face photo keys and
    /// identities, confirmed faces, rotations, and burst splits. Presence
    /// and Immich rows are left out — the app refreshes them on its own,
    /// and the migration only re-points their ids.
    public static func digest(database: Database) throws -> String {
        var text = ""
        func add(_ sql: String, _ columns: Int) throws {
            text += "#\(sql)\n"
            for row in try Row.fetchAll(database, sql: sql) {
                text += (0..<columns).map { index -> String in
                    let value: DatabaseValue = row[index]
                    switch value.storage {
                    case .null: return "∅"
                    case .int64(let number): return String(number)
                    case .double(let number): return String(number)
                    case .string(let string): return string
                    case .blob(let data): return data.base64EncodedString()
                    }
                }.joined(separator: "\u{1F}")
                text += "\n"
            }
        }
        if try database.tableExists("events") {
            try add("SELECT id, payload FROM events ORDER BY id", 2)
        }
        if try database.tableExists("event_assets") {
            try add("SELECT id, event_id, source_root_path, relative_path, device_id FROM event_assets ORDER BY id", 5)
        }
        if try database.tableExists("face_photos") {
            try add("SELECT path_key, path, file_name, byte_count, modified_at FROM face_photos ORDER BY path_key", 5)
        }
        if try database.tableExists("faces") {
            try add("SELECT id, photo_id FROM faces WHERE state = 'confirmed' ORDER BY id", 2)
        }
        if try database.tableExists("display_orientations") {
            try add("SELECT file_key, quarter_turns FROM display_orientations ORDER BY file_key", 2)
        }
        if try database.tableExists("burst_splits") {
            try add("SELECT id, member_path_keys FROM burst_splits ORDER BY id", 2)
        }
        return LayoutMigrationHash.sha256(text)
    }
}
