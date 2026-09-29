import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// The Buffer is usually unplugged and will one day be wiped; the NAS is the
/// permanent library. Undo and Redo must work with only the NAS mounted —
/// acting on the NAS copies and the catalog, journaled, never replacing
/// anything — and must say so and change nothing when the volume they need
/// is not there. "Unplugged" here is the whole drive folder moved aside: its
/// files are exactly as they were and none can be reached.
@MainActor
final class UndoBufferAbsentTests: XCTestCase {
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

    /// The NAS side alone: what is under the library root.
    private func nasFiles(_ library: AuditLibrary) -> [String] {
        library.diskFiles().map(\.path).filter { $0.hasPrefix(library.root.appendingPathComponent("Library").path) }
            .map { $0.replacingOccurrences(of: library.root.path, with: "").lowercased() }.sorted()
    }

    private func settle(_ library: AuditLibrary) async throws {
        try await library.settle()
        if FileManager.default.fileExists(atPath: library.nasRoot.path) {
            try await library.waitUntil(timeout: 30, "the NAS renames never drained") {
                library.workspace.pendingNASRenameCount == 0 && library.workspace.isQuiet
            }
            try await library.settle()
        }
    }

    @discardableResult
    private func putOnNAS(_ library: AuditLibrary, _ assignment: PhotoEventAssignment, in key: String, content: String) throws -> URL {
        try FileManager.default.createDirectory(at: library.nasRoot, withIntermediateDirectories: true)
        let url = try XCTUnwrap(library.locations.archiveURL(for: assignment, event: library.event(key)))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        library.workspace.refreshConnectivity()
        return url
    }

    private var unpluggedName: String { "Drive.unplugged" }

    private func unplug(_ library: AuditLibrary) throws -> URL {
        let away = library.root.appendingPathComponent(unpluggedName)
        try FileManager.default.moveItem(at: library.drive, to: away)
        library.workspace.refreshConnectivity()
        return away
    }

    private func replug(_ library: AuditLibrary, from away: URL) throws {
        try FileManager.default.moveItem(at: away, to: library.drive)
        library.workspace.refreshConnectivity()
    }

    /// Every file under `folder` with its bytes: the proof a step never
    /// touched the unplugged drive.
    private func tree(_ folder: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return found }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            found[String(url.path.dropFirst(folder.path.count))] = try? Data(contentsOf: url)
        }
        return found
    }

    // MARK: - Nothing on the Buffer at all

    /// The Buffer's volume is not there from the start: a photo only the NAS
    /// has moves between events (catalog and NAS rename), and Undo and Redo
    /// act on the NAS copy and the catalog, in order, exactly.
    func testANASOnlyMoveIsUndoneAndRedoneWithNoBufferAtAll() async throws {
        let ghost = "/Volumes/AuditGhost-\(UUID().uuidString)/Camera Buffer"
        let library = try AuditLibrary.make(bufferPath: ghost)
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        try FileManager.default.createDirectory(at: library.nasRoot, withIntermediateDirectories: true)
        let only = try library.placeOnNASOnly("a", name: "NAS1.ARW", content: photo("nas"))
        let other = try library.placeOnNASOnly("a", name: "NAS2.ARW", content: photo("nas2"))
        workspace.refreshConnectivity()
        await library.open("a", "b")
        try await settle(library)
        let start = snapshot(library)
        let census = library.contentCensus()

        try click(library, [only.url.path], from: "a", to: "b")
        try await settle(library)
        let one = snapshot(library)
        XCTAssertEqual(library.assignments("b").map(\.relativePath), ["NAS1.ARW"])
        try click(library, [other.url.path], from: "a", to: "b")
        try await settle(library)
        let two = snapshot(library)
        XCTAssertEqual(workspace.undoHistory.undoStack.count, 2)

        workspace.undo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), one, "the newer NAS-only move went first, with the Buffer gone")
        workspace.undo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), start)
        XCTAssertEqual(library.contentCensus(), census, "no NAS copy was replaced or lost")

        workspace.redo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), one)
        workspace.redo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), two)
        XCTAssertFalse(workspace.canRedo)
    }

    /// Sorts, a split and a rename-free history need no drive at all.
    func testCatalogOnlyStepsNeedNoVolume() async throws {
        let ghost = "/Volumes/AuditGhost-\(UUID().uuidString)/Camera Buffer"
        let library = try AuditLibrary.make(bufferPath: ghost)
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let before = library.model.configuration
        workspace.setPolicy(library.id("a"), .archiveOnly)
        _ = workspace.createEvent(name: "Winter", date: AuditLibrary.day.addingTimeInterval(9 * 86_400), policy: nil)
        workspace.undo()
        workspace.undo()
        XCTAssertEqual(library.model.configuration.savedEvents, before.savedEvents)
        workspace.redo()
        workspace.redo()
        XCTAssertEqual(library.model.configuration.savedEvents.count, 3)
    }

    // MARK: - A move, with the Buffer unplugged afterwards

    /// Undo with the Buffer away: the NAS copy goes back and so does the
    /// catalog entry; the Buffer's copy is not touched. Plugged in again, Redo
    /// brings the NAS and the catalog level with the drive — the exact state
    /// after the move — and Undo then undoes everything, drive included.
    func testUndoWhileTheBufferIsUnpluggedActsOnTheNASAndCatalogAndTheDriveCatchesUpAfterwards() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        let nasBefore = try putOnNAS(library, file.assignment, in: "a", content: photo("1"))
        await library.open("a", "b")
        try await settle(library)
        let start = snapshot(library)

        try click(library, [file.url.path], from: "a", to: "b")
        try await settle(library)
        let moved = snapshot(library)
        let nasAfter = try XCTUnwrap(library.locations.archiveURL(for: library.assignments("b")[0], event: library.event("b")))
        XCTAssertTrue(library.exists(nasAfter.path))
        XCTAssertFalse(library.exists(nasBefore.path))

        let away = try unplug(library)
        let driveBefore = tree(away)
        workspace.undo()
        try await settle(library)
        XCTAssertTrue(library.model.statusMessage.contains("on the NAS and in the catalog only"), library.model.statusMessage)
        XCTAssertTrue(library.exists(nasBefore.path), "the NAS copy is back at the old path")
        XCTAssertFalse(library.exists(nasAfter.path))
        XCTAssertEqual(library.assignments("a").map(\.relativePath), ["DSC00001.ARW"])
        XCTAssertTrue(library.assignments("b").isEmpty)
        XCTAssertEqual(tree(away), driveBefore, "the unplugged drive's files were not touched")
        XCTAssertFalse(workspace.canUndo)
        XCTAssertEqual(workspace.redoMenuTitle, "Redo Move to Hotel Night (1 file)")
        guard case .files(let lagging)? = workspace.undoHistory.nextRedo?.action else { return XCTFail("a files entry") }
        XCTAssertNotNil(lagging.driveLagging, "the drive is one step behind, and the entry knows")

        try replug(library, from: away)
        workspace.redo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), moved, "Redo returns to the exact state after the move: the drive was never out of step")
        guard case .files(let level)? = workspace.undoHistory.nextUndo?.action else { return XCTFail("a files entry") }
        XCTAssertNil(level.driveLagging)

        workspace.undo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), start, "and a normal Undo, with the drive plugged in, returns everything")
    }

    /// The other order: the move is undone with everything plugged in, the
    /// Buffer is unplugged, and Redo acts on the NAS and the catalog alone;
    /// the Undo after that, Buffer back, is level again.
    func testRedoWhileTheBufferIsUnpluggedActsOnTheNASAndCatalogToo() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        try putOnNAS(library, file.assignment, in: "a", content: photo("1"))
        await library.open("a", "b")
        try await settle(library)
        let start = snapshot(library)
        try click(library, [file.url.path], from: "a", to: "b")
        try await settle(library)
        workspace.undo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), start)

        let away = try unplug(library)
        let driveBefore = tree(away)
        workspace.redo()
        try await settle(library)
        XCTAssertEqual(library.assignments("b").map(\.relativePath), ["DSC00001.ARW"], "the catalog followed")
        let nasAfter = try XCTUnwrap(library.locations.archiveURL(for: library.assignments("b")[0], event: library.event("b")))
        XCTAssertTrue(library.exists(nasAfter.path), "and so did the NAS copy")
        XCTAssertEqual(tree(away), driveBefore, "the drive was not touched")

        try replug(library, from: away)
        workspace.undo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), start)
        XCTAssertTrue(library.exists(file.url.path))
    }

    /// A file with no NAS copy that followed the move has nothing to act on
    /// while the Buffer is away: the step says so and changes nothing — the
    /// catalog is not swapped into a place the file is not in.
    func testUndoWhileTheBufferIsUnpluggedRefusesForAFileWithNoNASCopyAndChangesNothing() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        try FileManager.default.createDirectory(at: library.nasRoot, withIntermediateDirectories: true)
        workspace.refreshConnectivity()
        await library.open("a", "b")
        try click(library, [file.url.path], from: "a", to: "b")
        try await settle(library)
        let rows = library.model.configuration.photoEventAssignments

        let away = try unplug(library)
        let driveBefore = tree(away)
        workspace.undo()
        try await settle(library)
        XCTAssertTrue(library.model.statusMessage.contains("no NAS copy"), library.model.statusMessage)
        XCTAssertEqual(library.model.configuration.photoEventAssignments, rows, "the catalog is untouched")
        XCTAssertEqual(tree(away), driveBefore)
        XCTAssertTrue(workspace.canUndo, "the entry stays: undo it once the Buffer is back")

        try replug(library, from: away)
        workspace.undo()
        try await settle(library)
        XCTAssertEqual(library.assignments("a").map(\.relativePath), ["DSC00001.ARW"])
        XCTAssertTrue(library.exists(file.url.path), "with the Buffer back the whole step runs")
    }

    /// Neither the Buffer nor the NAS: there is no copy to act on. The step
    /// says which and changes nothing.
    func testUndoWithNeitherTheBufferNorTheNASRefusesAndChangesNothing() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        await library.open("a", "b")
        try click(library, [file.url.path], from: "a", to: "b")
        try await settle(library)
        let rows = library.model.configuration.photoEventAssignments

        let away = try unplug(library)
        workspace.undo()
        try await settle(library)
        XCTAssertEqual(library.model.configuration.photoEventAssignments, rows)
        XCTAssertTrue(workspace.canUndo)
        XCTAssertTrue(library.model.statusMessage.contains("NAS isn't connected either"), library.model.statusMessage)
        try replug(library, from: away)
    }

    // MARK: - A merge, with the Buffer emptied

    /// The spare copy of a merge is in the Buffer's Trash; the Buffer is
    /// emptied. Undo brings back the entry whose NAS copy went with the merge
    /// and the NAS copy itself; the drive is left alone, and once it is back
    /// Redo and then Undo finish the job exactly.
    func testUndoOfAMergeWhileTheBufferIsAwayActsOnTheNASCopyAndTheDriveCatchesUpAfterwards() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let spare = try library.place("a", name: "DSC00001.ARW", content: photo("same"))
        _ = try library.place("b", name: "DSC00001.ARW", content: photo("same"))
        let nasBefore = try putOnNAS(library, spare.assignment, in: "a", content: photo("same"))
        await library.open("a", "b")
        try await settle(library)
        let start = snapshot(library)

        try click(library, [spare.url.path], from: "a", to: "b")
        try await settle(library)
        let merged = snapshot(library)
        XCTAssertEqual(library.trashedNames(), ["DSC00001.ARW"])
        XCTAssertFalse(library.exists(nasBefore.path), "the NAS copy followed the merge")

        let away = try unplug(library)
        let driveBefore = tree(away)
        workspace.undo()
        try await settle(library)
        XCTAssertTrue(library.exists(nasBefore.path), "the NAS copy is back where it was")
        XCTAssertEqual(library.assignments("a").map(\.relativePath), ["DSC00001.ARW"], "the entry is back: its file is on the NAS")
        XCTAssertEqual(tree(away), driveBefore, "the spare copy stays in the Buffer's Trash, untouched")
        XCTAssertTrue(workspace.canRedo)

        try replug(library, from: away)
        workspace.redo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), merged, "Redo merges again — the spare copy was already in Trash")
        XCTAssertEqual(library.trashedNames(), ["DSC00001.ARW"])

        workspace.undo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), start, "and Undo with the Buffer back restores the spare copy from Trash")
        XCTAssertEqual(library.trashedNames(), [])
    }

    /// A Trash whose drive is not there cannot be restored from, and there is
    /// no NAS copy to stand in for it: Undo says so, keeps the entry, and puts
    /// no entry back for a file that is not anywhere the app can reach.
    func testUndoOfATrashWhoseDriveIsAwayRefusesAndKeepsTheEntry() async throws {
        let ghost = "/Volumes/AuditGhost-\(UUID().uuidString)"
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let dropped = PhotoEventAssignment(
            sourceRootPath: "\(ghost)/Card", relativePath: "DSC00001.ARW", fileSize: 4,
            modifiedAt: AuditLibrary.day, eventID: library.id("a"), deviceID: "sony-a7v"
        )
        let entry = MediaTrashEntry(
            trashedRelativePath: "Card/DSC00001.ARW", originalAbsolutePath: "\(ghost)/Card/DSC00001.ARW",
            eventID: library.id("a"), size: 4, droppedAssignments: [dropped]
        )
        workspace.recordUndo(
            "Move to Trash", detail: "1 file",
            .files(UndoFilesAction(
                removed: [dropped],
                trashed: [UndoTrashedFile(batchFolder: "\(ghost)/.Camera Toolkit/_Trash/2026-08-01_100000", entry: entry)]
            ))
        )
        let before = library.model.configuration.photoEventAssignments

        workspace.undo()
        XCTAssertTrue(library.model.statusMessage.contains("isn't connected"), library.model.statusMessage)
        XCTAssertEqual(library.model.configuration.photoEventAssignments, before, "no entry was put back")
        XCTAssertEqual(workspace.undoMenuTitle, "Undo Move to Trash (1 file)", "the entry is still there")
        XCTAssertFalse(library.model.isBusy)
    }

    /// The Buffer was emptied (mounted, nothing on it): the trashed file is
    /// not in Trash any more, so Undo cannot bring its entry back — and the
    /// entry leaves the history rather than stand in front of older ones.
    func testUndoOfATrashWhoseFilesAreGoneDropsTheEntryWithoutPuttingBackADanglingEntry() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        _ = try library.place("a", name: "DSC00002.ARW", content: photo("2"))
        await library.open("a")
        let stack = try XCTUnwrap(library.stack(at: file.url.path, on: "a"))
        workspace.requestTrash(stackIDs: [stack.id], fromEvent: library.id("a"))
        workspace.confirmTrash(try XCTUnwrap(workspace.pendingTrash))
        try await settle(library)
        XCTAssertEqual(library.trashedNames(), ["DSC00001.ARW"])
        let rows = library.model.configuration.photoEventAssignments

        let away = try unplug(library)
        try FileManager.default.createDirectory(at: library.drive, withIntermediateDirectories: true)
        workspace.undo()
        try await settle(library)
        XCTAssertEqual(library.model.configuration.photoEventAssignments, rows, "no entry for a file that is nowhere")
        XCTAssertTrue(library.model.statusMessage.contains("not in Trash any more"), library.model.statusMessage)
        XCTAssertFalse(workspace.canUndo)
        try? FileManager.default.removeItem(at: library.drive)
        try replug(library, from: away)
    }

    // MARK: - An event rename, with the Buffer unplugged

    /// The event's folder on the Buffer and on the NAS were renamed with it.
    /// Undo with the Buffer away renames the event and its NAS folder back;
    /// the Buffer's folder stays as it is; with the Buffer back Redo and Undo
    /// are exact again.
    func testUndoOfARenameWhileTheBufferIsAwayRenamesTheEventAndItsNASFolderAlone() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        let file = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        try putOnNAS(library, file.assignment, in: "a", content: photo("1"))
        await library.open("a")
        try await settle(library)
        let start = snapshot(library)

        workspace.renameEvent(library.id("a"), name: "Beach Weekend", date: AuditLibrary.day.addingTimeInterval(86_400), policy: .buffer, parentEventID: nil)
        try await settle(library)
        let renamed = snapshot(library)
        XCTAssertNotEqual(renamed, start)

        let away = try unplug(library)
        let driveBefore = tree(away)
        workspace.undo()
        try await settle(library)
        XCTAssertEqual(library.event("a").name, "Beach Day")
        XCTAssertTrue(library.model.statusMessage.contains("renamed alone"), library.model.statusMessage)
        XCTAssertEqual(tree(away), driveBefore, "the Buffer's renamed folder was not touched")
        let nasOld = try XCTUnwrap(library.locations.archiveURL(for: library.assignments("a")[0], event: library.event("a")))
        XCTAssertTrue(library.exists(nasOld.path), "the NAS folder went back with the name")

        try replug(library, from: away)
        workspace.redo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), renamed)
        workspace.undo()
        try await settle(library)
        XCTAssertEqual(snapshot(library), start)
    }

    func testUndoOfARenameWhoseFoldersAreAwayRefusesWhenNothingOnTheNASFollowed() async throws {
        let library = try AuditLibrary.make()
        defer { library.tearDown() }
        twoEvents(library)
        let workspace = library.workspace
        _ = try library.place("a", name: "DSC00001.ARW", content: photo("1"))
        // The NAS is there but holds nothing for the event: no NAS folder was renamed.
        try FileManager.default.createDirectory(at: library.nasRoot, withIntermediateDirectories: true)
        workspace.refreshConnectivity()
        await library.open("a")
        workspace.renameEvent(library.id("a"), name: "Beach Weekend", date: AuditLibrary.day, policy: .buffer, parentEventID: nil)
        try await settle(library)
        XCTAssertEqual(library.event("a").name, "Beach Weekend")

        let away = try unplug(library)
        workspace.undo()
        XCTAssertEqual(library.event("a").name, "Beach Weekend", "nothing changed")
        XCTAssertTrue(library.model.statusMessage.contains("nothing to act on"), library.model.statusMessage)
        XCTAssertTrue(workspace.canUndo)
        try replug(library, from: away)
        workspace.undo()
        try await settle(library)
        XCTAssertEqual(library.event("a").name, "Beach Day")
    }
}
