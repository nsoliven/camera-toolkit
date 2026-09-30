import AppKit
import CameraToolkitCore
import Foundation
import SwiftUI
import XCTest
@testable import CameraToolkitApp

/// "Swapping tabs I want to be flawless." Tabs are the sidebar's boards:
/// switching between them, back and forth, keeps each board's own state and
/// never makes the window wait.
@MainActor
final class BoardSwitchingTests: XCTestCase {
    private func waitUntil(timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Lets the window and its boards' tasks run. Suspending — not spinning the
    /// run loop — is what lets main-actor work (a board's `.task`) proceed.
    private func pump(_ seconds: TimeInterval = 0.3, _ window: NSWindow? = nil) async {
        try? await Task.sleep(for: .seconds(seconds))
        window?.contentView?.superview?.layoutSubtreeIfNeeded()
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHidden, scroll.frame.height > 0 { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    private func boardScrollView(in window: NSWindow) -> NSScrollView? {
        guard let content = window.contentView else { return nil }
        return scrollViews(in: content)
            .filter { !($0.documentView is NSTableView) && !($0.documentView is NSOutlineView) }
            .filter { $0.convert($0.bounds, to: nil).minX <= 0.5 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func hasText(_ text: String, in view: NSView) -> Bool {
        if let field = view as? NSTextField, field.stringValue.contains(text) { return true }
        if view.accessibilityLabel()?.contains(text) == true { return true }
        return view.subviews.contains { hasText(text, in: $0) }
    }

    private func open(_ library: MoveLibrary, _ ids: UUID...) async {
        for id in ids { await library.workspace.refreshEvent(id) }
    }

    // MARK: - Each board keeps its own state

    func testEachBoardKeepsItsOwnExpandedBurstsCollapsedGroupsAndFilters() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        await open(library, library.cityID, library.beachID)

        workspace.selection = .event(library.cityID)
        let city = try XCTUnwrap(workspace.eventStacks[library.cityID])
        let burst = try XCTUnwrap(city.first { $0.isBurst })
        workspace.setExpanded(burst.id, expanded: true)
        workspace.setGroupCollapsed("2026-03-01", collapsed: true)
        workspace.search.text = "DSC"
        workspace.search.excludedEventIDs = [library.beachID]
        let citySearch = workspace.search

        workspace.selection = .event(library.beachID)
        XCTAssertTrue(workspace.expandedStackIDs.isEmpty, "the other board starts with nothing expanded")
        XCTAssertTrue(workspace.collapsedGroupIDs.isEmpty)
        XCTAssertTrue(workspace.search.isUntouched, "the other board starts with no filters")
        workspace.search.text = "B00"
        let beachSearch = workspace.search

        workspace.selection = .event(library.cityID)
        XCTAssertEqual(workspace.expandedStackIDs, [burst.id])
        XCTAssertEqual(workspace.collapsedGroupIDs, ["2026-03-01"])
        XCTAssertEqual(workspace.search, citySearch)

        workspace.selection = .event(library.beachID)
        XCTAssertEqual(workspace.search, beachSearch)
        XCTAssertTrue(workspace.expandedStackIDs.isEmpty)
        // Through the welcome screen and back.
        workspace.selection = nil
        workspace.selection = .event(library.cityID)
        XCTAssertEqual(workspace.expandedStackIDs, [burst.id])
        XCTAssertEqual(workspace.search, citySearch)
        }
    }

    func testScrollPositionsAreRememberedPerBoard() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        workspace.noteScrollOffset(1_234, board: .event(library.cityID))
        workspace.noteScrollOffset(56, board: .event(library.beachID))
        workspace.selection = .event(library.cityID)
        workspace.selection = .event(library.beachID)
        XCTAssertEqual(workspace.savedScrollOffset(for: .event(library.cityID)), 1_234)
        XCTAssertEqual(workspace.savedScrollOffset(for: .event(library.beachID)), 56)
        XCTAssertEqual(workspace.savedScrollOffset(for: .event(library.roadID)), 0)
        }
    }

    /// The real window: scroll a long board, go to another and come back.
    func testTheWindowRestoresTheScrollPositionOfTheBoardYouLeft() async throws {
        try await eachLibrary(MoveLibrary.Shape(parentOwn: 0, beach: 60, city: 2_400, road: 0, elsewhere: 0, catalogBacked: false)) { library, mode in
        let workspace = library.workspace
        await open(library, library.cityID, library.beachID)
        let window = SnapshotWindows.main(model: library.model, workspace: workspace)
        defer { window.orderOut(nil); window.close() }
        window.setContentSize(NSSize(width: 1320, height: 840))

        workspace.selection = .event(library.cityID)
        await pump(0.6, window)
        let scroll = try XCTUnwrap(boardScrollView(in: window))
        let origin = scroll.contentView.bounds.origin.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: origin + 2_500))
        scroll.reflectScrolledClipView(scroll.contentView)
        await pump(0.4, window)
        let scrolledTo = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(scrolledTo, origin + 1_000, "the board did not scroll in the harness")
        XCTAssertGreaterThan(workspace.savedScrollOffset(for: .event(library.cityID)), 1_000)

        workspace.selection = .event(library.beachID)
        await pump(0.6, window)
        workspace.selection = .event(library.cityID)
        await pump(0.8, window)
        let back = try XCTUnwrap(boardScrollView(in: window))
        XCTAssertEqual(back.contentView.bounds.origin.y, scrolledTo, accuracy: 60, "the board came back at another place")
        }
    }

    // MARK: - Loaded boards switch without a wait

    func testSelectingALoadedBoardShowsItsGridInTheSameFrame() async throws {
        try await eachLibrary(MoveLibrary.Shape(parentOwn: 0, beach: 200, city: 600, road: 0, elsewhere: 0, catalogBacked: false)) { library, mode in
        let workspace = library.workspace
        await open(library, library.cityID, library.beachID)
        let window = SnapshotWindows.main(model: library.model, workspace: workspace)
        defer { window.orderOut(nil); window.close() }
        window.setContentSize(NSSize(width: 1320, height: 840))
        workspace.selection = .event(library.cityID)
        await pump(0.6, window)

        for id in [library.beachID, library.cityID, library.beachID] {
            workspace.selection = .event(id)
            // No run-loop turn between the click and the first layout.
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertFalse(workspace.eventBoardShowsPlaceholders(id))
            XCTAssertNotNil(workspace.eventStacks[id])
            XCTAssertNotNil(boardScrollView(in: window), "no grid on the first frame")
            let content = try XCTUnwrap(window.contentView)
            XCTAssertFalse(hasText("Loading", in: content), "a loading screen flashed")
            XCTAssertFalse(hasText("Not Connected", in: content))
            XCTAssertFalse(hasText("Not Reachable", in: content))
        }
        }
    }

    func testSwitchingToALoadedBoardDoesNotRestackOrSweepIt() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        let sweeps = SweepCounter()
        workspace.presenceProbe = sweeps.probe
        await open(library, library.cityID, library.beachID)
        let window = SnapshotWindows.main(model: library.model, workspace: workspace)
        defer { window.orderOut(nil); window.close() }
        // Opening the window re-checks connectivity, which (rightly) has each
        // board verified once more; let that settle, then count.
        // (The window's start-up also re-reads the configuration once, so a
        // board opened in that moment is verified against the old revision:
        // open each twice, the second time against the settled one.)
        for _ in 0..<2 {
            for id in [library.cityID, library.beachID] {
                workspace.selection = .event(id)
                await pump(0.7, window)
            }
        }
        for id in [library.cityID, library.beachID] {
            try await waitUntil { workspace.isBoardFresh(id) }
        }
        let statsAfterLoad = sweeps.count
        let city = workspace.eventStacks[library.cityID]
        for _ in 0..<3 {
            workspace.selection = .event(library.cityID)
            await pump(0.3, window)
            workspace.selection = .event(library.beachID)
            await pump(0.3, window)
        }
        XCTAssertEqual(sweeps.count, statsAfterLoad, "selecting a loaded board swept it again")
        XCTAssertEqual(workspace.eventStacks[library.cityID], city)
        }
    }

    /// The measured claim: time the main actor is held by a switch to a
    /// board that is already loaded — a small one and a family of ~15k files.
    func testSwitchStallsStayInsideTheFrameBudget() async throws {
        try await eachLibrary(
            MoveLibrary.Shape(parentOwn: 9_000, beach: 3_000, city: 3_000, road: 160, elsewhere: 300, catalogBacked: false),
            populateNAS: false
        ) { library, mode in
        let workspace = library.workspace
        await open(library, library.parentID, library.elsewhereID, library.roadID)
        let window = SnapshotWindows.main(model: library.model, workspace: workspace)
        defer { window.orderOut(nil); window.close() }
        window.setContentSize(NSSize(width: 1320, height: 840))
        workspace.selection = .event(library.parentID)
        await pump(0.8, window)
        workspace.selection = .event(library.elsewhereID)
        await pump(0.5, window)

        let monitor = MainStallMonitor()
        var samples: [String: [Double]] = [:]
        @MainActor func time(_ id: UUID, _ label: String) async {
            monitor.start()
            let start = ProcessInfo.processInfo.systemUptime
            workspace.selection = .event(id)
            window.contentView?.layoutSubtreeIfNeeded()
            let synchronous = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            await pump(0.4, window)
            let longest = (monitor.stop().first?.duration ?? 0) * 1_000
            print("TIMING|[\(mode.rawValue)] switch to \(label): sync \((synchronous * 10).rounded() / 10) ms, longest main stall \((longest * 10).rounded() / 10) ms")
            samples[label, default: []].append(max(synchronous, longest))
        }
        await time(library.parentID, "15k family board")
        await time(library.elsewhereID, "300-file board")
        await time(library.parentID, "15k family board")
        await time(library.roadID, "160-file board")
        await time(library.parentID, "15k family board")
        // What a switch costs is the window's own layout, not the board: a
        // 15k-file family must not stall the main actor much longer than a
        // small board does (before, it stalled about 2.5 times as long).
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let small = median((samples["300-file board"] ?? []) + (samples["160-file board"] ?? []))
        let big = median(samples["15k family board"] ?? [])
        XCTAssertLessThan(big, small * 2 + 250, "a 15k board stalls the main actor \(big) ms vs \(small) ms for a small one")
        }
    }

    /// Nothing mounted at all: the boards are still the catalog's grids, and
    /// no board — switching to it or staying on it — shows a "not connected"
    /// screen or a spinner.
    func testNothingMountedNeverShowsABlockingScreenWhileSwitching() async throws {
        try await eachLibrary(
            MoveLibrary.Shape(parentOwn: 0, beach: 200, city: 400, road: 30, elsewhere: 0, catalogBacked: false),
            modes: [.nothingMounted]
        ) { library, mode in
        let workspace = library.workspace
        let window = SnapshotWindows.main(model: library.model, workspace: workspace)
        defer { window.orderOut(nil); window.close() }
        window.setContentSize(NSSize(width: 1320, height: 840))
        for id in [library.cityID, library.beachID, library.roadID, library.parentID, library.cityID] {
            workspace.selection = .event(id)
            // The first frames of a board that has never been opened.
            for _ in 0..<40 {
                window.contentView?.layoutSubtreeIfNeeded()
                await pump(0.02, window)
                let content = try XCTUnwrap(window.contentView)
                XCTAssertFalse(hasText("Not Connected", in: content))
                XCTAssertFalse(hasText("Not Reachable", in: content))
            }
            XCTAssertNotNil(workspace.eventStacks[id]?.first, "board \(id) has no grid")
            XCTAssertNotNil(boardScrollView(in: window))
        }
        }
    }

    // MARK: - Rapid switching

    func testClickingThroughBoardsFastNeverCrossesSelectionsOrMixesTiles() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        let ids = [library.parentID, library.beachID, library.cityID, library.roadID, library.elsewhereID]
        await open(library, library.beachID, library.cityID, library.roadID, library.elsewhereID)
        var chosen: [UUID: Set<String>] = [:]
        for (index, id) in ids.dropFirst().enumerated() {
            workspace.selection = .event(id)
            let stacks = try XCTUnwrap(workspace.eventStacks[id])
            let ownIDs = Array(stacks.prefix(index + 1).map(\.id))
            workspace.selectStacks(ownIDs)
            chosen[id] = Set(ownIDs)
        }
        let window = SnapshotWindows.main(model: library.model, workspace: workspace)
        defer { window.orderOut(nil); window.close() }

        // Ten boards' worth of clicks and arrow-key steps, no waiting.
        var order: [UUID] = []
        for round in 0..<3 {
            for id in (round % 2 == 0 ? ids : ids.reversed()) {
                workspace.selection = .event(id)
                order.append(id)
                if let expected = chosen[id] {
                    XCTAssertEqual(workspace.selectedStackIDs, expected, "board \(id) lost or mixed its selection")
                } else {
                    XCTAssertTrue(workspace.selectedStackIDs.isEmpty, "the untouched board picked up a selection")
                }
                let own = Set((workspace.eventStacks[id] ?? []).map(\.id))
                XCTAssertTrue(workspace.selectedStackIDs.isSubset(of: own), "selected ids belong to another board")
                if round == 0 { window.contentView?.layoutSubtreeIfNeeded() }
            }
        }
        XCTAssertEqual(order.count, 15)
        await pump(0.5, window)
        XCTAssertEqual(workspace.selection, .event(order.last!))
        for (id, expected) in chosen {
            workspace.selection = .event(id)
            XCTAssertEqual(workspace.selectedStackIDs, expected)
        }
        }
    }

    func testABoardLeftWhileItIsStillLoadingStopsLoading() async throws {
        try await eachLibrary(
            MoveLibrary.Shape(parentOwn: 0, beach: 800, city: 800, road: 0, elsewhere: 0, catalogBacked: false),
            populateNAS: false
        ) { library, mode in
        let workspace = library.workspace
        // A family too big for a whole first screen, whose build is held in a
        // resolve that never returns until released — a drive answering one
        // file at a time.
        workspace.wholeBoardFirstScreenLimit = 0
        let gate = DispatchSemaphore(value: 0)
        defer { for _ in 0..<8 { gate.signal() } }
        let firstScreen = Set(library.model.configuration.photoEventAssignments
            .filter { $0.eventID == library.cityID }
            .sorted { ($0.modifiedAt, $0.relativePath) < ($1.modifiedAt, $1.relativePath) }
            .prefix(EventsWorkspace.firstScreenFileLimit)
            .map(\.relativePath))
        let locations = workspace.locations
        let city = try XCTUnwrap(workspace.event(library.cityID))
        let layout = locations.layout(for: city, deviceID: "sony-a7v")
        let released = ThreadRecorder()
        let bufferPlugged = mode == .bufferPlugged
        workspace.eventPathResolver = { assignment in
            if !firstScreen.contains(assignment.relativePath), released.total == 0 {
                _ = gate.wait(timeout: .now() + 20)
            }
            if bufferPlugged { return locations.impliedDrivePath(for: assignment, event: city, policy: .buffer) }
            return (try? layout.mirrorRelativePath(for: assignment.relativePath)).map { locations.nasRoot.appendingPathComponent($0).path }
        }
        workspace.selection = .event(library.cityID)
        let refresh = Task { await workspace.refreshEvent(library.cityID) }
        try await waitUntil { workspace.eventStacks[library.cityID]?.isEmpty == false }
        XCTAssertNotNil(workspace.eventBuildRemainders[library.cityID], "only the first screen is up")
        let firstCount = try XCTUnwrap(workspace.eventStacks[library.cityID]).count

        // Click another board while this one is still finding its files.
        workspace.selection = .event(library.beachID)
        XCTAssertFalse(workspace.eventsLoading.contains(library.cityID), "the superseded load is still marked loading")
        // The held resolve is released; the cancelled build must not publish.
        released.note()
        for _ in 0..<8 { gate.signal() }
        await refresh.value
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(workspace.eventStacks[library.cityID]?.count, firstCount, "the superseded load kept building")
        XCTAssertNotNil(workspace.eventBuildRemainders[library.cityID])

        // Coming back starts it over and finishes.
        workspace.selection = .event(library.cityID)
        await workspace.refreshEventIfStale(library.cityID)
        XCTAssertEqual(workspace.eventStacks[library.cityID]?.flatMap(\.files).count, 800)
        XCTAssertNil(workspace.eventBuildRemainders[library.cityID])
        }
    }

    func testALoadedBoardIsNotCancelledWhenYouLeaveIt() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        workspace.selection = .event(library.cityID)
        await workspace.refreshEvent(library.cityID)
        let stacks = workspace.eventStacks[library.cityID]
        workspace.selection = .event(library.beachID)
        XCTAssertEqual(workspace.eventStacks[library.cityID], stacks)
        XCTAssertTrue(workspace.isBoardFresh(library.cityID))
        }
    }
}
