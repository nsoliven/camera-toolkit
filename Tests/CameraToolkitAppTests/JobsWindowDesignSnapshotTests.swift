import AppKit
import CameraToolkitCore
import SwiftUI
@testable import CameraToolkitApp
import XCTest

/// Renders the whole Jobs window off-screen from a synthetic store in the
/// four states its design is judged on — a running sync, a finished job, a
/// job that ended with warnings, and a two-pass face and dog scan — in
/// light and dark. Everything lives in a temporary folder and no window is
/// ever put on screen. Runs only when `CT_SNAPSHOT_OUT` names a folder.
@MainActor
final class JobsWindowDesignSnapshotTests: XCTestCase {
    func testRenderJobsWindowStates() async throws {
        guard let out = ProcessInfo.processInfo.environment["CT_SNAPSHOT_OUT"] else {
            throw XCTSkip("Snapshot harness runs only with CT_SNAPSHOT_OUT set.")
        }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitJobsDesign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let scan = TwoPassFixture.make(now: now)
        let sync = Self.runningSync(now: now)

        let scanModel = try await makeModel(root: root.appendingPathComponent("scan", isDirectory: true), live: [scan.job], extra: scan.record, now: now)
        let syncRow = JobHistoryJob(
            id: sync.job.id, kind: JobAction.syncBuffer.rawValue, title: "Sync to NAS: Family Party", startedAt: sync.job.createdAt, outcome: .running,
            totalFiles: sync.job.totalFiles, totalBytes: sync.job.totalBytes / 2, bytesDone: sync.job.processedBytes / 2,
            transferBytes: sync.job.processedBytes, copied: sync.job.processedFiles, configuration: "4 transfers in parallel · SSH verify"
        )
        let syncRecord = JobHistoryRecord(job: syncRow, samples: Self.syncSamples(seconds: 620))
        let syncModel = try await makeModel(root: root.appendingPathComponent("sync", isDirectory: true), live: [sync.job], extra: syncRecord, now: now)
        let pastModel = try await makeModel(root: root.appendingPathComponent("past", isDirectory: true), live: [], extra: nil, now: now)

        let cases: [(String, DashboardModel, UUID, JobActivityMonitor)] = [
            ("two-pass", scanModel.model, scan.job.id, scan.monitor),
            ("running", syncModel.model, sync.job.id, sync.monitor),
            ("finished", pastModel.model, pastModel.finishedID, JobActivityMonitor(ceilingResolver: nil)),
            ("warning", pastModel.model, pastModel.warningID, JobActivityMonitor(ceilingResolver: nil)),
        ]
        for (name, model, selection, monitor) in cases {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                let browser = JobHistoryBrowser(model: model)
                await browser.reload()
                await browser.open(selection)
                let view = TransferQueueView(model: model, selection: selection, history: browser, monitor: monitor)
                    .background(.background)
                try render(AnyView(view), size: NSSize(width: 1_280, height: 860), appearance: appearance,
                           to: folder.appendingPathComponent("jobs-\(name)-\(suffix).png"))
            }
        }
        for checked in [scanModel, syncModel, pastModel] {
            if let url = checked.model.jobHistoryURL { CatalogDatabase.checkpointAndClose(url: url) }
        }
    }

    private struct Built {
        var model: DashboardModel
        var finishedID: UUID
        var warningID: UUID
    }

    /// A model whose history holds the same past jobs every state shares:
    /// a run of card copies, a clean sync, a sync with conflicts, and a
    /// failed one.
    private func makeModel(root: URL, live: [JobSnapshot], extra: JobHistoryRecord?, now: Date) async throws -> Built {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = DashboardModel(
            jobs: live,
            configuration: AppConfiguration.defaults(applicationSupport: root),
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
        )
        model.jobHistoryEnabled = true
        let url = try XCTUnwrap(model.jobHistoryURL)
        let store = try XCTUnwrap(JobHistoryStore.shared(at: url))
        if let extra {
            try store.write(job: extra.job, samples: extra.samples, items: [], jobID: extra.job.id)
        }

        for index in 0..<7 {
            let started = now.addingTimeInterval(-3_600 - Double(index) * 420)
            let card = JobHistoryJob(
                kind: JobAction.ingestCard.rawValue, title: "Copied queue to buffer",
                startedAt: started, endedAt: started.addingTimeInterval(95), outcome: .succeeded,
                totalFiles: 40, totalBytes: 1_900_000_000, bytesDone: 1_900_000_000
            )
            try store.write(job: card, samples: [], items: [], jobID: card.id)
        }

        let finishedStart = now.addingTimeInterval(-9_000)
        let finished = JobHistoryJob(
            kind: JobAction.syncBuffer.rawValue, title: "Sync to NAS: Trip 2026",
            startedAt: finishedStart, endedAt: finishedStart.addingTimeInterval(2_400), outcome: .succeeded,
            totalFiles: 1_880, totalBytes: 90_000_000_000, bytesDone: 90_000_000_000, transferBytes: 180_000_000_000,
            copied: 1_880, configuration: "4 transfers in parallel · SSH verify",
            summary: JobHistorySummary(
                phases: [
                    JobPhaseTotal(label: "Check", seconds: 12, activeSeconds: 12),
                    JobPhaseTotal(label: "Copy", seconds: 5_400, bytes: 90_000_000_000, activeSeconds: 1_300),
                    JobPhaseTotal(label: "Verify", seconds: 3_900, bytes: 90_000_000_000, activeSeconds: 1_050),
                ],
                verifyMethod: "ssh",
                note: "Sync to NAS for Trip 2026: 1,880 copied."
            )
        )
        try store.write(job: finished, samples: Self.syncSamples(seconds: 2_400), items: (0..<60).map { index in
            JobHistoryItem(
                relativePath: String(format: "2026/Trip 2026/DSC%05d.ARW", index), byteCount: 48_000_000,
                start: Double(index) * 40, end: Double(index) * 40 + 30, slot: index % 4, outcome: .copied, verifyMethod: "ssh"
            )
        }, jobID: finished.id)

        let warningStart = now.addingTimeInterval(-14_000)
        let warning = JobHistoryJob(
            kind: JobAction.syncBuffer.rawValue, title: "Sync to NAS: Beach Day",
            startedAt: warningStart, endedAt: warningStart.addingTimeInterval(900), outcome: .failed,
            totalFiles: 412, totalBytes: 20_000_000_000, bytesDone: 19_200_000_000, transferBytes: 38_400_000_000,
            copied: 400, alreadyVerified: 9, conflicts: 3, configuration: "4 transfers in parallel · SSH verify",
            summary: JobHistorySummary(
                phases: [
                    JobPhaseTotal(label: "Copy", seconds: 1_900, bytes: 19_200_000_000, activeSeconds: 520),
                    JobPhaseTotal(label: "Verify", seconds: 1_300, bytes: 19_200_000_000, activeSeconds: 360),
                ],
                verifyMethod: "ssh", notAttempted: 0, hashMismatches: 0,
                note: "Sync to NAS for Beach Day: 400 copied, 9 already verified, 3 conflict(s)."
            )
        )
        try store.write(job: warning, samples: Self.syncSamples(seconds: 900), items: (0..<3).map { index in
            JobHistoryItem(
                relativePath: String(format: "2026/Beach Day/DSC%05d.ARW", index + 40), byteCount: 48_000_000,
                start: 12, end: 18, slot: 0, outcome: .conflict, verifyMethod: "ssh",
                error: "The NAS holds a different file at this path."
            )
        }, jobID: warning.id)

        let failedStart = now.addingTimeInterval(-18_000)
        let failed = JobHistoryJob(
            kind: JobAction.syncBuffer.rawValue, title: "Sync to NAS: Family Party",
            startedAt: failedStart, endedAt: failedStart.addingTimeInterval(62), outcome: .failed,
            totalFiles: 900, totalBytes: 41_000_000_000, bytesDone: 2_100_000_000, copied: 44, failed: 1,
            summary: JobHistorySummary(stoppedReason: "The NAS disconnected.", note: "The NAS disconnected.")
        )
        try store.write(job: failed, samples: [], items: [], jobID: failed.id)

        CatalogDatabase.checkpointAndClose(url: url)
        return Built(model: model, finishedID: finished.id, warningID: warning.id)
    }

    private static func syncSamples(seconds: Int) -> [JobHistorySample] {
        stride(from: 0, to: seconds, by: 2).map { second in
            let t = Double(second)
            let wobble = sin(t / 37) * 7
            let rate = 104 + wobble
            return JobHistorySample(
                t: t, combined: second < 4 ? nil : rate, copy: 56 + wobble / 2, verify: 50 - wobble / 3,
                activeTransfers: 4, transferBytes: Int64(t * 104_000_000),
                doneBytes: Int64(t * 52_000_000), doneFiles: second / 2
            )
        }
    }

    /// A Sync to NAS ten minutes in, four transfers busy.
    private static func runningSync(now: Date) -> (job: JobSnapshot, monitor: JobActivityMonitor) {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        let elapsed: TimeInterval = 620
        let created = now.addingTimeInterval(-elapsed)
        var job = JobSnapshot(
            action: .syncBuffer, state: .running, progress: 0, note: "Sync to NAS: Copying to NAS",
            destinationPath: "/Volumes/nas_share", totalFiles: 1_880, totalBytes: 180_000_000_000, createdAt: created
        )
        for second in 0...Int(elapsed) {
            let transfer = Int64(second) * 104_000_000
            job.processedBytes = transfer
            job.processedFiles = second * 2
            job.progress = Double(transfer) / Double(job.totalBytes)
            job.telemetry = JobTelemetry(
                step: "Copying to NAS",
                activeItems: (0..<4).map { slot in
                    JobActiveItem(
                        name: String(format: "DSC%05d.ARW", 900 + slot), path: "/Volumes/Buffer/DSC.ARW", step: "Copying", slot: slot,
                        phase: slot == 3 ? "Verifying" : "Copying", bytesDone: 20_000_000, bytesTotal: 48_000_000, bytesPerSecond: 26_000_000
                    )
                },
                models: [],
                work: JobWorkEstimate(unitsDone: Int(transfer), unitsTotal: Int(job.totalBytes), secondsRemaining: 1_110),
                phases: [
                    JobPhaseTotal(label: "Copy", seconds: Double(second) * 2.4, bytes: transfer / 2, activeSeconds: Double(second) * 0.6),
                    JobPhaseTotal(label: "Verify", seconds: Double(second) * 1.6, bytes: transfer / 2, activeSeconds: Double(second) * 0.4),
                ],
                configuration: "4 transfers in parallel · SSH verify",
                transferBytes: transfer
            )
            let uptime = ProcessInfo.processInfo.systemUptime - elapsed + Double(second)
            monitor.tick(job: job, now: uptime, wallNow: created.addingTimeInterval(Double(second)))
        }
        return (job, monitor)
    }

    private func render(_ view: AnyView, size: NSSize, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        host.layoutSubtreeIfNeeded()
        host.display()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.orderOut(nil)
    }
}

/// A recorded job and its samples, as they would be read back.
struct JobHistoryRecord {
    var job: JobHistoryJob
    var samples: [JobHistorySample]
}

/// A face and dog scan replayed the way the old reporting recorded it: a
/// long first pass, a burst of matching where the face count stands in for
/// the file count, the counters back at zero, and the dog pass just begun.
/// All counts are made up; only the shape matches a real run.
@MainActor
enum TwoPassFixture {
    static let totalFiles = 4_800
    static let totalBytes: Int64 = 240_000_000_000

    static func make(now: Date) -> (job: JobSnapshot, monitor: JobActivityMonitor, record: JobHistoryRecord) {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        let elapsed: TimeInterval = 700
        let created = now.addingTimeInterval(-elapsed)
        let samples = samples()
        var job = JobSnapshot(
            action: .faceScan, state: .running, progress: 0.6, note: "Pet scan: Detecting faces",
            totalFiles: totalFiles, totalBytes: totalBytes, createdAt: created
        )
        for sample in samples {
            job.processedFiles = sample.doneFiles
            job.processedBytes = sample.doneBytes
            job.totalBytes = sample.doneBytes == 0 && sample.doneFiles > 0 ? 0 : totalBytes
            // On the clock the view's own ticks will continue.
            let uptime = ProcessInfo.processInfo.systemUptime - elapsed + sample.t
            monitor.tick(job: job, now: uptime, wallNow: created.addingTimeInterval(sample.t))
        }
        let pass = JobScanPass(index: 2, count: 2, subject: .dogs)
        job.processedFiles = samples.last?.doneFiles ?? 0
        job.processedBytes = samples.last?.doneBytes ?? 0
        job.progress = pass.jobFraction(passFraction: Double(job.processedFiles) / Double(totalFiles))
        job.note = "Dog scan: Detecting dogs"
        job.totalFiles = totalFiles
        job.totalBytes = totalBytes
        job.telemetry = ScanPassReporter.relabelled(JobTelemetry(
            step: "Detect",
            activeItems: (0..<10).map { index in
                let name = String(format: "DSC%05d.heic", 3_260 + index)
                return JobActiveItem(name: name, path: "/Volumes/Buffer/\(name)", step: "Detect")
            },
            counters: [JobCounter(label: "Faces", value: 0)],
            models: ["Dog detector 1.0", "Dog embedder 2.1", "onnxruntime 1.30.0 CoreML"],
            facts: ["MED", "FAST · 10 workers", "min face 80 px", "scales 640"],
            work: JobWorkEstimate(unitsDone: job.processedFiles, unitsTotal: nil, totalIsEstimate: true, unitLabel: "photos and frames")
        ), pass: pass)
        let row = JobHistoryJob(
            id: job.id, kind: JobAction.faceScan.rawValue, title: "Face and dog scan: Beach Day", startedAt: created, outcome: .running,
            totalFiles: totalFiles, totalBytes: totalBytes, bytesDone: job.processedBytes
        )
        return (job, monitor, JobHistoryRecord(job: row, samples: samples))
    }

    /// Pass one for 640 s, the matching burst, then the second pass.
    static func samples() -> [JobHistorySample] {
        var result: [JobHistorySample] = []
        let passOne = 640
        let bytesPerFile = totalBytes / Int64(totalFiles)
        for second in stride(from: 2, to: passOne, by: 1) {
            let wobble = sin(Double(second) / 11) * 4
            let files = min(second * totalFiles / passOne, totalFiles - 2)
            result.append(JobHistorySample(
                t: Double(second), combined: 380 + wobble * 40, filesPerSecond: second < 6 ? nil : 7.5 + wobble,
                doneBytes: Int64(files) * bytesPerFile, doneFiles: files, secondsRemaining: second > 60 ? Double(passOne - second) : nil
            ))
        }
        result.append(JobHistorySample(t: 641.0, combined: 0, filesPerSecond: 0, doneBytes: 0, doneFiles: 0))
        result.append(JobHistorySample(t: 642.0, combined: 0, filesPerSecond: 2_900, doneBytes: 0, doneFiles: 21_000))
        result.append(JobHistorySample(t: 643.0, combined: 0, filesPerSecond: 7_200, doneBytes: 0, doneFiles: 42_000))
        result.append(JobHistorySample(t: 644.0, combined: 0, filesPerSecond: 11_900, doneBytes: 0, doneFiles: 64_000))
        result.append(JobHistorySample(t: 658.0, combined: 0, filesPerSecond: 3_400, doneBytes: 0, doneFiles: 43_000))
        result.append(JobHistorySample(t: 661.0, combined: 0, filesPerSecond: 0, doneBytes: 0, doneFiles: 0))
        for second in stride(from: 663, through: 700, by: 1) {
            let done = (second - 662) * 9
            result.append(JobHistorySample(
                t: Double(second), combined: 320, filesPerSecond: second < 668 ? 2 : 8.5,
                doneBytes: Int64(done) * bytesPerFile, doneFiles: done
            ))
        }
        return result
    }
}
