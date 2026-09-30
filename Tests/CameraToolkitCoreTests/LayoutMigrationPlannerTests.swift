import CameraToolkitCore
import Foundation
import GRDB
import XCTest

final class LayoutMigrationPlannerTests: XCTestCase {
    func testLegacyPathMappingCoversSubeventsAndDeviceNames() {
        let roots = ["/Volumes/D/Camera Buffer", "/Volumes/D/.Camera Toolkit/Private"]
        XCTAssertEqual(
            LayoutMigrationPaths.currentPath(forLegacy: "/Volumes/D/Camera Buffer/2026/2026-08-23 Trip/DJI Osmo 360/Card Copy/CAM.OSV", driveRoots: roots),
            "/Volumes/D/Camera Buffer/2026/2026-08-23 Trip/Originals/Osmo 360/CAM.OSV"
        )
        XCTAssertEqual(
            LayoutMigrationPaths.currentPath(
                forLegacy: "/Volumes/D/.Camera Toolkit/Private/2026/2026-08-23 Trip/2026-08-24 Night/DJI Nano/Card Copy/Sub/DJI_1.MP4",
                driveRoots: roots
            ),
            "/Volumes/D/.Camera Toolkit/Private/2026/2026-08-23 Trip/2026-08-24 Night/Originals/Osmo Nano/Sub/DJI_1.MP4"
        )
        // Not the legacy layout: unchanged callers get nil.
        XCTAssertNil(LayoutMigrationPaths.currentPath(forLegacy: "/Volumes/D/Camera Buffer/2026/2026-08-23 Trip/Originals/Sony A7V/A.ARW", driveRoots: roots))
        XCTAssertNil(LayoutMigrationPaths.currentPath(forLegacy: "/Volumes/D/Unparsed A7V/Card Copy/A.ARW", driveRoots: roots))
        XCTAssertNil(LayoutMigrationPaths.currentPath(forLegacy: "/Volumes/D/Camera Buffer/2026/2026-08-23 Trip/Sony A7V/Card Copy", driveRoots: roots))
        XCTAssertEqual(LayoutMigrationPaths.cameraFolder(forLegacyDeviceFolder: "Sony A7V"), "Sony A7V")
        XCTAssertEqual(LayoutMigrationPaths.cameraFolder(forLegacyDeviceFolder: "DJI Action 6"), "Osmo Action 6")
        XCTAssertEqual(LayoutMigrationPaths.cameraFolder(forLegacyDeviceFolder: "generic-camera"), "Camera")
        XCTAssertEqual(LayoutMigrationPaths.cameraFolder(forLegacyDeviceFolder: "Hasselblad"), "Hasselblad")
    }

    func testPlanMovesEveryFileWithSidecarsTwinsAndCollisionSuffixes() throws {
        try withTemporaryDirectory { root in
            let fixture = try LayoutMigrationFixture.make(in: root)
            let before = try fixture.driveTree()
            let plan = try fixture.plan()
            // Planning is read-only.
            XCTAssertEqual(try fixture.driveTree(), before)

            XCTAssertTrue(plan.isExecutable, plan.blockers.joined(separator: "\n"))
            // The junk "Unparsed A7V" folder is reported, not planned.
            XCTAssertEqual(plan.folders.map { ($0.legacyDeviceFolderPath as NSString).lastPathComponent }, [
                "DJI Osmo 360", "Sony A7V", "osmo-360", "DJI Nano", "Sony A7V",
            ])
            XCTAssertEqual(plan.folders.map(\.id), ["F0001", "F0002", "F0003", "F0004", "F0005"])
            XCTAssertEqual(plan.folders.map(\.cameraFolder), ["Osmo 360", "Sony A7V", "Osmo 360", "Osmo Nano", "Sony A7V"])
            XCTAssertEqual(plan.folders.map(\.policy), [.buffer, .buffer, .buffer, .archiveOnly, .archiveOnly])
            XCTAssertEqual(plan.summary.files, 19)
            XCTAssertEqual(plan.summary.events, 2)
            XCTAssertEqual(plan.fingerprint.legacyCameraFolders.count, 6)

            let moves = Dictionary(uniqueKeysWithValues: plan.allMoves.map { ($0.source, $0) })
            let sony = fixture.sonyCardCopy.path
            let originals = fixture.parentFolder.appendingPathComponent("Originals").path
            func dest(_ source: String) -> String? { moves[source]?.destination }
            XCTAssertEqual(dest(sony + "/DSC00001.ARW"), originals + "/Sony A7V/DSC00001.ARW")
            XCTAssertEqual(dest(sony + "/DSC00001.ARW.xmp"), originals + "/Sony A7V/DSC00001.ARW.xmp")
            XCTAssertEqual(dest(sony + "/._DSC00001.ARW"), originals + "/Sony A7V/._DSC00001.ARW")
            XCTAssertEqual(moves[sony + "/._DSC00001.ARW"]?.kind, .appleDouble)
            XCTAssertNotNil(moves[sony + "/._DSC00001.ARW"]?.companionOf)
            // An older DSC00002.ARW already sits in Originals: the pair
            // takes "(2)" together.
            XCTAssertEqual(dest(sony + "/DSC00002.ARW"), originals + "/Sony A7V/DSC00002 (2).ARW")
            XCTAssertEqual(dest(sony + "/DSC00002.JPG"), originals + "/Sony A7V/DSC00002 (2).JPG")
            // A twin, and the twin of that twin, chain onto the new name.
            XCTAssertEqual(dest(sony + "/._DSC00002.JPG"), originals + "/Sony A7V/._DSC00002 (2).JPG")
            XCTAssertEqual(dest(sony + "/._._DSC00002.JPG"), originals + "/Sony A7V/._._DSC00002 (2).JPG")
            XCTAssertEqual(dest(sony + "/Transfer 4 (Lakeside)/DSC00010.ARW"), originals + "/Sony A7V/Transfer 4 (Lakeside)/DSC00010.ARW")
            XCTAssertEqual(dest(sony + "/._Transfer 4 (Lakeside)"), originals + "/Sony A7V/._Transfer 4 (Lakeside)")
            XCTAssertEqual(moves[sony + "/._Transfer 4 (Lakeside)"]?.kind, .folderAppleDouble)
            // Unknown files inside Card Copy move along.
            XCTAssertEqual(dest(sony + "/notes.txt"), originals + "/Sony A7V/notes.txt")
            XCTAssertEqual(moves[sony + "/notes.txt"]?.catalogKnown, false)
            XCTAssertEqual(dest(sony + "/.DS_Store"), originals + "/Sony A7V/.DS_Store")
            // Two legacy folders map to one "Osmo 360": the second is "(2)",
            // sidecar and AppleDouble twin included.
            let alt = fixture.osmoAltCardCopy.path
            XCTAssertEqual(dest(fixture.osmoCardCopy.path + "/CAM_0001.OSV"), originals + "/Osmo 360/CAM_0001.OSV")
            XCTAssertEqual(dest(alt + "/CAM_0001.OSV"), originals + "/Osmo 360/CAM_0001 (2).OSV")
            XCTAssertEqual(dest(alt + "/CAM_0001.LRF"), originals + "/Osmo 360/CAM_0001 (2).LRF")
            XCTAssertEqual(dest(alt + "/._CAM_0001.OSV"), originals + "/Osmo 360/._CAM_0001 (2).OSV")
            // The private subevent keeps its hidden home.
            XCTAssertEqual(
                dest(fixture.childFolder.appendingPathComponent("DJI Nano/Card Copy/DJI_0001.MP4").path),
                fixture.childFolder.appendingPathComponent("Originals/Osmo Nano/DJI_0001.MP4").path
            )

            XCTAssertEqual(Set(plan.conflicts.map { ($0.source as NSString).lastPathComponent + ":" + $0.reason.rawValue }), [
                "DSC00002.ARW:destinationExists",
                "DSC00002.JPG:travelsWithConflict",
                "CAM_0001.OSV:claimedByAnotherFile",
                "CAM_0001.LRF:claimedByAnotherFile",
            ])
            XCTAssertEqual(plan.conflicts.first { $0.reason == .destinationExists }?.identicalContent, nil)

            // Every destination is unique, case-insensitively.
            let destinations = plan.allMoves.map { $0.destination.lowercased() }
            XCTAssertEqual(Set(destinations).count, destinations.count)
        }
    }

    func testPlanReportsLeftoversMissingRowsOddFoldersAndStores() throws {
        try withTemporaryDirectory { root in
            let fixture = try LayoutMigrationFixture.make(in: root)
            let plan = try fixture.plan()

            XCTAssertEqual(Set(plan.leftInPlace.map { ($0.path as NSString).lastPathComponent }), ["Photomator", "Exports", "readme.txt", "Sony A7V"])
            XCTAssertEqual(plan.missingRows.map(\.eventAssetID), [CatalogStore.eventAssetID(fixture.missing)])
            XCTAssertEqual(plan.oddFolders.map { ($0.path as NSString).lastPathComponent }, ["2026-08-23 Unparsed A7V"])
            XCTAssertEqual(plan.oddFolders.first?.mediaFileCount, 0)
            XCTAssertEqual(plan.oddFolders.first?.hasCatalogEvent, false)
            XCTAssertTrue(plan.refused.isEmpty)

            XCTAssertEqual(plan.stores.captureDateKeys, 1)
            XCTAssertEqual(plan.stores.moveJournalsSuperseded, 1)
            XCTAssertEqual(plan.stores.trashManifests.count, 1)
            XCTAssertEqual(plan.stores.trashManifests.first?.entries, [.init(
                old: fixture.sonyCardCopy.appendingPathComponent("DSC08937.ARW").path,
                new: fixture.parentFolder.appendingPathComponent("Originals/Sony A7V/DSC08937.ARW").path
            )])
        }
    }

    func testPlanRewritesAdoptedAndRenamedAssignmentsFacesRotationsAndSplits() throws {
        try withTemporaryDirectory { root in
            let fixture = try LayoutMigrationFixture.make(in: root)
            let plan = try fixture.plan()
            let catalog = plan.catalog
            let byOld = Dictionary(uniqueKeysWithValues: catalog.assignmentRewrites.map { ($0.oldID, $0) })
            XCTAssertEqual(catalog.assignmentRewrites.count, 4)

            let originals = fixture.parentFolder.appendingPathComponent("Originals")
            let sony = try XCTUnwrap(byOld[CatalogStore.eventAssetID(fixture.adoptedSony)])
            XCTAssertEqual(sony.newSourceRootPath, originals.appendingPathComponent("Sony A7V").path)
            XCTAssertEqual(sony.newRelativePath, "DSC00001.ARW")
            let renamed = try XCTUnwrap(byOld[CatalogStore.eventAssetID(fixture.appliedRenamed)])
            XCTAssertEqual(renamed.newSourceRootPath, fixture.appliedRenamed.sourceRootPath, "an Apply row keeps its source root")
            XCTAssertEqual(renamed.newRelativePath, "DSC00002 (2).ARW")
            let alt = try XCTUnwrap(byOld[CatalogStore.eventAssetID(fixture.adoptedOsmoAlt)])
            XCTAssertEqual(alt.newSourceRootPath, originals.appendingPathComponent("Osmo 360").path)
            XCTAssertEqual(alt.newRelativePath, "CAM_0001 (2).OSV")
            XCTAssertNotNil(byOld[CatalogStore.eventAssetID(fixture.adoptedOsmo)])
            // Implied drive copies that keep their name need no row change.
            XCTAssertNil(byOld[CatalogStore.eventAssetID(fixture.appliedNested)])
            XCTAssertNil(byOld[CatalogStore.eventAssetID(fixture.appliedPrivate)])

            XCTAssertEqual(catalog.facePhotoRewrites.count, 1)
            XCTAssertEqual(catalog.facePhotoRewrites.first?.newPath, originals.appendingPathComponent("Sony A7V/DSC00001.ARW").path)
            XCTAssertEqual(catalog.facePhotoRewrites.first?.confirmedFaceCount, 1)
            XCTAssertEqual(catalog.faceIdentityRenames.map(\.newFileName), ["DSC00002 (2).ARW"])
            XCTAssertEqual(catalog.confirmedFaces, 3)
            XCTAssertEqual(catalog.confirmedFacesAffected, 2)
            XCTAssertEqual(catalog.orientationCopies.map(\.quarterTurns), [1])
            XCTAssertEqual(catalog.burstSplitRewrites.first?.newMemberPathKeys.first,
                           EventStorageLocations.pathKey(originals.appendingPathComponent("Sony A7V/DSC00001.ARW").path))

            let known = plan.allMoves.filter(\.catalogKnown).map { ($0.source as NSString).lastPathComponent }
            XCTAssertEqual(Set(known), ["DSC00001.ARW", "DSC00002.ARW", "DSC00010.ARW", "DSC00100.ARW", "CAM_0001.OSV"])
        }
    }

    func testPlanRoundTripsThroughJSONAndSummarizes() throws {
        try withTemporaryDirectory { root in
            let fixture = try LayoutMigrationFixture.make(in: root)
            let plan = try fixture.plan()
            let url = root.appendingPathComponent("plan.json")
            try plan.jsonData().write(to: url)
            let read = try LayoutMigrationPlan.read(url)
            XCTAssertEqual(read, plan)
            XCTAssertEqual(try read.digest(), try plan.digest())
            let text = plan.summaryText()
            XCTAssertTrue(text.contains("Moves: 19 files"), text)
            XCTAssertTrue(text.contains("Executable: yes"), text)
        }
    }

    func testPlanRefusesACatalogThatDoesNotOwnTheEventsAndAQueuedTransfer() throws {
        try withTemporaryDirectory { root in
            let fixture = try LayoutMigrationFixture.make(in: root)
            try writeFile(fixture.support.appendingPathComponent("transfer-queue.json"), "{}")
            let writer = try CatalogDatabase.writer(for: fixture.catalogURL)
            try writer.write { try $0.execute(sql: "DELETE FROM app_state WHERE key = 'eventStateSource'") }
            CatalogDatabase.checkpointAndClose(url: fixture.catalogURL)

            let plan = try fixture.plan()
            XCTAssertFalse(plan.isExecutable)
            XCTAssertTrue(plan.blockers.contains { $0.contains("does not hold the events") })
            XCTAssertTrue(plan.blockers.contains { $0.contains("transfer-queue.json") })
        }
    }

    func testOfflineRootIsReportedNotScanned() throws {
        try withTemporaryDirectory { root in
            var fixture = try LayoutMigrationFixture.make(in: root)
            fixture.configuration.bufferPath = "/Volumes/Camera Toolkit Test Drive That Is Not Mounted/Camera Buffer"
            let plan = try fixture.plan()
            XCTAssertEqual(plan.driveRoots.first?.scanned, false)
            XCTAssertEqual(plan.driveRoots.first?.note, "volume not mounted")
        }
    }
}
