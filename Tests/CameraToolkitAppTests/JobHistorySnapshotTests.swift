import AppKit
import CameraToolkitCore
import SwiftUI
@testable import CameraToolkitApp
import XCTest

/// Renders the Jobs window's History off-screen from a synthetic store — a
/// two-hour Sync to NAS with four parallel transfers and a stall, a failed
/// sync, a card copy — and writes PNGs: the whole window, the detail with
/// the pointer on the chart, and a zoomed detail with a file row hovered.
/// Everything lives in a temporary folder. Runs only when
/// `CT_SNAPSHOT_OUT` names an output folder.
@MainActor
final class JobHistorySnapshotTests: XCTestCase {
    func testRenderJobHistory() async throws {
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
        try store.insert(JobHistoryJob(
            kind: JobAction.ingestCard.rawValue, title: "Copied the camera card to the Buffer",
            startedAt: sync.startedAt.addingTimeInterval(-86_400), endedAt: sync.startedAt.addingTimeInterval(-86_400 + 540),
            outcome: .succeeded, totalFiles: 812, totalBytes: 38_000_000_000, bytesDone: 38_000_000_000
        ))

        let browser = JobHistoryBrowser(model: model)
        await browser.reload()
        await browser.open(sync.id)
        let detail = try XCTUnwrap(browser.detail)

        let hover = JobHistoryHover()
        hover.t = 3_050
        hover.inFlight = Set(detail.flights.inFlight(at: 3_050))
        let zoomedHover = JobHistoryHover()
        let row = items.firstIndex { ($0.start ?? 0) > 1_110 } ?? 0
        zoomedHover.row = row
        var zoom = JobHistoryZoom(full: 0...detail.chart.duration)
        zoom.show(1_080...1_160)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            try render(AnyView(JobHistoryView(model: model, browser: browser).background(.background)), size: NSSize(width: 1_280, height: 820), appearance: appearance,
                       to: folder.appendingPathComponent("history-window-\(suffix).png"))
            try render(AnyView(JobHistoryDetailView(detail: detail, isLive: false, hover: hover).background(.background)), size: NSSize(width: 1_000, height: 760), appearance: appearance,
                       to: folder.appendingPathComponent("history-hover-\(suffix).png"))
            try render(AnyView(JobHistoryDetailView(detail: detail, isLive: false, hover: zoomedHover, zoom: zoom).background(.background)), size: NSSize(width: 1_000, height: 760), appearance: appearance,
                       to: folder.appendingPathComponent("history-zoomed-\(suffix).png"))
        }
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
