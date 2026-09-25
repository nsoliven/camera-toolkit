@testable import CameraToolkitCore
import Foundation
import XCTest

final class ApplyCollisionCheckTests: XCTestCase {
    private func assignment(_ root: URL, _ relative: String, size: Int64) -> PhotoEventAssignment {
        PhotoEventAssignment(
            sourceRootPath: root.path,
            relativePath: relative,
            fileSize: size,
            modifiedAt: Date(timeIntervalSince1970: 1_000),
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            deviceID: "sony-a7v"
        )
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Classification

    func testFreeDestinationIsNotACollision() throws {
        try withTemporaryDirectory { root in
            let source = try writeFile(root.appendingPathComponent("Unsorted/DSC00001.ARW"), "a")
            XCTAssertNil(ApplyCollisionCheck.classify(
                sourcePath: source.path,
                destinationPath: root.appendingPathComponent("Event/DSC00001.ARW").path
            ))
        }
    }

    func testIdenticalDestinationIsADuplicateAndADifferentOneIsAConflict() throws {
        try withTemporaryDirectory { root in
            let source = try writeFile(root.appendingPathComponent("Unsorted/DSC00001.ARW"), "same bytes")
            let identical = try writeFile(root.appendingPathComponent("EventA/DSC00001.ARW"), "same bytes")
            let differentSize = try writeFile(root.appendingPathComponent("EventB/DSC00001.ARW"), "a longer, different file")
            let sameSizeDifferent = try writeFile(root.appendingPathComponent("EventC/DSC00001.ARW"), "SAME BYTES")

            let dup = try XCTUnwrap(ApplyCollisionCheck.classify(sourcePath: source.path, destinationPath: identical.path))
            XCTAssertEqual(dup.kind, .identicalCopy)
            XCTAssertEqual(dup.existingByteCount, 10)

            XCTAssertEqual(ApplyCollisionCheck.classify(sourcePath: source.path, destinationPath: differentSize.path)?.kind, .nameConflict)
            XCTAssertEqual(ApplyCollisionCheck.classify(sourcePath: source.path, destinationPath: sameSizeDifferent.path)?.kind, .nameConflict)
            // Classification never touches either file.
            XCTAssertEqual(try text(source), "same bytes")
            XCTAssertEqual(try text(sameSizeDifferent), "SAME BYTES")
        }
    }

    func testDifferentSizesAreNeverHashed() throws {
        try withTemporaryDirectory { root in
            let source = try writeFile(root.appendingPathComponent("Unsorted/DSC00001.ARW"), "a")
            let other = try writeFile(root.appendingPathComponent("Event/DSC00001.ARW"), "bb")
            let calls = Counter()
            let found = ApplyCollisionCheck.classify(sourcePath: source.path, destinationPath: other.path) { url in
                calls.increment()
                return url.path
            }
            XCTAssertEqual(found?.kind, .nameConflict)
            XCTAssertEqual(calls.value, 0)
        }
    }

    func testAHashFailureIsAConflictNotADuplicate() throws {
        try withTemporaryDirectory { root in
            let source = try writeFile(root.appendingPathComponent("Unsorted/DSC00001.ARW"), "x")
            let other = try writeFile(root.appendingPathComponent("Event/DSC00001.ARW"), "x")
            let found = ApplyCollisionCheck.classify(sourcePath: source.path, destinationPath: other.path) { _ in
                throw ToolkitError.commandFailed("short read")
            }
            XCTAssertEqual(found?.kind, .nameConflict)
        }
    }

    func testPartitionHoldsSidecarsBackWithTheirConflictingPhoto() throws {
        try withTemporaryDirectory { root in
            let unsorted = root.appendingPathComponent("Unsorted", isDirectory: true)
            let event = root.appendingPathComponent("Event", isDirectory: true)
            let raw = try writeFile(unsorted.appendingPathComponent("DSC00001.ARW"), "new photo")
            let xmp = try writeFile(unsorted.appendingPathComponent("DSC00001.XMP"), "<xmp/>")
            let dup = try writeFile(unsorted.appendingPathComponent("DSC00002.ARW"), "twin")
            let clean = try writeFile(unsorted.appendingPathComponent("DSC00003.ARW"), "free")
            try writeFile(event.appendingPathComponent("DSC00001.ARW"), "older photo, other camera")
            try writeFile(event.appendingPathComponent("DSC00002.ARW"), "twin")

            let candidates = [raw, xmp, dup, clean].map { url in
                ApplyMoveCandidate(
                    move: DriveMove(sourcePath: url.path, destinationPath: event.appendingPathComponent(url.lastPathComponent).path, byteCount: 1),
                    assignment: assignment(unsorted, url.lastPathComponent, size: 1)
                )
            }
            let partition = ApplyCollisionCheck.partition(candidates)
            XCTAssertEqual(partition.clear.map { ($0.move.sourcePath as NSString).lastPathComponent }, ["DSC00003.ARW"])
            XCTAssertEqual(partition.duplicates.map(\.fileName), ["DSC00002.ARW"])
            XCTAssertEqual(partition.conflicts.map(\.fileName).sorted(), ["DSC00001.ARW", "DSC00001.XMP"])
            XCTAssertEqual(partition.conflicts.first { $0.fileName == "DSC00001.XMP" }?.kind, .travelsWithConflict)
        }
    }

    // MARK: - Keep Both

    func testSuffixedNamesKeepTheWholeExtension() {
        XCTAssertEqual(KeepBothNaming.suffixed("DSC00001.ARW", 2), "DSC00001 (2).ARW")
        XCTAssertEqual(KeepBothNaming.suffixed("DSC00001.ARW.xmp", 3), "DSC00001 (3).ARW.xmp")
        XCTAssertEqual(KeepBothNaming.suffixed("README", 2), "README (2)")
        XCTAssertEqual(KeepBothNaming.suffixed(".hidden", 2), ".hidden (2)")
    }

    func testRenamedMovesSkipATakenSuffixForTheWholeGroup() throws {
        try withTemporaryDirectory { root in
            let event = root.appendingPathComponent("Event", isDirectory: true)
            try writeFile(event.appendingPathComponent("DSC00001 (2).XMP"), "someone else's sidecar")
            let moves = ["DSC00001.ARW", "DSC00001.XMP"].map {
                DriveMove(sourcePath: root.appendingPathComponent("Unsorted/\($0)").path, destinationPath: event.appendingPathComponent($0).path, byteCount: 1)
            }
            let renamed = try XCTUnwrap(KeepBothNaming.renamedMoves(for: moves))
            // "(2)" is free for the ARW but not the XMP, so both take "(3)".
            XCTAssertEqual(renamed.map { ($0.destinationPath as NSString).lastPathComponent }, ["DSC00001 (3).ARW", "DSC00001 (3).XMP"])
        }
    }

    func testRenamedMovesNeverClaimTheSameNameTwiceInOneBatch() {
        let moves = ["A", "B"].map {
            DriveMove(sourcePath: "/tmp/\($0)/DSC00001.ARW", destinationPath: "/Event/DSC00001.ARW", byteCount: 1)
        }
        let renamed = KeepBothNaming.renamedMoves(for: moves) { _ in false }
        XCTAssertEqual(renamed?.map(\.destinationPath), ["/Event/DSC00001 (2).ARW", "/Event/DSC00001 (3).ARW"])
    }

    func testKeepBothNeverOverwritesCarriesSidecarsAndUndoesToTheOriginalNames() throws {
        try withTemporaryDirectory { root in
            let unsorted = root.appendingPathComponent("Unsorted", isDirectory: true)
            let event = root.appendingPathComponent("Buffer/2026/2026-08-23 Trip/Sony A7V/Card Copy", isDirectory: true)
            let journals = root.appendingPathComponent("Journals", isDirectory: true)
            let raw = try writeFile(unsorted.appendingPathComponent("DSC00001.ARW"), "new photo")
            let xmp = try writeFile(unsorted.appendingPathComponent("DSC00001.XMP"), "<new/>")
            let appleDouble = try writeFile(unsorted.appendingPathComponent("._DSC00001.ARW"), "finder info")
            let existing = try writeFile(event.appendingPathComponent("DSC00001.ARW"), "older photo, other camera")
            let taken = try writeFile(event.appendingPathComponent("DSC00001 (2).ARW"), "a previous keep-both")

            let candidates = [raw, xmp].map { url in
                ApplyMoveCandidate(
                    move: DriveMove(sourcePath: url.path, destinationPath: event.appendingPathComponent(url.lastPathComponent).path, byteCount: 1),
                    assignment: assignment(unsorted, url.lastPathComponent, size: 1)
                )
            }
            let conflicts = ApplyCollisionCheck.partition(candidates).conflicts
            XCTAssertEqual(conflicts.count, 2)

            let outcome = try DriveMoveService().keepBoth(conflicts, title: "Keep both", journalFolder: journals, pruneBoundaries: [unsorted])
            XCTAssertEqual(outcome.report.moved.count, 2)
            XCTAssertTrue(outcome.report.skipped.isEmpty)

            // The files that already had the names are untouched.
            XCTAssertEqual(try text(existing), "older photo, other camera")
            XCTAssertEqual(try text(taken), "a previous keep-both")
            // Both members took the same free number, "(3)".
            XCTAssertEqual(try text(event.appendingPathComponent("DSC00001 (3).ARW")), "new photo")
            XCTAssertEqual(try text(event.appendingPathComponent("DSC00001 (3).XMP")), "<new/>")
            XCTAssertEqual(try text(event.appendingPathComponent("._DSC00001 (3).ARW")), "finder info")
            XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: appleDouble.path))

            // Assignments follow the new names.
            XCTAssertEqual(outcome.removedAssignments.map(\.relativePath).sorted(), ["DSC00001.ARW", "DSC00001.XMP"])
            XCTAssertEqual(outcome.addedAssignments.map(\.relativePath).sorted(), ["DSC00001 (3).ARW", "DSC00001 (3).XMP"])

            // The journal records it, so Undo puts the files back under
            // their original names and the new names disappear.
            let latest = try XCTUnwrap(DriveMoveService.latestUndoableJournal(in: journals))
            XCTAssertEqual(latest.journal.addedAssignments.count, 2)
            let undone = try DriveMoveService().undo(journalURL: latest.url)
            XCTAssertEqual(undone.report.moved.count, 2)
            XCTAssertEqual(try text(raw), "new photo")
            XCTAssertEqual(try text(xmp), "<new/>")
            XCTAssertEqual(try text(appleDouble), "finder info")
            XCTAssertFalse(FileManager.default.fileExists(atPath: event.appendingPathComponent("DSC00001 (3).ARW").path))
            XCTAssertEqual(try text(existing), "older photo, other camera")
            XCTAssertEqual(try text(taken), "a previous keep-both")
        }
    }

    func testRenamedMovesSkipNamesReservedByPlainMovesInTheSameBatch() {
        let conflict = DriveMove(sourcePath: "/tmp/A/DSC00001.ARW", destinationPath: "/Event/DSC00001.ARW", byteCount: 1)
        // A plain move in the same Apply already lands on "(2)".
        let plain = DriveMove(sourcePath: "/tmp/B/DSC00001 (2).ARW", destinationPath: "/Event/DSC00001 (2).ARW", byteCount: 1)
        let renamed = KeepBothNaming.renamedMoves(for: [conflict], reserved: [plain]) { _ in false }
        XCTAssertEqual(renamed?.map(\.destinationPath), ["/Event/DSC00001 (3).ARW"])
    }

    /// "Move 2 Files (Keep Both for 1)": the plain move and the Keep Both
    /// rename share one journal, so one Undo reverses both.
    func testKeepBothWithPlainMovesIsOneJournalAndOneUndo() throws {
        try withTemporaryDirectory { root in
            let unsorted = root.appendingPathComponent("Unsorted", isDirectory: true)
            let event = root.appendingPathComponent("Event", isDirectory: true)
            let journals = root.appendingPathComponent("Journals", isDirectory: true)
            let raw = try writeFile(unsorted.appendingPathComponent("DSC00001.ARW"), "new photo")
            let clean = try writeFile(unsorted.appendingPathComponent("DSC00002.ARW"), "free name")
            let existing = try writeFile(event.appendingPathComponent("DSC00001.ARW"), "older photo")
            let conflicts = ApplyCollisionCheck.partition([ApplyMoveCandidate(
                move: DriveMove(sourcePath: raw.path, destinationPath: event.appendingPathComponent("DSC00001.ARW").path, byteCount: 1),
                assignment: assignment(unsorted, "DSC00001.ARW", size: 1)
            )]).conflicts
            let plain = DriveMove(sourcePath: clean.path, destinationPath: event.appendingPathComponent("DSC00002.ARW").path, byteCount: 1)

            let outcome = try DriveMoveService().keepBoth(conflicts, plainMoves: [plain], title: "Apply", journalFolder: journals)
            XCTAssertEqual(outcome.report.moved.count, 2)
            XCTAssertEqual(try text(event.appendingPathComponent("DSC00001 (2).ARW")), "new photo")
            XCTAssertEqual(try text(event.appendingPathComponent("DSC00002.ARW")), "free name")
            XCTAssertEqual(try text(existing), "older photo")
            XCTAssertEqual(outcome.addedAssignments.map(\.relativePath), ["DSC00001 (2).ARW"])
            let journalFiles = try FileManager.default.contentsOfDirectory(atPath: journals.path).filter { $0.hasSuffix(".json") }
            XCTAssertEqual(journalFiles.count, 1)

            let latest = try XCTUnwrap(DriveMoveService.latestUndoableJournal(in: journals))
            _ = try DriveMoveService().undo(journalURL: latest.url)
            XCTAssertEqual(try text(raw), "new photo")
            XCTAssertEqual(try text(clean), "free name")
            XCTAssertEqual(try text(existing), "older photo")
        }
    }

    func testFactsReadSizeAndDatesWithoutWritingAndKeepBothNamePreview() throws {
        try withTemporaryDirectory { root in
            let source = try writeFile(root.appendingPathComponent("Unsorted/DSC00001.ARW"), "12345")
            try writeFile(root.appendingPathComponent("Event/DSC00001.ARW"), "older")
            try writeFile(root.appendingPathComponent("Event/DSC00001 (2).ARW"), "taken")
            let facts = ApplyCollisionCheck.facts(atPath: source.path)
            XCTAssertEqual(facts.byteCount, 5)
            XCTAssertNil(facts.captureDate, "no EXIF in a synthetic file")
            XCTAssertNotNil(facts.modifiedAt)
            XCTAssertEqual(ApplyCollisionCheck.facts(atPath: root.appendingPathComponent("missing").path).byteCount, nil)

            let conflict = ApplyCollision(
                kind: .nameConflict,
                move: DriveMove(sourcePath: source.path, destinationPath: root.appendingPathComponent("Event/DSC00001.ARW").path, byteCount: 5),
                assignment: nil,
                existingByteCount: 5
            )
            XCTAssertEqual(ApplyCollisionCheck.keepBothName(for: conflict), "DSC00001 (3).ARW")
        }
    }

    /// Regression: journals wrote whole-second dates while an assignment's
    /// identity rounds its modification time, so a file modified at .5 s or
    /// later came back from the journal as a different assignment and Undo
    /// could not remove the renamed one.
    func testJournalKeepsFractionalSecondsSoUndoFindsTheSameAssignment() throws {
        try withTemporaryDirectory { root in
            let source = try writeFile(root.appendingPathComponent("Unsorted/DSC00001.ARW"), "x")
            let journals = root.appendingPathComponent("Journals", isDirectory: true)
            var old = assignment(root.appendingPathComponent("Unsorted"), "DSC00001.ARW", size: 1)
            old.modifiedAt = Date(timeIntervalSince1970: 1_787_205_604.75)
            var new = old
            new.relativePath = "DSC00001 (2).ARW"
            _ = try DriveMoveService().apply(
                [DriveMove(sourcePath: source.path, destinationPath: root.appendingPathComponent("Event/DSC00001 (2).ARW").path, byteCount: 1)],
                title: "Keep both",
                journalFolder: journals,
                removedAssignments: [old],
                addedAssignments: [new]
            )
            let journal = try XCTUnwrap(DriveMoveService.latestUndoableJournal(in: journals)).journal
            XCTAssertEqual(journal.addedAssignments.map(CatalogStore.eventAssetID), [CatalogStore.eventAssetID(new)])
            XCTAssertEqual(journal.removedAssignments.map(CatalogStore.eventAssetID), [CatalogStore.eventAssetID(old)])
        }
    }

    func testOlderWholeSecondJournalsStillRead() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("old.json")
            try writeFile(url, """
            {"completedIndices":[],"createdAt":"2026-08-20T06:00:04Z","id":"00000000-0000-0000-0000-0000000000AA","moves":[],"removedAssignments":[],"addedAssignments":[],"title":"Apply"}
            """)
            let journal = try DriveMoveService.read(url)
            XCTAssertEqual(journal.createdAt.timeIntervalSince1970, 1_787_205_604, accuracy: 0.001)
        }
    }

    func testANameTakenAfterPlanningIsLeftAloneNotOverwritten() throws {
        try withTemporaryDirectory { root in
            let source = try writeFile(root.appendingPathComponent("Unsorted/DSC00001.ARW"), "new photo")
            let raced = root.appendingPathComponent("Event/DSC00001 (2).ARW")
            // The suffix was chosen while free, then something wrote it.
            let move = try XCTUnwrap(KeepBothNaming.renamedMoves(
                for: [DriveMove(sourcePath: source.path, destinationPath: root.appendingPathComponent("Event/DSC00001.ARW").path, byteCount: 1)]
            ) { _ in false }?.first)
            XCTAssertEqual(move.destinationPath, raced.path)
            try writeFile(raced, "arrived meanwhile")

            let report = try DriveMoveService().apply([move], title: "Keep both", journalFolder: nil)
            XCTAssertTrue(report.moved.isEmpty)
            XCTAssertEqual(report.skipped.count, 1)
            XCTAssertEqual(try text(raced), "arrived meanwhile")
            XCTAssertEqual(try text(source), "new photo")
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
