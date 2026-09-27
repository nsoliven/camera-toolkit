import AppKit
import CameraToolkitCore
import SwiftUI
@testable import CameraToolkitApp
import XCTest

/// Renders the Jobs window's activity pane off-screen from synthetic
/// telemetry — a Sync to NAS job with four parallel transfers on a 1 GbE
/// link (SMB and SSH verification), a face scan, and a card copy — and
/// writes PNGs. Nothing on
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
            Self.fastSyncJob(ssh: false),
            Self.fastSyncJob(ssh: true),
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
                try render(AnyView(view), size: NSSize(width: 900, height: 600), appearance: appearance,
                           to: folder.appendingPathComponent("jobs-\(name)-\(suffix).png"))
            }
        }
    }

    /// 900 files of 48 MB through the fast engine: four transfers in
    /// parallel sharing a 1 GbE link (~28 MB/s each), no flush, then either
    /// an SMB re-read per file or NAS-side hashing in batches of eight.
    private static func fastSyncJob(ssh: Bool) -> (String, JobSnapshot, JobActivityMonitor, TimeInterval) {
        let monitor = JobActivityMonitor(ceilingResolver: nil)
        let elapsed: TimeInterval = 170
        let created = Date().addingTimeInterval(-elapsed)
        let workers = 4
        let fileBytes: Int64 = 48_000_000
        var job = JobSnapshot(
            action: .syncBuffer, state: .running, progress: 0, note: "Sync to NAS: Copying to NAS",
            destinationPath: "/Sample/NAS", processedFiles: 0, totalFiles: 900, totalBytes: 2 * 900 * fileBytes,
            createdAt: created
        )
        monitor.setCeiling(JobLinkCeiling(label: "1 GbE", megabytesPerSecond: 115), for: job.id)

        struct Worker {
            var stage = 0 // 0 idle, 1 copy, 2 verify (SMB), 3 rename
            var file = 0
            var done: Int64 = 0
            var left = 0.0
            var moved: Int64 = 0
            var meter = TransferRateMeter()
            var outcome = "Starting"
        }
        var ledger = JobPhaseLedger(order: ["Check", "Copy", "Flush", "Verify", "Remote verify (NAS)", "Hash", "Rename"])
        var rows = Array(repeating: Worker(), count: workers)
        var nextFile = 0, finished = 0
        var doneWork: Int64 = 0, transfer: Int64 = 0
        var queued: [Int] = []
        var batch: (files: [Int], left: Double)?
        var t = 0.0
        let step = 0.05
        var nextEmit = 0.0, nextTick = 0.0
        ledger.begin("Check", lane: -1, at: 0)
        let checkUntil = 1.2
        while t <= elapsed {
            if t >= checkUntil { ledger.end(lane: -1, at: t) }
            for index in rows.indices where t >= checkUntil {
                if rows[index].stage == 0 {
                    rows[index].file = nextFile
                    nextFile += 1
                    rows[index].stage = 1
                    rows[index].done = 0
                    ledger.begin("Copy", lane: index, at: t)
                }
                let wobble = 1 + 0.12 * sin(t / 6 + Double(index))
                switch rows[index].stage {
                case 1, 2:
                    let rate = (rows[index].stage == 1 ? 28_000_000 : 26_000_000) * wobble
                    let bytes = min(Int64(rate * step), fileBytes - rows[index].done)
                    rows[index].done += bytes
                    rows[index].moved += bytes
                    doneWork += bytes
                    transfer += bytes
                    ledger.addBytes(bytes, to: rows[index].stage == 1 ? "Copy" : "Verify")
                    if rows[index].done >= fileBytes {
                        if rows[index].stage == 1 && ssh {
                            queued.append(rows[index].file)
                            ledger.end(lane: index, at: t)
                            rows[index].outcome = "Queued for NAS verify"
                            rows[index].stage = 0
                        } else if rows[index].stage == 1 {
                            rows[index].stage = 2
                            rows[index].done = 0
                            ledger.begin("Verify", lane: index, at: t)
                        } else {
                            rows[index].stage = 3
                            rows[index].left = 0.08
                            ledger.begin("Rename", lane: index, at: t)
                        }
                    }
                case 3:
                    rows[index].left -= step
                    if rows[index].left <= 0 {
                        ledger.end(lane: index, at: t)
                        rows[index].outcome = "Verified"
                        rows[index].stage = 0
                        finished += 1
                    }
                default: break
                }
            }
            // NAS-side hashing: one batch of eight at a time, ~400 MB/s on the NAS.
            if ssh {
                if batch == nil, queued.count >= 8 {
                    batch = (Array(queued.prefix(8)), Double(8 * fileBytes) / 400_000_000)
                    queued.removeFirst(8)
                    ledger.begin("Remote verify (NAS)", lane: workers, at: t)
                }
                if var current = batch {
                    current.left -= step
                    batch = current
                    if current.left <= 0 {
                        let bytes = Int64(current.files.count) * fileBytes
                        doneWork += bytes
                        ledger.addBytes(bytes, to: "Remote verify (NAS)")
                        ledger.end(lane: workers, at: t)
                        finished += current.files.count
                        batch = nil
                    }
                }
            }
            t += step
            if t >= nextEmit {
                nextEmit += 0.25
                var items: [JobActiveItem] = []
                for index in rows.indices where t >= checkUntil {
                    rows[index].meter.record(rows[index].moved, at: t)
                    let row = rows[index]
                    let phase = [0: row.outcome, 1: "Copying", 2: "Verifying", 3: "Renaming"][row.stage] ?? ""
                    let name = String(format: "DSC%05d.ARW", 1700 + row.file)
                    items.append(JobActiveItem(
                        name: name, path: "/Sample/Drive/\(name)", step: phase, slot: index, phase: phase,
                        bytesDone: row.stage == 3 || row.stage == 0 ? fileBytes : row.done, bytesTotal: fileBytes,
                        bytesPerSecond: row.meter.bytesPerSecond
                    ))
                }
                if let batch {
                    items.append(JobActiveItem(
                        name: "\(batch.files.count) files", path: "/Sample/NAS", step: "Hashing on NAS", slot: workers,
                        phase: "Verifying on NAS", bytesDone: 0, bytesTotal: Int64(batch.files.count) * fileBytes
                    ))
                }
                job.processedBytes = doneWork
                job.processedFiles = finished
                let remaining = Double(job.totalBytes - doneWork)
                job.telemetry = JobTelemetry(
                    step: t < checkUntil ? "Checking NAS" : "Copying to NAS",
                    activeItems: items,
                    counters: [
                        JobCounter(label: "Copied", value: finished),
                        JobCounter(label: "Already on NAS", value: 0),
                        JobCounter(label: "Conflicts", value: 0),
                        JobCounter(label: "Failed", value: 0),
                    ],
                    facts: ["\(workers) parallel", ssh ? "Verify: NAS SHA-256 (ssh nas)" : "Verify: SMB re-read"],
                    work: JobWorkEstimate(
                        unitsDone: Int(doneWork), unitsTotal: Int(job.totalBytes),
                        secondsRemaining: t < 15 ? nil : remaining / (Double(doneWork) / t)
                    ),
                    phases: ledger.snapshot(at: t),
                    configuration: "\(workers) transfers in parallel · \(ssh ? "SSH" : "SMB") verify",
                    transferBytes: transfer
                )
                job.progress = Double(doneWork) / Double(job.totalBytes)
            }
            if t >= nextTick {
                nextTick += 1
                monitor.tick(job: job, now: t, wallNow: created.addingTimeInterval(t))
            }
        }
        return (ssh ? "fastsync-ssh" : "fastsync-smb", job, monitor, t)
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
