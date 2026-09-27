import XCTest
@testable import CameraToolkitApp
@testable import CameraToolkitCore

final class ScanTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ seconds: TimeInterval) {
        lock.lock(); value = seconds; lock.unlock()
    }
}

/// The owner's XHIGH scan: 52 DJI clips, 6 h 7 min, 257.69 GB, ~12 frames/s.
/// Byte progress only reached the Jobs window when a whole file finished,
/// and the old monitor's per-second EWMA (×0.55 per idle tick) collapsed
/// the rate between completions — 904 h on screen for a ~1 h job.
@MainActor
final class ScanETATests: XCTestCase {
    private struct Observation {
        var job: JobSnapshot
        var filesDone: Int
        var framesDone: Int
        var totalFrames: Int
        /// The largest byte-rate ETA the monitor produced.
        var worstByteETA: TimeInterval
    }

    /// Replays the scan: 20 five-second clips interleaved with 32 long
    /// ones, 4 workers at 3 frames/s each. Telemetry sees every frame
    /// (the fix); the job's byte counter only moves when a file finishes
    /// (the pre-fix emission cadence). The monitor ticks at 1 Hz.
    private func replay(until end: TimeInterval, monitor: JobActivityMonitor) -> Observation {
        var durations: [Double] = []
        var shorts = 20
        var index = 0
        while durations.count < 52 {
            if shorts > 0, index % 2 == 0 || durations.count < 4 {
                durations.append(5); shorts -= 1
            } else {
                durations.append(0)
            }
            index += 1
        }
        let longCount = durations.filter { $0 == 0 }.count
        let longDuration = (22_020 - Double(20 * 5)) / Double(longCount)
        durations = durations.map { $0 == 0 ? longDuration : $0 }
        let bytesPerSecond = 257.69e9 / 22_020
        let sizes = durations.map { Int64($0 * bytesPerSecond) }
        let frames = durations.map {
            FaceVideoSampler.sampleTimes(duration: $0, stride: 0.5, maxFrames: .max).count
        }

        let clock = ScanTestClock()
        let telemetry = FaceScanTelemetry(clock: { clock.now })
        telemetry.planWork(
            photos: [],
            videos: sizes.enumerated().map { ($0.offset, $0.element) },
            stride: 0.5,
            maximumFrames: .max
        )
        var job = JobSnapshot(action: .faceScan, state: .running, totalBytes: sizes.reduce(0, +))
        var next = 0
        var workers: [(clip: Int, done: Int, credit: Double)?] = Array(repeating: nil, count: 4)
        var bytesLive: Int64 = 0
        var filesDone = 0
        var framesDone = 0
        var step = 0
        var nextTick = 0.0
        var worstByteETA: TimeInterval = 0
        while Double(step) * 0.1 < end {
            step += 1
            let now = Double(step) * 0.1
            clock.set(now)
            for w in 0..<4 {
                if workers[w] == nil, next < 52 {
                    let url = "/clips/DJI_\(next).MP4"
                    telemetry.begin(next, file: OrganizeFile(path: url, size: sizes[next], modifiedAt: Date()))
                    telemetry.openVideo(next, duration: durations[next], plannedFrames: frames[next])
                    workers[w] = (next, 0, 0)
                    next += 1
                }
                guard var slot = workers[w] else { continue }
                slot.credit += 0.1 * 3
                while slot.credit >= 1, slot.done < frames[slot.clip] {
                    slot.credit -= 1
                    slot.done += 1
                    framesDone += 1
                    bytesLive += Int64(Double(sizes[slot.clip]) * 0.5 / durations[slot.clip])
                    telemetry.noteFrame(slot.clip, decoded: true)
                }
                if slot.done >= frames[slot.clip] {
                    telemetry.finish(slot.clip, faces: 0, videoFramesRead: slot.done, failed: false)
                    workers[w] = nil
                    filesDone += 1
                    job.processedBytes = bytesLive
                    job.processedFiles = filesDone
                } else {
                    workers[w] = slot
                }
            }
            job.telemetry = telemetry.snapshot(skipped: 0, models: [], facts: [])
            if now >= nextTick {
                monitor.tick(job: job, now: now)
                nextTick += 1
                if let eta = monitor.estimatedRemaining(for: job) {
                    worstByteETA = max(worstByteETA, eta)
                }
            }
        }
        return Observation(job: job, filesDone: filesDone, framesDone: framesDone, totalFrames: frames.reduce(0, +), worstByteETA: worstByteETA)
    }

    func testObservedSequenceEstimatesAboutAnHourNotHundreds() throws {
        let monitor = JobActivityMonitor()
        let observed = replay(until: 107, monitor: monitor)
        XCTAssertTrue((43_900...44_200).contains(observed.totalFrames), "\(observed.totalFrames)")

        // The byte-rate path used to decay ×0.55 on every tick without a
        // finished file and read 904 h here. It now measures between the
        // counter's change points and holds the rate in between, so even
        // this worst case stays in the right order of magnitude.
        XCTAssertGreaterThan(observed.worstByteETA, 0)
        XCTAssertLessThan(observed.worstByteETA, 3 * 3600, "the byte ETA no longer collapses between file completions")

        // The work-unit estimate: remaining frames at ~12 frames/s.
        let estimate = try XCTUnwrap(monitor.remainingEstimate(for: observed.job))
        guard case .seconds(let seconds) = estimate else {
            return XCTFail("expected a time, got \(estimate)")
        }
        let expected = Double(observed.totalFrames - observed.framesDone) / 12
        XCTAssertEqual(seconds, expected, accuracy: expected * 0.1)
        XCTAssertEqual(seconds / 3600, 1, accuracy: 0.1)
        let text = JobActivityDetail.remainingText(estimate)
        XCTAssertTrue(text.hasPrefix("~1 h") || text.hasPrefix("~5"), text)

        // Progress is frames done over the plan (~3 %), not bytes.
        let work = try XCTUnwrap(observed.job.telemetry?.work)
        XCTAssertEqual(work.unitsDone, observed.framesDone)
        XCTAssertEqual(work.unitLabel, "frames")
        XCTAssertEqual(try XCTUnwrap(work.fraction), Double(observed.framesDone) / Double(observed.totalFrames), accuracy: 0.01)
    }

    func testObservedSequenceIsStillEstimatingAtEightSeconds() {
        let monitor = JobActivityMonitor()
        let observed = replay(until: 8, monitor: monitor)
        XCTAssertEqual(monitor.remainingEstimate(for: observed.job), .estimating)
        XCTAssertEqual(JobActivityDetail.remainingText(.estimating), "estimating…")
    }

    // MARK: - Formatting

    func testRemainingTextFormatsAndClamps() {
        XCTAssertEqual(JobActivityDetail.remainingText(.seconds(3_900)), "~1 h 5 m left")
        XCTAssertEqual(JobActivityDetail.remainingText(.seconds(3_600)), "~1 h left")
        XCTAssertEqual(JobActivityDetail.remainingText(.seconds(12 * 60)), "~12 m left")
        XCTAssertEqual(JobActivityDetail.remainingText(.seconds(30)), "under a minute left")
        XCTAssertEqual(JobActivityDetail.remainingText(.seconds(99 * 3600)), "~99 h left")
        // 904:24:14 is noise, not information.
        XCTAssertEqual(JobActivityDetail.remainingText(.seconds(904 * 3600 + 24 * 60 + 14)), "many hours left")
        XCTAssertEqual(JobActivityDetail.remainingText(.seconds(.infinity)), "many hours left")
    }

    func testJobsWithoutWorkTelemetryKeepTheByteEstimate() {
        let monitor = JobActivityMonitor()
        var job = JobSnapshot(action: .ingestCard, state: .running, processedBytes: 0, totalBytes: 1_000_000)
        monitor.tick(job: job, now: 0)
        job.processedBytes = 500_000
        monitor.tick(job: job, now: 1)
        XCTAssertEqual(monitor.remainingEstimate(for: job), .seconds(1))
        job.state = .done
        XCTAssertNil(monitor.remainingEstimate(for: job))
    }
}
