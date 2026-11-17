import XCTest
@testable import CameraToolkitApp
@testable import CameraToolkitCore

@MainActor
final class JobActivityMonitorTests: XCTestCase {
    // MARK: - CPU/GPU probes

    func testCPUFractionMeasuresBusyTicksBetweenSamples() {
        let earlier = SystemLoadProbe.CPUTicks(user: 100, system: 50, idle: 1_000, nice: 0)
        let later = SystemLoadProbe.CPUTicks(user: 180, system: 90, idle: 1_020, nice: 0)

        // Δbusy = 120, Δidle = 20 → 120/140.
        let fraction = SystemLoadProbe.cpuFraction(between: earlier, and: later)
        XCTAssertEqual(try XCTUnwrap(fraction), 120.0 / 140.0, accuracy: 0.001)

        // Non-monotonic or identical samples are no reading at all.
        XCTAssertNil(SystemLoadProbe.cpuFraction(between: later, and: earlier))
        XCTAssertNil(SystemLoadProbe.cpuFraction(between: earlier, and: earlier))
    }

    func testHardwareProbesAnswerOrSayNil() {
        // host_statistics is always available on macOS.
        XCTAssertNotNil(SystemLoadProbe.cpuTicks())

        // GPU utilization is legitimately nil when the driver reports
        // nothing — the pane shows "n/a" for it. If it does report, the
        // value is a real fraction.
        if let gpu = SystemLoadProbe.gpuFraction() {
            XCTAssertTrue((0...1).contains(gpu))
        }
    }

    // MARK: - Monitor

    func testMonitorTurnsByteDeltasIntoAReadout() {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        let job = JobSnapshot(
            action: .ingestCard,
            state: .running,
            processedBytes: 0,
            totalBytes: 1_000_000
        )
        monitor.tick(job: job, now: 0, wallNow: job.createdAt)
        XCTAssertNil(monitor.readout(for: job, now: 0).current, "the first tick only sets the baseline")

        var moved = job
        moved.processedBytes = 500_000
        monitor.tick(job: moved, now: 1, wallNow: job.createdAt.addingTimeInterval(1))
        let readout = monitor.readout(for: moved, now: 1)
        XCTAssertEqual(try XCTUnwrap(readout.current), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(readout.average), 0.5, accuracy: 1e-9)
        XCTAssertEqual(readout.points.map(\.value), [0.5])
        XCTAssertNotNil(monitor.estimatedRemaining(for: moved))
    }

    func testANewJobGetsItsOwnTrackAndDoesNotResetTheRunningOne() {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        var first = JobSnapshot(action: .syncBuffer, state: .running, processedBytes: 1_000_000, totalBytes: 10_000_000)
        let second = JobSnapshot(action: .ingestCard, state: .running, processedBytes: 0, totalBytes: 5_000_000)
        monitor.tick(job: first, now: 0)
        // Two expanded rows tick the same monitor in turn — the old
        // monitor wiped its history on every switch.
        monitor.tick(job: second, now: 0.1)
        first.processedBytes = 3_000_000
        monitor.tick(job: first, now: 1)
        monitor.tick(job: second, now: 1.1)
        XCTAssertEqual(monitor.readout(for: first, now: 1).points.count, 1)
        XCTAssertEqual(try XCTUnwrap(monitor.readout(for: first, now: 1).current), 2, accuracy: 1e-9)
        XCTAssertNil(monitor.readout(for: second, now: 1.1).current)
    }

    func testMonitorStopsSamplingFinishedJobs() {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        var job = JobSnapshot(
            action: .faceScan,
            state: .running,
            processedBytes: 100,
            totalBytes: 1_000
        )
        monitor.tick(job: job, now: 0)
        job.state = .done
        job.processedBytes = 1_000
        monitor.tick(job: job, now: 1)
        XCTAssertTrue(monitor.readout(for: job, now: 1).points.isEmpty, "a finished job is not sampled")
        XCTAssertNil(monitor.readout(for: job, now: 1).current, "a finished job has no current speed")
        XCTAssertNil(monitor.estimatedRemaining(for: job))
    }

    // MARK: - DashboardModel passthrough

    /// The existing progress channel forwards telemetry into the job
    /// update — no second mechanism.
    func testJobUpdateForwardsTelemetry() {
        let telemetry = JobTelemetry(
            step: "Embed",
            counters: [JobCounter(label: "Faces", value: 3)]
        )
        let update = FileOperationProgress(
            phase: "Detecting faces",
            processedFiles: 1,
            totalFiles: 2,
            telemetry: telemetry
        )
        let jobUpdate = DashboardModel.jobUpdate(
            from: update,
            notePrefix: "Face scan",
            command: "scan"
        )
        XCTAssertEqual(jobUpdate.telemetry, telemetry)
    }

    func testJobSnapshotStoresTelemetryFromUpdates() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobActivityMonitorTests-\(UUID().uuidString)")
        let job = JobSnapshot(action: .faceScan, state: .running)
        let model = DashboardModel(
            jobs: [job],
            configuration: AppConfiguration(
                demoRootPath: scratch.path,
                importSourcePath: scratch.appendingPathComponent("Card").path,
                archivePath: scratch.appendingPathComponent("Archive").path,
                bufferPath: scratch.appendingPathComponent("Buffer").path,
                activityLogPath: scratch.appendingPathComponent("activity.jsonl").path
            ),
            configurationStore: ConfigurationStore(
                url: scratch.appendingPathComponent("config.json")
            )
        )

        let telemetry = JobTelemetry(step: "Match", counters: [JobCounter(label: "Faces", value: 9)])
        model.updateJob(
            id: job.id,
            update: BackgroundJobUpdate(
                progress: 0.5,
                note: "Face scan: Matching people",
                telemetry: telemetry
            )
        )
        XCTAssertEqual(model.jobs.first?.telemetry, telemetry)
    }

    // MARK: - Graded render (frames)

    private func renderJob(step: String, frame: Int, total: Int?, done: Int, rate: Double? = 30, clip: Int = 1, of clips: Int = 1) -> JobSnapshot {
        JobSnapshot(
            id: renderID,
            action: .gradeRender,
            state: .running,
            progress: 0.1,
            note: "Stabilizing 1 of 1 · C0001.MP4 · frame \(frame) of \(total ?? 0)",
            processedFiles: clip - 1,
            totalFiles: clips,
            telemetry: JobTelemetry(frames: JobFrameProgress(
                step: step, steps: ["Stabilize", "Grade"], frame: frame, totalFrames: total,
                framesDone: done, videoFrameRate: rate, clipIndex: clip, clipCount: clips
            )),
            createdAt: renderStart
        )
    }

    private let renderID = UUID()
    private let renderStart = Date(timeIntervalSince1970: 1_790_000_000)

    /// The Jobs window's card for a render: frames/s now and on average,
    /// × realtime, the time left in the running step — never 0.00 files/s.
    func testARenderReadsInFramesPerSecondWithTimeLeftInItsStep() {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        XCTAssertEqual(JobActivityMonitor.throughputUnit(renderJob(step: "Stabilize", frame: 0, total: nil, done: 0)), .framesPerSecond)
        // Gyroflow at 15 frames a second on a 30 fps clip of 3,000 frames.
        for second in 0...10 {
            let job = renderJob(step: "Stabilize", frame: second * 15, total: 3_000, done: second * 15)
            monitor.tick(job: job, now: Double(second), wallNow: renderStart.addingTimeInterval(Double(second)))
        }
        let job = renderJob(step: "Stabilize", frame: 150, total: 3_000, done: 150)
        let readout = monitor.readout(for: job, now: 10)
        XCTAssertEqual(readout.unit, .framesPerSecond)
        XCTAssertEqual(try XCTUnwrap(readout.current), 15, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(readout.average), 15, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(readout.realtime), 0.5, accuracy: 0.001)
        XCTAssertNil(readout.filesPerSecond, "a render has no files rate to show")
        XCTAssertEqual(readout.series, ["Frames"])
        XCTAssertFalse(readout.points.isEmpty)
        guard case .seconds(let left)? = monitor.remainingEstimate(for: job) else {
            return XCTFail("a step that has run 10 s at a steady pace has a time left")
        }
        XCTAssertEqual(left, 2_850.0 / 15, accuracy: 1, "the stabilize step's frames left at its own pace")

        let facts = JobDetailFacts.liveReadouts(readout, graph: JobSpeedGraph.build(samples: [], kind: "gradeRender", duration: 10), job: job)
        XCTAssertEqual(facts.map(\.caption), ["now", "speed", "average"])
        XCTAssertEqual(facts.map(\.unit), ["frames/s", "× realtime", "frames/s"])
        XCTAssertEqual(facts.first?.value, "15.0")
        XCTAssertEqual(facts[1].value, "0.50")
        XCTAssertEqual(JobDetailFacts.liveCounts(job), "Stabilizing 150 of 3,000 frames · Grade next")
        XCTAssertEqual(JobDetailFacts.liveSubline(job, remaining: "~3 m left"), "~3 m left to stabilize")
    }

    /// The grade step starts its own pace: its time left is not timed by
    /// Gyroflow's, and it needs a few seconds before it says anything.
    func testTheGradeStepIsTimedOnItsOwn() {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        for second in 0...10 {
            monitor.tick(job: renderJob(step: "Stabilize", frame: second * 300, total: 3_000, done: second * 300), now: Double(second), wallNow: renderStart.addingTimeInterval(Double(second)))
        }
        let firstGrade = renderJob(step: "Grade", frame: 0, total: 3_000, done: 3_000)
        monitor.tick(job: firstGrade, now: 11, wallNow: renderStart.addingTimeInterval(11))
        XCTAssertEqual(monitor.remainingEstimate(for: firstGrade), .estimating, "a step just begun has no pace yet")
        for second in 12...20 {
            let frame = (second - 11) * 60
            monitor.tick(job: renderJob(step: "Grade", frame: frame, total: 3_000, done: 3_000 + frame), now: Double(second), wallNow: renderStart.addingTimeInterval(Double(second)))
        }
        let grading = renderJob(step: "Grade", frame: 540, total: 3_000, done: 3_540, clip: 1, of: 2)
        guard case .seconds(let left)? = monitor.remainingEstimate(for: grading) else {
            return XCTFail("the grade step has run long enough")
        }
        XCTAssertEqual(left, 2_460.0 / 60, accuracy: 1)
        XCTAssertEqual(JobDetailFacts.liveCounts(grading), "Clip 1 of 2 · Stabilized · Grading 540 of 3,000 frames")
        XCTAssertEqual(JobDetailFacts.liveSubline(grading, remaining: "under a minute left"), "under a minute left on this clip")
        let last = renderJob(step: "Grade", frame: 540, total: 3_000, done: 3_540)
        XCTAssertEqual(JobDetailFacts.liveSubline(last, remaining: "under a minute left"), "under a minute left")
        XCTAssertNil(JobDetailFacts.liveSubline(last, remaining: nil))
    }

    /// A report without frames (the Immich send's closing check) keeps the
    /// render's count and unit instead of starting the chart over.
    func testARenderReportWithoutFramesKeepsItsCount() {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        for second in 0...5 {
            monitor.tick(job: renderJob(step: "Grade", frame: second * 60, total: 600, done: second * 60), now: Double(second), wallNow: renderStart.addingTimeInterval(Double(second)))
        }
        var checking = renderJob(step: "Grade", frame: 300, total: 600, done: 300)
        checking.telemetry = nil
        monitor.tick(job: checking, now: 6, wallNow: renderStart.addingTimeInterval(6))
        let readout = monitor.readout(for: checking, now: 6)
        XCTAssertEqual(readout.unit, .framesPerSecond)
        XCTAssertEqual(try XCTUnwrap(readout.average), 300.0 / 6, accuracy: 0.01, "the frames already made still count")
        XCTAssertGreaterThan(readout.current ?? 0, 0, "the speed is held, not dropped to zero")
    }

    /// A queued render starts no track: its speed and average are timed
    /// from its first frame report while running, not from the queue.
    func testAQueuedRenderIsNotTimedUntilItRunsWithFrames() {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        var queued = renderJob(step: "Stabilize", frame: 0, total: nil, done: 0)
        queued.state = .queued
        XCTAssertNil(JobActivityMonitor.throughputUnit(queued))
        monitor.tick(job: queued, now: 0, wallNow: renderStart)
        XCTAssertNil(monitor.tracks[renderID], "no track while queued")

        var running = JobSnapshot(id: renderID, action: .gradeRender, state: .running, totalFiles: 1, createdAt: renderStart.addingTimeInterval(60))
        XCTAssertNil(JobActivityMonitor.throughputUnit(running), "no frames reported yet")
        monitor.tick(job: running, now: 60, wallNow: running.createdAt)
        XCTAssertNil(monitor.tracks[renderID])

        for second in 0...10 {
            running.telemetry = renderJob(step: "Grade", frame: second * 30, total: 900, done: second * 30).telemetry
            monitor.tick(job: running, now: 60 + Double(second), wallNow: running.createdAt.addingTimeInterval(Double(second)))
        }
        let readout = monitor.readout(for: running, now: 70)
        XCTAssertEqual(readout.unit, .framesPerSecond)
        XCTAssertEqual(try XCTUnwrap(readout.average), 30, accuracy: 0.01, "the minute in the queue is not averaged in")
    }

    /// File jobs keep their files/s.
    func testFileJobsStillReadInFiles() {
        let job = JobSnapshot(action: .organize, state: .running, processedFiles: 3, totalFiles: 10)
        XCTAssertEqual(JobActivityMonitor.throughputUnit(job), .filesPerSecond)
        XCTAssertEqual(JobDetailFacts.liveCounts(job), "3 of 10 files · 7 to go")
    }
}
