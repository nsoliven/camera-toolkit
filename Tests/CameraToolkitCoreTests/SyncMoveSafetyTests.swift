@testable import CameraToolkitCore
import CryptoKit
import Darwin
import Foundation
import GRDB
import XCTest

/// Regression tests for the ways the app used to lose TRACK of a file on the
/// NAS (the NAS copy was always kept; what went wrong was that nothing owned,
/// verified or could find it). Each test is the deterministic form of a
/// failure a randomized sweep (`NASChaosHarnessTests`) once found, and now
/// asserts the corrected behavior.
final class SyncMoveSafetyTests: XCTestCase {
    override func tearDown() {
        NASFileIO.renameExclusivePrimitive = nil
        NASFileIO.verificationHashOverride = nil
        super.tearDown()
    }

    private func bytes(_ seed: Int, _ count: Int = 1_200) -> Data { NASSafetyFixtures.bytes(seed, count) }
}

// MARK: - A transient share error must not strand a NAS copy

extension SyncMoveSafetyTests {
    private func opFor(_ w: NASSafetyWorld, name: String, size: Int) -> (batch: NASRenameBatch, from: String, to: String) {
        let from = w.mirror(w.a, name), to = w.mirror(w.b, name)
        return (NASRenameBatch(title: "Move", origin: .move, nasRoot: w.nas.path, ops: [NASRename(from: from, to: to, byteCount: Int64(size))]), from, to)
    }

    func testATransientErrorOnANASOnlyRenameIsRetriedInTheSameRun() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            var (batch, from, to) = opFor(w, name: "DSC00004.ARW", size: 1_200)
            try writeFile(w.nas.appendingPathComponent(from), bytes(4))
            var once = true
            NASFileIO.renameExclusivePrimitive = { source, destination in
                if once { once = false; errno = EIO; return -1 }
                return renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
            let result = try w.follower().apply(&batch, nasRoot: w.nas)
            XCTAssertEqual(result.renamed, 1, result.summary)
            XCTAssertTrue(result.deferred.isEmpty)
            XCTAssertFalse(w.exists(from))
            XCTAssertTrue(w.exists(to))
            XCTAssertEqual(batch.ops[0].attempts, 1, "the one error is on the record")
            XCTAssertEqual(w.queue.pendingRenameCount(), 0)
        }
    }

    func testARenameThatKeepsFailingStaysQueuedAndIsGivenUpOnlyAfterEveryAttempt() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let (batch, from, to) = opFor(w, name: "DSC00004.ARW", size: 1_200)
            try writeFile(w.nas.appendingPathComponent(from), bytes(4))
            NASFileIO.renameExclusivePrimitive = { _, _ in errno = ESTALE; return -1 }
            try w.queue.save(batch)
            var runs = 0
            var last = NASFollowResult()
            while w.queue.pendingRenameCount() > 0, runs < 10 {
                runs += 1
                last = try w.follower().applyPending(nasRoot: w.nas)
                XCTAssertTrue(w.exists(from), "the copy never leaves its place while renames fail")
                XCTAssertFalse(w.exists(to))
            }
            // Two tries a run, six in all: three runs.
            XCTAssertEqual(runs, NASMoveFollower.maxAttempts / NASMoveFollower.attemptsPerRun)
            let saved = try XCTUnwrap(w.queue.batches().first)
            XCTAssertEqual(saved.ops[0].state, .failed)
            XCTAssertEqual(saved.ops[0].attempts, NASMoveFollower.maxAttempts)
            XCTAssertEqual(last.failed.count, 1)
            XCTAssertTrue(last.failed[0].reason.contains("Tried"), last.failed[0].reason)
        }
    }

    func testARenameLeftQueuedByATransientErrorRunsOnTheNextDrain() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let (batch, from, to) = opFor(w, name: "DSC00004.ARW", size: 1_200)
            try writeFile(w.nas.appendingPathComponent(from), bytes(4))
            try w.queue.save(batch)
            NASFileIO.renameExclusivePrimitive = { _, _ in errno = EIO; return -1 }
            let first = try w.follower().applyPending(nasRoot: w.nas)
            XCTAssertEqual(first.deferred.count, 1, first.summary)
            XCTAssertTrue(first.summary.contains("stay queued"), first.summary)
            XCTAssertEqual(w.queue.pendingRenameCount(), 1)
            NASFileIO.renameExclusivePrimitive = nil
            let second = try w.follower().applyPending(nasRoot: w.nas)
            XCTAssertEqual(second.renamed, 1, second.summary)
            XCTAssertTrue(w.exists(to))
            XCTAssertEqual(w.queue.pendingRenameCount(), 0)
        }
    }

    func testANonTransientErrorFailsAtOnceAndIsNotRetried() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            var (batch, from, _) = opFor(w, name: "DSC00004.ARW", size: 1_200)
            try writeFile(w.nas.appendingPathComponent(from), bytes(4))
            var calls = 0
            NASFileIO.renameExclusivePrimitive = { _, _ in calls += 1; errno = EACCES; return -1 }
            let result = try w.follower().apply(&batch, nasRoot: w.nas)
            XCTAssertEqual(result.failed.count, 1)
            XCTAssertEqual(calls, 1)
            XCTAssertNil(batch.ops[0].attempts)
        }
    }

    func testADestinationFolderTheShareLostBetweenCreateAndRenameIsMadeAgain() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            var (batch, from, to) = opFor(w, name: "DSC00004.ARW", size: 1_200)
            try writeFile(w.nas.appendingPathComponent(from), bytes(4))
            let folder = w.nas.appendingPathComponent((to as NSString).deletingLastPathComponent)
            var once = true
            NASFileIO.renameExclusivePrimitive = { source, destination in
                if once {
                    once = false
                    rmdir(folder.path)  // gone between the mkdir and the rename
                    errno = ENOENT
                    return -1
                }
                return renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
            let result = try w.follower().apply(&batch, nasRoot: w.nas)
            XCTAssertEqual(result.renamed, 1, result.summary)
            XCTAssertTrue(w.exists(to))
        }
    }
}

// MARK: - Finding a NAS-only photo whose rename never landed

extension SyncMoveSafetyTests {
    private func repair(_ w: NASSafetyWorld, assignments: [PhotoEventAssignment]) throws -> NASFollowResult {
        try w.follower().catchUp(
            plan: w.plan(),
            ownedKeys: NASCatchUp.ownedKeys(assignments: assignments, locations: w.locations),
            locations: w.locations,
            nasRoot: w.nas,
            assignments: assignments
        )
    }

    func testAStrandedNASOnlyPhotoIsRenamedToWhereTheCatalogNowLooksForIt() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let data = bytes(4)
            let old = try w.placeOnNASOnly(w.a, "DSC00004.ARW", data)
            // The catalog moved the entry to Trip B; the NAS rename never ran.
            let moved = w.assignment(w.b, "DSC00004.ARW", size: data.count)
            let result = try repair(w, assignments: [moved])
            XCTAssertEqual(result.renamed, 1, result.summary)
            XCTAssertFalse(w.exists(old))
            XCTAssertEqual(try Data(contentsOf: w.nas.appendingPathComponent(w.mirror(w.b, "DSC00004.ARW"))), data)
            XCTAssertNotNil(try w.record(w.mirror(w.b, "DSC00004.ARW")), "its record follows it")
            XCTAssertNil(try w.record(old))
        }
    }

    func testTheRepairIsPartOfPreparingASync() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let data = bytes(4)
            let old = try w.placeOnNASOnly(w.a, "DSC00004.ARW", data)
            let moved = w.assignment(w.b, "DSC00004.ARW", size: data.count)
            let prepared = try w.follower().prepareSync(
                events: w.configuration.savedEvents, locations: w.locations, nasRoot: w.nas,
                ownedKeys: NASCatchUp.ownedKeys(assignments: [moved], locations: w.locations), catchUp: true, assignments: [moved]
            )
            XCTAssertEqual(prepared.follow.renamed, 1)
            XCTAssertFalse(w.exists(old))
            XCTAssertTrue(w.exists(w.mirror(w.b, "DSC00004.ARW")))
        }
    }

    func testNoRepairWhenSeveralNASCopiesFitAndNothingIsGuessed() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let one = try w.placeOnNASOnly(w.a, "DSC00001.ARW", bytes(1))
            let two = try w.placeOnNASOnly(w.a, "DSC00002.ARW", bytes(2))  // same size and time as the first
            let moved = w.assignment(w.b, "DSC00009.ARW", size: 1_200)
            let plan = w.plan()
            let analysis = NASCatchUp.repairs(
                assignments: [moved], plan: plan, records: try w.store.records(nasRoot: w.nas.path),
                ownedKeys: NASCatchUp.ownedKeys(assignments: [moved], locations: w.locations),
                locations: w.locations, nasRoot: w.nas.path
            )
            XCTAssertTrue(analysis.repairs.isEmpty)
            XCTAssertEqual(analysis.ambiguous.count, 1)
            let result = try repair(w, assignments: [moved])
            XCTAssertEqual(result.changed, 0)
            XCTAssertTrue(w.exists(one) && w.exists(two))
        }
    }

    func testTheSameNameBreaksATieBetweenSeveralFits() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            _ = try w.placeOnNASOnly(w.a, "DSC00001.ARW", bytes(1))
            let wanted = try w.placeOnNASOnly(w.a, "DSC00002.ARW", bytes(2))
            let moved = w.assignment(w.b, "DSC00002.ARW", size: 1_200)
            let result = try repair(w, assignments: [moved])
            XCTAssertEqual(result.renamed, 1, result.summary)
            XCTAssertFalse(w.exists(wanted))
            XCTAssertTrue(w.exists(w.mirror(w.b, "DSC00002.ARW")))
            XCTAssertTrue(w.exists(w.mirror(w.a, "DSC00001.ARW")))
        }
    }

    func testACopyAnAssignmentStillOwnsIsNeverTakenAsARepair() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let owned = try w.placeOnNASOnly(w.a, "DSC00004.ARW", bytes(4))
            // Two entries name the photo; only Trip B's is missing on the NAS.
            let stay = w.assignment(w.a, "DSC00004.ARW", size: 1_200)
            let gap = w.assignment(w.b, "DSC00004.ARW", size: 1_200)
            let result = try repair(w, assignments: [stay, gap])
            XCTAssertEqual(result.changed, 0)
            XCTAssertTrue(w.exists(owned))
        }
    }

    func testNothingIsRepairedOverAFileAlreadyAtTheNewPath() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let old = try w.placeOnNASOnly(w.a, "DSC00004.ARW", bytes(4))
            let other = try w.placeOnNASOnly(w.b, "DSC00004.ARW", bytes(9, 700), verified: false)
            let moved = w.assignment(w.b, "DSC00004.ARW", size: 1_200)
            let result = try repair(w, assignments: [moved])
            XCTAssertEqual(result.changed, 0)
            XCTAssertTrue(w.exists(old))
            XCTAssertEqual(try Data(contentsOf: w.nas.appendingPathComponent(other)), bytes(9, 700))
        }
    }

    func testACopyOnTheDriveIsLeftToSyncNotRepaired() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let data = bytes(4)
            let old = try w.placeOnNASOnly(w.a, "DSC00004.ARW", data)
            try writeFile(w.drivePath(w.b, "DSC00004.ARW"), data)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_780_000_000)], ofItemAtPath: w.drivePath(w.b, "DSC00004.ARW").path)
            let moved = w.assignment(w.b, "DSC00004.ARW", size: data.count)
            let analysis = NASCatchUp.repairs(
                assignments: [moved], plan: w.plan(), records: try w.store.records(nasRoot: w.nas.path),
                ownedKeys: NASCatchUp.ownedKeys(assignments: [moved], locations: w.locations),
                locations: w.locations, nasRoot: w.nas.path
            )
            XCTAssertTrue(analysis.repairs.isEmpty, "Sync's own catch-up handles files the drive holds")
            XCTAssertTrue(w.exists(old))
        }
    }
}

// MARK: - A NAS-only photo moved onto a name the NAS holds

extension SyncMoveSafetyTests {
    private func moveService(_ w: NASSafetyWorld) -> EventMoveService {
        EventMoveService(
            trash: MediaTrashService(removedFilesRoot: w.locations.removedFilesRoot, volumeRoot: { _ in nil }),
            nasCheck: EventMoveNASCheck(locations: w.locations)
        )
    }

    private func nasOnlyItem(_ w: NASSafetyWorld, name: String, size: Int) -> EventMoveItem {
        let removed = w.assignment(w.a, name, size: size)
        var added = removed
        added.eventID = w.b.id
        return EventMoveItem(
            removed: removed, added: added, move: nil, currentPath: nil,
            nasCopy: NASCopyMove(from: w.mirror(w.a, name), to: w.mirror(w.b, name), driveDestination: w.drivePath(w.b, name).path)
        )
    }

    func testANASOnlyPhotoMovedOntoANameTheNASHoldsMovesInUnderAFreeName() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let real = bytes(7)
            let realPath = try w.placeOnNASOnly(w.a, "DSC00007.ARW", real)
            // A leftover nobody owns, same name and size, in Trip B.
            let leftover = bytes(8)
            let leftoverPath = try w.placeOnNASOnly(w.b, "DSC00007.ARW", leftover, verified: false)

            let outcome = try moveService(w).move([nasOnlyItem(w, name: "DSC00007.ARW", size: real.count)], title: "Move", journalFolder: w.journals)
            XCTAssertEqual(outcome.nasRenamed.count, 1)
            XCTAssertEqual(outcome.moved.count, 1, "one change: the catalog entry, its NAS rename and their Undo go together")
            XCTAssertEqual(outcome.nasRenamed[0].newName, "DSC00007 (2).ARW")
            XCTAssertEqual(outcome.addedAssignments.map(\.relativePath), ["DSC00007 (2).ARW"])

            let owed = NASMoveFollower.renames(forEventMove: outcome, locations: w.locations)
            XCTAssertEqual(owed.moves.count, 1)
            XCTAssertEqual(owed.moves[0].to, w.mirror(w.b, "DSC00007 (2).ARW"))
            var batch = NASRenameBatch(title: "Move", origin: .move, nasRoot: w.nas.path, ops: owed.moves)
            let result = try w.follower().apply(&batch, nasRoot: w.nas)
            XCTAssertEqual(result.renamed, 1, result.summary)
            XCTAssertEqual(try Data(contentsOf: w.nas.appendingPathComponent(leftoverPath)), leftover, "the file that was there is untouched")
            XCTAssertEqual(try Data(contentsOf: w.nas.appendingPathComponent(w.mirror(w.b, "DSC00007 (2).ARW"))), real, "the entry shows the photo it names")
            XCTAssertFalse(w.exists(realPath))
        }
    }

    func testAFreeNameOnTheNASMovesInPlainAndTheNumberSkipsANameAlsoTaken() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let real = bytes(7)
            _ = try w.placeOnNASOnly(w.a, "DSC00007.ARW", real)
            let free = try moveService(w).move([nasOnlyItem(w, name: "DSC00007.ARW", size: real.count)], title: "Move", journalFolder: w.journals)
            XCTAssertEqual(free.moved.count, 1)
            XCTAssertTrue(free.nasRenamed.isEmpty)

            // The NAS also holds " (2)": the next free number is used.
            _ = try w.placeOnNASOnly(w.b, "DSC00007.ARW", bytes(8), verified: false)
            _ = try w.placeOnNASOnly(w.b, "DSC00007 (2).ARW", bytes(9), verified: false)
            let skipping = try moveService(w).move([nasOnlyItem(w, name: "DSC00007.ARW", size: real.count)], title: "Move", journalFolder: w.journals)
            XCTAssertEqual(skipping.nasRenamed.map(\.newName), ["DSC00007 (3).ARW"])
        }
    }

    func testANameTheTargetsCatalogAlreadyClaimsIsAvoidedToo() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let real = bytes(7)
            _ = try w.placeOnNASOnly(w.a, "DSC00007.ARW", real)
            _ = try w.placeOnNASOnly(w.b, "DSC00007.ARW", bytes(8), verified: false)
            // Trip B's catalog already lists " (2)" (on the drive, not yet on the NAS).
            let claimed = w.assignment(w.b, "DSC00007 (2).ARW", size: 900)
            let taken: Set<String> = [EventStorageLocations.pathKey(w.locations.impliedDrivePath(for: claimed, event: w.b, policy: .buffer) ?? "")]
            let outcome = try moveService(w).move(
                [nasOnlyItem(w, name: "DSC00007.ARW", size: real.count)], title: "Move", journalFolder: w.journals, takenPathKeys: taken
            )
            XCTAssertEqual(outcome.nasRenamed.map(\.newName), ["DSC00007 (3).ARW"])
        }
    }

    private func driveItem(_ w: NASSafetyWorld, name: String, data: Data) throws -> EventMoveItem {
        try writeFile(w.drivePath(w.a, name), data)
        let removed = w.assignment(w.a, name, size: data.count)
        var added = removed
        added.eventID = w.b.id
        added.sourceRootPath = w.locations.originalsRoot(for: w.b, deviceID: "sony-a7v", policy: .buffer).path
        return EventMoveItem(
            removed: removed, added: added,
            move: DriveMove(sourcePath: w.drivePath(w.a, name).path, destinationPath: w.drivePath(w.b, name).path, byteCount: Int64(data.count)),
            currentPath: w.drivePath(w.a, name).path
        )
    }

    /// A drive file moving onto a NAS name that a different file holds (debris
    /// of an older Buffer) used to leave its NAS copy behind and the entry
    /// pointing at the other file.
    func testADriveFileMovedOntoANASNameADifferentFileHoldsTakesAFreeName() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let data = bytes(3)
            let item = try driveItem(w, name: "DSC00003.ARW", data: data)
            _ = try w.placeOnNASOnly(w.a, "DSC00003.ARW", data)  // the moved file's own NAS copy
            let debris = try w.placeOnNASOnly(w.b, "DSC00003.ARW", bytes(4), verified: false)  // same size, other bytes
            let outcome = try moveService(w).move([item], title: "Move", journalFolder: w.journals)
            XCTAssertEqual(outcome.keptBoth.map(\.newName), ["DSC00003 (2).ARW"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: w.drivePath(w.b, "DSC00003 (2).ARW").path))
            var batch = NASRenameBatch(title: "Move", origin: .move, nasRoot: w.nas.path, ops: NASMoveFollower.renames(forEventMove: outcome, locations: w.locations).moves)
            let result = try w.follower().apply(&batch, nasRoot: w.nas)
            XCTAssertEqual(result.renamed, 1, result.summary)
            XCTAssertEqual(try Data(contentsOf: w.nas.appendingPathComponent(debris)), bytes(4), "the debris is untouched")
            XCTAssertEqual(try Data(contentsOf: w.nas.appendingPathComponent(w.mirror(w.b, "DSC00003 (2).ARW"))), data)
        }
    }

    /// A Keep Both name never takes the name a plain move of the same batch
    /// is about to use.
    func testAKeepBothNumberNeverTakesTheNameAPlainMoveInTheSameBatchUses() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let plain = try driveItem(w, name: "DSC00002 (2).ARW", data: bytes(2, 700))
            let clash = try driveItem(w, name: "DSC00002.ARW", data: bytes(3, 1_300))
            try writeFile(w.drivePath(w.b, "DSC00002.ARW"), bytes(5, 1_300))  // Trip B already has this name
            let outcome = try moveService(w).move([plain, clash], title: "Move", journalFolder: w.journals)
            XCTAssertEqual(outcome.moved.map(\.fileName), ["DSC00002 (2).ARW"])
            XCTAssertEqual(outcome.keptBoth.map(\.newName), ["DSC00002 (3).ARW"])
            XCTAssertTrue(outcome.stayed.isEmpty, "\(outcome.stayed.map(\.reason))")
        }
    }

    func testAKeepBothNumberAlsoAvoidsANameAPhotoOnlyTheNASHasIsAboutToTake() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            _ = try w.placeOnNASOnly(w.a, "DSC00002 (2).ARW", bytes(2, 700))
            let nasOnly = nasOnlyItem(w, name: "DSC00002 (2).ARW", size: 700)
            let clash = try driveItem(w, name: "DSC00002.ARW", data: bytes(3, 1_300))
            try writeFile(w.drivePath(w.b, "DSC00002.ARW"), bytes(5, 1_300))
            let outcome = try moveService(w).move([nasOnly, clash], title: "Move", journalFolder: w.journals)
            XCTAssertEqual(outcome.moved.map(\.fileName), ["DSC00002 (2).ARW"])
            XCTAssertEqual(outcome.keptBoth.map(\.newName), ["DSC00002 (3).ARW"])
        }
    }

    func testADriveFileMovedOntoANASNameHoldingItsIdenticalBytesMovesPlainly() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let data = bytes(3)
            let item = try driveItem(w, name: "DSC00003.ARW", data: data)
            _ = try w.placeOnNASOnly(w.b, "DSC00003.ARW", data, verified: false)  // an earlier sync already put it there
            let outcome = try moveService(w).move([item], title: "Move", journalFolder: w.journals)
            XCTAssertEqual(outcome.moved.count, 1)
            XCTAssertTrue(outcome.keptBoth.isEmpty)
        }
    }

    func testADriveFileMovedOntoANASNameHoldingAFileOfAnotherSizeTakesAFreeName() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let item = try driveItem(w, name: "DSC00003.ARW", data: bytes(3))
            _ = try w.placeOnNASOnly(w.b, "DSC00003.ARW", bytes(4, 700), verified: false)
            let outcome = try moveService(w).move([item], title: "Move", journalFolder: w.journals)
            XCTAssertEqual(outcome.keptBoth.map(\.newName), ["DSC00003 (2).ARW"])
        }
    }

    func testAMoveBetweenTheBufferAndPrivateKeepsItsMirrorPathAndIsNoClash() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let data = bytes(3)
            _ = try w.placeOnNASOnly(w.a, "DSC00003.ARW", data)
            let check = EventMoveNASCheck(locations: w.locations)
            let source = w.drivePath(w.a, "DSC00003.ARW").path
            let privateCopy = w.locations.originalsRoot(for: w.a, deviceID: "sony-a7v", policy: .archiveOnly).appendingPathComponent("DSC00003.ARW").path
            XCTAssertFalse(check.wouldClash(DriveMove(sourcePath: source, destinationPath: privateCopy, byteCount: 1_200), byteCount: 1_200, hasher: { _ in "x" }))
        }
    }

    func testWithoutANASCheckTheMoveIsCatalogOnlyAsBefore() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            _ = try w.placeOnNASOnly(w.a, "DSC00007.ARW", bytes(7))
            _ = try w.placeOnNASOnly(w.b, "DSC00007.ARW", bytes(8), verified: false)
            let service = EventMoveService(trash: MediaTrashService(removedFilesRoot: w.locations.removedFilesRoot, volumeRoot: { _ in nil }))
            let outcome = try service.move([nasOnlyItem(w, name: "DSC00007.ARW", size: 1_200)], title: "Move", journalFolder: w.journals)
            XCTAssertEqual(outcome.moved.count, 1, "no NAS check was given: nothing to compare against")
        }
    }
}

// MARK: - Accented names

extension SyncMoveSafetyTests {
    func testAKeyIsOneSpellingWhateverTheCompositionAndCase() {
        let composed = "2026/2026-08-01 Caf\u{00E9} Day/Originals/Cam/DSC00001.ARW"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        XCTAssertEqual(NASSyncStore.pathKey(composed), NASSyncStore.pathKey(decomposed))
        XCTAssertEqual(NASSyncStore.pathKey(composed), NASSyncStore.pathKey(composed.uppercased()))
        XCTAssertEqual(Array(NASSyncStore.pathKey(decomposed).utf8), Array(NASSyncStore.pathKey(composed).utf8), "SQLite compares bytes")
        XCTAssertEqual(NASTreeListing.key(decomposed), NASSyncStore.pathKey(decomposed))
    }

    func testAnAccentedEventsRecordsAreSeenByPresenceAndFollowAFolderRename() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root, aName: "Caf\u{00E9} Day")
            try writeFile(w.drivePath(w.a, "DSC00003.ARW"), bytes(3))
            XCTAssertEqual(try w.sync().copied.count, 1)
            // What the app asks by: the event name it holds (composed).
            let prefix = w.locations.layout(for: w.a, deviceID: nil).mirrorEventFolderPath
            let verified = try w.store.verifiedDates(nasRoot: w.nas.path, prefixes: [prefix])
            XCTAssertEqual(verified.count, 1, "presence sees the verification")
            XCTAssertEqual(try w.store.verifiedDates(nasRoot: w.nas.path, prefixes: [prefix.decomposedStringWithCanonicalMapping]).count, 1)

            var renamed = w.a
            renamed.name = "Renamed"
            let op = try XCTUnwrap(NASMoveFollower.folderRename(from: w.a, to: renamed, locations: w.locations))
            var batch = NASRenameBatch(title: "Rename", origin: .folderRename, nasRoot: w.nas.path, ops: [op])
            XCTAssertEqual(try w.follower().apply(&batch, nasRoot: w.nas).foldersRenamed, 1)
            let records = try w.store.records(nasRoot: w.nas.path).values.map(\.relativePath)
            XCTAssertEqual(records.count, 1)
            XCTAssertTrue(records.allSatisfy { $0.hasPrefix("2026/2026-08-01 Renamed") }, "every record followed the folder: \(records)")
        }
    }

    func testAnAccentedFileIsVerifiedAndRecognisedOnTheNextSync() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root, aName: "Caf\u{00E9} Day")
            try writeFile(w.drivePath(w.a, "DSC00003.ARW"), bytes(3))
            XCTAssertEqual(try w.sync().copied.count, 1)
            let again = try w.sync()
            XCTAssertEqual(again.alreadyVerified.count, 1, "the drive listing's spelling finds the record")
            XCTAssertTrue(again.copied.isEmpty)
        }
    }

    /// Records written before the key was composed are moved to the current
    /// key: backup first, a candidate copy checked on its own, exact counts.
    func testRecordsKeyedByTheOldSpellingMoveToTheCurrentKeyWithBackupAndCounts() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            try CatalogStore(url: catalog).prepareSchema()
            let store = try NASSyncStore(catalogURL: catalog)
            let nasRoot = root.appendingPathComponent("NAS").path
            func record(_ path: String, state: NASSyncRecord.State = .verified, checked: TimeInterval = 100, sha: String = "aa") -> NASSyncRecord {
                NASSyncRecord(
                    nasRoot: nasRoot, relativePath: path, byteCount: 10, sourceModifiedAt: 5, sha256: sha, state: state,
                    checkedAt: Date(timeIntervalSinceReferenceDate: checked), verifiedAt: state == .verified ? Date(timeIntervalSinceReferenceDate: checked) : nil
                )
            }
            let composed = "2026/2026-08-01 Caf\u{00E9} Day/Originals/Cam/DSC00001.ARW"
            let decomposed = composed.decomposedStringWithCanonicalMapping
            let onlyOld = "2026/2026-08-01 Caf\u{00E9} Day/Originals/Cam/DSC00002.ARW".decomposedStringWithCanonicalMapping
            let plain = "2026/2026-08-02 Trip B/Originals/Cam/DSC00003.ARW"
            try store.upsert([record(composed, sha: "new"), record(onlyOld), record(plain)])
            // Two spellings of DSC00001 (the composed one is already current), and one stored
            // only under the old spelling — exactly what an older build left behind.
            let writer = try CatalogDatabase.writer(for: catalog)
            try writer.write { database in
                try database.execute(
                    sql: "INSERT INTO \(NASSyncStore.tableName)(nas_root, path_key, relative_path, byte_count, source_modified_at, sha256, state, checked_at, verified_at) VALUES (?, ?, ?, 10, 5, 'old', 'verified', ?, ?)",
                    arguments: [NASSyncStore.standardizedRoot(nasRoot), decomposed.lowercased(), decomposed, NASSyncStore.timestamp(Date(timeIntervalSinceReferenceDate: 50)), NASSyncStore.timestamp(Date(timeIntervalSinceReferenceDate: 50))]
                )
                try database.execute(sql: "UPDATE \(NASSyncStore.tableName) SET path_key = ? WHERE relative_path = ?", arguments: [onlyOld.lowercased(), onlyOld])
            }
            XCTAssertTrue(NASSyncKeyMigration.needsMigration(catalogURL: catalog))
            XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(NASSyncStore.tableName)") }, 4, "four rows, though Swift sees three distinct keys")

            let backups = CatalogBackupService(catalogURL: catalog, configurationURL: nil, localFolder: root.appendingPathComponent("Backups"), remoteFolder: nil)
            let work = root.appendingPathComponent("Work")
            let report = try XCTUnwrap(try NASSyncKeyMigration.migrateIfNeeded(catalogURL: catalog, backups: backups, workFolder: work))
            XCTAssertEqual(report.rowsBefore, 4)
            XCTAssertEqual(report.rowsMerged, 1, "two spellings of one path became one record")
            XCTAssertEqual(report.rowsRekeyed, 1, "the record only the old spelling had")
            XCTAssertEqual(report.rowsAfter, 3)
            XCTAssertNotNil(report.backupID)
            XCTAssertNotNil(backups.newestManifest(in: backups.localFolder), "a backup was made before anything changed")
            XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: work.path))?.count ?? 0, 0, "the candidate catalog is gone")

            let after = try store.records(nasRoot: nasRoot)
            XCTAssertEqual(after.count, 3)
            XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(NASSyncStore.tableName)") }, 3)
            XCTAssertEqual(after[NASSyncStore.pathKey(composed)]?.sha256, "new", "the newer verified record won")
            XCTAssertNotNil(after[NASSyncStore.pathKey(onlyOld)])
            XCTAssertNotNil(after[NASSyncStore.pathKey(plain)])
            XCTAssertTrue(after.allSatisfy { $0.key == NASSyncStore.pathKey($0.value.relativePath) })
            let integrity = try writer.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") }
            XCTAssertEqual(integrity, ["ok"])
            XCTAssertFalse(NASSyncKeyMigration.needsMigration(catalogURL: catalog))
            XCTAssertNil(try NASSyncKeyMigration.migrateIfNeeded(catalogURL: catalog, backups: backups, workFolder: work), "a second run has nothing to do")
        }
    }

    func testACatalogWithNothingAccentedIsNotTouchedOrBackedUp() throws {
        try withTemporaryDirectory { root in
            let catalog = root.appendingPathComponent("catalog.sqlite")
            let store = try NASSyncStore(catalogURL: catalog)
            try store.upsert([NASSyncRecord(nasRoot: root.path, relativePath: "2026/x/Originals/a.ARW", byteCount: 1, state: .verified, checkedAt: Date())])
            let backups = CatalogBackupService(catalogURL: catalog, configurationURL: nil, localFolder: root.appendingPathComponent("Backups"), remoteFolder: nil)
            XCTAssertNil(try NASSyncKeyMigration.migrateIfNeeded(catalogURL: catalog, backups: backups))
            XCTAssertFalse(FileManager.default.fileExists(atPath: backups.localFolder.path), "no backup for a no-op")
        }
    }
}

// MARK: - Bytes, not records

extension SyncMoveSafetyTests {
    /// Two sync records used to prove a merge without reading either copy; a
    /// keeper damaged since kept its place and the good copy was set aside.
    func testAMergeReadsBothCopiesSoADamagedKeeperNeverCostsTheGoodCopy() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let data = bytes(6)
            try writeFile(w.drivePath(w.a, "DSC00006.ARW"), data)
            try writeFile(w.drivePath(w.b, "DSC00006.ARW"), data)
            XCTAssertEqual(try w.sync().copied.count, 2)
            let keeper = w.nas.appendingPathComponent(w.mirror(w.b, "DSC00006.ARW"))
            var damaged = data
            damaged[100] ^= 0xFF
            try damaged.write(to: keeper)  // bit rot on the kept copy, same size
            var batch = NASRenameBatch(
                title: "merged", origin: .merge, nasRoot: w.nas.path,
                ops: [NASRename(from: w.mirror(w.a, "DSC00006.ARW"), to: w.mirror(w.b, "DSC00006.ARW"), byteCount: Int64(data.count))]
            )
            let result = try w.follower().apply(&batch, nasRoot: w.nas)
            XCTAssertEqual(result.merged, 0, result.summary)
            XCTAssertEqual(result.differs.count, 1)
            XCTAssertTrue(w.files(under: w.nas).filter { $0.hasPrefix(".Camera Toolkit/_Stale Copies/") }.isEmpty, "nothing was set aside")
            XCTAssertEqual(try Data(contentsOf: w.nas.appendingPathComponent(w.mirror(w.a, "DSC00006.ARW"))), data, "the good copy stays where it is")
            XCTAssertEqual(try Data(contentsOf: keeper), damaged, "the damaged copy is untouched too")

            // And the scrub is what tells the owner about the damaged keeper.
            let scrub = try NASVerifyScrub(store: w.store, isCancelled: { false }).run(nasRoot: w.nas)
            XCTAssertEqual(scrub.hashMismatches.map(\.path), [w.mirror(w.b, "DSC00006.ARW")])
        }
    }

    func testAMergeOfIdenticalCopiesWithoutSSHReadsThemOverSMBAndSetsTheStaleOneAside() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let data = bytes(6)
            try writeFile(w.drivePath(w.a, "DSC00006.ARW"), data)
            try writeFile(w.drivePath(w.b, "DSC00006.ARW"), data)
            XCTAssertEqual(try w.sync().copied.count, 2)
            // No record for either: only bytes can say.
            try CatalogDatabase.writer(for: w.store.catalogURL).write { try $0.execute(sql: "DELETE FROM \(NASSyncStore.tableName)") }
            var reads = 0
            NASFileIO.verificationHashOverride = { _ in reads += 1; return nil }
            var batch = NASRenameBatch(
                title: "merged", origin: .merge, nasRoot: w.nas.path,
                ops: [NASRename(from: w.mirror(w.a, "DSC00006.ARW"), to: w.mirror(w.b, "DSC00006.ARW"), byteCount: Int64(data.count))]
            )
            let result = try w.follower().apply(&batch, nasRoot: w.nas)
            XCTAssertEqual(result.merged, 1, result.summary)
            XCTAssertEqual(reads, 2, "both copies were read")
            XCTAssertEqual(w.files(under: w.nas).filter { $0.hasPrefix(".Camera Toolkit/_Stale Copies/") }.count, 1)
        }
    }

    func testTwoVerifiedRecordsWithDifferentHashesRuleAMergeOutWithoutReadingAnything() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let from = try w.placeOnNASOnly(w.a, "DSC00006.ARW", bytes(6))
            let to = try w.placeOnNASOnly(w.b, "DSC00006.ARW", bytes(6))  // identical bytes …
            var newer = try XCTUnwrap(try w.record(to))
            newer.sha256 = String(repeating: "0", count: 64)  // … but a record that says otherwise
            try w.store.upsert([newer])
            var batch = NASRenameBatch(title: "merged", origin: .merge, nasRoot: w.nas.path, ops: [NASRename(from: from, to: to, byteCount: 1_200)])
            let result = try w.follower().apply(&batch, nasRoot: w.nas)
            XCTAssertEqual(result.differs.count, 1, "a record can only rule a pair out — nothing is set aside on it")
            XCTAssertEqual(result.merged, 0)
        }
    }

    // MARK: Presence

    private func presence(_ w: NASSafetyWorld, size: Int) throws -> EventAssetPresence {
        let assignment = w.assignment(w.a, "DSC00006.ARW", size: size)
        let prefix = NASMoveFollower.mirrorEventFolder(of: w.a, locations: w.locations)
        let facts = try w.store.verifiedFacts(nasRoot: w.nas.path, prefixes: [prefix])
        let summary = try XCTUnwrap(EventPresenceScanner.scan(event: w.a, assignments: [assignment], locations: w.locations, nasFacts: facts))
        return summary.assets[0]
    }

    func testAVerificationOnlyCountsForTheFileItWasAbout() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let data = bytes(6)
            try writeFile(w.drivePath(w.a, "DSC00006.ARW"), data)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_780_000_000)], ofItemAtPath: w.drivePath(w.a, "DSC00006.ARW").path)
            XCTAssertEqual(try w.sync().copied.count, 1)
            let trusted = try presence(w, size: data.count)
            XCTAssertNotNil(trusted.archiveVerifiedAt)
            XCTAssertTrue(trusted.archiveIsTrusted)

            // The drive file was replaced by another of the same size: its mtime differs.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_000_000)], ofItemAtPath: w.drivePath(w.a, "DSC00006.ARW").path)
            let replaced = try presence(w, size: data.count)
            XCTAssertEqual(replaced.archive, .present)
            XCTAssertNil(replaced.archiveVerifiedAt, "the record is about another drive file")
            XCTAssertFalse(replaced.archiveIsTrusted)

            // A record about a file of another size is never inherited.
            var record = try XCTUnwrap(try w.record(w.mirror(w.a, "DSC00006.ARW")))
            record.byteCount += 1
            try w.store.upsert([record])
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_780_000_000)], ofItemAtPath: w.drivePath(w.a, "DSC00006.ARW").path)
            XCTAssertNil(try presence(w, size: data.count).archiveVerifiedAt)
        }
    }

    func testANASOnlyFileKeepsItsVerificationWhenNoDriveCopyIsThere() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let data = bytes(6)
            _ = try w.placeOnNASOnly(w.a, "DSC00006.ARW", data)
            XCTAssertNotNil(try presence(w, size: data.count).archiveVerifiedAt)
        }
    }

    // MARK: Scrub

    func testTheScrubFindsACopyThatChangedAndNeverTouchesIt() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let good = bytes(1), rot = bytes(2)
            let goodPath = try w.placeOnNASOnly(w.a, "DSC00001.ARW", good)
            let rotPath = try w.placeOnNASOnly(w.a, "DSC00002.ARW", rot)
            var changed = rot
            changed[7] ^= 0x55
            try changed.write(to: w.nas.appendingPathComponent(rotPath))
            let modified = (try FileManager.default.attributesOfItem(atPath: w.nas.appendingPathComponent(goodPath).path))[.modificationDate] as? Date

            let report = try NASVerifyScrub(store: w.store, isCancelled: { false }).run(nasRoot: w.nas)
            XCTAssertEqual(report.checked, 2)
            XCTAssertEqual(report.verified, 1)
            XCTAssertEqual(report.hashMismatches.map(\.path), [rotPath])
            XCTAssertEqual(report.recordsDowngraded, 1)
            XCTAssertFalse(report.succeeded)
            XCTAssertEqual(report.method, "SMB re-read")
            XCTAssertTrue(report.summary.contains("Nothing was deleted"))
            XCTAssertEqual(try Data(contentsOf: w.nas.appendingPathComponent(rotPath)), changed, "the changed copy is left as it is")
            XCTAssertEqual(try Data(contentsOf: w.nas.appendingPathComponent(goodPath)), good)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: w.nas.appendingPathComponent(goodPath).path))[.modificationDate] as? Date, modified)
            // It no longer counts as verified anywhere.
            XCTAssertEqual(try w.record(rotPath)?.state, .conflict)
            XCTAssertNil(try w.record(rotPath)?.verifiedAt)
            XCTAssertEqual(try w.record(goodPath)?.state, .verified)
            XCTAssertNil(try w.store.verifiedDates(nasRoot: w.nas.path, prefixes: [NASMoveFollower.mirrorEventFolder(of: w.a, locations: w.locations)])[NASSyncStore.pathKey(rotPath)])
            // A second scrub has nothing verified left to doubt for that file.
            let again = try NASVerifyScrub(store: w.store, isCancelled: { false }).run(nasRoot: w.nas)
            XCTAssertEqual(again.checked, 1)
            XCTAssertTrue(again.succeeded)
        }
    }

    func testTheScrubHashesOnTheNASWhenSSHIsSetUp() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            for n in 1...3 { _ = try w.placeOnNASOnly(w.a, "DSC0000\(n).ARW", bytes(n)) }
            let rotPath = w.mirror(w.a, "DSC00003.ARW")
            var changed = bytes(3)
            changed[3] ^= 1
            try changed.write(to: w.nas.appendingPathComponent(rotPath))
            let commands = SyncLocked<[String]>([])
            var reads = 0
            NASFileIO.verificationHashOverride = { _ in reads += 1; return nil }
            let report = try NASVerifyScrub(store: w.store, remoteVerifier: try w.localVerifier(commands: commands), isCancelled: { false }).run(nasRoot: w.nas)
            XCTAssertEqual(commands.value.count, 1, "one NAS-side command for the batch")
            XCTAssertEqual(reads, 0, "nothing was re-read over SMB")
            XCTAssertEqual(report.verified, 2)
            XCTAssertEqual(report.hashMismatches.map(\.path), [rotPath])
            XCTAssertEqual(report.method, "NAS SHA-256 (local sh)")
        }
    }

    func testTheScrubReportsMissingAndResizedCopiesAndCanBeLimitedToAnEvent() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let gone = try w.placeOnNASOnly(w.a, "DSC00001.ARW", bytes(1))
            let resized = try w.placeOnNASOnly(w.a, "DSC00002.ARW", bytes(2))
            _ = try w.placeOnNASOnly(w.b, "DSC00003.ARW", bytes(3))
            try FileManager.default.removeItem(at: w.nas.appendingPathComponent(gone))
            try bytes(2, 1_300).write(to: w.nas.appendingPathComponent(resized))
            let scoped = try NASVerifyScrub(store: w.store, isCancelled: { false })
                .run(nasRoot: w.nas, prefixes: [NASMoveFollower.mirrorEventFolder(of: w.a, locations: w.locations)])
            XCTAssertEqual(scoped.checked, 2, "only Trip A's records")
            XCTAssertEqual(scoped.missing.map(\.path), [gone])
            XCTAssertEqual(scoped.sizeChanged.map(\.path), [resized])
            XCTAssertEqual(try w.record(gone)?.state, .verified, "a missing file's record is left alone")
            XCTAssertEqual(try w.record(resized)?.state, .conflict)
        }
    }

    func testTheScrubStopsWhenTheNASIsNotThere() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            XCTAssertThrowsError(try NASVerifyScrub(store: w.store, isCancelled: { false }).run(nasRoot: root.appendingPathComponent("NotMounted")))
        }
    }
}

// MARK: - Renaming an event twice before the NAS follows

extension SyncMoveSafetyTests {
    func testTwoEventRenamesQueuedBeforeTheNASRanBothApplyInOrder() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let data = bytes(5)
            let original = try w.placeOnNASOnly(w.a, "DSC00005.ARW", data)
            var second = w.a
            second.name = "Trip A2"
            var third = second
            third.name = "Trip A3"
            let first = try XCTUnwrap(NASMoveFollower.folderRenameBatch(from: w.a, to: second, locations: w.locations, title: "Rename"))
            // The NAS folder is still at the first name: the second rename is
            // queued anyway.
            let next = try XCTUnwrap(NASMoveFollower.folderRenameBatch(from: second, to: third, locations: w.locations, title: "Rename again"))
            try w.queue.save(first)
            try w.queue.save(next)
            XCTAssertEqual(w.queue.pendingRenameCount(), 2)
            let result = try w.follower().applyPending(nasRoot: w.nas)
            XCTAssertEqual(result.foldersRenamed, 2, result.summary)
            XCTAssertFalse(w.exists(original))
            var events = w.configuration.savedEvents
            events[0] = third
            var configuration = w.configuration
            configuration.savedEvents = events
            let locations = EventStorageLocations(configuration: configuration)
            XCTAssertTrue(FileManager.default.fileExists(atPath: w.nas.appendingPathComponent(try locations.layout(for: third, deviceID: "sony-a7v").mirrorRelativePath(for: "DSC00005.ARW")).path))
            let records = try w.store.records(nasRoot: w.nas.path).values.map(\.relativePath)
            XCTAssertTrue(records.allSatisfy { $0.contains("Trip A3") }, "\(records)")
        }
    }

    func testARenameForAFolderTheNASNeverHadIsRecordedAsAbsent() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            var renamed = w.a
            renamed.name = "Trip A2"
            let batch = try XCTUnwrap(NASMoveFollower.folderRenameBatch(from: w.a, to: renamed, locations: w.locations, title: "Rename"))
            try w.queue.save(batch)
            let result = try w.follower().applyPending(nasRoot: w.nas)
            XCTAssertEqual(result.absent, 1)
            XCTAssertTrue(result.succeeded)
            XCTAssertEqual(w.queue.pendingRenameCount(), 0)
        }
    }

    func testAnEventWhoseNASFolderKeepsItsPathOwesNoRename() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            XCTAssertNil(NASMoveFollower.folderRenameBatch(from: w.a, to: w.a, locations: w.locations, title: "Rename"))
        }
    }
}

// MARK: - An old Buffer with folders nothing owns

extension SyncMoveSafetyTests {
    func testEventFoldersOnTheBufferThatNoEventOwnsAreReportedAndNeverSynced() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            try writeFile(w.drivePath(w.a, "DSC00001.ARW"), bytes(1))
            // An old Buffer: the same trip under the name it had before it was renamed.
            let oldFolder = w.locations.bufferRoot.appendingPathComponent("2026/2026-08-01 Old Name/Originals/Cam/DSC00009.ARW")
            try writeFile(oldFolder, bytes(9))
            let plan = w.plan()
            XCTAssertEqual(plan.unownedFolders.map { ($0 as NSString).lastPathComponent }, ["2026-08-01 Old Name"])
            XCTAssertFalse(plan.items.contains { $0.relativePath.contains("Old Name") }, "nothing under it is synced automatically")
            XCTAssertEqual(try w.sync().copied.count, 1)
            XCTAssertFalse(w.files(under: w.nas).contains { $0.contains("Old Name") })
            XCTAssertTrue(FileManager.default.fileExists(atPath: oldFolder.path), "and nothing on the drive is touched")
        }
    }

    func testAnOwnedFolderIsNotReportedWhateverItsCaseOrComposition() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root, aName: "Caf\u{00E9} Day")
            try writeFile(w.drivePath(w.a, "DSC00001.ARW"), bytes(1))
            XCTAssertTrue(w.plan().unownedFolders.isEmpty)
            XCTAssertEqual(NASSyncPlanner.unownedEventFolders(events: w.configuration.savedEvents, locations: w.locations), [])
        }
    }

    func testWithNoBufferNothingIsReported() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            XCTAssertTrue(w.plan().unownedFolders.isEmpty)
        }
    }
}

// MARK: - Leftover temporaries

extension SyncMoveSafetyTests {
    /// A temporary a dropped sync left was only cleared when that name was
    /// copied into that folder again; after a move it stayed, and kept the
    /// folder alive.
    func testALeftoverTemporaryIsClearedAfterTheFileMovedOnAndTheEmptiedFolderGoes() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            let data = bytes(5)
            try writeFile(w.drivePath(w.a, "DSC00005.ARW"), data)
            XCTAssertEqual(try w.sync().copied.count, 1)
            let folderA = w.nas.appendingPathComponent((w.mirror(w.a, "DSC00005.ARW") as NSString).deletingLastPathComponent)
            let temporary = folderA.appendingPathComponent(".DSC00005.ARW.ctsync-1A2B3C4D")
            try writeFile(temporary, data.prefix(300))  // a partial from a dropped sync
            let report = try DriveMoveService().apply(
                [DriveMove(sourcePath: w.drivePath(w.a, "DSC00005.ARW").path, destinationPath: w.drivePath(w.b, "DSC00005.ARW").path, byteCount: Int64(data.count))],
                title: "Move", journalFolder: w.journals, pruneBoundaries: [w.locations.bufferRoot]
            )
            var batch = NASRenameBatch(title: "Move", origin: .move, nasRoot: w.nas.path, ops: NASMoveFollower.renames(forMoves: report.moved, locations: w.locations))
            _ = try w.follower().apply(&batch, nasRoot: w.nas)
            XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path), "the rename cannot know about it")
            let synced = try w.sync()
            XCTAssertEqual(synced.clearedTemporaries, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folderA.path), "the folder it kept alive is pruned")
            XCTAssertEqual(try Data(contentsOf: w.nas.appendingPathComponent(w.mirror(w.b, "DSC00005.ARW"))), data)
        }
    }

    func testOnlyExactlyThatNamePatternIsClearedAndNothingElseIsTouched() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            try writeFile(w.drivePath(w.a, "DSC00001.ARW"), bytes(1))
            XCTAssertEqual(try w.sync().copied.count, 1)
            let folder = w.nas.appendingPathComponent((w.mirror(w.a, "DSC00001.ARW") as NSString).deletingLastPathComponent)
            let stale = folder.appendingPathComponent(".other.ARW.ctsync-0A0B0C0D")
            let nested = w.nas.appendingPathComponent("2026/2026-08-01 Trip A/Edited/Picks/.PICK.JPG.ctsync-ABCDEF12")
            try writeFile(stale, Data(count: 10))
            try writeFile(nested, Data(count: 10))
            let keep: [URL] = [
                folder.appendingPathComponent("DSC00001.ARW.ctsync-1A2B3C4D"),   // not hidden: a real name
                folder.appendingPathComponent(".notes.ctsync-XYZ"),                // too short and not hex
                folder.appendingPathComponent(".ctsync-1A2B3C4D"),                 // no name
                folder.appendingPathComponent(".backup.ARW.ctsync-1A2B3C4D5"),    // nine characters
                folder.appendingPathComponent("._DSC00001.ARW"),                   // a Finder file
            ]
            for url in keep { try writeFile(url, Data(count: 10)) }
            let synced = try w.sync()
            XCTAssertEqual(synced.clearedTemporaries, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
            for url in keep { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: w.nas.appendingPathComponent(w.mirror(w.a, "DSC00001.ARW")).path))
        }
    }

    func testATemporaryNewerThanTheRunIsAnotherProcessesAndIsLeftAlone() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            try writeFile(w.drivePath(w.a, "DSC00001.ARW"), bytes(1))
            XCTAssertEqual(try w.sync().copied.count, 1)
            let folder = w.nas.appendingPathComponent((w.mirror(w.a, "DSC00001.ARW") as NSString).deletingLastPathComponent)
            let live = folder.appendingPathComponent(".other.ARW.ctsync-0A0B0C0D")
            try writeFile(live, Data(count: 10))
            let plan = w.plan()
            // A run that started an hour ago: the file is newer than the run.
            let started = Date().addingTimeInterval(-3_600)
            let service = NASSyncService(store: w.store, options: NASSyncOptions(retryDelay: 0), now: { started }, isCancelled: { false })
            let report = try service.sync(plan, nasRoot: w.nas)
            XCTAssertEqual(report.clearedTemporaries, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        }
    }
}

// MARK: - Reconcile needs the drive

extension SyncMoveSafetyTests {
    func testTheDriveCountsAsMountedOnlyWhenTheBufferOrPrivateFolderIsThere() throws {
        try withTemporaryDirectory { root in
            let w = try NASSafetyWorld.make(root)
            XCTAssertFalse(NASCatchUp.driveIsMounted(w.locations))
            try FileManager.default.createDirectory(at: w.locations.bufferRoot, withIntermediateDirectories: true)
            XCTAssertTrue(NASCatchUp.driveIsMounted(w.locations))
        }
    }
}
