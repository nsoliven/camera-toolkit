@testable import CameraToolkitCore
import Foundation
import XCTest

/// The one time-ordered history behind ⌘Z and ⌘⇧Z: order, Redo, naming,
/// persistence, and the pieces the actions replay — the journal's Redo, the
/// Trash manifest's dropped entries, the NAS Redo.
final class UndoHistoryTests: XCTestCase {
    private let eventA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let eventB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private func entry(_ title: String, detail: String? = nil, at seconds: TimeInterval = 0) -> UndoEntry {
        UndoEntry(
            createdAt: Date(timeIntervalSince1970: 1_000 + seconds),
            title: title,
            detail: detail,
            action: .files(UndoFilesAction())
        )
    }

    private func assignment(_ name: String, event: UUID? = nil, modified: TimeInterval = 1_000.75) -> PhotoEventAssignment {
        PhotoEventAssignment(
            sourceRootPath: "/Card", relativePath: name, fileSize: 3,
            modifiedAt: Date(timeIntervalSince1970: modified), eventID: event ?? eventA, deviceID: "sony-a7v"
        )
    }

    // MARK: - Order

    func testCommandZAlwaysTakesTheNewestEntryAndRedoPutsItBack() {
        var history = UndoHistory()
        history.record(entry("Sort into Lakeside"))
        history.record(entry("Move to Harbor Walk"))
        history.record(entry("Rename Lakeside"))
        XCTAssertEqual(history.nextUndo?.title, "Rename Lakeside")

        let renamed = history.nextUndo!
        history.completeUndo(renamed)
        XCTAssertEqual(history.nextUndo?.title, "Move to Harbor Walk")
        XCTAssertEqual(history.nextRedo?.title, "Rename Lakeside")

        let moved = history.nextUndo!
        history.completeUndo(moved)
        XCTAssertEqual(history.nextRedo?.title, "Move to Harbor Walk", "the newest Undo is the first Redo")

        history.completeRedo(history.nextRedo!)
        XCTAssertEqual(history.nextUndo?.title, "Move to Harbor Walk")
        XCTAssertEqual(history.nextRedo?.title, "Rename Lakeside")
        XCTAssertEqual(history.undoStack.map(\.title), ["Sort into Lakeside", "Move to Harbor Walk"])
    }

    func testANewActionForgetsWhatWasUndone() {
        var history = UndoHistory()
        history.record(entry("A"))
        history.record(entry("B"))
        history.completeUndo(history.nextUndo!)
        XCTAssertTrue(history.canRedo)
        history.record(entry("C"))
        XCTAssertFalse(history.canRedo, "B can no longer be redone on top of C")
        XCTAssertEqual(history.undoStack.map(\.title), ["A", "C"])
    }

    func testTheHistoryKeepsTheNewestEntriesWhenItIsFull() {
        var history = UndoHistory(capacity: 3)
        for index in 1...5 { history.record(entry("Action \(index)")) }
        XCTAssertEqual(history.undoStack.map(\.title), ["Action 3", "Action 4", "Action 5"])
    }

    func testAnEntryThatCanNeverRunLeavesBothStacks() {
        var history = UndoHistory()
        let stuck = entry("Stuck")
        history.record(entry("Older"))
        history.record(stuck)
        history.remove(stuck.id)
        XCTAssertEqual(history.nextUndo?.title, "Older")
    }

    func testAJournalNoEntryKnowsTakesItsPlaceInTimeOrder() {
        var history = UndoHistory()
        history.record(entry("Old", at: 10))
        history.record(entry("New", at: 30))
        history.insertChronologically(entry("Between", at: 20))
        XCTAssertEqual(history.undoStack.map(\.title), ["Old", "Between", "New"])
    }

    func testMenuNamesCarryTheFileCount() {
        XCTAssertEqual(entry("Move to Lakeside", detail: UndoEntry.fileCount(12)).displayName, "Move to Lakeside (12 files)")
        XCTAssertEqual(entry("Move to Lakeside", detail: UndoEntry.fileCount(1)).displayName, "Move to Lakeside (1 file)")
        XCTAssertEqual(entry("Rename Lakeside").displayName, "Rename Lakeside")
    }

    // MARK: - On disk

    func testTheHistorySurvivesARelaunchInOrderWithItsRedoStack() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("undo-history.sqlite")
            var history = UndoHistory()
            let sort = UndoEntry(
                createdAt: Date(timeIntervalSince1970: 1_001), title: "Sort into Lakeside", detail: "2 files",
                action: .files(UndoFilesAction(removed: [assignment("A.ARW")], added: [assignment("A.ARW", event: eventB)]))
            )
            let edit = UndoEntry(
                createdAt: Date(timeIntervalSince1970: 1_002), title: "Rename Lakeside",
                action: .eventEdit(UndoEventEdit(
                    eventID: eventA,
                    before: SavedCameraEvent(id: eventA, name: "Lakeside", eventDate: Date(timeIntervalSince1970: 0)),
                    after: SavedCameraEvent(id: eventA, name: "Lakeside Trip", eventDate: Date(timeIntervalSince1970: 0)),
                    folderMoves: [UndoFolderMove(old: "/Drive/Lakeside", new: "/Drive/Lakeside Trip", caseOnly: false)],
                    touchedEventIDs: [eventA], nasLink: UUID()
                ))
            )
            let split = UndoEntry(
                createdAt: Date(timeIntervalSince1970: 1_003), title: "Split Burst",
                action: .config(.burstSplit(BurstSplit(memberPathKeys: ["/a", "/b"])))
            )
            let session = UndoEntry(createdAt: Date(timeIntervalSince1970: 1_004), title: "Regroup", action: .session(UUID()))
            history.record(sort)
            history.record(edit)
            history.record(split)
            history.record(session)
            history.completeUndo(session)
            history.completeUndo(split)

            let store = UndoHistoryStore(url: url)
            try store.save(history)
            store.close()

            let reopened = try UndoHistoryStore(url: url).load()
            XCTAssertEqual(reopened.undoStack.map(\.title), ["Sort into Lakeside", "Rename Lakeside"])
            XCTAssertEqual(reopened.redoStack.map(\.title), ["Split Burst"], "the memory-only entry is not written")
            XCTAssertEqual(reopened.undoStack[0], sort, "the exact modification time survives, so the entry names the same assignment")
            XCTAssertEqual(reopened.undoStack[1], edit)
            XCTAssertEqual(reopened.undoStack[0].displayName, "Sort into Lakeside (2 files)")
        }
    }

    func testAnEntryTooLargeToKeepStaysInMemoryOnly() throws {
        try withTemporaryDirectory { root in
            let huge = FaceSnapshot(
                personIDs: [],
                faceIDs: [],
                faces: [FaceSnapshotRow(values: ["crop": .blob(Data(count: UndoHistoryStore.maximumPayloadBytes + 1))])]
            )
            var history = UndoHistory()
            history.record(entry("Small"))
            history.record(UndoEntry(title: "Remove 5,000 faces", action: .faces(huge)))
            let store = UndoHistoryStore(url: root.appendingPathComponent("undo-history.sqlite"))
            try store.save(history)
            XCTAssertEqual(try store.load().undoStack.map(\.title), ["Small"])
        }
    }

    func testSavingAgainReplacesWhatWasStored() throws {
        try withTemporaryDirectory { root in
            let store = UndoHistoryStore(url: root.appendingPathComponent("undo-history.sqlite"))
            var history = UndoHistory()
            history.record(entry("One"))
            history.record(entry("Two"))
            try store.save(history)
            history.completeUndo(history.nextUndo!)
            try store.save(history)
            let loaded = try store.load()
            XCTAssertEqual(loaded.undoStack.map(\.title), ["One"])
            XCTAssertEqual(loaded.redoStack.map(\.title), ["Two"])
        }
    }

    // MARK: - The journal's Redo

    private func pair(_ name: String) -> (old: PhotoEventAssignment, new: PhotoEventAssignment) {
        let old = assignment(name)
        var new = old
        new.eventID = eventB
        return (old, new)
    }

    func testRedoRenamesForwardWhatUndoPutBackAndSwapsTheEntriesAgain() throws {
        try withTemporaryDirectory { root in
            let journals = root.appendingPathComponent("Journals", isDirectory: true)
            let a = try writeFile(root.appendingPathComponent("Old/A.ARW"), "a")
            let b = try writeFile(root.appendingPathComponent("Old/B.ARW"), "b")
            let entries = [pair("A.ARW"), pair("Catalog only.ARW"), pair("B.ARW")]
            let newA = root.appendingPathComponent("New/A.ARW")
            let newB = root.appendingPathComponent("New/B.ARW")
            let report = try DriveMoveService().apply(
                [
                    DriveMove(sourcePath: a.path, destinationPath: newA.path, byteCount: 1),
                    DriveMove(sourcePath: b.path, destinationPath: newB.path, byteCount: 1),
                ],
                title: "Move",
                journalFolder: journals,
                removedAssignments: entries.map(\.old),
                addedAssignments: entries.map(\.new),
                assignmentMoveSources: [a.path, nil, b.path]
            )
            let url = URL(fileURLWithPath: try XCTUnwrap(report.journalPath))

            let undone = try DriveMoveService().undo(journalURL: url)
            XCTAssertEqual(undone.report.moved.count, 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
            XCTAssertNotNil(undone.journal.undoneAt)
            XCTAssertEqual(undone.journal.undoneIndices, [0, 1])
            XCTAssertNil(DriveMoveService.latestUndoableJournal(in: journals), "an undone journal is not an Undo any more")

            let redone = try DriveMoveService().redo(journalURL: url)
            XCTAssertEqual(redone.report.moved.count, 2)
            XCTAssertEqual(redone.report.reversedIndices.sorted(), [0, 1], "the moves that went forward again")
            XCTAssertTrue(FileManager.default.fileExists(atPath: newA.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: newB.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
            XCTAssertNil(redone.journal.undoneAt, "it can be undone again")
            XCTAssertEqual(DriveMoveService.latestUndoableJournal(in: journals)?.journal.id, redone.journal.id)

            // The catalog entries swap forward too — the catalog-only one included.
            let reapply = redone.journal.assignmentsToReapply(redone: redone.report.reversedIndices, fullyRedone: true)
            XCTAssertEqual(reapply.removed, entries.map(\.old))
            XCTAssertEqual(reapply.added, entries.map(\.new))

            // And the cycle repeats: Undo, Redo, Undo again put everything back.
            _ = try DriveMoveService().undo(journalURL: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
            _ = try DriveMoveService().redo(journalURL: url)
            _ = try DriveMoveService().undo(journalURL: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: newB.path))
        }
    }

    func testRedoNeverReplacesAFileThatTookTheDestinationName() throws {
        try withTemporaryDirectory { root in
            let journals = root.appendingPathComponent("Journals", isDirectory: true)
            let a = try writeFile(root.appendingPathComponent("Old/A.ARW"), "a")
            let b = try writeFile(root.appendingPathComponent("Old/B.ARW"), "b")
            let newA = root.appendingPathComponent("New/A.ARW")
            let report = try DriveMoveService().apply(
                [
                    DriveMove(sourcePath: a.path, destinationPath: newA.path, byteCount: 1),
                    DriveMove(sourcePath: b.path, destinationPath: root.appendingPathComponent("New/B.ARW").path, byteCount: 1),
                ],
                title: "Move", journalFolder: journals,
                removedAssignments: [pair("A.ARW").old, pair("B.ARW").old],
                addedAssignments: [pair("A.ARW").new, pair("B.ARW").new],
                assignmentMoveSources: [a.path, b.path]
            )
            let url = URL(fileURLWithPath: try XCTUnwrap(report.journalPath))
            _ = try DriveMoveService().undo(journalURL: url)
            // Something else claims A's new name while the move is undone.
            try writeFile(newA, "someone else's photo")

            let redone = try DriveMoveService().redo(journalURL: url)
            XCTAssertEqual(redone.report.moved.count, 1)
            XCTAssertEqual(redone.report.skipped.count, 1)
            XCTAssertTrue(redone.report.skipped[0].reason.contains("Nothing was replaced"))
            XCTAssertEqual(try String(contentsOf: newA, encoding: .utf8), "someone else's photo")
            XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "a", "the file that could not go forward stays where Undo put it")
            XCTAssertEqual(redone.report.reversedIndices, [1])
            let reapply = redone.journal.assignmentsToReapply(redone: redone.report.reversedIndices, fullyRedone: false)
            XCTAssertEqual(reapply.added.map(\.relativePath), ["B.ARW"], "only the entry whose file went forward swaps")
        }
    }

    func testRedoOfAJournalThatWasNeverUndoneRefuses() throws {
        try withTemporaryDirectory { root in
            let a = try writeFile(root.appendingPathComponent("Old/A.ARW"), "a")
            let report = try DriveMoveService().apply(
                [DriveMove(sourcePath: a.path, destinationPath: root.appendingPathComponent("New/A.ARW").path, byteCount: 1)],
                title: "Move", journalFolder: root.appendingPathComponent("Journals")
            )
            XCTAssertThrowsError(try DriveMoveService().redo(journalURL: URL(fileURLWithPath: try XCTUnwrap(report.journalPath))))
        }
    }

    func testAJournalUndoneByAnEarlierBuildRedoesEveryCompletedMove() throws {
        try withTemporaryDirectory { root in
            let journals = root.appendingPathComponent("Journals", isDirectory: true)
            let a = try writeFile(root.appendingPathComponent("Old/A.ARW"), "a")
            let newA = root.appendingPathComponent("New/A.ARW")
            let report = try DriveMoveService().apply(
                [DriveMove(sourcePath: a.path, destinationPath: newA.path, byteCount: 1)],
                title: "Move", journalFolder: journals
            )
            let url = URL(fileURLWithPath: try XCTUnwrap(report.journalPath))
            _ = try DriveMoveService().undo(journalURL: url)
            // A journal an older build closed carries no list of what went back.
            var text = try String(contentsOf: url, encoding: .utf8)
            text = text.replacingOccurrences(of: #"\s*"undoneIndices"\s*:\s*\[[^\]]*\],?"#, with: "", options: .regularExpression)
            try text.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertNil(try DriveMoveService.read(url).undoneIndices)

            let redone = try DriveMoveService().redo(journalURL: url)
            XCTAssertEqual(redone.report.moved.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: newA.path))
        }
    }

    // MARK: - The Trash manifest

    private func trashFolder(_ root: URL) -> URL {
        root.appendingPathComponent("Drive/.Camera Toolkit/_Trash", isDirectory: true)
    }

    /// Files under the temp folder are not on a mounted volume, so they go to
    /// the removed-files folder, keeping their folders below `Unsorted`.
    private func trash(_ root: URL) -> MediaTrashService {
        MediaTrashService(removedFilesRoot: trashFolder(root), volumeRoot: { _ in nil })
    }

    func testAManifestKeepsTheDroppedEntriesWithTheirExactModificationTime() throws {
        try withTemporaryDirectory { root in
            let dropped = assignment("DSC1.ARW", modified: 1_752_000_000.6)
            let source = try writeFile(root.appendingPathComponent("Unsorted/DSC1.ARW"), "photo")
            let trash = self.trash(root)
            let key = EventStorageLocations.pathKey(source.path)
            let batch = try trash.trash(
                files: [OrganizeFile(path: source.path, size: 5, modifiedAt: dropped.modifiedAt)],
                originRoot: root.appendingPathComponent("Unsorted"),
                context: TrashContext(eventIDsByPathKey: [key: eventA], assignmentsByPathKey: [key: [dropped]])
            )
            let entry = try XCTUnwrap(batch.entries.first)
            XCTAssertEqual(entry.droppedAssignments, [dropped])
            // Read back from the manifest on disk: the whole-second dates the
            // manifest uses elsewhere must not truncate the entry's identity.
            let listed = try XCTUnwrap(trash.listBatches(under: [trashFolder(root)]).first?.entries.first)
            XCTAssertEqual(listed.droppedAssignments, [dropped])
            XCTAssertEqual(CatalogStore.eventAssetID(listed.droppedAssignments[0]), CatalogStore.eventAssetID(dropped))
        }
    }

    func testARestoreReportsTheEntriesOfTheFilesThatCameBackAndOnlyThose() throws {
        try withTemporaryDirectory { root in
            let one = try writeFile(root.appendingPathComponent("Unsorted/ONE.ARW"), "1")
            let two = try writeFile(root.appendingPathComponent("Unsorted/TWO.ARW"), "2")
            let trash = self.trash(root)
            var context = TrashContext()
            for (file, name) in [(one, "ONE.ARW"), (two, "TWO.ARW")] {
                context.assignmentsByPathKey[EventStorageLocations.pathKey(file.path)] = [assignment(name)]
            }
            let batch = try trash.trash(
                files: [one, two].map { OrganizeFile(path: $0.path, size: 1, modifiedAt: Date()) },
                originRoot: root.appendingPathComponent("Unsorted"), context: context
            )
            // A name taken since keeps TWO in Trash.
            try writeFile(two, "someone else's")
            let items = batch.undoTrashedFiles.map(\.item)
            let report = trash.restore(items: items)
            XCTAssertEqual(report.restored, [one.path])
            XCTAssertEqual(report.conflicts, [two.path])
            XCTAssertEqual(report.restoredEntries.flatMap(\.droppedAssignments).map(\.relativePath), ["ONE.ARW"])
            XCTAssertEqual(try String(contentsOf: two, encoding: .utf8), "someone else's", "nothing was replaced")
        }
    }

    func testAManifestFromBeforeEntriesWereRecordedStillReadsAndRestoresFilesOnly() throws {
        let json = """
        {"trashedRelativePath":"a/B.ARW","originalAbsolutePath":"/x/B.ARW","personNames":[],"size":4}
        """
        let entry = try JSONDecoder().decode(MediaTrashEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.droppedAssignments, [])
    }

    func testARestoredFileCanBeSentToTrashAgain() throws {
        try withTemporaryDirectory { root in
            let source = try writeFile(root.appendingPathComponent("Unsorted/DSC1.ARW"), "photo")
            let trash = self.trash(root)
            let file = OrganizeFile(path: source.path, size: 5, modifiedAt: Date())
            let first = try trash.trash(files: [file], originRoot: root.appendingPathComponent("Unsorted"))
            _ = trash.restore(items: first.undoTrashedFiles.map(\.item))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            let second = try trash.trash(files: [file], originRoot: root.appendingPathComponent("Unsorted"))
            XCTAssertEqual(second.entries.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }

    // MARK: - The NAS

    func testNASRedoQueuesTheClosedBatchAgainOnceAndTheNextUndoReversesIt() throws {
        try withTemporaryDirectory { root in
            let nas = root.appendingPathComponent("NAS", isDirectory: true)
            let old = try writeFile(nas.appendingPathComponent("2026/A/x.ARW"), "x")
            let new = nas.appendingPathComponent("2026/B/x.ARW")
            let queue = NASRenameQueue(journalFolder: root.appendingPathComponent("Journals"))
            let link = UUID()
            var batch = NASRenameBatch(
                title: "Move", origin: .move, nasRoot: nas.path, moveJournalID: link,
                ops: [NASRename(from: "2026/A/x.ARW", to: "2026/B/x.ARW", byteCount: 1)]
            )
            let follower = NASMoveFollower(store: nil, queue: queue)
            try follower.apply(&batch, nasRoot: nas)
            XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))

            let undone = try follower.undo(moveJournalID: link, nasRoot: nas)
            XCTAssertEqual(undone.follow.renamed, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))

            let redone = try follower.redo(moveJournalID: link, nasRoot: nas)
            XCTAssertEqual(redone.follow.renamed, 1, "the copy follows the redone move")
            XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))

            // A second Redo finds nothing left to queue.
            let again = try follower.redo(moveJournalID: link, nasRoot: nas)
            XCTAssertEqual(again.follow.renamed, 0)

            // The redone batch belongs to the same move, so Undo reverses it too.
            _ = try follower.undo(moveJournalID: link, nasRoot: nas)
            XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
        }
    }

    func testNASRedoWhileTheNASIsAwayLeavesTheRenamesQueued() throws {
        try withTemporaryDirectory { root in
            let nas = root.appendingPathComponent("NAS", isDirectory: true)
            try writeFile(nas.appendingPathComponent("2026/A/x.ARW"), "x")
            let queue = NASRenameQueue(journalFolder: root.appendingPathComponent("Journals"))
            let link = UUID()
            var batch = NASRenameBatch(
                title: "Move", origin: .move, nasRoot: nas.path, moveJournalID: link,
                ops: [NASRename(from: "2026/A/x.ARW", to: "2026/B/x.ARW", byteCount: 1)]
            )
            let follower = NASMoveFollower(store: nil, queue: queue)
            try follower.apply(&batch, nasRoot: nas)
            _ = try follower.undo(moveJournalID: link, nasRoot: nas)

            let away = root.appendingPathComponent("NotMounted", isDirectory: true)
            let redone = try follower.redo(moveJournalID: link, nasRoot: away)
            XCTAssertEqual(redone.queued, 1, "the rename waits in the queue for the NAS")
            XCTAssertEqual(queue.pendingRenameCount(), 1)
            XCTAssertEqual(queue.batches(forMoveJournal: link).count, 2, "the closed batch and the queued one; the reverse batch belongs to the Undo")
        }
    }
}
