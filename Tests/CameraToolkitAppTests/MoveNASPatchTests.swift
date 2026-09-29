import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

extension MoveLibrary {
    /// A copy of every assignment's file at its mirror path on the NAS
    /// stand-in, as Sync to NAS would have left them.
    func putEveryFileOnTheNAS() throws {
        let locations = workspace.locations
        var folders = Set<String>()
        for assignment in model.configuration.photoEventAssignments {
            guard let event = workspace.event(assignment.eventID) else { continue }
            let drive = locations.originalsRoot(for: event, deviceID: assignment.deviceID, policy: .buffer).appendingPathComponent(assignment.relativePath).path
            guard let relative = locations.mirrorRelativePath(forDrivePath: drive) else { continue }
            let path = locations.nasRoot.appendingPathComponent(relative).path
            let folder = (path as NSString).deletingLastPathComponent
            if folders.insert(folder).inserted {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data([0x78])))
        }
    }

    /// Unplugs the Buffer: every event's Originals folder goes with it, so
    /// only the NAS copies are left. (Temp folders; nothing real is touched.)
    func unplugTheBuffer() throws {
        try FileManager.default.removeItem(at: URL(fileURLWithPath: model.configuration.bufferPath, isDirectory: true))
    }
}

/// Once a move's NAS renames have run, the NAS column of the moved files is
/// patched from the rename result — no board is re-read (a re-read of a big
/// family is a sweep of the share and a redraw of every tile). That holds
/// when the drive copy moved too, and when the Buffer is away and the NAS
/// copy is the file: then the tiles, the storage rows and the badge index
/// follow the NAS copy to its new path, all from strings — no file of the
/// share is stat'ed on the main actor.
@MainActor
final class MoveNASPatchTests: XCTestCase {
    private func waitUntil(timeout: TimeInterval = 60, _ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func rows(_ workspace: EventsWorkspace, _ id: UUID) -> Set<String> {
        Set((workspace.presence[id]?.assets ?? []).map {
            "\($0.id)|\($0.assignment.eventID)|\($0.source)|\($0.drive)|\($0.otherDrive)|\($0.archive)|\($0.bestLocalPath ?? "-")|\($0.archivePath ?? "-")"
        })
    }

    private func cut(_ workspace: EventsWorkspace, _ id: UUID) -> Set<[String]> {
        Set((workspace.eventStacks[id] ?? []).map { $0.files.map { $0.path.lowercased() }.sorted() })
    }

    private func moveAndCompareWithAFreshRead(bufferAway: Bool) async throws {
        let library = try MoveLibrary.make(.small)
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        try library.putEveryFileOnTheNAS()
        if bufferAway { try library.unplugTheBuffer() }
        workspace.refreshConnectivity()
        try await waitUntil("the NAS to connect") { workspace.nasIsConnected }
        let probe = MovePresenceProbe(nasRoot: workspace.locations.nasRoot.path)
        workspace.presenceProbe = probe.probe
        let open = [library.parentID, library.sourceSubeventID, library.targetSubeventID]
        for id in open { await workspace.refreshEvent(id) }

        let selection = library.bursts(in: library.sourceSubeventID, count: 2)
        XCTAssertEqual(selection.count, 2)
        let files = selection.flatMap(\.files)
        XCTAssertFalse(files.isEmpty)
        XCTAssertTrue(files.allSatisfy { $0.path.hasPrefix(workspace.locations.nasRoot.path) == bufferAway }, "the tiles point at the NAS only when the Buffer is away")
        let readsBefore = workspace.boardReadCount
        let statsBefore = probe.total

        workspace.moveStacks(Set(selection.map(\.id)), fromEvent: library.sourceSubeventID, toEvent: library.targetSubeventID)
        try await waitUntil("the move and its NAS renames") {
            !model.isBusy && workspace.pendingNASRenameCount == 0 && model.jobs.contains { $0.action == .nasRename && $0.state == .done }
        }
        try await Task.sleep(for: .milliseconds(300))

        // No board was re-read, and no file of any board stat'ed.
        XCTAssertEqual(workspace.boardReadCount, readsBefore, "the NAS rename patched the rows instead of re-reading the boards")
        XCTAssertEqual(probe.total, statsBefore)
        XCTAssertTrue(workspace.pendingNASArrivals.isEmpty, "every arrival was consumed")

        // The move's line survives, with the NAS part after it.
        XCTAssertTrue(model.statusMessage.hasPrefix("Moved"), model.statusMessage)
        XCTAssertTrue(model.statusMessage.contains("Renamed \(files.count) cop"), model.statusMessage)
        let nasJob = try XCTUnwrap(model.jobs.first { $0.action == .nasRename })
        XCTAssertTrue(nasJob.note.hasPrefix("Renamed"), "the job's own row keeps its own sentence: \(nasJob.note)")

        // The tiles read the files where they are.
        let target = try XCTUnwrap(workspace.event(library.targetSubeventID))
        let targetFolder = workspace.locations.originalsRoot(for: target, deviceID: "sony-a7v", policy: .buffer)
        for id in [library.targetSubeventID, library.parentID] {
            for stack in workspace.eventStacks[id] ?? [] where selection.contains(where: { $0.id == stack.id }) {
                for file in stack.files {
                    if bufferAway {
                        let relative = try XCTUnwrap(workspace.locations.mirrorRelativePath(forDrivePath: targetFolder.appendingPathComponent(file.name).path))
                        XCTAssertEqual(file.path, workspace.locations.nasRoot.appendingPathComponent(relative).path)
                        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(file.name) is at the path its tile reads")
                        XCTAssertEqual(workspace.assignment(for: file)?.eventID, library.targetSubeventID, "the tile resolves to its new event")
                    } else {
                        XCTAssertEqual(file.path, targetFolder.appendingPathComponent(file.name).standardizedFileURL.path)
                    }
                }
            }
        }

        // What the patched boards say is what a fresh read finds.
        for id in open {
            let patchedRows = rows(workspace, id)
            let patchedCut = cut(workspace, id)
            let patchedCounts = workspace.presence[id]?.counts
            await workspace.refreshEvent(id)
            XCTAssertEqual(patchedRows, rows(workspace, id), "storage rows of \(workspace.event(id)?.name ?? "?")")
            XCTAssertEqual(patchedCut, cut(workspace, id), "board of \(workspace.event(id)?.name ?? "?")")
            XCTAssertEqual(patchedCounts, workspace.presence[id]?.counts, "storage strip of \(workspace.event(id)?.name ?? "?")")
        }
        let onNAS = workspace.presence[library.targetSubeventID]?.assets.filter { row in files.contains { $0.name == (row.assignment.relativePath as NSString).lastPathComponent } }
        XCTAssertEqual(onNAS?.count, files.count)
        XCTAssertTrue(onNAS?.allSatisfy { $0.archive == .present } ?? false, "the moved files are on the NAS at their new place")
    }

    func testTheNASRenameOfAMovedFilePatchesTheRowsInsteadOfReReadingTheBoards() async throws {
        try await moveAndCompareWithAFreshRead(bufferAway: false)
    }

    func testWithTheBufferAwayTheNASCopyMovesAndTilesRowsAndBadgesFollowIt() async throws {
        try await moveAndCompareWithAFreshRead(bufferAway: true)
    }

    /// A rename the move did not queue (an Undo's reverse renames) is not
    /// something the patch can answer: the boards are re-read, as before.
    func testAnUndoOfAMoveStillRereadsTheBoards() async throws {
        let library = try MoveLibrary.make(.small)
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        try library.putEveryFileOnTheNAS()
        workspace.refreshConnectivity()
        try await waitUntil("the NAS to connect") { workspace.nasIsConnected }
        for id in [library.parentID, library.sourceSubeventID, library.targetSubeventID] { await workspace.refreshEvent(id) }
        let selection = library.bursts(in: library.sourceSubeventID, count: 1)
        workspace.moveStacks(Set(selection.map(\.id)), fromEvent: library.sourceSubeventID, toEvent: library.targetSubeventID)
        try await waitUntil("the move and its NAS renames") {
            !model.isBusy && workspace.pendingNASRenameCount == 0 && model.jobs.contains { $0.action == .nasRename && $0.state == .done }
        }
        let reads = workspace.boardReadCount
        workspace.undoLastMove()
        try await waitUntil("the undo") { !model.isBusy && model.statusMessage.hasPrefix("Moved") }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(workspace.boardReadCount, reads)
        for id in [library.parentID, library.sourceSubeventID, library.targetSubeventID] {
            let patched = cut(workspace, id)
            await workspace.refreshEvent(id)
            XCTAssertEqual(patched, cut(workspace, id))
        }
    }
}
