import AppKit
import CameraToolkitCore
import SwiftUI
@testable import CameraToolkitApp
import XCTest

/// Renders the Jobs window off-screen from a synthetic store — a two-hour
/// Sync to NAS with four parallel transfers and a stall, an interrupted
/// sync, a check-only sync that copied nothing, a short card copy — and
/// writes PNGs in light and dark: the whole window, the sync's pane with
/// the pointer on the graph, a zoomed pane with a file row hovered, and the
/// summaries that replace a chart. Everything lives in a temporary folder.
/// Runs only when `CT_SNAPSHOT_OUT` names an output folder.
///
/// With `CT_SNAPSHOT_HISTORY_DB` naming a copy of a real
/// `job-history.sqlite`, it also renders the pane of every recorded copy,
/// sync and scan in it — from a further copy in the temporary folder, so
/// the file named is never opened for writing.
@MainActor
final class JobHistorySnapshotTests: XCTestCase {
    func testRenderJobsWindow() async throws {
        guard let out = ProcessInfo.processInfo.environment["CT_SNAPSHOT_OUT"] else {
            throw XCTSkip("Snapshot harness runs only with CT_SNAPSHOT_OUT set.")
        }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraToolkitSnapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = DashboardModel(
            jobs: [],
            configuration: AppConfiguration.defaults(applicationSupport: root),
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
        )
        model.jobHistoryEnabled = true
        let url = try XCTUnwrap(model.jobHistoryURL)
        defer { CatalogDatabase.checkpointAndClose(url: url) }
        let store = try XCTUnwrap(JobHistoryStore.shared(at: url))
        let (sync, samples, items) = Self.syncJob()
        try store.write(job: sync, samples: samples, items: items, jobID: sync.id)
        try store.write(job: Self.failedSync(), samples: [], items: [
            JobHistoryItem(relativePath: "2026/Sample Event/Originals/Camera A/DSC01234.ARW", byteCount: 48_000_000, start: 3, end: 9, slot: 0, outcome: .failed, verifyMethod: "smb", error: "The NAS disconnected. Sync again once it is back; verified files are skipped."),
        ], jobID: Self.failedSync().id)
        let (check, checkSamples) = Self.checkOnlySync(after: sync.startedAt)
        try store.write(job: check, samples: checkSamples, items: [], jobID: check.id)
        let card = JobHistoryJob(
            kind: JobAction.ingestCard.rawValue, title: "Copied the camera card to the Buffer",
            startedAt: sync.startedAt.addingTimeInterval(-86_400), endedAt: sync.startedAt.addingTimeInterval(-86_400 + 4),
            outcome: .succeeded, totalFiles: 18, totalBytes: 580_000_000, bytesDone: 580_000_000
        )
        try store.write(job: card, samples: [
            JobHistorySample(t: 1, combined: 150, doneBytes: 150_000_000, doneFiles: 4),
            JobHistorySample(t: 2, combined: 148, doneBytes: 300_000_000, doneFiles: 9),
            JobHistorySample(t: 3, combined: 151, doneBytes: 450_000_000, doneFiles: 14),
        ], items: [], jobID: card.id)

        // A Clear from Card run: two files removed, one skipped in Verify.
        let clear = JobHistoryJob(
            kind: JobAction.freeUp.rawValue, title: "Cleared files from CARD",
            startedAt: sync.startedAt.addingTimeInterval(8_000), endedAt: sync.startedAt.addingTimeInterval(8_012), outcome: .succeeded,
            totalFiles: 3, totalBytes: 90_000_000, matchedExisting: 2, failed: 1,
            summary: JobHistorySummary(
                phases: [JobPhaseTotal(label: "Verify", seconds: 9, activeSeconds: 9), JobPhaseTotal(label: "Remove", seconds: 2, activeSeconds: 2)],
                note: "Cleared 2 file(s) from CARD (50 MB). 1 file(s) stayed: its drive copy changed since Sync to NAS verified it."
            )
        )
        try store.write(job: clear, samples: [], items: [
            JobHistoryItem(relativePath: "DCIM/100MSDCF/DSC00001.ARW", byteCount: 40_000_000, start: nil, end: 10, outcome: .matched, verifyMethod: "NAS re-read"),
            JobHistoryItem(relativePath: "DCIM/100MSDCF/DSC00001.JPG", byteCount: 10_000_000, start: nil, end: 10, outcome: .matched, verifyMethod: "NAS re-read"),
            JobHistoryItem(relativePath: "DCIM/100MSDCF/DSC00002.ARW", byteCount: 40_000_000, start: nil, end: 9, outcome: .failed, verifyMethod: "NAS re-read", error: "Skipped in Verify: the drive copy changed since Sync to NAS verified it. The card file stays."),
        ], jobID: clear.id)

        let browser = JobHistoryBrowser(model: model)
        await browser.reload()
        await browser.open(sync.id)
        let detail = try XCTUnwrap(browser.detail)
        await browser.open(check.id)
        let checkDetail = try XCTUnwrap(browser.detail)
        await browser.open(card.id)
        let cardDetail = try XCTUnwrap(browser.detail)
        await browser.open(clear.id)
        let clearDetail = try XCTUnwrap(browser.detail)
        // The window opens on the sync.
        await browser.open(sync.id)
        let monitor = JobActivityMonitor(ceilingResolver: nil)

        let hover = JobHistoryHover()
        hover.t = 3_050
        hover.inFlight = Set(detail.flights.inFlight(at: 3_050))
        let zoomedHover = JobHistoryHover()
        let row = items.firstIndex { ($0.start ?? 0) > 1_110 } ?? 0
        zoomedHover.row = row
        let full = JobHistoryZoom(full: 0...detail.graph.duration)
        var zoom = full
        zoom.show(1_080...1_160)

        func pane(_ detail: JobHistoryDetail, zoom: JobHistoryZoom, hover: JobHistoryHover) -> AnyView {
            AnyView(ScrollView {
                JobActivityDetail(live: nil, detail: detail, monitor: monitor, zoom: .constant(zoom), hover: hover)
            }
            .background(.background))
        }

        // A Clear from Card waiting behind the running sync.
        let running = JobSnapshot(action: .syncBuffer, state: .running, progress: 0.4, note: "Sync to NAS: Copying to NAS", createdAt: Date().addingTimeInterval(-90))
        let queuedClear = JobSnapshot(
            action: .freeUp, state: .queued, note: "Clear 12 file(s) from CARD.",
            detail: "Waits for the running job. Then Verify re-hashes each card file, its drive copy and the NAS copy against the hash Sync to NAS verified, and Remove deletes only the card files that passed."
        )
        let queueModel = DashboardModel(
            jobs: [running, queuedClear],
            configuration: AppConfiguration.defaults(applicationSupport: root),
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config-queue.json"))
        )

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            try render(AnyView(TransferQueueView(model: model, selection: sync.id, history: browser).background(.background)), size: NSSize(width: 1_280, height: 820), appearance: appearance,
                       to: folder.appendingPathComponent("jobs-window-\(suffix).png"))
            try render(AnyView(TransferQueueView(model: queueModel, selection: queuedClear.id).background(.background)), size: NSSize(width: 1_100, height: 560), appearance: appearance,
                       to: folder.appendingPathComponent("jobs-queued-\(suffix).png"))
            try render(pane(clearDetail, zoom: JobHistoryZoom(full: 0...clearDetail.graph.duration), hover: JobHistoryHover()), size: NSSize(width: 860, height: 560), appearance: appearance,
                       to: folder.appendingPathComponent("jobs-clear-card-\(suffix).png"))
            try render(pane(detail, zoom: full, hover: hover), size: NSSize(width: 860, height: 640), appearance: appearance,
                       to: folder.appendingPathComponent("jobs-sync-hover-\(suffix).png"))
            try render(pane(detail, zoom: zoom, hover: zoomedHover), size: NSSize(width: 860, height: 640), appearance: appearance,
                       to: folder.appendingPathComponent("jobs-sync-zoomed-\(suffix).png"))
            try render(pane(checkDetail, zoom: JobHistoryZoom(full: 0...checkDetail.graph.duration), hover: JobHistoryHover()), size: NSSize(width: 860, height: 420), appearance: appearance,
                       to: folder.appendingPathComponent("jobs-check-only-\(suffix).png"))
            try render(pane(cardDetail, zoom: JobHistoryZoom(full: 0...cardDetail.graph.duration), hover: JobHistoryHover()), size: NSSize(width: 860, height: 420), appearance: appearance,
                       to: folder.appendingPathComponent("jobs-short-card-\(suffix).png"))
        }

        if let real = ProcessInfo.processInfo.environment["CT_SNAPSHOT_HISTORY_DB"] {
            try await renderRecordedJobs(from: URL(fileURLWithPath: real), root: root, folder: folder, monitor: monitor)
        }
    }

    /// Every copy, sync and scan in a real history file, rendered from a
    /// copy of it.
    private func renderRecordedJobs(from source: URL, root: URL, folder: URL, monitor: JobActivityMonitor) async throws {
        let copy = root.appendingPathComponent("recorded-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { CatalogDatabase.checkpointAndClose(url: copy) }
        let store = try XCTUnwrap(JobHistoryStore.shared(at: copy))
        let kinds: Set<String> = [JobAction.syncBuffer.rawValue, JobAction.ingestCard.rawValue, JobAction.faceScan.rawValue]
        for (index, job) in try store.jobs().filter({ kinds.contains($0.kind) }).enumerated() {
            let detail = JobHistoryDetail(job: job, samples: try store.samples(jobID: job.id), items: try store.items(jobID: job.id))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                let view = ScrollView {
                    JobActivityDetail(live: nil, detail: detail, monitor: monitor, zoom: .constant(JobHistoryZoom(full: 0...detail.graph.duration)), hover: JobHistoryHover())
                }
                .background(.background)
                try render(AnyView(view), size: NSSize(width: 860, height: 600), appearance: appearance,
                           to: folder.appendingPathComponent("recorded-\(String(format: "%02d", index))-\(job.kind)-\(suffix).png"))
            }
        }
    }

    /// A sync of an event already on the NAS: 16,000 files checked in about
    /// ten seconds, nothing copied.
    private static func checkOnlySync(after start: Date) -> (JobHistoryJob, [JobHistorySample]) {
        let started = start.addingTimeInterval(9_000)
        let job = JobHistoryJob(
            kind: JobAction.syncBuffer.rawValue, title: "Synced all events to the NAS",
            startedAt: started, endedAt: started.addingTimeInterval(16), outcome: .succeeded,
            totalFiles: 16_010, alreadyVerified: 16_009, conflicts: 1,
            configuration: "4 transfers in parallel · SSH verify",
            summary: JobHistorySummary(phases: [JobPhaseTotal(label: "Check", seconds: 10.5, activeSeconds: 10.5)], verifyMethod: "ssh")
        )
        return (job, [
            JobHistorySample(t: 5.04),
            JobHistorySample(t: 6.36, combined: 0, filesPerSecond: 1_718, doneFiles: 2_276),
            JobHistorySample(t: 7.96, combined: 0, filesPerSecond: 2_493, doneFiles: 7_275),
            JobHistorySample(t: 15.52, combined: 0, filesPerSecond: 1_155, doneFiles: 16_010),
        ])
    }

    /// Two hours through four transfers on 1 GbE: ~48 MB files copied at
    /// ~28 MB/s each and re-read over SMB, with a stall at 50 minutes.
    private static func syncJob() -> (JobHistoryJob, [JobHistorySample], [JobHistoryItem]) {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let duration = 7_200.0
        var samples: [JobHistorySample] = []
        var generator = SystemRandomNumberGenerator()
        for second in 0..<Int(duration) {
            let t = Double(second)
            let stalled = (3_000..<3_090).contains(second)
            let wobble = Double.random(in: -6...6, using: &generator)
            let combined = stalled ? 0 : 108 + wobble
            samples.append(JobHistorySample(
                t: t,
                combined: second < 2 ? nil : combined,
                copy: stalled ? nil : 57 + wobble / 2,
                verify: stalled ? nil : 52 - wobble / 3,
                activeTransfers: stalled ? 0 : 4,
                cpu: 0.18 + Double.random(in: 0...0.05, using: &generator),
                transferBytes: Int64(t * 108_000_000),
                doneBytes: Int64(t * 108_000_000),
                doneFiles: second / 2
            ))
        }
        var items: [JobHistoryItem] = []
        for slot in 0..<4 {
            var t = Double(slot) * 0.4 + 1.5
            var index = 0
            while t < duration - 4 {
                if (3_000..<3_090).contains(Int(t)) { t = 3_090 }
                let bytes = Int64(40_000_000 + (index * 7_919 + slot * 104_729) % 20_000_000)
                let copy = Double(bytes) / 28_000_000
                let verify = Double(bytes) / 26_000_000
                let failed = index == 211 && slot == 2
                items.append(JobHistoryItem(
                    relativePath: "2026/Sample Event/Originals/Camera \(slot % 2 == 0 ? "A" : "B")/DSC\(String(format: "%05d", slot * 10_000 + index)).ARW",
                    byteCount: bytes,
                    start: t,
                    end: t + copy + verify + 0.05,
                    slot: slot,
                    outcome: failed ? .failed : .copied,
                    verifyMethod: "smb",
                    copySeconds: copy,
                    verifySeconds: verify,
                    error: failed ? "SHA-256 MISMATCH: the NAS copy did not verify. The NAS copy was removed; the drive copy is untouched." : nil
                ))
                t += copy + verify + 0.1
                index += 1
            }
        }
        let copied = items.filter { $0.outcome == .copied }
        let bytes = copied.reduce(Int64(0)) { $0 + $1.byteCount }
        var timings = NASSyncTimings()
        timings.parallelTransfers = 4
        timings.verification = "SMB re-read"
        timings.wallSeconds = duration
        timings.copySeconds = copied.compactMap(\.copySeconds).reduce(0, +)
        timings.verifySeconds = copied.compactMap(\.verifySeconds).reduce(0, +)
        timings.renameSeconds = Double(copied.count) * 0.05
        let job = JobHistoryJob(
            kind: JobAction.syncBuffer.rawValue,
            title: "Synced Sample Event to the NAS",
            startedAt: started,
            endedAt: started.addingTimeInterval(duration),
            outcome: .failed,
            totalFiles: items.count + 4_000,
            totalBytes: bytes + 48_000_000,
            bytesDone: bytes,
            transferBytes: 2 * bytes,
            copied: copied.count,
            matchedExisting: 0,
            alreadyVerified: 4_000,
            conflicts: 0,
            failed: 1,
            configuration: "4 transfers in parallel · SMB verify",
            summary: JobHistorySummary(
                phases: [
                    JobPhaseTotal(label: "Check", seconds: 4, activeSeconds: 4),
                    JobPhaseTotal(label: "Copy", seconds: timings.copySeconds, bytes: bytes, activeSeconds: duration * 0.97),
                    JobPhaseTotal(label: "Verify", seconds: timings.verifySeconds, bytes: bytes, activeSeconds: duration * 0.97),
                    JobPhaseTotal(label: "Rename", seconds: timings.renameSeconds, activeSeconds: 300),
                ],
                timings: timings,
                verifyMethod: "smb",
                hashMismatches: 1,
                note: "Sync to NAS for Sample Event: 1 NAS copy did NOT match the drive's SHA-256."
            )
        )
        return (job, samples, items)
    }

    private static let failedID = UUID()

    private static func failedSync() -> JobHistoryJob {
        let started = Date(timeIntervalSince1970: 1_790_000_000 - 3_600 * 5)
        return JobHistoryJob(
            id: failedID, kind: JobAction.syncBuffer.rawValue, title: "Synced all events to the NAS",
            startedAt: started, endedAt: started.addingTimeInterval(12), outcome: .interrupted,
            totalFiles: 20_000, totalBytes: 900_000_000_000, failed: 1,
            configuration: "4 transfers in parallel · SSH verify"
        )
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
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        host.layoutSubtreeIfNeeded()
        host.display()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.orderOut(nil)
    }
}
