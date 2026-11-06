@testable import CameraToolkitCore
import Foundation
import XCTest

/// Media that only ever reached the NAS mirror: discovery finds the event
/// folders no assignment covers, and adoption lists them on their events as
/// NAS-only files without touching a file.
final class NASEventDiscoveryTests: XCTestCase {
    private func day(_ value: String) -> Date { DateFormatter.yyyyMMdd.date(from: value)! }

    private struct Fixture {
        var root: URL
        var nas: URL
        var buffer: URL
        var configuration: AppConfiguration
        var trip: SavedCameraEvent
        var fullCard: SavedCameraEvent
        var tripFolder: URL { nas.appendingPathComponent("2026/2026-08-21 Trip") }
        var fullCardFolder: URL { tripFolder.appendingPathComponent("2026-08-22 Full Card") }
    }

    /// "Trip" owns two files in its own `Originals/Sony A7V/{Exported,Photos}`
    /// on the NAS; its subevent "Full Card" exists in the catalog with no
    /// files, while its NAS folder holds a whole card — same frame names as
    /// the parent's, a second folder reusing a name, sidecars, junk, an
    /// edit, and a second camera.
    private func makeFixture(_ root: URL) throws -> Fixture {
        var configuration = testConfiguration(root: root)
        let nas = root.appendingPathComponent("Library", isDirectory: true)
        let trip = SavedCameraEvent(name: "Trip", eventDate: day("2026-08-21"))
        let fullCard = SavedCameraEvent(name: "Full Card", eventDate: day("2026-08-22"), parentEventID: trip.id)
        configuration.savedEvents = [trip, fullCard]
        var fixture = Fixture(
            root: root,
            nas: nas,
            buffer: root.appendingPathComponent("Buffer", isDirectory: true),
            configuration: configuration,
            trip: trip,
            fullCard: fullCard
        )
        let tripCamera = fixture.tripFolder.appendingPathComponent("Originals/Sony A7V")
        for relative in ["Exported/DSC00001.JPG", "Photos/DSC00001.ARW"] {
            try writeFile(tripCamera.appendingPathComponent(relative), "trip \(relative)")
            fixture.configuration.photoEventAssignments.append(PhotoEventAssignment(
                sourceRootPath: fixture.buffer.appendingPathComponent("2026/2026-08-21 Trip/Originals/Sony A7V").path,
                relativePath: relative,
                fileSize: Int64("trip \(relative)".utf8.count),
                modifiedAt: Date(timeIntervalSince1970: 1_780_000_000),
                eventID: trip.id,
                deviceID: "sony-a7v"
            ))
        }
        let card = fixture.fullCardFolder.appendingPathComponent("Originals/Sony A7V")
        try writeFile(card.appendingPathComponent("DSC00001.ARW"), "card frame 1")
        try writeFile(card.appendingPathComponent("DSC00001.xmp"), "<xmp/>")
        try writeFile(card.appendingPathComponent("DSC00001.ARW.photo-edit"), "edit")
        try writeFile(card.appendingPathComponent("101MSDCF/DSC00001.ARW"), "card frame 1, second folder")
        try writeFile(card.appendingPathComponent("._DSC00001.ARW"), "apple double")
        try writeFile(card.appendingPathComponent(".DS_Store"), "finder")
        try writeFile(card.appendingPathComponent(".DSC00002.ARW.ctsync-1234"), "half copied")
        try writeFile(fixture.fullCardFolder.appendingPathComponent("Originals/Osmo 360/CAM_0001.OSV"), "video")
        try writeFile(fixture.fullCardFolder.appendingPathComponent("Edited/Favorites/DSC00001-edit.jpg"), "edit tag")
        return fixture
    }

    func testSubeventFolderOnlyOnTheNASIsAdoptedIntoTheSavedSubeventAsNASOnly() throws {
        try withTemporaryDirectory { temporary in
            var f = try makeFixture(temporary.resolvingSymlinksInPath())
            let tripBefore = f.configuration.photoEventAssignments
            let diskBefore = try treeBytes(f.root)

            let found = NASEventDiscovery.discover(configuration: f.configuration)
            XCTAssertEqual(found.events.map(\.relativeFolderPath), ["2026/2026-08-21 Trip/2026-08-22 Full Card"])
            let folder = try XCTUnwrap(found.events.first)
            XCTAssertEqual(folder.matchingEventID, f.fullCard.id)
            XCTAssertEqual(folder.displayName, "Trip / Full Card")
            XCTAssertEqual(folder.cameras.map(\.folderName), ["Osmo 360", "Sony A7V"])
            XCTAssertEqual(
                folder.cameras.first { $0.folderName == "Sony A7V" }?.files.map(\.path),
                ["101MSDCF/DSC00001.ARW", "DSC00001.ARW", "DSC00001.ARW.photo-edit", "DSC00001.xmp"]
            )

            let summary = NASEventDiscovery.adopt(found.events, into: &f.configuration)
            XCTAssertEqual(summary.createdEvents, 0)
            XCTAssertEqual(summary.addedAssignments, 5)
            XCTAssertEqual(f.configuration.savedEvents.map(\.id), [f.trip.id, f.fullCard.id])

            // The parent keeps exactly what it had; everything new is the subevent's.
            XCTAssertEqual(f.configuration.photoEventAssignments.filter { $0.eventID == f.trip.id }, tripBefore)
            let added = f.configuration.photoEventAssignments.filter { $0.eventID == f.fullCard.id }
            XCTAssertEqual(added.count, 5)
            let driveRoot = f.buffer.appendingPathComponent("2026/2026-08-21 Trip/2026-08-22 Full Card/Originals")
            XCTAssertEqual(
                Set(added.map { "\($0.sourceRootPath)|\($0.relativePath)|\($0.deviceID ?? "")" }),
                [
                    "\(driveRoot.path)/Sony A7V|DSC00001.ARW|sony-a7v",
                    "\(driveRoot.path)/Sony A7V|101MSDCF/DSC00001.ARW|sony-a7v",
                    "\(driveRoot.path)/Sony A7V|DSC00001.ARW.photo-edit|sony-a7v",
                    "\(driveRoot.path)/Sony A7V|DSC00001.xmp|sony-a7v",
                    "\(driveRoot.path)/Osmo 360|CAM_0001.OSV|osmo-360",
                ]
            )

            // On the board: on no drive, not a separate source, and its NAS
            // copy is the file that was found — so it reads "NAS only" and
            // previews from the NAS, and Take Off Drive, Free Up Source and
            // copying to the drive have nothing to act on.
            let locations = EventStorageLocations(configuration: f.configuration)
            let summaryRows = try XCTUnwrap(EventPresenceScanner.scan(
                event: f.fullCard,
                assignments: added,
                locations: locations
            ))
            for asset in summaryRows.assets {
                XCTAssertEqual(asset.archive, .present, asset.assignment.relativePath)
                XCTAssertEqual(asset.drive, .missing)
                XCTAssertEqual(asset.otherDrive, .missing)
                XCTAssertTrue(asset.sourceIsDriveCopy)
                XCTAssertNil(asset.archiveVerifiedAt)
                XCTAssertEqual(asset.bestLocalPath, asset.archivePath)
            }
            XCTAssertEqual(
                Set(summaryRows.assets.compactMap(\.archivePath)),
                Set([
                    "Sony A7V/DSC00001.ARW", "Sony A7V/101MSDCF/DSC00001.ARW", "Sony A7V/DSC00001.ARW.photo-edit",
                    "Sony A7V/DSC00001.xmp", "Osmo 360/CAM_0001.OSV",
                ].map { f.fullCardFolder.appendingPathComponent("Originals/\($0)").path })
            )
            XCTAssertEqual(summaryRows.counts.separateSource, 0)
            XCTAssertEqual(summaryRows.counts.needsDrive, 0)
            XCTAssertEqual(summaryRows.counts.removable, 0)
            XCTAssertEqual(summaryRows.counts.onArchive, 5)

            XCTAssertTrue(NASEventDiscovery.discover(configuration: f.configuration).events.isEmpty)
            XCTAssertEqual(try treeBytes(f.root), diskBefore)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.buffer.path))
        }
    }

    func testMissingSubeventAndParentAreCreatedWithTheFolderLinkage() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.resolvingSymlinksInPath()
            var configuration = testConfiguration(root: root)
            let nas = root.appendingPathComponent("Library", isDirectory: true)
            try writeFile(nas.appendingPathComponent("2026/2026-08-21 Trip/2026-08-22 Full Card/Originals/Sony A7V/DSC00003.ARW"), "x")

            let found = NASEventDiscovery.discover(configuration: configuration)
            XCTAssertEqual(found.events.count, 1)
            XCTAssertNil(found.events.first?.matchingEventID)
            let summary = NASEventDiscovery.adopt(found.events, into: &configuration)

            XCTAssertEqual(summary.createdEvents, 2)
            XCTAssertEqual(summary.addedAssignments, 1)
            let trip = try XCTUnwrap(configuration.savedEvents.first { $0.name == "Trip" })
            let fullCard = try XCTUnwrap(configuration.savedEvents.first { $0.name == "Full Card" })
            XCTAssertNil(trip.parentEventID)
            XCTAssertEqual(fullCard.parentEventID, trip.id)
            XCTAssertEqual(EventStorageLocations.eventDateString(fullCard.eventDate), "2026-08-22")
            XCTAssertEqual(configuration.photoEventAssignments.map(\.eventID), [fullCard.id])
            XCTAssertEqual(summary.touchedEventIDs, [trip.id, fullCard.id])
            XCTAssertTrue(NASEventDiscovery.discover(configuration: configuration).events.isEmpty)
        }
    }

    func testAdoptingAStaleDiscoveryNeverAddsAFileTwice() throws {
        try withTemporaryDirectory { temporary in
            var f = try makeFixture(temporary.resolvingSymlinksInPath())
            let found = NASEventDiscovery.discover(configuration: f.configuration).events
            // The file was assigned after discovery ran.
            f.configuration.photoEventAssignments.append(PhotoEventAssignment(
                sourceRootPath: "/Volumes/Card/DCIM/100MSDCF",
                relativePath: "DSC00001.ARW",
                fileSize: 12,
                modifiedAt: Date(),
                eventID: f.fullCard.id,
                deviceID: "sony-a7v"
            ))

            let first = NASEventDiscovery.adopt(found, into: &f.configuration)
            XCTAssertEqual(first.addedAssignments, 4)
            XCTAssertEqual(first.alreadyCovered, 1)
            let second = NASEventDiscovery.adopt(found, into: &f.configuration)
            XCTAssertEqual(second.addedAssignments, 0)
            XCTAssertEqual(second.alreadyCovered, 5)
            XCTAssertEqual(f.configuration.photoEventAssignments.count, 2 + 1 + 4)
        }
    }

    func testCameraFolderTheAppNamesDifferentlyIsReportedNotAdopted() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.resolvingSymlinksInPath()
            var configuration = testConfiguration(root: root)
            let nas = root.appendingPathComponent("Library", isDirectory: true)
            try writeFile(nas.appendingPathComponent("2026/2026-08-21 Trip/Originals/DJI Osmo 360/CAM_0001.OSV"), "x")
            try writeFile(nas.appendingPathComponent("2026/Not An Event/Originals/Sony A7V/DSC00001.ARW"), "x")

            let found = NASEventDiscovery.discover(configuration: configuration)
            XCTAssertTrue(found.events.isEmpty)
            XCTAssertEqual(found.problems.map(\.path), ["2026/2026-08-21 Trip/Originals/DJI Osmo 360"])
            XCTAssertEqual(NASEventDiscovery.adopt(found.events, into: &configuration).addedAssignments, 0)
            XCTAssertTrue(configuration.savedEvents.isEmpty)
        }
    }

    func testPreparingTheAdoptionBacksUpTheCatalogFirstAndRefusesWhileRenamesWait() throws {
        try withTemporaryDirectory { temporary in
            let f = try makeFixture(temporary.resolvingSymlinksInPath())
            let catalog = f.root.appendingPathComponent("catalog.sqlite")
            _ = try CatalogStore(url: catalog).bootstrap(configuration: f.configuration, createLibraryFolders: false)
            let backups = f.root.appendingPathComponent("Backups", isDirectory: true)
            let service = CatalogBackupService(catalogURL: catalog, configurationURL: nil, localFolder: backups, remoteFolder: nil)
            let folders = Set(NASEventDiscovery.discover(configuration: f.configuration).events.map(\.id))

            var backedUp = 0
            XCTAssertThrowsError(try NASEventDiscovery.prepareAdoption(
                folderIDs: folders,
                configuration: f.configuration,
                pendingNASRenames: 2,
                backup: { backedUp += 1; return try service.backupNow(reason: .manual, mirrorToRemote: false) }
            ))
            XCTAssertEqual(backedUp, 0)

            XCTAssertThrowsError(try NASEventDiscovery.prepareAdoption(
                folderIDs: folders,
                configuration: f.configuration,
                pendingNASRenames: 0,
                backup: { throw ToolkitError.commandFailed("disk full") }
            ))

            let plan = try NASEventDiscovery.prepareAdoption(
                folderIDs: folders,
                configuration: f.configuration,
                pendingNASRenames: 0,
                backup: { try service.backupNow(reason: .manual, mirrorToRemote: false) }
            )
            XCTAssertEqual(plan.events.map(\.id), Array(folders))
            let manifest = try XCTUnwrap(plan.backup)
            XCTAssertEqual(service.newestManifest(in: backups)?.id, manifest.id)
        }
    }
}
