@testable import CameraToolkitCore
import Foundation
import GRDB
import XCTest

/// Duplicate detection by content, its hash cache, and the "Keep in X
/// only" resolution that re-hashes before anything moves to Trash.
final class DuplicateReviewTests: XCTestCase {
    private let beach = UUID()
    private let hotel = UUID()

    /// Counts real reads so the tests can prove what was and was not hashed.
    private final class CountingHasher: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var paths: [String] = []

        var scanner: DuplicateScanner.Hasher {
            { [self] url, progress in
                lock.withLock { paths.append(url.lastPathComponent) }
                return try withoutActuallyEscaping(progress) { try FileScanner.sha256(url, progress: $0) }
            }
        }

        func reset() { lock.withLock { paths.removeAll() } }
    }

    private func assignment(_ url: URL, event: UUID) throws -> PhotoEventAssignment {
        let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        return PhotoEventAssignment(
            sourceRootPath: url.deletingLastPathComponent().path,
            relativePath: url.lastPathComponent,
            fileSize: Int64(size),
            modifiedAt: Date(timeIntervalSince1970: 1_780_000_000),
            eventID: event,
            deviceID: "sony-a7v"
        )
    }

    private func candidate(_ url: URL, _ event: UUID) throws -> DuplicateCandidate {
        DuplicateCandidate(owner: .event(event), path: url.path, assignment: try assignment(url, event: event))
    }

    // MARK: Detection

    func testIdenticalAcrossEventsIsAGroupButSameNameDifferentPhotoAndSameEventCopiesAreNot() throws {
        try withTemporaryDirectory { root in
            let a = root.appendingPathComponent("Buffer/Beach", isDirectory: true)
            let b = root.appendingPathComponent("Private/Hotel", isDirectory: true)
            let shared = try writeFile(a.appendingPathComponent("DSC06001.ARW"), "same photo bytes")
            let sharedCopy = try writeFile(b.appendingPathComponent("DSC06001.ARW"), "same photo bytes")
            // Sony reused the number: same name, same size, other picture.
            let reusedA = try writeFile(a.appendingPathComponent("DSC06987.ARW"), "picture number one")
            let reusedB = try writeFile(b.appendingPathComponent("DSC06987.ARW"), "picture number two")
            // Same name, different size: known different without a read.
            let sizedA = try writeFile(a.appendingPathComponent("DSC07000.ARW"), "short")
            let sizedB = try writeFile(b.appendingPathComponent("DSC07000.ARW"), "a much, much longer file here")
            // Two identical files inside one event are not cross-event.
            let twinA = try writeFile(a.appendingPathComponent("IMG_1.JPG"), "twin bytes!!")
            let twinB = try writeFile(a.appendingPathComponent("IMG_2.JPG"), "twin bytes!!")
            // A unique size nobody else has is never read.
            let lonely = try writeFile(b.appendingPathComponent("DSC08000.ARW"), "nobody else is this long at all")

            let hasher = CountingHasher()
            let report = DuplicateScanner(store: nil, readsCaptureDates: false, hasher: hasher.scanner).scan([
                try candidate(shared, beach), try candidate(sharedCopy, hotel),
                try candidate(reusedA, beach), try candidate(reusedB, hotel),
                try candidate(sizedA, beach), try candidate(sizedB, hotel),
                try candidate(twinA, beach), try candidate(twinB, beach),
                try candidate(lonely, hotel),
            ])

            XCTAssertEqual(report.scannedFiles, 9)
            XCTAssertEqual(report.groups.count, 1)
            let group = try XCTUnwrap(report.groups.first)
            XCTAssertEqual(group.fileName, "DSC06001.ARW")
            XCTAssertEqual(group.owners, [DuplicateOwner.event(beach), .event(hotel)].sorted())
            XCTAssertFalse(group.isOneFile)
            XCTAssertEqual(Set(report.nameCollisions.map(\.fileName)), ["DSC06987.ARW", "DSC07000.ARW"])

            // Only sizes two events share were read.
            XCTAssertEqual(Set(hasher.paths), ["DSC06001.ARW", "DSC06987.ARW"])
            XCTAssertEqual(report.hashedFiles, 4)

            let pairs = report.pairs()
            XCTAssertEqual(pairs.count, 1)
            XCTAssertEqual(pairs.first?.fileCount, 1)
            XCTAssertEqual(pairs.first?.byteCount, Int64("same photo bytes".utf8.count))
            XCTAssertEqual(report.collisionPairs().first?.collisions.count, 2)
        }
    }

    func testOneFileAssignedToTwoEventsIsFlaggedAsOneFile() throws {
        try withTemporaryDirectory { root in
            let file = try writeFile(root.appendingPathComponent("Unsorted/DSC00001.ARW"), "one file")
            let link = root.appendingPathComponent("Other/DSC00001.ARW")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: file, to: link)
            let report = DuplicateScanner(store: nil, readsCaptureDates: false).scan([
                try candidate(file, beach), try candidate(link, hotel),
            ])
            XCTAssertEqual(report.groups.count, 1)
            XCTAssertTrue(try XCTUnwrap(report.groups.first).isOneFile)
        }
    }

    func testHashCacheIsReusedAndMissesAfterMtimeOrSizeChange() throws {
        try withTemporaryDirectory { root in
            let store = try DuplicateReviewStore(url: root.appendingPathComponent(DuplicateReviewStore.fileName))
            let a = try writeFile(root.appendingPathComponent("A/DSC00001.ARW"), "cached bytes")
            let b = try writeFile(root.appendingPathComponent("B/DSC00001.ARW"), "cached bytes")
            let candidates = [try candidate(a, beach), try candidate(b, hotel)]
            let hasher = CountingHasher()
            let scanner = DuplicateScanner(store: store, readsCaptureDates: false, hasher: hasher.scanner)

            let first = scanner.scan(candidates)
            XCTAssertEqual(first.hashedFiles, 2)
            XCTAssertEqual(first.groups.count, 1)

            hasher.reset()
            let second = scanner.scan(candidates)
            XCTAssertEqual(second.hashedFiles, 0)
            XCTAssertEqual(second.cachedFiles, 2)
            XCTAssertTrue(hasher.paths.isEmpty)
            XCTAssertEqual(second.groups.count, 1)

            // A touch alone invalidates: same bytes, new modification time.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: a.path)
            hasher.reset()
            let touched = scanner.scan(candidates)
            XCTAssertEqual(hasher.paths, ["DSC00001.ARW"])
            XCTAssertEqual(touched.cachedFiles, 1)
            XCTAssertEqual(touched.groups.count, 1)

            // A size change invalidates too — and the copies now differ.
            try writeFile(b, "cached bytes, then edited")
            try writeFile(a, "cached bytes, then EDITED")
            hasher.reset()
            let resized = scanner.scan(candidates)
            XCTAssertEqual(Set(hasher.paths), ["DSC00001.ARW"])
            XCTAssertEqual(resized.hashedFiles, 2)
            XCTAssertTrue(resized.groups.isEmpty)
            XCTAssertEqual(resized.nameCollisions.count, 1)
        }
    }

    func testKeepBothPersistsAcrossStoresAndReturnsWhenAThirdOwnerAppears() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent(DuplicateReviewStore.fileName)
            let a = try writeFile(root.appendingPathComponent("A/X.ARW"), "kept both")
            let b = try writeFile(root.appendingPathComponent("B/X.ARW"), "kept both")
            let report = DuplicateScanner(store: nil, readsCaptureDates: false).scan([try candidate(a, beach), try candidate(b, hotel)])
            let group = try XCTUnwrap(report.groups.first)

            try DuplicateReviewStore(url: url).markReviewed([group])
            CatalogDatabase.checkpointAndClose(url: url)
            let reviewed = try DuplicateReviewStore(url: url).reviewedGroupKeys()
            XCTAssertEqual(reviewed, [group.id])
            let pairs = report.pairs(reviewed: reviewed)
            XCTAssertEqual(pairs.first?.fileCount, 0)
            XCTAssertEqual(pairs.first?.reviewedCount, 1)
            XCTAssertTrue(report.groups(sharedBy: .event(beach), reviewed: reviewed).isEmpty)

            let c = try writeFile(root.appendingPathComponent("C/X.ARW"), "kept both")
            let third = UUID()
            let wider = DuplicateScanner(store: nil, readsCaptureDates: false).scan([
                try candidate(a, beach), try candidate(b, hotel), try candidate(c, third),
            ])
            XCTAssertFalse(reviewed.contains(try XCTUnwrap(wider.groups.first).id))

            try DuplicateReviewStore(url: url).clearReviewed([group.id])
            XCTAssertTrue(try DuplicateReviewStore(url: url).reviewedGroupKeys().isEmpty)
        }
    }

    // MARK: Resolution

    private func scanPair(_ root: URL) throws -> (keep: URL, drop: URL, group: DuplicateGroup) {
        let keep = try writeFile(root.appendingPathComponent("Buffer/2026/Beach/Originals/Sony A7V/DSC06001.ARW"), "identical raw bytes")
        let drop = try writeFile(root.appendingPathComponent("Private/2026/Hotel/Originals/Sony A7V/DSC06001.ARW"), "identical raw bytes")
        let report = DuplicateScanner(store: nil, readsCaptureDates: false).scan([try candidate(keep, beach), try candidate(drop, hotel)])
        return (keep, drop, try XCTUnwrap(report.groups.first))
    }

    func testKeepOnlyMovesTheOtherCopyToTrashAndItRestores() throws {
        try withTemporaryDirectory { root in
            let (keep, drop, group) = try scanPair(root)
            let trashRoot = root.appendingPathComponent("Removed/_Trash", isDirectory: true)
            let service = MediaTrashService(removedFilesRoot: trashRoot, volumeRoot: { _ in nil })
            let outcome = try DuplicateResolver(trash: service).resolve([
                DuplicateResolution(group: group, keep: .event(beach), drop: [.event(hotel)]),
            ], context: TrashContext(eventIDsByPathKey: [EventStorageLocations.pathKey(drop.path): hotel]))

            XCTAssertEqual(outcome.trashed.map(\.path), [drop.path])
            XCTAssertTrue(outcome.refused.isEmpty)
            XCTAssertEqual(outcome.removedAssignments.map(\.eventID), [hotel])
            XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: drop.path))
            let batch = try XCTUnwrap(outcome.trashBatch)
            XCTAssertEqual(batch.entries.first?.eventID, hotel)

            let listed = try XCTUnwrap(service.listBatches(under: [trashRoot]).first)
            let restored = service.restore(batch: listed)
            XCTAssertEqual(restored.restored.count, 1)
            XCTAssertEqual(try String(contentsOf: drop, encoding: .utf8), "identical raw bytes")
        }
    }

    func testResolverRehashesAndRefusesAChangedCopy() throws {
        try withTemporaryDirectory { root in
            let (keep, drop, group) = try scanPair(root)
            // Same size, different bytes: only a fresh hash can tell.
            try writeFile(drop, "identical raw BYTES")
            let trashRoot = root.appendingPathComponent("Removed/_Trash", isDirectory: true)
            let outcome = try DuplicateResolver(trash: MediaTrashService(removedFilesRoot: trashRoot, volumeRoot: { _ in nil })).resolve([
                DuplicateResolution(group: group, keep: .event(beach), drop: [.event(hotel)]),
            ])
            XCTAssertTrue(outcome.trashed.isEmpty)
            XCTAssertTrue(outcome.removedAssignments.isEmpty)
            XCTAssertEqual(outcome.refused.count, 1)
            XCTAssertNil(outcome.trashBatch)
            XCTAssertEqual(try String(contentsOf: drop, encoding: .utf8), "identical raw BYTES")
            XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: trashRoot.path))
        }
    }

    func testResolverRefusesTheWholeGroupWhenTheKeptCopyChanged() throws {
        try withTemporaryDirectory { root in
            let (keep, drop, group) = try scanPair(root)
            try writeFile(keep, "the kept one changed")
            let outcome = try DuplicateResolver(trash: MediaTrashService(removedFilesRoot: root.appendingPathComponent("_Trash"), volumeRoot: { _ in nil })).resolve([
                DuplicateResolution(group: group, keep: .event(beach), drop: [.event(hotel)]),
            ])
            XCTAssertEqual(outcome.refused.map(\.copy.path), [drop.path])
            XCTAssertTrue(FileManager.default.fileExists(atPath: drop.path))
            XCTAssertTrue(outcome.removedAssignments.isEmpty)
        }
    }

    func testOneFileListedTwiceOnlyLosesTheExtraAssignment() throws {
        try withTemporaryDirectory { root in
            let file = try writeFile(root.appendingPathComponent("Unsorted/DSC00001.ARW"), "one file")
            let link = root.appendingPathComponent("Other/DSC00001.ARW")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: file, to: link)
            let group = try XCTUnwrap(DuplicateScanner(store: nil, readsCaptureDates: false)
                .scan([try candidate(file, beach), try candidate(link, hotel)]).groups.first)
            let outcome = try DuplicateResolver(trash: MediaTrashService(removedFilesRoot: root.appendingPathComponent("_Trash"), volumeRoot: { _ in nil })).resolve([
                DuplicateResolution(group: group, keep: .event(beach), drop: [.event(hotel)]),
            ])
            XCTAssertTrue(outcome.trashed.isEmpty)
            XCTAssertEqual(outcome.unassigned.map(\.path), [link.path])
            XCTAssertEqual(outcome.removedAssignments.map(\.eventID), [hotel])
            XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
            XCTAssertNil(outcome.trashBatch)
        }
    }

    func testProtectedCopyKeepsItsFile() throws {
        try withTemporaryDirectory { root in
            let (_, drop, group) = try scanPair(root)
            let outcome = try DuplicateResolver(trash: MediaTrashService(removedFilesRoot: root.appendingPathComponent("_Trash"), volumeRoot: { _ in nil })).resolve(
                [DuplicateResolution(group: group, keep: .event(beach), drop: [.event(hotel)])],
                protectedPathKeys: [EventStorageLocations.pathKey(drop.path)]
            )
            XCTAssertTrue(outcome.trashed.isEmpty)
            XCTAssertEqual(outcome.unassigned.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: drop.path))
        }
    }

    /// The resolver's removed assignments, saved the way the app's catalog
    /// writer saves (`CatalogStateStore.apply`, one transaction): exactly
    /// the dropped event's row goes, and its location and Immich rows
    /// cascade away. The kept event's rows are untouched.
    func testRemovedAssignmentsLeaveTheCatalogWithTheirCascadingRows() throws {
        try withTemporaryDirectory { root in
            let (_, _, group) = try scanPair(root)
            let catalogURL = root.appendingPathComponent("Support/catalog.sqlite")
            try CatalogStore(url: catalogURL).prepareSchema()
            let keptAssignment = try XCTUnwrap(group.copies(of: .event(beach)).first?.assignment)
            let droppedAssignment = try XCTUnwrap(group.copies(of: .event(hotel)).first?.assignment)
            let state = CatalogOwnedState(
                savedEvents: [
                    SavedCameraEvent(id: beach, name: "Beach", eventDate: Date(timeIntervalSince1970: 1_780_000_000)),
                    SavedCameraEvent(id: hotel, name: "Hotel", eventDate: Date(timeIntervalSince1970: 1_780_000_000), storagePolicy: .archiveOnly),
                ],
                photoEventAssignments: [keptAssignment, droppedAssignment]
            )
            let store = CatalogStateStore(url: catalogURL)
            _ = try store.migrate(
                state: state,
                configurationURL: nil,
                backups: CatalogBackupService(catalogURL: catalogURL, configurationURL: nil, localFolder: root.appendingPathComponent("Support/Backups"), remoteFolder: nil)
            )
            let now = ISO8601DateFormatter().string(from: Date())
            try CatalogDatabase.writer(for: catalogURL).write { db in
                for id in [CatalogStore.eventAssetID(keptAssignment), CatalogStore.eventAssetID(droppedAssignment)] {
                    try db.execute(sql: "INSERT INTO event_asset_locations(event_asset_id, location, state, checked_at) VALUES (?, 'buffer', 1, ?)", arguments: [id, now])
                    try db.execute(sql: "INSERT INTO immich_assets(event_asset_id, status, checked_at) VALUES (?, 'uploaded', ?)", arguments: [id, now])
                }
            }

            let outcome = try DuplicateResolver(trash: MediaTrashService(removedFilesRoot: root.appendingPathComponent("_Trash"), volumeRoot: { _ in nil })).resolve([
                DuplicateResolution(group: group, keep: .event(beach), drop: [.event(hotel)]),
            ])
            let summary = try store.apply(from: state, to: state.removingAssignments(outcome.removedAssignments))
            XCTAssertEqual(summary.assignmentsDeleted, 1)
            XCTAssertEqual(summary.assignmentsWritten, 0)

            try CatalogDatabase.writer(for: catalogURL).read { db in
                XCTAssertEqual(try String.fetchAll(db, sql: "SELECT id FROM event_assets"), [CatalogStore.eventAssetID(keptAssignment)])
                XCTAssertEqual(try String.fetchAll(db, sql: "SELECT event_asset_id FROM event_asset_locations"), [CatalogStore.eventAssetID(keptAssignment)])
                XCTAssertEqual(try String.fetchAll(db, sql: "SELECT event_asset_id FROM immich_assets"), [CatalogStore.eventAssetID(keptAssignment)])
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events"), 2)
                XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
            CatalogDatabase.checkpointAndClose(url: catalogURL)
        }
    }

    // MARK: Move conflicts

    func testMoveConflictClassification() throws {
        try withTemporaryDirectory { root in
            let incoming = try writeFile(root.appendingPathComponent("From/DSC06987.ARW"), "photo bytes 1")
            let identical = try writeFile(root.appendingPathComponent("To1/DSC06987.ARW"), "photo bytes 1")
            let reused = try writeFile(root.appendingPathComponent("To2/DSC06987.ARW"), "photo bytes 2")
            let sized = try writeFile(root.appendingPathComponent("To3/DSC06987.ARW"), "a longer, different photo")
            let link = root.appendingPathComponent("To4/DSC06987.ARW")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: incoming, to: link)

            XCTAssertEqual(MoveConflictCheck.classify(incomingPath: incoming.path, existingPath: identical.path), .identical)
            XCTAssertEqual(MoveConflictCheck.classify(incomingPath: incoming.path, existingPath: reused.path), .different)
            XCTAssertEqual(MoveConflictCheck.classify(
                incomingPath: incoming.path,
                existingPath: sized.path,
                hasher: { _ in XCTFail("different sizes need no hash"); return "" }
            ), .different)
            XCTAssertEqual(MoveConflictCheck.classify(incomingPath: incoming.path, existingPath: link.path), .sameFile)
            guard case .unreadable = MoveConflictCheck.classify(incomingPath: incoming.path, existingPath: root.appendingPathComponent("gone.ARW").path) else {
                return XCTFail("a missing file is never decided")
            }
            guard case .unreadable = MoveConflictCheck.classify(
                incomingPath: incoming.path,
                existingPath: identical.path,
                hasher: { _ in throw ToolkitError.commandFailed("read error") }
            ) else {
                return XCTFail("a read failure is never decided")
            }
        }
    }

    /// Identical → merged, the extra copy in Trash; different → moved in
    /// as "(2)" with its sidecar; unreadable → stays; free name → moves.
    func testEventMoveDecidesTakenNamesByContent() throws {
        try withTemporaryDirectory { root in
            let from = root.appendingPathComponent("Buffer/Hotel/Originals/Sony A7V", isDirectory: true)
            let to = root.appendingPathComponent("Buffer/Beach/Originals/Sony A7V", isDirectory: true)
            let same = try writeFile(from.appendingPathComponent("DSC00001.ARW"), "already there")
            try writeFile(to.appendingPathComponent("DSC00001.ARW"), "already there")
            let reused = try writeFile(from.appendingPathComponent("DSC06987.ARW"), "the new picture")
            let reusedXMP = try writeFile(from.appendingPathComponent("DSC06987.xmp"), "<xmp/>")
            let existingReused = try writeFile(to.appendingPathComponent("DSC06987.ARW"), "an older picture")
            let lost = try writeFile(from.appendingPathComponent("DSC00005.ARW"), "cannot compare")
            let free = try writeFile(from.appendingPathComponent("DSC00009.ARW"), "free name")

            func item(_ url: URL, takenBy: [URL] = []) throws -> EventMoveItem {
                let removed = try assignment(url, event: hotel)
                var added = removed
                added.eventID = beach
                added.sourceRootPath = to.path
                return EventMoveItem(
                    removed: removed,
                    added: added,
                    move: DriveMove(sourcePath: url.path, destinationPath: to.appendingPathComponent(url.lastPathComponent).path, byteCount: removed.fileSize),
                    currentPath: url.path,
                    takenBy: takenBy.map(\.path)
                )
            }
            let trashRoot = root.appendingPathComponent("Removed/_Trash", isDirectory: true)
            let outcome = try EventMoveService(trash: MediaTrashService(removedFilesRoot: trashRoot, volumeRoot: { _ in nil })).move(
                [
                    // Taken on disk only: found by the destination check.
                    try item(same),
                    try item(reused, takenBy: [existingReused]),
                    try item(reusedXMP),
                    try item(lost, takenBy: [to.appendingPathComponent("gone/DSC00005.ARW")]),
                    try item(free),
                ],
                title: "Move to Beach",
                journalFolder: root.appendingPathComponent("Journals", isDirectory: true)
            )

            XCTAssertEqual(outcome.merged.map(\.fileName), ["DSC00001.ARW"])
            XCTAssertEqual(outcome.mergedToTrash, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: same.path))
            XCTAssertEqual(try String(contentsOf: to.appendingPathComponent("DSC00001.ARW"), encoding: .utf8), "already there")
            XCTAssertEqual(outcome.trashBatch?.entries.count, 1)

            XCTAssertEqual(outcome.keptBoth.map(\.newName), ["DSC06987 (2).ARW"])
            XCTAssertEqual(try String(contentsOf: to.appendingPathComponent("DSC06987 (2).ARW"), encoding: .utf8), "the new picture")
            XCTAssertEqual(try String(contentsOf: existingReused, encoding: .utf8), "an older picture")
            XCTAssertTrue(FileManager.default.fileExists(atPath: to.appendingPathComponent("DSC06987 (2).xmp").path))

            XCTAssertEqual(outcome.stayed.map(\.item.fileName), ["DSC00005.ARW"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: lost.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: to.appendingPathComponent("DSC00009.ARW").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: free.path))

            // The catalog change: every file but the stayed one leaves Hotel;
            // the merged one adopts Beach's untracked file, the rest arrive
            // under their final names.
            XCTAssertEqual(Set(outcome.removedAssignments.map(\.relativePath)), ["DSC00001.ARW", "DSC06987.ARW", "DSC06987.xmp", "DSC00009.ARW"])
            XCTAssertEqual(Set(outcome.addedAssignments.map(\.relativePath)), ["DSC00001.ARW", "DSC06987 (2).ARW", "DSC06987 (2).xmp", "DSC00009.ARW"])
            XCTAssertTrue(outcome.addedAssignments.allSatisfy { $0.eventID == beach })

            // One journal: Undo puts every rename back, nothing replaced.
            let journal = try XCTUnwrap(outcome.report.journalPath)
            let undone = try DriveMoveService().undo(journalURL: URL(fileURLWithPath: journal))
            XCTAssertEqual(undone.report.moved.count, 3)
            XCTAssertTrue(FileManager.default.fileExists(atPath: reused.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: reusedXMP.path))
        }
    }

    func testIdenticalMergeNeverTrashesAFileOthersStillUse() throws {
        try withTemporaryDirectory { root in
            let from = root.appendingPathComponent("From", isDirectory: true)
            let to = root.appendingPathComponent("To", isDirectory: true)
            let incoming = try writeFile(from.appendingPathComponent("DSC00001.ARW"), "same")
            let existing = try writeFile(to.appendingPathComponent("DSC00001.ARW"), "same")
            let removed = try assignment(incoming, event: hotel)
            var added = removed
            added.eventID = beach
            let outcome = try EventMoveService(trash: MediaTrashService(removedFilesRoot: root.appendingPathComponent("_Trash"), volumeRoot: { _ in nil })).move(
                [EventMoveItem(removed: removed, added: added, move: nil, currentPath: incoming.path, takenBy: [existing.path])],
                title: "Move",
                journalFolder: nil,
                protectedPathKeys: [EventStorageLocations.pathKey(incoming.path)]
            )
            XCTAssertEqual(outcome.merged.count, 1)
            XCTAssertEqual(outcome.mergedToTrash, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.path))
            XCTAssertEqual(outcome.removedAssignments, [removed])
            XCTAssertTrue(outcome.addedAssignments.isEmpty)
        }
    }
}
