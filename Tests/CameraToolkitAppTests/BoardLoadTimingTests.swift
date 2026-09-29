import AppKit
import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// First-tile and board-switch timings at the sizes the app is used at.
/// The numbers are printed (`TIMING|…`) so a run can be compared before and
/// after a change; the assertions are generous budgets that only catch a
/// regression back to blocking work.
@MainActor
final class BoardLoadTimingTests: XCTestCase {
    struct Sample {
        var firstTilesMs: Double
        var sawEmptyGrid: Bool
    }

    private static func ms(_ seconds: Double) -> Double { (seconds * 10_000).rounded() / 10 }

    /// Opens `eventID` and returns how long until its board has tiles, and
    /// whether the board ever published an empty grid on the way.
    private func firstTiles(_ library: MoveLibrary, _ eventID: UUID, timeout: TimeInterval = 60) async throws -> Sample {
        let workspace = library.workspace
        let start = ProcessInfo.processInfo.systemUptime
        let refresh = Task { await workspace.refreshEvent(eventID) }
        var sawEmpty = false
        while true {
            if let stacks = workspace.eventStacks[eventID] {
                if stacks.isEmpty { sawEmpty = true } else { break }
            }
            guard ProcessInfo.processInfo.systemUptime - start < timeout else {
                XCTFail("no tiles after \(timeout) s")
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        await refresh.value
        return Sample(firstTilesMs: Self.ms(elapsed), sawEmptyGrid: sawEmpty)
    }

    /// A NAS root that does not answer for `seconds`, the way a hung SMB
    /// share does; everything else answers at once.
    private func hangNASRoot(_ library: MoveLibrary, seconds: UInt32 = 4) {
        let nas = library.workspace.locations.nasRoot.path
        library.workspace.placeResponseProbe = { url in
            if url.path == nas { sleep(seconds) }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private func report(_ label: String, _ cold: Sample, _ warm: Sample) {
        print("TIMING|\(label)|cold=\(cold.firstTilesMs)ms|warm=\(warm.firstTilesMs)ms|emptyGridSeen=\(cold.sawEmptyGrid)")
    }

    /// Cold = first open in the process; warm = the same board opened again
    /// from scratch (grid dropped, caches kept).
    private func coldAndWarm(_ library: MoveLibrary, _ eventID: UUID) async throws -> (Sample, Sample) {
        let cold = try await firstTiles(library, eventID)
        library.workspace.eventStacks[eventID] = nil
        let warm = try await firstTiles(library, eventID)
        return (cold, warm)
    }

    func testFirstTilesSmallEventNASAnswering() async throws {
        let library = try MoveLibrary.make(MoveLibrary.Shape(parentOwn: 200, harbor: 0, island: 0, road: 0, elsewhere: 0, catalogBacked: false))
        defer { library.tearDown() }
        try library.model.configurationStore.save(library.model.configuration)
        let (cold, warm) = try await coldAndWarm(library, library.parentID)
        report("200 files, NAS answering", cold, warm)
        XCTAssertLessThan(cold.firstTilesMs, 5_000)
    }

    func testFirstTilesSmallEventNASHung() async throws {
        let library = try MoveLibrary.make(MoveLibrary.Shape(parentOwn: 200, harbor: 0, island: 0, road: 0, elsewhere: 0, catalogBacked: false))
        defer { library.tearDown() }
        try library.model.configurationStore.save(library.model.configuration)
        hangNASRoot(library)
        let (cold, warm) = try await coldAndWarm(library, library.parentID)
        report("200 files, NAS root hung", cold, warm)
    }

    func testFirstTilesFifteenThousandOneEvent() async throws {
        let library = try MoveLibrary.make(MoveLibrary.Shape(parentOwn: 15_000, harbor: 0, island: 0, road: 0, elsewhere: 0, catalogBacked: false))
        defer { library.tearDown() }
        try library.model.configurationStore.save(library.model.configuration)
        let (cold, warm) = try await coldAndWarm(library, library.parentID)
        report("15k files one event, NAS answering", cold, warm)
        hangNASRoot(library)
        let (hungCold, hungWarm) = try await coldAndWarm(library, library.parentID)
        report("15k files one event, NAS root hung", hungCold, hungWarm)
    }

    func testFirstTilesFamilyWithNoFilesOfItsOwn() async throws {
        let library = try MoveLibrary.make(MoveLibrary.Shape(parentOwn: 0, harbor: 5_000, island: 5_000, road: 5_000, elsewhere: 0, catalogBacked: false))
        defer { library.tearDown() }
        try library.model.configurationStore.save(library.model.configuration)
        let (cold, warm) = try await coldAndWarm(library, library.parentID)
        report("family: parent 0 files + 3x5000", cold, warm)
    }

    /// Where a switch spends its main-actor time: the selection write, the
    /// SwiftUI update it triggers, and the run-loop turns after it.
    func testSwitchBreakdown() async throws {
        let library = try MoveLibrary.make(MoveLibrary.Shape(parentOwn: 9_000, harbor: 3_000, island: 3_000, road: 160, elsewhere: 300, catalogBacked: false))
        defer { library.tearDown() }
        try library.model.configurationStore.save(library.model.configuration)
        let workspace = library.workspace
        for id in [library.parentID, library.elsewhereID] { await workspace.refreshEvent(id) }
        let window = SnapshotWindows.main(model: library.model, workspace: workspace)
        defer { window.orderOut(nil); window.close() }
        window.setContentSize(NSSize(width: 1320, height: 840))
        func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }
        func step(_ label: String, _ id: UUID?) async {
            let t0 = ProcessInfo.processInfo.systemUptime
            let c0 = cpu()
            workspace.selection = id.map { .event($0) }
            let t1 = ProcessInfo.processInfo.systemUptime
            window.contentView?.layoutSubtreeIfNeeded()
            let t2 = ProcessInfo.processInfo.systemUptime
            let c2 = cpu()
            try? await Task.sleep(for: .seconds(0.25))
            let c3 = cpu()
            print("TIMING|breakdown \(label): write \(Self.ms(t1 - t0)) ms, layout wall \(Self.ms(t2 - t1)) ms, main-thread CPU in switch \(Self.ms(c2 - c0)) ms, CPU in the 250 ms after \(Self.ms(c3 - c2)) ms")
        }
        await step("welcome -> small", library.elsewhereID)
        await step("small -> family15k", library.parentID)
        await step("family15k -> small", library.elsewhereID)
        await step("small -> family15k", library.parentID)
        await step("family15k -> welcome", nil)
        await step("welcome -> family15k", library.parentID)
        await step("family15k -> small", library.elsewhereID)
        await step("small -> small (again)", library.elsewhereID)
    }

    // MARK: - Switching boards in the real window

    /// Selecting an already-loaded board: the longest time the main actor
    /// was blocked between the click and the new board settling, and the
    /// main-actor time the whole switch took.
    func testSwitchTimingsInTheMainWindow() async throws {
        let library = try MoveLibrary.make(MoveLibrary.Shape(parentOwn: 9_000, harbor: 3_000, island: 3_000, road: 160, elsewhere: 300, catalogBacked: false))
        defer { library.tearDown() }
        try library.model.configurationStore.save(library.model.configuration)
        let workspace = library.workspace
        for id in [library.parentID, library.elsewhereID, library.roadID] { await workspace.refreshEvent(id) }
        let window = SnapshotWindows.main(model: library.model, workspace: workspace)
        defer { window.orderOut(nil); window.close() }
        window.setContentSize(NSSize(width: 1320, height: 840))

        let monitor = MainStallMonitor()
        func switchTo(_ id: UUID, label: String) async {
            monitor.start()
            let start = ProcessInfo.processInfo.systemUptime
            workspace.selection = .event(id)
            window.contentView?.layoutSubtreeIfNeeded()
            let synchronous = ProcessInfo.processInfo.systemUptime - start
            try? await Task.sleep(for: .seconds(0.3))
            let stalls = monitor.stop()
            let total = stalls.reduce(0) { $0 + $1.duration }
            print("TIMING|switch \(label)|syncMs=\(Self.ms(synchronous))|longestStallMs=\(Self.ms(stalls.first?.duration ?? 0))|totalStallMs=\(Self.ms(total))")
        }
        // First time on each board this session, then back and forth.
        await switchTo(library.elsewhereID, label: "to small board (first)")
        await switchTo(library.parentID, label: "to 15k family board (first)")
        try await Task.sleep(for: .milliseconds(300))
        await switchTo(library.elsewhereID, label: "to small board (loaded)")
        try await Task.sleep(for: .milliseconds(300))
        await switchTo(library.parentID, label: "to 15k family board (loaded)")
        try await Task.sleep(for: .milliseconds(300))
        await switchTo(library.roadID, label: "to 160-file board (loaded)")
    }
}
