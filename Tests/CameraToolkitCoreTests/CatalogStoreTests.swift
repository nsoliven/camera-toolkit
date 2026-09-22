import CameraToolkitCore
import Foundation
import SQLite3
import XCTest

final class CatalogStoreTests: XCTestCase {
    func testLocalCatalogSyncDoesNotTouchConfiguredLibraryFolders() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("Catalog/catalog.sqlite")
            let library = root.appendingPathComponent("Slow Library", isDirectory: true)
            let configuration = AppConfiguration(
                demoRootPath: root.appendingPathComponent("Demo").path,
                importSourcePath: root.appendingPathComponent("Card").path,
                archivePath: library.appendingPathComponent("Originals").path,
                bufferPath: root.appendingPathComponent("Buffer").path,
                cameraLibraryRootPath: library.path,
                catalogDatabasePath: catalog.path,
                activityLogPath: root.appendingPathComponent("activity.jsonl").path
            )

            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: configuration,
                createBackup: false,
                createLibraryFolders: false
            )

            XCTAssertTrue(FileManager.default.fileExists(atPath: catalog.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
            XCTAssertEqual(
                try integerValue("SELECT COUNT(*) FROM sqlite_schema WHERE name = 'event_asset_locations'", database: catalog),
                1
            )
        }
    }

    func testOfflineConfiguredVolumeDoesNotBlockLocalCatalogSchema() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            let missingVolume = "/Volumes/CameraToolkit-Definitely-Not-Mounted/Camera"
            let configuration = AppConfiguration(
                demoRootPath: root.appendingPathComponent("Demo").path,
                importSourcePath: root.appendingPathComponent("Card").path,
                archivePath: missingVolume + "/Originals",
                bufferPath: root.appendingPathComponent("Buffer").path,
                cameraLibraryRootPath: missingVolume,
                catalogDatabasePath: catalog.path,
                catalogBackupFolderPath: missingVolume + "/_Manifests/backups",
                activityLogPath: root.appendingPathComponent("activity.jsonl").path
            )

            let report = try CatalogStore(url: catalog).bootstrap(configuration: configuration)

            XCTAssertTrue(FileManager.default.fileExists(atPath: catalog.path))
            XCTAssertNil(report.backupPath)
            XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM sqlite_schema WHERE name = 'events'", database: catalog), 1)
        }
    }

    func testLargeEventSyncDoesNotHitSQLiteVariableLimitAndPrunesStaleAssignments() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            let event = SavedCameraEvent(name: "Large Event", eventDate: Date(timeIntervalSince1970: 1_752_124_800))
            let assignments = (0..<1_050).map { index in
                PhotoEventAssignment(
                    sourceRootPath: root.appendingPathComponent("Card").path,
                    relativePath: String(format: "DCIM/DSC%05d.ARW", index),
                    fileSize: Int64(index + 1),
                    modifiedAt: Date(timeIntervalSince1970: Double(1_752_124_800 + index)),
                    eventID: event.id,
                    deviceID: "sony-a7v"
                )
            }
            var configuration = AppConfiguration(
                demoRootPath: root.appendingPathComponent("Demo").path,
                importSourcePath: root.appendingPathComponent("Card").path,
                archivePath: root.appendingPathComponent("Library/Originals").path,
                bufferPath: root.appendingPathComponent("Buffer").path,
                cameraLibraryRootPath: root.appendingPathComponent("Library").path,
                catalogDatabasePath: catalog.path,
                activityLogPath: root.appendingPathComponent("activity.jsonl").path,
                savedEvents: [event],
                selectedEventID: event.id,
                photoEventAssignments: assignments
            )

            _ = try CatalogStore(url: catalog).bootstrap(configuration: configuration, createBackup: false)
            XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM event_assets", database: catalog), 1_050)

            configuration.photoEventAssignments = Array(assignments.prefix(10))
            _ = try CatalogStore(url: catalog).bootstrap(configuration: configuration, createBackup: false)
            XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM event_assets", database: catalog), 10)
        }
    }

    func testBootstrapCreatesLibraryFoldersDatabaseRowsAndBackup() throws {
        try withTemporaryDirectory { root in
            let libraryRoot = root.appendingPathComponent("Camera", isDirectory: true)
            let catalog = root.appendingPathComponent("catalog.sqlite")
            let backupRoot = libraryRoot
                .appendingPathComponent("_Manifests", isDirectory: true)
                .appendingPathComponent("CameraToolkit", isDirectory: true)
                .appendingPathComponent("catalog-backups", isDirectory: true)
            let source = root.appendingPathComponent("Card", isDirectory: true)
            let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)

            var configuration = AppConfiguration(
                demoRootPath: root.appendingPathComponent("Safety Test", isDirectory: true).path,
                importSourcePath: source.path,
                archivePath: libraryRoot.appendingPathComponent("Originals", isDirectory: true).path,
                bufferPath: buffer.path,
                cameraLibraryRootPath: libraryRoot.path,
                catalogDatabasePath: catalog.path,
                catalogBackupFolderPath: backupRoot.path,
                activityLogPath: root.appendingPathComponent("activity-log.jsonl").path
            )
            configuration.configuredLocations = [
                ConfiguredLocation(role: .importSource, name: "Card", path: source.path),
                ConfiguredLocation(role: .archive, name: "Library Originals", path: configuration.archivePath),
                ConfiguredLocation(role: .buffer, name: "Buffer", path: buffer.path)
            ]
            configuration.normalizeLocationSelections()

            let report = try CatalogStore(url: catalog).bootstrap(configuration: configuration)

            XCTAssertTrue(FileManager.default.fileExists(atPath: catalog.path))
            XCTAssertEqual(report.storageLocationCount, 3)
            XCTAssertNotNil(report.backupPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: report.backupPath ?? ""))
            for folder in CameraLibraryFolder.allCases {
                XCTAssertTrue(FileManager.default.fileExists(atPath: configuration.libraryFolderPath(folder).path))
            }
            XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM storage_locations", database: catalog), 3)
            XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM library_folders", database: catalog), CameraLibraryFolder.allCases.count)
        }
    }

    func testBootstrapAddsParentEventIDToExistingCatalogs() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            // A catalog written before subevents existed: `events` has no
            // parent_event_id column.
            var legacy: OpaquePointer?
            XCTAssertEqual(sqlite3_open(catalog.path, &legacy), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(
                legacy,
                """
                CREATE TABLE events(
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
                """,
                nil, nil, nil
            ), SQLITE_OK)
            sqlite3_close(legacy)

            let parent = SavedCameraEvent(name: "PHIL2026", eventDate: Date(timeIntervalSince1970: 1_787_414_400))
            let child = SavedCameraEvent(name: "Matcha", eventDate: Date(timeIntervalSince1970: 1_787_414_400), parentEventID: parent.id)
            var configuration = testConfiguration(root: root)
            configuration.savedEvents = [parent, child]

            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: configuration,
                createBackup: false,
                createLibraryFolders: false
            )

            XCTAssertEqual(
                try stringValue("SELECT parent_event_id FROM events WHERE id = '\(child.id.uuidString)'", database: catalog),
                parent.id.uuidString
            )
            XCTAssertNil(try stringValue("SELECT parent_event_id FROM events WHERE id = '\(parent.id.uuidString)'", database: catalog))
        }
    }

    private func integerValue(_ sql: String, database url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw XCTSkip("Could not open catalog database")
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw XCTSkip("Could not prepare catalog query")
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func stringValue(_ sql: String, database url: URL) throws -> String? {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw XCTSkip("Could not open catalog database")
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw XCTSkip("Could not prepare catalog query")
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: text)
    }
}
