import AppKit
import CameraToolkitCore
import SwiftUI
@testable import CameraToolkitApp
import XCTest

/// Renders the Jobs window's activity pane off-screen from synthetic
/// telemetry — a Sync to NAS job alternating copy, flush and verify on a
/// 1 GbE link, a face scan, and a card copy — and writes PNGs. Nothing on
/// disk is read; link detection is off. Runs only when `CT_SNAPSHOT_OUT`
/// names an output folder.
@MainActor
final class JobActivitySnapshotTests: XCTestCase {
    func testRenderJobActivity() throws {
        guard let out = ProcessInfo.processInfo.environment["CT_SNAPSHOT_OUT"] else {
            throw XCTSkip("Snapshot harness runs only with CT_SNAPSHOT_OUT set.")
        }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let cases: [(String, JobSnapshot, JobActivityMonitor, TimeInterval)] = [
            Self.syncJob(),
            Self.faceScanJob(),
            Self.cardCopyJob(),
        ]
        for (name, job, monitor, now) in cases {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                let view = JobActivityDetail(job: job, monitor: monitor, sampling: false, fixedUptime: now)
                    .padding(.vertical, 12)
                    .padding(.trailing, 12)
                    .frame(width: 900, alignment: .top)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(.background)
                try render(AnyView(view), size: NSSize(width: 900, height: 460), appearance: appearance,
                           to: folder.appendingPathComponent("jobs-\(name)-\(suffix).png"))
            }
        }
    }

    /// 150 files, ~16 MB each: copy at ~60 MB/s, a flush that stalls the
    /// counters for a few seconds, then a re-read at ~100 MB/s.
    private static func syncJob() -> (String, JobSnapshot, JobActivityMonitor, TimeInterval) {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        let elapsed: TimeInterval = 170
        let created = Date().addingTimeInterval(-elapsed)
        var job = JobSnapshot(
            action: .syncBuffer, state: .running, progress: 0, note: "Sync to NAS: Re-reading NAS copy DSC01793.HEIC",
            destinationPath: "/Sample/NAS", processedFiles: 0, totalFiles: 150, totalBytes: 2 * 150 * 48_000_000,
            createdAt: created
        )
        monitor.setCeiling(JobLinkCeiling(label: "1 GbE", megabytesPerSecond: 115), for: job.id)
        let fileBytes: Double = 48_000_000
        var phases = JobPhaseTimer(order: ["Check", "Copy", "Flush", "Verify", "Hash", "Rename"])
        var copied = 0.0, verified = 0.0, files = 0
        var t = 0.0
        var stage = 0
        var stageLeft = 0.0
        var rate = 0.0
        var nextTick = 0.0
        let step = 0.1
        while t <= elapsed {
            if stageLeft <= 0 {
                stage = (stage + 1) % 5
                let wobble = 1 + 0.25 * sin(t / 9)
                switch stage {
                case 0: phases.begin("Check", at: t); stageLeft = 0.15
                case 1: phases.begin("Copy", at: t); rate = 58_000_000 * wobble; stageLeft = fileBytes / rate
                case 2: phases.begin("Flush", at: t); stageLeft = 0.9 * wobble
                case 3: phases.begin("Verify", at: t); rate = 104_000_000 / wobble; stageLeft = fileBytes / rate
                default: phases.begin("Rename", at: t); stageLeft = 0.2; files += 1
                }
            }
            let bytes = rate * min(step, max(stageLeft, 0))
            switch stage {
            case 1: copied += bytes; phases.addBytes(Int64(bytes))
            case 3: verified += bytes; phases.addBytes(Int64(bytes))
            default: break
            }
            stageLeft -= step
            t += step
            if t >= nextTick {
                nextTick += 1
                // Counters move in 4 MB chunks, as NASFileIO reports them.
                let chunk = 4_194_304.0
                job.processedBytes = Int64(((copied + verified) / chunk).rounded(.down) * chunk)
                job.processedFiles = files
                job.telemetry = JobTelemetry(
                    step: stage == 2 ? "Flushing to NAS" : "Re-reading NAS copy",
                    activeItems: [JobActiveItem(name: "DSC01793.HEIC", path: "/Sample/Drive/DSC01793.HEIC", step: "Re-reading NAS copy")],
                    counters: [
                        JobCounter(label: "Copied", value: files),
                        JobCounter(label: "Already on NAS", value: 0),
                        JobCounter(label: "Conflicts", value: 0),
                        JobCounter(label: "Failed", value: 0),
                    ],
                    work: JobWorkEstimate(unitsDone: Int(job.processedBytes), unitsTotal: Int(job.totalBytes), secondsRemaining: 14 * 60),
                    phases: phases.snapshot(at: t)
                )
                job.progress = Double(job.processedBytes) / Double(job.totalBytes)
                monitor.tick(job: job, now: t, wallNow: created.addingTimeInterval(t))
            }
        }
        return ("sync", job, monitor, t)
    }

    private static func faceScanJob() -> (String, JobSnapshot, JobActivityMonitor, TimeInterval) {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        let elapsed: TimeInterval = 95
        let created = Date().addingTimeInterval(-elapsed)
        var job = JobSnapshot(
            action: .faceScan, state: .running, note: "Face scan: Detecting faces", processedFiles: 0, totalFiles: 820,
            totalBytes: 24_000_000_000, createdAt: created
        )
        var read = 0.0
        for second in 0...Int(elapsed) {
            let t = Double(second)
            read += 42_000_000 * (1 + 0.35 * sin(t / 7))
            job.processedFiles = Int(t * 2.4)
            job.processedBytes = Int64(read)
            job.telemetry = JobTelemetry(
                step: "Embed",
                activeItems: (0..<4).map { JobActiveItem(name: "DSC0\(4100 + $0 + second).ARW", path: "/Sample/DSC0\(4100 + $0 + second).ARW", step: ["Decode", "Detect", "Embed", "Align"][$0]) },
                counters: [JobCounter(label: "Faces", value: second * 3), JobCounter(label: "Video frames", value: second * 11)],
                models: ["InsightFace buffalo_l (SCRFD-10G + ArcFace w600k_r50)"],
                facts: ["MED", "FAST", "4 workers"],
                work: JobWorkEstimate(unitsDone: second * 13, unitsTotal: 9_000, unitLabel: "photos and frames", secondsRemaining: 610)
            )
            job.progress = Double(second * 13) / 9_000
            monitor.tick(job: job, now: t, wallNow: created.addingTimeInterval(t))
        }
        return ("face-scan", job, monitor, elapsed)
    }

    private static func cardCopyJob() -> (String, JobSnapshot, JobActivityMonitor, TimeInterval) {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        let elapsed: TimeInterval = 240
        let created = Date().addingTimeInterval(-elapsed)
        var job = JobSnapshot(
            action: .ingestCard, state: .running, note: "Card copy: Copying C0042.MP4", currentPath: "/Sample/Card/C0042.MP4",
            processedFiles: 0, totalFiles: 412, totalBytes: 96_000_000_000, createdAt: created
        )
        monitor.setCeiling(JobLinkCeiling(label: "USB 10 Gb/s", megabytesPerSecond: 300), for: job.id)
        var bytes = 0.0
        for second in 0...Int(elapsed) {
            let t = Double(second)
            bytes += 182_000_000 * (1 + 0.12 * sin(t / 5)) * (second % 47 < 3 ? 0.2 : 1)
            job.processedBytes = Int64(bytes)
            job.processedFiles = Int(bytes / 230_000_000)
            job.progress = bytes / Double(job.totalBytes)
            monitor.tick(job: job, now: t, wallNow: created.addingTimeInterval(t))
        }
        return ("card-copy", job, monitor, elapsed)
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        host.display()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.orderOut(nil)
    }
}
