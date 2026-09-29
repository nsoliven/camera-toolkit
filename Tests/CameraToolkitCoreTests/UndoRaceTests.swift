@testable import CameraToolkitCore
import Darwin
import Foundation
import XCTest

/// Undo and the NAS renames it reverses share one queue folder. Nothing may
/// rename while an Undo changes the queue, and a batch read before an Undo
/// must never be saved back over what the Undo wrote. And an Undo that stops
/// half way must leave its journal saying so.
final class UndoRaceTests: XCTestCase {
    override func tearDown() {
        NASFileIO.renameExclusivePrimitive = nil
        super.tearDown()
    }

    private struct World {
        var root: URL
        var nas: URL
        var queue: NASRenameQueue
        var store: NASSyncStore

        func follower() -> NASMoveFollower { NASMoveFollower(store: store, queue: queue, isCancelled: { false }) }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: nas.appendingPathComponent(relative).path) }
    }

    private func world(_ root: URL) throws -> World {
        let nas = root.appendingPathComponent("NAS", isDirectory: true)
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        return World(
            root: root, nas: nas,
            queue: NASRenameQueue(journalFolder: root.appendingPathComponent("Move Journals")),
            store: try NASSyncStore(catalogURL: root.appendingPathComponent("catalog.sqlite"))
        )
    }

    private let from = "2026/Trip A/Originals/Sony A7V/DSC00002.ARW"
    private let to = "2026/Trip B/Originals/Sony A7V/DSC00002.ARW"

    /// The job read the batch; an Undo then cancelled its rename on disk; the job
    /// carries on. It used to rename the only copy anyway and save its stale
    /// copy over the cancellation. Now it re-reads the batch from disk and finds
    /// it closed.
    func testAJobHoldingAStaleBatchDoesNotUndoTheUndo() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            try writeFile(w.nas.appendingPathComponent(from), "only-copy-pad-pad")
            let moveID = UUID()
            try w.queue.save(NASRenameBatch(
                title: "Move to Trip B", origin: .move, nasRoot: w.nas.path, moveJournalID: moveID,
                ops: [NASRename(from: from, to: to, byteCount: 17)]
            ))
            var inFlight = try XCTUnwrap(w.queue.pending(nasRoot: w.nas.path).first)  // what a job loaded
            let undone = try w.follower().undo(moveJournalID: moveID, nasRoot: w.nas)   // ⌘Z: back to Trip A
            XCTAssertEqual(undone.cancelled, 1)

            let result = try w.follower().apply(&inFlight, nasRoot: w.nas)               // the job carries on
            XCTAssertEqual(result.renamed, 0, "the cancelled rename is not performed")
            XCTAssertTrue(w.exists(from), "the only copy is still under Trip A")
            XCTAssertFalse(w.exists(to))
            let saved = try XCTUnwrap(w.queue.batches(forMoveJournal: moveID).first)
            XCTAssertNotNil(saved.undoneAt, "and the cancellation was not overwritten")
            XCTAssertEqual(saved.ops[0].state, .cancelled)
        }
    }

    /// The same, two ops of one batch: one was already renamed and one is still
    /// pending when the batch is read again — only the pending one runs.
    func testAJobReadsWhatIsStillPendingFromDiskBeforeItRenames() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            let names = ["DSC1.ARW", "DSC2.ARW"]
            for name in names { try writeFile(w.nas.appendingPathComponent("2026/Trip A/\(name)"), "photo-\(name)") }
            var batch = NASRenameBatch(
                title: "Move", origin: .move, nasRoot: w.nas.path, moveJournalID: UUID(),
                ops: names.map { NASRename(from: "2026/Trip A/\($0)", to: "2026/Trip B/\($0)", byteCount: Int64("photo-\($0)".utf8.count)) }
            )
            try w.queue.save(batch)
            // Another writer settled the first op (renamed it) while this copy was in hand.
            var settled = batch
            settled.ops[0].state = .renamed
            try FileManager.default.createDirectory(at: w.nas.appendingPathComponent("2026/Trip B"), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: w.nas.appendingPathComponent("2026/Trip A/DSC1.ARW"), to: w.nas.appendingPathComponent("2026/Trip B/DSC1.ARW"))
            try w.queue.save(settled)

            let result = try w.follower().apply(&batch, nasRoot: w.nas)
            XCTAssertEqual(result.renamed, 1, "only the op still pending on disk ran")
            XCTAssertTrue(w.exists("2026/Trip B/DSC1.ARW") && w.exists("2026/Trip B/DSC2.ARW"))
            XCTAssertEqual(batch.ops.map(\.state), [.renamed, .renamed])
        }
    }

    /// A renaming job and an Undo on two threads: the Undo waits for the lock,
    /// then reverses what the job renamed — the copy ends where the catalog
    /// (back at Trip A) says it is, and the batch is closed.
    func testAnUndoWaitsForARenamingJobAndThenReversesItsRename() throws {
        try withTemporaryDirectory { root in
            let w = try world(root)
            try writeFile(w.nas.appendingPathComponent(from), "only-copy-pad-pad")
            let moveID = UUID()
            let batch = NASRenameBatch(
                title: "Move to Trip B", origin: .move, nasRoot: w.nas.path, moveJournalID: moveID,
                ops: [NASRename(from: from, to: to, byteCount: 17)]
            )
            try w.queue.save(batch)

            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            NASFileIO.renameExclusivePrimitive = { source, destination in
                entered.signal()
                release.wait()
                return renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
            let jobDone = DispatchSemaphore(value: 0)
            let undoDone = DispatchSemaphore(value: 0)
            let follower = w.follower()
            let nas = w.nas
            nonisolated(unsafe) var undoResult: NASUndoResult?
            Thread {
                var pending = try? XCTUnwrap(w.queue.pending(nasRoot: nas.path).first)
                if var loaded = pending { _ = try? follower.apply(&loaded, nasRoot: nas); pending = loaded }
                jobDone.signal()
            }.start()
            XCTAssertEqual(entered.wait(timeout: .now() + 10), .success, "the job reached its rename")

            Thread {
                undoResult = try? follower.undo(moveJournalID: moveID, nasRoot: nas)
                undoDone.signal()
            }.start()
            XCTAssertEqual(undoDone.wait(timeout: .now() + 0.5), .timedOut, "the Undo waits while the job renames")
            release.signal()
            release.signal()
            XCTAssertEqual(jobDone.wait(timeout: .now() + 10), .success)
            XCTAssertEqual(undoDone.wait(timeout: .now() + 10), .success)

            NASFileIO.renameExclusivePrimitive = nil
            XCTAssertEqual(undoResult?.follow.renamed, 1, "the Undo reversed the rename the job made")
            XCTAssertTrue(w.exists(from), "the copy is back where the catalog says it is")
            XCTAssertFalse(w.exists(to))
            let saved = try XCTUnwrap(w.queue.batches(forMoveJournal: moveID).first)
            XCTAssertNotNil(saved.undoneAt)
        }
    }

    // MARK: - A step that stopped half way

    private func pair(_ name: String, from source: UUID, to target: UUID) -> (old: PhotoEventAssignment, new: PhotoEventAssignment) {
        let old = PhotoEventAssignment(
            sourceRootPath: "/Card", relativePath: name, fileSize: 1,
            modifiedAt: Date(timeIntervalSince1970: 1_000), eventID: source, deviceID: "sony-a7v"
        )
        var new = old
        new.eventID = target
        return (old, new)
    }

    func testAnUndoIsMarkedBeforeItsFirstRenameAndClosedOnlyWhenTheCatalogFollowed() throws {
        try withTemporaryDirectory { root in
            let journals = root.appendingPathComponent("Journals", isDirectory: true)
            let a = try writeFile(root.appendingPathComponent("Old/A.ARW"), "a")
            let entries = [pair("A.ARW", from: UUID(), to: UUID())]
            let report = try DriveMoveService().apply(
                [DriveMove(sourcePath: a.path, destinationPath: root.appendingPathComponent("New/A.ARW").path, byteCount: 1)],
                title: "Move", journalFolder: journals,
                removedAssignments: entries.map(\.old), addedAssignments: entries.map(\.new), assignmentMoveSources: [a.path]
            )
            let url = URL(fileURLWithPath: try XCTUnwrap(report.journalPath))
            XCTAssertTrue(DriveMoveService.interruptedSteps(in: journals).isEmpty)

            let undone = try DriveMoveService().undo(journalURL: url)
            XCTAssertNotNil(undone.journal.undoneAt)
            XCTAssertEqual(undone.journal.pendingStep, "undo", "the catalog and NAS phases are still to do")
            XCTAssertEqual(undone.journal.driveStepDone, true)
            XCTAssertEqual(DriveMoveService.interruptedSteps(in: journals).map(\.journal.id), [undone.journal.id])

            try DriveMoveService.finishStep(journalURL: url)
            XCTAssertNil(try DriveMoveService.read(url).pendingStep)
            XCTAssertTrue(DriveMoveService.interruptedSteps(in: journals).isEmpty)

            // And the same for a Redo.
            _ = try DriveMoveService().redo(journalURL: url)
            XCTAssertEqual(try DriveMoveService.read(url).pendingStep, "redo")
            try DriveMoveService.finishStep(journalURL: url)
        }
    }

    func testAnUndoThatFoundNothingToReverseLeavesNoStepToFinish() throws {
        try withTemporaryDirectory { root in
            let journals = root.appendingPathComponent("Journals", isDirectory: true)
            let a = try writeFile(root.appendingPathComponent("Old/A.ARW"), "a")
            let dest = root.appendingPathComponent("New/A.ARW")
            let report = try DriveMoveService().apply(
                [DriveMove(sourcePath: a.path, destinationPath: dest.path, byteCount: 1)], title: "Move", journalFolder: journals
            )
            let url = URL(fileURLWithPath: try XCTUnwrap(report.journalPath))
            // Someone took the file elsewhere: the Undo can reverse nothing.
            try FileManager.default.removeItem(at: dest)
            let undone = try DriveMoveService().undo(journalURL: url)
            XCTAssertTrue(undone.report.reversedIndices.isEmpty)
            XCTAssertNil(undone.journal.pendingStep, "no catalog step to replay for a step that did nothing")
        }
    }

    func testAnInterruptedUndoCountsTheFilesAlreadyBackAsReversedWhenItRunsAgain() throws {
        try withTemporaryDirectory { root in
            let journals = root.appendingPathComponent("Journals", isDirectory: true)
            let a = try writeFile(root.appendingPathComponent("Old/A.ARW"), "a")
            let b = try writeFile(root.appendingPathComponent("Old/B.ARW"), "b")
            let newA = root.appendingPathComponent("New/A.ARW"), newB = root.appendingPathComponent("New/B.ARW")
            let report = try DriveMoveService().apply(
                [
                    DriveMove(sourcePath: a.path, destinationPath: newA.path, byteCount: 1),
                    DriveMove(sourcePath: b.path, destinationPath: newB.path, byteCount: 1),
                ],
                title: "Move", journalFolder: journals
            )
            let url = URL(fileURLWithPath: try XCTUnwrap(report.journalPath))
            // The first Undo got as far as B — A stayed — and stopped; its marker is on the journal.
            try FileManager.default.moveItem(at: newB, to: b)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            object["pendingStep"] = "undo"
            object["driveStepDone"] = false
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)

            let again = try DriveMoveService().undo(journalURL: url)
            XCTAssertEqual(Set(again.report.reversedIndices), [0, 1], "one moved now, one was already back")
            XCTAssertEqual(again.report.moved.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
            XCTAssertNotNil(again.journal.undoneAt)
        }
    }
}
