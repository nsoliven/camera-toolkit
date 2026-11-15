@testable import CameraToolkitCore
import Foundation
import XCTest

/// The Jobs window's speed graph: which rate a job plots, gaps, phases,
/// average and peak, the summaries that replace an empty chart, and the
/// column reduction that smooths a long job.
final class JobSpeedGraphTests: XCTestCase {
    // MARK: Which rate

    func testACopyJobPlotsMegabytesPerSecond() {
        let samples = (1...30).map { second in
            JobHistorySample(t: Double(second), combined: 100, filesPerSecond: 2, transferBytes: Int64(second) * 100_000_000, doneBytes: Int64(second) * 100_000_000, doneFiles: second * 2)
        }
        let graph = JobSpeedGraph.build(samples: samples, kind: "syncBuffer", duration: 30)
        XCTAssertEqual(graph.metric, .megabytesPerSecond)
        XCTAssertNil(graph.summary)
        XCTAssertEqual(graph.pointCount, 30)
        XCTAssertEqual(graph.average ?? 0, 100, accuracy: 0.001)
    }

    func testAFaceScanPlotsFilesPerSecondEvenThoughItReadsBytes() {
        let samples = (1...40).map { second in
            JobHistorySample(t: Double(second), combined: 300, filesPerSecond: 12, doneBytes: Int64(second) * 300_000_000, doneFiles: second * 12)
        }
        let graph = JobSpeedGraph.build(samples: samples, kind: "faceScan", duration: 40)
        XCTAssertEqual(graph.metric, .filesPerSecond)
        XCTAssertEqual(graph.average ?? 0, 12, accuracy: 0.001)
        XCTAssertEqual(graph.peak?.value, 12)
    }

    func testAJobThatOnlyCountsFilesPlotsFilesPerSecond() {
        let samples = (1...20).map { JobHistorySample(t: Double($0), combined: 0, filesPerSecond: 50, doneFiles: $0 * 50) }
        let graph = JobSpeedGraph.build(samples: samples, kind: "organize", duration: 20)
        XCTAssertEqual(graph.metric, .filesPerSecond)
        XCTAssertNil(graph.summary)
    }

    // MARK: Summaries instead of empty charts

    /// The case that drew one floating fragment on a files/s axis: a sync
    /// that only checked 16,000 files already on the NAS.
    func testACheckOnlySyncIsASummaryNotAChart() {
        let samples = [
            JobHistorySample(t: 5.04, gpu: 0.21),
            JobHistorySample(t: 6.36, combined: 0, filesPerSecond: 1_718, doneFiles: 2_276),
            JobHistorySample(t: 7.96, combined: 0, filesPerSecond: 2_493, doneFiles: 7_275),
            JobHistorySample(t: 15.52, combined: 0, filesPerSecond: 1_155, doneFiles: 16_010),
            JobHistorySample(t: 15.52, combined: 0, filesPerSecond: 1_155, doneFiles: 16_010),
        ]
        let graph = JobSpeedGraph.build(samples: samples, kind: "syncBuffer", duration: 16, movedBytes: 0)
        guard case .nothingMoved(let files, let rate) = graph.summary else {
            return XCTFail("expected a nothing-moved summary, got \(String(describing: graph.summary))")
        }
        XCTAssertEqual(files, 16_010)
        XCTAssertEqual(rate ?? 0, 16_010 / 16, accuracy: 0.01)
    }

    func testAFewSecondJobIsASummary() {
        let samples = [
            JobHistorySample(t: 1, combined: 400, doneBytes: 400_000_000),
            JobHistorySample(t: 2, combined: 410, doneBytes: 810_000_000),
            JobHistorySample(t: 3, combined: 405, doneBytes: 1_215_000_000),
        ]
        let graph = JobSpeedGraph.build(samples: samples, kind: "ingestCard", duration: 4)
        XCTAssertEqual(graph.summary, .tooShort(duration: 4))
        XCTAssertEqual(graph.metric, .megabytesPerSecond)
    }

    func testALongJobWithoutRatesSaysSo() {
        let samples = (1...20).map { JobHistorySample(t: Double($0)) }
        let graph = JobSpeedGraph.build(samples: samples, kind: "nasRename", duration: 20)
        XCTAssertNil(graph.metric)
        XCTAssertEqual(graph.summary, .noSamples)
    }

    // MARK: Gaps

    func testSamplesFurtherApartThanTheGapThresholdBreakTheLine() {
        var samples = (1...10).map { JobHistorySample(t: Double($0), combined: 50, doneBytes: Int64($0) * 50_000_000) }
        samples += (30...40).map { JobHistorySample(t: Double($0), combined: 60, doneBytes: Int64($0) * 50_000_000) }
        let graph = JobSpeedGraph.build(samples: samples, kind: "syncBuffer", duration: 40)
        XCTAssertEqual(graph.gapThreshold, 5)
        XCTAssertEqual(graph.segments.count, 2)
        XCTAssertEqual(graph.segments[0].last?.t, 10)
        XCTAssertEqual(graph.segments[1].first?.t, 30)
    }

    func testANilRateIsLeftOutNotDrawnAsZero() {
        let samples = [
            JobHistorySample(t: 1),
            JobHistorySample(t: 2, combined: 10, doneBytes: 10_000_000),
            JobHistorySample(t: 3, combined: 20, doneBytes: 30_000_000),
        ]
        let graph = JobSpeedGraph.build(samples: samples, kind: "syncBuffer", duration: 3)
        XCTAssertEqual(graph.segments.flatMap { $0 }.map(\.t), [2, 3])
    }

    func testTheGapThresholdFollowsASlowerRecordingCadence() {
        let samples = stride(from: 0.0, through: 60, by: 3).map { JobHistorySample(t: $0, combined: 10, doneBytes: Int64($0 * 1e7)) }
        XCTAssertEqual(JobSpeedGraph.gapThreshold(samples), 9, accuracy: 0.001)
    }

    func testDuplicateInstantsKeepTheLastSample() {
        let samples = [
            JobHistorySample(t: 1, combined: 5),
            JobHistorySample(t: 2, combined: 6),
            JobHistorySample(t: 2, combined: 7),
        ]
        XCTAssertEqual(JobSpeedGraph.deduplicated(samples).map(\.combined), [5, 7])
    }

    // MARK: Average, peak, axis

    func testAverageCountsACounterThatRestartsBetweenPasses() {
        // A card copy's byte counter restarts for its verify pass.
        let counters: [Int64] = [0, 100, 200, 300, 50, 150, 300]
        XCTAssertEqual(JobSpeedGraph.positiveDeltaSum(counters), 550)
    }

    func testTheJobsOwnTotalWinsOverTheSampleCounters() {
        let samples = (1...20).map { JobHistorySample(t: Double($0), combined: 100, doneBytes: Int64($0) * 1_000) }
        let graph = JobSpeedGraph.build(samples: samples, kind: "syncBuffer", duration: 20, movedBytes: 2_000_000_000)
        XCTAssertEqual(graph.average ?? 0, 100, accuracy: 0.001)
    }

    func testPeakIsTheHighestSampleAndTheAxisClearsIt() {
        var samples = (1...20).map { JobHistorySample(t: Double($0), combined: 80, doneBytes: Int64($0) * 80_000_000) }
        samples[12].combined = 193
        let graph = JobSpeedGraph.build(samples: samples, kind: "syncBuffer", duration: 20)
        XCTAssertEqual(graph.peak, JobSpeedGraph.Point(t: 13, value: 193))
        XCTAssertEqual(graph.yUpper, 250)
    }

    func testNiceUpperRoundsUp() {
        XCTAssertEqual(JobSpeedGraph.niceUpper(0), 1)
        XCTAssertEqual(JobSpeedGraph.niceUpper(1.7), 2)
        XCTAssertEqual(JobSpeedGraph.niceUpper(230), 250)
        XCTAssertEqual(JobSpeedGraph.niceUpper(3_100), 5_000)
        XCTAssertEqual(JobSpeedGraph.niceUpper(6_000), 10_000)
    }

    // MARK: Phases

    func testPhasesComeFromTheRatesEachSampleCarries() {
        var samples: [JobHistorySample] = []
        // Check 1–4 s: files finish, nothing moves.
        for second in 1...4 {
            samples.append(JobHistorySample(t: Double(second), combined: 0, filesPerSecond: 1_000, doneFiles: second * 1_000))
        }
        // Copy 5–12 s, verifying on the NAS from 9 s alongside.
        for second in 5...12 {
            samples.append(JobHistorySample(
                t: Double(second), combined: 110, copy: 110, remoteVerify: second >= 9 ? 300 : nil,
                filesPerSecond: 2, doneBytes: Int64(second) * 110_000_000, doneFiles: 4_000 + second
            ))
        }
        // Verify only, 13–15 s.
        for second in 13...15 {
            samples.append(JobHistorySample(t: Double(second), combined: 0, remoteVerify: 280, doneBytes: 1_320_000_000, doneFiles: 4_020))
        }
        let graph = JobSpeedGraph.build(samples: samples, kind: "syncBuffer", duration: 15)
        XCTAssertEqual(graph.phases, [
            .init(phase: .check, start: 1, end: 4),
            .init(phase: .copy, start: 4, end: 12),
            .init(phase: .verify, start: 8, end: 15),
        ])
        XCTAssertTrue(graph.showsPhases)
        XCTAssertEqual(graph.phases(at: 10), [.copy, .verify])
        XCTAssertEqual(graph.phases(at: 2), [.check])
    }

    func testAGapEndsAPhaseSpan() {
        let samples = [1.0, 2, 3, 20, 21, 22].map { JobHistorySample(t: $0, combined: 50, copy: 50, doneBytes: Int64($0 * 5e7)) }
        let graph = JobSpeedGraph.build(samples: samples, kind: "syncBuffer", duration: 22)
        XCTAssertEqual(graph.phases, [
            .init(phase: .copy, start: 1, end: 3),
            .init(phase: .copy, start: 20, end: 22),
        ])
        XCTAssertFalse(graph.showsPhases, "one kind of phase needs no lane")
    }

    // MARK: Columns and smoothing

    func testAggregateKeepsShortSegmentsPointForPoint() {
        let points = (0..<10).map { JobSpeedGraph.Point(t: Double($0), value: Double($0)) }
        let buckets = JobSpeedGraph.aggregate(points, in: 0...9, buckets: 50)
        XCTAssertEqual(buckets.count, 10)
        XCTAssertEqual(buckets[3], .init(t: 3, mean: 3, low: 3, high: 3))
    }

    func testAggregateAveragesEachColumnAndKeepsItsRange() {
        // 100 points over 0..<100 s into 10 columns of 10 s.
        let points = (0..<100).map { JobSpeedGraph.Point(t: Double($0), value: $0 % 10 == 5 ? 100 : 10) }
        let buckets = JobSpeedGraph.aggregate(points, in: 0...100, buckets: 10)
        XCTAssertEqual(buckets.count, 10)
        for bucket in buckets {
            XCTAssertEqual(bucket.mean, 19, accuracy: 0.0001)
            XCTAssertEqual(bucket.low, 10)
            XCTAssertEqual(bucket.high, 100)
        }
        XCTAssertEqual(buckets[0].t, 4.5, accuracy: 0.0001)
    }

    func testVisibleBucketsKeepANeighbourOutsideEachEdge() {
        let samples = (0...100).map { JobHistorySample(t: Double($0), combined: Double($0), doneBytes: Int64($0) * 1_000_000) }
        let graph = JobSpeedGraph.build(samples: samples, kind: "syncBuffer", duration: 100)
        let visible = graph.visibleBuckets(in: 40.5...60.5, buckets: 200)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].first?.t, 40)
        XCTAssertEqual(visible[0].last?.t, 61)
        XCTAssertTrue(graph.visibleBuckets(in: 200...300, buckets: 10).isEmpty)
    }

    func testAZoomInsideAGapDrawsTheTwoEdgesOfTheSegmentAcrossIt() {
        // One segment with points at 0 and 4 (under the gap threshold):
        // zoomed to 1...3, its line still crosses the view.
        let samples = [0.0, 4].map { JobHistorySample(t: $0, combined: 10, doneBytes: Int64($0 * 1e7)) }
        let graph = JobSpeedGraph.build(samples: samples, kind: "syncBuffer", duration: 4)
        XCTAssertEqual(graph.visibleBuckets(in: 1...3, buckets: 10).first?.map(\.t), [0, 4])
    }

    // MARK: Hover

    func testHoverInAGapFindsNoSample() {
        let samples = [1.0, 2, 3, 20, 21].map { JobHistorySample(t: $0, combined: 10) }
        XCTAssertEqual(JobSpeedGraph.sample(near: 2.2, in: samples, within: 5)?.t, 2)
        XCTAssertNil(JobSpeedGraph.sample(near: 11, in: samples, within: 5))
    }

    // MARK: Outliers and smoothing

    /// A job that ran at ~30 files/s and settled thousands of cached files
    /// in its last second: the axis follows the run, and the burst is the
    /// peak, marked off the scale. A scan drops such a burst altogether.
    func testALoneBurstDoesNotFlattenTheRun() {
        var samples = (1...600).map { JobHistorySample(t: Double($0), combined: 0, filesPerSecond: 25 + Double($0 % 10), doneFiles: $0 * 30) }
        samples.append(JobHistorySample(t: 601, combined: 0, filesPerSecond: 8_551, doneFiles: 18_100))
        let graph = JobSpeedGraph.build(samples: samples, kind: "organize", duration: 601)
        XCTAssertEqual(graph.peak?.value, 8_551)
        XCTAssertEqual(graph.yUpper, 50)
        XCTAssertTrue(graph.peakIsOffScale)

        let scan = JobSpeedGraph.build(samples: samples, kind: "faceScan", duration: 601)
        XCTAssertLessThan(scan.peak?.value ?? .infinity, 40)
        XCTAssertFalse(scan.peakIsOffScale)
    }

    func testAnOrdinaryPeakStaysOnTheScale() {
        let samples = (1...100).map { JobHistorySample(t: Double($0), combined: Double(50 + $0), doneBytes: Int64($0) * 100_000_000) }
        let graph = JobSpeedGraph.build(samples: samples, kind: "syncBuffer", duration: 100)
        XCTAssertFalse(graph.peakIsOffScale)
        XCTAssertEqual(graph.yUpper, 200)
    }

    func testSmoothingAveragesNeighboursAndKeepsTheBand() {
        let buckets = [10.0, 30, 10, 30, 10].enumerated().map { JobSpeedGraph.Bucket(t: Double($0.offset), mean: $0.element, low: 0, high: 100) }
        let smoothed = JobSpeedGraph.smoothed(buckets, radius: 1)
        XCTAssertEqual(smoothed.map(\.mean), [20, 50.0 / 3, 70.0 / 3, 50.0 / 3, 20])
        XCTAssertTrue(smoothed.allSatisfy { $0.low == 0 && $0.high == 100 })
        XCTAssertEqual(JobSpeedGraph.smoothed(buckets, radius: 0), buckets)
    }

    func testOnlyMergedColumnsAreSmoothed() {
        let short = (0...20).map { JobHistorySample(t: Double($0), combined: $0 % 2 == 0 ? 10 : 30, doneBytes: Int64($0) * 20_000_000) }
        let graph = JobSpeedGraph.build(samples: short, kind: "syncBuffer", duration: 20)
        XCTAssertEqual(graph.visibleBuckets(in: 0...20, buckets: 100).first.map { Array($0.map(\.mean).prefix(3)) }, [10, 30, 10])
    }
}
