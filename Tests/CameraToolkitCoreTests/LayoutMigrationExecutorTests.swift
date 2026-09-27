import CameraToolkitCore
import Foundation
import GRDB
import XCTest

final class LayoutMigrationExecutorTests: XCTestCase {
    private struct SimulatedCrash: Error {}

    private func executor(_ fixture: LayoutMigrationFixture, hooks: LayoutMigrationExecutor.Hooks = .init(), running: Bool = false) -> LayoutMigrationExecutor {
        LayoutMigrationExecutor(
            supportFolder: fixture.support,
            configurationURL: fixture.configurationURL,
            catalogURL: fixture.catalogURL,
            isAppRunning: { running },
            hooks: hooks
        )
    }

    /// Everything the catalog holds that the migration may touch, in a
    /// comparable form (timestamps left out).
    private struct CatalogImage: Equatable {
        var state: CatalogOwnedState
        var facePhotos: [String]
        var faces: [String]
        var templates: [String]
        var locations: [String]
        var immich: [String]
        var digest: String
    }

    private func catalogImage(_ fixture: LayoutMigrationFixture) throws -> CatalogImage {
        try fixture.readCatalog { db in
            CatalogImage(
                state: try CatalogStateStoreProbe.load(db),
                facePhotos: try String.fetchAll(db, sql: "SELECT path_key || '|' || path || '|' || file_name FROM face_photos ORDER BY path_key"),
                faces: try String.fetchAll(db, sql: "SELECT id || '|' || photo_id || '|' || state || '|' || IFNULL(person_id, '') FROM faces ORDER BY id"),
                templates: try String.fetchAll(db, sql: "SELECT person_id || '|' || face_id FROM face_templates ORDER BY face_id"),
                locations: try String.fetchAll(db, sql: "SELECT event_asset_id || '|' || location FROM event_asset_locations ORDER BY event_asset_id"),
                immich: try String.fetchAll(db, sql: "SELECT event_asset_id || '|' || status FROM immich_assets ORDER BY event_asset_id"),
                digest: try LayoutMigrationCatalogProbe.digest(db)
            )
        }
    }

    // MARK: - A full run

    func testExecuteMovesEveryFileAndRewritesTheCatalogInOneVerifiedStep() throws {
        try withTemporaryDirectory { root in
            let fixture = try LayoutMigrationFixture.make(in: root)
            let plan = try fixture.plan()
            let report = try executor(fixture).execute(plan)
            XCTAssertTrue(report.succeeded, report.text)
            XCTAssertEqual(report.phase, .completed)

            // Files: every planned file at its destination, same inode.
            for move in plan.allMoves {
                XCTAssertFalse(FileManager.default.fileExists(atPath: move.source), move.source)
                var info = stat()
                XCTAssertEqual(lstat(move.destination, &info), 0, move.destination)
                XCTAssertEqual(UInt64(info.st_ino), move.inode, move.destination)
            }
            let originals = fixture.parentFolder.appendingPathComponent("Originals")
            XCTAssertEqual(try String(contentsOf: originals.appendingPathComponent("Sony A7V/DSC00002 (2).ARW"), encoding: .utf8), "raw-two")
            XCTAssertEqual(try String(contentsOf: originals.appendingPathComponent("Sony A7V/DSC00002.ARW"), encoding: .utf8), "an older raw-two already migrated")
            XCTAssertEqual(try String(contentsOf: originals.appendingPathComponent("Osmo 360/CAM_0001 (2).OSV"), encoding: .utf8), "osv-b-different")
            XCTAssertEqual(try String(contentsOf: originals.appendingPathComponent("Osmo 360/._CAM_0001 (2).OSV"), encoding: .utf8), "appledouble-b")
            // Emptied legacy folders are gone; one holding a file stays.
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sonyCardCopy.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.osmoCardCopy.deletingLastPathComponent().path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parentFolder.appendingPathComponent("Sony A7V/readme.txt").path))
            XCTAssertTrue(report.text.contains("kept \(fixture.parentFolder.appendingPathComponent("Sony A7V").path)"), report.text)
            // Left-in-place folders were not touched.
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.parentFolder.appendingPathComponent("Photomator/edit.jpg").path))
            // Only the odd junk folder's legacy camera folder is left, untouched.
            XCTAssertEqual(try DriveEventDiscovery.cameraFolders(driveRoot: fixture.buffer).filter { $0.layout == .legacyCardCopy }.map(\.cameraFolderPath), [
                fixture.buffer.appendingPathComponent("2026/2026-08-23 Unparsed A7V/Sony A7V").path,
            ])
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.buffer.appendingPathComponent("2026/2026-08-23 Unparsed A7V/Sony A7V/Card Copy/.DS_Store").path))
            XCTAssertTrue(try DriveEventDiscovery.cameraFolders(driveRoot: fixture.privateRoot).allSatisfy { $0.layout == .originals })

            // Catalog.
            try fixture.readCatalog { db in
                XCTAssertEqual(try String.fetchAll(db, sql: "PRAGMA integrity_check"), ["ok"])
                XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM faces WHERE state = 'confirmed'"), 3)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_assets"), 7)
                let driveKey = EventStorageLocations.pathKey(originals.appendingPathComponent("Sony A7V/DSC00001.ARW").path)
                XCTAssertEqual(try String.fetchAll(db, sql: "SELECT id FROM faces WHERE photo_id = ? ORDER BY id", arguments: [driveKey]), ["F-B1", "F-B2"])
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM face_templates WHERE face_id = 'F-B1'"), 1)
                XCTAssertEqual(
                    try String.fetchOne(db, sql: "SELECT file_name FROM face_photos WHERE path_key = ?", arguments: [
                        EventStorageLocations.pathKey(fixture.unsorted.appendingPathComponent("Transfer 2/DSC00002.ARW").path),
                    ]),
                    "DSC00002 (2).ARW"
                )
                XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'layoutMigration'"))
            }
            let state = try CatalogStateStore(url: fixture.catalogURL).load()
            var adopted = fixture.adoptedSony
            adopted.sourceRootPath = originals.appendingPathComponent("Sony A7V").path
            XCTAssertTrue(state.photoEventAssignments.contains(adopted))
            XCTAssertFalse(state.photoEventAssignments.contains(fixture.adoptedSony))
            try fixture.readCatalog { db in
                // Presence and Immich rows followed the new id.
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_asset_locations WHERE event_asset_id = ?", arguments: [CatalogStore.eventAssetID(adopted)]), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM immich_assets WHERE event_asset_id = ?", arguments: [CatalogStore.eventAssetID(adopted)]), 1)
            }
            var renamed = fixture.appliedRenamed
            renamed.relativePath = "DSC00002 (2).ARW"
            XCTAssertTrue(state.photoEventAssignments.contains(renamed))
            XCTAssertEqual(state.displayOrientations[FaceIndexStore.fileKey(fileName: "DSC00002 (2).ARW", byteCount: 7, modifiedAt: LayoutMigrationFixture.fixedDate)], 1)
            XCTAssertEqual(state.burstSplits.first?.memberPathKeys.first, EventStorageLocations.pathKey(originals.appendingPathComponent("Sony A7V/DSC00001.ARW").path))

            // Presence works against the new layout: every file but the
            // missing one is on the drive, none through the legacy fallback.
            var configuration = fixture.configuration
            state.apply(to: &configuration)
            let locations = EventStorageLocations(configuration: configuration)
            for event in [fixture.parent, fixture.child] {
                let summary = try XCTUnwrap(EventPresenceScanner.scan(
                    event: event,
                    assignments: state.photoEventAssignments.filter { $0.eventID == event.id },
                    locations: locations
                ))
                XCTAssertEqual(summary.onLegacyLayout, 0)
                XCTAssertEqual(summary.missingEverywhere, event.id == fixture.parent.id ? 1 : 0)
                XCTAssertEqual(summary.onDrive + summary.onOtherDrive, summary.total - summary.missingEverywhere)
            }

            // Stores.
            let cache = CaptureDateCache(url: fixture.support.appendingPathComponent("capture-dates.json"))
            XCTAssertTrue(cache.cachedPaths.contains(originals.appendingPathComponent("Sony A7V/DSC00001.ARW").path))
            XCTAssertFalse(cache.cachedPaths.contains(fixture.sonyCardCopy.appendingPathComponent("DSC00001.ARW").path))
            let trash = MediaTrashService(removedFilesRoot: fixture.trashRoot)
            let batch = try XCTUnwrap(trash.listBatches(under: [fixture.trashRoot]).first)
            let restore = trash.restore(batch: batch)
            XCTAssertEqual(restore.restored, [originals.appendingPathComponent("Sony A7V/DSC08937.ARW").path])
            XCTAssertNotNil(DriveMoveService.layoutMigrationBarrier(in: fixture.support.appendingPathComponent("Move Journals")))
        }
    }

    // MARK: - Refusals

    func testRefusesWhileTheAppRunsAndWhenTheDriveOrCatalogChanged() throws {
        try withTemporaryDirectory { root in
            let fixture = try LayoutMigrationFixture.make(in: root)
            let plan = try fixture.plan()
            let before = try fixture.driveTree()

            XCTAssertThrowsError(try executor(fixture, running: true).execute(plan)) { error in
                XCTAssertTrue(error.localizedDescription.contains("running"), error.localizedDescription)
            }

            // A new file inside a Card Copy.
            try writeFile(fixture.sonyCardCopy.appendingPathComponent("DSC09999.ARW"), "new since the plan")
            XCTAssertThrowsError(try executor(fixture).execute(plan)) { error in
                XCTAssertTrue(error.localizedDescription.contains("changed since the plan"), error.localizedDescription)
            }
            try FileManager.default.removeItem(at: fixture.sonyCardCopy.appendingPathComponent("DSC09999.ARW"))

            // A source file rewritten (same size, new inode).
            let victim = fixture.osmoCardCopy.appendingPathComponent("CAM_0001.LRF")
            try FileManager.default.removeItem(at: victim)
            try writeFile(victim, "lrf-a")
            try FileManager.default.setAttributes([.modificationDate: LayoutMigrationFixture.fixedDate], ofItemAtPath: victim.path)
            XCTAssertThrowsError(try executor(fixture).execute(plan))

            // The catalog changed.
            let fresh = try fixture.plan()
            let writer = try CatalogDatabase.writer(for: fixture.catalogURL)
            try writer.write { try $0.execute(sql: "UPDATE face_photos SET file_name = 'x' WHERE file_name = 'other.ARW'") }
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
            XCTAssertThrowsError(try executor(fixture).execute(fresh)) { error in
                XCTAssertTrue(error.localizedDescription.contains("catalog"), error.localizedDescription)
            }
            // Nothing moved through any of it, and no journal was left.
            var expected = before
            expected["Buffer/2026/2026-08-23 Trip 2026/DJI Osmo 360/Card Copy/CAM_0001.LRF"] = nil
            var now = try fixture.driveTree()
            now["Buffer/2026/2026-08-23 Trip 2026/DJI Osmo 360/Card Copy/CAM_0001.LRF"] = nil
            XCTAssertEqual(now, expected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.support.appendingPathComponent("Layout Migrations").appendingPathComponent("x").path))
        }
    }

    func testExclusiveRenamesNeverReplaceAFileThatAppearsMidRun() throws {
        try withTemporaryDirectory { root in
            let fixture = try LayoutMigrationFixture.make(in: root)
            let plan = try fixture.plan()
            // Right after the first rename, something else writes a file at
            // a later destination.
            let intruder = fixture.parentFolder.appendingPathComponent("Originals/Sony A7V/notes.txt")
            let hooks = LayoutMigrationExecutor.Hooks(afterMove: { count in
                if count == 1 { try writeFile(intruder, "someone else's file") }
            })
            let report = try executor(fixture, hooks: hooks).execute(plan)
            XCTAssertFalse(report.succeeded)
            XCTAssertEqual(try String(contentsOf: intruder, encoding: .utf8), "someone else's file")
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sonyCardCopy.appendingPathComponent("notes.txt").path))
            let journalURL = try XCTUnwrap(report.journalURL)

            // Resume refuses while both exist; after the owner moves the
            // intruder away it finishes.
            let blocked = try executor(fixture).resume(journalURL: journalURL)
            XCTAssertFalse(blocked.succeeded)
            try FileManager.default.moveItem(at: intruder, to: root.appendingPathComponent("intruder.txt"))
            let resumed = try executor(fixture).resume(journalURL: journalURL)
            XCTAssertTrue(resumed.succeeded, resumed.text)
            XCTAssertEqual(try String(contentsOf: intruder, encoding: .utf8), "unknown to the catalog")
        }
    }

    // MARK: - Crash and resume

    func testResumeAfterAnInterruptionAtEachBoundaryReachesTheSameEndState() throws {
        let reference = try withTemporaryDirectory { root -> (tree: [String], image: CatalogImage) in
            let fixture = try LayoutMigrationFixture.make(in: root)
            XCTAssertTrue(try executor(fixture).execute(try fixture.plan()).succeeded)
            return (try relativeTree(fixture), try normalized(catalogImage(fixture), fixture))
        }
        typealias Point = (name: String, hooks: LayoutMigrationExecutor.Hooks)
        let points: [Point] = [
            ("after the journal", .init(afterJournal: { throw SimulatedCrash() })),
            ("after 3 renames", .init(afterMove: { if $0 == 3 { throw SimulatedCrash() } })),
            ("after 11 renames", .init(afterMove: { if $0 == 11 { throw SimulatedCrash() } })),
            ("after a folder", .init(afterFolder: { if $0 == "F0002" { throw SimulatedCrash() } })),
            ("after all renames", .init(afterMoves: { throw SimulatedCrash() })),
            ("inside the catalog transaction", .init(beforeCatalogValidation: { _ in throw SimulatedCrash() })),
            ("after the catalog commit", .init(afterCatalogCommit: { throw SimulatedCrash() })),
            ("after the stores", .init(afterStores: { throw SimulatedCrash() })),
        ]
        for point in points {
            try withTemporaryDirectory { root in
                let fixture = try LayoutMigrationFixture.make(in: root)
                let plan = try fixture.plan()
                var journalURL: URL?
                do {
                    let report = try executor(fixture, hooks: point.hooks).execute(plan)
                    XCTAssertFalse(report.succeeded, point.name)
                    journalURL = report.journalURL
                } catch is SimulatedCrash {
                    journalURL = try latestJournal(fixture)
                }
                // A second execute refuses while the first is unfinished.
                XCTAssertThrowsError(try executor(fixture).execute(plan), point.name)
                let resumed = try executor(fixture).resume(journalURL: try XCTUnwrap(journalURL, point.name))
                XCTAssertTrue(resumed.succeeded, "\(point.name): \(resumed.text)")
                assertTree(try relativeTree(fixture), reference.tree, point.name)
                XCTAssertEqual(try normalized(catalogImage(fixture), fixture), reference.image, point.name)
            }
        }
    }

    /// The commit landed but the process died before the journal said so:
    /// the catalog's marker row keeps resume from rewriting it twice.
    func testResumeDoesNotRepeatACommitTheJournalMissed() throws {
        try withTemporaryDirectory { root in
            let fixture = try LayoutMigrationFixture.make(in: root)
            let plan = try fixture.plan()
            let report = try executor(fixture, hooks: .init(afterCatalogCommit: { throw SimulatedCrash() })).execute(plan)
            let journalURL = try XCTUnwrap(report.journalURL)
            var journal = try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as! [String: Any]
            journal["phase"] = "movesVerified"
            journal["catalogCommittedAt"] = nil
            try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)
            let resumed = try executor(fixture).resume(journalURL: journalURL)
            XCTAssertTrue(resumed.succeeded, resumed.text)
            try fixture.readCatalog { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_assets"), 7)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM faces WHERE state = 'confirmed'"), 3)
            }
        }
    }

    // MARK: - Undo

    func testUndoPutsBackByteIdenticalPathsTheCatalogAndTheStores() throws {
        try withTemporaryDirectory { root in
            let fixture = try LayoutMigrationFixture.make(in: root)
            let treeBefore = try fixture.driveTree()
            let imageBefore = try catalogImage(fixture)
            let captureBefore = try Data(contentsOf: fixture.support.appendingPathComponent("capture-dates.json"))
            let manifestURL = fixture.trashRoot.appendingPathComponent("2026-09-21_230244/manifest.json")
            let manifestBefore = try Data(contentsOf: manifestURL)

            let report = try executor(fixture).execute(try fixture.plan())
            XCTAssertTrue(report.succeeded, report.text)
            XCTAssertNotEqual(try fixture.driveTree(), treeBefore)

            let undo = try executor(fixture).undo(journalURL: try XCTUnwrap(report.journalURL))
            XCTAssertTrue(undo.succeeded, undo.text)
            XCTAssertEqual(undo.phase, .undone)
            assertTree(try fixture.driveTree(), treeBefore)
            XCTAssertEqual(try catalogImage(fixture), imageBefore)
            XCTAssertEqual(try Data(contentsOf: fixture.support.appendingPathComponent("capture-dates.json")), captureBefore)
            XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
            XCTAssertNil(DriveMoveService.layoutMigrationBarrier(in: fixture.support.appendingPathComponent("Move Journals")))
            try fixture.readCatalog { db in
                XCTAssertNil(try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'layoutMigration'"))
                XCTAssertEqual(try String.fetchAll(db, sql: "PRAGMA integrity_check"), ["ok"])
            }
            // Undoing twice is a no-op, and the plan could now run again.
            XCTAssertTrue(try executor(fixture).undo(journalURL: try XCTUnwrap(report.journalURL)).succeeded)
        }
    }

    func testUndoAfterAnInterruptedRunRestoresTheTreeWithoutTouchingTheCatalog() throws {
        try withTemporaryDirectory { root in
            let fixture = try LayoutMigrationFixture.make(in: root)
            let treeBefore = try fixture.driveTree()
            let imageBefore = try catalogImage(fixture)
            let report = try executor(fixture, hooks: .init(afterMove: { if $0 == 7 { throw SimulatedCrash() } })).execute(try fixture.plan())
            XCTAssertFalse(report.succeeded)
            let undo = try executor(fixture).undo(journalURL: try XCTUnwrap(report.journalURL))
            XCTAssertTrue(undo.succeeded, undo.text)
            assertTree(try fixture.driveTree(), treeBefore)
            XCTAssertEqual(try catalogImage(fixture), imageBefore)
        }
    }

    func testUndoRefusesWhenTheCatalogChangedAfterTheMigration() throws {
        try withTemporaryDirectory { root in
            let fixture = try LayoutMigrationFixture.make(in: root)
            let report = try executor(fixture).execute(try fixture.plan())
            let writer = try CatalogDatabase.writer(for: fixture.catalogURL)
            try writer.write { try $0.execute(sql: "UPDATE faces SET state = 'confirmed' WHERE id = 'F-B2'") }
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)
            let treeAfter = try fixture.driveTree()
            XCTAssertThrowsError(try executor(fixture).undo(journalURL: try XCTUnwrap(report.journalURL))) { error in
                XCTAssertTrue(error.localizedDescription.contains("changed after the migration"), error.localizedDescription)
            }
            XCTAssertEqual(try fixture.driveTree(), treeAfter)
        }
    }

    func testCatalogCheckFailureRollsBackTheTransactionAndLeavesItResumable() throws {
        try withTemporaryDirectory { root in
            let fixture = try LayoutMigrationFixture.make(in: root)
            let imageBefore = try catalogImage(fixture)
            // Tamper inside the transaction: a confirmed face disappears.
            let hooks = LayoutMigrationExecutor.Hooks(beforeCatalogValidation: { db in
                try db.execute(sql: "UPDATE faces SET state = 'cached' WHERE id = 'F-C1'")
            })
            let report = try executor(fixture, hooks: hooks).execute(try fixture.plan())
            XCTAssertFalse(report.succeeded)
            XCTAssertEqual(report.phase, .movesVerified)
            XCTAssertTrue(report.text.contains("confirmed faces"), report.text)
            XCTAssertEqual(try catalogImage(fixture), imageBefore, "the failed transaction wrote nothing")
            let resumed = try executor(fixture).resume(journalURL: try XCTUnwrap(report.journalURL))
            XCTAssertTrue(resumed.succeeded, resumed.text)
        }
    }

    // MARK: - Journals and CLI

    func testApplyJournalsFromBeforeTheMigrationAreNoLongerUndoable() throws {
        try withTemporaryDirectory { root in
            let journals = root.appendingPathComponent("Move Journals", isDirectory: true)
            let source = try writeFile(root.appendingPathComponent("Unsorted/A.ARW"), "a")
            let destination = root.appendingPathComponent("Buffer/E/A.ARW")
            _ = try DriveMoveService().apply(
                [DriveMove(sourcePath: source.path, destinationPath: destination.path, byteCount: 1)],
                title: "Apply",
                journalFolder: journals
            )
            XCTAssertNotNil(DriveMoveService.latestUndoableJournal(in: journals))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(DriveMoveService.LayoutMigrationBarrier(migrationID: UUID(), completedAt: Date().addingTimeInterval(2)))
                .write(to: journals.appendingPathComponent(DriveMoveService.layoutMigrationBarrierFileName))
            XCTAssertNil(DriveMoveService.latestUndoableJournal(in: journals))
            let url = try XCTUnwrap(DriveMoveService.journals(in: journals).first)
            XCTAssertThrowsError(try DriveMoveService().undo(journalURL: url))
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testCommandParsesItsModesAndDryRunWritesThePlanFromTheSupportOverride() throws {
        XCTAssertEqual(try LayoutMigrationCommand.parse(["app", "--migrate-layout", "--dry-run", "--json", "/tmp/p.json"]).mode, .dryRun(jsonPath: "/tmp/p.json"))
        XCTAssertEqual(try LayoutMigrationCommand.parse(["app", "--migrate-layout", "--execute", "--plan", "/tmp/p.json"]).mode, .execute(planPath: "/tmp/p.json"))
        XCTAssertEqual(try LayoutMigrationCommand.parse(["app", "--migrate-layout", "--undo", "/tmp/j.json"]).mode, .undo(journalPath: "/tmp/j.json"))
        XCTAssertEqual(try LayoutMigrationCommand.parse(["app", "--migrate-layout", "--resume", "/tmp/j.json", "--support-dir", "/tmp/s"]).supportDirectory, "/tmp/s")
        XCTAssertEqual(
            try LayoutMigrationCommand.parse(["app", "--migrate-layout", "--dry-run"], environment: ["CAMERA_TOOLKIT_SUPPORT_DIR": "/tmp/env"]).supportDirectory,
            "/tmp/env"
        )
        XCTAssertThrowsError(try LayoutMigrationCommand.parse(["app", "--migrate-layout", "--dry-run", "--execute", "--plan", "x"]))
        XCTAssertThrowsError(try LayoutMigrationCommand.parse(["app", "--migrate-layout", "--execute"]))
        XCTAssertThrowsError(try LayoutMigrationCommand.parse(["app", "--migrate-layout", "--dry-run", "--bogus"]))

        try withTemporaryDirectory { root in
            let fixture = try LayoutMigrationFixture.make(in: root)
            // The copied config names a catalog elsewhere; the override
            // must read the one in the support folder only.
            var settings = fixture.configuration
            settings.catalogDatabasePath = root.appendingPathComponent("elsewhere/catalog.sqlite").path
            try ConfigurationStore(url: fixture.configurationURL).save(settings, settingsOnly: true)
            let json = root.appendingPathComponent("plan.json")
            var output: [String] = []
            let status = LayoutMigrationCommand.run(
                arguments: ["app", "--migrate-layout", "--dry-run", "--json", json.path, "--support-dir", fixture.support.path],
                environment: [:],
                defaultSupportFolder: root.appendingPathComponent("never used"),
                output: { output.append($0) }
            )
            XCTAssertEqual(status, 0, output.joined(separator: "\n"))
            XCTAssertTrue(output.contains { $0.contains("Catalog:        \(fixture.catalogURL.path)") }, output.joined(separator: "\n"))
            XCTAssertEqual(try LayoutMigrationPlan.read(json).summary.files, 19)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("elsewhere").path))
            // Never overwrites a plan file.
            let again = LayoutMigrationCommand.run(
                arguments: ["app", "--migrate-layout", "--dry-run", "--json", json.path, "--support-dir", fixture.support.path],
                environment: [:],
                defaultSupportFolder: root,
                output: { output.append($0) }
            )
            XCTAssertEqual(again, 1)
        }
    }

    // MARK: - Helpers

    /// Reports only the entries that differ.
    private func assertTree(_ actual: [String: String], _ expected: [String: String], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let keys = Set(actual.keys).union(expected.keys)
        let differing = keys.filter { actual[$0] != expected[$0] }.sorted()
        XCTAssertTrue(differing.isEmpty, "\(message) differing: " + differing.prefix(12).map { "\n  \($0): \(actual[$0] ?? "absent") ≠ expected \(expected[$0] ?? "absent")" }.joined(), file: file, line: line)
    }

    private func assertTree(_ actual: [String], _ expected: [String], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let a = Set(actual), e = Set(expected)
        XCTAssertTrue(a == e, "\(message) extra: \(a.subtracting(e).sorted().prefix(8)) missing: \(e.subtracting(a).sorted().prefix(8))", file: file, line: line)
    }

    private func latestJournal(_ fixture: LayoutMigrationFixture) throws -> URL {
        let folder = fixture.support.appendingPathComponent("Layout Migrations", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
        return folder.appendingPathComponent(try XCTUnwrap(names.last)).appendingPathComponent("journal.json")
    }

    /// The tree relative to the fixture root, without inodes, so two runs
    /// in different temp folders compare equal.
    private func relativeTree(_ fixture: LayoutMigrationFixture) throws -> [String] {
        try fixture.driveTree().map { key, value in
            // A trash manifest names absolute paths under this run's temp
            // root; its bytes are compared on their own elsewhere.
            if key.hasSuffix("manifest.json") { return key }
            return key + " " + value.replacingOccurrences(of: #" ino \d+"#, with: "", options: .regularExpression)
        }.sorted()
    }

    /// Paths in the catalog made relative to the fixture root, event ids
    /// replaced by names.
    private func normalized(_ image: CatalogImage, _ fixture: LayoutMigrationFixture) throws -> CatalogImage {
        var image = image
        let root = fixture.root.standardizedFileURL.path
        func strip(_ text: String) -> String {
            text.replacingOccurrences(of: root, with: "<root>")
                .replacingOccurrences(of: root.lowercased(), with: "<root>")
                .replacingOccurrences(of: fixture.parent.id.uuidString, with: "<parent>")
                .replacingOccurrences(of: fixture.child.id.uuidString, with: "<child>")
        }
        image.facePhotos = image.facePhotos.map(strip)
        image.faces = image.faces.map(strip)
        image.locations = image.locations.map(strip)
        image.immich = image.immich.map(strip)
        image.state = CatalogOwnedState(
            savedEvents: [],
            photoEventAssignments: image.state.photoEventAssignments.map { assignment in
                var copy = assignment
                copy.sourceRootPath = strip(copy.sourceRootPath)
                copy.eventID = copy.eventID == fixture.parent.id ? UUID(uuidString: "00000000-0000-0000-0000-000000000001")! : UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
                return copy
            },
            displayOrientations: image.state.displayOrientations,
            burstSplits: image.state.burstSplits.map { BurstSplit(id: $0.id, createdAt: $0.createdAt, memberPathKeys: $0.memberPathKeys.map(strip)) }
        )
        image.digest = ""
        return image
    }
}

/// Test access to the catalog readers the migration uses.
enum CatalogStateStoreProbe {
    static func load(_ db: Database) throws -> CatalogOwnedState {
        try LayoutMigrationCatalog.snapshot(database: db).state
    }
}

enum LayoutMigrationCatalogProbe {
    static func digest(_ db: Database) throws -> String {
        try LayoutMigrationCatalog.digest(database: db)
    }
}
