@testable import CameraToolkitCore
import Foundation
import GRDB
import XCTest

/// `job-history.sqlite`: the store, the recorder, the Sync to NAS hook, and
/// the pure helpers the History view draws with.
final class JobHistoryTests: XCTestCase {
    /// A clock the test moves by hand.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000
        func read() -> TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    private func withStore<T>(_ body: (URL, JobHistoryStore) throws -> T) throws -> T {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent(JobHistoryStore.fileName)
            defer { CatalogDatabase.checkpointAndClose(url: url) }
            return try body(url, try JobHistoryStore(url: url))
        }
    }

    // MARK: Store

    func testTheStoreRoundTripsJobsSamplesAndItems() throws {
        try withStore { _, store in
            let id = UUID()
            let started = Date(timeIntervalSince1970: 1_790_000_000.25)
            var job = JobHistoryJob(
                id: id, kind: "syncBuffer", title: "Synced a test event to the NAS", startedAt: started,
                totalFiles: 3, totalBytes: 3_000, configuration: "4 transfers in parallel · SMB verify"
            )
            try store.insert(job)
            let samples = [
                JobHistorySample(t: 1, combined: nil, activeTransfers: 4, doneBytes: 10, doneFiles: 0),
                JobHistorySample(t: 2, combined: 112.5, copy: 60, verify: 58, hash: nil, remoteVerify: nil, filesPerSecond: 1.5, activeTransfers: 3, cpu: 0.2, gpu: nil, transferBytes: 1_000, doneBytes: 900, doneFiles: 1),
            ]
            let items = [
                JobHistoryItem(relativePath: "2026/Event/Originals/Cam/A.ARW", byteCount: 1_000, start: 0.5, end: 1.5, slot: 0, outcome: .copied, verifyMethod: "smb", copySeconds: 0.6, verifySeconds: 0.3),
                JobHistoryItem(relativePath: "2026/Event/Originals/Cam/B.ARW", byteCount: 1_000, start: nil, end: 0.1, outcome: .alreadyVerified),
                JobHistoryItem(relativePath: "2026/Event/Originals/Cam/C.ARW", byteCount: 1_000, start: 1, end: 2, slot: 1, outcome: .failed, error: "Input/output error"),
            ]
            job.outcome = .succeeded
            job.endedAt = started.addingTimeInterval(2)
            job.copied = 1
            job.alreadyVerified = 1
            job.failed = 1
            job.bytesDone = 1_000
            job.transferBytes = 2_000
            job.summary = JobHistorySummary(
                phases: [JobPhaseTotal(label: "Copy", seconds: 0.6, bytes: 1_000, activeSeconds: 0.6)],
                verifyMethod: "smb",
                note: "Sync to NAS: 1 copied and verified."
            )
            try store.write(job: job, samples: samples, items: items, jobID: id)

            XCTAssertEqual(try store.job(id: id), job)
            XCTAssertEqual(try store.jobs(), [job])
            XCTAssertEqual(try store.samples(jobID: id), samples)
            let read = try store.items(jobID: id)
            XCTAssertEqual(read, items)
            XCTAssertEqual(read[0].fileName, "A.ARW")
            XCTAssertEqual(try XCTUnwrap(read[0].averageMegabytesPerSecond), 0.001, accuracy: 1e-9, "1,000 bytes over 1 s")
            XCTAssertNil(read[1].averageMegabytesPerSecond, "no transfer, no speed")
            XCTAssertEqual(job.averageBytesPerSecond(), 1_000, "the combined counter over the whole job")
        }
    }

    func testMigrationsCreateIndexedTablesAndReopeningIsIdempotent() throws {
        try withStore { url, store in
            try store.insert(JobHistoryJob(kind: "faceScan", title: "Scanned faces", startedAt: Date(), outcome: .succeeded))
            let reopened = try JobHistoryStore(url: url)
            XCTAssertEqual(try reopened.jobs().count, 1, "reopening migrates nothing twice and keeps rows")
            let writer = try CatalogDatabase.writer(for: url)
            let indexes = try writer.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'")
            }
            XCTAssertTrue(Set(indexes).isSuperset(of: ["job_samples_job_id", "job_items_job_id", "jobs_started_at"]), "\(indexes)")
            let migrations = try writer.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
            XCTAssertEqual(migrations, ["v1"])
            let journal = try writer.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
            XCTAssertEqual(journal, "wal")
        }
    }

    func testJobsStillRunningAtLaunchBecomeInterruptedAtTheirLastRecordedSecond() throws {
        try withStore { url, store in
            let started = Date(timeIntervalSince1970: 1_790_000_000)
            let running = JobHistoryJob(kind: "syncBuffer", title: "Crashed sync", startedAt: started)
            let done = JobHistoryJob(kind: "ingestCard", title: "Copied a card", startedAt: started, endedAt: started.addingTimeInterval(5), outcome: .succeeded)
            try store.insert(running)
            try store.insert(done)
            try store.write(job: nil, samples: [JobHistorySample(t: 41), JobHistorySample(t: 42)], items: [
                JobHistoryItem(relativePath: "a", byteCount: 1, start: 30, end: 40, outcome: .copied),
            ], jobID: running.id)

            _ = try JobHistoryStore(url: url, now: started.addingTimeInterval(3_600))
            let after = try XCTUnwrap(store.job(id: running.id))
            XCTAssertEqual(after.outcome, .interrupted)
            XCTAssertEqual(try XCTUnwrap(after.endedAt).timeIntervalSince(started), 42, accuracy: 0.01)
            XCTAssertEqual(try store.job(id: done.id)?.outcome, .succeeded, "finished jobs are left alone")
            XCTAssertEqual(try store.markInterrupted(), 0)
        }
    }

    func testOldSamplesArePrunedButJobsAndFileRowsStay() throws {
        try withStore { url, store in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let old = JobHistoryJob(kind: "syncBuffer", title: "Old", startedAt: now.addingTimeInterval(-JobHistoryStore.sampleRetention - 86_400), outcome: .succeeded)
            let recent = JobHistoryJob(kind: "syncBuffer", title: "Recent", startedAt: now.addingTimeInterval(-86_400), outcome: .succeeded)
            for job in [old, recent] {
                try store.write(job: job, samples: (1...3).map { JobHistorySample(t: Double($0)) }, items: [
                    JobHistoryItem(relativePath: "x", byteCount: 1, start: 0, end: 1, outcome: .copied),
                ], jobID: job.id)
            }
            _ = try JobHistoryStore(url: url, now: now)
            XCTAssertTrue(try store.samples(jobID: old.id).isEmpty)
            XCTAssertEqual(try store.items(jobID: old.id).count, 1)
            XCTAssertNotNil(try store.job(id: old.id))
            XCTAssertEqual(try store.samples(jobID: recent.id).count, 3)
        }
    }

    func testAStoreThatCannotOpenIsNilAndARecorderWithoutOneStillRecordsInMemory() throws {
        try withTemporaryDirectory { root in
            // A file where the folder should be: nothing can be created under it.
            let blocker = try writeFile(root.appendingPathComponent("NotAFolder"), "x")
            XCTAssertNil(JobHistoryStore.shared(at: blocker.appendingPathComponent(JobHistoryStore.fileName)))

            let clock = ManualClock()
            let recorder = JobHistoryRecorder(storeURL: blocker.appendingPathComponent(JobHistoryStore.fileName), kind: "syncBuffer", title: "t", clock: { clock.read() })
            for second in 0..<3 {
                clock.advance(1)
                recorder.observe(.init(processedFiles: second, totalFiles: 3, processedBytes: Int64(second) * 100, totalBytes: 300))
            }
            recorder.finish(outcome: .succeeded, note: nil)
            recorder.flush()
            XCTAssertEqual(recorder.samples().count, 3)
        }
    }

    // MARK: Recorder

    func testTheRecorderSamplesOnceASecondAndWritesInBatches() throws {
        try withStore { _, store in
            let clock = ManualClock()
            let recorder = JobHistoryRecorder(store: store, kind: "syncBuffer", title: "Batching", clock: { clock.read() })
            recorder.drain()
            XCTAssertEqual(try store.job(id: recorder.jobID)?.outcome, .running, "the running row lands at once")

            // 10 MB/s over the link, reported four times a second.
            var transferred: Int64 = 0
            func tick() {
                clock.advance(0.25)
                transferred += 2_500_000
                recorder.observe(.init(
                    processedFiles: 0, totalFiles: 10, processedBytes: transferred, totalBytes: 100_000_000,
                    telemetry: JobTelemetry(transferBytes: transferred)
                ))
                recorder.drain()
            }
            for _ in 0..<18 { tick() } // 4.5 s
            XCTAssertTrue(try store.samples(jobID: recorder.jobID).isEmpty, "nothing is written before the first batch is due")
            XCTAssertEqual(recorder.samples().map(\.t), [0.25, 1.25, 2.25, 3.25, 4.25], "one sample a second, kept in memory")
            for _ in 0..<4 { tick() } // 5.5 s
            let written = try store.samples(jobID: recorder.jobID)
            XCTAssertEqual(written.map(\.t), [0.25, 1.25, 2.25, 3.25, 4.25, 5.25], "the first batch: every sample so far, in one write")
            XCTAssertEqual(try XCTUnwrap(written.last?.combined), 10, accuracy: 0.001, "combined MB/s over the trailing window")

            recorder.finish(outcome: .succeeded, note: "Done.")
            recorder.flush()
            let job = try XCTUnwrap(store.job(id: recorder.jobID))
            XCTAssertEqual(job.outcome, .succeeded)
            XCTAssertEqual(job.summary?.note, "Done.")
            XCTAssertEqual(job.totalBytes, 100_000_000)
            XCTAssertEqual(try store.samples(jobID: recorder.jobID).count, recorder.samples().count)

            // After the end, nothing more is recorded.
            for _ in 0..<8 { tick() }
            XCTAssertEqual(recorder.samples().count, 6)
        }
    }

    func testPhaseRatesAreOverTheTimeEachPhaseRan() throws {
        let clock = ManualClock()
        let recorder = JobHistoryRecorder(store: nil, kind: "syncBuffer", title: "Rates", clock: { clock.read() })
        // Copy runs half of each second at 100 MB/s; verify never runs.
        for second in 1...8 {
            clock.advance(1)
            let copy = JobPhaseTotal(label: "Copy", seconds: Double(second) * 0.5, bytes: Int64(second) * 50_000_000, activeSeconds: Double(second) * 0.5)
            recorder.observe(.init(
                processedFiles: second, totalFiles: 10, processedBytes: 0, totalBytes: 0,
                telemetry: JobTelemetry(
                    activeItems: [JobActiveItem(name: "a", path: "a", step: "Copying to NAS", slot: 0, phase: "Copying"), JobActiveItem(name: "b", path: "b", step: "Verified", slot: 1, phase: "Verified")],
                    phases: [copy],
                    transferBytes: Int64(second) * 50_000_000
                )
            ))
        }
        recorder.drain()
        let last = try XCTUnwrap(recorder.samples().last)
        XCTAssertEqual(try XCTUnwrap(last.copy), 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(last.combined), 50, accuracy: 0.001)
        XCTAssertNil(last.verify, "a phase that did not run has no rate, not zero")
        XCTAssertEqual(try XCTUnwrap(last.filesPerSecond), 1, accuracy: 0.001)
        XCTAssertEqual(last.activeTransfers, 1, "only rows that are working count")
    }

    // MARK: Sync to NAS

    private struct Fixture {
        var nas: URL
        var plan: NASSyncPlan
        var contents: [String: Data]
    }

    private func fixture(_ root: URL, count: Int = 9) throws -> Fixture {
        let drive = root.appendingPathComponent("Drive")
        let nas = root.appendingPathComponent("NAS")
        try FileManager.default.createDirectory(at: nas, withIntermediateDirectories: true)
        var items: [NASSyncItem] = []
        var contents: [String: Data] = [:]
        for index in 0..<count {
            let relative = "2026/Event/Originals/Cam \(index % 2)/IMG_\(index).ARW"
            let data = Data((0..<(2_000 + index * 53)).map { UInt8(($0 * (index + 5)) & 0xFF) })
            let url = try writeFile(drive.appendingPathComponent(relative), data)
            let entry = try XCTUnwrap(LayoutMigrationDisk.lstatEntry(url.path))
            items.append(NASSyncItem(sourcePath: url.path, relativePath: relative, byteCount: Int64(data.count), modifiedAt: entry.modifiedAt, eventID: nil))
            contents[relative] = data
        }
        return Fixture(nas: nas, plan: NASSyncPlan(items: items), contents: contents)
    }

    /// Everything a report says except how long things took.
    private func outcome(_ report: NASSyncReport) -> [String] {
        [
            report.copied.sorted().joined(separator: "|"),
            report.matchedExisting.sorted().joined(separator: "|"),
            report.alreadyVerified.sorted().joined(separator: "|"),
            report.conflicts.map(\.path).sorted().joined(separator: "|"),
            report.failed.map(\.path).sorted().joined(separator: "|"),
            "\(report.notAttempted) \(report.bytesCopied) \(report.foldersCreated) \(report.stoppedReason ?? "-") \(report.succeeded)",
            "\(report.timings.parallelTransfers) \(report.timings.verification) \(report.timings.copyBytes) \(report.timings.smbVerifyBytes)",
        ]
    }

    func testARecordedSyncCopiesExactlyWhatAnUnrecordedOneDoes() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root)
            let otherNAS = root.appendingPathComponent("NAS2")
            try FileManager.default.createDirectory(at: otherNAS, withIntermediateDirectories: true)
            let historyURL = root.appendingPathComponent(JobHistoryStore.fileName)
            defer { CatalogDatabase.checkpointAndClose(url: historyURL) }
            let store = try JobHistoryStore(url: historyURL)
            let recorder = JobHistoryRecorder(store: store, kind: "syncBuffer", title: "Recorded")
            let options = NASSyncOptions(parallelTransfers: 3)

            let plain = try NASSyncService(store: nil, options: options).sync(f.plan, nasRoot: f.nas)
            let recorded = try NASSyncService(store: nil, options: options, recorder: recorder).sync(f.plan, nasRoot: otherNAS)
            XCTAssertEqual(outcome(plain), outcome(recorded))
            for relative in f.contents.keys {
                XCTAssertEqual(try Data(contentsOf: f.nas.appendingPathComponent(relative)), try Data(contentsOf: otherNAS.appendingPathComponent(relative)))
            }
            XCTAssertEqual(
                try FileManager.default.subpathsOfDirectory(atPath: f.nas.path).sorted(),
                try FileManager.default.subpathsOfDirectory(atPath: otherNAS.path).sorted(),
                "the same files and folders, nothing left behind"
            )
            XCTAssertEqual(Set(recorded.copied), Set(f.contents.keys))

            // A second pass over both: the same files match, the same way.
            let plainAgain = try NASSyncService(store: nil, options: options).sync(f.plan, nasRoot: f.nas)
            let recordedAgain = try NASSyncService(store: nil, options: options, recorder: JobHistoryRecorder(store: store, kind: "syncBuffer", title: "Again")).sync(f.plan, nasRoot: otherNAS)
            XCTAssertEqual(outcome(plainAgain), outcome(recordedAgain))
            XCTAssertEqual(recordedAgain.matchedExisting.count, f.plan.items.count)
        }
    }

    func testASyncRecordsItsJobSamplesAndOneRowPerFile() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, count: 12)
            let historyURL = root.appendingPathComponent(JobHistoryStore.fileName)
            defer { CatalogDatabase.checkpointAndClose(url: historyURL) }
            let store = try JobHistoryStore(url: historyURL)
            let recorder = JobHistoryRecorder(store: store, kind: JobAction.syncBuffer.rawValue, title: "Synced to the NAS")
            // Slow the SMB re-read so transfers overlap and the run spans
            // more than a second.
            NASFileIO.verificationHashOverride = { _ in usleep(120_000); return nil }
            defer { NASFileIO.verificationHashOverride = nil }
            let report = try NASSyncService(store: nil, options: NASSyncOptions(parallelTransfers: 4), recorder: recorder).sync(f.plan, nasRoot: f.nas)
            XCTAssertTrue(report.succeeded, "\(report)")
            recorder.finish(outcome: .succeeded, note: "Sync to NAS: 12 copied and verified.")
            recorder.flush()

            let job = try XCTUnwrap(store.job(id: recorder.jobID))
            XCTAssertEqual(job.outcome, .succeeded)
            XCTAssertEqual(job.kind, "syncBuffer")
            XCTAssertEqual(job.totalFiles, 12)
            XCTAssertEqual(job.totalBytes, f.plan.totalBytes, "the plan's bytes, not the doubled work counter")
            XCTAssertEqual(job.bytesDone, f.plan.totalBytes)
            XCTAssertEqual(job.transferBytes, 2 * f.plan.totalBytes, "copies and SMB re-reads")
            XCTAssertEqual(job.copied, 12)
            XCTAssertEqual(job.configuration, "4 transfers in parallel · SMB verify")
            XCTAssertEqual(job.summary?.verifyMethod, "smb")
            XCTAssertEqual(job.summary?.timings, report.timings)
            XCTAssertTrue(job.summary?.phases.contains { $0.label == "Copy" && $0.bytes == f.plan.totalBytes } == true)
            XCTAssertNotNil(job.endedAt)

            let items = try store.items(jobID: recorder.jobID)
            XCTAssertEqual(Set(items.map(\.relativePath)), Set(f.contents.keys))
            for item in items {
                XCTAssertEqual(item.outcome, .copied)
                XCTAssertEqual(item.verifyMethod, "smb")
                let start = try XCTUnwrap(item.start)
                XCTAssertLessThanOrEqual(start, item.end)
                XCTAssertTrue((0..<4).contains(try XCTUnwrap(item.slot)))
                XCTAssertNotNil(item.copySeconds)
                XCTAssertGreaterThan(try XCTUnwrap(item.verifySeconds), 0.1)
                XCTAssertEqual(item.byteCount, Int64(f.contents[item.relativePath]?.count ?? -1))
            }
            // Four transfers: some files were in flight together.
            let index = JobHistoryFlightIndex(items)
            let overlap = items.compactMap(\.start).map { index.inFlight(at: $0 + 0.01).count }.max() ?? 0
            XCTAssertGreaterThan(overlap, 1)

            let samples = try store.samples(jobID: recorder.jobID)
            XCTAssertFalse(samples.isEmpty)
            XCTAssertEqual(samples.map(\.t), samples.map(\.t).sorted())
            XCTAssertEqual(samples.last?.transferBytes, 2 * f.plan.totalBytes, "the final sample is the end state")
        }
    }

    func testAResumedSyncRecordsAlreadyVerifiedFilesWithoutATransfer() throws {
        try withTemporaryDirectory { root in
            let f = try fixture(root, count: 5)
            let historyURL = root.appendingPathComponent(JobHistoryStore.fileName)
            let catalogURL = root.appendingPathComponent("catalog.sqlite")
            defer {
                CatalogDatabase.checkpointAndClose(url: historyURL)
                CatalogDatabase.checkpointAndClose(url: catalogURL)
            }
            let store = try JobHistoryStore(url: historyURL)
            let syncStore = try NASSyncStore(catalogURL: catalogURL)
            _ = try NASSyncService(store: syncStore).sync(f.plan, nasRoot: f.nas)
            let recorder = JobHistoryRecorder(store: store, kind: "syncBuffer", title: "Resume")
            let again = try NASSyncService(store: syncStore, recorder: recorder).sync(f.plan, nasRoot: f.nas)
            XCTAssertEqual(again.alreadyVerified.count, 5)
            recorder.finish(outcome: .succeeded, note: nil)
            recorder.flush()
            let items = try store.items(jobID: recorder.jobID)
            XCTAssertEqual(items.map(\.outcome), Array(repeating: .alreadyVerified, count: 5))
            XCTAssertTrue(items.allSatisfy { $0.start == nil && $0.slot == nil })
            XCTAssertEqual(try store.job(id: recorder.jobID)?.alreadyVerified, 5)
        }
    }

    // MARK: Analysis

    func testDownsamplingKeepsEachColumnsExtremesAndStaysSmall() {
        // 10 hours at 1 Hz: a steady 100 MB/s with one spike and one stall.
        var points = (0..<36_000).map { JobHistoryAnalysis.Point(t: Double($0), value: 100 + Double($0 % 7)) }
        points[12_345].value = 900
        points[30_001].value = 0
        let drawn = JobHistoryAnalysis.downsample(points, in: 0...35_999, buckets: 400)
        XCTAssertLessThanOrEqual(drawn.count, 804)
        XCTAssertTrue(drawn.contains(points[12_345]), "the spike survives")
        XCTAssertTrue(drawn.contains(points[30_001]), "the stall survives")
        XCTAssertEqual(drawn.map(\.t), drawn.map(\.t).sorted(), "still in time order")
        XCTAssertEqual(drawn.first?.t, 0)
        XCTAssertEqual(drawn.last?.t, 35_999)
    }

    func testDownsamplingAZoomedRangeKeepsItsNeighboursAndSmallRangesUntouched() {
        let points = (0..<1_000).map { JobHistoryAnalysis.Point(t: Double($0), value: Double($0)) }
        let zoomed = JobHistoryAnalysis.downsample(points, in: 100.5...110.5, buckets: 400)
        XCTAssertEqual(zoomed.map(\.t), Array(100...111).map(Double.init), "every point in range plus one beyond each edge")
        let wide = JobHistoryAnalysis.downsample(points, in: 200.5...899.5, buckets: 50)
        XCTAssertEqual(wide.first?.t, 200, "the neighbour before the range")
        XCTAssertEqual(wide.last?.t, 900, "the neighbour after it")
        XCTAssertLessThanOrEqual(wide.count, 104)
        XCTAssertTrue(JobHistoryAnalysis.downsample([], in: 0...1, buckets: 10).isEmpty)
    }

    func testTheFlightIndexAnswersWhichFilesWereInFlight() {
        let items = [
            JobHistoryItem(relativePath: "a", byteCount: 1, start: 0, end: 10, outcome: .copied),
            JobHistoryItem(relativePath: "b", byteCount: 1, start: 2, end: 3, outcome: .copied),
            JobHistoryItem(relativePath: "c", byteCount: 1, start: nil, end: 5, outcome: .alreadyVerified),
            JobHistoryItem(relativePath: "d", byteCount: 1, start: 9, end: 12, outcome: .failed),
            JobHistoryItem(relativePath: "e", byteCount: 1, start: 20, end: 21, outcome: .copied),
        ]
        let index = JobHistoryFlightIndex(items)
        XCTAssertEqual(index.inFlight(at: 2.5), [0, 1])
        XCTAssertEqual(index.inFlight(at: 5), [0], "a file without a transfer never flies")
        XCTAssertEqual(index.inFlight(at: 9.5), [0, 3])
        XCTAssertEqual(index.inFlight(at: 15), [])
        XCTAssertEqual(index.inFlight(during: 11...20), [3, 4])
        XCTAssertEqual(JobHistoryAnalysis.nearestSample([JobHistorySample(t: 1), JobHistorySample(t: 2), JobHistorySample(t: 4)], to: 3.2)?.t, 4)
    }
}
