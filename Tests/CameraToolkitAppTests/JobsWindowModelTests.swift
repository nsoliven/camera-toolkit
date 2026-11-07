import Foundation
import XCTest
@testable import CameraToolkitApp
@testable import CameraToolkitCore

/// The Jobs window's list and the words and numbers its pane shows.
@MainActor
final class JobsWindowModelTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: List

    func testRunningJobsArePinnedAboveHistoryGroupedByDay() {
        let running = JobSnapshot(action: .syncBuffer, state: .running, progress: 0.4, createdAt: now.addingTimeInterval(-60))
        let recordedRunning = JobHistoryJob(id: running.id, kind: "syncBuffer", title: "Synced Trip 2026 to the NAS", startedAt: running.createdAt, bytesDone: 2_000_000_000, transferBytes: 4_000_000_000)
        let earlierToday = JobHistoryJob(kind: "ingestCard", title: "Copied the card", startedAt: now.addingTimeInterval(-3_600), endedAt: now.addingTimeInterval(-3_500), outcome: .succeeded, bytesDone: 5_000_000_000)
        let yesterday = JobHistoryJob(kind: "faceScan", title: "Scanned faces", startedAt: now.addingTimeInterval(-86_400), endedAt: now.addingTimeInterval(-86_000), outcome: .failed)
        let leftRunning = JobHistoryJob(kind: "syncBuffer", title: "Synced Beach Day", startedAt: now.addingTimeInterval(-90_000), outcome: .running)

        let sections = JobsList.sections(session: [running], history: [recordedRunning, earlierToday, yesterday, leftRunning], now: now, calendar: calendar)

        XCTAssertEqual(sections.active.map(\.id), [running.id])
        XCTAssertEqual(sections.active.first?.title, "Synced Trip 2026 to the NAS", "the recorder's title wins over the action name")
        XCTAssertEqual(sections.active.first?.status, .running(progress: 0.4))
        XCTAssertEqual(sections.days.map(\.title), ["Today", "Yesterday"])
        XCTAssertEqual(sections.days[0].entries.map(\.id), [earlierToday.id])
        XCTAssertEqual(sections.days[1].entries.map(\.id), [yesterday.id, leftRunning.id])
        XCTAssertEqual(sections.days[1].entries[1].status, .ended(.interrupted), "a row a quit left running is not running")
        XCTAssertEqual(sections.all.count, 4, "the session job and its recorded row are one entry")
    }

    func testASessionJobWithoutARecordIsListed() {
        let done = JobSnapshot(action: .organize, state: .done, processedBytes: 1_000, createdAt: now.addingTimeInterval(-30), finishedAt: now.addingTimeInterval(-29))
        let sections = JobsList.sections(session: [done], history: [], now: now, calendar: calendar)
        XCTAssertTrue(sections.active.isEmpty)
        XCTAssertEqual(sections.days.first?.entries.first?.title, JobAction.organize.displayName)
        XCTAssertEqual(sections.days.first?.entries.first?.status, .ended(.succeeded))
    }

    func testRowDetailSaysWhatMovedOrWhatWasChecked() {
        let copied = JobHistoryJob(kind: "syncBuffer", title: "", startedAt: now.addingTimeInterval(-100), endedAt: now, outcome: .succeeded, bytesDone: 2_000_000_000, transferBytes: 4_000_000_000)
        XCTAssertEqual(JobsList.rowDetail(copied, now: now), "\(Int64(2_000_000_000).formattedBytes) · 40.0 MB/s")
        let checked = JobHistoryJob(kind: "syncBuffer", title: "", startedAt: now.addingTimeInterval(-10), endedAt: now, outcome: .succeeded, alreadyVerified: 16_009)
        XCTAssertEqual(JobsList.rowDetail(checked, now: now), "16,009 checked")
        XCTAssertNil(JobsList.rowDetail(JobHistoryJob(kind: "nasRename", title: "", startedAt: now), now: now))
    }

    func testDayTitlesNameOlderDaysByDate() {
        let older = calendar.startOfDay(for: now.addingTimeInterval(-5 * 86_400))
        let title = JobsList.dayTitle(older, now: now, calendar: calendar)
        XCTAssertNotEqual(title, "Today")
        XCTAssertNotEqual(title, "Yesterday")
        XCTAssertFalse(title.isEmpty)
    }

    func testACardTransferBelongsToTheCardCopyThatStartedWithIt() {
        let queue = TransferQueueSnapshot(sourcePath: "/Volumes/Card", destinationPath: "/Volumes/Buffer", items: [], totalBytes: 0, createdAt: now)
        let copy = JobListEntry(id: UUID(), kind: "ingestCard", title: "", startedAt: now.addingTimeInterval(1), status: .running(progress: 0))
        let olderCopy = JobListEntry(id: UUID(), kind: "ingestCard", title: "", startedAt: now.addingTimeInterval(-3_600), status: .ended(.succeeded))
        let sync = JobListEntry(id: UUID(), kind: "syncBuffer", title: "", startedAt: now, status: .running(progress: 0))
        XCTAssertEqual(JobsList.transferJobID(for: queue, in: [sync, olderCopy, copy]), copy.id)
        XCTAssertNil(JobsList.transferJobID(for: queue, in: [sync, olderCopy]))
    }

    // MARK: Readouts and tally

    func testAFinishedSyncReadsAverageAndPeakFromItsRecording() {
        let job = JobHistoryJob(kind: "syncBuffer", title: "", startedAt: now.addingTimeInterval(-20), endedAt: now, outcome: .succeeded, bytesDone: 1_000_000_000, transferBytes: 2_000_000_000, copied: 20)
        var samples = (1...20).map { JobHistorySample(t: Double($0), combined: 100, filesPerSecond: 1, transferBytes: Int64($0) * 100_000_000, doneBytes: Int64($0) * 50_000_000, doneFiles: $0) }
        samples[9].combined = 180
        let detail = JobHistoryDetail(job: job, samples: samples, items: [], now: now)
        let readouts = JobDetailFacts.finishedReadouts(job: job, graph: detail.graph)
        XCTAssertEqual(readouts.map(\.caption), ["average · combined", "peak", "files"])
        XCTAssertEqual(readouts[0].value, "100", "2 GB over 20 s")
        XCTAssertEqual(readouts[1].value, "180")
        XCTAssertEqual(readouts[2].value, "1.0")
        XCTAssertEqual(detail.graph.average ?? 0, 100, accuracy: 0.001, "the dashed average is the readout's number")
    }

    func testAFaceScanLeadsWithPhotosPerSecond() {
        let job = JobHistoryJob(kind: "faceScan", title: "", startedAt: now.addingTimeInterval(-30), endedAt: now, outcome: .succeeded)
        let samples = (1...30).map { JobHistorySample(t: Double($0), combined: 0, filesPerSecond: 12, doneFiles: $0 * 12) }
        let detail = JobHistoryDetail(job: job, samples: samples, items: [], now: now)
        let readouts = JobDetailFacts.finishedReadouts(job: job, graph: detail.graph)
        XCTAssertEqual(readouts.first?.unit, "photos/s")
        XCTAssertEqual(readouts.first?.value, "12.0")
        XCTAssertFalse(readouts.contains { $0.caption == "files" }, "the files rate already leads")
    }

    func testATallySaysCopiedAgainstAlreadyThereAndIssues() {
        var timings = NASSyncTimings()
        timings.remoteVerifyBytes = 2_000_000_000
        let job = JobHistoryJob(
            kind: "syncBuffer", title: "", startedAt: now, endedAt: now, outcome: .succeeded,
            bytesDone: 2_000_000_000, copied: 8, alreadyVerified: 16_141, conflicts: 1,
            summary: JobHistorySummary(timings: timings, verifyMethod: "ssh")
        )
        let tally = JobDetailFacts.tally(job: job, live: nil)
        XCTAssertEqual(tally.map(\.label), ["Copied", "Verified", "Already there", "Issues"])
        XCTAssertEqual(tally[0].value, "\(Int64(2_000_000_000).formattedBytes) · 8 files")
        XCTAssertEqual(tally[1].value, "\(Int64(2_000_000_000).formattedBytes) on the NAS")
        XCTAssertEqual(tally[2].value, "16,141 files")
        XCTAssertEqual(tally[3].value, "1 conflict")
        XCTAssertEqual(tally[3].tone, .warning)
    }

    // MARK: Graph words

    func testACheckOnlySyncSaysNothingNeededCopying() {
        let job = JobHistoryJob(kind: "syncBuffer", title: "", startedAt: now.addingTimeInterval(-16), endedAt: now, outcome: .succeeded, alreadyVerified: 16_009)
        let samples = [
            JobHistorySample(t: 6, combined: 0, filesPerSecond: 1_700, doneFiles: 2_000),
            JobHistorySample(t: 15, combined: 0, filesPerSecond: 1_100, doneFiles: 16_000),
        ]
        let graph = JobHistoryDetail(job: job, samples: samples, items: [], now: now).graph
        let text = JobDetailFacts.graphSummary(graph, kind: "syncBuffer", isLive: false)
        XCTAssertEqual(text, "Nothing to copy — every file was already on the NAS. Checked 16,000 files in 0:16 at 1,000 files/s.")
        XCTAssertEqual(JobDetailFacts.graphSummary(graph, kind: "syncBuffer", isLive: true), "Checking — 16,000 files so far at 1,000 files/s, nothing copied yet.")
        XCTAssertTrue(JobDetailFacts.finishedReadouts(job: job, graph: graph).allSatisfy { $0.caption != "peak" }, "no peak without a chart")
    }

    func testAShortJobSaysHowFastItWent() {
        let job = JobHistoryJob(kind: "ingestCard", title: "", startedAt: now.addingTimeInterval(-4), endedAt: now, outcome: .succeeded, bytesDone: 600_000_000)
        let graph = JobHistoryDetail(job: job, samples: [JobHistorySample(t: 2, combined: 150, doneBytes: 300_000_000)], items: [], now: now).graph
        XCTAssertEqual(JobDetailFacts.graphSummary(graph, kind: "ingestCard", isLive: false), "Done in 0:04 — too quick to chart. Averaged 150 MB/s.")
        XCTAssertEqual(JobDetailFacts.graphSummary(graph, kind: "ingestCard", isLive: true), "Measuring speed…")
    }

    func testTheHoverCardShowsTheJobsNumbersAndNoGPUForATransfer() {
        let sample = JobHistorySample(t: 10, combined: 110, copy: 108, remoteVerify: 300, filesPerSecond: 2.5, activeTransfers: 4, gpu: 0.01, doneBytes: 1_000_000_000, doneFiles: 42)
        let samples = (1...20).map { JobHistorySample(t: Double($0), combined: 110, copy: 108, remoteVerify: 300, doneBytes: Int64($0) * 110_000_000) }
        let graph = JobSpeedGraph.build(samples: samples, kind: "syncBuffer", duration: 20)
        let lines = JobDetailFacts.hoverLines(sample: sample, t: 10, graph: graph, kind: "syncBuffer")
        XCTAssertEqual(lines.title, "0:10 · Copy + Verify")
        let labels = lines.rows.map(\.label)
        XCTAssertEqual(labels, ["Speed", "Files", "Done", "Copy", "Verify on NAS", "Transfers"])
        XCTAssertEqual(lines.rows[0].value, "110 MB/s")
        XCTAssertFalse(labels.contains("GPU"))
        XCTAssertEqual(JobDetailFacts.hoverLines(sample: sample, t: 10, graph: graph, kind: "faceScan").rows.last?.label, "GPU")
        XCTAssertEqual(JobDetailFacts.hoverLines(sample: nil, t: 10, graph: graph, kind: "syncBuffer").rows.first?.value, "No samples — nothing reported")
    }

    // MARK: Outcome and issues

    /// The reported case: 12 files copied and verified, one Photomator
    /// sidecar the NAS holds in another version. Sync calls it failed; the
    /// window shows it as done with a conflict.
    func testASyncThatOnlyLeftConflictsReadsAsDoneWithAConflict() {
        var job = JobHistoryJob(
            kind: "syncBuffer", title: "", startedAt: now, endedAt: now, outcome: .failed,
            bytesDone: 2_750_000_000, copied: 12, alreadyVerified: 16_141, conflicts: 1,
            summary: JobHistorySummary(note: "Sync to NAS for all events: 12 copied and verified, 16141 already on the NAS, 1 conflict(s) left untouched.")
        )
        XCTAssertTrue(JobDetailFacts.endedWithOnlyConflicts(job))
        let display = JobDetailFacts.outcomeDisplay(.failed, job: job)
        XCTAssertEqual(display.label, "Done · 1 conflict")
        XCTAssertEqual(display.tone, .warning)
        XCTAssertEqual(JobsList.entry(job, now: now).display?.tone, .warning)

        job.failed = 1
        XCTAssertFalse(JobDetailFacts.endedWithOnlyConflicts(job), "a failed file is a failure")
        XCTAssertEqual(JobDetailFacts.outcomeDisplay(.failed, job: job).tone, .failure)
        job.failed = 0
        job.summary?.stoppedReason = "The NAS disconnected."
        XCTAssertFalse(JobDetailFacts.endedWithOnlyConflicts(job), "a stop is a failure")
    }

    func testTheClosingNoteSplitsIntoClausesAndARevealablePath() {
        let note = "Sync to NAS for all events: 12 copied and verified, 16141 already on the NAS, 1 conflict(s) left untouched, 1 folder(s) outside Originals/Edited not synced, 3 already on the NAS in the old archive layout, not copied again (run the NAS layout migration for this event, then sync). Details: /Volumes/Buffer/reports/sync-1.json"
        let parts = JobDetailFacts.noteParts(note)
        XCTAssertEqual(parts.reportPath, "/Volumes/Buffer/reports/sync-1.json")
        XCTAssertEqual(parts.clauses, [
            "12 copied and verified",
            "16141 already on the NAS",
            "1 conflict left untouched",
            "1 folder outside Originals/Edited not synced",
            "3 already on the NAS in the old archive layout",
            "Not copied again (run the NAS layout migration for this event, then sync)",
        ])
        XCTAssertEqual(JobDetailFacts.plural("2 conflict(s) and 1 folder(s)"), "2 conflicts and 1 folder")
        XCTAssertNil(JobDetailFacts.noteParts("Copied 3 files.").reportPath)
        XCTAssertEqual(JobDetailFacts.noteParts("Copied 3 files.").clauses, ["Copied 3 files"])
    }

    func testIssueHeadlinesSayWhy() {
        let conflicted = JobHistoryJob(kind: "syncBuffer", title: "", startedAt: now, outcome: .failed, conflicts: 1)
        XCTAssertTrue(JobDetailFacts.issueHeadline(conflicted).hasPrefix("Finished — 1 file left untouched"))
        let failed = JobHistoryJob(kind: "syncBuffer", title: "", startedAt: now, outcome: .failed, failed: 8)
        XCTAssertEqual(JobDetailFacts.issueHeadline(failed), "Finished with 8 files failed")
        let conflict = JobHistoryItem(relativePath: "a/B1152_DSC00177.photo-edit", byteCount: 231_244, start: nil, end: 1, outcome: .conflict)
        XCTAssertTrue(JobDetailFacts.advice(for: conflict).contains("Neither copy was changed"))
    }

    func testQueuedJobsFollowRunningOnesInTheOrderTheyStart() {
        let running = JobSnapshot(action: .syncBuffer, state: .running, createdAt: now.addingTimeInterval(-60))
        let second = JobSnapshot(action: .freeUp, state: .queued, createdAt: now.addingTimeInterval(-10))
        let first = JobSnapshot(action: .ingestCard, state: .queued, createdAt: now.addingTimeInterval(-30))
        let sections = JobsList.sections(session: [second, running, first], history: [], now: now, calendar: calendar)
        XCTAssertEqual(sections.running.map(\.id), [running.id])
        XCTAssertEqual(sections.queued.map(\.id), [first.id, second.id])
        XCTAssertEqual(sections.active.map(\.id), [running.id, first.id, second.id])
    }

    // MARK: Removing jobs and the file-job queue

    /// Clear from Card records removed files as `matched` and skipped ones
    /// as `failed` (the table's CHECK only knows sync outcomes); the window
    /// reads them as Removed and Skipped.
    func testAClearFromCardJobReadsRemovedAndSkipped() {
        let items = [
            JobHistoryItem(relativePath: "DCIM/100MSDCF/DSC00001.ARW", byteCount: 40_000_000, start: nil, end: 3, outcome: .matched, verifyMethod: "NAS re-read"),
            JobHistoryItem(relativePath: "DCIM/100MSDCF/DSC00001.JPG", byteCount: 10_000_000, start: nil, end: 3, outcome: .matched, verifyMethod: "NAS re-read"),
            JobHistoryItem(relativePath: "DCIM/100MSDCF/DSC00002.ARW", byteCount: 40_000_000, start: nil, end: 4, outcome: .failed, verifyMethod: "NAS re-read", error: "Skipped in Verify: the drive copy changed. The card file stays."),
        ]
        let job = JobHistoryJob(kind: "freeUp", title: "Cleared files from CARD", startedAt: now.addingTimeInterval(-20), endedAt: now, outcome: .succeeded, matchedExisting: 2, failed: 1)
        XCTAssertEqual(items.map { $0.outcome.label(kind: job.kind) }, ["Removed", "Removed", "Skipped"])
        XCTAssertEqual(JobHistoryFileFilter.available(kind: job.kind).map { $0.title(kind: job.kind) }, ["All", "Removed", "Skipped"])
        XCTAssertEqual(JobHistoryFileFilter.rows(items, filter: .issues, kind: job.kind, sortedBy: []).map(\.name), ["DSC00002.ARW"])
        XCTAssertEqual(JobHistoryFileFilter.rows(items, filter: .transferred, kind: job.kind, sortedBy: []).count, 2)
        XCTAssertEqual(JobDetailFacts.tally(job: job, live: nil, items: items).map(\.label), ["Removed", "Skipped"])
        XCTAssertEqual(JobDetailFacts.tally(job: job, live: nil, items: items).first?.value, "2 files · \(Int64(50_000_000).formattedBytes)")
        XCTAssertEqual(JobsList.rowDetail(job, now: now), "2 removed · 1 skipped")
        XCTAssertEqual(JobDetailFacts.outcomeDisplay(.succeeded, job: job), JobOutcomeDisplay(label: "Done · 1 skipped", symbol: "exclamationmark.triangle.fill", tone: .warning))
        XCTAssertEqual(
            JobDetailFacts.noteParts("Cleared 2 file(s) from CARD (50 MB). 1 file(s) stayed: its drive copy changed.").clauses,
            ["Cleared 2 files from CARD (50 MB)", "1 file stayed: its drive copy changed"]
        )
        XCTAssertTrue(JobDetailFacts.issueHeadline(job).hasPrefix("1 file skipped and kept"))
        XCTAssertTrue(JobHistoryText.item(items[2], kind: job.kind).contains("Skipped in Verify"))
        XCTAssertTrue(JobHistoryText.item(items[0], kind: job.kind).contains("Checked against the NAS re-read"))
        // A sync keeps its own words.
        XCTAssertEqual(JobHistoryItemOutcome.matched.label(kind: "syncBuffer"), "Already on NAS")
    }

    func testQueuedJobsFollowTheQueuesOwnOrder() {
        let a = JobSnapshot(action: .freeUp, state: .queued, createdAt: now.addingTimeInterval(-30))
        let b = JobSnapshot(action: .freeUp, state: .queued, createdAt: now.addingTimeInterval(-20))
        let sections = JobsList.sections(session: [a, b], history: [], queueOrder: [b.id, a.id], now: now, calendar: calendar)
        XCTAssertEqual(sections.queued.map(\.id), [b.id, a.id])
    }
}
