import AppKit
import CameraToolkitCore
import SwiftUI
@testable import CameraToolkitApp
import XCTest

/// The Jobs window's live "Now" pane must fit the window it is hosted in:
/// readouts and labels stay on one line, the chart stays inside its slot
/// in both ranges, and nothing pushes the pane wider than the window —
/// when the pane did, the window grew past its minimum (or the running
/// app's content clipped at the right edge), "CPU" folded to one letter
/// per line, and the rate column read "18.5 MB/:".
///
/// These host the real `TransferQueueView` in a `CameraToolkitWindowFactory`
/// window off-screen (like `MainWindowLayoutTests` does the main window)
/// with a running Sync to NAS — four transfers plus a NAS verify row,
/// telemetry, and a recorder fed ~26 s of samples — and check, at the
/// minimum and a large size, in both chart ranges and across the toggle,
/// that:
/// - the content's fitting width stays within the window,
/// - every scroll view and every expanded job row lies inside the window,
/// - the jobs table is never wider than its scroll view.
///
/// The chart's legend and axes live in the hosting view's layer tree, not
/// in `NSView` frames, and the AX tree stays empty without a window server;
/// the chart slot is instead pinned by `.clipped()` and a fixed frame, and
/// with `CT_SNAPSHOT_OUT` set every checked state is also written as a PNG
/// (`cacheDisplay`, like `MainWindowLayoutTests`; `CT_SNAPSHOT_PREFIX`
/// prefixes the file names) so the marks can be reviewed inside it.
@MainActor
final class JobNowPaneLayoutTests: XCTestCase {
    private var root: URL!
    private var window: NSWindow?

    /// The window sizes checked: the factory minimum and a big desktop
    /// window like the reporter's.
    private static let sizes = [
        NSSize(width: 720, height: 440),
        NSSize(width: 1_680, height: 1_450),
    ]

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobNowPaneLayout-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: JobActivityDetail.chartRangeDefaultsKey)
        window?.orderOut(nil)
        window?.close()
        window = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Layout

    func testNowPaneFitsTheWindowInBothRanges() throws {
        let (job, _, recorder) = makeRunningSyncJob()
        let model = DashboardModel(
            jobs: [job],
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
        )
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
            initialContentSize: NSSize(width: 840, height: 500),
            rootView: TransferQueueView(model: model)
        )
        SnapshotWindows.hide(window)
        window.orderFrontRegardless()
        self.window = window

        for size in Self.sizes {
            window.setContentSize(size)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))

            for range in [ThroughputChartRange.recent, .wholeJob] {
                setChartRange(range)
                try assertLayout(window, size: size, name: "\(range.rawValue)-\(Int(size.width))x\(Int(size.height))")
            }

            // The reported sequence: the chart's slot off-screen below the
            // fold, toggle to the whole job, then scroll down to look.
            scrollJobsList(in: window, toTop: true)
            setChartRange(.wholeJob)
            scrollJobsList(in: window, toTop: false)
            try assertLayout(window, size: size, name: "toggled-scrolled-\(Int(size.width))x\(Int(size.height))")

            // Rapid toggles mid-scroll settle to a contained chart too.
            setChartRange(.recent)
            setChartRange(.wholeJob)
            try assertLayout(window, size: size, name: "toggled-again-\(Int(size.width))x\(Int(size.height))")
        }
    }

    /// The pane on its own must fit the minimum window's inner column
    /// when that width is proposed — a minimum above it is what forced
    /// the pane past the right edge (measured: the row wanted 867 pt in a
    /// ~700 pt column).
    func testDetailFittingWidthStaysInsideTheMinimumWindow() throws {
        let (job, monitor, recorder) = makeRunningSyncJob()
        for range in [ThroughputChartRange.recent, .wholeJob] {
            setChartRange(range)
            let probe = NSHostingController(rootView: AnyView(
                JobActivityDetail(
                    job: job, monitor: monitor, sampling: false, fixedUptime: 26,
                    wholeJobSamples: { recorder.samples() }
                )
                .background(.background)
            ))
            probe.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let fitted = probe.sizeThatFits(in: NSSize(width: 700, height: CGFloat.infinity))
            XCTAssertLessThanOrEqual(
                fitted.width, 700.5,
                "\(range): the pane wants \(fitted.width) inside a 700-wide column"
            )
            probe.view.frame = NSRect(origin: .zero, size: NSSize(width: 700, height: fitted.height))
            probe.view.layoutSubtreeIfNeeded()
            try writePNG(probe.view, name: "detail-700-\(range.rawValue)")
        }
    }

    // MARK: - Whole-job readout

    /// In the whole-job range the FILES readout is the job average —
    /// files done over the job's wall time — like the byte "average" next
    /// to it, not the smoothed live rate (a resumed sync settling already-
    /// verified files holds a meaningless rate otherwise).
    func testWholeJobFilesRateIsTheJobAverage() throws {
        var live = JobThroughputReadout(unit: .megabytesPerSecond, current: 12.4, average: 8.1, filesPerSecond: 19_589)
        live.series = ["Overall"]

        var samples: [JobHistorySample] = []
        for second in 0...26 {
            let doneFiles: Int = second < 2 ? second * 1_900 : 3_800 + (second - 2) * 16
            let doneBytes: Int64 = Int64(second) * 1_600_000_000
            samples.append(JobHistorySample(
                t: Double(second), combined: 104, copy: 108, verify: 96,
                doneBytes: doneBytes, doneFiles: doneFiles
            ))
        }
        let readout = live.wholeJob(samples: samples, elapsed: 26)

        XCTAssertEqual(readout.filesPerSecond ?? 0, 4_184 / 26, accuracy: 0.01)
        XCTAssertTrue(readout.wholeJobRate)
        XCTAssertEqual(live.wholeJobRate, false)
        XCTAssertFalse(readout.points.isEmpty)
        XCTAssertEqual(readout.xDomain, 0...60)
    }

    /// No settled files yet (or a job that just started) shows no rate
    /// rather than a huge or divided-by-zero one.
    func testWholeJobFilesRateNeedsAFileAndASecond() throws {
        var live = JobThroughputReadout(unit: .megabytesPerSecond, filesPerSecond: 9_999)
        let sample = JobHistorySample(t: 0, combined: 0, doneBytes: 0, doneFiles: 0)
        XCTAssertNil(live.wholeJob(samples: [sample], elapsed: 0.5).filesPerSecond)
        XCTAssertTrue(live.wholeJob(samples: [sample], elapsed: 0.5).wholeJobRate)
        live = JobThroughputReadout(unit: .megabytesPerSecond, filesPerSecond: 9_999)
        XCTAssertNil(live.wholeJob(samples: [sample], elapsed: 30).filesPerSecond)
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

        // Every realized row stays inside its table, and the running
        // job's detail row — a tall one, ~500 pt with the chart — is
        // present somewhere in the window's tables.
        var expanded = false
        for (_, table) in tables {
            for rowIndex in 0..<table.numberOfRows {
                guard let row = table.rowView(atRow: rowIndex, makeIfNecessary: false) else { continue }
                let rect = row.convert(row.bounds, to: table)
                XCTAssertLessThanOrEqual(rect.maxX, table.bounds.width + 0.5,
                    "\(name): row \(rowIndex) \(rect) of \(type(of: table)) runs past its table's width")
                expanded = expanded || rect.height > 100
            }
        }
        XCTAssertTrue(expanded, "\(name): the running job's detail row is not expanded")

        try writeSnapshot(window, name: name)
    }

    private func setChartRange(_ range: ThroughputChartRange) {
        UserDefaults.standard.set(range.rawValue, forKey: JobActivityDetail.chartRangeDefaultsKey)
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// The jobs list's scroll view is the one inside the Jobs section —
    /// the window's smallest table scroll view.
    private func scrollJobsList(in window: NSWindow, toTop: Bool) {
        guard let content = window.contentView else { return }
        guard let scroll = scrollViews(in: content)
            .filter({ $0.documentView is NSTableView })
            .min(by: { $0.frame.height < $1.frame.height }),
            let document = scroll.documentView else { return }
        let clip = scroll.contentView
        document.scroll(NSPoint(x: 0, y: toTop ? 0 : max(document.bounds.height - clip.bounds.height, 0)))
        scroll.reflectScrolledClipView(clip)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
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
    /// "Whole job" appears.
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
