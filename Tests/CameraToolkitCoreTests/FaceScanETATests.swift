import Foundation
@testable import CameraToolkitCore
import XCTest

/// A settable clock for telemetry tests — the ETA is a function of time.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }

    var read: @Sendable () -> TimeInterval { { self.now } }
}

final class FaceScanETATests: XCTestCase {
    private let modified = Date(timeIntervalSince1970: 1_752_000_000)

    private func file(_ name: String, size: Int64 = 4_000_000) -> OrganizeFile {
        OrganizeFile(path: "/card/DCIM/\(name)", size: size, modifiedAt: modified)
    }

    private func work(_ telemetry: FaceScanTelemetry) throws -> JobWorkEstimate {
        try XCTUnwrap(telemetry.snapshot(skipped: 0, models: [], facts: []).work)
    }

    // MARK: - Photo-only

    func testPhotoOnlyScanCountsFilesAndEstimatesFromTheirRate() throws {
        let clock = ManualClock()
        let telemetry = FaceScanTelemetry(clock: clock.read)
        telemetry.planWork(photos: Array(0..<1_000), videos: [], stride: nil, maximumFrames: 0)

        // 5 photos/s for 60 s.
        for token in 0..<300 {
            clock.advance(0.2)
            telemetry.begin(token, file: file("DSC_\(token).ARW"))
            telemetry.finish(token, faces: 1, videoFramesRead: 0, failed: false)
        }
        let estimate = try work(telemetry)
        XCTAssertEqual(estimate.unitsDone, 300)
        XCTAssertEqual(estimate.unitsTotal, 1_000)
        XCTAssertFalse(estimate.totalIsEstimate)
        XCTAssertNil(estimate.unitLabel, "a photo-only scan's file count already says it")
        XCTAssertEqual(estimate.fraction ?? 0, 0.3, accuracy: 0.001)
        // 700 photos left at 5/s = 140 s.
        XCTAssertEqual(try XCTUnwrap(estimate.secondsRemaining), 140, accuracy: 10)
    }

    // MARK: - Mixed

    func testMixedScanWeighsPhotosAndPlannedFramesAsUnits() throws {
        let clock = ManualClock()
        let telemetry = FaceScanTelemetry(clock: clock.read)
        // 100 photos, then two 100 s clips of 100 MB (1 MB/s) at 0.5 s.
        telemetry.planWork(
            photos: Array(0..<100),
            videos: [(100, 100_000_000), (101, 100_000_000)],
            stride: 0.5,
            maximumFrames: .max
        )
        for token in 0..<100 {
            clock.advance(0.1) // 10 units/s
            telemetry.begin(token, file: file("P\(token).JPG"))
            telemetry.finish(token, faces: 0, videoFramesRead: 0, failed: false)
        }
        // Before any clip opens, the clips have no known length yet.
        var estimate = try work(telemetry)
        XCTAssertNil(estimate.unitsTotal)
        XCTAssertEqual(estimate.unitLabel, "photos and frames")
        XCTAssertNil(estimate.secondsRemaining, "no honest total, no time left")

        telemetry.begin(100, file: file("C100.MP4", size: 100_000_000))
        let planned = FaceVideoSampler.sampleTimes(duration: 100, stride: 0.5, maxFrames: .max).count
        telemetry.openVideo(100, duration: 100, plannedFrames: planned)
        // The unopened clip is extrapolated from the opened one's bitrate.
        estimate = try work(telemetry)
        XCTAssertTrue(estimate.totalIsEstimate)
        XCTAssertEqual(estimate.unitsTotal, 100 + planned + 201)

        for _ in 0..<100 {
            clock.advance(0.1)
            telemetry.noteFrame(100, decoded: true)
        }
        estimate = try work(telemetry)
        XCTAssertEqual(estimate.unitsDone, 200)
        let remaining = Double(try XCTUnwrap(estimate.unitsTotal) - 200)
        XCTAssertEqual(try XCTUnwrap(estimate.secondsRemaining), remaining / 10, accuracy: remaining / 10 * 0.1)
        // Live frames show on the counter before the clip finishes.
        XCTAssertEqual(telemetry.snapshot(skipped: 0, models: [], facts: []).counter("Video frames"), 100)

        // Finishing does not double-count the live frames.
        telemetry.finish(100, faces: 2, videoFramesRead: 100, failed: false)
        XCTAssertEqual(telemetry.snapshot(skipped: 0, models: [], facts: []).counter("Video frames"), 100)
        // A clip that ended early contributes only what it ran.
        estimate = try work(telemetry)
        XCTAssertEqual(estimate.unitsDone, 200)
        XCTAssertEqual(estimate.unitsTotal, 200 + 201)
    }

    func testProgressFractionUsesWorkUnitsOverBytes() {
        let work = JobWorkEstimate(unitsDone: 1_272, unitsTotal: 44_092, totalIsEstimate: true, unitLabel: "frames")
        let progress = FileOperationProgress(
            phase: "Detecting faces",
            processedFiles: 19,
            totalFiles: 52,
            processedBytes: 16_340_000_000,
            totalBytes: 257_690_000_000,
            telemetry: JobTelemetry(work: work)
        )
        XCTAssertEqual(progress.fractionComplete, 1_272.0 / 44_092.0, accuracy: 0.0001)

        // Without a known total the byte counters still answer.
        let unknown = FileOperationProgress(
            phase: "Detecting faces",
            processedBytes: 1,
            totalBytes: 4,
            telemetry: JobTelemetry(work: JobWorkEstimate(unitsDone: 3, unitsTotal: nil))
        )
        XCTAssertEqual(unknown.fractionComplete, 0.25, accuracy: 0.0001)
    }

    // MARK: - Estimating window

    func testNoEstimateDuringTheWarmUp() throws {
        let clock = ManualClock()
        let telemetry = FaceScanTelemetry(clock: clock.read)
        telemetry.planWork(photos: Array(0..<1_000), videos: [], stride: nil, maximumFrames: 0)
        for token in 0..<140 {
            clock.advance(0.1)
            telemetry.begin(token, file: file("P\(token).JPG"))
            telemetry.finish(token, faces: 0, videoFramesRead: 0, failed: false)
        }
        // 14 s in: still estimating, even with a steady rate.
        XCTAssertNil(try work(telemetry).secondsRemaining)

        for token in 140..<200 {
            clock.advance(0.1)
            telemetry.begin(token, file: file("P\(token).JPG"))
            telemetry.finish(token, faces: 0, videoFramesRead: 0, failed: false)
        }
        XCTAssertEqual(try XCTUnwrap(try work(telemetry).secondsRemaining), 80, accuracy: 5)
    }

    func testMatchStageDropsTheWorkEstimate() {
        let telemetry = FaceScanTelemetry()
        telemetry.planWork(photos: [0], videos: [], stride: nil, maximumFrames: 0)
        XCTAssertNotNil(telemetry.snapshot(skipped: 0, models: [], facts: []).work)
        telemetry.enterStage("Match")
        XCTAssertNil(telemetry.snapshot(skipped: 0, models: [], facts: []).work)
    }

    // MARK: - Rate change

    func testRateChangeMidScanConverges() {
        var estimator = ScanRateEstimator()
        var now: TimeInterval = 0
        var units = 0.0
        estimator.start(at: now)
        for _ in 0..<600 { // 60 s at 10 units/s
            now += 0.1; units += 1
            estimator.record(units: units, at: now)
        }
        XCTAssertEqual(estimator.rate, 10, accuracy: 0.2)

        for _ in 0..<300 { // the scan halves speed (a slow drive)
            now += 0.2; units += 1
            estimator.record(units: units, at: now)
        }
        // After 60 s at the new rate the estimate has converged, and the
        // ETA over 1,000 units reflects 5/s, not 10/s.
        XCTAssertEqual(estimator.rate, 5, accuracy: 0.5)
        XCTAssertEqual(estimator.secondsRemaining(1_000, at: now) ?? 0, 200, accuracy: 25)
    }

    func testIdleStretchLowersTheRateInProportionNotExponentially() {
        var estimator = ScanRateEstimator()
        var now: TimeInterval = 0
        var units = 0.0
        estimator.start(at: now)
        for _ in 0..<300 {
            now += 0.1; units += 1
            estimator.record(units: units, at: now)
        }
        // 13 s with nothing recorded (a slow frame), then work resumes:
        // the gap is one measured interval, not 13 decays toward zero.
        now += 13; units += 1
        estimator.record(units: units, at: now)
        XCTAssertGreaterThan(estimator.rate, 3)
    }
}
