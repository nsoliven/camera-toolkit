import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// The app-side halves of the sync/move safety fixes: what the workspace
/// queues, what it hands the move job, and what the Sync All sheet may offer.
/// The Core halves are in `SyncMoveSafetyTests`; the randomized sweep is
/// `NASChaosHarnessTests`.
@MainActor
final class SyncMoveSafetyAppTests: XCTestCase {
    private func nasLibrary() throws -> AuditLibrary {
        let library = try AuditLibrary.make()
        library.addEvent("a", name: "Trip A")
        library.addEvent("b", name: "Trip B", date: AuditLibrary.day.addingTimeInterval(86_400))
        try FileManager.default.createDirectory(at: library.nasRoot, withIntermediateDirectories: true)
        return library
    }

    private func move(_ library: AuditLibrary, _ names: [String], from: String, to: String) async throws {
        await library.open(from)
        let ids = Set((library.workspace.eventStacks[library.id(from)] ?? []).filter { $0.files.contains { names.contains($0.name) } }.map(\.id))
        library.workspace.moveStacks(ids, fromEvent: library.id(from), toEvent: library.id(to))
        try await library.settle()
        try await library.waitUntil(timeout: 10, "renames never drained") { library.workspace.pendingNASRenameCount == 0 && !library.model.isBusy }
        try await library.settle()
    }

    /// A second rename of an event, before the first one's NAS folder rename
    /// ran, used to queue nothing: the NAS folder then stayed at the first
    /// name for good and a photo only the NAS has could not be found.
    func testASecondRenameBeforeTheFirstNASRenameRanIsQueuedAndBothApply() async throws {
        let library = try nasLibrary()
        defer { library.tearDown() }
        let placed = try library.place("a", name: "DSC00001.ARW", content: "drive-photo-pad-pad-pad")
        let only = try library.placeOnNASOnly("a", name: "DSC00002.ARW", content: "nas-only-photo-pad-pad")
        let mirror = try XCTUnwrap(library.locations.archiveURL(for: placed.assignment, event: library.event("a")))
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: placed.url).write(to: mirror)
        library.workspace.refreshConnectivity()
        try await library.settle()
        let event = library.event("a")
        library.workspace.renameEvent(event.id, name: "Trip A2", date: event.eventDate, policy: event.storagePolicy, parentEventID: nil)
        let renamed = library.event("a")
        library.workspace.renameEvent(renamed.id, name: "Trip A3", date: renamed.eventDate, policy: renamed.storagePolicy, parentEventID: nil)
        try await library.settle()
        try await library.waitUntil(timeout: 10, "renames never drained") { library.workspace.pendingNASRenameCount == 0 && !library.model.isBusy }

        XCTAssertEqual(library.workspace.nasRenameQueue.batches().count, 2, "both renames were queued")
        let now = try XCTUnwrap(library.assignments("a").first { $0.relativePath == "DSC00002.ARW" })
        let expected = try XCTUnwrap(library.locations.archiveURL(for: now, event: library.event("a")))
        XCTAssertEqual(library.event("a").name, "Trip A3")
        XCTAssertTrue(library.exists(expected.path), "the NAS-only photo is where the app looks")
        XCTAssertFalse(library.exists(only.url.path))
        XCTAssertTrue(library.exists(mirror.deletingLastPathComponent().path) == false, "the old folder name is gone from the NAS")
        XCTAssertTrue(library.workspace.nasRenameQueue.pending().isEmpty)
    }

    /// A photo only the NAS has, moved onto a name the NAS already held (a
    /// leftover of the same size the catalog never listed), used to show the
    /// other file under the moved photo's name.
    func testANASOnlyPhotoMovedOntoANameTheNASHoldsMovesInUnderAFreeName() async throws {
        let library = try nasLibrary()
        defer { library.tearDown() }
        try library.place("a", name: "DSC00001.ARW", content: "drive-photo-pad-pad-pad")
        let real = "the-real-photo-7-pad-pad"
        let only = try library.placeOnNASOnly("a", name: "DSC00007.ARW", content: real)
        let target = try XCTUnwrap(library.locations.archiveURL(for: only.assignment, event: library.event("b")))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let leftover = "another-photo-7-pad-pad!"
        XCTAssertEqual(leftover.utf8.count, real.utf8.count)
        try Data(leftover.utf8).write(to: target)
        library.workspace.refreshConnectivity()
        try await library.settle()

        try await move(library, ["DSC00007.ARW"], from: "a", to: "b")

        let entries = library.assignments("b").map(\.relativePath).sorted()
        XCTAssertEqual(entries, ["DSC00007 (2).ARW"], "the entry carries the free name")
        let moved = try XCTUnwrap(library.assignments("b").first)
        let newPath = try XCTUnwrap(library.locations.archiveURL(for: moved, event: library.event("b")))
        XCTAssertEqual(library.data(newPath).map { String(decoding: $0, as: UTF8.self) }, real, "the entry shows the photo it names")
        XCTAssertEqual(library.data(target).map { String(decoding: $0, as: UTF8.self) }, leftover, "the file that was there is untouched")
        XCTAssertFalse(library.exists(only.url.path))
        XCTAssertTrue(library.workspace.nasRenameQueue.pending().isEmpty)
    }

    func testANASOnlyPhotoMovedToAFreeNameStillMovesPlainly() async throws {
        let library = try nasLibrary()
        defer { library.tearDown() }
        try library.place("a", name: "DSC00001.ARW", content: "drive-photo-pad-pad-pad")
        let only = try library.placeOnNASOnly("a", name: "DSC00007.ARW", content: "the-real-photo-7-pad-pad")
        library.workspace.refreshConnectivity()
        try await library.settle()
        try await move(library, ["DSC00007.ARW"], from: "a", to: "b")
        XCTAssertEqual(library.assignments("b").map(\.relativePath), ["DSC00007.ARW"])
        let moved = try XCTUnwrap(library.assignments("b").first)
        XCTAssertTrue(library.exists(try XCTUnwrap(library.locations.archiveURL(for: moved, event: library.event("b"))).path))
        XCTAssertFalse(library.exists(only.url.path))
    }

    /// The Sync All sheet's switch used to be forced on every time the sheet
    /// opened, and it stayed on with the Buffer away, where nothing can be
    /// proven stale.
    func testTheReconcileSwitchKeepsTheOwnersChoiceAndIsUnavailableWhileTheBufferIsAway() async throws {
        let library = try nasLibrary()
        defer { library.tearDown() }
        let workspace = library.workspace
        // No Buffer, no private folder: nothing to prove anything against.
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.locations.bufferRoot.path))
        workspace.requestSyncAllToNAS()
        XCTAssertFalse(workspace.syncAllDriveMounted, "the switch is greyed out with the drive away")
        XCTAssertTrue(workspace.syncAllReconcile, "on by default")
        workspace.syncAllRequest = nil

        workspace.syncAllReconcile = false
        try FileManager.default.createDirectory(at: library.locations.bufferRoot, withIntermediateDirectories: true)
        workspace.requestSyncAllToNAS()
        XCTAssertTrue(workspace.syncAllDriveMounted)
        XCTAssertFalse(workspace.syncAllReconcile, "opening the sheet no longer forces the switch back on")
        workspace.syncAllRequest = nil

        try FileManager.default.removeItem(at: library.locations.bufferRoot)
        workspace.requestSyncAllToNAS()
        XCTAssertFalse(workspace.syncAllDriveMounted)
        XCTAssertFalse(workspace.syncAllReconcile, "and the owner's choice survives the drive going away")
    }
}
