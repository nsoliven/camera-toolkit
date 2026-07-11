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

    public func bootstrap(configuration: AppConfiguration) throws -> CatalogBootstrapReport {
        let folders = try ensureLibraryFolders(configuration: configuration)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            throw ToolkitError.commandFailed("Could not open catalog database: \(message)")
        }
        defer { sqlite3_close(database) }

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
        """, database: database)

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

        let backupURL = try backupIfConfigured(configuration: configuration)
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
