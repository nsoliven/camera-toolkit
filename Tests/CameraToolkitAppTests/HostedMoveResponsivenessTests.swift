import AppKit
import CameraToolkitCore
import Foundation
import SwiftUI
import XCTest
@testable import CameraToolkitApp

/// One tap on Move to Event, in the real main window, at the size Camera
/// Toolkit is really used at. The model work of a move is ~10 ms; what a
/// user felt as "the app freezes for a couple of seconds" was the open board
/// redrawing — every tile, 150–500 ms a pass on a 15,000-file family — seven
/// times per move (eleven with a NAS), because every state change the move
/// made re-rendered the whole board, the storage strip recounted 15,000 rows
/// per slot, a hidden inspector still built, a board was re-read after the
/// move had already patched it, and the NAS rename finishing refreshed every
/// open board. Measured before the fix (release build, parent board): 1.6 s
/// of stalls without a NAS, 2.5 s with one.
///
/// Two kinds of assertions:
///
/// - Deterministic, always on: how many times the open board's grid is
///   rebuilt per move, that no board is re-read after a plain move or its NAS
///   rename, that the hidden inspector never builds, and that what the
///   patched boards and storage strips say is exactly what a fresh read says.
/// - Timing, only with `CT_PERF_BUDGETS=1` (on a quiet machine, release build):
///   `swift test -c release -Xswiftc -enable-testing --filter HostedMoveResponsivenessTests`
///   with `CT_PERF_BUDGETS=1`. Then the library has the full ~17,000
///   assignments; otherwise the fixture's small one keeps the suite quick — the
///   render and read counts do not depend on size. Stalls are what a 1 ms
///   watchdog on a background thread sees the main queue answer late, from
///   the click until everything the move started, NAS Rename included, is quiet.
///
/// Board settings (tiles or list, grouping, sort, inspector) are pinned
/// through the argument domain — the xctest defaults domain is shared with
/// every other test run on the machine. Nothing touches the real Application
/// Support folder, `/Volumes`, or the NAS: temp folders stand in for all of them.
@MainActor
final class HostedMoveResponsivenessTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    private var enforcesBudgets: Bool { ProcessInfo.processInfo.environment["CT_PERF_BUDGETS"] == "1" }

    private enum Source { case parent, subevent }

    private struct Scenario {
        var name: String
        var source: Source = .parent
        /// The NAS stand-in holds a copy of every file.
        var withNAS = false
        /// The Buffer is unplugged: only the NAS copies exist, and the move
        /// acts on those.
        var bufferAway = false
        var list = false
        var inspector = false
        /// Dropped on a sidebar row instead of chosen from the menu.
        var drop = false
        /// The most times the open board's grid may be rebuilt from the click
        /// until everything is quiet. Before: 7, or 11 with a NAS.
        var gridRenders: Int
        /// Timing budgets in ms, checked only with `CT_PERF_BUDGETS=1`.
        var totalStall: Double
        var longestStall: Double
    }

    private struct Report {
        var stalls: [MainStallMonitor.Stall]
        var total: Double { stalls.reduce(0) { $0 + $1.duration } * 1_000 }
        var longest: Double { (stalls.map(\.duration).max() ?? 0) * 1_000 }
        var gridRenders = 0
        var tileBuilds = 0
        var inspectorRenders = 0
        var boardReads = 0
    }

    // MARK: - Harness

    private func waitUntil(_ what: String, timeout: TimeInterval = 240, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isBusy(_ workspace: EventsWorkspace) -> Bool {
        !workspace.isQuiet || workspace.nasPresence.isChecking || (workspace.pendingNASRenameCount > 0 && workspace.nasIsConnected)
    }

    /// Nothing the move could have started is still running, and it stayed
    /// that way for `quiet` seconds.
    private func waitForQuiet(_ workspace: EventsWorkspace, quiet: Double = 1.0, timeout: TimeInterval = 240) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var since = Date()
        while Date().timeIntervalSince(since) < quiet {
            guard Date() < deadline else { return XCTFail("the app never went quiet") }
            try await Task.sleep(for: .milliseconds(20))
            if isBusy(workspace) { since = Date() }
        }
    }

    private func pinBoardSettings(list: Bool, inspector: Bool) -> () -> Void {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = original
        arguments["CameraToolkit.organize.mode"] = list ? "list" : "tiles"
        arguments["CameraToolkit.eventboard.grouping"] = "day"
        arguments["CameraToolkit.organize.tileWidth"] = 220.0
        arguments[EventInfoInspector.visibilityDefaultsKey] = inspector
        arguments[OrganizeBoardSortDefaults.eventKey] = "captureTime"
        arguments[OrganizeBoardSortDefaults.eventAscending] = true
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        return { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    }

    /// The board as a set of stacks, each a sorted list of file paths.
    private func cut(_ workspace: EventsWorkspace, _ id: UUID) -> Set<[String]> {
        Set((workspace.eventStacks[id] ?? []).map { $0.files.map { $0.path.lowercased() }.sorted() })
    }

    /// Every row's id with where the file is: what the storage strip counts.
    private func rows(_ workspace: EventsWorkspace, _ id: UUID) -> Set<String> {
        Set((workspace.presence[id]?.assets ?? []).map {
            "\($0.id)|\($0.assignment.eventID)|\($0.source)|\($0.drive)|\($0.otherDrive)|\($0.archive)|\($0.bestLocalPath ?? "-")"
        })
    }

    // MARK: - One move

    private func run(_ scenario: Scenario) async throws {
        // Catalog-backed, like the app, at either size.
        var shape = enforcesBudgets ? MoveLibrary.Shape.realistic : MoveLibrary.Shape.small
        shape.catalogBacked = true
        let library = try MoveLibrary.make(shape)
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        if scenario.withNAS || scenario.bufferAway { try library.putEveryFileOnTheNAS() }
        if scenario.bufferAway { try library.unplugTheBuffer() }
        let probe = MovePresenceProbe(nasRoot: workspace.locations.nasRoot.path)
        workspace.presenceProbe = probe.probe
        let restoreDefaults = pinBoardSettings(list: scenario.list, inspector: scenario.inspector)
        defer { restoreDefaults() }
        let window = SnapshotWindows.main(model: model, workspace: workspace)
        self.window = window

        // Visit the boards a user would have open: the parent (whole
        // family), the subevent the files leave, the one they join.
        for id in [library.parentID, library.sourceSubeventID, library.targetSubeventID] {
            workspace.selection = .event(id)
            try await waitUntil("board \(id)") { workspace.eventStacks[id] != nil && workspace.presence[id] != nil }
            try await waitForQuiet(workspace, quiet: 0.6)
        }
        let sourceBoard = scenario.source == .parent ? library.parentID : library.sourceSubeventID
        workspace.selection = .event(sourceBoard)
        try await waitForQuiet(workspace, quiet: 0.8)
        if scenario.withNAS || scenario.bufferAway {
            try await waitUntil("the NAS to connect") { workspace.nasIsConnected }
        }

        // One burst of the source subevent, as drawn on the source board.
        let sourceIDs = Set((workspace.eventStacks[library.sourceSubeventID] ?? []).map(\.id))
        let selection = Array((workspace.eventStacks[sourceBoard] ?? []).filter { $0.isBurst && sourceIDs.contains($0.id) }.prefix(1))
        XCTAssertEqual(selection.count, 1, "\(scenario.name): no burst of the source subevent on the source board")
        let files = selection.flatMap(\.files)
        workspace.selectStacks(selection.map(\.id))
        try await Task.sleep(for: .milliseconds(300))

        let parentStacks = try XCTUnwrap(workspace.eventStacks[library.parentID]).count
        let sourceStacks = try XCTUnwrap(workspace.eventStacks[library.sourceSubeventID]).count
        let targetStacks = try XCTUnwrap(workspace.eventStacks[library.targetSubeventID]).count
        let statsBefore = probe.total
        BoardRenderCounter.reset()
        let readsBefore = workspace.boardReadCount
        let monitor = MainStallMonitor()
        monitor.start()
        try await Task.sleep(for: .milliseconds(50))

        // The click.
        if scenario.drop {
            let payload = workspace.dragPayload(for: selection[0].id, origin: .event, containerID: sourceBoard)
            XCTAssertTrue(workspace.handleDrop([payload], onto: library.targetSubeventID))
        } else {
            workspace.moveStacks(Set(selection.map(\.id)), fromEvent: sourceBoard, toEvent: library.targetSubeventID)
        }
        try await waitUntil("the move to land") { !model.isBusy && model.statusMessage.hasPrefix("Moved") }
        try await waitForQuiet(workspace, quiet: 1.5)
        let stalls = monitor.stop()
        let report = Report(
            stalls: stalls,
            gridRenders: BoardRenderCounter.count(.grid),
            tileBuilds: BoardRenderCounter.count(.gridTile),
            inspectorRenders: BoardRenderCounter.count(.inspector),
            boardReads: workspace.boardReadCount - readsBefore
        )
        print(String(
            format: "BENCH %@: stalls %d, total %.0f ms, longest %.0f ms · grid renders %d, tile builds %d, inspector builds %d, board reads %d, status: %@",
            scenario.name, report.stalls.count, report.total, report.longest, report.gridRenders, report.tileBuilds,
            report.inspectorRenders, report.boardReads, model.statusMessage
        ))

        // The move did what it says, everywhere it shows.
        XCTAssertEqual(workspace.eventStacks[library.parentID]?.count, parentStacks, "\(scenario.name): the parent holds both subevents")
        XCTAssertEqual(workspace.eventStacks[library.sourceSubeventID]?.count, sourceStacks - 1, scenario.name)
        XCTAssertEqual(workspace.eventStacks[library.targetSubeventID]?.count, targetStacks + 1, scenario.name)
        XCTAssertTrue(model.statusMessage.hasPrefix("Moved"), "\(scenario.name): \(model.statusMessage)")
        if scenario.withNAS || scenario.bufferAway {
            XCTAssertTrue(model.statusMessage.contains("Renamed \(files.count) cop"), "\(scenario.name): the NAS part joins the move's line — \(model.statusMessage)")
            XCTAssertEqual(workspace.pendingNASRenameCount, 0, scenario.name)
        }
        let target = try XCTUnwrap(workspace.event(library.targetSubeventID))
        let targetOriginals = workspace.locations.originalsRoot(for: target, deviceID: "sony-a7v", policy: .buffer)
        for file in files {
            let landed = targetOriginals.appendingPathComponent(file.name).path
            if scenario.bufferAway {
                XCTAssertFalse(FileManager.default.fileExists(atPath: landed), "\(scenario.name): \(file.name) appeared on the unplugged Buffer")
                let nas = try XCTUnwrap(workspace.locations.mirrorRelativePath(forDrivePath: landed))
                XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.locations.nasRoot.appendingPathComponent(nas).path), "\(scenario.name): the NAS copy of \(file.name) is at its new place")
            } else {
                XCTAssertTrue(FileManager.default.fileExists(atPath: landed), "\(scenario.name): \(file.name) is in the target's folder")
            }
        }

        // Deterministic budgets.
        XCTAssertEqual(report.boardReads, 0, "\(scenario.name): a plain move and its NAS rename re-read no board")
        XCTAssertEqual(probe.total, statsBefore, "\(scenario.name): and stat no file of any board")
        XCTAssertLessThanOrEqual(report.gridRenders, scenario.gridRenders, "\(scenario.name): the open board's grid was rebuilt \(report.gridRenders) times")
        if !scenario.inspector {
            XCTAssertEqual(report.inspectorRenders, 0, "\(scenario.name): a hidden inspector must not build")
        } else {
            XCTAssertLessThanOrEqual(report.inspectorRenders, scenario.gridRenders, scenario.name)
        }

        // What the patched boards and storage strips say is what a fresh read says.
        for (label, id) in [("parent", library.parentID), ("source subevent", library.sourceSubeventID), ("target subevent", library.targetSubeventID)] {
            let patchedCut = cut(workspace, id)
            let patchedRows = rows(workspace, id)
            let patchedCounts = workspace.presence[id]?.counts
            if let summary = workspace.presence[id] {
                XCTAssertEqual(summary.counts, EventPresenceCounts(summary.assets), "\(scenario.name): \(label) counts follow their rows")
            }
            await workspace.refreshEvent(id)
            XCTAssertEqual(patchedCut, cut(workspace, id), "\(scenario.name): the \(label) board is not what a fresh read draws")
            XCTAssertEqual(patchedRows, rows(workspace, id), "\(scenario.name): the \(label) storage rows are not what a fresh read finds")
            XCTAssertEqual(patchedCounts, workspace.presence[id]?.counts, "\(scenario.name): the \(label) storage strip is not what a fresh read counts")
        }

        // Timing, on a quiet machine.
        if enforcesBudgets {
            XCTAssertLessThan(report.total, scenario.totalStall, "\(scenario.name): main-thread stalls added up to \(Int(report.total)) ms")
            XCTAssertLessThan(report.longest, scenario.longestStall, "\(scenario.name): the longest stall was \(Int(report.longest)) ms")
        }
    }

    // MARK: - The cases

    // Measured in a release build on a quiet machine, before the fix ->
    // after (stalls >= 16 ms from the click until quiet, total / longest):
    //   parent board          1,633 / 480 ms -> ~410 / 290
    //   parent board + NAS    2,512 / 448 ms -> ~520 / 275
    //   Subevent board + NAS   782 / 140 ms -> ~230 / 120
    //   list mode             2,028 / 608 ms -> ~430 / 300
    //   inspector open        1,637 / 465 ms -> ~460 / 330
    //   sidebar drop            375 / 156 ms -> ~190 / 125
    // The budgets sit between: well above what the fixed code measures, below
    // what the old code did. They need a quiet machine — with other builds
    // running (load average in the tens) every number is inflated ~2x. The grid still redraws for each change to the
    // app-wide dictionaries it reads (one per move, one when the NAS rename
    // lands); per-board observable state is what removes those.

    func testMoveFromTheParentBoard() async throws {
        try await run(Scenario(name: "parent board", gridRenders: 4, totalStall: 900, longestStall: 500))
    }

    func testMoveFromTheParentBoardWithTheNAS() async throws {
        try await run(Scenario(name: "parent board + NAS", withNAS: true, gridRenders: 5, totalStall: 1_100, longestStall: 500))
    }

    func testMoveFromTheParentBoardWithTheBufferUnplugged() async throws {
        try await run(Scenario(name: "parent board, Buffer unplugged", withNAS: true, bufferAway: true, gridRenders: 5, totalStall: 1_100, longestStall: 500))
    }

    func testMoveFromTheSubeventBoardWithTheNAS() async throws {
        try await run(Scenario(name: "subevent board + NAS", source: .subevent, withNAS: true, gridRenders: 5, totalStall: 500, longestStall: 250))
    }

    func testMoveInListMode() async throws {
        try await run(Scenario(name: "list mode", list: true, gridRenders: 4, totalStall: 1_000, longestStall: 600))
    }

    func testMoveWithTheInspectorOpen() async throws {
        try await run(Scenario(name: "inspector open", inspector: true, gridRenders: 4, totalStall: 1_000, longestStall: 600))
    }

    func testDropOnASidebarRow() async throws {
        try await run(Scenario(name: "sidebar drop", source: .subevent, drop: true, gridRenders: 4, totalStall: 350, longestStall: 250))
    }
}
