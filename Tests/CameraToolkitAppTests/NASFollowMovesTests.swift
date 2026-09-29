import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// Move to Event on the board: the NAS copies follow — queued while the NAS
/// is away, applied by a NAS Rename job once it is back, reversed by Undo.
/// Temp folders stand in for the Buffer and the NAS; nothing real is touched.
@MainActor
final class NASFollowMovesTests: XCTestCase {
    private func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// The NAS copy of a drive path, as Sync to NAS would have made it.
    private func nasPath(_ library: MoveLibrary, drivePath: String) throws -> String {
        let relative = try XCTUnwrap(library.workspace.locations.mirrorRelativePath(forDrivePath: drivePath))
        return library.workspace.locations.nasRoot.appendingPathComponent(relative).path
    }

    private func putOnNAS(_ library: MoveLibrary, _ files: [OrganizeFile]) throws {
        for file in files {
            let path = try nasPath(library, drivePath: file.path)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data([0x78]).write(to: URL(fileURLWithPath: path))
        }
    }

    func testMoveQueuesNASRenamesWhileTheNASIsAwayThenAppliesThemOnMountAndUndoReversesThem() async throws {
        let library = try MoveLibrary.make(.small)
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        for id in [library.parentID, library.islandID, library.harborID] { await workspace.refreshEvent(id) }
        let selection = library.bursts(in: library.islandID, count: 2)
        let files = selection.flatMap(\.files)
        XCTAssertFalse(files.isEmpty)
        let oldNAS = try files.map { try nasPath(library, drivePath: $0.path) }

        // The NAS is not mounted: the move runs, the renames are journaled.
        XCTAssertFalse(exists(workspace.locations.nasRoot.path))
        workspace.moveStacks(Set(selection.map(\.id)), fromEvent: library.islandID, toEvent: library.harborID)
        try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle != nil }
        XCTAssertTrue(model.statusMessage.contains("will be renamed when the NAS is connected"), model.statusMessage)
        XCTAssertEqual(workspace.pendingNASRenameCount, files.count)
        let queued = workspace.nasRenameQueue.pending()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued[0].ops.count, files.count)
        XCTAssertEqual(queued[0].origin, .move)
        let journal = try XCTUnwrap(DriveMoveService.latestUndoableJournal(in: workspace.journalFolder))
        XCTAssertEqual(queued[0].moveJournalID, journal.journal.id, "the batch is tied to the move's journal, so Undo finds it")

        // The share mounts (its copies still at the old paths) and the
        // queue is applied by a NAS Rename job.
        try putOnNAS(library, files)
        XCTAssertTrue(oldNAS.allSatisfy(exists))
        workspace.refreshConnectivity()
        try await waitUntil { !model.isBusy && workspace.pendingNASRenameCount == 0 && model.jobs.contains { $0.action == .nasRename && $0.state == .done } }
        XCTAssertTrue(model.statusMessage.hasPrefix("Renamed \(files.count) copies on the NAS"), model.statusMessage)
        XCTAssertTrue(oldNAS.allSatisfy { !exists($0) })
        for file in files {
            XCTAssertTrue(exists(try nasPath(library, drivePath: workspace.locations.originalsRoot(for: workspace.event(library.harborID)!, deviceID: "sony-a7v", policy: .buffer).appendingPathComponent(file.name).path)))
        }
        XCTAssertTrue(workspace.nasRenameQueue.pending().isEmpty)

        // Undo moves the files back on the drive and the NAS copies back too.
        workspace.undoLastMove()
        try await waitUntil { !model.isBusy && model.statusMessage.hasPrefix("Moved") }
        XCTAssertTrue(model.statusMessage.contains("Renamed \(files.count) NAS copies back."), model.statusMessage)
        XCTAssertTrue(oldNAS.allSatisfy(exists))
        XCTAssertTrue(files.allSatisfy { exists($0.path) })
    }
}
