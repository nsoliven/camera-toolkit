import Foundation
import XCTest
@testable import CameraToolkitApp
@testable import CameraToolkitCore

/// The pure pieces of the Jobs window's History — zoom math, series,
/// the whole-job live chart, the file list — and the model recording a
/// job from start to end into a temporary store.
@MainActor
final class JobHistoryViewTests: XCTestCase {
    // MARK: Zoom

    func testZoomKeepsTheAnchorInPlaceAndStaysInsideTheJob() {
        var zoom = JobHistoryZoom(full: 0...1_000)
        XCTAssertTrue(zoom.isFit)
        zoom.zoom(by: 4, around: 250)
        XCTAssertEqual(zoom.span, 250, accuracy: 1e-9)
        // 250 sat a quarter of the way across; it still does.
        XCTAssertEqual((250 - zoom.visible.lowerBound) / zoom.span, 0.25, accuracy: 1e-9)
        XCTAssertFalse(zoom.isFit)

        zoom.pan(by: -10_000)
        XCTAssertEqual(zoom.visible, 0...250, "panning stops at the start")
        zoom.pan(by: 10_000)
        XCTAssertEqual(zoom.visible, 750...1_000, "and at the end")

        zoom.zoom(by: 1_000_000, around: 900)
        XCTAssertEqual(zoom.span, JobHistoryZoom.minimumSpan, accuracy: 1e-9, "never narrower than a few samples")
        zoom.zoom(by: 0.000_001, around: 900)
        XCTAssertEqual(zoom.visible, 0...1_000, "never wider than the job")
        zoom.zoom(by: .nan, around: 1)
        XCTAssertEqual(zoom.visible, 0...1_000)
    }

    func testZoomToARangeAFileAndFit() {
        var zoom = JobHistoryZoom(full: 0...600)
        zoom.show(100...200, padding: 0.5)
        XCTAssertEqual(zoom.visible, 50...250)
        zoom.show(599...599.5)
        XCTAssertEqual(zoom.visible, 595...600, "a tiny span widens to the minimum, inside the job")
        zoom.center(on: 300)
        XCTAssertEqual(zoom.visible, 297.5...302.5)
        zoom.fit()
        XCTAssertTrue(zoom.isFit)

        // A running job grows: a fitted view follows it, a zoomed one stays.
        zoom.setFull(0...700)
        XCTAssertEqual(zoom.visible, 0...700)
        zoom.show(10...20)
        zoom.setFull(0...800)
        XCTAssertEqual(zoom.visible, 10...20)

        let short = JobHistoryZoom(full: 0...2)
        XCTAssertEqual(JobHistoryZoom.clamp(0, 1, in: short.full), 0...2, "a job shorter than the minimum shows whole")
    }

    func testTimeStrideGivesAboutSixRoundTicks() {
        XCTAssertEqual(JobHistoryChartMath.timeStride(30), 5)
        XCTAssertEqual(JobHistoryChartMath.timeStride(180), 30)
        XCTAssertEqual(JobHistoryChartMath.timeStride(3_600), 600)
        XCTAssertEqual(JobHistoryChartMath.timeStride(10 * 3_600), 7_200)
    }

    // MARK: Files and text

    func testTheFileListFiltersAndSorts() {
        let items = [
            JobHistoryItem(relativePath: "a/B.ARW", byteCount: 300, start: 5, end: 9, outcome: .copied),
            JobHistoryItem(relativePath: "a/A.ARW", byteCount: 100, start: 1, end: 2, outcome: .failed, error: "Input/output error"),
            JobHistoryItem(relativePath: "a/C.ARW", byteCount: 200, start: nil, end: 0.5, outcome: .alreadyVerified),
            JobHistoryItem(relativePath: "a/D.ARW", byteCount: 50, start: 2, end: 8, outcome: .conflict),
        ]
        let byStart = JobHistoryFileFilter.rows(items, filter: .all, sortedBy: [KeyPathComparator(\JobHistoryFileRow.start)])
        XCTAssertEqual(byStart.map(\.name), ["C.ARW", "A.ARW", "D.ARW", "B.ARW"])
        XCTAssertEqual(byStart.map(\.id), [2, 1, 3, 0], "rows keep their item index")
        let bySize = JobHistoryFileFilter.rows(items, filter: .all, sortedBy: [KeyPathComparator(\JobHistoryFileRow.size, order: .reverse)])
        XCTAssertEqual(bySize.map(\.size), [300, 200, 100, 50])
        XCTAssertEqual(JobHistoryFileFilter.rows(items, filter: .issues, sortedBy: [KeyPathComparator(\JobHistoryFileRow.name)]).map(\.name), ["A.ARW", "D.ARW"])
        XCTAssertEqual(JobHistoryFileFilter.rows(items, filter: .transferred, sortedBy: []).map(\.name), ["B.ARW"])
        XCTAssertEqual(JobHistoryFileFilter.rows(items, filter: .skipped, sortedBy: []).map(\.name), ["C.ARW"])

        let tooltip = JobHistoryText.item(items[1])
        XCTAssertTrue(tooltip.contains("Input/output error"))
        XCTAssertTrue(tooltip.contains("0:01 → 0:02"))
        XCTAssertTrue(JobHistoryText.item(items[2]).contains("without a transfer"))
    }

    func testListTextSaysWhatAJobMovedAndHowItsFilesEnded() {
        var job = JobHistoryJob(kind: JobAction.syncBuffer.rawValue, title: "Synced", startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 100), outcome: .succeeded)
        job.bytesDone = 5_000_000_000
        job.transferBytes = 10_000_000_000
        job.copied = 120
        job.matchedExisting = 3_000
        job.alreadyVerified = 1_000
        job.failed = 2
        XCTAssertEqual(JobHistoryText.counts(job), "120 copied · 4,000 already on NAS · 2 failed")
        XCTAssertTrue(JobHistoryText.movedAndSpeed(job).hasSuffix("100 MB/s average"), JobHistoryText.movedAndSpeed(job))
        XCTAssertNil(JobHistoryText.counts(JobHistoryJob(kind: "faceScan", title: "", startedAt: Date())))
        XCTAssertEqual(JobHistoryText.seconds(0.25), "0.25 s")
        XCTAssertEqual(JobHistoryText.seconds(4.12), "4.1 s")
    }

    // MARK: Recording through the model

    func testTheModelRecordsOnlyWhenHistoryIsOn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraToolkitAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DashboardModel(
            jobs: [],
            configuration: AppConfiguration.defaults(applicationSupport: root),
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
        )
        XCTAssertNil(model.jobHistoryURL, "tests and previews never record")
        XCTAssertNil(model.makeHistoryRecorder(action: .organize, title: "Off"))

        model.jobHistoryEnabled = true
        let url = try XCTUnwrap(model.jobHistoryURL)
        defer { CatalogDatabase.checkpointAndClose(url: url) }
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, URL(fileURLWithPath: model.configuration.catalogDatabasePath).deletingLastPathComponent().standardizedFileURL, "beside the catalog")
        XCTAssertEqual(url.lastPathComponent, "job-history.sqlite")

        let jobID = try XCTUnwrap(model.runBackgroundJob(
            action: .ingestCard,
            runningNote: "Copying",
            logTitle: "Copied a card",
            logDetail: "",
            operation: { progress in
                for step in 1...3 {
                    progress(BackgroundJobUpdate(progress: Double(step) / 3, note: "Copying", processedFiles: step, totalFiles: 3, processedBytes: Int64(step) * 1_000, totalBytes: 3_000))
                }
                return 3
            },
            completion: { _ in "Copied 3 files." }
        ))
        let deadline = Date().addingTimeInterval(5)
        while model.isBusy, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.jobHistoryRevision, 1)
        XCTAssertNotNil(model.historySamples(for: jobID), "the finished job's samples stay for its chart")
        model.flushJobHistory()

        let store = try XCTUnwrap(JobHistoryStore.shared(at: url))
        let job = try XCTUnwrap(store.job(id: jobID), "the history row has the Jobs list's id")
        XCTAssertEqual(job.outcome, .succeeded)
        XCTAssertEqual(job.kind, "ingestCard")
        XCTAssertEqual(job.title, "Copied a card")
        XCTAssertEqual(job.totalFiles, 3)
        XCTAssertEqual(job.totalBytes, 3_000)
        XCTAssertEqual(job.bytesDone, 3_000)
        XCTAssertEqual(job.summary?.note, "Copied 3 files.")
        XCTAssertNotNil(job.endedAt)
    }
}
