import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// Timings of one 15-burst Move to Event in a library of real size, stage by
/// stage. Opt-in — it is a measuring tool, not a gate (the budgets that gate
/// a change live in `EventMoveLatencyTests`):
/// `BENCH_MOVES=1 [BENCH_NAS_DELAY_US=1000] swift test --filter EventMoveBenchmarkTests 2>&1 | grep BENCH`.
/// Add `-c release -Xswiftc -enable-testing` for optimized numbers.
@MainActor
final class EventMoveBenchmarkTests: XCTestCase {
    private func seconds(_ since: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - since
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func ms(_ value: Double) -> String { String(format: "%.1f ms", value * 1_000) }

    func testFifteenBurstMoveInARealisticLibrary() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BENCH_MOVES"] != nil, "Set BENCH_MOVES=1 to run the move benchmark.")
        let library = try MoveLibrary.make()
        defer { library.tearDown() }
        let workspace = library.workspace
        let model = library.model
        let env = ProcessInfo.processInfo.environment
        let nasDelay = UInt32(env["BENCH_NAS_DELAY_US"] ?? "0") ?? 0
        let probe = MovePresenceProbe(nasRoot: workspace.locations.nasRoot.path, nasDelayMicroseconds: nasDelay)
        workspace.presenceProbe = probe.probe
        print("BENCH library: \(library.shape.total) assignments, family \(library.shape.family), NAS stat delay \(nasDelay) µs")

        // Open the boards a user would have visited: the parent (whole
        // family), the subevent the bursts leave, and the one they join.
        var clock = ContinuousClock.now
        for id in [library.parentID, library.islandID, library.harborID] {
            await workspace.refreshEvent(id)
        }
        print("BENCH open three boards (refresh + sweeps): \(ms(seconds(clock))) · stacks parent \(workspace.eventStacks[library.parentID]?.count ?? -1), island \(workspace.eventStacks[library.islandID]?.count ?? -1), harbor \(workspace.eventStacks[library.harborID]?.count ?? -1) · NAS stats so far \(probe.nasStats)")

        let selection = library.bursts(in: library.islandID, count: 15)
        XCTAssertEqual(selection.count, 15)
        let fileCount = selection.flatMap(\.files).count
        let statsBefore = probe.nasStats
        let monitor = MainStallMonitor()
        monitor.start()
        try await Task.sleep(for: .milliseconds(50))

        // Stage 1: the click. Everything `moveStacks` does before it
        // returns runs on the main actor.
        clock = ContinuousClock.now
        let clicked = clock
        workspace.moveStacks(Set(selection.map(\.id)), fromEvent: library.islandID, toEvent: library.harborID)
        let click = seconds(clicked)
        let jobStarted = model.isBusy
        print("BENCH click -> moveStacks returned (main actor): \(ms(click)) · job started: \(jobStarted) · \(selection.count) bursts, \(fileCount) files · status: \(model.statusMessage)")
        let paintedOnClick = workspace.eventStacks[library.islandID]?.count

        // Stage 2: the rename job, its completion, the catalog write.
        clock = ContinuousClock.now
        try await waitUntil { !model.isBusy }
        print("BENCH job start -> done (rename + completion callback): \(ms(seconds(clock)))")
        let afterJob = ContinuousClock.now

        // Stage 3: the refreshes the completion queues.
        var lastCalls = -1
        var quietSince = ContinuousClock.now
        while seconds(quietSince) < 0.5 {
            try await Task.sleep(for: .milliseconds(25))
            let busy = [library.parentID, library.islandID, library.harborID].contains { workspace.isCheckingFiles(for: $0) }
            if probe.total != lastCalls || busy {
                lastCalls = probe.total
                quietSince = ContinuousClock.now
            }
        }
        let settle = seconds(afterJob) - 0.5
        let stalls = monitor.stop()
        print("BENCH job done -> refreshes settled: \(ms(settle)) · NAS stats during move: \(probe.nasStats - statsBefore)")
        print("BENCH main-actor stalls >= 8 ms: \(stalls.count) · longest \(stalls.prefix(5).map { ms($0.duration) + " @" + String(format: "%.2fs", $0.startedAt) }.joined(separator: ", ")) · total \(ms(stalls.reduce(0) { $0 + $1.duration }))")
        print("BENCH island stacks: before click \(paintedOnClick ?? -1) (was \(library.shape.island)-file board), final \(workspace.eventStacks[library.islandID]?.count ?? -1); harbor final \(workspace.eventStacks[library.harborID]?.count ?? -1); parent final \(workspace.eventStacks[library.parentID]?.count ?? -1)")
        XCTAssertTrue(jobStarted)
    }

    private func waitUntil(timeout: TimeInterval = 120, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
