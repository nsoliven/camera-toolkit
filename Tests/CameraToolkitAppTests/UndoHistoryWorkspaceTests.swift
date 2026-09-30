import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// ⌘Z and ⌘⇧Z through the app: one time-ordered history over sorts, moves,
/// merges, Trash, duplicate resolutions, event edits, configuration and face
/// changes — every Undo returns the exact prior state, every Redo the state
/// after, nothing is replaced, and what moves files runs as a job.
@MainActor
final class UndoHistoryWorkspaceTests: XCTestCase {
    private func photo(_ tag: String) -> String { "ARW-\(tag)-" + String(repeating: "x", count: 24) }

    private func twoEvents(_ library: AuditLibrary) {
        library.addEvent("a", name: "Beach Day", date: AuditLibrary.day)
        library.addEvent("b", name: "Hotel Night", date: AuditLibrary.day.addingTimeInterval(86_400))
    }

    private func click(_ library: AuditLibrary, _ paths: [String], from: String, to: String) throws {
        let stacks = try paths.map { try XCTUnwrap(library.stack(at: $0, on: from), $0) }
        library.workspace.moveStacks(Set(stacks.map(\.id)), fromEvent: library.id(from), toEvent: library.id(to))
    }

    private struct Snapshot: Equatable {
        var rows: [String]
        var files: [String]
    }

    /// The catalog and every file on the drive and the NAS, Trash aside.
    private func snapshot(_ library: AuditLibrary) -> Snapshot {
        let rows = library.model.configuration.photoEventAssignments.map {
            "\(library.key(of: $0.eventID))|\($0.relativePath)|\($0.fileSize)|\($0.modifiedAt.timeIntervalSince1970)"
        }.sorted()
        let files = library.diskFiles()
            .filter { !$0.path.contains("/_Trash/") }
            .map { file in
                file.path.replacingOccurrences(of: library.root.path, with: "").lowercased() + "#" + String(decoding: file.content, as: UTF8.self)
            }.sorted()
        return Snapshot(rows: rows, files: files)
    }

    /// Every job, board read and queued NAS rename is done. The NAS renames
    /// drain only while the NAS is there — a test with no NAS keeps them queued.
    private func settle(_ library: AuditLibrary) async throws {
        try await library.settle()
        if FileManager.default.fileExists(atPath: library.nasRoot.path) {
            try await library.waitUntil(timeout: 30, "the NAS renames never drained") {
                library.workspace.pendingNASRenameCount == 0 && library.workspace.isQuiet
            }
            try await library.settle()
        }
    }

    /// A NAS copy of a drive file, at the event's mirror path.
    @discardableResult
    private func putOnNAS(_ library: AuditLibrary, _ assignment: PhotoEventAssignment, in key: String, content: String) throws -> URL {
        try FileManager.default.createDirectory(at: library.nasRoot, withIntermediateDirectories: true)
        let url = try XCTUnwrap(library.locations.archiveURL(for: assignment, event: library.event(key)))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        library.workspace.refreshConnectivity()
        return url
    }

    // MARK: - Merges

    /// A merge-only move: the target already has the identical photo, so the
    /// source's entry goes, its spare copy goes to Trash, and its NAS copy
    /// follows into the kept copy's place. One ⌘Z brings all of it back.
    func testAMergeOnlyMoveIsUndoneAndRedoneWithItsEntryItsSpareCopyAndItsNASRename() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let spare = try library.place("a", name: "DSC00001.ARW", content: photo("same"))
        _ = try library.place("b", name: "DSC00001.ARW", content: photo("same"))
        let nasCopy = try putOnNAS(library, spare.assignment, in: "a", content: photo("same"))
        await library.open("a", "b")
        try await settle(library)
        let before = snapshot(library)
        let census = library.contentCensus()

        try click(library, [spare.url.path], from: "a", to: "b")
        try await settle(library)
        let after = snapshot(library)
        XCTAssertTrue(library.assignments("a").isEmpty, "the entry merged into Hotel Night's own")
        XCTAssertEqual(library.assignments("b").count, 1)
        XCTAssertEqual(library.trashedNames(), ["DSC00001.ARW"], "the spare copy is in Trash")
        XCTAssertFalse(library.exists(nasCopy.path), "the NAS copy followed the merge")
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Move to Hotel Night (1 file)", "a merge-only move is in the history — it used to record nothing")
        XCTAssertNotEqual(after, before)

        workspace.undo()
        XCTAssertTrue(library.model.isBusy, "a step that renames files runs as a job")
        try await settle(library)
        XCTAssertEqual(snapshot(library), before, "Undo returns the exact prior state")
        XCTAssertEqual(library.trashedNames(), [], "the spare copy came out of Trash")
        XCTAssertTrue(library.exists(nasCopy.path), "and the NAS copy is back where it was")
        XCTAssertEqual(library.contentCensus(), census)
        XCTAssertEqual(workspace.redoMenuTitle, "Redo Move to Hotel Night (1 file)")
        XCTAssertNotNil(library.stack(at: spare.url.path, on: "a"), "and the tile is back on the board")

        workspace.redo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), after, "Redo merges again")
        XCTAssertEqual(library.trashedNames(), ["DSC00001.ARW"])
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Move to Hotel Night (1 file)")
        XCTAssertEqual(library.contentCensus(), census)

        workspace.undo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), before, "and Undo once more")
    }

    /// A move that brings some files across and merges one: one entry, one
    /// journal for the renames, and one ⌘Z for both.
    func testAMoveThatBothRenamesAndMergesIsOneUndo() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let same = try library.place("a", name: "DSC00001.ARW", content: photo("same"))
        _ = try library.place("b", name: "DSC00001.ARW", content: photo("same"))
        let other = try library.place("a", name: "DSC00002.ARW", content: photo("2"))
        await library.open("a", "b")
        let before = snapshot(library)

        try click(library, [same.url.path, other.url.path], from: "a", to: "b")
        try await settle(library)
        XCTAssertEqual(library.assignments("b").count, 2)
        XCTAssertEqual(workspace.undoHistory.undoStack.count, 1, "one click, one entry")

        workspace.undo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), before)
        XCTAssertEqual(library.trashedNames(), [])
        XCTAssertFalse(workspace.canUndo)
    }

    // MARK: - Trash

    private func trashFromEvent(_ library: AuditLibrary, _ key: String, paths: [String]) async throws {
        let stacks = try paths.map { try XCTUnwrap(library.stack(at: $0, on: key), $0) }
        library.workspace.requestTrash(stackIDs: Set(stacks.map(\.id)), fromEvent: library.id(key))
        library.workspace.confirmTrash(try XCTUnwrap(library.workspace.pendingTrash))
        try await settle(library)
    }

    /// Trash used to drop the event's entry and never bring it back: the
    /// restored file sat on the drive and no event showed it.
    func testTrashThenUndoPutsTheEntryTheFileAndTheTileBack() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let keep = try library.place("a", name: "DSC00002.ARW", content: photo("2"))
        await library.open("a")
        let before = snapshot(library)

        try await trashFromEvent(library, "a", paths: [file.url.path])
        let after = snapshot(library)
        XCTAssertEqual(library.assignments("a").map(\.relativePath), ["DSC00002.ARW"])
        XCTAssertEqual(library.trashedNames(), ["DSC00001.ARW"])
        XCTAssertNil(library.stack(at: file.url.path, on: "a"))
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Move to Trash (1 file)")

        workspace.undo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), before, "the file is back and so is its entry")
        XCTAssertEqual(library.trashedNames(), [])
        XCTAssertEqual(library.assignments("a").count, 2)
        XCTAssertNotNil(library.stack(at: file.url.path, on: "a"), "the tile is back on the board")
        XCTAssertNotNil(library.stack(at: keep.url.path, on: "a"))
        XCTAssertEqual(workspace.assignmentCount(for: library.id("a")), 2)

        workspace.redo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), after)
        XCTAssertEqual(library.trashedNames(), ["DSC00001.ARW"])
        XCTAssertNil(library.stack(at: file.url.path, on: "a"))
    }

    /// The Trash window's Restore is the other way back: the manifest carries
    /// the entries the trash dropped, so the file and the entry return
    /// together — measured before: file back on disk, zero entries, empty board.
    func testRestoringFromTheTrashWindowPutsTheEntryAndTheTileBack() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a")
        let before = snapshot(library)
        try await trashFromEvent(library, "a", paths: [file.url.path])
        XCTAssertTrue(library.assignments("a").isEmpty)

        let service = MediaTrashService(removedFilesRoot: library.locations.removedFilesRoot)
        let items = service.listItems(under: library.locations.trashRoots())
        XCTAssertEqual(items.count, 1)
        let report = service.restore(items: items)
        XCTAssertEqual(report.restored.count, 1)
        XCTAssertEqual(workspace.reinstateTrashedAssignments(report), 1)
        try await settle(library)
        await library.open("a")
        XCTAssertEqual(snapshot(library), before, "the window's Restore leaves the same state Undo does")
        XCTAssertNotNil(library.stack(at: file.url.path, on: "a"))

        // Undo of the Trash afterwards finds nothing left to restore and does
        // not add a second entry for the file.
        workspace.undo()
        try await settle(library)
        XCTAssertEqual(library.assignments("a").count, 1)
    }

    /// A name taken since keeps the file in Trash — and its entry out.
    func testUndoOfATrashNeverReplacesAFileThatTookItsPlace() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a")
        try await trashFromEvent(library, "a", paths: [file.url.path])
        try Data("someone else's photo".utf8).write(to: file.url)

        library.workspace.undo()
        try await settle(library)
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), "someone else's photo", "nothing was replaced")
        XCTAssertEqual(library.trashedNames(), ["DSC00001.ARW"], "the trashed copy stays")
        XCTAssertTrue(library.assignments("a").isEmpty, "no entry for a file that is not back")
        XCTAssertTrue(library.model.statusMessage.contains("stayed in Trash"), library.model.statusMessage)
        XCTAssertTrue(library.workspace.canUndo, "the step can be tried again")
    }

    // MARK: - One history

    /// The measured bug: a NAS-only move and then a drive move; ⌘Z undid the
    /// older NAS-only move and left the newer drive move standing.
    func testANASOnlyMoveThenADriveMoveUndoesTheNewestFirstAndRedoesInOrder() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        try FileManager.default.createDirectory(at: library.nasRoot, withIntermediateDirectories: true)
        let only = try library.placeOnNASOnly("a", name: "NAS1.ARW", content: photo("nas"))
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        workspace.refreshConnectivity()
        await library.open("a", "b")
        let start = snapshot(library)

        try click(library, [only.url.path], from: "a", to: "b")
        try await settle(library)
        let afterNAS = snapshot(library)
        try click(library, [file.url.path], from: "a", to: "b")
        try await settle(library)
        let afterBoth = snapshot(library)
        XCTAssertEqual(library.assignments("b").count, 2)
        XCTAssertEqual(workspace.undoHistory.undoStack.count, 2)

        workspace.undo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), afterNAS, "the newer drive move went first")
        XCTAssertEqual(library.assignments("b").map(\.relativePath), ["NAS1.ARW"])
        XCTAssertTrue(library.exists(file.url.path))

        workspace.undo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), start, "then the older NAS-only move")
        XCTAssertFalse(workspace.canUndo)

        workspace.redo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), afterNAS, "Redo re-applies the older one first")
        workspace.redo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), afterBoth)
        XCTAssertFalse(workspace.canRedo)
    }

    func testANewActionForgetsTheRedoStackAndTheMenuNamesEachStep() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let one = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let two = try library.place("a", name: "DSC00002.ARW", content: photo("2"))
        await library.open("a", "b")
        XCTAssertNil(workspace.undoMenuTitle)
        XCTAssertNil(workspace.redoMenuTitle)

        try click(library, [one.url.path], from: "a", to: "b")
        try await settle(library)
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Move to Hotel Night (1 file)")
        workspace.undo()
        try await settle(library)
        XCTAssertEqual(workspace.redoMenuTitle, "Redo Move to Hotel Night (1 file)")

        try click(library, [two.url.path], from: "a", to: "b")
        try await settle(library)
        XCTAssertNil(workspace.redoMenuTitle, "the undone move can no longer be redone on top of another")
        workspace.redo()
        XCTAssertEqual(library.model.statusMessage, "Nothing to redo.")
    }

    func testUndoWhileAMoveIsStillQueuedRefusesInsteadOfUndoingSomethingOlder() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let one = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let two = try library.place("a", name: "DSC00002.ARW", content: photo("2"))
        await library.open("a", "b")
        try click(library, [one.url.path], from: "a", to: "b")
        try await settle(library)

        library.model.isStorageBenchmarkRunning = true
        try click(library, [two.url.path], from: "a", to: "b")
        workspace.undo()
        XCTAssertTrue(library.model.statusMessage.contains("still waiting or running"), library.model.statusMessage)
        library.model.isStorageBenchmarkRunning = false
        try await settle(library)
        XCTAssertEqual(library.assignments("b").count, 2, "nothing was undone")
        XCTAssertEqual(workspace.undoHistory.undoStack.count, 2)
    }

    // MARK: - Events

    func testARenameThatMovesFoldersAndTheirNASCopiesIsUndoneAndRedone() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        try putOnNAS(library, file.assignment, in: "a", content: photo("1"))
        await library.open("a")
        try await settle(library)
        let before = snapshot(library)

        workspace.renameEvent(library.id("a"), name: "Beach Weekend", date: AuditLibrary.day.addingTimeInterval(86_400), policy: .buffer, parentEventID: nil)
        try await settle(library)
        let after = snapshot(library)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(library.event("a").name, "Beach Weekend")
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Rename Beach Day")

        workspace.undo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), before, "the folder, the NAS folder, the name and the date all came back")
        XCTAssertEqual(library.event("a").name, "Beach Day")
        XCTAssertEqual(library.event("a").eventDate, AuditLibrary.day)
        XCTAssertEqual(workspace.redoMenuTitle, "Redo Rename Beach Day")

        workspace.redo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), after)
        XCTAssertEqual(library.event("a").name, "Beach Weekend")
    }

    func testReparentingAnEventIsUndoneAndAMoveBeforeItStaysUndoable() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        library.addEvent("trip", name: "Trip 2026")
        library.addEvent("beach", name: "Lakeside", date: AuditLibrary.day.addingTimeInterval(86_400), policy: nil)
        library.addEvent("solo", name: "Solo Day", date: AuditLibrary.day.addingTimeInterval(9 * 86_400))
        let workspace = library.workspace
        let file = try library.place("beach", name: "DSC00001.ARW", content: photo("1"))
        await library.open("trip", "beach", "solo")
        try click(library, [file.url.path], from: "beach", to: "solo")
        try await settle(library)
        let afterMove = snapshot(library)

        let beach = library.event("beach")
        workspace.renameEvent(beach.id, name: beach.name, date: beach.eventDate, policy: beach.storagePolicy, parentEventID: library.id("trip"))
        try await settle(library)
        XCTAssertEqual(library.event("beach").parentEventID, library.id("trip"))
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Move Lakeside")

        workspace.undo()
        try await settle(library)
        XCTAssertNil(library.event("beach").parentEventID)
        XCTAssertEqual(snapshot(library), afterMove)
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Move to Solo Day (1 file)", "the move before it was not abandoned")
    }

    func testCreatingAPolicyChangeAndDeletingAnEventAreUndoable() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        let workspace = library.workspace
        let id = try XCTUnwrap(workspace.createEvent(name: "New Year", date: AuditLibrary.day, policy: nil))
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Create New Year")
        workspace.setPolicy(id, .archiveOnly)
        XCTAssertEqual(workspace.event(id)?.storagePolicy, .archiveOnly)
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Set New Year to Private")

        workspace.undo()
        XCTAssertNil(workspace.event(id)?.storagePolicy)
        workspace.undo()
        XCTAssertNil(workspace.event(id), "the event created here is gone again")
        workspace.redo()
        XCTAssertNotNil(workspace.event(id), "and the same event returns")
        workspace.redo()
        XCTAssertEqual(workspace.event(id)?.storagePolicy, .archiveOnly)

        workspace.deleteEmptyEvent(id)
        XCTAssertNil(workspace.event(id))
        workspace.undo()
        XCTAssertEqual(workspace.event(id)?.storagePolicy, .archiveOnly, "a deleted empty event comes back as it was")
    }

    // MARK: - Configuration

    func testBurstSplitsAndRotationsAreUndoneAndRedone() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        _ = try library.place("a", name: "DSC00001.JPG", content: photo("1"))
        _ = try library.place("a", name: "DSC00002.JPG", content: photo("2"))
        await library.open("a")
        let stacks = try XCTUnwrap(workspace.eventStacks[library.id("a")])
        XCTAssertFalse(stacks.isEmpty)

        workspace.rotateStack(stacks[0], quarterTurnsCW: 1)
        let rotated = library.model.configuration.displayOrientations
        XCTAssertFalse(rotated.isEmpty)
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Rotate 90° Clockwise")
        workspace.undo()
        XCTAssertTrue(library.model.configuration.displayOrientations.isEmpty)
        workspace.redo()
        XCTAssertEqual(library.model.configuration.displayOrientations, rotated)

        workspace.splitItems(stacks[0].items)
        XCTAssertEqual(library.model.configuration.burstSplits.count, 1)
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Split Burst (1 frame)")
        workspace.undo()
        XCTAssertTrue(library.model.configuration.burstSplits.isEmpty)
        workspace.redo()
        XCTAssertEqual(library.model.configuration.burstSplits.count, 1)
    }

    // MARK: - Apply, and changes that live in memory

    /// Apply is one entry: ⌘Z renames the photo back to its card folder,
    /// ⌘⇧Z renames it into the event again — exactly, and never over a file.
    func testAnApplyIsUndoneAndRedone() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        try FileManager.default.createDirectory(at: library.card, withIntermediateDirectories: true)
        let photoFile = library.card.appendingPathComponent("DSC00001.ARW")
        try Data(photo("c").utf8).write(to: photoFile)
        try FileManager.default.setAttributes([.modificationDate: AuditLibrary.day.addingTimeInterval(60)], ofItemAtPath: photoFile.path)
        let location = ConfiguredLocation(role: .importSource, name: "Card", path: library.card.path, deviceID: "sony-a7v")
        library.model.updateConfiguration { $0.configuredLocations.append(location) }
        workspace.scan(location)
        try await library.waitUntil("the card never scanned") { workspace.sources[location.id]?.result != nil }
        let result = try XCTUnwrap(workspace.sources[location.id]?.result)
        workspace.assign(stackIDs: Set(result.stacks.map(\.id)), from: location.id, to: library.id("a"))
        workspace.prepareApply(sourceLocationID: location.id)
        try await library.waitUntil("the plan never appeared") { workspace.pendingApplyPlan != nil }
        workspace.performApply(try XCTUnwrap(workspace.pendingApplyPlan))
        try await library.settle()
        let landed = library.folder("a").appendingPathComponent("DSC00001.ARW")
        XCTAssertTrue(library.exists(landed.path))
        XCTAssertEqual(workspace.undoHistory.undoStack.count, 2, "the sort and the Apply")
        let applied = snapshot(library)

        workspace.undo()
        try await library.settle()
        XCTAssertTrue(library.exists(photoFile.path))
        XCTAssertFalse(library.exists(landed.path))
        workspace.redo()
        try await library.settle()
        XCTAssertEqual(snapshot(library), applied)
        XCTAssertFalse(library.exists(photoFile.path))
    }

    /// Regrouped bursts live in the scanned board, not on disk: their Undo is
    /// a closure, in the history in order but never written to it.
    func testAChangeThatLivesInMemoryUndoesInOrderAndIsNeverPersisted() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        let workspace = library.workspace
        var state = "before"
        workspace.recordUndo("Sort into Beach Day", .files(UndoFilesAction()))
        workspace.recordSessionUndo("Regroup Bursts on Card", undo: { state = "before" }, redo: { state = "after" })
        state = "after"
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Regroup Bursts on Card")

        workspace.undo()
        XCTAssertEqual(state, "before")
        XCTAssertEqual(workspace.redoMenuTitle, "Redo Regroup Bursts on Card")
        workspace.redo()
        XCTAssertEqual(state, "after")

        workspace.flushUndoHistory()
        let stored = try UndoHistoryStore(url: library.root.appendingPathComponent("Support/\(UndoHistoryStore.fileName)")).load()
        XCTAssertEqual(stored.undoStack.map(\.title), ["Sort into Beach Day"], "the closure cannot outlive the run")
    }

    // MARK: - Relaunch

    /// The history is kept in a small SQLite file and by the journals: a
    /// workspace made after a quit still offers the last disk-backed Undo,
    /// and the catalog-only entries below it, in order.
    func testARelaunchedWorkspaceStillOffersTheLastUndoAndItsRedo() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let card = try library.place("a", name: "CARD_1.ARW", content: photo("c"), onDrive: false)
        await library.open("a", "b")
        let start = snapshot(library)

        try click(library, [card.url.path], from: "a", to: "b")
        try await settle(library)
        try click(library, [file.url.path], from: "a", to: "b")
        try await settle(library)
        let moved = snapshot(library)
        XCTAssertEqual(library.workspace.undoHistory.undoStack.count, 2)
        library.workspace.flushUndoHistory()

        // A relaunch: a new workspace over the same support folder.
        let relaunched = EventsWorkspace(
            model: library.model,
            supportFolder: library.root.appendingPathComponent("Support", isDirectory: true),
            driveActivityGate: DriveActivityGate()
        )
        XCTAssertNil(relaunched.undoMenuTitle, "nothing until it reads the file")
        await relaunched.loadUndoHistory()
        XCTAssertEqual(relaunched.undoMenuTitle, "Undo Move to Hotel Night (1 file)")
        XCTAssertEqual(relaunched.undoHistory.undoStack.count, 2, "the catalog-only move too")

        relaunched.undo()
        try await library.waitUntil("the relaunched Undo never finished") { !library.model.isBusy && relaunched.isQuiet }
        XCTAssertTrue(library.exists(file.url.path), "the drive move came back — the newest first")
        relaunched.undo()
        try await library.waitUntil("the second Undo never finished") { !library.model.isBusy && relaunched.isQuiet }
        XCTAssertEqual(snapshot(library), start)
        relaunched.flushUndoHistory()

        // And a third launch offers the Redo the second left.
        let third = EventsWorkspace(
            model: library.model,
            supportFolder: library.root.appendingPathComponent("Support", isDirectory: true),
            driveActivityGate: DriveActivityGate()
        )
        await third.loadUndoHistory()
        XCTAssertEqual(third.redoMenuTitle, "Redo Move to Hotel Night (1 file)".replacingOccurrences(of: "Move", with: "Move"))
        XCTAssertFalse(third.canUndo)
        third.redo()
        try await library.waitUntil("Redo never finished") { !library.model.isBusy && third.isQuiet }
        XCTAssertEqual(library.assignments("b").count, 1)
        _ = moved
    }

    /// A journal an earlier build wrote (no history file yet) is still an Undo.
    func testAJournalNoHistoryEntryKnowsIsOfferedOnLaunch() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a", "b")
        try click(library, [file.url.path], from: "a", to: "b")
        try await settle(library)
        library.workspace.flushUndoHistory()
        try? FileManager.default.removeItem(at: library.root.appendingPathComponent("Support/\(UndoHistoryStore.fileName)"))

        let relaunched = EventsWorkspace(
            model: library.model,
            supportFolder: library.root.appendingPathComponent("Support", isDirectory: true),
            driveActivityGate: DriveActivityGate()
        )
        await relaunched.loadUndoHistory()
        XCTAssertEqual(relaunched.undoMenuTitle, "Undo Move to Hotel Night (1 file)")
    }

    // MARK: - Duplicates

    func testADuplicateResolutionIsUndoneWithItsEntryItsTrashAndItsNASSetAside() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let kept = try library.place("a", name: "DSC00001.ARW", content: photo("same"))
        let dropped = try library.place("b", name: "DSC00001.ARW", content: photo("same"))
        // The dropped copy has a NAS twin at its own mirror path; the kept
        // copy's is there too, so the twin is set aside, not renamed.
        try putOnNAS(library, kept.assignment, in: "a", content: photo("same"))
        let twin = try putOnNAS(library, dropped.assignment, in: "b", content: photo("same"))
        try await settle(library)
        let before = snapshot(library)

        let report = DuplicateScanner(store: nil, readsCaptureDates: false).scan([
            DuplicateCandidate(owner: .event(library.id("a")), path: kept.url.path, assignment: kept.assignment),
            DuplicateCandidate(owner: .event(library.id("b")), path: dropped.url.path, assignment: dropped.assignment),
        ])
        let group = try XCTUnwrap(report.groups.first)
        var finished: DuplicateResolutionOutcome?
        XCTAssertTrue(workspace.resolveDuplicates(
            [DuplicateResolution(group: group, keep: .event(library.id("a")), drop: [.event(library.id("b"))])],
            onFinish: { finished = $0 }
        ))
        try await settle(library)
        XCTAssertEqual(finished?.trashed.count, 1)
        XCTAssertTrue(library.assignments("b").isEmpty)
        XCTAssertEqual(library.trashedNames(), ["DSC00001.ARW"])
        let after = snapshot(library)
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Remove Duplicate Copies (1 copy)")

        workspace.undo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), before, "the copy, its entry, and its NAS twin are all back")
        XCTAssertEqual(library.trashedNames(), [])
        XCTAssertTrue(library.exists(twin.path))

        workspace.redo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), after)
    }

    // MARK: - Faces

    func testFaceChangesAreUndoneThroughTheWorkspace() async throws {
        let library = try AuditLibrary.make(catalogBacked: true)
        defer { library.tearDown() }
        let workspace = library.workspace
        let store = workspace.faceStore
        let group = try store.createPerson(name: "Person 1", isRoster: false)
        let photo = FacePhotoRecord(
            pathKey: EventStorageLocations.pathKey("/tmp/faces/A.ARW"), path: "/tmp/faces/A.ARW", fileName: "A.ARW",
            byteCount: 10, modifiedAt: Date(timeIntervalSince1970: 1_752_000_000)
        )
        var confirmed = FaceRecord(photoID: photo.pathKey, personID: group.id, box: NormalizedFaceBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2), detScore: 0.9, embedding: [Float](repeating: 0.044, count: 512), state: .confirmed, photoPath: photo.path)
        confirmed.crop = Data([1, 2, 3])
        let loose = FaceRecord(photoID: photo.pathKey, personID: group.id, box: NormalizedFaceBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2), detScore: 0.8, embedding: [Float](repeating: 0.044, count: 512), state: .other, photoPath: photo.path)
        try store.replaceFaces(photo: photo, faces: [confirmed, loose])
        try store.refreshFaceCounts()

        workspace.junkGroup(group.id)
        XCTAssertNil(workspace.person(group.id))
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Remove Person 1 (2 faces)")
        let revision = workspace.facesRevision

        workspace.undo()
        XCTAssertGreaterThan(workspace.facesRevision, revision, "the People window re-reads")
        XCTAssertEqual(workspace.person(group.id)?.faceCount, 2)
        let back = workspace.faces(for: group.id)
        XCTAssertEqual(back.first { $0.id == confirmed.id }?.state, .confirmed, "the confirmed label is still confirmed")
        XCTAssertEqual(back.first { $0.id == loose.id }?.crop, nil)
        XCTAssertEqual(back.first { $0.id == confirmed.id }?.crop, Data([1, 2, 3]))

        workspace.redo()
        XCTAssertNil(workspace.person(group.id))
        workspace.undo()

        workspace.mergePerson(group.id, into: try store.createPerson(name: "Dad", isRoster: true).id)
        XCTAssertNil(workspace.person(group.id))
        workspace.undo()
        XCTAssertEqual(workspace.faces(for: group.id).count, 2, "a merge is no longer irreversible")
    }
}
