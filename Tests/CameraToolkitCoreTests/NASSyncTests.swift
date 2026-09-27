@testable import CameraToolkitCore
import Darwin
import Foundation
import XCTest

final class NASSyncTests: XCTestCase {
    override func tearDown() {
        NASFileIO.verificationHashOverride = nil
        NASFileIO.renameExclusivePrimitive = nil
        DirectoryListing.override = nil
        super.tearDown()
    }

    private struct Fixture {
        var root: URL
        var configuration: AppConfiguration
        var locations: EventStorageLocations
        var event: SavedCameraEvent
        var child: SavedCameraEvent
        var catalog: URL
        var nas: URL { locations.nasRoot }
    }

    private func fixture(_ root: URL) throws -> Fixture {
        var configuration = testConfiguration(root: root)
        configuration.archiveLayoutRootPath = root.appendingPathComponent("NAS").path
        let event = SavedCameraEvent(name: "Mountain Trip", eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-08-26")))
        var child = SavedCameraEvent(name: "Summit", eventDate: try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: "2026-08-27")), parentEventID: event.id)
        child.storagePolicy = .archiveOnly
        configuration.savedEvents = [event, child]
        try FileManager.default.createDirectory(at: root.appendingPathComponent("NAS"), withIntermediateDirectories: true)
        return Fixture(
            root: root,
            configuration: configuration,
            locations: EventStorageLocations(configuration: configuration),
            event: event,
            child: child,
            catalog: root.appendingPathComponent("Support/catalog.sqlite")
        )
    }

    /// Two cameras, an edit, a subfolder with a repeated name, junk, and a
    /// private subevent that lives in private staging.
    @discardableResult
    private func populate(_ f: Fixture) throws -> [String: Data] {
        let originals = f.locations.originalsRoot(for: f.event, deviceID: "sony-a7v", policy: .buffer)
        let osmo = f.locations.originalsRoot(for: f.event, deviceID: "osmo-360", policy: .buffer)
        let edited = f.locations.editedRoot(for: f.event, policy: .buffer)
        let privateOriginals = f.locations.originalsRoot(for: f.child, deviceID: "sony-a7v", policy: .archiveOnly)
        var files: [URL: Data] = [
            originals.appendingPathComponent("DSC00001.ARW"): Data(repeating: 1, count: 3_000),
            originals.appendingPathComponent("DSC00001.XMP"): Data("xmp".utf8),
            originals.appendingPathComponent("Transfer 2/DSC00001.ARW"): Data(repeating: 2, count: 3_000),
            osmo.appendingPathComponent("CAM_0001.OSV"): Data(repeating: 3, count: 5_000),
            edited.appendingPathComponent("Web/DSC00001-edit.jpg"): Data("edit".utf8),
            privateOriginals.appendingPathComponent("DSC00009.ARW"): Data(repeating: 9, count: 2_000),
        ]
        files[originals.appendingPathComponent("._DSC00001.ARW")] = Data("apple double".utf8)
        files[originals.appendingPathComponent(".DS_Store")] = Data("finder".utf8)
        var byRelative: [String: Data] = [:]
        for (url, data) in files {
            try writeFile(url, data)
            if let relative = f.locations.mirrorRelativePath(forDrivePath: url.path), !NASSyncPlanner.isJunk(url.lastPathComponent) {
                byRelative[relative] = data
            }
        }
        return byRelative
    }

    func testDirectoryListingReturnsEveryEntryWithSizesInOneCall() throws {
        try withTemporaryDirectory { root in
            try writeFile(root.appendingPathComponent("a.ARW"), Data(repeating: 0, count: 1_234))
            try writeFile(root.appendingPathComponent("._a.ARW"), "x")
            try writeFile(root.appendingPathComponent("sub/b.JPG"), "b")
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("a.ARW"))
            let entries = try DirectoryListing.list(root.path)
            XCTAssertEqual(entries.map(\.name), ["._a.ARW", "a.ARW", "link", "sub"])
            XCTAssertEqual(entries.first { $0.name == "a.ARW" }?.size, 1_234)
            XCTAssertEqual(entries.first { $0.name == "a.ARW" }?.kind, .file)
            XCTAssertEqual(entries.first { $0.name == "sub" }?.kind, .directory)
            XCTAssertEqual(entries.first { $0.name == "link" }?.kind, .symlink)
            let stat = try XCTUnwrap(LayoutMigrationDisk.lstatEntry(root.appendingPathComponent("a.ARW").path))
            XCTAssertEqual(entries.first { $0.name == "a.ARW" }?.modifiedAt ?? 0, stat.modifiedAt, accuracy: 0.001)
            XCTAssertThrowsError(try DirectoryListing.list(root.appendingPathComponent("missing").path))
            // The bulk call itself (not the fallback) answers on a local
            // volume, and agrees with readdir + lstat.
            let descriptor = open(root.path, O_RDONLY | O_DIRECTORY)
            defer { close(descriptor) }
            let bulk = try DirectoryListing.bulk(descriptor: descriptor)
            let fallback = try DirectoryListing.readdirFallback(root.path)
            XCTAssertEqual(bulk.map(\.name), fallback.map(\.name))
            XCTAssertEqual(bulk.map(\.size), fallback.map(\.size))
            XCTAssertEqual(bulk.map(\.kind), fallback.map(\.kind))
            XCTAssertEqual(bulk.map(\.fileID), fallback.map(\.fileID))
        }
    }

    func testPlannerListsOriginalsEditedAndPrivateSubeventsAndReportsTheRest() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let expected = try populate(f)
            // A legacy Card Copy folder next to Originals is never mirrored.
            try writeFile(f.locations.eventFolder(for: f.event, policy: .buffer).appendingPathComponent("Sony A7V/Card Copy/DSC00002.ARW"), "legacy")
            try FileManager.default.createSymbolicLink(
                at: f.locations.originalsRoot(for: f.event, deviceID: "sony-a7v", policy: .buffer).appendingPathComponent("alias.ARW"),
                withDestinationURL: root.appendingPathComponent("elsewhere")
            )

            let plan = NASSyncPlanner.plan(events: [f.event, f.child], locations: f.locations)
            XCTAssertEqual(Set(plan.items.map(\.relativePath)), Set(expected.keys))
            XCTAssertTrue(plan.items.contains { $0.relativePath == "2026/2026-08-26 Mountain Trip/2026-08-27 Summit/Originals/Sony A7V/DSC00009.ARW" })
            XCTAssertEqual(plan.items.first { $0.relativePath.hasSuffix("Summit/Originals/Sony A7V/DSC00009.ARW") }?.eventID, f.child.id)
            XCTAssertEqual(plan.skippedJunk, 2)
            XCTAssertEqual(plan.outsideLayout.map { ($0 as NSString).lastPathComponent }, ["Sony A7V"])
            XCTAssertEqual(plan.refused.map { ($0.path as NSString).lastPathComponent }, ["alias.ARW"])
            XCTAssertEqual(plan.totalBytes, Int64(expected.values.reduce(0) { $0 + $1.count }))
        }
    }

    func testSyncCopiesVerifiesRecordsAndResumesWithoutRereading() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let expected = try populate(f)
            let store = try NASSyncStore(catalogURL: f.catalog)
            let plan = NASSyncPlanner.plan(events: [f.event, f.child], locations: f.locations)

            var verifiedReads: [String] = []
            NASFileIO.verificationHashOverride = { path in
                verifiedReads.append(path)
                return nil
            }
            let report = try NASSyncService(store: store).sync(plan, nasRoot: f.nas)
            XCTAssertTrue(report.succeeded, "\(report)")
            XCTAssertEqual(Set(report.copied), Set(expected.keys))
            for (relative, data) in expected {
                XCTAssertEqual(try Data(contentsOf: f.nas.appendingPathComponent(relative)), data, relative)
            }
            // Every copy was re-read (uncached) before it was renamed in —
            // the temporary, which then became the final file.
            XCTAssertEqual(verifiedReads.count, expected.count)
            XCTAssertTrue(verifiedReads.allSatisfy { ($0 as NSString).lastPathComponent.contains(NASSyncPlanner.temporaryMarker) })
            // No temporaries are left behind.
            let leftovers = LayoutMigrationDisk.walk(f.nas.path, fileManager: .default).filter { $0.name.contains(NASSyncPlanner.temporaryMarker) }
            XCTAssertTrue(leftovers.isEmpty)
            // Modification times travel with the copy.
            let source = try XCTUnwrap(plan.items.first)
            XCTAssertEqual(LayoutMigrationDisk.lstatEntry(f.nas.appendingPathComponent(source.relativePath).path)?.modifiedAt ?? 0, source.modifiedAt, accuracy: 1)

            let records = try store.records(nasRoot: f.nas.path)
            XCTAssertEqual(records.count, expected.count)
            XCTAssertTrue(records.values.allSatisfy { $0.state == .verified && $0.verifiedAt != nil && $0.sha256?.count == 64 })
            let dates = try store.verifiedDates(nasRoot: f.nas.path, prefixes: ["2026/2026-08-26 Mountain Trip"])
            XCTAssertEqual(dates.count, expected.count)

            // A second run (a resume after a quit) skips everything already
            // verified without re-reading a byte.
            verifiedReads = []
            let again = try NASSyncService(store: store).sync(plan, nasRoot: f.nas)
            XCTAssertEqual(Set(again.alreadyVerified), Set(expected.keys))
            XCTAssertTrue(again.copied.isEmpty)
            XCTAssertTrue(verifiedReads.isEmpty)

            // A drive file changed since: checked again, and a different
            // NAS copy is a conflict, never overwritten.
            let changed = try XCTUnwrap(plan.items.first { $0.relativePath.hasSuffix("Web/DSC00001-edit.jpg") })
            try Data("edit v2".utf8).write(to: URL(fileURLWithPath: changed.sourcePath))
            let replanned = NASSyncPlanner.plan(events: [f.event, f.child], locations: f.locations)
            let third = try NASSyncService(store: store).sync(replanned, nasRoot: f.nas)
            XCTAssertEqual(third.conflicts.map(\.path), [changed.relativePath])
            XCTAssertEqual(try Data(contentsOf: f.nas.appendingPathComponent(changed.relativePath)), Data("edit".utf8))
            XCTAssertEqual(try store.records(nasRoot: f.nas.path)[NASSyncStore.pathKey(changed.relativePath)]?.state, .conflict)
        }
    }

    func testExistingNASFilesAreMatchedByHashAndConflictsAreNeverOverwritten() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let expected = try populate(f)
            let plan = NASSyncPlanner.plan(events: [f.event], locations: f.locations)
            let same = try XCTUnwrap(plan.items.first { $0.relativePath.hasSuffix("Sony A7V/DSC00001.ARW") && !$0.relativePath.contains("Transfer") })
            let sameSize = try XCTUnwrap(plan.items.first { $0.relativePath.hasSuffix("Transfer 2/DSC00001.ARW") })
            let otherSize = try XCTUnwrap(plan.items.first { $0.relativePath.hasSuffix("CAM_0001.OSV") })
            try writeFile(f.nas.appendingPathComponent(same.relativePath), try XCTUnwrap(expected[same.relativePath]))
            try writeFile(f.nas.appendingPathComponent(sameSize.relativePath), Data(repeating: 7, count: 3_000))
            try writeFile(f.nas.appendingPathComponent(otherSize.relativePath), Data("short".utf8))

            let store = try NASSyncStore(catalogURL: f.catalog)
            let report = try NASSyncService(store: store).sync(plan, nasRoot: f.nas)
            XCTAssertEqual(report.matchedExisting, [same.relativePath])
            XCTAssertEqual(Set(report.conflicts.map(\.path)), [sameSize.relativePath, otherSize.relativePath])
            XCTAssertEqual(try Data(contentsOf: f.nas.appendingPathComponent(sameSize.relativePath)), Data(repeating: 7, count: 3_000))
            XCTAssertEqual(try Data(contentsOf: f.nas.appendingPathComponent(otherSize.relativePath)), Data("short".utf8))
            let records = try store.records(nasRoot: f.nas.path)
            XCTAssertEqual(records[NASSyncStore.pathKey(same.relativePath)]?.state, .verified)
            let conflict = try XCTUnwrap(records[NASSyncStore.pathKey(sameSize.relativePath)])
            XCTAssertEqual(conflict.state, .conflict)
            XCTAssertNotEqual(conflict.sha256, conflict.nasSHA256)
            XCTAssertFalse(report.succeeded)
        }
    }

    func testAFailedVerificationOrUnreadableFileIsReportedAndTheRestStillSync() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let expected = try populate(f)
            let plan = NASSyncPlanner.plan(events: [f.event, f.child], locations: f.locations)
            let corrupted = try XCTUnwrap(plan.items.first { $0.relativePath.hasSuffix("CAM_0001.OSV") })
            let unreadable = try XCTUnwrap(plan.items.first { $0.relativePath.hasSuffix("DSC00001.XMP") })
            // The NAS hands back different bytes for one file (a flaky pool),
            // and one drive file cannot be read.
            NASFileIO.verificationHashOverride = { path in
                (path as NSString).lastPathComponent.hasPrefix(".CAM_0001.OSV") ? String(repeating: "0", count: 64) : nil
            }
            chmod(unreadable.sourcePath, 0)
            defer { chmod(unreadable.sourcePath, 0o644) }

            let store = try NASSyncStore(catalogURL: f.catalog)
            let report = try NASSyncService(store: store).sync(plan, nasRoot: f.nas)
            XCTAssertEqual(Set(report.failed.map(\.path)), [corrupted.relativePath, unreadable.relativePath])
            XCTAssertEqual(report.copied.count, expected.count - 2)
            XCTAssertNil(report.stoppedReason)
            // Neither the corrupted temporary nor a final file exists.
            XCTAssertNil(LayoutMigrationDisk.lstatEntry(f.nas.appendingPathComponent(corrupted.relativePath).path))
            XCTAssertNil(LayoutMigrationDisk.lstatEntry(f.nas.appendingPathComponent(unreadable.relativePath).path))
            let folder = f.nas.appendingPathComponent(corrupted.relativePath).deletingLastPathComponent().path
            XCTAssertTrue(LayoutMigrationDisk.names(in: folder, fileManager: .default).allSatisfy { !$0.contains(NASSyncPlanner.temporaryMarker) })
            XCTAssertEqual(try store.records(nasRoot: f.nas.path)[NASSyncStore.pathKey(corrupted.relativePath)]?.state, .failed)

            // Once the NAS behaves, the next sync finishes the job.
            NASFileIO.verificationHashOverride = nil
            chmod(unreadable.sourcePath, 0o644)
            let retry = try NASSyncService(store: store).sync(plan, nasRoot: f.nas)
            XCTAssertEqual(Set(retry.copied), [corrupted.relativePath, unreadable.relativePath])
            XCTAssertTrue(retry.succeeded)
        }
    }

    func testRenameFallsBackToCheckThenRenameWhenExclusiveRenameIsUnsupported() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let expected = try populate(f)
            var calls = 0
            NASFileIO.renameExclusivePrimitive = { _, _ in
                calls += 1
                errno = ENOTSUP
                return -1
            }
            let plan = NASSyncPlanner.plan(events: [f.event], locations: f.locations)
            let report = try NASSyncService(store: nil).sync(plan, nasRoot: f.nas)
            XCTAssertTrue(report.succeeded)
            XCTAssertEqual(calls, plan.items.count)
            XCTAssertEqual(report.copied.count, plan.items.count)
            for item in plan.items {
                XCTAssertEqual(try Data(contentsOf: f.nas.appendingPathComponent(item.relativePath)), expected[item.relativePath])
            }

            // The fallback still refuses a taken destination.
            let a = try writeFile(root.appendingPathComponent("a"), "a")
            let b = try writeFile(root.appendingPathComponent("b"), "b")
            XCTAssertThrowsError(try NASFileIO.renameExclusive(from: a.path, to: b.path))
            XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b")
            NASFileIO.renameExclusivePrimitive = nil
            XCTAssertThrowsError(try NASFileIO.renameExclusive(from: a.path, to: b.path))
            XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b")
        }
    }

    func testAStaleTemporaryFromACrashedSyncIsClearedAndOnlyThatOne() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            try populate(f)
            let plan = NASSyncPlanner.plan(events: [f.event], locations: f.locations)
            let item = try XCTUnwrap(plan.items.first { $0.relativePath.hasSuffix("CAM_0001.OSV") })
            let folder = f.nas.appendingPathComponent(item.relativePath).deletingLastPathComponent()
            let stale = try writeFile(folder.appendingPathComponent(".CAM_0001.OSV\(NASSyncPlanner.temporaryMarker)DEADBEEF"), "partial")
            let unrelated = try writeFile(folder.appendingPathComponent(".CAM_0001.OSV.keep"), "not ours")

            let report = try NASSyncService(store: nil).sync(plan, nasRoot: f.nas)
            XCTAssertTrue(report.succeeded)
            XCTAssertNil(LayoutMigrationDisk.lstatEntry(stale.path))
            XCTAssertNotNil(LayoutMigrationDisk.lstatEntry(unrelated.path))
        }
    }

    func testStoppingLeavesTheRestNotAttemptedAndAnOfflineNASCopiesNothing() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            try populate(f)
            let plan = NASSyncPlanner.plan(events: [f.event], locations: f.locations)
            var checks = 0
            let report = try NASSyncService(store: nil, isCancelled: {
                checks += 1
                return checks > 2
            }).sync(plan, nasRoot: f.nas)
            XCTAssertEqual(report.copied.count, 2)
            XCTAssertEqual(report.notAttempted, plan.items.count - 2)
            XCTAssertNotNil(report.stoppedReason)

            XCTAssertThrowsError(try NASSyncService(store: nil).sync(plan, nasRoot: root.appendingPathComponent("Offline")))
            XCTAssertNil(LayoutMigrationDisk.lstatEntry(root.appendingPathComponent("Offline").path))
        }
    }

    func testFilesAlreadyInTheLegacyArchiveLayoutAreNotCopiedAgainOrTrusted() throws {
        try withTemporaryDirectory { root in
            var f = try fixture(root)
            // The legacy archive lives under the library root, the mirror
            // under the NAS root; put the library on the same "NAS".
            f.configuration.cameraLibraryRootPath = f.nas.path
            f.locations = EventStorageLocations(configuration: f.configuration)
            let expected = try populate(f)
            let osmo = f.locations.originalsRoot(for: f.event, deviceID: "osmo-360", policy: .buffer)
            let assignment = PhotoEventAssignment(sourceRootPath: osmo.path, relativePath: "CAM_0001.OSV", fileSize: 5_000, modifiedAt: Date(), eventID: f.event.id, deviceID: "osmo-360")
            // Archived the old way: same size under Video/.
            try writeFile(try XCTUnwrap(f.locations.legacyArchiveURL(for: assignment, event: f.event)), Data(repeating: 3, count: 5_000))
            // DSC00001.ARW and Transfer 2/DSC00001.ARW both flatten to one
            // legacy RAW/DSC00001.ARW of the same size: ambiguous, so
            // neither is held back.
            let sony = PhotoEventAssignment(sourceRootPath: osmo.path, relativePath: "DSC00001.ARW", fileSize: 3_000, modifiedAt: Date(), eventID: f.event.id, deviceID: "sony-a7v")
            try writeFile(try XCTUnwrap(f.locations.legacyArchiveURL(for: sony, event: f.event)), Data(repeating: 2, count: 3_000))

            let plan = NASSyncPlanner.plan(events: [f.event, f.child], locations: f.locations)
            let mirror = "2026/2026-08-26 Mountain Trip/Originals/Osmo 360/CAM_0001.OSV"
            XCTAssertEqual(plan.inLegacyLayout, [mirror])
            XCTAssertFalse(plan.items.contains { $0.relativePath == mirror })
            XCTAssertEqual(plan.items.count, expected.count - 1)
            let report = try NASSyncService(store: nil).sync(plan, nasRoot: f.nas)
            XCTAssertTrue(report.succeeded)
            XCTAssertNil(LayoutMigrationDisk.lstatEntry(f.nas.appendingPathComponent(mirror).path))
            XCTAssertTrue(report.copied.contains("2026/2026-08-26 Mountain Trip/Originals/Sony A7V/DSC00001.ARW"))
            XCTAssertTrue(report.copied.contains("2026/2026-08-26 Mountain Trip/Originals/Sony A7V/Transfer 2/DSC00001.ARW"))

            // The legacy copy shows as on the NAS but cannot justify Take
            // Off Drive until it is migrated and verified.
            let summary = try XCTUnwrap(EventPresenceScanner.scan(event: f.event, assignments: [assignment], locations: f.locations))
            XCTAssertEqual(summary.onArchive, 1)
            XCTAssertEqual(summary.onLegacyArchiveLayout, 1)
            XCTAssertFalse(try XCTUnwrap(summary.assets.first).archiveIsTrusted)
        }
    }

    func testPresenceSaysWhichNASCopiesSyncVerified() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let originals = f.locations.originalsRoot(for: f.event, deviceID: "sony-a7v", policy: .buffer)
            try writeFile(originals.appendingPathComponent("DSC00001.ARW"), Data(repeating: 1, count: 100))
            try writeFile(originals.appendingPathComponent("DSC00002.ARW"), Data(repeating: 2, count: 100))
            let assignments = ["DSC00001.ARW", "DSC00002.ARW"].map {
                PhotoEventAssignment(sourceRootPath: originals.path, relativePath: $0, fileSize: 100, modifiedAt: Date(), eventID: f.event.id, deviceID: "sony-a7v")
            }
            let store = try NASSyncStore(catalogURL: f.catalog)
            let plan = NASSyncPlanner.plan(events: [f.event], locations: f.locations)
            _ = try NASSyncService(store: store).sync(plan, nasRoot: f.nas)
            // A copy put on the NAS by hand has the right size but was
            // never verified.
            let unverified = PhotoEventAssignment(sourceRootPath: originals.path, relativePath: "DSC00003.ARW", fileSize: 100, modifiedAt: Date(), eventID: f.event.id, deviceID: "sony-a7v")
            try writeFile(originals.appendingPathComponent("DSC00003.ARW"), Data(repeating: 3, count: 100))
            try writeFile(try XCTUnwrap(f.locations.archiveURL(for: unverified, event: f.event)), Data(repeating: 3, count: 100))

            let verified = try store.verifiedDates(nasRoot: f.nas.path, prefixes: [f.locations.layout(for: f.event, deviceID: nil).mirrorEventFolderPath])
            let summary = try XCTUnwrap(EventPresenceScanner.scan(event: f.event, assignments: assignments + [unverified], locations: f.locations, nasVerified: verified))
            XCTAssertEqual(summary.onArchive, 3)
            XCTAssertEqual(summary.verifiedOnArchive, 2)
            XCTAssertNotNil(summary.oldestArchiveVerification)
            XCTAssertFalse(try XCTUnwrap(summary.assets.first { $0.assignment.relativePath == "DSC00003.ARW" }).archiveIsTrusted)
            XCTAssertTrue(try XCTUnwrap(summary.assets.first { $0.assignment.relativePath == "DSC00001.ARW" }).archiveIsTrusted)
        }
    }
}
