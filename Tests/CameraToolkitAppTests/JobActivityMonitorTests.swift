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

    func testMonitorTurnsByteDeltasIntoARateHistory() {
        let monitor = JobActivityMonitor()
        let job = JobSnapshot(
            action: .faceScan,
            state: .running,
            processedBytes: 0,
            totalBytes: 1_000_000
        )
        monitor.tick(job: job)
        XCTAssertTrue(monitor.readRateHistory.isEmpty, "the first tick only sets the baseline")

        var moved = job
        moved.processedBytes = 500_000
        monitor.tick(job: moved)
        XCTAssertEqual(monitor.readRateHistory.count, 1)
        XCTAssertGreaterThan(monitor.readRateHistory[0], 0)
        XCTAssertEqual(monitor.peakReadRate, monitor.readRateHistory[0])
        XCTAssertNotNil(monitor.estimatedRemaining(for: moved))
    }

    func testMonitorResetsByteHistoryWhenANewJobStarts() {
        let monitor = JobActivityMonitor()
        var first = JobSnapshot(action: .faceScan, state: .running, processedBytes: 1_000)
        monitor.tick(job: first)
        first.processedBytes = 2_000
        monitor.tick(job: first)
        XCTAssertEqual(monitor.readRateHistory.count, 1)

        monitor.tick(job: JobSnapshot(action: .ingestCard, state: .running))
        XCTAssertTrue(monitor.readRateHistory.isEmpty)
        XCTAssertEqual(monitor.peakReadRate, 0)
    }

    func testMonitorStopsSamplingFinishedJobs() {
        let monitor = JobActivityMonitor()
        var job = JobSnapshot(
            action: .faceScan,
            state: .running,
            processedBytes: 100,
            totalBytes: 1_000
        )
        monitor.tick(job: job)
        job.state = .done
        job.processedBytes = 1_000
        monitor.tick(job: job)
        XCTAssertTrue(monitor.readRateHistory.isEmpty, "a finished job reports no rate")
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
            activePlan: CopyPlan(),
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
