import AppKit
import CameraToolkitCore
import Foundation
import SwiftUI
import XCTest
@testable import CameraToolkitApp

/// One tap on Move to Event, in the real main window, at the size Camera
/// Toolkit is really used at. The model work of a move is ~10 ms; what a
/// user felt as "the app freezes" was the window drawing what the move
/// changed: first every tile of the open board, seven times per move, then —
/// with that fixed — one frame that did the whole landing at once (the
/// catalog write, the counts, the tiles' new paths, the storage strip, the
/// toolbar, the sidebar) at 130–200 ms of main-thread CPU on a 15,000-file
/// family. Now the click's own frame is ~30–40 ms and the landing is drawn in
/// slices (`EventsWorkspace.landMove`), none of them over ~30 ms.
///
/// Two kinds of assertions:
///
/// - Deterministic, always on: how many times the open board's grid is
///   rebuilt per move, how many tiles the move asks to be built, that no
///   board is re-read after a plain move or its NAS rename, that the hidden
///   inspector never builds, and that what the patched boards and storage
///   strips say is exactly what a fresh read says.
/// - Timing, only with `CT_PERF_BUDGETS=1` (release build, awake display):
///   `swift test -c release -Xswiftc -enable-testing --filter HostedMoveResponsivenessTests`
///   with `CT_PERF_BUDGETS=1`. Then the library has the full ~17,000
///   assignments; otherwise the fixture's small one keeps the suite quick — the
///   render and read counts do not depend on size. Stalls are what a 1 ms
///   watchdog on a background thread sees the main queue answer late, from
///   the click until everything the move started, NAS Rename included, is
///   quiet; each carries the main thread's own CPU time over the wait, which
///   is what to compare across machines and loads (the wait itself grows when
///   the machine is busy).
///
/// The click follows what a person does: the burst is selected (which scrolls
/// the board to it), and the harness then drives frames until the scroll and
/// the lazy stack's row building are over — a visible window does that on its
/// own, a hosted one has no display behind it — so a run measures the move,
/// not an animation left over from the selection.
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
        /// The user scrolled through the board before choosing what to move:
        /// the lazy stack keeps every row it built, and a redraw of the
        /// grid re-evaluates all of them.
        var scrolled = false
        /// Dropped on a sidebar row instead of chosen from the menu.
        var drop = false
        /// The most times the open board's grid may be rebuilt from the click
        /// until everything is quiet. Before: 7, or 11 with a NAS; now 1.
        var gridRenders = 1
        /// The most tiles (rows, in list mode) the move may ask to be built,
        /// counted from the click until everything is quiet. A tile is built
        /// when it is new or when something it shows changed; the rows the
        /// lazy stack already holds are not asked again.
        var tileBuilds: Int
        /// The most times the open inspector may build.
        var inspectorRenders = 7
        /// Timing budgets in ms, checked only with `CT_PERF_BUDGETS=1`. The
        /// longest stall is the goal — nothing over 50 ms from the click until
        /// quiet — the total is what the whole move may cost the main thread.
        var totalStall: Double
        var longestStall = 50.0
    }

    private struct Report {
        var stalls: [MainStallMonitor.Stall]
        var total: Double { stalls.reduce(0) { $0 + $1.duration } * 1_000 }
        var longest: Double { (stalls.map(\.duration).max() ?? 0) * 1_000 }
        /// The main thread's own CPU time in the longest stall.
        var longestCPU: Double { (stalls.max { $0.duration < $1.duration }?.cpu ?? 0) * 1_000 }
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

    // MARK: - Scrolling

    private func boardScrollView(_ window: NSWindow) throws -> NSScrollView {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let views = all(window.contentView!.superview!).compactMap { $0 as? NSScrollView }
        return try XCTUnwrap(views.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
    }

    private func setOffset(_ scroll: NSScrollView, _ y: Double) {
        let clip = scroll.contentView
        guard let doc = scroll.documentView else { return }
        let top = -scroll.contentInsets.top
        let maxY = max(top, doc.frame.height - clip.bounds.height + scroll.contentInsets.bottom)
        let target = min(max(top, top + y), maxY)
        let flippedY = doc.isFlipped ? target : doc.frame.height - clip.bounds.height - target
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: flippedY))
        scroll.reflectScrolledClipView(clip)
    }

    /// Scrolls down through `points` of the board a screenful at a time, one
    /// drawn frame each, and back to the top — what browsing a big board
    /// leaves behind: hundreds of rows the lazy stack still holds.
    private func scrollThroughTheBoard(_ window: NSWindow, workspace: EventsWorkspace, points: Double = 6_000) async throws {
        let scroll = try boardScrollView(window)
        var y = 0.0
        while y <= points {
            setOffset(scroll, y)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(120))
            y += 350
        }
        setOffset(scroll, 0)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        try await waitForQuiet(workspace, quiet: 0.8)
    }

    /// Selecting a stack scrolls the board to it (animated), and the lazy
    /// stack builds the rows around wherever the board comes to rest, a frame
    /// at a time. On a visible window all of that is long over by the time a
    /// person presses Move; a hosted window has no display running behind it,
    /// so this drives the frames itself (a layout and a draw each) until the
    /// scroll offset and the row count have held still for a full second.
    /// Without it the click lands in the middle of the scroll and pays for
    /// the animation and for rows nobody would be waiting on.
    private func waitForTheBoardToSettle(_ window: NSWindow, timeout: TimeInterval = 60) async throws {
        let scroll = try boardScrollView(window)
        let deadline = Date().addingTimeInterval(timeout)
        var lastRows = -1
        var lastOffset = -1.0
        var stableSince = Date()
        while Date() < deadline {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(50))
            let rows = BoardRenderCounter.count(.gridTile)
            let offset = Double(scroll.contentView.bounds.origin.y)
            if rows != lastRows || abs(offset - lastOffset) > 0.5 {
                lastRows = rows
                lastOffset = offset
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) >= 1.0 {
                return
            }
        }
        XCTFail("The board never settled")
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

        if scenario.scrolled { try await scrollThroughTheBoard(window, workspace: workspace) }

        // One burst of the source subevent, as drawn on the source board.
        let sourceIDs = Set((workspace.eventStacks[library.sourceSubeventID] ?? []).map(\.id))
        let selection = Array((workspace.eventStacks[sourceBoard] ?? []).filter { $0.isBurst && sourceIDs.contains($0.id) }.prefix(1))
        XCTAssertEqual(selection.count, 1, "\(scenario.name): no burst of the source subevent on the source board")
        let files = selection.flatMap(\.files)
        workspace.selectStacks(selection.map(\.id))
        try await Task.sleep(for: .milliseconds(300))
        try await waitForTheBoardToSettle(window)

        let parentStacks = try XCTUnwrap(workspace.eventStacks[library.parentID]).count
        let sourceStacks = try XCTUnwrap(workspace.eventStacks[library.sourceSubeventID]).count
        let targetStacks = try XCTUnwrap(workspace.eventStacks[library.targetSubeventID]).count
        let statsBefore = probe.total
        BoardRenderCounter.reset()
        let readsBefore = workspace.boardReadCount
        let monitor = MainStallMonitor()
        let monitorOrigin = ProcessInfo.processInfo.systemUptime
        monitor.start()
        try await Task.sleep(for: .milliseconds(50))
        let clickAt = ProcessInfo.processInfo.systemUptime

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
        print("STALLS \(scenario.name), ms after the click: " + stalls.sorted { $0.startedAt < $1.startedAt }.map { String(format: "@%.0f+%.0f(cpu %.0f)", ($0.startedAt - (clickAt - monitorOrigin)) * 1000, $0.duration * 1000, $0.cpu * 1000) }.joined(separator: " "))
        print(String(
            format: "BENCH %@: stalls %d, total %.0f ms, longest %.0f ms (main thread cpu %.0f) · grid renders %d, tile builds %d, inspector builds %d, board reads %d, status: %@",
            scenario.name, report.stalls.count, report.total, report.longest, report.longestCPU, report.gridRenders, report.tileBuilds,
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
        XCTAssertLessThanOrEqual(report.tileBuilds, scenario.tileBuilds, "\(scenario.name): the move asked for \(report.tileBuilds) tiles to be built — the rows the lazy stack holds must not all be asked again")
        if !scenario.inspector {
            XCTAssertEqual(report.inspectorRenders, 0, "\(scenario.name): a hidden inspector must not build")
        } else {
            XCTAssertLessThanOrEqual(report.inspectorRenders, scenario.inspectorRenders, scenario.name)
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
            XCTAssertLessThan(report.longest, scenario.longestStall, "\(scenario.name): the longest stall was \(Int(report.longest)) ms (main thread cpu \(Int(report.longestCPU)) ms)")
        }
    }

    // MARK: - The cases

    // Measured in a release build on a display that was awake, stalls >= 8 ms
    // from the click until quiet: (total ms / longest ms) before this work ->
    // now, main-thread CPU in the longest stall in brackets, at load average
    // ~10-14 before and ~12-20 now (the later runs were on a busier machine) (`BoardScrollPerfTests` covers scrolling; this covers
    // the move):
    //   parent board          172 / 110 -> 121 / 29   (tiles built 54 -> 7)
    //   parent board + NAS    219 / 110 -> 138 / 30   (77 -> 8)
    //   Buffer unplugged      188 / 94  -> 142 / 30   (-> 8)
    //   subevent board + NAS  162 / 87  -> 125 / 42   (52 -> 20)
    //   scrolled board        175 / 115 -> 117 / 24   (54 -> 7)
    //   list mode             175 / 112 -> 107 / 23   (34 -> 4)
    //   inspector open        228 / 167 -> 156 / 30   (42 -> 6)
    //   sidebar drop          145 / 101 -> 113 / 42   (36 -> 20)
    // What made the difference: a tile depends on its own files and stack and
    // is told when those change (not when anything does), tile rows and list
    // entries are values SwiftUI skips when equal, the header, strip, toolbar
    // title and bottom bar read their own state, views read the events and
    // locations through facets that ignore an event's last-used stamp, and the
    // landing is cut into slices that are each drawn before the next starts.
    // What is left is SwiftUI's update and layout of the click's own frame (the
    // tiles change boards, counts follow, a job starts) and of each slice.

    func testMoveFromTheParentBoard() async throws {
        try await run(Scenario(name: "parent board", tileBuilds: 12, totalStall: 180))
    }

    func testMoveFromTheParentBoardWithTheNAS() async throws {
        try await run(Scenario(name: "parent board + NAS", withNAS: true, tileBuilds: 12, totalStall: 190))
    }

    func testMoveFromTheParentBoardWithTheBufferUnplugged() async throws {
        try await run(Scenario(name: "parent board, Buffer unplugged", withNAS: true, bufferAway: true, tileBuilds: 12, totalStall: 220))
    }

    func testMoveFromTheSubeventBoardWithTheNAS() async throws {
        try await run(Scenario(name: "subevent board + NAS", source: .subevent, withNAS: true, tileBuilds: 28, totalStall: 180))
    }

    func testMoveFromAScrolledParentBoard() async throws {
        try await run(Scenario(name: "scrolled parent board", scrolled: true, tileBuilds: 12, totalStall: 170))
    }

    func testMoveInListMode() async throws {
        try await run(Scenario(name: "list mode", list: true, tileBuilds: 8, totalStall: 150))
    }

    // The inspector, unlike the grid, redraws with each slice that changes
    // what it shows (counts, storage rows, people).
    func testMoveWithTheInspectorOpen() async throws {
        try await run(Scenario(name: "inspector open", inspector: true, tileBuilds: 10, totalStall: 230))
    }

    func testDropOnASidebarRow() async throws {
        try await run(Scenario(name: "sidebar drop", source: .subevent, drop: true, tileBuilds: 28, totalStall: 170))
    }
}
