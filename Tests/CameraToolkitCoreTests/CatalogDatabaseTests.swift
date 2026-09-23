@testable import CameraToolkitCore
import Foundation
import GRDB
import XCTest

final class CatalogDatabaseTests: XCTestCase {
    func testBootstrapPutsALocalCatalogInWALWithNormalSync() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: .testConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )

            let writer = try CatalogDatabase.writer(for: catalog)
            XCTAssertTrue(writer is DatabasePool, "a local catalog gets concurrent WAL readers")
            try writer.read { database in
                XCTAssertEqual(try String.fetchOne(database, sql: "PRAGMA journal_mode"), "wal")
                // 1 = NORMAL
                XCTAssertEqual(try Int.fetchOne(database, sql: "PRAGMA synchronous"), 1)
                XCTAssertEqual(try Int.fetchOne(database, sql: "PRAGMA foreign_keys"), 1)
            }
            try writer.write { database in
                XCTAssertEqual(try Int.fetchOne(database, sql: "PRAGMA busy_timeout"), 5_000)
            }
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testSharedWriterIsReusedPerFileAndReopenedWhenTheFileIsReplaced() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            let first = try CatalogDatabase.writer(for: catalog)
            let again = try CatalogDatabase.writer(for: root.appendingPathComponent("./catalog.sqlite"))
            XCTAssertTrue(first === again, "one connection per catalog file")

            try first.write { try $0.execute(sql: "CREATE TABLE marker(id INTEGER)") }
            CatalogDatabase.checkpointAndClose(url: catalog)
            try FileManager.default.removeItem(at: catalog)

            let reopened = try CatalogDatabase.writer(for: catalog)
            XCTAssertFalse(first === reopened)
            let tables = try reopened.read {
                try String.fetchAll($0, sql: "SELECT name FROM sqlite_schema WHERE type = 'table'")
            }
            XCTAssertFalse(tables.contains("marker"), "a replaced file must not be served by the old connection")
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testCheckpointAtQuitLeavesTheMainFileComplete() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: .testConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            let store = FaceIndexStore(url: catalog)
            _ = try store.createPerson(name: "Ada", isRoster: true)
            let wal = URL(fileURLWithPath: catalog.path + "-wal")

            CatalogDatabase.checkpointAndCloseAll()

            let walSize = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertEqual(walSize, 0, "a TRUNCATE checkpoint empties the WAL")
            // Copy only the main file: everything must already be in it.
            let copy = root.appendingPathComponent("copy.sqlite")
            try FileManager.default.copyItem(at: catalog, to: copy)
            let names = try DatabaseQueue(path: copy.path).read {
                try String.fetchAll($0, sql: "SELECT name FROM people")
            }
            XCTAssertEqual(names, ["Ada"])
        }
    }

    func testFaceStoresOverTheSameFileShareOneConnection() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(
                configuration: .testConfiguration(root: root, catalog: catalog),
                createBackup: false,
                createLibraryFolders: false
            )
            let person = try FaceIndexStore(url: catalog).createPerson(name: "Grace", isRoster: true)
            // A second store — a fresh scan service's — sees the committed
            // row through the same shared connection.
            XCTAssertEqual(try FaceIndexStore(url: catalog).person(person.id)?.name, "Grace")
            CatalogDatabase.checkpointAndClose(url: catalog)
        }
    }

    func testLocalFolderSupportsWAL() {
        XCTAssertTrue(CatalogDatabase.supportsWAL(at: FileManager.default.temporaryDirectory.appendingPathComponent("x.sqlite")))
    }
}

extension AppConfiguration {
    static func testConfiguration(root: URL, catalog: URL) -> AppConfiguration {
        AppConfiguration(
            demoRootPath: root.appendingPathComponent("Demo").path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path,
            bufferPath: root.appendingPathComponent("Buffer").path,
            cameraLibraryRootPath: root.appendingPathComponent("Library").path,
            catalogDatabasePath: catalog.path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path
        )
    }
}
