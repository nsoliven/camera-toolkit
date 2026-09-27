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
            action: .faceScan,
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
}
