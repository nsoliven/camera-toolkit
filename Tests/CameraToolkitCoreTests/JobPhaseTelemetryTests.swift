import Foundation
@testable import CameraToolkitCore
import XCTest

/// A monotonic test clock that advances a fixed step on every read, so each
/// timed phase takes measurable time without sleeping.
private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    let step: TimeInterval

    init(step: TimeInterval) { self.step = step }

    func read() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        value += step
        return value
    }
}

final class JobPhaseTelemetryTests: XCTestCase {
    // MARK: - Timer

    func testTimerAccumulatesPhasesAndCountsTheRunningOne() {
        var timer = JobPhaseTimer(order: ["Copy", "Flush", "Verify", "Rename"])
        timer.begin("Copy", at: 0)
        timer.addBytes(40)
        timer.begin("Copy", at: 1) // same phase: keeps running, no restart
        timer.addBytes(60)
        timer.begin("Flush", at: 3)
        timer.begin("Verify", at: 7)
        timer.addBytes(100)

        // Snapshot mid-verify: the running phase's time so far is included,
        // unused phases (Rename) are left out.
        let live = timer.snapshot(at: 9)
        XCTAssertEqual(live.map(\.label), ["Copy", "Flush", "Verify"])
        XCTAssertEqual(live.map(\.seconds), [3, 4, 2])
        XCTAssertEqual(live.map(\.bytes), [100, 0, 100])
        XCTAssertEqual(timer.current, "Verify")

        timer.begin("Rename", at: 10)
        timer.end(at: 10.5)
        timer.addBytes(999) // between phases: ignored
        let done = timer.snapshot(at: 50)
        XCTAssertEqual(done.map(\.seconds), [3, 4, 3, 0.5])
        XCTAssertEqual(done.map(\.bytes), [100, 0, 100, 0])
        XCTAssertNil(timer.current)
        XCTAssertEqual(done[0].bytesPerSecond ?? 0, 100.0 / 3, accuracy: 1e-9)
        XCTAssertNil(done[1].bytesPerSecond)
    }

    func testTimerAppendsPhasesItWasNotToldAbout() {
        var timer = JobPhaseTimer(order: ["Copy"])
        timer.begin("Upload", at: 0)
        timer.end(at: 2)
        XCTAssertEqual(timer.snapshot(at: 2).map(\.label), ["Upload"])
    }

    // MARK: - Breakdown

    func testPhaseSharesSumToOneAndToExactlyOneHundredPercent() {
        let thirds = JobTelemetry.shares(of: [
            JobPhaseTotal(label: "Copy", seconds: 1),
            JobPhaseTotal(label: "Flush", seconds: 1),
            JobPhaseTotal(label: "Verify", seconds: 1),
        ])
        XCTAssertEqual(thirds.map(\.percent).reduce(0, +), 100)
        XCTAssertEqual(thirds.map(\.percent), [34, 33, 33])
        XCTAssertEqual(thirds.map(\.fraction).reduce(0, +), 1, accuracy: 1e-12)

        let owner = JobTelemetry(phases: [
            JobPhaseTotal(label: "Copy", seconds: 30, bytes: 300_000_000),
            JobPhaseTotal(label: "Flush", seconds: 40),
            JobPhaseTotal(label: "Verify", seconds: 25, bytes: 300_000_000),
            JobPhaseTotal(label: "Rename", seconds: 5),
            JobPhaseTotal(label: "Hash", seconds: 0),
        ]).phaseShares
        XCTAssertEqual(owner.map(\.label), ["Copy", "Flush", "Verify", "Rename"], "unmeasured phases are left out")
        XCTAssertEqual(owner.map(\.percent), [30, 40, 25, 5])
        XCTAssertEqual(owner[0].bytesPerSecond ?? 0, 10_000_000, accuracy: 1e-6)
        XCTAssertEqual(owner[2].bytesPerSecond ?? 0, 12_000_000, accuracy: 1e-6)

        // Awkward splits still add up.
        let odd = JobTelemetry.shares(of: [0.7, 2.9, 0.05, 11.3, 0.001].enumerated().map {
            JobPhaseTotal(label: "P\($0.offset)", seconds: $0.element)
        })
        XCTAssertEqual(odd.map(\.percent).reduce(0, +), 100)
        XCTAssertEqual(odd.map(\.fraction).reduce(0, +), 1, accuracy: 1e-12)

        XCTAssertTrue(JobTelemetry.shares(of: []).isEmpty)
        XCTAssertTrue(JobTelemetry.shares(of: [JobPhaseTotal(label: "Copy", seconds: 0)]).isEmpty)
    }

    func testTelemetryFromOlderBuildsDecodesWithoutPhases() throws {
        let json = #"{"activeItems":[],"counters":[{"label":"Faces","value":2}],"models":[],"facts":[]}"#
        let decoded = try JSONDecoder().decode(JobTelemetry.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.counter("Faces"), 2)
        XCTAssertTrue(decoded.phases.isEmpty)

        let current = JobTelemetry(step: "Copy", phases: [JobPhaseTotal(label: "Copy", seconds: 1.5, bytes: 9)])
        let roundTrip = try JSONDecoder().decode(JobTelemetry.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(roundTrip, current)
    }

    // MARK: - Parallel ledger

    /// Two lanes in Copy at once count twice toward busy time but once
    /// toward the wall time the phase was running.
    func testLedgerSumsBusyTimeOverLanesAndKeepsWallTimeApart() {
        var ledger = JobPhaseLedger(order: ["Copy", "Flush", "Verify"])
        ledger.begin("Copy", lane: 0, at: 0)
        ledger.begin("Copy", lane: 1, at: 1)
        ledger.addBytes(300, to: "Copy")
        ledger.begin("Verify", lane: 0, at: 4) // lane 0: Copy 0...4
        ledger.end(lane: 1, at: 5)             // lane 1: Copy 1...5
        ledger.addBytes(100, to: "Verify")

        let live = ledger.snapshot(at: 6)      // lane 0 still verifying
        XCTAssertEqual(live.map(\.label), ["Copy", "Verify"], "Flush never ran: left out")
        XCTAssertEqual(live[0].seconds, 8, "busy time: 4 s on each lane")
        XCTAssertEqual(live[0].activeSeconds, 5, "wall time any lane was copying: 0...5")
        XCTAssertEqual(live[0].bytesPerSecond ?? 0, 60, accuracy: 1e-9, "combined copy speed over the wall time")
        XCTAssertEqual(live[1].seconds, 2)
        XCTAssertEqual(ledger.current(lane: 0), "Verify")
        XCTAssertNil(ledger.current(lane: 1))

        ledger.end(lane: 0, at: 7)
        let done = ledger.snapshot(at: 99)
        XCTAssertEqual(done.map(\.seconds), [8, 3])
        XCTAssertEqual(done.map(\.activeSeconds), [5, 3])
        let shares = JobTelemetry.shares(of: done)
        XCTAssertEqual(shares.map(\.percent), [73, 27])
        XCTAssertEqual(shares.map(\.percent).reduce(0, +), 100)
    }

    // MARK: - Per-transfer rate

    /// A row's speed is steady through chunky 4 MB counters, samples at
    /// most ~4 times a second, holds across a reused row, and still
    /// follows a real slowdown.
    func testTransferRateMeterSmoothsChunkyCountersAndFollowsRealChanges() {
        var meter = TransferRateMeter()
        XCTAssertNil(meter.bytesPerSecond)
        let chunk: Int64 = 4_194_304
        var moved: Int64 = 0
        var readings: [Double] = []
        // 40 MB/s on average, arriving as whole chunks at 0.1 s ticks.
        var owed = 0.0
        for tick in 0...300 {
            let t = Double(tick) * 0.1
            owed += 4_000_000
            while owed >= Double(chunk) {
                moved += chunk
                owed -= Double(chunk)
            }
            meter.record(moved, at: t)
            if t >= 10, let rate = meter.bytesPerSecond { readings.append(rate) }
        }
        let settled = readings.map { $0 / 1_000_000 }
        XCTAssertEqual(settled.reduce(0, +) / Double(settled.count), 40, accuracy: 2)
        // Raw samples swing by a whole 4 MB chunk per interval; the meter does not.
        XCTAssertLessThan((settled.max() ?? 0) - (settled.min() ?? 0), 20, "\(settled.min() ?? 0)...\(settled.max() ?? 0)")

        // Reads closer together than the interval do not move it.
        meter.record(moved, at: 40)
        let before = meter.bytesPerSecond
        meter.record(moved + 50 * chunk, at: 40.1)
        XCTAssertEqual(meter.bytesPerSecond, before)

        // A slowdown to 10 MB/s is followed within a few time constants,
        // and the value never blanks on the way.
        var count = moved
        for tick in 1...40 {
            count += 2_500_000
            meter.record(count, at: 40 + Double(tick) * 0.25)
            XCTAssertNotNil(meter.bytesPerSecond)
        }
        XCTAssertEqual((meter.bytesPerSecond ?? 0) / 1_000_000, 10, accuracy: 1)
    }

    // MARK: - Sync job

    /// Sync to NAS times every phase of every file and credits each byte to
    /// the phase that moved it: a copy's bytes to Copy, the NAS re-read's
    /// to Verify, with Flush and Rename timed on their own. The legacy
    /// engine (one transfer, a flush per file) is the one that flushes.
    func testSyncReportsPerPhaseTimeAndBytes() throws {
        try withTemporaryDirectory { root in
            let drive = root.appendingPathComponent("Drive", isDirectory: true)
            let nas = root.appendingPathComponent("NAS", isDirectory: true)
            try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
            let sizes = [3 * 1024 * 1024, 5 * 1024 * 1024 + 7]
            var items: [NASSyncItem] = []
            for (index, size) in sizes.enumerated() {
                let url = try writeFile(drive.appendingPathComponent("Event/Originals/Cam/F\(index).ARW"), Data(repeating: UInt8(index + 1), count: size))
                let modified = try XCTUnwrap(LayoutMigrationDisk.lstatEntry(url.path)).modifiedAt
                items.append(NASSyncItem(
                    sourcePath: url.path,
                    relativePath: "Event/Originals/Cam/F\(index).ARW",
                    byteCount: Int64(size),
                    modifiedAt: modified,
                    eventID: nil
                ))
            }
            let plan = NASSyncPlan(items: items, outsideLayout: [], skippedJunk: 0, refused: [], unreadable: [])
            let recorder = ProgressRecorder()
            let clock = SteppingClock(step: 0.01)
            let report = try NASSyncService(store: nil, options: .legacy, clock: { clock.read() }).sync(plan, nasRoot: nas, progress: recorder.handler)
            XCTAssertEqual(report.copied.count, 2, "\(report)")

            let updates = recorder.updates
            let last = try XCTUnwrap(updates.last?.telemetry)
            let byLabel = Dictionary(uniqueKeysWithValues: last.phases.map { ($0.label, $0) })
            let total = Int64(sizes.reduce(0, +))
            XCTAssertEqual(byLabel["Copy"]?.bytes, total)
            XCTAssertEqual(byLabel["Verify"]?.bytes, total)
            for label in ["Check", "Copy", "Flush", "Verify", "Rename"] {
                XCTAssertGreaterThan(byLabel[label]?.seconds ?? 0, 0, label)
            }
            XCTAssertNil(byLabel["Hash"], "no drive copy was hashed on its own")
            XCTAssertNil(byLabel[NASSyncRun.remoteVerifyPhase], "verified over SMB")
            // Every byte of work is attributed to exactly one phase.
            XCTAssertEqual(last.phases.reduce(Int64(0)) { $0 + $1.bytes }, updates.last?.processedBytes)
            XCTAssertEqual(last.phaseShares.map(\.percent).reduce(0, +), 100)
            XCTAssertEqual(last.configuration, "1 transfer in parallel · SMB verify · flush per file")
            // The legacy engine's own timings agree that it flushed.
            XCTAssertGreaterThan(report.timings.flushSeconds, 0)
        }
    }
}
