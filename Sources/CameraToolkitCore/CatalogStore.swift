import Foundation
import SQLite3

public struct CatalogBootstrapReport: Codable, Equatable, Sendable {
    public var databasePath: String
    public var backupPath: String?
    public var libraryFolders: [String]
    public var storageLocationCount: Int

    public init(databasePath: String, backupPath: String?, libraryFolders: [String], storageLocationCount: Int) {
        self.databasePath = databasePath
        self.backupPath = backupPath
        self.libraryFolders = libraryFolders
        self.storageLocationCount = storageLocationCount
    }
}

public struct CatalogStore {
    public let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func bootstrap(
        configuration: AppConfiguration,
        createBackup: Bool = true,
        createLibraryFolders: Bool = true
    ) throws -> CatalogBootstrapReport {
        let folders = createLibraryFolders ? try ensureLibraryFolders(configuration: configuration) : []
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            throw ToolkitError.commandFailed("Could not open catalog database: \(message)")
        }
        defer { sqlite3_close(database) }
        // Catalog work always runs away from the main actor. A short wait is
        // preferable to dropping a cache update when a read-only inspector has
        // the local database open for a moment.
        sqlite3_busy_timeout(database, 5_000)

        try execute("""
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS app_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS storage_locations (
            id TEXT PRIMARY KEY,
            role TEXT NOT NULL,
            name TEXT NOT NULL,
            path TEXT NOT NULL,
            selected INTEGER NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS library_folders (
            kind TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS import_batches (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            source_location_id TEXT,
            archive_location_id TEXT,
            created_at TEXT NOT NULL,
            FOREIGN KEY(source_location_id) REFERENCES storage_locations(id),
            FOREIGN KEY(archive_location_id) REFERENCES storage_locations(id)
        );
        CREATE TABLE IF NOT EXISTS assets (
            id TEXT PRIMARY KEY,
            relative_path TEXT NOT NULL,
            sha256 TEXT,
            byte_count INTEGER NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS file_instances (
            id TEXT PRIMARY KEY,
            asset_id TEXT,
            storage_location_id TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            sha256 TEXT,
            observed_at TEXT NOT NULL,
            FOREIGN KEY(asset_id) REFERENCES assets(id),
            FOREIGN KEY(storage_location_id) REFERENCES storage_locations(id)
        );
        CREATE TABLE IF NOT EXISTS events (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            event_date TEXT NOT NULL,
            immich_upload_enabled INTEGER NOT NULL DEFAULT 0,
            immich_album_policy TEXT NOT NULL DEFAULT 'none',
            immich_album_name TEXT,
            created_at TEXT NOT NULL,
            last_used_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS event_assets (
            id TEXT PRIMARY KEY,
            event_id TEXT NOT NULL,
            source_root_path TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            modified_at TEXT NOT NULL,
            device_id TEXT,
            immich_upload_override INTEGER,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(event_id) REFERENCES events(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS event_assets_event_id ON event_assets(event_id);
        CREATE TABLE IF NOT EXISTS event_asset_locations (
            event_asset_id TEXT NOT NULL,
            location TEXT NOT NULL CHECK(location IN ('source', 'buffer', 'archive')),
            state INTEGER NOT NULL,
            checked_at TEXT NOT NULL,
            PRIMARY KEY(event_asset_id, location),
            FOREIGN KEY(event_asset_id) REFERENCES event_assets(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS immich_assets (
            event_asset_id TEXT PRIMARY KEY,
            status TEXT NOT NULL,
            immich_asset_id TEXT,
            checksum_sha1 TEXT,
            is_trashed INTEGER NOT NULL DEFAULT 0,
            checked_at TEXT NOT NULL,
            FOREIGN KEY(event_asset_id) REFERENCES event_assets(id) ON DELETE CASCADE
        );
        """, database: database)

        try execute("BEGIN IMMEDIATE;", database: database)
        do {
            try upsertAppState("cameraLibraryRootPath", value: configuration.cameraLibraryRootPath, database: database)
            try upsertAppState("archivePath", value: configuration.archivePath, database: database)
            try upsertAppState("bufferPath", value: configuration.bufferPath, database: database)
            try upsertAppState("catalogBackupFolderPath", value: configuration.catalogBackupFolderPath, database: database)

            for folder in CameraLibraryFolder.allCases {
                try upsertLibraryFolder(folder, path: configuration.libraryFolderPath(folder).path, database: database)
            }

            for location in configuration.configuredLocations {
                let selected = configuration.selectedLocationID(for: location.role) == location.id
                try upsertStorageLocation(location, selected: selected, database: database)
            }

            try synchronizeEvents(configuration: configuration, database: database)
            try execute("COMMIT;", database: database)
        } catch {
            try? execute("ROLLBACK;", database: database)
            throw error
        }

        let backupURL = createBackup ? try backupIfConfigured(configuration: configuration) : nil
        return CatalogBootstrapReport(
            databasePath: url.path,
            backupPath: backupURL?.path,
            libraryFolders: folders.map(\.path),
            storageLocationCount: configuration.configuredLocations.count
        )
    }

    private func ensureLibraryFolders(configuration: AppConfiguration) throws -> [URL] {
        guard !configuration.cameraLibraryRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        var folders: [URL] = []
        let root = URL(fileURLWithPath: configuration.cameraLibraryRootPath, isDirectory: true)
        // Never manufacture a fake /Volumes mount point when a NAS or removable
        // drive is offline. The local SQLite catalog must remain usable anyway.
        guard Self.configuredVolumeIsAvailable(for: root, fileManager: fileManager) else {
            return []
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        folders.append(root)

        for folder in CameraLibraryFolder.allCases {
            let url = configuration.libraryFolderPath(folder)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            folders.append(url)
        }
        return folders
    }

    private func backupIfConfigured(configuration: AppConfiguration) throws -> URL? {
        let backupPath = configuration.catalogBackupFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !backupPath.isEmpty, fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let backupRoot = URL(fileURLWithPath: backupPath, isDirectory: true)
        guard Self.configuredVolumeIsAvailable(for: backupRoot, fileManager: fileManager) else {
            return nil
        }
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let stamp = Self.backupTimestamp()
        let destination = backupRoot.appendingPathComponent("catalog-\(stamp).sqlite")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw ToolkitError.commandFailed("Catalog SQL failed: \(message)")
        }
    }

    private func upsertAppState(_ key: String, value: String, database: OpaquePointer) throws {
        try runUpsert(
            """
            INSERT INTO app_state(key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;
            """,
            values: [key, value, Self.isoTimestamp()],
            database: database
        )
    }

    private func upsertLibraryFolder(_ folder: CameraLibraryFolder, path: String, database: OpaquePointer) throws {
        try runUpsert(
            """
            INSERT INTO library_folders(kind, path, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(kind) DO UPDATE SET path = excluded.path, updated_at = excluded.updated_at;
            """,
            values: [folder.rawValue, path, Self.isoTimestamp()],
            database: database
        )
    }

    private func upsertStorageLocation(_ location: ConfiguredLocation, selected: Bool, database: OpaquePointer) throws {
        try runUpsert(
            """
            INSERT INTO storage_locations(id, role, name, path, selected, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                role = excluded.role,
                name = excluded.name,
                path = excluded.path,
                selected = excluded.selected,
                updated_at = excluded.updated_at;
            """,
            values: [
                location.id.uuidString,
                location.role.rawValue,
                location.name,
                location.path,
                selected ? "1" : "0",
                Self.isoTimestamp()
            ],
            database: database
        )
    }

    private func synchronizeEvents(configuration: AppConfiguration, database: OpaquePointer) throws {
        let now = Self.isoTimestamp()
        let eventsByID = Dictionary(uniqueKeysWithValues: configuration.savedEvents.map { ($0.id, $0) })

        for event in configuration.savedEvents {
            try runUpsert(
                """
                INSERT INTO events(
                    id, name, event_date, immich_upload_enabled, immich_album_policy,
                    immich_album_name, created_at, last_used_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    event_date = excluded.event_date,
                    immich_upload_enabled = excluded.immich_upload_enabled,
                    immich_album_policy = excluded.immich_album_policy,
                    immich_album_name = excluded.immich_album_name,
                    last_used_at = excluded.last_used_at,
                    updated_at = excluded.updated_at;
                """,
                values: [
                    event.id.uuidString,
                    event.name,
                    Self.isoTimestamp(event.eventDate),
                    event.sendsToImmich ? "1" : "0",
                    event.resolvedImmichAlbumPolicy.rawValue,
                    event.immichAlbumName ?? "",
                    Self.isoTimestamp(event.createdAt),
                    Self.isoTimestamp(event.lastUsedAt),
                    now
                ],
                database: database
            )
        }

        for assignment in configuration.photoEventAssignments where eventsByID[assignment.eventID] != nil {
            try runUpsert(
                """
                INSERT INTO event_assets(
                    id, event_id, source_root_path, relative_path, byte_count,
                    modified_at, device_id, immich_upload_override, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    event_id = excluded.event_id,
                    source_root_path = excluded.source_root_path,
                    relative_path = excluded.relative_path,
                    byte_count = excluded.byte_count,
                    modified_at = excluded.modified_at,
                    device_id = excluded.device_id,
                    immich_upload_override = excluded.immich_upload_override,
                    updated_at = excluded.updated_at;
                """,
                values: [
                    Self.eventAssetID(assignment),
                    assignment.eventID.uuidString,
                    assignment.sourceRootPath,
                    assignment.relativePath,
                    String(assignment.fileSize),
                    Self.isoTimestamp(assignment.modifiedAt),
                    assignment.deviceID ?? "",
                    assignment.immichUploadOverride.map { $0 ? "1" : "0" } ?? "",
                    now
                ],
                database: database
            )
        }

        try deleteRowsNotIn(
            table: "event_assets",
            ids: configuration.photoEventAssignments.map(Self.eventAssetID),
            database: database
        )
        try deleteRowsNotIn(
            table: "events",
            ids: configuration.savedEvents.map { $0.id.uuidString },
            database: database
        )
    }

    private func deleteRowsNotIn(table: String, ids: [String], database: OpaquePointer) throws {
        guard table == "events" || table == "event_assets" else { return }
        if ids.isEmpty {
            try execute("DELETE FROM \(table);", database: database)
            return
        }
        // A temporary key table avoids SQLite's bound-variable limit for large
        // events with thousands of photos.
        let temporaryTable = table == "events" ? "active_event_ids" : "active_event_asset_ids"
        try execute(
            "CREATE TEMP TABLE IF NOT EXISTS \(temporaryTable) (id TEXT PRIMARY KEY); DELETE FROM \(temporaryTable);",
            database: database
        )
        for id in ids {
            try runUpsert(
                "INSERT OR IGNORE INTO \(temporaryTable)(id) VALUES (?);",
                values: [id],
                database: database
            )
        }
        try execute(
            "DELETE FROM \(table) WHERE id NOT IN (SELECT id FROM \(temporaryTable)); DROP TABLE \(temporaryTable);",
            database: database
        )
    }

    private func runUpsert(_ sql: String, values: [String], database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ToolkitError.commandFailed("Could not prepare catalog statement: \(String(cString: sqlite3_errmsg(database)))")
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ToolkitError.commandFailed("Could not write catalog row: \(String(cString: sqlite3_errmsg(database)))")
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func isoTimestamp() -> String {
        isoTimestamp(Date())
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func eventAssetID(_ assignment: PhotoEventAssignment) -> String {
        [
            assignment.eventID.uuidString,
            assignment.sourceRootPath,
            assignment.relativePath,
            String(assignment.fileSize),
            String(Int64(assignment.modifiedAt.timeIntervalSince1970.rounded()))
        ].joined(separator: "|")
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func configuredVolumeIsAvailable(for url: URL, fileManager: FileManager) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return true }
        let mountURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            .appendingPathComponent(components[2], isDirectory: true)
        return fileManager.fileExists(atPath: mountURL.path)
    }
}
