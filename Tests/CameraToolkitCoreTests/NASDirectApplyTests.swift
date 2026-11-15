@testable import CameraToolkitCore
import Darwin
import Foundation
import XCTest

/// Apply straight to the NAS: with the event's drive unplugged, sorted card
/// files go through the Sync to NAS engine into the event's NAS folder —
/// the path and the record Sync would have produced from the drive copy —
/// and the card is only ever read. Clear from Card and a later Sync agree
/// with those records; a different NAS file at the path is never touched.
final class NASDirectApplyTests: XCTestCase {
    private struct Fixture {
        var root: URL
        var card: URL
        var nas: URL
        var catalog: URL
        var configuration: AppConfiguration
        var locations: EventStorageLocations
        var beach: SavedCameraEvent
        var hotel: SavedCameraEvent
        var assignments: [PhotoEventAssignment]

        func event(_ id: UUID) -> SavedCameraEvent { id == beach.id ? beach : hotel }

        func targets(_ rows: [PhotoEventAssignment]? = nil) -> [NASDirectCopyFile] {
            (rows ?? assignments).map { row in
                NASDirectCopyFile(
                    sourcePath: card.appendingPathComponent(row.relativePath).path,
                    relativePath: NASDirectApply.mirrorPath(for: row, event: event(row.eventID), locations: locations)!,
                    byteCount: row.fileSize,
                    eventID: row.eventID
                )
            }
        }
    }

    /// The Buffer is a drive that is not mounted; the NAS and the card are
    /// folders. "Beach Day" is shared, "Hotel Night" private — Sync sends
    /// both to the NAS mirror, so this path does too.
    private func makeFixture(_ root: URL, names: [String] = ["DSC00001.ARW", "DSC00002.ARW", "C0001.MP4"]) throws -> Fixture {
        let offline = "/Volumes/CT-Offline-\(UUID().uuidString)/Camera Buffer"
        var configuration = testConfiguration(root: root, bufferPath: offline)
        let catalog = root.appendingPathComponent("catalog.sqlite")
        configuration.catalogDatabasePath = catalog.path
        let beach = SavedCameraEvent(name: "Beach Day", eventDate: DateFormatter.yyyyMMdd.date(from: "2026-08-26")!)
        let hotel = SavedCameraEvent(name: "Hotel Night", eventDate: DateFormatter.yyyyMMdd.date(from: "2026-08-26")!, storagePolicy: .archiveOnly)
        configuration.savedEvents = [beach, hotel]
        let card = root.appendingPathComponent("Card/DCIM/100MSDCF", isDirectory: true)
        var rows: [PhotoEventAssignment] = []
        for (index, name) in names.enumerated() {
            let data = Data((0..<4_096).map { UInt8(($0 &* 13 &+ index &* 5) & 0xff) })
            let url = try writeFile(card.appendingPathComponent(name), data)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            rows.append(PhotoEventAssignment(
                sourceRootPath: card.path,
                relativePath: name,
                fileSize: Int64(data.count),
                modifiedAt: attributes[.modificationDate] as! Date,
                eventID: index == names.count - 1 ? hotel.id : beach.id,
                deviceID: "sony-a7v"
            ))
        }
        configuration.photoEventAssignments = rows
        let nas = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        let locations = EventStorageLocations(configuration: configuration)
        XCTAssertFalse(VolumeInfo.isAvailable(locations.bufferRoot))
        XCTAssertTrue(NASDirectApply.isNASUsable(locations))
        return Fixture(root: root, card: card, nas: nas, catalog: catalog, configuration: configuration, locations: locations, beach: beach, hotel: hotel, assignments: rows)
    }

    private struct Identity: Equatable {
        var data: Data
        var size: Int64
        var modified: Double
        var inode: UInt64
    }

    private func identities(_ folder: URL) throws -> [String: Identity] {
        var result: [String: Identity] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let path = folder.appendingPathComponent(name).path
            var info = stat()
            XCTAssertEqual(lstat(path, &info), 0)
            result[name] = Identity(
                data: try Data(contentsOf: URL(fileURLWithPath: path)),
                size: Int64(info.st_size),
                modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
                inode: UInt64(info.st_ino)
            )
        }
        return result
    }

    private func run(_ f: Fixture, _ targets: [NASDirectCopyFile]? = nil) throws -> NASDirectApplyOutcome {
        try NASDirectApply.run(
            targets ?? f.targets(),
            configuration: f.configuration,
            store: try NASSyncStore(catalogURL: f.catalog),
            options: NASSyncOptions(),
            isCancelled: { false }
        )
    }

    func testCopiesIntoTheEventsNASFolderWithSyncRecordsAndNeverTouchesTheSource() throws {
        try withTemporaryDirectory { root in
            let f = try makeFixture(root)
            let before = try identities(f.card)

            let outcome = try run(f)

            XCTAssertTrue(outcome.succeeded, "\(outcome.report)")
            XCTAssertEqual(outcome.report.copied.count, 3)
            // The card is exactly as it was: bytes, size, time, file number.
            XCTAssertEqual(try identities(f.card), before)
            let records = try NASSyncStore(catalogURL: f.catalog).records(nasRoot: f.locations.nasRoot.path)
            for row in f.assignments {
                let event = f.event(row.eventID)
                // The same path Sync to NAS gives the drive copy.
                let drivePath = f.locations.driveURL(for: row, event: event, policy: f.locations.resolvedPolicy(for: event))!.path
                let syncPath = try XCTUnwrap(f.locations.mirrorRelativePath(forDrivePath: drivePath))
                XCTAssertEqual(NASDirectApply.mirrorPath(for: row, event: event, locations: f.locations), syncPath)
                let copy = f.nas.appendingPathComponent(syncPath)
                XCTAssertEqual(try Data(contentsOf: copy), before[row.relativePath]?.data, syncPath)
                let record = try XCTUnwrap(records[NASSyncStore.pathKey(syncPath)])
                XCTAssertEqual(record.state, .verified)
                XCTAssertNotNil(record.verifiedAt)
                XCTAssertEqual(record.sha256, try FileScanner.sha256(f.card.appendingPathComponent(row.relativePath)))
                XCTAssertEqual(record.byteCount, row.fileSize)
                XCTAssertEqual(record.eventID, row.eventID)
                XCTAssertEqual(try XCTUnwrap(record.sourceModifiedAt), try XCTUnwrap(before[row.relativePath]?.modified) - Date.timeIntervalBetween1970AndReferenceDate, accuracy: 0.001)
                XCTAssertTrue(NASDirectApply.vouches(record, sourcePath: f.card.appendingPathComponent(row.relativePath).path, byteCount: row.fileSize))
            }
            // The private event lands in its own NAS folder, like Sync.
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.nas.appendingPathComponent("2026/2026-08-26 Hotel Night/Originals/Sony A7V/C0001.MP4").path))

            // Again: every file is already verified, nothing is copied.
            let again = try run(f)
            XCTAssertEqual(again.report.copied.count, 0)
            XCTAssertEqual(again.report.alreadyVerified.count, 3)
            XCTAssertEqual(try identities(f.card), before)
        }
    }

    func testADifferentFileOnTheNASIsLeftUntouchedAndReported() throws {
        try withTemporaryDirectory { root in
            let f = try makeFixture(root)
            let targets = f.targets()
            // Same size, different bytes; and a different size.
            let sameSize = f.nas.appendingPathComponent(targets[0].relativePath)
            try writeFile(sameSize, Data(repeating: 0x41, count: 4_096))
            let otherSize = f.nas.appendingPathComponent(targets[1].relativePath)
            try writeFile(otherSize, Data(repeating: 0x42, count: 10))
            let nasBefore = [sameSize: try Data(contentsOf: sameSize), otherSize: try Data(contentsOf: otherSize)]
            let cardBefore = try identities(f.card)

            let outcome = try run(f, targets)

            XCTAssertFalse(outcome.succeeded)
            XCTAssertEqual(Set(outcome.report.conflicts.map(\.path)), [targets[0].relativePath, targets[1].relativePath])
            XCTAssertEqual(outcome.report.copied, [targets[2].relativePath])
            for (url, data) in nasBefore {
                XCTAssertEqual(try Data(contentsOf: url), data, "a NAS file is never replaced")
            }
            XCTAssertEqual(try identities(f.card), cardBefore)
            // A conflict never counts as verified: Clear from Card and the
            // Apply plan do not trust it.
            let records = try NASSyncStore(catalogURL: f.catalog).records(nasRoot: f.locations.nasRoot.path)
            for target in targets.prefix(2) {
                XCTAssertFalse(NASDirectApply.vouches(records[NASSyncStore.pathKey(target.relativePath)], sourcePath: target.sourcePath, byteCount: target.byteCount))
            }
        }
    }

    func testASourceThatChangedOrVanishedIsLeftOutBeforeCopying() throws {
        try withTemporaryDirectory { root in
            let f = try makeFixture(root)
            var targets = f.targets()
            targets[0].byteCount += 1
            try FileManager.default.removeItem(atPath: targets[1].sourcePath)
            let outcome = try run(f, targets)
            XCTAssertEqual(outcome.skipped.count, 2)
            XCTAssertEqual(outcome.report.copied, [targets[2].relativePath])
            XCTAssertFalse(outcome.succeeded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.nas.appendingPathComponent(targets[0].relativePath).path))
        }
    }

    func testClearFromCardAndALaterSyncAgreeWithTheRecords() throws {
        try withTemporaryDirectory { root in
            let f = try makeFixture(root)
            let outcome = try run(f)
            XCTAssertTrue(outcome.succeeded)
            let cardBefore = try identities(f.card)

            // Clear from Card: the drive is away, so each card file is
            // clearable on its NAS copy alone, marked as such.
            let inputs = f.assignments.map { row in
                CardClearInput(
                    id: EventStorageLocations.pathKey(f.card.appendingPathComponent(row.relativePath).path),
                    entries: [.init(path: f.card.appendingPathComponent(row.relativePath).path, assignment: row)]
                )
            }
            let events = Dictionary(uniqueKeysWithValues: f.configuration.savedEvents.map { ($0.id, $0) })
            let plan = CardClearPlanner.plan(inputs: inputs, sourceRoot: f.card.path, events: events, locations: f.locations, catalogURL: f.catalog)
            XCTAssertEqual(plan.clearableFiles, 3)
            XCTAssertEqual(plan.nasOnlyFiles, 3)
            XCTAssertEqual(plan.waitingFiles, 0)
            XCTAssertEqual(Set(plan.applied.keys), Set(inputs.map(\.id)), "the board stops calling them waiting for Apply")
            XCTAssertTrue(plan.clearable.allSatisfy { $0.files.allSatisfy(\.nasOnly) })

            // The NAS away: nothing is cleared, and the reason says so.
            let offline = try CardClearService().clear(items: plan.clearable, nasReachable: false, confirmation: FreeUpService.confirmationToken)
            XCTAssertTrue(offline.cleared.isEmpty)
            XCTAssertTrue(offline.skipped.values.allSatisfy { $0.contains("NAS is not connected") })
            XCTAssertEqual(try identities(f.card), cardBefore)

            // A later Sync to NAS of a drive copy with the same bytes and
            // time finds every file already verified and copies nothing.
            let drive = root.appendingPathComponent("Returned Buffer", isDirectory: true)
            var items: [NASSyncItem] = []
            for target in f.targets() {
                let copy = drive.appendingPathComponent(target.relativePath)
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: target.sourcePath, toPath: copy.path)
                let modified = try XCTUnwrap(cardBefore[(target.sourcePath as NSString).lastPathComponent]?.modified)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: copy.path)
                items.append(NASSyncItem(
                    sourcePath: copy.path,
                    relativePath: target.relativePath,
                    byteCount: target.byteCount,
                    modifiedAt: LayoutMigrationDisk.lstatEntry(copy.path)!.modifiedAt,
                    eventID: target.eventID
                ))
            }
            let resync = try NASSyncService(store: try NASSyncStore(catalogURL: f.catalog), isCancelled: { false })
                .sync(NASSyncPlan(items: items), nasRoot: f.nas)
            XCTAssertEqual(resync.copied, [])
            XCTAssertEqual(resync.alreadyVerified.count, 3)

            // With the NAS here, the card files go only after the NAS copy
            // and the card file both hash to the verified hash. The NAS is
            // only read.
            let nasBefore = try treeBytes(f.nas)
            let cleared = try CardClearService().clear(items: plan.clearable, nasReachable: true, confirmation: FreeUpService.confirmationToken)
            XCTAssertEqual(cleared.cleared.count, 3, "\(cleared.skipped)")
            XCTAssertEqual(cleared.checks.nasMatched, 3)
            XCTAssertEqual(cleared.checks.cardMatched, 3)
            XCTAssertEqual(try treeBytes(f.nas), nasBefore)
        }
    }

    private func clearPlan(_ f: Fixture) -> CardClearPlan {
        let inputs = f.assignments.map { row in
            CardClearInput(
                id: EventStorageLocations.pathKey(f.card.appendingPathComponent(row.relativePath).path),
                entries: [.init(path: f.card.appendingPathComponent(row.relativePath).path, assignment: row)]
            )
        }
        let events = Dictionary(uniqueKeysWithValues: f.configuration.savedEvents.map { ($0.id, $0) })
        return CardClearPlanner.plan(inputs: inputs, sourceRoot: f.card.path, events: events, locations: f.locations, catalogURL: f.catalog)
    }

    /// The record alone never makes a card file "applied" or clearable: a
    /// NAS copy deleted outside the app, or a NAS that is not connected,
    /// leaves it waiting.
    func testARecordAloneIsNotEnoughWhenTheNASCopyIsGoneOrTheNASIsAway() throws {
        try withTemporaryDirectory { root in
            let f = try makeFixture(root)
            XCTAssertTrue(try run(f).succeeded)
            XCTAssertEqual(clearPlan(f).nasOnlyFiles, 3)

            // One NAS copy deleted outside the app.
            let gone = f.targets()[0]
            try FileManager.default.removeItem(at: f.nas.appendingPathComponent(gone.relativePath))
            var plan = clearPlan(f)
            XCTAssertNil(plan.applied[EventStorageLocations.pathKey(gone.sourcePath)])
            XCTAssertEqual(plan.nasOnlyFiles, 2)
            XCTAssertFalse(plan.clearable.contains { $0.files.contains { $0.sourcePath == gone.sourcePath } })

            // The NAS not connected: nothing is applied or clearable on it,
            // and the files are counted as not checked.
            let away = root.appendingPathComponent("NAS away", isDirectory: true)
            try FileManager.default.moveItem(at: f.nas, to: away)
            plan = clearPlan(f)
            XCTAssertTrue(plan.applied.isEmpty)
            XCTAssertTrue(plan.clearable.isEmpty)
            XCTAssertEqual(plan.nasUncheckedFiles, 3)
            try FileManager.default.moveItem(at: away, to: f.nas)
        }
    }

    /// The copy uses the catalog as it is when the job starts: a file whose
    /// event was renamed or which was re-sorted while the job waited is left
    /// out and reported, never copied into the old folder.
    func testAFileRenamedOrReSortedWhileTheJobWaitedIsLeftOut() throws {
        try withTemporaryDirectory { root in
            let f = try makeFixture(root)
            let planned = f.targets()
            var later = f.configuration
            // Beach Day renamed; the private event's file re-sorted into it.
            later.savedEvents[0].name = "Beach Weekend"
            later.photoEventAssignments[2].eventID = f.beach.id
            let checked = NASDirectApply.revalidate(planned, configuration: later)
            XCTAssertTrue(checked.kept.isEmpty)
            XCTAssertEqual(checked.dropped.count, 3)
            XCTAssertEqual(checked.dropped.filter { $0.reason.contains("NAS folder changed") }.count, 2)
            XCTAssertEqual(checked.dropped.filter { $0.reason.contains("another event") }.count, 1)

            let outcome = try NASDirectApply.run(planned, configuration: later, store: try NASSyncStore(catalogURL: f.catalog), options: NASSyncOptions(), isCancelled: { false })
            XCTAssertTrue(outcome.report.copied.isEmpty)
            XCTAssertEqual(outcome.skipped.count, 3)
            XCTAssertFalse(outcome.succeeded)
            XCTAssertEqual(try treeBytes(f.nas), [:], "nothing lands in the old folder")

            // Unchanged, everything is kept.
            XCTAssertEqual(NASDirectApply.revalidate(planned, configuration: f.configuration).kept, planned)
        }
    }

    func testANASCopyThatChangedKeepsTheCardFile() throws {
        try withTemporaryDirectory { root in
            let f = try makeFixture(root, names: ["DSC00001.ARW"])
            XCTAssertTrue(try run(f).succeeded)
            let target = f.targets()[0]
            let input = CardClearInput(id: EventStorageLocations.pathKey(target.sourcePath), entries: [.init(path: target.sourcePath, assignment: f.assignments[0])])
            let plan = CardClearPlanner.plan(
                inputs: [input], sourceRoot: f.card.path,
                events: [f.beach.id: f.beach, f.hotel.id: f.hotel], locations: f.locations, catalogURL: f.catalog
            )
            XCTAssertEqual(plan.nasOnlyFiles, 1)
            // The NAS copy is corrupted after verification (same size).
            try Data(repeating: 0x7A, count: Int(target.byteCount)).write(to: f.nas.appendingPathComponent(target.relativePath))
            let report = try CardClearService().clear(items: plan.clearable, nasReachable: true, confirmation: FreeUpService.confirmationToken)
            XCTAssertTrue(report.cleared.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.sourcePath))
            XCTAssertTrue(report.skipped[target.sourcePath]?.contains("NAS copy no longer matches") == true)
        }
    }
}
