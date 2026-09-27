@testable import CameraToolkitCore
import Foundation
import GRDB
import XCTest

/// SMB-portable path components: the rule itself, the NAS paths presence
/// and Sync to NAS compute with it, and the NAS layout migration rewriting
/// an assignment whose relative path SMB cannot store.
final class PortablePathTests: XCTestCase {
    // MARK: - The rule

    func testUnsafeComponentsAreRewrittenStablyAndPortableOnesAreKept() {
        let cases: [(String, String)] = [
            ("Library w: Friend", "Library with Friend"),
            ("W: Guests", "With Guests"),
            ("Trip w:", "Trip with"),
            ("Draw:ing", "Draw - ing"),
            ("Time 12 : 30", "Time 12 - 30"),
            ("Part: Two", "Part - Two"),
            ("say \"hi\"", "say 'hi'"),
            ("a*b?c<d>e|f\\g", "a-b-c-d-e-f-g"),
            ("Ends with dot.", "Ends with dot"),
            ("Ends with space ", "Ends with space"),
            (":leading", "- leading"),
            ("...", "_"),
            ("Plain Name", "Plain Name"),
            ("a - b", "a - b"),
            (" leading space kept", " leading space kept"),
            ("wow:", "wow -"),
        ]
        for (input, expected) in cases {
            let sanitized = PortablePath.sanitize(component: input)
            XCTAssertEqual(sanitized, expected, input)
            XCTAssertTrue(PortablePath.isPortable(component: sanitized), input)
            XCTAssertEqual(PortablePath.sanitize(component: sanitized), sanitized, "idempotent: \(input)")
        }
        XCTAssertEqual(
            PortablePath.sanitize(relativePath: "DCIM/CAM_001/Library w: Friend/CAM_0001.OSV"),
            "DCIM/CAM_001/Library with Friend/CAM_0001.OSV"
        )
        XCTAssertEqual(PortablePath.sanitize(relativePath: "DCIM/100MSDCF/DSC0001.ARW"), "DCIM/100MSDCF/DSC0001.ARW")
        XCTAssertFalse(PortablePath.isPortable(relativePath: "a/b:c/d"))
        XCTAssertFalse(PortablePath.isPortable(relativePath: "a./d"))
        XCTAssertTrue(PortablePath.isPortable(relativePath: "a/b - c/d.jpg"))
    }

    // MARK: - Presence and Sync to NAS agree

    func testPresenceAndSyncComputeTheSameNASPathForASanitizedComponent() throws {
        try withTemporaryDirectory { root in
            var configuration = testConfiguration(root: root)
            let event = SavedCameraEvent(name: "Trip", eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-05-02")))
            configuration.savedEvents = [event]
            let locations = EventStorageLocations(configuration: configuration)
            let relative = "DCIM/CAM_001/Library w: Friend/CAM_0001.OSV"
            let assignment = PhotoEventAssignment(
                sourceRootPath: root.appendingPathComponent("Card").path, relativePath: relative,
                fileSize: 4, modifiedAt: Date(), eventID: event.id, deviceID: "osmo-360"
            )
            let expected = "2026/2026-05-02 Trip/Originals/Osmo 360/DCIM/CAM_001/Library with Friend/CAM_0001.OSV"
            let layout = locations.layout(for: event, deviceID: "osmo-360")
            XCTAssertEqual(try layout.mirrorRelativePath(for: relative), expected)
            XCTAssertEqual(
                layout.requiredFolders(for: [relative]),
                ["2026/2026-05-02 Trip/Originals/Osmo 360", "2026/2026-05-02 Trip/Originals/Osmo 360/DCIM/CAM_001/Library with Friend"]
            )
            let archive = try XCTUnwrap(locations.archiveURL(for: assignment, event: event))
            XCTAssertEqual(archive.path, locations.nasRoot.appendingPathComponent(expected).path)

            // The drive keeps the name as the app wrote it (APFS stores the
            // `:`); Sync to NAS copies it to the path presence looks at.
            let drive = try XCTUnwrap(locations.driveURL(for: assignment, event: event, policy: .buffer))
            try writeFile(drive, "osv!")
            XCTAssertEqual(locations.nasMirrorURL(forDrivePath: drive.path)?.path, archive.path)
            let plan = NASSyncPlanner.plan(events: [event], locations: locations, checkLegacyLayout: false)
            XCTAssertEqual(plan.items.map(\.relativePath), [expected])
            XCTAssertEqual(plan.items.first?.sourcePath, drive.path)
            XCTAssertTrue(plan.refused.isEmpty)

            try FileManager.default.createDirectory(at: locations.nasRoot, withIntermediateDirectories: true)
            let report = try NASSyncService(store: nil).sync(plan, nasRoot: locations.nasRoot)
            XCTAssertEqual(report.copied.count + report.matchedExisting.count, 1, "\(report)")
            XCTAssertEqual(FileManager.default.contents(atPath: archive.path), Data("osv!".utf8))
        }
    }

    // MARK: - NAS layout migration

    private struct Fixture {
        var library: URL
        var support: URL
        var configurationURL: URL
        var catalogURL: URL
        var configuration: AppConfiguration
        var mapping: NASLayoutMapping
        var event: SavedCameraEvent
        var assignments: [PhotoEventAssignment]

        func plan() throws -> NASLayoutMigrationPlan {
            try NASLayoutMigrationPlanner().plan(.init(
                mapping: mapping, configuration: configuration, supportFolder: support,
                configurationURL: configurationURL, catalogURL: catalogURL
            ))
        }

        func executor() -> NASLayoutMigrationExecutor {
            NASLayoutMigrationExecutor(
                supportFolder: support, configurationURL: configurationURL, catalogURL: catalogURL,
                configuration: configuration, verifySamples: 2, isAppRunning: { false }
            )
        }

        func path(_ relative: String) -> String { library.appendingPathComponent(relative).path }
    }

    private static let oldFolder = "2026/2026-05-02 old-trip/Originals"
    private static let newFolder = "2026/2026-05-02 New Trip/Originals"
    private static let subfolder = "DCIM/CAM_001/Library w: Friend"
    private static let portableSubfolder = "DCIM/CAM_001/Library with Friend"

    /// A NAS library already in the mirror layout, whose Osmo files sit
    /// flat at `Originals/Osmo 360/` because the app's path
    /// (`…/DCIM/CAM_001/Library w: Friend/…`) could not be used; a Sony
    /// file already where the app looks; a face on the OSV; presence rows.
    private func fixture(_ root: URL) throws -> Fixture {
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let files: [(String, String)] = [
            ("\(Self.oldFolder)/Osmo 360/CAM_0001.OSV", "osv one"),
            ("\(Self.oldFolder)/Osmo 360/CAM_0001.LRF", "lrf one!"),
            ("\(Self.oldFolder)/Sony A7V/DCIM/100MSDCF/DSC0001.ARW", "sony raw"),
        ]
        for (path, text) in files { try writeFile(library.appendingPathComponent(path), text) }

        let catalogURL = support.appendingPathComponent("catalog.sqlite")
        var configuration = AppConfiguration.testConfiguration(root: root, catalog: catalogURL)
        configuration.cameraLibraryRootPath = library.path
        configuration.archiveLayoutRootPath = library.path
        let configurationURL = support.appendingPathComponent("config.json")
        try JSONEncoder().encode(configuration).write(to: configurationURL)
        try CatalogStore(url: catalogURL).prepareSchema()

        let event = SavedCameraEvent(name: "old-trip", eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-05-02")))
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let assignments = [
            PhotoEventAssignment(sourceRootPath: "/Volumes/Card360", relativePath: "\(Self.subfolder)/CAM_0001.OSV", fileSize: 7, modifiedAt: date, eventID: event.id, deviceID: "osmo-360"),
            PhotoEventAssignment(sourceRootPath: "/Volumes/Card360", relativePath: "\(Self.subfolder)/CAM_0001.LRF", fileSize: 8, modifiedAt: date, eventID: event.id, deviceID: "osmo-360"),
            PhotoEventAssignment(sourceRootPath: "/Volumes/CardA", relativePath: "DCIM/100MSDCF/DSC0001.ARW", fileSize: 8, modifiedAt: date, eventID: event.id, deviceID: "sony-a7v"),
        ]
        _ = try CatalogStateStore(url: catalogURL).migrate(
            state: CatalogOwnedState(savedEvents: [event], photoEventAssignments: assignments),
            configurationURL: nil,
            backups: CatalogBackupService(catalogURL: catalogURL, configurationURL: nil, localFolder: support.appendingPathComponent("Backups"), remoteFolder: nil)
        )
        let osv = library.appendingPathComponent("\(Self.oldFolder)/Osmo 360/CAM_0001.OSV").path
        let now = ISO8601DateFormatter().string(from: Date())
        try CatalogDatabase.writer(for: catalogURL).write { db in
            try db.execute(sql: "INSERT INTO people(id, name, is_roster, face_count, created_at, updated_at) VALUES ('P1', 'Person A', 1, 1, ?, ?)", arguments: [now, now])
            try db.execute(
                sql: """
                INSERT INTO face_photos(path_key, path, file_name, byte_count, modified_at, scan_grade, face_count, engine, indexed_at, updated_at)
                VALUES (?, ?, 'CAM_0001.OSV', 7, ?, 'med', 1, 'insightface/buffalo_l', ?, ?)
                """,
                arguments: [EventStorageLocations.pathKey(osv), osv, now, now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO faces(id, photo_id, person_id, box_x, box_y, box_w, box_h, det_score, state, created_at, updated_at)
                VALUES ('F1', ?, 'P1', 0.1, 0.1, 0.2, 0.2, 0.9, 'confirmed', ?, ?)
                """,
                arguments: [EventStorageLocations.pathKey(osv), now, now]
            )
            for assignment in assignments {
                for location in ["source", "archive"] {
                    try db.execute(
                        sql: "INSERT INTO event_asset_locations(event_asset_id, location, state, checked_at) VALUES (?, ?, 1, ?)",
                        arguments: [CatalogStore.eventAssetID(assignment), location, now]
                    )
                }
            }
        }
        CatalogDatabase.checkpointAndClose(url: catalogURL)

        let mapping = NASLayoutMapping(
            legacyRoot: library.path,
            mirrorRoot: library.path,
            events: [],
            files: [
                .init(source: "\(Self.oldFolder)/Osmo 360/CAM_0001.OSV", byteCount: 7, destination: "\(Self.newFolder)/Osmo 360/\(Self.portableSubfolder)/CAM_0001.OSV"),
                .init(source: "\(Self.oldFolder)/Osmo 360/CAM_0001.LRF", byteCount: 8, destination: "\(Self.newFolder)/Osmo 360/\(Self.portableSubfolder)/CAM_0001.LRF"),
                .init(source: "\(Self.oldFolder)/Sony A7V/DCIM/100MSDCF/DSC0001.ARW", byteCount: 8, destination: "\(Self.newFolder)/Sony A7V/DCIM/100MSDCF/DSC0001.ARW"),
            ],
            eventRenames: [.init(event: event.id.uuidString, name: "New Trip")]
        )
        return Fixture(
            library: library, support: support, configurationURL: configurationURL, catalogURL: catalogURL,
            configuration: configuration, mapping: mapping, event: event, assignments: assignments
        )
    }

    func testTheMigrationMovesFilesToThePortablePathAndRewritesTheirAssignmentsWithFacesAndPresenceKept() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let plan = try f.plan()
            XCTAssertTrue(plan.isExecutable, plan.blockers.joined(separator: "\n"))
            XCTAssertEqual(plan.summary.conflicts, 0)
            let attached = try XCTUnwrap(plan.catalog.attachedEvents?.first)
            XCTAssertEqual(attached.matched, 3)
            XCTAssertEqual(attached.sanitized, 2)
            XCTAssertEqual(attached.keptNonPortable, 0)
            XCTAssertEqual(attached.alreadyAligned, 3, "the CSV already names the portable path")
            let rewrites = try XCTUnwrap(plan.catalog.assignmentRewrites)
            XCTAssertEqual(Set(rewrites.map(\.newRelativePath)), ["\(Self.portableSubfolder)/CAM_0001.OSV", "\(Self.portableSubfolder)/CAM_0001.LRF"])
            XCTAssertTrue(rewrites.allSatisfy { $0.newSourceRootPath == $0.oldSourceRootPath })
            XCTAssertEqual(plan.catalog.facePhotoRewrites.count, 1)

            // A CSV that leaves the files flat is aligned to the portable path.
            var flat = f
            flat.mapping.files?[0].destination = "\(Self.newFolder)/Osmo 360/CAM_0001.OSV"
            flat.mapping.files?[1].destination = "\(Self.newFolder)/Osmo 360/CAM_0001.LRF"
            let aligned = try flat.plan()
            XCTAssertTrue(aligned.isExecutable, aligned.blockers.joined(separator: "\n"))
            XCTAssertEqual(
                Set(aligned.allMoves.map { String($0.destination.dropFirst(f.library.path.count + 1)) }),
                Set(plan.allMoves.map { String($0.destination.dropFirst(f.library.path.count + 1)) })
            )

            let facesBefore = try CatalogDatabase.writer(for: f.catalogURL).read { db in
                try Row.fetchAll(db, sql: "SELECT id, person_id, state FROM faces ORDER BY id").map { "\($0["id"] as String)|\($0["person_id"] as String)|\($0["state"] as String)" }
            }
            let locationCount = try CatalogDatabase.writer(for: f.catalogURL).read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM event_asset_locations") }

            let report = try f.executor().execute(plan)
            XCTAssertTrue(report.succeeded, report.text)
            let journalURL = try XCTUnwrap(report.journalURL)
            XCTAssertNil(LayoutMigrationDisk.lstatEntry(f.path("2026/2026-05-02 old-trip")), "the emptied old folder is removed")

            // The app, reading the catalog, finds every file on the NAS.
            let state = try CatalogStateStore(url: f.catalogURL).load()
            let event = try XCTUnwrap(state.savedEvents.first { $0.id == f.event.id })
            XCTAssertEqual(event.name, "New Trip")
            var configuration = f.configuration
            configuration.savedEvents = state.savedEvents
            let locations = EventStorageLocations(configuration: configuration)
            XCTAssertEqual(state.photoEventAssignments.count, 3)
            for assignment in state.photoEventAssignments {
                XCTAssertTrue(PortablePath.isPortable(relativePath: assignment.relativePath), assignment.relativePath)
                let archive = try XCTUnwrap(locations.archiveURL(for: assignment, event: event))
                XCTAssertEqual(LayoutMigrationDisk.lstatEntry(archive.path)?.kind, .file, archive.path)
            }
            let osv = try XCTUnwrap(state.photoEventAssignments.first { $0.relativePath.hasSuffix(".OSV") })
            XCTAssertEqual(osv.sourceRootPath, "/Volumes/Card360")
            XCTAssertEqual(osv.relativePath, "\(Self.portableSubfolder)/CAM_0001.OSV")
            XCTAssertEqual(osv.fileSize, f.assignments[0].fileSize)
            XCTAssertEqual(osv.deviceID, "osmo-360")

            try CatalogDatabase.writer(for: f.catalogURL).read { db in
                // Ids are the path: each row's id is the one its new path
                // gives, the old id is gone, and presence rows followed.
                let ids = try String.fetchAll(db, sql: "SELECT id FROM event_assets ORDER BY id")
                XCTAssertEqual(ids, state.photoEventAssignments.map(CatalogStore.eventAssetID).sorted())
                XCTAssertFalse(ids.contains(CatalogStore.eventAssetID(f.assignments[0])))
                XCTAssertTrue(ids.contains(CatalogStore.eventAssetID(f.assignments[2])), "the Sony row keeps its id")
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_asset_locations"), locationCount)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_asset_locations WHERE event_asset_id NOT IN (SELECT id FROM event_assets)"), 0)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_asset_locations WHERE event_asset_id = ?", arguments: [CatalogStore.eventAssetID(osv)]), 2)
                // Faces keep their ids, people and states; the photo row
                // follows the file.
                let faces = try Row.fetchAll(db, sql: "SELECT id, person_id, state FROM faces ORDER BY id").map { "\($0["id"] as String)|\($0["person_id"] as String)|\($0["state"] as String)" }
                XCTAssertEqual(faces, facesBefore)
                let newOSV = f.path("\(Self.newFolder)/Osmo 360/\(Self.portableSubfolder)/CAM_0001.OSV")
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT photo_id FROM faces WHERE id = 'F1'"), EventStorageLocations.pathKey(newOSV))
                XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            }

            // Undo puts back the files and the original rows.
            let undone = try f.executor().undo(journalURL: journalURL)
            XCTAssertTrue(undone.succeeded, undone.text)
            XCTAssertNotNil(LayoutMigrationDisk.lstatEntry(f.path("\(Self.oldFolder)/Osmo 360/CAM_0001.OSV")))
            let restored = try CatalogStateStore(url: f.catalogURL).load()
            XCTAssertEqual(Set(restored.photoEventAssignments.map(\.relativePath)), Set(f.assignments.map(\.relativePath)))
        }
    }

    func testARenameInsideTheMirrorLayoutIsAllowedButOverlappingFoldersAreRefused() {
        let rename = NASLayoutMapping.fileProblems([
            .init(source: "2026/2026-05-02 old/Originals/Cam/A.JPG", byteCount: 1, destination: "2026/2026-05-02 New/Originals/Cam/A.JPG"),
        ])
        XCTAssertEqual(rename, [])
        let inside = NASLayoutMapping.fileProblems([
            .init(source: "2026/2026-05-02 old/Originals/Cam/A.JPG", byteCount: 1, destination: "2026/2026-05-02 old/Originals/Cam/Sub/A.JPG"),
        ])
        XCTAssertTrue(inside.contains { $0.contains("holds sources") }, inside.joined(separator: "\n"))
        let above = NASLayoutMapping.fileProblems([
            .init(source: "2026/2026-05-02 old/Originals/Cam/A.JPG", byteCount: 1, destination: "2026/2026-05-02 old/A.JPG"),
        ])
        XCTAssertTrue(above.contains { $0.contains("holds sources") }, above.joined(separator: "\n"))
        let legacy = NASLayoutMapping.fileProblems([
            .init(source: "Originals/2026/Trip/A.JPG", byteCount: 1, destination: "Originals/2026/Elsewhere/A.JPG"),
        ])
        XCTAssertTrue(legacy.contains { $0.contains("inside the legacy tree") })
    }
}
