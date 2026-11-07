import AppKit
import CameraToolkitCore
import SwiftUI
@testable import CameraToolkitApp
import XCTest

/// The Jobs window — job list on the left, the selected job's pane on the
/// right — must fit the window it is hosted in: readouts and labels stay on
/// one line, the speed graph stays inside its slot, and nothing pushes the
/// pane wider than the window — when the old pane did, the window grew
/// past its minimum (or the running app's content clipped at the right
/// edge), "CPU" folded to one letter per line, and the rate column read
/// "18.5 MB/:".
///
/// These host the real `TransferQueueView` in a `CameraToolkitWindowFactory`
/// window off-screen (like `MainWindowLayoutTests` does the main window)
/// with a running Sync to NAS — four transfers plus a NAS verify row,
/// telemetry, and a recorder fed ~26 s of samples — and check, at the
/// minimum and a large size, that:
/// - the content's fitting width stays within the window,
/// - every scroll view and table lies inside the window,
/// - the selected job's pane is there, tall enough to hold the graph.
///
/// The chart's marks live in the hosting view's layer tree, not in
/// `NSView` frames; with `CT_SNAPSHOT_OUT` set every checked state is also
/// written as a PNG (`cacheDisplay`; `CT_SNAPSHOT_PREFIX` prefixes the file
/// names) so the marks can be reviewed.
@MainActor
final class JobNowPaneLayoutTests: XCTestCase {
    private var root: URL!
    private var window: NSWindow?

    /// The window sizes checked: the factory minimum and a big desktop
    /// window like the reporter's.
    private static let sizes = [
        CameraToolkitPopOutWindow.transferQueue.minimumContentSize,
        NSSize(width: 1_680, height: 1_450),
    ]

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobNowPaneLayout-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.close()
        window = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Layout

    func testJobsWindowFitsAtItsMinimumAndLarge() throws {
        let (job, _, recorder) = makeRunningSyncJob()
        let model = DashboardModel(
            jobs: [job],
            configuration: AppConfiguration.defaults(applicationSupport: root),
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
        )
        model.jobHistoryEnabled = true
        defer { model.jobHistoryURL.map { CatalogDatabase.checkpointAndClose(url: $0) } }
        model.transferQueue = TransferQueueSnapshot(
            state: .running,
            sourcePath: "/Sample/Camera",
            destinationPath: "/Sample/Drive",
            items: (0..<40).map { TransferQueueItem(relativePath: "DSC\($0).ARW", size: 48_000_000) },
            progress: 0.3,
            totalBytes: 900_000_000_000,
            phase: "Copying"
        )
        model.jobHistoryRecorders[job.id] = recorder

        let window = CameraToolkitWindowFactory.make(
            .transferQueue,
            identifier: "CameraToolkitJobsLayout-\(UUID().uuidString)",
            title: "Jobs",
            initialContentSize: NSSize(width: 1_080, height: 720),
            rootView: TransferQueueView(model: model)
        )
        SnapshotWindows.hide(window)
        window.orderFrontRegardless()
        self.window = window

        for size in Self.sizes {
            window.setContentSize(size)
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            try assertLayout(window, size: size, name: "\(Int(size.width))x\(Int(size.height))")
        }
    }

    /// The pane on its own must fit the detail column of the minimum
    /// window when that width is proposed — a minimum above it is what
    /// forced the old pane past the right edge.
    func testDetailFittingWidthStaysInsideTheMinimumWindow() throws {
        let (job, monitor, recorder) = makeRunningSyncJob()
        let detail = JobHistoryDetail(job: recorder.currentJob(), samples: recorder.samples(), items: [])
        let column = CameraToolkitPopOutWindow.transferQueue.minimumContentSize.width - 230
        for live in [job, nil] {
            let probe = NSHostingController(rootView: AnyView(
                JobActivityDetail(
                    live: live, detail: detail, monitor: monitor,
                    zoom: .constant(JobHistoryZoom(full: 0...detail.graph.duration)), hover: JobHistoryHover(),
                    sampling: false, fixedUptime: 26
                )
                .background(.background)
            ))
            probe.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let fitted = probe.sizeThatFits(in: NSSize(width: column, height: CGFloat.infinity))
            let name = live == nil ? "recorded" : "running"
            XCTAssertLessThanOrEqual(fitted.width, column + 0.5, "\(name): the pane wants \(fitted.width) inside a \(column)-wide column")
            probe.view.frame = NSRect(origin: .zero, size: NSSize(width: column, height: fitted.height))
            probe.view.layoutSubtreeIfNeeded()
            try writePNG(probe.view, name: "detail-\(Int(column))-\(name)")
        }
    }

    // MARK: - Checks

    private func assertLayout(_ window: NSWindow, size: NSSize, name: String) throws {
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        window.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(window.contentView, name)

        // The laid-out content stays inside the window it was given —
        // before, the pane ran past the trailing edge and the window
        // grew to fit it.
        XCTAssertLessThanOrEqual(content.bounds.width, size.width + 0.5,
            "\(name): the window grew to \(content.bounds.width) for overflowing content")

        // Nothing scrollable — and no table — reaches past the edge.
        var tables: [(scroll: NSScrollView, table: NSTableView)] = []
        for scroll in scrollViews(in: content) {
            let frame = scroll.convert(scroll.bounds, to: nil)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(name): \(type(of: scroll)) \(frame) runs off the leading edge")
            XCTAssertLessThanOrEqual(frame.maxX, content.bounds.width + 0.5, "\(name): \(type(of: scroll)) \(frame) runs off the trailing edge")
            if let table = scroll.documentView as? NSTableView {
                tables.append((scroll, table))
                XCTAssertLessThanOrEqual(table.bounds.width, scroll.contentView.bounds.width + 0.5,
                    "\(name): the table (\(table.bounds.width)) is wider than its scroll view (\(scroll.contentView.bounds.width))")
            }
        }

        // Every realized row stays inside its table.
        for (_, table) in tables {
            for rowIndex in 0..<table.numberOfRows {
                guard let row = table.rowView(atRow: rowIndex, makeIfNecessary: false) else { continue }
                let rect = row.convert(row.bounds, to: table)
                XCTAssertLessThanOrEqual(rect.maxX, table.bounds.width + 0.5,
                    "\(name): row \(rowIndex) \(rect) of \(type(of: table)) runs past its table's width")
            }
        }
        // The running job is selected and its pane — header, transfers,
        // readouts, graph — is laid out in a scroll view of its own.
        let panes = scrollViews(in: content).filter { !($0.documentView is NSTableView) && ($0.documentView?.frame.height ?? 0) > 300 }
        XCTAssertFalse(panes.isEmpty, "\(name): the running job's pane is missing")

        try writeSnapshot(window, name: name)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHidden, scroll.frame.height > 0 {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    private func writeSnapshot(_ window: NSWindow, name: String) throws {
        guard let frameView = window.contentView?.superview else { return }
        try writePNG(frameView, name: name)
    }

    /// PNG review copies, only with `CT_SNAPSHOT_OUT` set.
    private func writePNG(_ view: NSView, name: String) throws {
        guard let out = ProcessInfo.processInfo.environment["CT_SNAPSHOT_OUT"] else { return }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bounds = view.bounds
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: bitmap)
        let prefix = ProcessInfo.processInfo.environment["CT_SNAPSHOT_PREFIX"] ?? ""
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent("\(prefix)nowpane-\(name).png"))
    }

    // MARK: - Fixture

    /// A running Sync to NAS, ~26 s in: four transfers plus a NAS verify
    /// row like the reporter's job, and a recorder fed the same seconds so
    /// the graph has its whole run.
    private func makeRunningSyncJob() -> (JobSnapshot, JobActivityMonitor, JobHistoryRecorder) {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        let elapsed: TimeInterval = 26
        let created = Date().addingTimeInterval(-elapsed)
        var job = JobSnapshot(
            action: .syncBuffer, state: .running, progress: 0.26, note: "Sync to NAS: Copying to NAS",
            destinationPath: "/Sample/NAS", processedFiles: 0, totalFiles: 15_957,
            totalBytes: 900_000_000_000, createdAt: created
        )
        monitor.setCeiling(JobLinkCeiling(label: "10 GbE", megabytesPerSecond: 1_150), for: job.id)

        final class ClockBox: @unchecked Sendable { var t = 0.0 }
        let clock = ClockBox()
        let recorder = JobHistoryRecorder(
            store: nil, id: job.id, kind: job.action.rawValue, title: "Sync to NAS",
            startedAt: created, clock: { clock.t }
        )

        var copyBytes: Int64 = 0
        var verifyBytes: Int64 = 0
        var remoteBytes: Int64 = 0
        var copySeconds = 0.0
        var verifySeconds = 0.0
        var remoteSeconds = 0.0
        for second in 0...Int(elapsed) {
            let t = Double(second)
            let done = second < 2 ? second * 1_900 : min(3_800 + (second - 2) * 16, 15_957)
            job.processedFiles = done
            copyBytes += 4 * 30_000_000
            verifyBytes += 4 * 26_000_000
            if second % 6 == 5 {
                remoteBytes += 8 * 48_000_000
                remoteSeconds += 1
            }
            copySeconds += 0.9
            verifySeconds += 0.8
            let transfer = copyBytes + verifyBytes
            job.processedBytes = transfer
            job.telemetry = JobTelemetry(
                step: "Copying to NAS",
                activeItems: (0..<4).map { slot in
                    JobActiveItem(
                        name: String(format: "DSC%05d.ARW", 1_700 + slot + second * 4), path: "/Sample/Drive/DSC.ARW",
                        step: slot == 3 ? "Verifying" : "Copying", slot: slot,
                        phase: slot == 3 ? "Verifying" : "Copying",
                        bytesDone: 20_000_000, bytesTotal: 48_000_000,
                        bytesPerSecond: slot == 3 ? 26_000_000 : 30_000_000
                    )
                } + [JobActiveItem(
                    name: "8 files", path: "/Sample/NAS", step: "Hashing on NAS", slot: 4,
                    phase: "Verifying on NAS", bytesDone: 0, bytesTotal: 384_000_000
                )],
                counters: [
                    JobCounter(label: "Copied", value: done),
                    JobCounter(label: "Already on NAS", value: 0),
                    JobCounter(label: "Failed", value: 0),
                ],
                facts: ["4 parallel", "Verify: NAS SHA-256 (ssh nas)"],
                work: JobWorkEstimate(
                    unitsDone: Int(transfer), unitsTotal: Int(job.totalBytes),
                    secondsRemaining: 6_800
                ),
                phases: [
                    JobPhaseTotal(label: "Check", seconds: 1.2, activeSeconds: 1.2),
                    JobPhaseTotal(label: "Copy", seconds: copySeconds, bytes: copyBytes, activeSeconds: copySeconds),
                    JobPhaseTotal(label: "Verify", seconds: verifySeconds, bytes: verifyBytes, activeSeconds: verifySeconds),
                    JobPhaseTotal(label: "Remote verify (NAS)", seconds: remoteSeconds, bytes: remoteBytes, activeSeconds: remoteSeconds),
                ].filter { $0.seconds > 0 },
                configuration: "4 transfers in parallel · SSH verify",
                transferBytes: transfer
            )
            job.progress = Double(transfer) / Double(job.totalBytes)
            monitor.tick(job: job, now: t, wallNow: created.addingTimeInterval(t))
            clock.t = t
            recorder.observe(JobHistoryRecorder.Observation(
                processedFiles: done, totalFiles: job.totalFiles,
                processedBytes: transfer, totalBytes: job.totalBytes,
                telemetry: job.telemetry
            ), force: t == 0)
        }
        recorder.flush()
        return (job, monitor, recorder)
    }
}
