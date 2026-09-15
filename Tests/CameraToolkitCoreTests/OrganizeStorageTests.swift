import CameraToolkitCore
import Foundation
import XCTest

final class OrganizeStorageTests: XCTestCase {
    func testDefaultPrivateStagingLivesHiddenOnTheBufferDrive() throws {
        try withTemporaryDirectory { root in
            let external = EventStorageLocations(configuration: testConfiguration(root: root, bufferPath: "/Volumes/Travel Drive/Camera Buffer"))
            XCTAssertEqual(external.privateStagingRoot.path, "/Volumes/Travel Drive/.Camera Toolkit/Private")
            XCTAssertEqual(external.removedFilesRoot.path, "/Volumes/Travel Drive/.Camera Toolkit/_Trash")

            let local = EventStorageLocations(configuration: testConfiguration(root: root))
            XCTAssertEqual(local.privateStagingRoot.path, root.appendingPathComponent(".Camera Toolkit/Private").standardizedFileURL.path)

            var custom = testConfiguration(root: root)
            custom.privateStagingPath = root.appendingPathComponent("Vault").path
            XCTAssertEqual(EventStorageLocations(configuration: custom).privateStagingRoot.lastPathComponent, "Vault")
        }
    }

    func testEventPathsFollowPolicy() throws {
        try withTemporaryDirectory { root in
            let locations = EventStorageLocations(configuration: testConfiguration(root: root))
            let date = try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-08-26"))
            let event = SavedCameraEvent(name: "Mountain Trip", eventDate: date)
            let assignment = PhotoEventAssignment(sourceRootPath: "/Volumes/Card/DCIM/100MSDCF", relativePath: "DSC00001.ARW", fileSize: 1, modifiedAt: date, eventID: event.id, deviceID: "sony-a7v")

            XCTAssertEqual(
                locations.driveURL(for: assignment, event: event, policy: .buffer)?.path,
                root.appendingPathComponent("Buffer/2026/2026-08-26 Mountain Trip/Sony A7V/Card Copy/DSC00001.ARW").standardizedFileURL.path
            )
            XCTAssertEqual(
                locations.driveURL(for: assignment, event: event, policy: .archiveOnly)?.path,
                root.appendingPathComponent(".Camera Toolkit/Private/2026/2026-08-26 Mountain Trip/Sony A7V/Card Copy/DSC00001.ARW").standardizedFileURL.path
            )
            XCTAssertEqual(
                locations.archiveURL(for: assignment, event: event)?.path,
                root.appendingPathComponent("Library/Originals/2026/2026-08-26 Mountain Trip/Sony A7V/RAW/DSC00001.ARW").standardizedFileURL.path
            )
        }
    }

    func testAssignmentIdentityStaysFlatUnlessNamesCollide() {
        let now = Date()
        let eventID = UUID()
        let files = [
            OrganizeFile(path: "/Volumes/D/Unsorted/Transfer 2/B0001_DSC00001.ARW", size: 1, modifiedAt: now),
            OrganizeFile(path: "/Volumes/D/Unsorted/Transfer 2/DSC00009.ARW", size: 1, modifiedAt: now),
            OrganizeFile(path: "/Volumes/D/Unsorted/Transfer 7/100MSDCF/DSC00009.ARW", size: 1, modifiedAt: now),
        ]
        let assignments = OrganizeAssignmentBuilder.assignments(
            for: files,
            scanRootPath: "/Volumes/D/Unsorted",
            duplicateNames: ["dsc00009.arw"],
            existingEventAssignments: [],
            eventID: eventID,
            deviceID: "sony-a7v"
        )
        XCTAssertEqual(assignments[0].sourceRootPath, "/Volumes/D/Unsorted/Transfer 2")
        XCTAssertEqual(assignments[0].relativePath, "B0001_DSC00001.ARW")
        XCTAssertEqual(assignments[1].sourceRootPath, "/Volumes/D/Unsorted")
        XCTAssertEqual(assignments[1].relativePath, "Transfer 2/DSC00009.ARW")
        XCTAssertEqual(assignments[2].relativePath, "Transfer 7/100MSDCF/DSC00009.ARW")

        let existing = [PhotoEventAssignment(sourceRootPath: "/Volumes/Card/DCIM", relativePath: "B0001_DSC00001.ARW", fileSize: 1, modifiedAt: now, eventID: eventID)]
        let collided = OrganizeAssignmentBuilder.assignments(
            for: [files[0]],
            scanRootPath: "/Volumes/D/Unsorted",
            duplicateNames: [],
            existingEventAssignments: existing,
            eventID: eventID,
            deviceID: nil
        )
        XCTAssertEqual(collided[0].relativePath, "Transfer 2/B0001_DSC00001.ARW")
    }

    func testPresenceScannerSeesSourceDriveAndArchiveCopies() throws {
        try withTemporaryDirectory { root in
            let configuration = testConfiguration(root: root)
            let locations = EventStorageLocations(configuration: configuration)
            let event = SavedCameraEvent(name: "City Walk", eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-08-29")))
            let bytes = Data(repeating: 7, count: 100)
            let source = try writeFile(root.appendingPathComponent("Unsorted/DSC00001.ARW"), bytes)
            let assignment = PhotoEventAssignment(sourceRootPath: source.deletingLastPathComponent().path, relativePath: "DSC00001.ARW", fileSize: 100, modifiedAt: Date(), eventID: event.id, deviceID: "sony-a7v")

            var summary = EventPresenceScanner.scan(event: event, assignments: [assignment], locations: locations)
            XCTAssertEqual(summary.onSource, 1)
            XCTAssertEqual(summary.onDrive, 0)

            let drive = try XCTUnwrap(locations.driveURL(for: assignment, event: event, policy: .buffer))
            try writeFile(drive, bytes)
            try writeFile(try XCTUnwrap(locations.archiveURL(for: assignment, event: event)), bytes)
            summary = EventPresenceScanner.scan(event: event, assignments: [assignment], locations: locations)
            XCTAssertEqual(summary.onDrive, 1)
            XCTAssertEqual(summary.onArchive, 1)
            XCTAssertEqual(summary.assets.first?.bestLocalPath, drive.path)

            var privateEvent = event
            privateEvent.storagePolicy = .archiveOnly
            summary = EventPresenceScanner.scan(event: privateEvent, assignments: [assignment], locations: locations)
            XCTAssertEqual(summary.onDrive, 0)
            XCTAssertEqual(summary.onOtherDrive, 1)
        }
    }

    func testDriveMovesRenameRefuseConflictsJournalAndUndo() throws {
        try withTemporaryDirectory { root in
            let unsorted = root.appendingPathComponent("Unsorted", isDirectory: true)
            let a = try writeFile(unsorted.appendingPathComponent("Transfer 2/DSC00001.ARW"), "a")
            let b = try writeFile(unsorted.appendingPathComponent("Transfer 2/DSC00002.ARW"), "b")
            let event = root.appendingPathComponent("Buffer/2026/2026-08-23 Mall/Sony A7V/Card Copy", isDirectory: true)
            try writeFile(event.appendingPathComponent("DSC00002.ARW"), "different")
            let journals = root.appendingPathComponent("Journals", isDirectory: true)

            let report = try DriveMoveService().apply(
                [
                    DriveMove(sourcePath: a.path, destinationPath: event.appendingPathComponent("DSC00001.ARW").path, byteCount: 1),
                    DriveMove(sourcePath: b.path, destinationPath: event.appendingPathComponent("DSC00002.ARW").path, byteCount: 1),
                ],
                title: "Apply",
                journalFolder: journals,
                pruneBoundaries: [unsorted]
            )

            XCTAssertEqual(report.moved.count, 1)
            XCTAssertEqual(report.skipped.count, 1)
            XCTAssertEqual(try String(contentsOf: event.appendingPathComponent("DSC00001.ARW"), encoding: .utf8), "a")
            XCTAssertEqual(try String(contentsOf: event.appendingPathComponent("DSC00002.ARW"), encoding: .utf8), "different")
            XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b")
            XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))

            let latest = try XCTUnwrap(DriveMoveService.latestUndoableJournal(in: journals))
            XCTAssertEqual(latest.journal.completedMoves.count, 1)
            let undone = try DriveMoveService().undo(journalURL: latest.url, pruneBoundaries: [root.appendingPathComponent("Buffer")])
            XCTAssertEqual(undone.report.moved.count, 1)
            XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "a")
            XCTAssertNil(DriveMoveService.latestUndoableJournal(in: journals))
        }
    }

    func testUndoPicksTheMostRecentMoveEvenWithinTheSameSecond() throws {
        try withTemporaryDirectory { root in
            let journals = root.appendingPathComponent("Journals", isDirectory: true)
            for index in 1...5 {
                let source = try writeFile(root.appendingPathComponent("Unsorted/DSC0000\(index).ARW"), "\(index)")
                _ = try DriveMoveService().apply(
                    [DriveMove(sourcePath: source.path, destinationPath: root.appendingPathComponent("Event/DSC0000\(index).ARW").path, byteCount: 1)],
                    title: "Move \(index)",
                    journalFolder: journals
                )
            }
            XCTAssertEqual(DriveMoveService.latestUndoableJournal(in: journals)?.journal.title, "Move 5")
        }
    }

    func testPruneRemovesOnlyEmptiedFoldersInsideBoundary() throws {
        try withTemporaryDirectory { root in
            let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
            let file = try writeFile(buffer.appendingPathComponent("2026/2026-08-26 Secret/Sony A7V/Card Copy/DSC00001.ARW"), "x")
            try writeFile(buffer.appendingPathComponent("2026/2026-08-27 Other/Sony A7V/Card Copy/DSC00002.ARW"), "y")
            try writeFile(buffer.appendingPathComponent("2026/2026-08-26 Secret/Sony A7V/Card Copy/.DS_Store"), "junk")
            let staging = root.appendingPathComponent("Private/2026/2026-08-26 Secret/Sony A7V/Card Copy/DSC00001.ARW")

            let report = try DriveMoveService().apply(
                [DriveMove(sourcePath: file.path, destinationPath: staging.path, byteCount: 1)],
                title: "Make private",
                journalFolder: nil,
                pruneBoundaries: [buffer]
            )
            XCTAssertEqual(report.moved.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: buffer.appendingPathComponent("2026/2026-08-26 Secret").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: buffer.appendingPathComponent("2026/2026-08-27 Other").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: buffer.path))
        }
    }

    func testVerifiedRemovalMovesMatchingCopiesToTrashOnly() throws {
        try withTemporaryDirectory { root in
            let drive = try writeFile(root.appendingPathComponent("Private/2026/E/Sony A7V/Card Copy/DSC00001.ARW"), "same")
            let nas = try writeFile(root.appendingPathComponent("NAS/Originals/2026/E/Sony A7V/RAW/DSC00001.ARW"), "same")
            let trash = root.appendingPathComponent(".Camera Toolkit/_Trash", isDirectory: true)
            let pair = VerifiedRemovalPair(driveCopyPath: drive.path, referencePath: nas.path, batchRelativePath: "E/DSC00001.ARW", byteCount: 4)

            XCTAssertThrowsError(try VerifiedRemovalService().moveVerifiedCopiesAside(pairs: [pair], trashRoot: trash, confirmation: "yes"))
            XCTAssertThrowsError(try VerifiedRemovalService().moveVerifiedCopiesAside(pairs: [pair], trashRoot: root.appendingPathComponent("Bin"), confirmation: "REMOVE"))

            let report = try VerifiedRemovalService().moveVerifiedCopiesAside(pairs: [pair], trashRoot: trash, confirmation: "REMOVE", pruneBoundaries: [root.appendingPathComponent("Private")])
            XCTAssertEqual(report.moved, [drive.path])
            XCTAssertFalse(FileManager.default.fileExists(atPath: drive.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: nas.path))
            let batch = try XCTUnwrap(report.batchPath)
            XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: batch).appendingPathComponent("E/DSC00001.ARW"), encoding: .utf8), "same")
        }
    }

    func testVerifiedRemovalMovesNothingWhenAnyCopyDiffers() throws {
        try withTemporaryDirectory { root in
            let good = try writeFile(root.appendingPathComponent("Drive/a.ARW"), "same")
            let goodNAS = try writeFile(root.appendingPathComponent("NAS/a.ARW"), "same")
            let bad = try writeFile(root.appendingPathComponent("Drive/b.ARW"), "left")
            let badNAS = try writeFile(root.appendingPathComponent("NAS/b.ARW"), "rite")
            let report = try VerifiedRemovalService().moveVerifiedCopiesAside(
                pairs: [
                    VerifiedRemovalPair(driveCopyPath: good.path, referencePath: goodNAS.path, batchRelativePath: "a.ARW", byteCount: 4),
                    VerifiedRemovalPair(driveCopyPath: bad.path, referencePath: badNAS.path, batchRelativePath: "b.ARW", byteCount: 4),
                ],
                trashRoot: root.appendingPathComponent("_Trash"),
                confirmation: "REMOVE"
            )
            XCTAssertEqual(report.differ, [bad.path])
            XCTAssertTrue(report.moved.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: good.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
        }
    }

    func testDiscoversAndAdoptsHandOrganizedDriveEventsOnce() throws {
        try withTemporaryDirectory { root in
            var configuration = testConfiguration(root: root)
            let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
            try writeFile(buffer.appendingPathComponent("2026/2026-08-19 Harbor + Ferry/Sony A7V/Card Copy/DSC06610.ARW"), "a")
            try writeFile(buffer.appendingPathComponent("2026/2026-08-19 Harbor + Ferry/Sony A7V/Card Copy/Exported/DSC06610.heic"), "b")
            try FileManager.default.createDirectory(at: buffer.appendingPathComponent("2026/2026-08-23 Empty/Sony A7V/Card Copy"), withIntermediateDirectories: true)
            try writeFile(buffer.appendingPathComponent("Loose Folder/DSC1.ARW"), "c")

            let found = try DriveEventDiscovery.discover(driveRoot: buffer, policy: .buffer, configuration: configuration)
            XCTAssertEqual(found.count, 1)
            XCTAssertEqual(found.first?.name, "Harbor + Ferry")
            XCTAssertEqual(found.first?.dateString, "2026-08-19")
            XCTAssertEqual(found.first?.deviceID, "sony-a7v")
            XCTAssertEqual(found.first?.files.count, 2)

            let adopted = DriveEventDiscovery.adopt(found, into: &configuration)
            XCTAssertEqual(adopted.createdEvents, 1)
            XCTAssertEqual(adopted.addedAssignments, 2)

            let event = try XCTUnwrap(configuration.savedEvents.first { $0.name == "Harbor + Ferry" })
            let summary = EventPresenceScanner.scan(
                event: event,
                assignments: configuration.photoEventAssignments.filter { $0.eventID == event.id },
                locations: EventStorageLocations(configuration: configuration)
            )
            XCTAssertEqual(summary.onDrive, 2)
            XCTAssertEqual(summary.onSource, 0)
            XCTAssertTrue(summary.assets.allSatisfy(\.sourceIsDriveCopy))

            XCTAssertTrue(try DriveEventDiscovery.discover(driveRoot: buffer, policy: .buffer, configuration: configuration).isEmpty)
        }
    }

    func testOlderConfigurationsDecodeWithoutNewFields() throws {
        let json = #"{"bufferPath":"/tmp/Buffer","savedEvents":[{"id":"8987780B-3749-43BC-8801-D7DF3B7FFAD7","name":"Trip","eventDate":0,"createdAt":0,"lastUsedAt":0}],"configuredLocations":[{"id":"13C11FA7-5E71-4DDF-B545-80FC13C2A8F2","role":"importSource","name":"Card","path":"/Volumes/Card"}]}"#
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(configuration.privateStagingPath, "")
        XCTAssertEqual(configuration.savedEvents.first?.resolvedStoragePolicy, .buffer)
        XCTAssertNil(configuration.configuredLocations.first { $0.role == .importSource }?.deviceID)

        var updated = configuration
        updated.savedEvents[0].storagePolicy = .archiveOnly
        updated.privateStagingPath = "/Volumes/Drive/Vault"
        let roundTrip = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(roundTrip.savedEvents.first?.resolvedStoragePolicy, .archiveOnly)
        XCTAssertEqual(roundTrip.privateStagingPath, "/Volumes/Drive/Vault")
    }
}

extension DateFormatter {
    static var yyyyMMdd: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
