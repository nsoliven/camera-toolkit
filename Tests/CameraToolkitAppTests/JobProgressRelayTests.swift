import Foundation
@testable import CameraToolkitApp
import CameraToolkitCore
import XCTest

/// A worker may report hundreds of times a second; the main actor sees at
/// most four a second, the newest each time, and nothing after the job ends.
@MainActor
final class JobProgressRelayTests: XCTestCase {
    private func update(_ n: Int) -> BackgroundJobUpdate {
        BackgroundJobUpdate(progress: Double(n) / 1_000, note: "Step \(n)", processedFiles: n, totalFiles: 1_000)
    }

    private final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var _notes: [String] = []
        var notes: [String] { lock.withLock { _notes } }
        func add(_ note: String) { lock.withLock { _notes.append(note) } }
    }

    private func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    }

    func testTheFirstReportIsDeliveredAtOnce() async {
        let delivered = Delivered()
        let relay = JobProgressRelay(minimumInterval: 0.2) { delivered.add($0.note) }
        relay.submit(update(1))
        await pump(0.05)
        XCTAssertEqual(delivered.notes, ["Step 1"])
    }

    func testAFloodOfReportsBecomesTheFirstAndTheNewest() async {
        let delivered = Delivered()
        let relay = JobProgressRelay(minimumInterval: 0.2) { delivered.add($0.note) }
        relay.submit(update(1))
        await pump(0.05)
        for n in 2...500 { relay.submit(update(n)) }
        await pump(0.1)
        XCTAssertEqual(delivered.notes, ["Step 1"], "the flood waits out the interval")
        await pump(0.25)
        XCTAssertEqual(delivered.notes, ["Step 1", "Step 500"], "and lands as one report: the newest")
    }

    func testReportsSpacedByTheIntervalAreAllDelivered() async {
        let delivered = Delivered()
        let relay = JobProgressRelay(minimumInterval: 0.05) { delivered.add($0.note) }
        for n in 1...3 {
            relay.submit(update(n))
            await pump(0.12)
        }
        XCTAssertEqual(delivered.notes, ["Step 1", "Step 2", "Step 3"])
    }

    func testAClosedRelayDropsWhatIsWaitingAndWhatComesAfter() async {
        let delivered = Delivered()
        let relay = JobProgressRelay(minimumInterval: 0.2) { delivered.add($0.note) }
        relay.submit(update(1))
        await pump(0.05)
        relay.submit(update(2))
        relay.close()
        relay.submit(update(3))
        await pump(0.3)
        XCTAssertEqual(delivered.notes, ["Step 1"])
    }

    func testTheModelAppliesAReportInOneWriteAndIgnoresLateOnesForFinishedJobs() async throws {
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CameraToolkitRelayTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = DashboardModel(
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: root.appendingPathComponent("Safety Test").path,
                    importSourcePath: root.appendingPathComponent("Card").path,
                    archivePath: root.appendingPathComponent("Library/Originals").path,
                    bufferPath: root.appendingPathComponent("Buffer").path,
                    activityLogPath: root.appendingPathComponent("activity.jsonl").path,
                    selectedDeviceID: "sony-a7v"
                ),
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json")),
                transferQueueStore: TransferQueueStore(url: root.appendingPathComponent("transfer-queue.json")),
                pendingTransferQueueStore: PendingTransferQueueStore(url: root.appendingPathComponent("pending-transfers.json"))
            )
            let job = JobSnapshot(action: .faceScan, state: .running, progress: 0.02, note: "Start")
            model.jobs.insert(job, at: 0)
            let handler = model.jobProgressHandler(jobID: job.id)
            handler(self.update(10))
            await self.pump(0.1)
            XCTAssertEqual(model.jobs.first?.note, "Step 10")
            XCTAssertEqual(model.jobs.first?.processedFiles, 10)
            XCTAssertEqual(try XCTUnwrap(model.jobs.first?.progress), 0.01, accuracy: 0.0001)

            model.finishJob(id: job.id, action: .faceScan, state: .done, note: "Done", logTitle: "Scan", logDetail: "")
            handler(self.update(999))
            model.updateJob(id: job.id, update: self.update(998))
            await self.pump(0.4)
            XCTAssertEqual(model.jobs.first?.note, "Done", "a report that arrives after the job finished leaves its final row alone")
            XCTAssertEqual(model.jobs.first?.progress, 1)
        }
    }
}
