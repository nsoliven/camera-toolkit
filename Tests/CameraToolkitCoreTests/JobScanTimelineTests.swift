import XCTest
@testable import CameraToolkitCore

/// A scan's recorded counters are one field used three ways: photos in the
/// first pass, faces while matching, photos again in the second pass. These
/// replay that shape with made-up numbers and check what the graph keeps.
final class JobScanTimelineTests: XCTestCase {
    private func twoPassSamples(passOneSeconds: Int = 600, rate: Int = 8) -> [JobHistorySample] {
        var samples: [JobHistorySample] = []
        for second in 2...passOneSeconds {
            samples.append(JobHistorySample(
                t: Double(second), combined: 300, filesPerSecond: Double(rate) + (second.isMultiple(of: 7) ? 3 : 0),
                doneBytes: Int64(second) * 40_000_000, doneFiles: second * rate
            ))
        }
        let end = Double(passOneSeconds)
        samples.append(JobHistorySample(t: end + 1.5, combined: 0, filesPerSecond: 0, doneBytes: 0, doneFiles: 0))
        samples.append(JobHistorySample(t: end + 2.5, combined: 0, filesPerSecond: 2_900, doneBytes: 0, doneFiles: 21_000))
        samples.append(JobHistorySample(t: end + 3.5, combined: 0, filesPerSecond: 7_200, doneBytes: 0, doneFiles: 42_000))
        samples.append(JobHistorySample(t: end + 4.5, combined: 0, filesPerSecond: 11_900, doneBytes: 0, doneFiles: 66_000))
        samples.append(JobHistorySample(t: end + 18, combined: 0, filesPerSecond: 3_400, doneBytes: 0, doneFiles: 44_000))
        samples.append(JobHistorySample(t: end + 21, combined: 0, filesPerSecond: 0, doneBytes: 0, doneFiles: 0))
        for second in 1...120 {
            samples.append(JobHistorySample(
                t: end + 21 + Double(second), combined: 300, filesPerSecond: 10,
                doneBytes: Int64(second) * 40_000_000, doneFiles: second * 10
            ))
        }
        return samples
    }

    func testBothPassesAreFoundAndNamed() {
        let graph = JobSpeedGraph.build(samples: twoPassSamples(), kind: "faceScan", duration: 750)
        XCTAssertEqual(graph.scanPasses.map(\.label), ["Pass 1 · Faces", "Pass 2 · Dogs"])
        XCTAssertEqual(graph.scanPasses[0].photos, 4_800)
        XCTAssertEqual(graph.scanPasses[1].photos, 1_200)
        XCTAssertGreaterThanOrEqual(graph.segments.count, 2, "the line must not run across the passes")
        XCTAssertEqual(graph.metric, .filesPerSecond)
    }

    func testCounterResetsAndMatchingDoNotMakeASpike() throws {
        let graph = JobSpeedGraph.build(samples: twoPassSamples(), kind: "faceScan", duration: 750)
        let peak = try XCTUnwrap(graph.peak)
        XCTAssertLessThan(peak.value, 15, "peak \(peak.value) came from the matching burst")
        XCTAssertFalse(graph.segments.joined().contains { $0.value > 15 })
        XCTAssertFalse(graph.peakIsOffScale)
        XCTAssertLessThanOrEqual(graph.yUpper, 20, "the axis must fit the scan, not the burst")
    }

    func testAverageIsOverTheWorkNotTheBookkeeping() throws {
        let graph = JobSpeedGraph.build(samples: twoPassSamples(), kind: "faceScan", duration: 750)
        let average = try XCTUnwrap(graph.average)
        // 6,000 photos over about 720 s of reading; the old sum added the
        // face counts and came out near 190.
        XCTAssertEqual(average, 6_000.0 / 719.0, accuracy: 0.3)
        XCTAssertEqual(graph.filesDone, 6_000)
    }

    func testMatchingIsMarkedSoHoverCanSaySo() {
        let graph = JobSpeedGraph.build(samples: twoPassSamples(), kind: "faceScan", duration: 750)
        XCTAssertTrue(graph.isScanFinishing(at: 603))
        XCTAssertFalse(graph.isScanFinishing(at: 300))
        XCTAssertEqual(graph.scanPass(at: 300)?.title, "Faces")
        XCTAssertEqual(graph.scanPass(at: 700)?.title, "Dogs")
    }

    func testAJumpInsideAPassDoesNotBecomeThePeakOrTheAverage() throws {
        var samples: [JobHistorySample] = []
        var done = 0
        for second in 1...300 {
            done += second == 150 ? 3_000 : 8
            let window = (150...154).contains(second) ? 600.0 : 8.0
            samples.append(JobHistorySample(t: Double(second), combined: 200, filesPerSecond: window, doneBytes: Int64(second) * 20_000_000, doneFiles: done))
        }
        let graph = JobSpeedGraph.build(samples: samples, kind: "faceScan", duration: 300)
        let peak = try XCTUnwrap(graph.peak)
        XCTAssertLessThan(peak.value, 20)
        XCTAssertEqual(try XCTUnwrap(graph.average), 8, accuracy: 0.5)
        XCTAssertTrue(graph.scanPasses.isEmpty)
    }

    /// The shape older builds recorded: no bytes at all, one pass, then the
    /// matching burst.
    func testOldSinglePassRecordWithoutBytes() throws {
        var samples = (1...400).map { JobHistorySample(t: Double($0), filesPerSecond: 5, doneFiles: $0 * 5) }
        samples.append(JobHistorySample(t: 401, filesPerSecond: 0, doneFiles: 0))
        samples.append(JobHistorySample(t: 402, filesPerSecond: 8_500, doneFiles: 42_000))
        samples.append(JobHistorySample(t: 403, filesPerSecond: 8_500, doneFiles: 78_000))
        samples.append(JobHistorySample(t: 411, filesPerSecond: 4_000, doneFiles: 55_000))
        let graph = JobSpeedGraph.build(samples: samples, kind: "faceScan", duration: 411)
        XCTAssertTrue(graph.scanPasses.isEmpty)
        XCTAssertEqual(graph.filesDone, 2_000)
        XCTAssertLessThan(try XCTUnwrap(graph.peak).value, 6)
    }

    func testAScanThatOnlyMatchedDrawsNoChart() {
        let samples = [
            JobHistorySample(t: 1, filesPerSecond: 0, doneFiles: 0),
            JobHistorySample(t: 2, filesPerSecond: 15_000, doneFiles: 48_000),
            JobHistorySample(t: 8, filesPerSecond: 3_000, doneFiles: 35_000),
            JobHistorySample(t: 12, filesPerSecond: 0, doneFiles: 0),
        ]
        let graph = JobSpeedGraph.build(samples: samples, kind: "faceScan", duration: 14)
        XCTAssertNil(graph.peak)
        XCTAssertEqual(graph.filesDone, 0)
        XCTAssertEqual(graph.summary, .noSamples)
    }

    /// Reports held through matching: the count just stops, then restarts.
    func testNewRecordsWhereTheCountHoldsThroughMatching() throws {
        var samples = (1...200).map {
            JobHistorySample(t: Double($0), filesPerSecond: 6, doneBytes: Int64($0) * 10_000_000, doneFiles: $0 * 6)
        }
        for second in 201...220 {
            samples.append(JobHistorySample(t: Double(second), filesPerSecond: 0, doneBytes: 2_000_000_000, doneFiles: 1_200))
        }
        for second in 1...60 {
            samples.append(JobHistorySample(t: 220 + Double(second), filesPerSecond: 6, doneBytes: Int64(second) * 10_000_000, doneFiles: second * 6))
        }
        let graph = JobSpeedGraph.build(samples: samples, kind: "faceScan", duration: 280)
        XCTAssertEqual(graph.scanPasses.count, 2)
        XCTAssertEqual(graph.scanPasses[0].end, 200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(graph.average), 6, accuracy: 0.2)
    }

    func testOtherJobKindsAreUntouched() {
        let samples = (1...30).map {
            JobHistorySample(t: Double($0), combined: 100, filesPerSecond: 2, transferBytes: Int64($0) * 100_000_000, doneBytes: Int64($0) * 100_000_000, doneFiles: $0 * 2)
        }
        let graph = JobSpeedGraph.build(samples: samples, kind: "syncBuffer", duration: 30)
        XCTAssertEqual(graph.metric, .megabytesPerSecond)
        XCTAssertTrue(graph.scanPasses.isEmpty)
        XCTAssertEqual(graph.peak?.value, 100)
    }

    func testPassPercentAndTitles() {
        let dogs = JobScanPass(index: 2, count: 2, subject: .dogs)
        XCTAssertEqual(dogs.label, "Pass 2 of 2 · Dogs")
        XCTAssertEqual(dogs.jobFraction(passFraction: 0), 0.5)
        XCTAssertEqual(dogs.jobFraction(passFraction: 1), 1)
        XCTAssertEqual(dogs.title(forRecorded: "Face and dog scan: Beach Day"), "Dog scan: Beach Day")
        XCTAssertEqual(dogs.title(forRecorded: "Face scan: Beach Day"), "Dog scan: Beach Day")
        XCTAssertEqual(dogs.title(forRecorded: "Re-matched faces"), "Re-matched faces")
        XCTAssertNil(JobScanPass(index: 1, count: 1, subject: .faces).label)
    }

    func testTelemetryFromAnOlderBuildStillDecodes() throws {
        let old = #"{"step":"Detect","activeItems":[],"counters":[{"label":"Faces","value":3}],"models":[],"facts":[]}"#
        let telemetry = try JSONDecoder().decode(JobTelemetry.self, from: Data(old.utf8))
        XCTAssertNil(telemetry.scanPass)
        XCTAssertEqual(telemetry.counter("Faces"), 3)
    }
}
