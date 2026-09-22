import Foundation
@testable import CameraToolkitCore
import XCTest

/// Thread-safe collector for `@Sendable` progress handlers — the face scan
/// fires them off worker threads, so a plain array would race.
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FileOperationProgress] = []

    var handler: FileOperationProgressHandler {
        { self.append($0) }
    }

    var updates: [FileOperationProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private func append(_ update: FileOperationProgress) {
        lock.lock()
        storage.append(update)
        lock.unlock()
    }
}

final class JobTelemetryTests: XCTestCase {
    private let modified = Date(timeIntervalSince1970: 1_752_000_000)

    private func file(_ name: String) -> OrganizeFile {
        OrganizeFile(path: "/card/DCIM/\(name)", size: 4_000_000, modifiedAt: modified)
    }

    func testSnapshotShowsInFlightFilesWithPipelineSteps() {
        let telemetry = FaceScanTelemetry()
        telemetry.begin(0, file: file("DSC_1.ARW"))
        telemetry.begin(2, file: file("DSC_2.ARW"))
        telemetry.step(0, .embed)

        let snapshot = telemetry.snapshot(skipped: 4, models: ["det_10g.mlpackage"], facts: ["LOW"])

        // A tie between steps resolves to the later one — that is where the
        // time is going.
        XCTAssertEqual(snapshot.step, "Embed")
        // Basenames for display; the full path is tooltip material only.
        XCTAssertEqual(snapshot.activeItems.map(\.name), ["DSC_1.ARW", "DSC_2.ARW"])
        XCTAssertEqual(snapshot.activeItems.map(\.step), ["Embed", "Decode"])
        XCTAssertEqual(snapshot.models, ["det_10g.mlpackage"])
        XCTAssertEqual(snapshot.facts, ["LOW"])
        XCTAssertEqual(snapshot.counter("Skipped"), 4)
    }

    func testFinishFoldsOutcomesIntoCounters() {
        let telemetry = FaceScanTelemetry()
        telemetry.begin(0, file: file("A.ARW"))
        telemetry.begin(1, file: file("B.MP4"))
        telemetry.finish(0, faces: 3, videoFramesRead: 0, failed: false)
        telemetry.finish(1, faces: 0, videoFramesRead: 5, failed: true)

        let snapshot = telemetry.snapshot(skipped: 0, models: [], facts: [])
        XCTAssertTrue(snapshot.activeItems.isEmpty)
        XCTAssertEqual(snapshot.counter("Faces"), 3)
        XCTAssertEqual(snapshot.counter("Failed"), 1)
        XCTAssertEqual(snapshot.counter("Video frames"), 5)
    }

    func testMatchAndGroupStagesReplaceThePerFileStep() {
        let telemetry = FaceScanTelemetry()
        telemetry.begin(0, file: file("A.ARW"))
        telemetry.enterStage("Match")
        telemetry.noteMatch()
        telemetry.noteMatch()

        var snapshot = telemetry.snapshot(skipped: 0, models: [], facts: [])
        XCTAssertEqual(snapshot.step, "Match")
        XCTAssertTrue(snapshot.activeItems.isEmpty)
        XCTAssertEqual(snapshot.counter("Matched"), 2)

        telemetry.enterStage("Group")
        telemetry.noteGrouped(assigned: 4, groupsCreated: 2)
        snapshot = telemetry.snapshot(skipped: 0, models: [], facts: [])
        XCTAssertEqual(snapshot.step, "Group")
        XCTAssertEqual(snapshot.counter("Grouped"), 4)
        XCTAssertEqual(snapshot.counter("New groups"), 2)
    }

    func testEmissionsAreRateLimited() {
        let telemetry = FaceScanTelemetry(minimumEmissionInterval: 60)
        XCTAssertTrue(telemetry.shouldEmit())
        XCTAssertFalse(telemetry.shouldEmit())
        XCTAssertTrue(telemetry.shouldEmit(force: true))
    }

    func testReadRateNeedsTwoSamplesAndStaysPositive() {
        let telemetry = FaceScanTelemetry()
        XCTAssertEqual(telemetry.bytesPerSecond, 0)
        telemetry.noteReadBytes(5_000_000)
        XCTAssertEqual(telemetry.bytesPerSecond, 0, "one sample cannot make a rate")
        XCTAssertEqual(telemetry.totalBytesRead, 5_000_000)

        Thread.sleep(forTimeInterval: 0.02)
        telemetry.noteReadBytes(5_000_000)
        XCTAssertGreaterThan(telemetry.bytesPerSecond, 0)
        XCTAssertEqual(telemetry.totalBytesRead, 10_000_000)
    }

    func testJobTelemetryCodableRoundTrip() throws {
        let telemetry = JobTelemetry(
            step: "Embed",
            activeItems: [JobActiveItem(name: "DSC.ARW", path: "/x/DSC.ARW", step: "Embed")],
            counters: [JobCounter(label: "Faces", value: 7)],
            models: ["det_10g.mlpackage", "w600k_r50.mlpackage"],
            facts: ["MED · FAST · 10 workers"]
        )
        let decoded = try JSONDecoder().decode(
            JobTelemetry.self,
            from: JSONEncoder().encode(telemetry)
        )
        XCTAssertEqual(decoded, telemetry)
        XCTAssertEqual(decoded.counter("Faces"), 7)
    }

    /// `telemetry` is optional so snapshots serialized by older builds —
    /// and jobs that never report detail — still decode.
    func testJobSnapshotWithoutTelemetryStillDecodes() throws {
        let job = JobSnapshot(action: .faceScan, note: "Face scan: Detecting faces")
        let data = try JSONEncoder().encode(job)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "telemetry")

        let legacy = try JSONDecoder().decode(
            JobSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.telemetry)
        XCTAssertEqual(legacy.action, .faceScan)
    }

    /// The progress envelope carries telemetry through `withPhase`
    /// unchanged — the channel the jobs window reads.
    func testFileOperationProgressCarriesTelemetry() {
        let telemetry = JobTelemetry(step: "Detect")
        let progress = FileOperationProgress(
            phase: "Detecting faces",
            processedFiles: 3,
            totalFiles: 10,
            telemetry: telemetry
        )
        let rephrased = progress.withPhase("Embedding faces")
        XCTAssertEqual(rephrased.telemetry, telemetry)
        XCTAssertEqual(rephrased.phase, "Embedding faces")
    }
}
