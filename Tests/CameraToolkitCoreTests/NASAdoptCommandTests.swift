@testable import CameraToolkitCore
import Foundation
import GRDB
import XCTest

/// `CameraToolkit --adopt-nas`: the sidebar's NAS adoption from a script,
/// planned read-only and executed only as reviewed.
final class NASAdoptCommandTests: XCTestCase {
    private struct World {
        var root: URL
        var support: URL
        var catalog: URL
        var nas: URL
        var configuration: AppConfiguration
        var trip: SavedCameraEvent
        var fullCard: SavedCameraEvent
        var tripRows: [PhotoEventAssignment]
        var cardFolder: URL { nas.appendingPathComponent("2026/2026-08-21 Trip/2026-08-22 Full Card/Originals/Sony A7V") }
        var backups: URL { support.appendingPathComponent("Backups", isDirectory: true) }

        func executor(appRunning: Bool = false) -> NASAdoptExecutor {
            NASAdoptExecutor(
                supportFolder: support,
                configurationURL: support.appendingPathComponent("config.json"),
                catalogURL: catalog,
                configuration: configuration,
                isAppRunning: { appRunning }
            )
        }
    }

    private func makeWorld(_ temporary: URL) throws -> World {
        let root = temporary.resolvingSymlinksInPath()
        let support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let catalog = support.appendingPathComponent("catalog.sqlite")
        var configuration = testConfiguration(root: root)
        configuration.catalogDatabasePath = catalog.path
        try JSONEncoder().encode(configuration).write(to: support.appendingPathComponent("config.json"))

        let trip = SavedCameraEvent(name: "Trip", eventDate: DateFormatter.yyyyMMdd.date(from: "2026-08-21")!)
        let fullCard = SavedCameraEvent(name: "Full Card", eventDate: DateFormatter.yyyyMMdd.date(from: "2026-08-22")!, parentEventID: trip.id)
        let nas = root.appendingPathComponent("Library", isDirectory: true)
        let tripCamera = nas.appendingPathComponent("2026/2026-08-21 Trip/Originals/Sony A7V")
        var tripRows: [PhotoEventAssignment] = []
        for relative in ["Exported/DSC00001.JPG", "Photos/DSC00001.ARW"] {
            try writeFile(tripCamera.appendingPathComponent(relative), "trip \(relative)")
            tripRows.append(PhotoEventAssignment(
                sourceRootPath: root.appendingPathComponent("Buffer/2026/2026-08-21 Trip/Originals/Sony A7V").path,
                relativePath: relative,
                fileSize: Int64("trip \(relative)".utf8.count),
                modifiedAt: Date(timeIntervalSince1970: 1_780_000_000),
                eventID: trip.id,
                deviceID: "sony-a7v"
            ))
        }
        try CatalogStore(url: catalog).prepareSchema()
        _ = try CatalogStateStore(url: catalog).migrate(
            state: CatalogOwnedState(savedEvents: [trip, fullCard], photoEventAssignments: tripRows, displayOrientations: [:], burstSplits: []),
            configurationURL: nil,
            backups: CatalogBackupService(catalogURL: catalog, configurationURL: nil, localFolder: root.appendingPathComponent("Setup Backups"), remoteFolder: nil)
        )
        CatalogDatabase.checkpointAndClose(url: catalog)
        let world = World(root: root, support: support, catalog: catalog, nas: nas, configuration: configuration, trip: trip, fullCard: fullCard, tripRows: tripRows)
        try writeFile(world.cardFolder.appendingPathComponent("DSC00001.ARW"), "card frame 1")
        try writeFile(world.cardFolder.appendingPathComponent("101MSDCF/DSC00001.ARW"), "card frame 1, second folder")
        try writeFile(world.cardFolder.appendingPathComponent("DSC00001.xmp"), "<xmp/>")
        try writeFile(world.cardFolder.appendingPathComponent("._DSC00001.ARW"), "apple double")
        try writeFile(nas.appendingPathComponent("2026/2026-09-01 Beach Day/Originals/Sony A7V/DSC00009.ARW"), "beach")
        return world
    }

    private func catalogState(_ world: World) throws -> (state: CatalogOwnedState, digest: String) {
        try NASAdoptPlanner.readCatalog(world.catalog)
    }

    func testDryRunWritesNothingAndExecuteAddsExactlyThePlannedRows() throws {
        try withTemporaryDirectory { temporary in
            let world = try makeWorld(temporary)
            let treeBefore = try treeBytes(world.root)
            let nasBefore = try treeBytes(world.nas)
            let planURL = world.root.appendingPathComponent("Plans/plan.json")
            try FileManager.default.createDirectory(at: planURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var output: [String] = []
            let status = NASAdoptCommand.run(
                arguments: [
                    "CameraToolkit", "--adopt-nas", "--dry-run", "--support-dir", world.support.path,
                    "--folder", "2026/2026-08-21 Trip/2026-08-22 Full Card", "--json", planURL.path,
                ],
                environment: [:],
                defaultSupportFolder: world.support,
                output: { output.append($0) }
            )
            XCTAssertEqual(status, 0, output.joined(separator: "\n"))
            // `-shm` is SQLite's shared-memory index, which any reader updates.
            func data(_ tree: [String: Data]) -> [String: Data] {
                tree.filter { !$0.key.hasSuffix("/Plans/plan.json") && !$0.key.hasSuffix("-shm") }
            }
            XCTAssertEqual(data(try treeBytes(world.root)), data(treeBefore), "the dry run wrote nothing but its plan")
            XCTAssertTrue(output.joined(separator: "\n").contains("→ event Trip / Full Card [\(world.fullCard.id.uuidString)]"))

            let plan = try NASAdoptPlan.read(planURL)
            XCTAssertEqual(plan.folders.map(\.relativeFolderPath), ["2026/2026-08-21 Trip/2026-08-22 Full Card"])
            XCTAssertEqual(plan.newEvents, [])
            XCTAssertEqual(Set(plan.rows.map(\.assignment.relativePath)), ["DSC00001.ARW", "101MSDCF/DSC00001.ARW", "DSC00001.xmp"])
            XCTAssertTrue(plan.rows.allSatisfy { $0.assignment.eventID == world.fullCard.id })

            let before = try catalogState(world)
            let report = try world.executor().execute(plan)
            XCTAssertEqual(report.assignmentsAdded, 3)
            XCTAssertEqual(report.eventsAdded, 0)
            XCTAssertEqual(report.counts["event_assets"]?.before, 2)
            XCTAssertEqual(report.counts["event_assets"]?.after, 5)
            let after = try catalogState(world)
            XCTAssertEqual(after.state.savedEvents, before.state.savedEvents)
            XCTAssertEqual(
                Set(after.state.photoEventAssignments.map(CatalogStore.eventAssetID)),
                Set((world.tripRows + plan.rows.map(\.assignment)).map(CatalogStore.eventAssetID))
            )
            XCTAssertEqual(after.state.photoEventAssignments.filter { $0.eventID == world.trip.id }, world.tripRows)
            XCTAssertEqual(CatalogBackupService(catalogURL: world.catalog, configurationURL: nil, localFolder: world.backups, remoteFolder: nil)
                .manifests(in: world.backups).map(\.id), [report.backupID])
            // Media untouched; the folder is no longer offered.
            XCTAssertEqual(try treeBytes(world.nas), nasBefore)
            XCTAssertFalse(try world.executor().plan(folders: plan.requestedFolders).isExecutable)
        }
    }

    func testExecuteRefusesWhenAListingChangedSinceThePlan() throws {
        try withTemporaryDirectory { temporary in
            let world = try makeWorld(temporary)
            let plan = try world.executor().plan(folders: ["2026/2026-08-21 Trip/2026-08-22 Full Card"])
            XCTAssertTrue(plan.isExecutable)
            try writeFile(world.cardFolder.appendingPathComponent("DSC00002.ARW"), "a frame that arrived later")
            let digest = try catalogState(world).digest

            XCTAssertThrowsError(try world.executor().execute(plan)) { error in
                XCTAssertTrue(error.localizedDescription.contains("changed since the plan was made"), error.localizedDescription)
            }
            XCTAssertEqual(try catalogState(world).digest, digest)
            XCTAssertFalse(FileManager.default.fileExists(atPath: world.backups.path))
        }
    }

    func testExecuteRefusesWhileTheAppRuns() throws {
        try withTemporaryDirectory { temporary in
            let world = try makeWorld(temporary)
            let plan = try world.executor().plan(folders: [])
            XCTAssertEqual(plan.folders.count, 2)
            let digest = try catalogState(world).digest

            XCTAssertThrowsError(try world.executor(appRunning: true).execute(plan)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Camera Toolkit is running"), error.localizedDescription)
            }
            XCTAssertEqual(try catalogState(world).digest, digest)
            XCTAssertFalse(FileManager.default.fileExists(atPath: world.backups.path))
        }
    }

    func testAWriteThatFailsItsChecksIsRolledBack() throws {
        try withTemporaryDirectory { temporary in
            let world = try makeWorld(temporary)
            let plan = try world.executor().plan(folders: [])
            XCTAssertEqual(plan.newEvents.map(\.name), ["Beach Day"])
            let digest = try catalogState(world).digest
            var executor = world.executor()
            executor.beforeValidation = { db in
                try db.execute(sql: "INSERT INTO display_orientations(file_key, quarter_turns, updated_at) VALUES ('stray', 1, 'now')")
            }

            XCTAssertThrowsError(try executor.execute(plan)) { error in
                XCTAssertTrue(error.localizedDescription.contains("rolled back"), error.localizedDescription)
            }
            XCTAssertEqual(try catalogState(world).digest, digest)
        }
    }

    func testParsingKeepsExecuteToExactlyThePlan() throws {
        XCTAssertEqual(
            try NASAdoptCommand.parse(["x", "--adopt-nas", "--dry-run", "--folder", "2026/a", "--folder", "2026/b"]).mode,
            .dryRun(folders: ["2026/a", "2026/b"], jsonPath: nil)
        )
        XCTAssertEqual(try NASAdoptCommand.parse(["x", "--adopt-nas", "--execute", "--plan", "p.json"]).mode, .execute(planPath: "p.json"))
        XCTAssertThrowsError(try NASAdoptCommand.parse(["x", "--adopt-nas", "--execute", "--plan", "p.json", "--folder", "2026/a"]))
        XCTAssertThrowsError(try NASAdoptCommand.parse(["x", "--adopt-nas", "--execute"]))
        XCTAssertThrowsError(try NASAdoptCommand.parse(["x", "--adopt-nas", "--dry-run", "--execute", "--plan", "p.json"]))
    }
}
