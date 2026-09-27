import XCTest
@testable import CameraToolkitApp
@testable import CameraToolkitCore

/// The Jobs window's speed readouts, from synthetic sample streams: the
/// owner saw the Sync to NAS read-rate caption flip to "Reading…" whenever
/// a 1 Hz tick fell between two 4 MB chunks, or while a copy was being
/// flushed, because the old monitor showed the last per-tick delta.
@MainActor
final class JobThroughputTests: XCTestCase {
    private let chunk: Int64 = 4 * 1024 * 1024

    // MARK: - Smoothing

    func testHeldRateSmoothsChunkyCountersInsteadOfDroppingToZero() throws {
        // 2.5 MB/s in 4 MiB chunks: most 1 Hz ticks see no change at all.
        var rate = HeldRate()
        let bytesPerSecond = 2_500_000.0
        var zeroTicks = 0
        var previous: Int64 = -1
        for second in 0...60 {
            let bytes = Int64(Double(second) * bytesPerSecond) / chunk * chunk
            if bytes == previous { zeroTicks += 1 }
            previous = bytes
            rate.observe(Double(bytes), at: Double(second))
            if second > 3 {
                XCTAssertNotNil(rate.value, "never blank once measured (t=\(second))")
            }
        }
        XCTAssertGreaterThan(zeroTicks, 20, "the stream really is chunky")
        XCTAssertEqual(try XCTUnwrap(rate.value), bytesPerSecond, accuracy: bytesPerSecond * 0.2)
    }

    func testAStallHoldsTheValueThenPullsItDownHonestly() throws {
        var rate = HeldRate()
        for second in 0...20 {
            rate.observe(Double(second) * 10_000_000, at: Double(second))
        }
        let steady = try XCTUnwrap(rate.value)
        XCTAssertEqual(steady, 10_000_000, accuracy: 1)

        // A 12 s flush: no bytes. The value is held, and says for how long.
        for second in 21...32 {
            rate.observe(200_000_000, at: Double(second))
            XCTAssertEqual(rate.value, steady, "held, not blanked or decayed")
        }
        XCTAssertEqual(try XCTUnwrap(rate.secondsSinceChange(at: 32)), 12, accuracy: 1e-9)

        // Progress resumes: the gap is part of the measurement, so the rate
        // drops to what the job really managed across the stall.
        rate.observe(210_000_000, at: 33)
        let after = try XCTUnwrap(rate.value)
        XCTAssertLessThan(after, steady * 0.2)
        XCTAssertEqual(rate.secondsSinceChange(at: 33), 0)

        // A counter that restarts is a new baseline, not negative speed.
        rate.observe(0, at: 34)
        XCTAssertEqual(rate.value, after)
    }

    func testMonitorReadoutHoldsAndFadesDuringAStallAndAveragesTheWholeJob() throws {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        var job = JobSnapshot(action: .syncBuffer, state: .running, processedFiles: 0, totalFiles: 50, totalBytes: 2_000_000_000, createdAt: started)
        // 20 s at 12 MB/s, 10 s stalled, 10 s at 12 MB/s again.
        var bytes: Int64 = 0
        for second in 0...40 {
            if !(21...30).contains(second), second > 0 { bytes += 12_000_000 }
            job.processedBytes = bytes
            job.processedFiles = Int(bytes / 40_000_000)
            monitor.tick(job: job, now: Double(second), wallNow: started.addingTimeInterval(Double(second)))
            let readout = monitor.readout(for: job, now: Double(second))
            if second >= 2 {
                XCTAssertNotNil(readout.current, "t=\(second)")
                XCTAssertNotNil(readout.average, "t=\(second)")
            }
            if (24...30).contains(second) {
                XCTAssertTrue(readout.isHeld, "t=\(second)")
                XCTAssertEqual(try XCTUnwrap(readout.current), 12, accuracy: 0.01, "the held value is the last speed")
            }
            if second == 20 {
                XCTAssertFalse(readout.isHeld)
                XCTAssertEqual(try XCTUnwrap(readout.current), 12, accuracy: 0.01)
            }
        }
        let final = monitor.readout(for: job, now: 40)
        XCTAssertFalse(final.isHeld)
        // 360 MB over 40 s.
        XCTAssertEqual(try XCTUnwrap(final.average), 9, accuracy: 0.01)
        XCTAssertNotNil(final.filesPerSecond)
        // The chart shows the stall as a dip — it is a trailing-window rate,
        // not the held readout.
        let dip = final.points.filter { (27...30).contains($0.elapsed) }
        XCTAssertFalse(dip.isEmpty)
        XCTAssertTrue(dip.allSatisfy { $0.value < 1 }, "\(dip)")
        XCTAssertEqual(final.series, ["Throughput"])
    }

    /// The owner's rule: once a job has started, NOW and AVERAGE are always
    /// numbers — through a 10 s gap with no bytes at all and through a
    /// phase change (copies → NAS-side verification) — and only the first
    /// ~2 s may show a placeholder. The primary numbers are the combined
    /// speed of all parallel transfers.
    func testSpeedReadoutStaysNumericThroughAGapAndAPhaseChange() throws {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        var job = JobSnapshot(action: .syncBuffer, state: .running, totalFiles: 40, totalBytes: 4_000_000_000, createdAt: started)
        var transfer: Int64 = 0, remote: Int64 = 0
        var copySeconds = 0.0, remoteSeconds = 0.0
        var beforeGap: Double?
        for tenth in 0...600 {
            let t = Double(tenth) / 10
            switch t {
            case ..<3: break                        // checking the NAS: nothing moves yet
            case ..<20:                             // 4 transfers copying, 25 MB/s each
                transfer += 4 * 2_500_000
                copySeconds += 0.4
            case ..<30: break                       // a 10 s gap: no bytes at all
            case ..<40:                             // the phase changes: NAS-side hashing only
                remote += 50_000_000
                remoteSeconds += 0.1
            default:                                // copies again
                transfer += 4 * 2_500_000
                copySeconds += 0.4
            }
            job.processedBytes = transfer + remote
            job.telemetry = JobTelemetry(
                step: t < 30 || t >= 40 ? "Copying to NAS" : "Hashing on NAS",
                phases: [
                    JobPhaseTotal(label: "Copy", seconds: copySeconds, bytes: transfer, activeSeconds: copySeconds / 4),
                    JobPhaseTotal(label: "Remote verify (NAS)", seconds: remoteSeconds, bytes: remote),
                ].filter { $0.seconds > 0 },
                configuration: "4 transfers in parallel · SSH verify",
                transferBytes: transfer
            )
            monitor.tick(job: job, now: t, wallNow: started.addingTimeInterval(t))
            let readout = monitor.readout(for: job, now: t)
            if t >= JobThroughputTrack.placeholderWindow {
                let current = try XCTUnwrap(readout.current, "NOW blanked at t=\(t)")
                let average = try XCTUnwrap(readout.average, "AVERAGE blanked at t=\(t)")
                for value in [current, average] {
                    let text = JobThroughputFormat.rate(value)
                    XCTAssertNotNil(Double(text.replacingOccurrences(of: ",", with: "")), "not a number at t=\(t): \(text)")
                }
            }
            if t < 21 { beforeGap = readout.current }
            if (25..<30).contains(t) {
                // The gap: the last combined speed is held, not zero, not blank.
                XCTAssertTrue(readout.isHeld, "t=\(t)")
                XCTAssertEqual(readout.current, beforeGap, "t=\(t)")
                XCTAssertGreaterThan(try XCTUnwrap(beforeGap), 90, "the combined speed of 4 × 25 MB/s")
            }
            if (35..<40).contains(t) {
                // NAS-side hashing moves no bytes over the link: the
                // combined transfer speed holds rather than counting it.
                XCTAssertLessThanOrEqual(try XCTUnwrap(readout.current), 101, "t=\(t)")
            }
        }
        let final = monitor.readout(for: job, now: 60)
        XCTAssertEqual(try XCTUnwrap(final.current), 100, accuracy: 5, "back to the combined 4 × 25 MB/s")
        // Everything that crossed the link, over the whole minute.
        XCTAssertEqual(try XCTUnwrap(final.average), Double(transfer) / 60 / 1_000_000, accuracy: 0.5)
        XCTAssertTrue(final.series.contains("Verify (on NAS)"), "\(final.series)")
        // Combined copy speed: bytes over the wall time any transfer copied.
        let copy = final.points.filter { $0.series == "Copy (write)" && $0.elapsed > 45 }.map(\.value)
        XCTAssertFalse(copy.isEmpty)
        XCTAssertTrue(copy.allSatisfy { abs($0 - 100) < 1 }, "\(copy)")
    }

    func testSyncPhasesSplitTheChartIntoCopyAndVerifySeries() throws {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        var job = JobSnapshot(action: .syncBuffer, state: .running, totalBytes: 1_000_000_000)
        var copy: Int64 = 0, verify: Int64 = 0
        var copySeconds = 0.0, flushSeconds = 0.0, verifySeconds = 0.0
        for second in 0...40 {
            // Each 4 s cycle: 1 s copying at 30 MB/s, 2 s flushing, 1 s
            // re-reading at 90 MB/s — shorter than the 5 s chart window.
            if second > 0 {
                switch (second - 1) % 4 {
                case 0: copy += 30_000_000; copySeconds += 1
                case 3: verify += 90_000_000; verifySeconds += 1
                default: flushSeconds += 1
                }
            }
            job.processedBytes = copy + verify
            job.telemetry = JobTelemetry(phases: [
                JobPhaseTotal(label: "Check", seconds: 0.1),
                JobPhaseTotal(label: "Copy", seconds: copySeconds, bytes: copy),
                JobPhaseTotal(label: "Flush", seconds: flushSeconds),
                JobPhaseTotal(label: "Verify", seconds: verifySeconds, bytes: verify),
            ])
            monitor.tick(job: job, now: Double(second))
        }
        let readout = monitor.readout(for: job, now: 40)
        XCTAssertEqual(readout.series, ["Overall", "Copy (write)", "Verify (re-read)"], "only phases that move bytes are lines")
        func values(_ series: String) -> [Double] {
            readout.points.filter { $0.series == series && $0.elapsed >= 10 }.map(\.value)
        }
        // Each phase's line is its speed while running — what to hold
        // against the link ceiling — not diluted by the flushes between.
        XCTAssertFalse(values("Copy (write)").isEmpty)
        XCTAssertTrue(values("Copy (write)").allSatisfy { abs($0 - 30) < 0.01 }, "\(values("Copy (write)"))")
        XCTAssertTrue(values("Verify (re-read)").allSatisfy { abs($0 - 90) < 0.01 }, "\(values("Verify (re-read)"))")
        // Overall: 120 MB per 4 s.
        let overall = values("Overall")
        XCTAssertEqual(overall.reduce(0, +) / Double(overall.count), 30, accuracy: 4)
    }

    // MARK: - Scale

    func testChartScaleStaysPutThroughASpike() {
        var scale = StableScale()
        scale.update(visibleMax: 42)
        XCTAssertEqual(scale.upper, 50)
        scale.update(visibleMax: 38)
        XCTAssertEqual(scale.upper, 50, "small wobbles do not rescale")
        scale.update(visibleMax: 90)
        XCTAssertEqual(scale.upper, 200, "growing is immediate — no clipped line")
        scale.update(visibleMax: 60)
        XCTAssertEqual(scale.upper, 200, "the spike's room is kept while data is in the same range")
        scale.update(visibleMax: 5)
        XCTAssertEqual(scale.upper, 10, "a far lower range does shrink the axis")
        // A known link ceiling stays on the chart.
        scale.update(visibleMax: 5, floor: 115 * 1.1)
        XCTAssertEqual(scale.upper, 200)

        XCTAssertEqual(StableScale.nice(0.3), 0.5)
        XCTAssertEqual(StableScale.nice(1), 1)
        XCTAssertEqual(StableScale.nice(2.2), 2.5)
        XCTAssertEqual(StableScale.nice(126.5), 200)
        XCTAssertEqual(StableScale.nice(0), 1)
    }

    // MARK: - Ceiling

    func testLinkCeilingComesFromTheSpeedTestsLinkDetection() throws {
        let gigabit = StorageLinkInspector.networkContext(
            host: "nas.local", interfaceName: "en7", interfaceHardwareName: "USB 10/100/1G/2.5G LAN",
            mediaMegabitsPerSecond: 1_000, wifiMegabitsPerSecond: nil
        )
        let ceiling = try XCTUnwrap(JobLinkCeiling.from(gigabit))
        XCTAssertEqual(ceiling.label, "1 GbE")
        XCTAssertEqual(ceiling.megabytesPerSecond, 115)
        XCTAssertEqual(ceiling.caption, "1 GbE ≈ 115 MB/s")

        let twoFive = try XCTUnwrap(JobLinkCeiling.from(StorageLinkInspector.networkContext(
            host: nil, interfaceName: "en7", interfaceHardwareName: nil, mediaMegabitsPerSecond: 2_500, wifiMegabitsPerSecond: nil
        )))
        XCTAssertEqual(twoFive.label, "2.5 GbE")
        XCTAssertEqual(twoFive.megabytesPerSecond, 290)

        let wifi = try XCTUnwrap(JobLinkCeiling.from(StorageLinkInspector.networkContext(
            host: nil, interfaceName: "en0", interfaceHardwareName: "Wi-Fi", mediaMegabitsPerSecond: nil, wifiMegabitsPerSecond: 866
        )))
        XCTAssertTrue(wifi.label.hasPrefix("Wi-Fi 866"), wifi.label)

        // An undetected link is a guess: no dashed line.
        XCTAssertNil(JobLinkCeiling.from(StorageLinkInspector.networkContext(
            host: nil, interfaceName: nil, interfaceHardwareName: nil, mediaMegabitsPerSecond: nil, wifiMegabitsPerSecond: nil
        )))
    }

    func testCeilingReachesTheReadoutAndTheScale() {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        var job = JobSnapshot(action: .syncBuffer, state: .running, totalBytes: 1_000_000_000)
        monitor.setCeiling(JobLinkCeiling(label: "1 GbE", megabytesPerSecond: 115), for: job.id)
        for second in 0...5 {
            job.processedBytes = Int64(second) * 8_000_000
            monitor.tick(job: job, now: Double(second))
        }
        let readout = monitor.readout(for: job, now: 5)
        XCTAssertEqual(readout.ceiling?.megabytesPerSecond, 115)
        XCTAssertGreaterThanOrEqual(readout.yUpper, 115 * 1.1)
    }

    // MARK: - Formatting

    func testRatesFormatToAStableShape() {
        XCTAssertEqual(JobThroughputFormat.rate(12.44), "12.4")
        XCTAssertEqual(JobThroughputFormat.rate(9.8), "9.8")
        XCTAssertEqual(JobThroughputFormat.rate(0), "0.0")
        XCTAssertEqual(JobThroughputFormat.rate(-3), "0.0")
        XCTAssertEqual(JobThroughputFormat.rate(115.4), "115")
        XCTAssertEqual(JobThroughputFormat.rate(1_234), 1_234.formatted())
        XCTAssertEqual(JobThroughputFormat.rate(.infinity), JobThroughputFormat.placeholder)
        XCTAssertEqual(JobThroughputFormat.itemRate(0.25), "0.25")
        XCTAssertEqual(JobThroughputFormat.itemRate(3.14), "3.1")
        XCTAssertEqual(JobThroughputFormat.itemRate(412.2), "412")
        XCTAssertEqual(JobThroughputFormat.megabytes(12_400_000), 12.4, accuracy: 1e-12)

        let shares = JobTelemetry.shares(of: [
            JobPhaseTotal(label: "Copy", seconds: 30),
            JobPhaseTotal(label: "Flush", seconds: 40),
            JobPhaseTotal(label: "Verify", seconds: 25),
            JobPhaseTotal(label: "Rename", seconds: 5),
        ])
        XCTAssertEqual(PhaseBreakdown.summary(shares), "Copy 30% · Flush 40% · Verify 25% · Rename 5%")
        XCTAssertEqual(ThroughputChart.axisNumber(2.5), "2.5")
        XCTAssertEqual(ThroughputChart.axisNumber(50), "50")
    }
}
