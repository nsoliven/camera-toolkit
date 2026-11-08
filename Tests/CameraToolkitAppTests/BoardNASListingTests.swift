import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// The NAS chip on a board: one listing of the family's NAS folder answers
/// it, a listing that fails says "unknown", and the chips do not wait for
/// the burst Vision pass.
@MainActor
final class BoardNASListingTests: XCTestCase {
    private final class ListingCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var folderSets: [[String]] = []
        var calls: [[String]] { lock.withLock { folderSets } }
        func note(_ folders: [String]) { lock.withLock { folderSets.append(folders) } }
    }

    private func makeLibrary() throws -> MoveLibrary {
        let library = try MoveLibrary.make(.small)
        try FileManager.default.createDirectory(at: library.workspace.locations.nasRoot, withIntermediateDirectories: true)
        return library
    }

    func testOneListingOfTheFamilysFolderAnswersTheNASPlace() async throws {
        let library = try makeLibrary()
        defer { library.tearDown() }
        try library.populateNASMirror()
        let counter = ListingCounter()
        library.workspace.presenceArchiveLister = { root, folders, isCancelled in
            counter.note(folders)
            return try EventArchiveListing.smbLister(root, folders, isCancelled)
        }

        await library.workspace.refreshEvent(library.parentID)

        XCTAssertEqual(counter.calls.count, 1, "one listing for the whole family")
        XCTAssertEqual(counter.calls.first?.count, 1, "the parent's folder holds its subevents")
        let summary = try XCTUnwrap(library.workspace.presence[library.parentID])
        XCTAssertEqual(summary.total, library.shape.family)
        XCTAssertEqual(summary.onArchive, library.shape.family)
        XCTAssertEqual(summary.counts.archiveUnknown, 0)
        XCTAssertEqual(summary.verifiedOnArchive, 0, "listed is not verified")
        XCTAssertEqual(summary.removableFromDrive, 0, "Take Off Drive needs a sync record")
    }

    func testAFailedListingLeavesTheChipUnknownAndTheBoardWhole() async throws {
        let library = try makeLibrary()
        defer { library.tearDown() }
        library.workspace.presenceArchiveLister = { _, _, _ in throw ToolkitError.commandFailed("no answer") }

        await library.workspace.refreshEvent(library.parentID)

        let summary = try XCTUnwrap(library.workspace.presence[library.parentID])
        XCTAssertEqual(summary.counts.archiveUnknown, library.shape.family)
        XCTAssertEqual(summary.onArchive, 0)
        XCTAssertFalse(summary.archiveOffline, "connected, just not answering")
        XCTAssertEqual(summary.onDrive, library.shape.family, "the drive place is answered as before")
        XCTAssertEqual(library.workspace.eventStacks[library.parentID]?.flatMap(\.files).count, library.shape.family)
    }

    func testAStalledListingTimesOutToUnknown() async throws {
        let library = try makeLibrary()
        defer { library.tearDown() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        library.workspace.presenceArchiveListingTimeout = 0.2
        library.workspace.presenceArchiveLister = { _, _, _ in
            _ = release.wait(timeout: .now() + 30)
            throw CancellationError()
        }

        await library.workspace.refreshEvent(library.cityID)

        let summary = try XCTUnwrap(library.workspace.presence[library.cityID])
        XCTAssertEqual(summary.counts.archiveUnknown, library.shape.city)
    }

    func testAFreshListingThatCoversTheFamilySavesTheFolderRead() async throws {
        let library = try makeLibrary()
        defer { library.tearDown() }
        let counter = ListingCounter()
        library.workspace.presenceArchiveLister = { root, folders, isCancelled in
            counter.note(folders)
            return try EventArchiveListing.smbLister(root, folders, isCancelled)
        }
        await library.workspace.refreshEvent(library.cityID)
        XCTAssertEqual(counter.calls.count, 1)
    }

    func testTheChipsLandBeforeTheBurstVisionPass() async throws {
        let library = try makeLibrary()
        defer { library.tearDown() }
        let workspace = library.workspace
        let eventID = library.cityID
        let seen = Flag()
        workspace.beforeBurstVisionPass = {
            let chips = await MainActor.run { workspace.presence[eventID] != nil }
            seen.set(chips)
        }

        await workspace.refreshEvent(eventID)

        XCTAssertEqual(seen.value, true, "presence is published before Vision starts")
    }

    func testAMoveOfANASOnlyFileIsRefusedWhileTheNASIsUnknown() async throws {
        let library = try makeLibrary()
        defer { library.tearDown() }
        let workspace = library.workspace
        let eventID = library.roadID
        // The drive copies gone: the only copies would be on the NAS.
        let event = try XCTUnwrap(workspace.event(eventID))
        let originals = workspace.locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
        try FileManager.default.removeItem(at: originals)
        workspace.presenceArchiveLister = { _, _, _ in throw ToolkitError.commandFailed("no answer") }
        await workspace.refreshEvent(eventID)
        let before = library.model.configuration.photoEventAssignments.filter { $0.eventID == eventID }.count

        let stacks = Set((workspace.eventStacks[eventID] ?? []).map(\.id))
        XCTAssertFalse(stacks.isEmpty, "unknown files stay on the board")
        workspace.moveStacks(stacks, fromEvent: eventID, toEvent: library.beachID)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(library.model.configuration.photoEventAssignments.filter { $0.eventID == eventID }.count, before, "the catalog did not move without the NAS copy")
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        var value: Bool? { lock.withLock { stored } }
        func set(_ value: Bool) { lock.withLock { stored = value } }
    }
}
