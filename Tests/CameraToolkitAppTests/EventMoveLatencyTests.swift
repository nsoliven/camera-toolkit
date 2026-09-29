import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// Move to Event must feel instant: the tiles change boards on the click,
/// the rename and catalog write run behind them, and nothing afterwards
/// re-reads a whole event family — least of all the NAS.
@MainActor
final class EventMoveLatencyTests: XCTestCase {
    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for the move") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func open(_ library: MoveLibrary, _ ids: UUID...) async {
        for id in ids { await library.workspace.refreshEvent(id) }
    }

    private func assignments(_ library: MoveLibrary, in eventID: UUID) -> [PhotoEventAssignment] {
        library.model.configuration.photoEventAssignments.filter { $0.eventID == eventID }
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    // MARK: - The budget, at the size the app is really used at

    /// 17,000 assignments, a 15,610-file family, 15 bursts moved between
    /// two subevents. Before: 1.2 s and 0.3 s main-actor stalls after the
    /// rename (a whole-board restack and a whole-family re-sweep) and ~15,000
    /// NAS stats. The budgets are several times what a slow CI machine
    /// measures on the new path, and an order of magnitude under the old one.
    func testFifteenBurstMoveStaysInsideTheMainActorBudgetAndNeverTouchesTheNAS() async throws {
        let library = try MoveLibrary.make()
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        // Every NAS stat would cost an SMB round trip; none may happen.
        let probe = MovePresenceProbe(nasRoot: workspace.locations.nasRoot.path)
        workspace.presenceProbe = probe.probe
        await open(library, library.parentID, library.islandID, library.harborID)
        probe.nasDelayMicroseconds = 2_000

        let selection = library.bursts(in: library.islandID, count: 15)
        XCTAssertEqual(selection.count, 15)
        let files = selection.flatMap(\.files)
        let parentBefore = try XCTUnwrap(workspace.eventStacks[library.parentID]).count
        let islandBefore = try XCTUnwrap(workspace.eventStacks[library.islandID]).count
        let harborBefore = try XCTUnwrap(workspace.eventStacks[library.harborID]).count
        let nasStatsBefore = probe.nasStats

        let monitor = MainStallMonitor()
        monitor.start()
        try await Task.sleep(for: .milliseconds(50))
        let clicked = ContinuousClock.now
        workspace.moveStacks(Set(selection.map(\.id)), fromEvent: library.islandID, toEvent: library.harborID)
        let click = seconds(since: clicked)

        // The click's own answer: tiles already on their new board.
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(workspace.eventStacks[library.islandID]?.count, islandBefore - 15)
        XCTAssertEqual(workspace.eventStacks[library.harborID]?.count, harborBefore + 15)
        XCTAssertEqual(workspace.eventStacks[library.parentID]?.count, parentBefore, "the parent's board holds both subevents")

        try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle != nil }
        // Let anything the completion queued run before reading the stalls.
        try await Task.sleep(for: .milliseconds(600))
        let stalls = monitor.stop()
        let longest = stalls.first?.duration ?? 0
        print("BENCH budget: click \(Int(click * 1000)) ms, longest main-actor stall \(Int(longest * 1000)) ms, stalls>=8ms \(stalls.count), NAS stats \(probe.nasStats - nasStatsBefore)")

        XCTAssertLessThan(click, 0.040, "planning and moving the tiles is the only work before the click returns")
        XCTAssertLessThan(longest, 0.250, "no whole-board restack or family sweep on the main actor")
        XCTAssertEqual(probe.nasStats, nasStatsBefore, "a Buffer rename must not stat a single NAS file")

        // The result is right on disk, in the catalog, and on the boards.
        let harborAssignments = assignments(library, in: library.harborID)
        XCTAssertEqual(harborAssignments.count, library.shape.harbor + files.count)
        XCTAssertEqual(assignments(library, in: library.islandID).count, library.shape.island - files.count)
        XCTAssertEqual(model.configuration.photoEventAssignments.count, library.shape.total)
        XCTAssertEqual(workspace.eventStacks[library.islandID]?.count, islandBefore - 15)
        XCTAssertEqual(workspace.eventStacks[library.harborID]?.count, harborBefore + 15)
        XCTAssertEqual(workspace.eventStacks[library.parentID]?.count, parentBefore)
        XCTAssertEqual(workspace.assignmentCount(for: library.parentID), library.shape.family)
        XCTAssertEqual(workspace.assignmentCount(for: library.harborID), library.shape.harbor + files.count)
        let harbor = try XCTUnwrap(workspace.event(library.harborID))
        let harborFolder = workspace.locations.originalsRoot(for: harbor, deviceID: "sony-a7v", policy: .buffer)
        for file in files {
            XCTAssertFalse(exists(file.path), "\(file.name) left its old folder")
            XCTAssertTrue(exists(harborFolder.appendingPathComponent(file.name).path), "\(file.name) is in Harbor's folder")
        }
        // The tiles on every board now read the files where they are.
        for stack in try XCTUnwrap(workspace.eventStacks[library.harborID]) where selection.contains(where: { $0.id == stack.id }) {
            XCTAssertTrue(stack.files.allSatisfy { exists($0.path) && $0.path.hasPrefix(harborFolder.path) })
        }
    }

    // MARK: - Optimistic tiles

    func testTilesChangeBoardsOnTheClickWhileTheCatalogWaitsForTheRename() async throws {
        let library = try MoveLibrary.make(.small)
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        await open(library, library.parentID, library.islandID, library.harborID)
        let selection = library.bursts(in: library.islandID, count: 3)
        let fileCount = selection.flatMap(\.files).count
        let islandCount = workspace.assignmentCount(for: library.islandID)
        let harborCount = workspace.assignmentCount(for: library.harborID)
        let islandStacks = try XCTUnwrap(workspace.eventStacks[library.islandID]).count
        let harborStacks = try XCTUnwrap(workspace.eventStacks[library.harborID]).count

        workspace.moveStacks(Set(selection.map(\.id)), fromEvent: library.islandID, toEvent: library.harborID)

        XCTAssertEqual(workspace.eventStacks[library.islandID]?.count, islandStacks - 3)
        XCTAssertEqual(workspace.eventStacks[library.harborID]?.count, harborStacks + 3)
        XCTAssertEqual(workspace.assignmentCount(for: library.islandID), islandCount - fileCount)
        XCTAssertEqual(workspace.assignmentCount(for: library.harborID), harborCount + fileCount)
        // The catalog is untouched until the rename lands — a crash now
        // must not leave an assignment pointing at a folder the file is not in.
        XCTAssertEqual(assignments(library, in: library.islandID).count, library.shape.island)
        XCTAssertTrue(selection.flatMap(\.files).allSatisfy { exists($0.path) })
        // The color dot on the parent's board already names the new home.
        let onParent = try XCTUnwrap(workspace.eventStacks[library.parentID]?.first { $0.id == selection[0].id })
        XCTAssertEqual(workspace.assignedEvent(for: onParent).event?.id, library.harborID)
        XCTAssertTrue(model.statusMessage.hasPrefix("Moving"), model.statusMessage)

        try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle != nil }
        XCTAssertEqual(assignments(library, in: library.islandID).count, library.shape.island - fileCount)
        XCTAssertEqual(assignments(library, in: library.harborID).count, library.shape.harbor + fileCount)
        XCTAssertEqual(workspace.assignmentCount(for: library.islandID), islandCount - fileCount)
        XCTAssertEqual(workspace.assignmentCount(for: library.harborID), harborCount + fileCount)
        XCTAssertEqual(workspace.assignedEvent(for: try XCTUnwrap(workspace.eventStacks[library.parentID]?.first { $0.id == selection[0].id })).event?.id, library.harborID)
        XCTAssertEqual(model.statusMessage.hasPrefix("Moved"), true, model.statusMessage)
    }

    func testFailedRenameRollsTheTilesBackWithAMessageAndChangesNothing() async throws {
        let library = try MoveLibrary.make(.small)
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        await open(library, library.parentID, library.islandID, library.harborID)
        // The journal is written before any rename; a file where its folder
        // should be makes the whole job fail before a file is touched.
        let support = workspace.journalFolder.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: workspace.journalFolder)

        let selection = library.bursts(in: library.islandID, count: 2)
        let fileCount = selection.flatMap(\.files).count
        let islandCount = workspace.assignmentCount(for: library.islandID)
        let islandStacks = try XCTUnwrap(workspace.eventStacks[library.islandID]).map(\.id)
        let harborStacks = try XCTUnwrap(workspace.eventStacks[library.harborID]).map(\.id)
        let parentBefore = try XCTUnwrap(workspace.eventStacks[library.parentID]).count

        workspace.moveStacks(Set(selection.map(\.id)), fromEvent: library.islandID, toEvent: library.harborID)
        XCTAssertEqual(workspace.eventStacks[library.islandID]?.count, islandStacks.count - 2, "optimistic first")

        try await waitUntil { !model.isBusy && model.statusMessage.contains("did not happen") }
        XCTAssertTrue(model.statusMessage.contains("went back to Trip 2026 / Island"), model.statusMessage)
        XCTAssertTrue(model.statusMessage.contains("The catalog was not changed"), model.statusMessage)
        // Back on the source board, gone from the target, counts restored.
        XCTAssertEqual(Set(try XCTUnwrap(workspace.eventStacks[library.islandID]).map(\.id)), Set(islandStacks))
        XCTAssertEqual(Set(try XCTUnwrap(workspace.eventStacks[library.harborID]).map(\.id)), Set(harborStacks))
        XCTAssertEqual(workspace.eventStacks[library.parentID]?.count, parentBefore)
        XCTAssertEqual(workspace.assignmentCount(for: library.islandID), islandCount)
        XCTAssertEqual(assignments(library, in: library.islandID).count, library.shape.island)
        XCTAssertEqual(workspace.assignedEvent(for: try XCTUnwrap(workspace.eventStacks[library.parentID]?.first { $0.id == selection[0].id })).event?.id, library.islandID)
        XCTAssertTrue(selection.flatMap(\.files).allSatisfy { exists($0.path) })
        XCTAssertEqual(fileCount, selection.flatMap(\.files).count)
        XCTAssertNil(workspace.latestMoveJournalTitle)
    }

    // MARK: - The job gate

    func testMoveClickedDuringAnotherJobQueuesAtOnceAndRunsWhenItFinishes() async throws {
        let library = try MoveLibrary.make(.small)
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        await open(library, library.parentID, library.islandID, library.harborID)
        let gate = DispatchSemaphore(value: 0)
        model.runBackgroundJob(
            action: .verifyManifest,
            runningNote: "Verifying the manifest",
            logTitle: "Verify",
            logDetail: "",
            operation: { _ in
                _ = gate.wait(timeout: .now() + 20)
                return 0
            },
            completion: { _ in "Verified." }
        )
        XCTAssertTrue(model.isBusy)

        let selection = library.bursts(in: library.islandID, count: 2)
        let ids = Set(selection.map(\.id))
        let islandStacks = try XCTUnwrap(workspace.eventStacks[library.islandID]).count
        workspace.moveStacks(ids, fromEvent: library.islandID, toEvent: library.harborID)

        // Said right away: what it waits behind — and the tiles are already there.
        XCTAssertTrue(model.statusMessage.contains("queued behind “Verifying the manifest”"), model.statusMessage)
        XCTAssertEqual(workspace.eventStacks[library.islandID]?.count, islandStacks - 2)
        XCTAssertTrue(selection.flatMap(\.files).allSatisfy { exists($0.path) }, "nothing is renamed while the other job holds the gate")
        XCTAssertEqual(assignments(library, in: library.islandID).count, library.shape.island)
        // The same tiles, still on the parent's board, cannot be moved twice.
        workspace.moveStacks(ids, fromEvent: library.parentID, toEvent: library.roadID)
        XCTAssertTrue(model.statusMessage.contains("already moving"), model.statusMessage)

        gate.signal()
        try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle == "Move to Trip 2026 / Harbor" }
        XCTAssertFalse(selection.flatMap(\.files).contains { exists($0.path) })
        XCTAssertEqual(assignments(library, in: library.harborID).count, library.shape.harbor + selection.flatMap(\.files).count)
        XCTAssertTrue(model.statusMessage.hasPrefix("Moved"), model.statusMessage)
    }

    // MARK: - No re-sweep: presence, NAS, counts

    func testMovePatchesPresenceFromTheReportAndNeverStatsTheNAS() async throws {
        let library = try MoveLibrary.make(.small)
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        let probe = MovePresenceProbe(nasRoot: workspace.locations.nasRoot.path, nasDelayMicroseconds: 1_000)
        workspace.presenceProbe = probe.probe
        await open(library, library.parentID, library.islandID, library.harborID, library.roadID)
        XCTAssertGreaterThan(probe.nasStats, 0, "opening a board sweeps the NAS place")
        let statsAfterOpening = probe.total

        let selection = library.bursts(in: library.islandID, count: 3)
        let moved = selection.flatMap(\.files).count
        let before = (
            island: try XCTUnwrap(workspace.presence[library.islandID]).total,
            harbor: try XCTUnwrap(workspace.presence[library.harborID]).total,
            parent: try XCTUnwrap(workspace.presence[library.parentID]).total,
            road: try XCTUnwrap(workspace.presence[library.roadID]).total
        )
        workspace.moveStacks(Set(selection.map(\.id)), fromEvent: library.islandID, toEvent: library.harborID)
        try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle != nil }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(probe.total, statsAfterOpening, "no file of any place was stat'ed after the rename")
        XCTAssertEqual(workspace.presence[library.islandID]?.total, before.island - moved)
        XCTAssertEqual(workspace.presence[library.harborID]?.total, before.harbor + moved)
        XCTAssertEqual(workspace.presence[library.parentID]?.total, before.parent)
        XCTAssertEqual(workspace.presence[library.roadID]?.total, before.road)
        let harborSummary = try XCTUnwrap(workspace.presence[library.harborID])
        let movedAssets = harborSummary.assets.filter { asset in selection.flatMap(\.files).contains { $0.name == (asset.assignment.relativePath as NSString).lastPathComponent } }
        XCTAssertEqual(movedAssets.count, moved)
        // On the drive at the new place; not on the NAS at the new mirror path.
        XCTAssertTrue(movedAssets.allSatisfy { $0.drive == .present && $0.archive == .missing && $0.archiveVerifiedAt == nil })
        XCTAssertTrue(movedAssets.allSatisfy { $0.assignment.eventID == library.harborID })

        // The patch says what a fresh sweep says.
        let patched = Dictionary(uniqueKeysWithValues: harborSummary.assets.map { ($0.id, [$0.drivePath, $0.archivePath, "\($0.drive)", "\($0.archive)", "\($0.source)"]) })
        await workspace.refreshEvent(library.harborID)
        let swept = try XCTUnwrap(workspace.presence[library.harborID])
        XCTAssertEqual(swept.total, harborSummary.total)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: swept.assets.map { ($0.id, [$0.drivePath, $0.archivePath, "\($0.drive)", "\($0.archive)", "\($0.source)"]) }),
            patched
        )
    }

    /// The incremental index patch must answer exactly like a rebuild.
    func testAssignmentIndexAfterAMoveMatchesAFreshRebuild() async throws {
        let library = try MoveLibrary.make(.small)
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        await open(library, library.parentID, library.islandID, library.harborID)
        let selection = library.bursts(in: library.islandID, count: 3)
        workspace.moveStacks(Set(selection.map(\.id)), fromEvent: library.islandID, toEvent: library.harborID)
        try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle != nil }

        let fresh = EventsWorkspace(model: model, supportFolder: library.root.appendingPathComponent("Fresh"), driveActivityGate: DriveActivityGate())
        for boardID in [library.parentID, library.islandID, library.harborID] {
            for stack in try XCTUnwrap(workspace.eventStacks[boardID]) {
                for file in stack.files {
                    XCTAssertEqual(workspace.assignment(for: file), fresh.assignment(for: file), file.path)
                }
            }
        }
        for event in model.configuration.savedEvents {
            XCTAssertEqual(workspace.assignmentCount(for: event.id), fresh.assignmentCount(for: event.id), event.name)
            XCTAssertEqual(workspace.assignmentBytes(for: event.id), fresh.assignmentBytes(for: event.id), event.name)
        }
        // A file of the moved bursts is no longer found at its old path.
        let old = try XCTUnwrap(selection.first?.files.first)
        XCTAssertNil(workspace.assignment(for: OrganizeFile(path: old.path, size: old.size, modifiedAt: old.modifiedAt)))
    }

    // MARK: - Undo

    func testUndoAfterAnInstantMoveRestoresFilesCatalogAndBoards() async throws {
        let library = try MoveLibrary.make(.small)
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        await open(library, library.parentID, library.islandID, library.harborID)
        let selection = library.bursts(in: library.islandID, count: 3)
        let originalPaths = selection.flatMap(\.files).map(\.path)
        let islandStacks = try XCTUnwrap(workspace.eventStacks[library.islandID]).count
        let harborStacks = try XCTUnwrap(workspace.eventStacks[library.harborID]).count
        let originalAssignments = Set(model.configuration.photoEventAssignments)

        workspace.moveStacks(Set(selection.map(\.id)), fromEvent: library.islandID, toEvent: library.harborID)
        try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle == "Move to Trip 2026 / Harbor" }
        XCTAssertFalse(originalPaths.contains { exists($0) })

        workspace.undoLastMove()
        try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle == nil }
        await open(library, library.islandID, library.harborID)

        XCTAssertTrue(originalPaths.allSatisfy { exists($0) }, "every file is back where it was")
        XCTAssertEqual(Set(model.configuration.photoEventAssignments), originalAssignments)
        XCTAssertEqual(workspace.eventStacks[library.islandID]?.count, islandStacks)
        XCTAssertEqual(workspace.eventStacks[library.harborID]?.count, harborStacks)
        XCTAssertEqual(workspace.assignmentCount(for: library.islandID), library.shape.island)
        XCTAssertEqual(workspace.assignmentCount(for: library.harborID), library.shape.harbor)
    }

    // MARK: - Board counts for the family

    func testBoardCountsAfterAMoveForParentAndEverySubevent() async throws {
        let library = try MoveLibrary.make(.small)
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        await open(library, library.parentID, library.islandID, library.harborID, library.roadID)
        let counts = { (id: UUID) in workspace.assignmentCount(for: id) }
        XCTAssertEqual(counts(library.parentID), library.shape.family)

        let selection = library.bursts(in: library.islandID, count: 2)
        let moved = selection.flatMap(\.files).count
        // Island → Harbor, then a burst from Harbor on to the parent itself.
        workspace.moveStacks(Set(selection.map(\.id)), fromEvent: library.islandID, toEvent: library.harborID)
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(counts(library.islandID), library.shape.island - moved)
        XCTAssertEqual(counts(library.harborID), library.shape.harbor + moved)
        XCTAssertEqual(counts(library.roadID), library.shape.road)
        XCTAssertEqual(counts(library.parentID), library.shape.family)

        let again = Array(try XCTUnwrap(workspace.eventStacks[library.harborID]).filter { stack in selection.contains { $0.id == stack.id } }.prefix(1))
        let movedAgain = again.flatMap(\.files).count
        workspace.moveStacks(Set(again.map(\.id)), fromEvent: library.harborID, toEvent: library.parentID)
        try await waitUntil { !model.isBusy && workspace.latestMoveJournalTitle != nil }
        XCTAssertEqual(counts(library.harborID), library.shape.harbor + moved - movedAgain)
        XCTAssertEqual(counts(library.parentID), library.shape.family)
        // The parent's own board keeps every stack; a subevent's board never
        // shows the sibling's.
        let parentStacks = try XCTUnwrap(workspace.eventStacks[library.parentID])
        XCTAssertTrue(parentStacks.contains { $0.id == again[0].id })
        XCTAssertFalse(try XCTUnwrap(workspace.eventStacks[library.harborID]).contains { $0.id == again[0].id })
        XCTAssertEqual(workspace.assignedEvent(for: try XCTUnwrap(parentStacks.first { $0.id == again[0].id })).event?.id, library.parentID)
        XCTAssertEqual(
            model.configuration.photoEventAssignments.count,
            library.shape.total,
            "a move never adds or drops an assignment"
        )
    }
}
