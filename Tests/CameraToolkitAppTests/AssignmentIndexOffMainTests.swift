import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// The assignment lookups built on a background task at launch: the same
/// answer as the synchronous build, landed all at once, never overwriting
/// a catalog that changed meanwhile.
@MainActor
final class AssignmentIndexOffMainTests: XCTestCase {
    private func library() throws -> MoveLibrary {
        try MoveLibrary.make(.small)
    }

    private func secondWorkspace(_ library: MoveLibrary) -> EventsWorkspace {
        EventsWorkspace(
            model: library.model,
            supportFolder: library.root.appendingPathComponent("Support2", isDirectory: true),
            driveActivityGate: DriveActivityGate()
        )
    }

    /// Holds the background build at its start until released.
    private final class Parked: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var offMain: [Bool] = []
        var ranOffMain: [Bool] { lock.withLock { offMain } }
        func hook() {
            let off = !Thread.isMainThread
            lock.withLock { offMain.append(off) }
            release.wait()
        }
        func open(_ times: Int = 1) { for _ in 0..<times { release.signal() } }
    }

    private func settle(_ workspace: EventsWorkspace) async throws {
        for _ in 0..<1_000 where !workspace.assignmentIndexIsCurrent {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(workspace.assignmentIndexIsCurrent)
    }

    func testTheBackgroundBuildMatchesTheSynchronousOne() async throws {
        let library = try library()
        defer { library.tearDown() }
        let synchronous = secondWorkspace(library)
        synchronous.refreshIndexIfNeeded()

        let parked = Parked()
        parked.open()
        library.workspace.assignmentIndexBuildHook = parked.hook
        library.workspace.buildAssignmentIndexOffMain()
        try await settle(library.workspace)

        XCTAssertEqual(parked.ranOffMain, [true], "built off the main thread")
        XCTAssertFalse(synchronous.assignmentsByPathKey.isEmpty)
        XCTAssertEqual(library.workspace.assignmentsByPathKey, synchronous.assignmentsByPathKey)
        XCTAssertEqual(library.workspace.assignmentCount(for: library.parentID), library.shape.family)
        XCTAssertEqual(library.workspace.assignmentBytes(for: library.cityID), synchronous.assignmentBytes(for: library.cityID))
    }

    func testCountsAreRightWhileThePathKeysAreStillBuilding() async throws {
        let library = try library()
        defer { library.tearDown() }
        let parked = Parked()
        library.workspace.assignmentIndexBuildHook = parked.hook
        library.workspace.buildAssignmentIndexOffMain()

        // "Is this event empty?" guards Delete Empty Event: never a guess.
        XCTAssertEqual(library.workspace.assignmentCount(for: library.parentID), library.shape.family)
        XCTAssertGreaterThan(library.workspace.assignmentBytes(for: library.parentID), 0)
        XCTAssertTrue(library.workspace.assignmentsByPathKey.isEmpty, "the build is parked, nothing half-landed")

        parked.open()
        try await settle(library.workspace)
        XCTAssertFalse(library.workspace.assignmentsByPathKey.isEmpty)
    }

    func testATileAsksWithoutBlockingAndARealActionDoesNotWait() async throws {
        let library = try library()
        defer { library.tearDown() }
        let parked = Parked()
        library.workspace.assignmentIndexBuildHook = parked.hook
        library.workspace.buildAssignmentIndexOffMain()

        let assignment = try XCTUnwrap(library.model.configuration.photoEventAssignments.first)
        let path = (assignment.sourceRootPath as NSString).appendingPathComponent(assignment.relativePath)
        let file = OrganizeFile(literalPath: path, size: assignment.fileSize, modifiedAt: assignment.modifiedAt)
        XCTAssertNil(library.workspace.tileAssignment(for: file), "a tile draws around the build")
        XCTAssertNotNil(library.workspace.assignment(for: file), "an action gets the true answer at once, built on the spot")
        XCTAssertTrue(library.workspace.assignmentIndexIsCurrent)

        parked.open()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(library.workspace.tileAssignment(for: file))
    }

    func testABuildOfACatalogThatChangedIsThrownAwayAndRedone() async throws {
        let library = try library()
        defer { library.tearDown() }
        let parked = Parked()
        library.workspace.assignmentIndexBuildHook = parked.hook
        library.workspace.buildAssignmentIndexOffMain()

        let added = PhotoEventAssignment(
            sourceRootPath: library.root.appendingPathComponent("Card").path,
            relativePath: "ADDED.ARW",
            fileSize: 7,
            modifiedAt: Date(timeIntervalSince1970: 1_780_000_000),
            eventID: library.cityID,
            deviceID: "sony-a7v"
        )
        library.model.updateConfiguration { $0.photoEventAssignments.append(added) }
        parked.open(2)
        try await settle(library.workspace)

        let keys = library.workspace.assignmentsByPathKey.values
        XCTAssertTrue(keys.contains(added), "the landed lookups describe the catalog as it is now")
    }

    func testTheFirstScreenDoesNotWaitForTheLookupsButTheBuildHonoursSplits() async throws {
        let library = try library()
        defer { library.tearDown() }
        let workspace = library.workspace
        // Some split exists, so the stacking context needs the lookups.
        library.model.updateConfiguration {
            $0.burstSplits = [BurstSplit(memberPathKeys: ["/nowhere/a.arw", "/nowhere/b.arw"])]
        }
        let parked = Parked()
        workspace.assignmentIndexBuildHook = parked.hook
        workspace.buildAssignmentIndexOffMain()
        workspace.wholeBoardFirstScreenLimit = 0

        let refresh = Task { await workspace.refreshEvent(library.cityID) }
        for _ in 0..<2_000 where workspace.eventStacks[library.cityID]?.isEmpty != false {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(workspace.eventStacks[library.cityID]?.isEmpty ?? true, "first screen drew with the lookups still parked")
        XCTAssertFalse(workspace.assignmentIndexIsCurrent)

        parked.open()
        await refresh.value
        XCTAssertTrue(workspace.assignmentIndexIsCurrent)
    }
}
