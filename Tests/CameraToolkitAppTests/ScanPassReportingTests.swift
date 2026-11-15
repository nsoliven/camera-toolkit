import CameraToolkitCore
@testable import CameraToolkitApp
import XCTest

/// The Jobs window's numbers for a scan in passes: each one comes from the
/// same counts, and none of them moves the wrong way.
final class ScanPassReporterTests: XCTestCase {
    private func working(_ done: Int, of total: Int = 1_000, bytes: Int64 = 0) -> FileOperationProgress {
        FileOperationProgress(
            phase: "Detecting faces", processedFiles: done, totalFiles: total, processedBytes: bytes,
            totalBytes: 50_000_000_000,
            telemetry: JobTelemetry(step: "Detect", counters: [JobCounter(label: "Faces", value: done / 2)], facts: ["min face 80 px"], work: JobWorkEstimate(unitsDone: done, unitsTotal: total))
        )
    }

    private func matching(_ done: Int, of total: Int) -> FileOperationProgress {
        FileOperationProgress(phase: "Matching people", processedFiles: done, totalFiles: total, telemetry: JobTelemetry(step: "Match", counters: [JobCounter(label: "Faces", value: 5)]))
    }

    /// The orientation check runs before the scan counts anything: it must
    /// say so without moving the bar or jumping it to the end of the pass.
    func testTheOrientationCheckHoldsTheBar() {
        let dogs = ScanPassReporter(pass: JobScanPass(index: 2, count: 2, subject: .dogs))
        let before = dogs.update(from: working(0))
        let checking = dogs.update(from: FileOperationProgress(phase: FaceIndexService.orientationCheckPhase, processedFiles: 400, totalFiles: 900))
        XCTAssertEqual(checking.progress, before.progress, accuracy: 1e-9)
        XCTAssertTrue(checking.note.contains(FaceIndexService.orientationCheckPhase))
        XCTAssertGreaterThanOrEqual(dogs.update(from: working(100)).progress, checking.progress)
    }

    func testPercentNeverGoesBackwardAcrossPassesAndMatching() {
        let faces = ScanPassReporter(pass: JobScanPass(index: 1, count: 2, subject: .faces))
        let dogs = ScanPassReporter(pass: JobScanPass(index: 2, count: 2, subject: .dogs))
        var updates = [faces.update(from: working(0))]
        updates += stride(from: 100, through: 1_000, by: 100).map { faces.update(from: working($0)) }
        updates += [faces.update(from: matching(0, of: 66_000)), faces.update(from: matching(42_000, of: 66_000))]
        updates += stride(from: 0, through: 1_000, by: 100).map { dogs.update(from: working($0)) }
        updates += [dogs.update(from: matching(0, of: 300))]
        for (earlier, later) in zip(updates, updates.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.progress, later.progress)
        }
        XCTAssertEqual(updates.last?.progress ?? 0, 0.99, accuracy: 0.0001, "finishing still has to run")
    }

    func testPercentComesFromTheCount() {
        let pass = JobScanPass(index: 2, count: 2, subject: .dogs)
        let reporter = ScanPassReporter(pass: pass)
        let update = reporter.update(from: working(250))
        XCTAssertEqual(update.progress, 0.625, accuracy: 0.0001)
        XCTAssertEqual(update.processedFiles, 250)
        XCTAssertEqual(update.totalFiles, 1_000)
    }

    func testMatchingFacesNeverReplaceTheFileCounts() {
        let reporter = ScanPassReporter(pass: JobScanPass(index: 1, count: 2, subject: .faces))
        _ = reporter.update(from: working(1_000, bytes: 50_000_000_000))
        let update = reporter.update(from: matching(42_000, of: 66_000))
        XCTAssertEqual(update.processedFiles, 1_000)
        XCTAssertEqual(update.totalFiles, 1_000)
        XCTAssertEqual(update.processedBytes, 50_000_000_000)
        XCTAssertEqual(update.totalBytes, 50_000_000_000)
        XCTAssertEqual(update.note, "Face scan: Matching people")
    }

    func testADogPassSaysDogs() {
        let reporter = ScanPassReporter(pass: JobScanPass(index: 2, count: 2, subject: .dogs))
        let update = reporter.update(from: working(10))
        XCTAssertEqual(update.note, "Dog scan: Detecting dogs")
        XCTAssertEqual(update.telemetry?.counter("Dogs"), 5)
        XCTAssertNil(update.telemetry?.counter("Faces"))
        XCTAssertEqual(update.telemetry?.facts, ["min dog 80 px"])
        XCTAssertEqual(update.telemetry?.scanPass?.label, "Pass 2 of 2 · Dogs")
    }

    func testAOnePassScanHasNoPassWording() {
        let reporter = ScanPassReporter(pass: JobScanPass(index: 1, count: 1, subject: .faces))
        let update = reporter.update(from: working(500))
        XCTAssertEqual(update.progress, 0.5, accuracy: 0.0001)
        XCTAssertNil(update.telemetry?.scanPass?.label)
    }
}

@MainActor
final class ScanPassDisplayTests: XCTestCase {
    private func scan(files: Int, total: Int, bytes: Int64, totalBytes: Int64, created: Date, telemetry: JobTelemetry? = nil, progress: Double = 0.5) -> JobSnapshot {
        var job = JobSnapshot(action: .faceScan, state: .running, progress: progress, note: "Dog scan: Detecting dogs", totalFiles: total, totalBytes: totalBytes, createdAt: created)
        job.processedFiles = files
        job.processedBytes = bytes
        job.telemetry = telemetry
        return job
    }

    /// The real sequence: the first pass, then matching with its face
    /// counts and no bytes, then the second pass from zero.
    func testMatchingAndAPassChangeKeepTheJobsTrack() throws {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let id = UUID()
        var t = 0.0
        func tick(_ files: Int, _ total: Int, _ bytes: Int64, _ totalBytes: Int64) {
            var job = scan(files: files, total: total, bytes: bytes, totalBytes: totalBytes, created: created)
            job.id = id
            monitor.tick(job: job, now: t, wallNow: created.addingTimeInterval(t))
            t += 1
        }
        for second in 0..<300 { tick(second * 8, 2_400, Int64(second) * 400_000_000, 120_000_000_000) }
        tick(21_000, 66_000, 0, 0)
        tick(66_000, 66_000, 0, 0)
        tick(0, 0, 0, 0)
        for second in 0..<20 { tick(second * 8, 2_400, Int64(second) * 400_000_000, 120_000_000_000) }

        var job = scan(files: 152, total: 2_400, bytes: 7_600_000_000, totalBytes: 120_000_000_000, created: created)
        job.id = id
        let readout = monitor.readout(for: job, now: t)
        XCTAssertEqual(readout.unit, .filesPerSecond)
        // The first pass's photos are still in the average; matching's
        // faces are not, though no count here says which is which.
        XCTAssertGreaterThan(try XCTUnwrap(readout.average), 1)
    }

    func testEveryReadoutOfAScanIsInPhotos() {
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let job = scan(files: 100, total: 1_000, bytes: 4_000_000_000, totalBytes: 40_000_000_000, created: created)
        let samples = (1...120).map {
            JobHistorySample(t: Double($0), combined: 300, filesPerSecond: 8, doneBytes: Int64($0) * 30_000_000, doneFiles: $0 * 8)
        }
        let graph = JobSpeedGraph.build(samples: samples, kind: "faceScan", duration: 120)
        let readout = JobThroughputReadout(unit: .filesPerSecond, current: 8, average: 0.2)
        let readouts = JobDetailFacts.liveReadouts(readout, graph: graph, job: job)
        XCTAssertEqual(Set(readouts.map(\.unit)), ["photos/s"])
        XCTAssertEqual(readouts.first { $0.caption == "average" }?.value, "8.0", "the average is the graph's, over the work")
    }

    func testPeakIsNeverBelowTheCurrentSpeed() {
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let job = scan(files: 100, total: 1_000, bytes: 4_000_000_000, totalBytes: 40_000_000_000, created: created)
        let samples = (1...120).map {
            JobHistorySample(t: Double($0), combined: 300, filesPerSecond: 8, doneBytes: Int64($0) * 30_000_000, doneFiles: $0 * 8)
        }
        let graph = JobSpeedGraph.build(samples: samples, kind: "faceScan", duration: 120)
        let readout = JobThroughputReadout(unit: .filesPerSecond, current: 12.9, average: 0.2)
        let readouts = JobDetailFacts.liveReadouts(readout, graph: graph, job: job)
        XCTAssertEqual(readouts.first { $0.caption == "peak" }?.value, "12.9")
    }

    func testAFinishedScanLeadsInPhotosEvenWithBytes() {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let job = JobHistoryJob(kind: "faceScan", title: "Face scan: Trip 2026", startedAt: started, endedAt: started.addingTimeInterval(120), outcome: .succeeded, totalFiles: 960, totalBytes: 40_000_000_000, bytesDone: 40_000_000_000)
        let samples = (1...120).map {
            JobHistorySample(t: Double($0), combined: 300, filesPerSecond: 8, doneBytes: Int64($0) * 30_000_000, doneFiles: $0 * 8)
        }
        let graph = JobSpeedGraph.build(samples: samples, kind: "faceScan", duration: 120)
        let readouts = JobDetailFacts.finishedReadouts(job: job, graph: graph)
        XCTAssertEqual(Set(readouts.map(\.unit)), ["photos/s"])
    }

    func testCountsLineAgreesWithItself() {
        let pass = JobScanPass(index: 2, count: 2, subject: .dogs)
        let telemetry = JobTelemetry(
            counters: [JobCounter(label: "Dogs", value: 3)],
            work: JobWorkEstimate(unitsDone: 250, unitsTotal: nil, unitLabel: "photos and frames"),
            scanPass: pass
        )
        let job = scan(files: 250, total: 1_000, bytes: 1_000_000_000, totalBytes: 4_000_000_000, created: Date(), telemetry: telemetry, progress: 0.625)
        XCTAssertEqual(JobDetailFacts.liveCounts(job), "250 of 1,000 files · 25% of this pass · 1 GB of 4 GB read · 3 dogs")
        XCTAssertEqual(JobDetailFacts.liveSubline(job, remaining: "~12 m left"), "Pass 2 of 2 · Dogs · ~12 m left")
        XCTAssertEqual(JobDetailFacts.liveHeadline(job), "Detecting dogs")
    }

    func testAnEarlierPassSaysTheTimeIsForThisPass() {
        let telemetry = JobTelemetry(scanPass: JobScanPass(index: 1, count: 2, subject: .faces))
        let job = scan(files: 1, total: 10, bytes: 0, totalBytes: 0, created: Date(), telemetry: telemetry)
        XCTAssertEqual(JobDetailFacts.liveSubline(job, remaining: "~3 m left"), "Pass 1 of 2 · Faces · ~3 m left in this pass")
    }

    func testOtherJobsKeepTheirCountsLine() {
        var job = JobSnapshot(action: .syncBuffer, state: .running, progress: 0.3, note: "Sync to NAS: Copying", totalFiles: 8_200, totalBytes: 9_000_000_000, createdAt: Date())
        job.processedFiles = 3_412
        job.processedBytes = 2_100_000_000
        job.telemetry = JobTelemetry(step: "Copying to NAS", counters: [JobCounter(label: "Failed", value: 2)])
        XCTAssertEqual(JobDetailFacts.liveCounts(job), "3,412 of 8,200 files · 4,788 to go · 2.1 GB of 9 GB read · 2 failed")
        XCTAssertEqual(JobDetailFacts.liveHeadline(job), "Copying to NAS")
        XCTAssertNil(JobDetailFacts.liveSubline(job, remaining: nil))
    }

    func testPassPaceWaitsThenEstimatesTheCurrentPassOnly() throws {
        var pace = JobPassPace(files: 900, bytes: 90_000_000_000, at: 0)
        pace.observe(files: 950, bytes: 95_000_000_000, at: 10)
        // The second pass starts: the counters fall.
        pace.observe(files: 0, bytes: 0, at: 20)
        XCTAssertNil(pace.secondsRemaining(totalFiles: 1_000, totalBytes: 100_000_000_000, at: 20))
        pace.observe(files: 50, bytes: 5_000_000_000, at: 45)
        XCTAssertNil(pace.secondsRemaining(totalFiles: 1_000, totalBytes: 100_000_000_000, at: 45), "under 30 s into the pass")
        pace.observe(files: 100, bytes: 10_000_000_000, at: 70)
        let seconds = try XCTUnwrap(pace.secondsRemaining(totalFiles: 1_000, totalBytes: 100_000_000_000, at: 70))
        XCTAssertEqual(seconds, 450, accuracy: 1, "90 GB left at 200 MB/s")
    }

    func testAScanWithoutACompleteFramePlanStillGetsATime() throws {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let telemetry = JobTelemetry(work: JobWorkEstimate(unitsDone: 0, unitsTotal: nil, totalIsEstimate: true))
        var job = scan(files: 0, total: 1_000, bytes: 0, totalBytes: 10_000_000_000, created: created, telemetry: telemetry)
        for second in 0...5 {
            job.processedFiles = second * 4
            job.processedBytes = Int64(second) * 40_000_000
            monitor.tick(job: job, now: Double(second), wallNow: created.addingTimeInterval(Double(second)))
        }
        XCTAssertEqual(monitor.remainingEstimate(for: job), .estimating, "too early")
        XCTAssertNil(JobActivityDetail.remainingText(.estimating), "and early says nothing")
        for second in 6...60 {
            job.processedFiles = second * 4
            job.processedBytes = Int64(second) * 40_000_000
            monitor.tick(job: job, now: Double(second), wallNow: created.addingTimeInterval(Double(second)))
        }
        guard case .seconds(let seconds) = try XCTUnwrap(monitor.remainingEstimate(for: job)) else {
            return XCTFail("expected a time")
        }
        XCTAssertEqual(seconds, 190, accuracy: 5)
    }

    func testPassBarOnlyEverFills() {
        XCTAssertEqual(JobPassBar.segmentFill(0, count: 2, fraction: 0.5), 1)
        XCTAssertEqual(JobPassBar.segmentFill(1, count: 2, fraction: 0.5), 0)
        XCTAssertEqual(JobPassBar.segmentFill(1, count: 2, fraction: 0.75), 0.5)
    }

    func testHoverDuringMatchingShowsNoRate() {
        let samples = (1...60).map {
            JobHistorySample(t: Double($0), combined: 200, filesPerSecond: 8, doneBytes: Int64($0) * 10_000_000, doneFiles: $0 * 8)
        } + [
            JobHistorySample(t: 61, filesPerSecond: 0, doneBytes: 0, doneFiles: 0),
            JobHistorySample(t: 62, filesPerSecond: 11_900, doneBytes: 0, doneFiles: 66_000),
        ]
        let graph = JobSpeedGraph.build(samples: samples, kind: "faceScan", duration: 62)
        let lines = JobDetailFacts.hoverLines(sample: samples.last, t: 61.5, graph: graph, kind: "faceScan")
        XCTAssertEqual(lines.rows.map(\.value), ["Matching and grouping"])
    }

    func testRunningScanRowIsNamedForItsPass() {
        let recorded = JobHistoryJob(kind: "faceScan", title: "Face and dog scan: Beach Day", startedAt: Date(), outcome: .running)
        let telemetry = JobTelemetry(scanPass: JobScanPass(index: 2, count: 2, subject: .dogs))
        let job = scan(files: 1, total: 10, bytes: 0, totalBytes: 0, created: Date(), telemetry: telemetry)
        XCTAssertEqual(JobsList.entry(job, recorded: recorded, now: Date()).title, "Dog scan: Beach Day")
    }

    func testOldRecordsStillOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScanPassOldRecords-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("job-history.sqlite")
        defer { CatalogDatabase.checkpointAndClose(url: url) }
        let store = try XCTUnwrap(JobHistoryStore.shared(at: url))
        let started = Date(timeIntervalSince1970: 1_780_000_000)
        // The shape a two-pass scan left before passes were reported.
        var samples = (2...300).map {
            JobHistorySample(t: Double($0), combined: 200, filesPerSecond: 8, doneBytes: Int64($0) * 10_000_000, doneFiles: $0 * 8)
        }
        samples += [
            JobHistorySample(t: 301, combined: 0, filesPerSecond: 0, doneBytes: 0, doneFiles: 0),
            JobHistorySample(t: 302, combined: 0, filesPerSecond: 11_900, doneBytes: 0, doneFiles: 66_000),
            JobHistorySample(t: 310, combined: 0, filesPerSecond: 3_400, doneBytes: 0, doneFiles: 44_000),
            JobHistorySample(t: 312, combined: 0, filesPerSecond: 0, doneBytes: 0, doneFiles: 0),
        ]
        samples += (1...60).map {
            JobHistorySample(t: 312 + Double($0), combined: 200, filesPerSecond: 9, doneBytes: Int64($0) * 10_000_000, doneFiles: $0 * 9)
        }
        let job = JobHistoryJob(kind: "faceScan", title: "Face scan: Beach Day", startedAt: started, endedAt: started.addingTimeInterval(372), outcome: .succeeded, totalFiles: 540, totalBytes: 600_000_000, bytesDone: 600_000_000)
        try store.write(job: job, samples: samples, items: [], jobID: job.id)

        let detail = JobHistoryDetail(
            job: try XCTUnwrap(try store.job(id: job.id)),
            samples: try store.samples(jobID: job.id),
            items: try store.items(jobID: job.id)
        )
        XCTAssertEqual(detail.graph.scanPasses.count, 2)
        XCTAssertLessThan(try XCTUnwrap(detail.graph.peak).value, 15)
        let hero = JobDetailFacts.finishedHero(
            job: detail.job, live: nil, outcome: .succeeded,
            display: JobDetailFacts.outcomeDisplay(.succeeded, job: detail.job),
            graph: detail.graph, elapsed: 372
        )
        XCTAssertEqual(hero.headline, "Done in 6:12")
        XCTAssertEqual(hero.value, "\(detail.graph.filesDone.formatted()) photos")
    }

    func testFinishedHeroSaysHowItEnded() {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let conflicts = JobHistoryJob(kind: "syncBuffer", title: "Sync", startedAt: started, endedAt: started.addingTimeInterval(60), outcome: .failed, bytesDone: 2_000_000_000, conflicts: 3)
        let graph = JobSpeedGraph.build(samples: [], kind: "syncBuffer", duration: 60)
        let hero = JobDetailFacts.finishedHero(job: conflicts, live: nil, outcome: .failed, display: JobDetailFacts.outcomeDisplay(.failed, job: conflicts), graph: graph, elapsed: 60)
        XCTAssertEqual(hero.headline, "Done with 3 conflicts")
        XCTAssertEqual(hero.value, "2 GB")

        let failed = JobHistoryJob(kind: "syncBuffer", title: "Sync", startedAt: started, endedAt: started.addingTimeInterval(62), outcome: .failed, failed: 1)
        let failedHero = JobDetailFacts.finishedHero(job: failed, live: nil, outcome: .failed, display: JobDetailFacts.outcomeDisplay(.failed, job: failed), graph: graph, elapsed: 62)
        XCTAssertEqual(failedHero.headline, "Failed after 1:02")
    }
}

final class JobListFoldingTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(_ title: String, _ index: Int, outcome: JobHistoryOutcome = .succeeded, conflicts: Int = 0) -> JobListEntry {
        var job = JobHistoryJob(kind: "ingestCard", title: title, startedAt: day.addingTimeInterval(Double(-index) * 60), endedAt: day.addingTimeInterval(Double(-index) * 60 + 30), outcome: outcome, conflicts: conflicts)
        job.summary = nil
        return JobsList.entry(job, now: day)
    }

    func testIdenticalCleanJobsFoldAndNothingIsLost() {
        let entries = (0..<5).map { entry("Copied queue to buffer", $0) }
        let items = JobsList.foldedRuns(entries)
        XCTAssertEqual(items.count, 1)
        guard case .run(let run) = items[0] else { return XCTFail("expected a run") }
        XCTAssertEqual(run.entries.map(\.id), entries.map(\.id))
    }

    func testTwoInARowStayAsTheyAre() {
        let items = JobsList.foldedRuns((0..<2).map { entry("Copied queue to buffer", $0) })
        XCTAssertEqual(items.count, 2)
    }

    func testAProblemIsNeverFolded() {
        let warning = entry("Copied queue to buffer", 3, outcome: .failed)
        let entries = (0..<3).map { entry("Copied queue to buffer", $0) } + [warning] + (4..<7).map { entry("Copied queue to buffer", $0) }
        let items = JobsList.foldedRuns(entries)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[1], .job(warning))
        let shown = items.flatMap { item -> [UUID] in
            switch item {
            case .job(let job): [job.id]
            case .run(let run): run.entries.map(\.id)
            }
        }
        XCTAssertEqual(shown, entries.map(\.id))
    }

    func testDifferentTitlesDoNotFoldTogether() {
        let entries = [entry("Copied queue to buffer", 0), entry("Copied queue to buffer", 1), entry("Sync to NAS", 2), entry("Copied queue to buffer", 3)]
        XCTAssertEqual(JobsList.foldedRuns(entries).count, 4)
    }
}
