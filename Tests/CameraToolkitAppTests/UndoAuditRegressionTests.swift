@testable import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// Regressions from the sync-and-move safety audit, through the one undo
/// history: ⌘Z during a running NAS rename job, ⌘Z of an old change after its
/// photo moved on, an entry put back under a name taken since, and an Undo
/// that stopped half way. With the Buffer usually away, for a photo only the
/// NAS has ⌘Z is often the only way back — these must be solid.
@MainActor
final class UndoAuditRegressionTests: XCTestCase {
    override func tearDown() {
        NASFileIO.renameExclusivePrimitive = nil
        super.tearDown()
    }

    /// Blocks the NAS rename primitive until released, and says when it was entered.
    private final class RenameGate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = 0
        private let release = DispatchSemaphore(value: 0)
        var enteredCount: Int { lock.withLock { entered } }
        func install() {
            NASFileIO.renameExclusivePrimitive = { [self] source, destination in
                lock.withLock { entered += 1 }
                release.wait()
                return renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
        }
        func open() { for _ in 0..<64 { release.signal() } }
    }

    private func nasLibrary() throws -> AuditLibrary {
        let library = try AuditLibrary.make()
        library.addEvent("a", name: "Trip A")
        library.addEvent("b", name: "Trip B", date: AuditLibrary.day.addingTimeInterval(86_400))
        library.addEvent("c", name: "Trip C", date: AuditLibrary.day.addingTimeInterval(2 * 86_400))
        try FileManager.default.createDirectory(at: library.nasRoot, withIntermediateDirectories: true)
        return library
    }

    private func move(_ library: AuditLibrary, _ names: [String], from: String, to: String) async throws {
        await library.open(from)
        let ids = Set((library.workspace.eventStacks[library.id(from)] ?? []).filter { $0.files.contains { names.contains($0.name) } }.map(\.id))
        library.workspace.moveStacks(ids, fromEvent: library.id(from), toEvent: library.id(to))
        try await library.settle()
        try await library.waitUntil(timeout: 20, "renames never drained") { library.workspace.pendingNASRenameCount == 0 && !library.model.isBusy }
        try await library.settle()
    }

    private func rows(_ library: AuditLibrary) -> [String] {
        library.model.configuration.photoEventAssignments.map { library.key(of: $0.eventID) + "/" + $0.relativePath }.sorted()
    }

    private func forgetNewestUndo(_ library: AuditLibrary) {
        if let newest = library.workspace.undoHistory.nextUndo { library.workspace.undoHistory.remove(newest.id) }
    }

    // MARK: - ⌘Z during a NAS rename job

    /// The NAS Rename job that follows a NAS-only move is renaming the photo's
    /// only copy; ⌘Z used to cancel its queued rename on disk behind the job's
    /// back, and the job then saved its stale copy over the cancellation: the
    /// catalog went back to the old event and the only copy stayed under the
    /// new one. ⌘Z now waits for the job gate like every step that touches the
    /// NAS: it says so and changes nothing, and works once the job is done.
    func testCmdZDuringTheNASRenameJobChangesNothingAndWorksAfterwards() async throws {
        let library = try nasLibrary()
        defer { library.tearDown() }
        try library.place("a", name: "DSC00001.ARW", content: "drive-photo-pad-pad-pad")
        let only = try library.placeOnNASOnly("a", name: "DSC00002.ARW", content: "nas-only-photo-pad-pad")
        library.workspace.refreshConnectivity()
        try await library.settle()
        await library.open("a")
        let gate = RenameGate()
        gate.install()
        let tile = try XCTUnwrap(library.workspace.eventStacks[library.id("a")]?.first { $0.files.contains { $0.name == "DSC00002.ARW" } })
        library.workspace.moveStacks([tile.id], fromEvent: library.id("a"), toEvent: library.id("b"))
        // The move lands (catalog only) and the NAS Rename job starts, then blocks in its rename.
        try await library.waitUntil(timeout: 20, "the NAS job never reached its rename") { gate.enteredCount > 0 }
        XCTAssertTrue(library.model.isBusy)
        let batchesBefore = library.workspace.nasRenameQueue.batches()

        library.workspace.undo()  // ⌘Z
        XCTAssertTrue(library.model.statusMessage.contains("already running"), library.model.statusMessage)
        XCTAssertEqual(library.workspace.nasRenameQueue.batches(), batchesBefore, "the queue was not touched under the job's feet")
        XCTAssertTrue(rows(library).contains("b/DSC00002.ARW"), "the catalog did not move")
        XCTAssertTrue(library.workspace.canUndo, "the entry is still there")

        gate.open()
        try await library.waitUntil(timeout: 20, "the job never finished") { !library.model.isBusy && library.workspace.pendingNASRenameCount == 0 }
        try await library.settle()
        let bCopy = try XCTUnwrap(library.locations.archiveURL(for: library.assignments("b")[0], event: library.event("b")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bCopy.path), "the job finished its rename")

        library.workspace.undo()
        try await library.settle()
        try await library.waitUntil(timeout: 20, "the undo never finished") { !library.model.isBusy && library.workspace.pendingNASRenameCount == 0 }
        XCTAssertTrue(rows(library).contains("a/DSC00002.ARW"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: only.url.path), "the only copy is back under Trip A, where the catalog says it is")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bCopy.path))
    }

    // MARK: - ⌘Z after the photo moved on

    /// A catalog-only move, then a journaled move that took the same photo on.
    /// The newest change is undone first; and when only the older one is left to
    /// undo (the newer entry is gone) it does not put the old entry back beside
    /// the new one — one photo, one owner.
    func testCmdZOfACatalogOnlyMoveAfterThePhotoMovedOn() async throws {
        let library = try nasLibrary()
        defer { library.tearDown() }
        try library.place("b", name: "DSC00009.ARW", content: "drive-photo-in-b-pad-pad")
        let only = try library.placeOnNASOnly("a", name: "DSC00002.ARW", content: "nas-only-photo-pad-pad")
        library.workspace.refreshConnectivity()
        try await library.settle()
        try await move(library, ["DSC00002.ARW"], from: "a", to: "b")
        try await move(library, ["DSC00002.ARW", "DSC00009.ARW"], from: "b", to: "c")
        let cCopy = try XCTUnwrap(library.locations.archiveURL(for: only.assignment, event: library.event("c")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cCopy.path))

        // Ordered: the newest goes first, then the older one.
        do {
            let workspace = library.workspace
            workspace.undo()
            try await library.settle()
            try await library.waitUntil(timeout: 20, "drain") { workspace.pendingNASRenameCount == 0 && !library.model.isBusy }
            XCTAssertTrue(rows(library).contains("b/DSC00002.ARW"))
            workspace.undo()
            try await library.settle()
            try await library.waitUntil(timeout: 20, "drain") { workspace.pendingNASRenameCount == 0 && !library.model.isBusy }
            XCTAssertEqual(rows(library), ["a/DSC00002.ARW", "b/DSC00009.ARW"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: only.url.path), "the NAS copy is back under Trip A")
            for _ in 0..<2 {
                workspace.redo()
                try await library.settle()
                try await library.waitUntil(timeout: 20, "drain") { workspace.pendingNASRenameCount == 0 && !library.model.isBusy }
            }
            XCTAssertEqual(rows(library), ["c/DSC00002.ARW", "c/DSC00009.ARW"])
        }

        // Out of order: the newer entry is not in the history any more.
        forgetNewestUndo(library)
        library.workspace.undo()
        try await library.settle()
        XCTAssertEqual(rows(library), ["c/DSC00002.ARW", "c/DSC00009.ARW"], "the photo is not given a second owner: \(rows(library))")
        XCTAssertTrue(library.model.statusMessage.contains("moved on"), library.model.statusMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cCopy.path), "its NAS copy stays where the newer change put it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: only.url.path))
    }

    // MARK: - A name taken since

    /// Undoing a move puts its entries back under their names. Another file
    /// took one of them since: the drive would put the file back and the
    /// catalog could not (or would hold two entries of one name). It is found
    /// before anything moves.
    func testUndoRefusesToRestoreANameTakenSinceAndMovesNothing() async throws {
        let library = try nasLibrary()
        defer { library.tearDown() }
        let x = try library.place("c", name: "DSC00005.ARW", content: "photo-x-in-c-pad-pad-pad")
        _ = try library.placeOnNASOnly("a", name: "DSC00005.ARW", content: "a-different-photo-y-pad")
        library.workspace.refreshConnectivity()
        try await library.settle()
        try await move(library, ["DSC00005.ARW"], from: "c", to: "b")  // journaled drive move of x
        try await move(library, ["DSC00005.ARW"], from: "a", to: "c")  // y, catalog only, takes the free name
        XCTAssertEqual(rows(library), ["b/DSC00005.ARW", "c/DSC00005.ARW"])
        let before = library.model.configuration.photoEventAssignments
        let movedX = try XCTUnwrap(library.assignments("b").first)
        let xNow = try XCTUnwrap(library.impliedPath(movedX))
        XCTAssertTrue(FileManager.default.fileExists(atPath: xNow))

        // The newest change is not in the history: the older move meets the name.
        forgetNewestUndo(library)
        library.workspace.undo()
        try await library.settle()
        XCTAssertTrue(library.model.statusMessage.contains("another file has taken it"), library.model.statusMessage)
        XCTAssertEqual(library.model.configuration.photoEventAssignments, before, "no second entry of one name")
        XCTAssertTrue(FileManager.default.fileExists(atPath: xNow), "and the file did not move back to be left with no entry")
        XCTAssertFalse(FileManager.default.fileExists(atPath: x.url.path))
        XCTAssertEqual(library.workspace.latestMoveJournalTitle, "Move to Trip B", "the move is still there to undo once the name is free")
    }

    func testTheOrderedUndoRestoresBothNamesExactly() async throws {
        let library = try nasLibrary()
        defer { library.tearDown() }
        let x = try library.place("c", name: "DSC00005.ARW", content: "photo-x-in-c-pad-pad-pad")
        let y = try library.placeOnNASOnly("a", name: "DSC00005.ARW", content: "a-different-photo-y-pad")
        library.workspace.refreshConnectivity()
        try await library.settle()
        try await move(library, ["DSC00005.ARW"], from: "c", to: "b")
        try await move(library, ["DSC00005.ARW"], from: "a", to: "c")
        let workspace = library.workspace

        workspace.undo()
        try await library.settle()
        try await library.waitUntil(timeout: 20, "drain") { workspace.pendingNASRenameCount == 0 && !library.model.isBusy }
        workspace.undo()
        try await library.settle()
        try await library.waitUntil(timeout: 20, "drain") { workspace.pendingNASRenameCount == 0 && !library.model.isBusy }
        XCTAssertEqual(rows(library), ["a/DSC00005.ARW", "c/DSC00005.ARW"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: x.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: y.url.path))
    }

    // MARK: - An Undo that stopped half way

    /// The app stopped after the Undo's drive renames and before its catalog
    /// and NAS phases: the journal already said "undone", so nothing ever put
    /// the catalog back and the file sat under an event that no longer owned it.
    /// The step is marked before the first rename and closed only when the
    /// catalog and the NAS followed; a launch replays what is left.
    func testAnUndoThatStoppedAfterTheDriveIsReplayedAtLaunch() async throws {
        let library = try nasLibrary()
        defer { library.tearDown() }
        let file = try library.place("a", name: "DSC00001.ARW", content: "drive-photo-pad-pad-pad")
        let nasOld = try XCTUnwrap(library.locations.archiveURL(for: file.assignment, event: library.event("a")))
        try FileManager.default.createDirectory(at: nasOld.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("drive-photo-pad-pad-pad".utf8).write(to: nasOld)
        library.workspace.refreshConnectivity()
        try await library.settle()
        try await move(library, ["DSC00001.ARW"], from: "a", to: "b")
        let moved = library.model.configuration.photoEventAssignments
        let nasNew = try XCTUnwrap(library.locations.archiveURL(for: library.assignments("b")[0], event: library.event("b")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nasNew.path))
        library.workspace.flushUndoHistory()

        // The Undo's drive phase ran; the app stopped before anything else.
        let journal = try XCTUnwrap(DriveMoveService.latestUndoableJournal(in: library.workspace.journalFolder))
        _ = try DriveMoveService().undo(journalURL: journal.url)
        XCTAssertEqual(library.model.configuration.photoEventAssignments, moved, "the catalog is still where the move put it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path), "and the file is already back")
        XCTAssertEqual(DriveMoveService.interruptedSteps(in: library.workspace.journalFolder).count, 1, "the journal remembers the step was not finished")

        let relaunched = EventsWorkspace(
            model: library.model,
            supportFolder: library.root.appendingPathComponent("Support", isDirectory: true),
            driveActivityGate: DriveActivityGate()
        )
        await relaunched.loadUndoHistory()
        try await library.waitUntil(timeout: 30, "the replay never finished") { !library.model.isBusy && relaunched.isQuiet }
        try await library.settle()
        XCTAssertEqual(library.assignments("a").map(\.relativePath), ["DSC00001.ARW"], "the catalog was put back")
        XCTAssertTrue(library.assignments("b").isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nasOld.path), "and so was the NAS copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nasNew.path))
        XCTAssertTrue(DriveMoveService.interruptedSteps(in: relaunched.journalFolder).isEmpty, "the step is closed")
        XCTAssertEqual(relaunched.redoMenuTitle, "Redo Move to Trip B (1 file)", "it is a finished Undo, offered as a Redo")
        XCTAssertFalse(relaunched.undoHistory.undoStack.contains { $0.journalID == journal.journal.id })

        relaunched.redo()
        try await library.waitUntil(timeout: 30, "the redo never finished") { !library.model.isBusy && relaunched.isQuiet && relaunched.pendingNASRenameCount == 0 }
        try await library.settle()
        XCTAssertEqual(library.model.configuration.photoEventAssignments.map(CatalogStore.eventAssetID).sorted(), moved.map(CatalogStore.eventAssetID).sorted())
        XCTAssertTrue(FileManager.default.fileExists(atPath: nasNew.path))
    }

    /// The same Undo stopped among the drive's renames: some files back, some
    /// not. Run again it recognises the ones already back, and the catalog
    /// follows all of them.
    func testAnUndoThatStoppedAmongTheDrivesRenamesFinishesTheRestAndTheCatalog() async throws {
        let library = try nasLibrary()
        defer { library.tearDown() }
        let one = try library.place("a", name: "DSC00001.ARW", content: "drive-photo-one-pad-pad")
        let two = try library.place("a", name: "DSC00002.ARW", content: "drive-photo-two-pad-pad")
        try await move(library, ["DSC00001.ARW", "DSC00002.ARW"], from: "a", to: "b")
        XCTAssertEqual(rows(library), ["b/DSC00001.ARW", "b/DSC00002.ARW"])
        let workspace = library.workspace
        workspace.flushUndoHistory()

        // One rename back was done; the app stopped there.
        let journal = try XCTUnwrap(DriveMoveService.latestUndoableJournal(in: workspace.journalFolder))
        let first = try XCTUnwrap(journal.journal.moves.first { $0.sourcePath == one.url.path })
        try FileManager.default.createDirectory(atPath: (first.sourcePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: first.destinationPath, toPath: first.sourcePath)
        // The step's start left its marker on the journal.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal.url)) as? [String: Any])
        object["pendingStep"] = "undo"
        object["driveStepDone"] = false
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: journal.url)

        let relaunched = EventsWorkspace(
            model: library.model,
            supportFolder: library.root.appendingPathComponent("Support", isDirectory: true),
            driveActivityGate: DriveActivityGate()
        )
        await relaunched.loadUndoHistory()
        try await library.waitUntil(timeout: 30, "the resumed Undo never finished") { !library.model.isBusy && relaunched.isQuiet }
        try await library.settle()
        XCTAssertEqual(rows(library), ["a/DSC00001.ARW", "a/DSC00002.ARW"], "both back, both in the catalog")
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: two.url.path))
        XCTAssertTrue(DriveMoveService.interruptedSteps(in: relaunched.journalFolder).isEmpty)
    }
}
