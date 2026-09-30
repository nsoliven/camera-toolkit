import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

@MainActor
final class DashboardModelTests: XCTestCase {
    func testConfiguredCameraSourceInfersItsDevice() {
        XCTAssertEqual(
            DashboardModel.inferredDeviceID(for: ConfiguredLocation(
                role: .importSource,
                name: "Osmo360 · DJI Osmo 360",
                path: "/Volumes/Osmo360"
            )),
            "osmo-360"
        )
        XCTAssertEqual(
            DashboardModel.inferredDeviceID(for: ConfiguredLocation(
                role: .importSource,
                name: "LEXAR · Sony A7V",
                path: "/Volumes/LEXAR"
            )),
            "sony-a7v"
        )
        XCTAssertEqual(
            DashboardModel.inferredDeviceID(for: ConfiguredLocation(
                role: .importSource,
                name: "OsmoNano · DJI Nano",
                path: "/Volumes/OsmoNano"
            )),
            "dji-nano"
        )
        XCTAssertEqual(
            DashboardModel.inferredDeviceID(for: ConfiguredLocation(
                role: .importSource,
                name: "DJI NANO",
                path: "/Volumes/Buffer Drive/Road Trip 2026 /DJI NANO"
            )),
            "dji-nano"
        )
    }

    func testEventTransfersCanQueueWhileBusyAndRunInSavedFIFOOrder() async throws {
        try await withTemporaryDirectoryAsync { root in
            let card = root.appendingPathComponent("Camera Card", isDirectory: true)
            let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
            let firstPath = "DCIM/FIRST.ARW"
            let secondPath = "DCIM/SECOND.ARW"
            let firstBytes = Data("first-event-photo".utf8)
            let secondBytes = Data("second-event-photo".utf8)
            let firstURL = try writeFile(card.appendingPathComponent(firstPath), firstBytes)
            let secondURL = try writeFile(card.appendingPathComponent(secondPath), secondBytes)
            let firstDestination = buffer.appendingPathComponent("Morning").path
            let secondDestination = buffer.appendingPathComponent("Evening").path
            let pendingStore = PendingTransferQueueStore(url: root.appendingPathComponent("pending-transfers.json"))
            let model = DashboardModel(
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: root.appendingPathComponent("Safety Test").path,
                    importSourcePath: card.path,
                    archivePath: root.appendingPathComponent("Library/Originals").path,
                    bufferPath: buffer.path,
                    activityLogPath: root.appendingPathComponent("activity.jsonl").path,
                    selectedDeviceID: "sony-a7v"
                ),
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json")),
                transferQueueStore: TransferQueueStore(url: root.appendingPathComponent("transfer-queue.json")),
                pendingTransferQueueStore: pendingStore
            )

            model.isBusy = true
            model.enqueueTransfer(
                files: [FileRecord(
                    path: firstPath,
                    size: Int64(firstBytes.count),
                    modifiedAt: try XCTUnwrap(firstURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                )],
                sourcePath: card.path,
                destinationPath: firstDestination,
                eventID: nil,
                eventName: "Morning Event",
                deviceID: "sony-a7v"
            )
            model.enqueueTransfer(
                files: [FileRecord(
                    path: secondPath,
                    size: Int64(secondBytes.count),
                    modifiedAt: try XCTUnwrap(secondURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                )],
                sourcePath: card.path,
                destinationPath: secondDestination,
                eventID: nil,
                eventName: "Evening Event",
                deviceID: "sony-a7v"
            )

            XCTAssertEqual(model.pendingTransferBatches.map(\.eventName), ["Morning Event", "Evening Event"])
            XCTAssertEqual(model.pendingTransferFileCount, 2)
            XCTAssertEqual(try pendingStore.load().map(\.eventName), ["Morning Event", "Evening Event"])

            model.isBusy = false
            model.resumePendingTransfers()
            try await waitForIdle(model)

            XCTAssertTrue(model.pendingTransferBatches.isEmpty)
            XCTAssertTrue(try pendingStore.load().isEmpty)
            XCTAssertEqual(
                try Data(contentsOf: URL(fileURLWithPath: firstDestination).appendingPathComponent(firstPath)),
                firstBytes
            )
            XCTAssertEqual(
                try Data(contentsOf: URL(fileURLWithPath: secondDestination).appendingPathComponent(secondPath)),
                secondBytes
            )
            XCTAssertEqual(model.transferQueue?.items.map(\.relativePath), [secondPath])
            XCTAssertEqual(model.transferQueue?.state, .completed)
        }
    }

    func testRelaunchMarksAnUnfinishedPersistentTransferAsInterrupted() throws {
        try withTemporaryDirectory { root in
            let queueStore = TransferQueueStore(url: root.appendingPathComponent("transfer-queue.json"))
            try queueStore.save(TransferQueueSnapshot(
                sourcePath: root.appendingPathComponent("Card").path,
                destinationPath: root.appendingPathComponent("Buffer").path,
                items: [
                    TransferQueueItem(
                        relativePath: "DCIM/large.OSV",
                        size: 1_000,
                        copiedBytes: 400,
                        state: .copying
                    )
                ],
                progress: 0.4,
                processedBytes: 400,
                totalBytes: 1_000,
                bytesPerSecond: 100,
                phase: "Copying"
            ))

            let model = DashboardModel(
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: root.appendingPathComponent("Safety Test").path,
                    importSourcePath: root.appendingPathComponent("Card").path,
                    archivePath: root.appendingPathComponent("Library").path,
                    bufferPath: root.appendingPathComponent("Buffer").path,
                    activityLogPath: root.appendingPathComponent("activity.jsonl").path
                ),
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json")),
                transferQueueStore: queueStore
            )

            XCTAssertEqual(model.transferQueue?.state, .failed)
            XCTAssertEqual(model.transferQueue?.items.first?.state, .failed)
            XCTAssertEqual(model.transferQueue?.processedBytes, 400)
            XCTAssertEqual(model.transferQueue?.phaseProcessedBytes, 400)
            XCTAssertEqual(model.transferQueue?.phaseTotalBytes, 1_000)
            XCTAssertEqual(model.transferQueue?.progress ?? -1, 0.4, accuracy: 0.001)
            XCTAssertTrue(try XCTUnwrap(model.transferQueue?.message).contains("closed before this transfer finished"))
            XCTAssertEqual(try queueStore.load()?.state, .failed)
        }
    }

    func testVerifiedTransferCanSafelyFreeItsExplicitCameraFiles() async throws {
        try await withTemporaryDirectoryAsync { root in
            let source = root.appendingPathComponent("Camera", isDirectory: true)
            let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
            let relativePath = "DCIM/verified.OSV"
            let bytes = Data("checksum-matched-video".utf8)
            try writeFile(source.appendingPathComponent(relativePath), bytes)
            try writeFile(buffer.appendingPathComponent(relativePath), bytes)
            let queueStore = TransferQueueStore(url: root.appendingPathComponent("transfer-queue.json"))
            let model = DashboardModel(
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: root.appendingPathComponent("Safety Test").path,
                    importSourcePath: source.path,
                    archivePath: root.appendingPathComponent("Library").path,
                    bufferPath: buffer.path,
                    activityLogPath: root.appendingPathComponent("activity.jsonl").path
                ),
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json")),
                transferQueueStore: queueStore
            )
            let queue = TransferQueueSnapshot(
                state: .completed,
                sourcePath: source.path,
                destinationPath: buffer.path,
                items: [
                    TransferQueueItem(
                        relativePath: relativePath,
                        size: Int64(bytes.count),
                        copiedBytes: Int64(bytes.count),
                        state: .verified
                    )
                ],
                progress: 1,
                processedBytes: Int64(bytes.count),
                totalBytes: Int64(bytes.count),
                phase: "Transfer complete"
            )
            model.transferQueue = queue

            model.removeVerifiedSourceFiles(
                queueID: queue.id,
                confirmation: SourceCleanupService.confirmationToken
            )
            try await waitForIdle(model)

            XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent(relativePath).path))
            XCTAssertEqual(try Data(contentsOf: buffer.appendingPathComponent(relativePath)), bytes)
            XCTAssertEqual(model.transferQueue?.items.first?.state, .sourceRemoved)
            XCTAssertEqual(model.transferQueue?.sourceRemovedCount, 1)
            XCTAssertTrue(model.sourceCleanupMessage?.contains("Buffer copies remain verified") == true)
            XCTAssertEqual(try queueStore.load()?.items.first?.state, .sourceRemoved)
        }
    }

    /// Config writes are debounced, so a burst of mutations lands as one
    /// write; `flushConfigurationSave` (termination) persists synchronously.
    func testConfigurationMutationsPersistAfterDebounceAndFlush() async throws {
        try await withTemporaryDirectoryAsync { root in
            let store = ConfigurationStore(url: root.appendingPathComponent("config.json"))
            let defaults = AppConfiguration.defaults(applicationSupport: root)
            let model = DashboardModel(
                jobs: [],
                configuration: defaults,
                configurationStore: store,
                transferQueueStore: TransferQueueStore(url: root.appendingPathComponent("transfer-queue.json")),
                pendingTransferQueueStore: PendingTransferQueueStore(url: root.appendingPathComponent("pending-transfers.json"))
            )

            model.updateConfiguration { $0.selectedDeviceID = "sony-a7v" }
            model.updateConfiguration { $0.selectedDeviceID = "dji-nano" }
            model.flushConfigurationSave()
            XCTAssertEqual(try store.load(defaults: defaults).selectedDeviceID, "dji-nano")

            model.updateConfiguration { $0.selectedDeviceID = "fuji-x100vi" }
            var persisted = ""
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, persisted != "fuji-x100vi" {
                try await Task.sleep(for: .milliseconds(50))
                persisted = (try? store.load(defaults: defaults).selectedDeviceID) ?? ""
            }
            XCTAssertEqual(persisted, "fuji-x100vi")
        }
    }

    /// "Refreshing latest app state" must not decode the configuration JSON
    /// on the main actor — for a library with ~14,000 assignments that decode
    /// is the freeze the owner saw behind the event grid. The loader parks
    /// mid-refresh; the main actor (this test) keeps running the whole time,
    /// and the parked load is recorded off-main at utility priority. A
    /// mutation that lands while the disk pass is in flight is newer than
    /// what was read and must survive the apply.
    func testRefreshAllDecodesConfigurationOffTheMainActor() async throws {
        try await withTemporaryDirectoryAsync { root in
            let store = ConfigurationStore(url: root.appendingPathComponent("config.json"))
            var configuration = AppConfiguration(
                demoRootPath: root.appendingPathComponent("Safety Test").path,
                importSourcePath: root.appendingPathComponent("Card").path,
                archivePath: root.appendingPathComponent("Library/Originals").path,
                bufferPath: root.appendingPathComponent("Buffer").path,
                activityLogPath: root.appendingPathComponent("activity.jsonl").path,
                selectedDeviceID: "sony-a7v"
            )
            configuration.eventName = "Before Refresh"
            let model = DashboardModel(
                jobs: [],
                configuration: configuration,
                configurationStore: store
            )
            var onDisk = configuration
            onDisk.eventName = "From Disk"
            try store.save(onDisk)

            let box = RefreshLoadProbeBox()
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            model.configurationLoader = { url, defaults in
                box.mark()
                _ = gate.wait(timeout: .now() + 30)
                return try ConfigurationStore(url: url).load(defaults: defaults)
            }

            model.refreshAll()
            XCTAssertTrue(model.isRefreshing)
            // Parked inside the decode: the refresh is still open and the
            // main actor was never stuck inside it.
            try await waitForCondition { box.started }
            XCTAssertTrue(model.isRefreshing)

            gate.signal()
            try await waitForCondition { !model.isRefreshing }

            XCTAssertFalse(box.onMainThread)
            XCTAssertEqual(box.priority, .utility)
            XCTAssertEqual(model.configuration.eventName, "From Disk")
            XCTAssertTrue(model.statusMessage.contains("Refreshed latest"))
        }
    }

    /// While the disk pass is in flight, a local mutation is newer than
    /// what was read — the refresh must not roll it back.
    func testRefreshAllKeepsMutationMadeDuringInFlightReload() async throws {
        try await withTemporaryDirectoryAsync { root in
            let store = ConfigurationStore(url: root.appendingPathComponent("config.json"))
            let configuration = AppConfiguration(
                demoRootPath: root.appendingPathComponent("Safety Test").path,
                importSourcePath: root.appendingPathComponent("Card").path,
                archivePath: root.appendingPathComponent("Library/Originals").path,
                bufferPath: root.appendingPathComponent("Buffer").path,
                activityLogPath: root.appendingPathComponent("activity.jsonl").path,
                selectedDeviceID: "sony-a7v"
            )
            let model = DashboardModel(
                jobs: [],
                configuration: configuration,
                configurationStore: store
            )
            var onDisk = configuration
            onDisk.eventName = "Stale On Disk"
            try store.save(onDisk)

            let box = RefreshLoadProbeBox()
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            model.configurationLoader = { url, defaults in
                box.mark()
                _ = gate.wait(timeout: .now() + 30)
                return try ConfigurationStore(url: url).load(defaults: defaults)
            }

            model.refreshAll()
            try await waitForCondition { box.started }
            // Newer than the parked read — wins over the disk result.
            model.updateConfiguration { $0.eventName = "Typed Meanwhile" }
            gate.signal()
            try await waitForCondition { !model.isRefreshing }

            XCTAssertEqual(model.configuration.eventName, "Typed Meanwhile")
        }
    }

    /// The apply board correlates its in-flight route diagram with the rename
    /// job through the id `runBackgroundJob` hands back.
    func testRunBackgroundJobReturnsIDAndRefusesWhileBusy() async throws {
        try await withTemporaryDirectoryAsync { root in
            let model = DashboardModel(
                jobs: [],
                configuration: AppConfiguration.defaults(applicationSupport: root),
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
            )

            let jobID = model.runBackgroundJob(
                action: .organize,
                runningNote: "Working",
                logTitle: "Job",
                logDetail: "",
                operation: { _ in 42 },
                completion: { _ in "Done" }
            )
            XCTAssertNotNil(jobID)
            XCTAssertEqual(model.jobs.first?.id, jobID)
            XCTAssertEqual(model.jobs.first?.state, .running)

            let refused = model.runBackgroundJob(
                action: .organize,
                runningNote: "Working",
                logTitle: "Job",
                logDetail: "",
                operation: { _ in 42 },
                completion: { _ in "Done" }
            )
            XCTAssertNil(refused)

            try await waitForIdle(model)
            XCTAssertEqual(model.jobs.first?.state, .done)
        }
    }

    /// Every file job holds a `ProcessInfo` activity assertion for exactly
    /// its busy window — App Nap and idle sleep cannot stall a copy or a
    /// scan, and nothing leaks once the job settles.
    func testBackgroundJobHoldsActivityAssertionWhileRunning() async throws {
        try await withTemporaryDirectoryAsync { root in
            let model = DashboardModel(
                jobs: [],
                configuration: AppConfiguration.defaults(applicationSupport: root),
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
            )
            let started = DispatchSemaphore(value: 0)
            let finish = DispatchSemaphore(value: 0)

            let jobID = model.runBackgroundJob(
                action: .organize,
                runningNote: "Working",
                logTitle: "Job",
                logDetail: "",
                operation: { _ in
                    started.signal()
                    finish.wait()
                    return 42
                },
                completion: { _ in "Done" }
            )
            XCTAssertNotNil(jobID)
            XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(model.jobActivityAssertions[jobID!] != nil, true)

            finish.signal()
            try await waitForIdle(model)
            XCTAssertTrue(model.jobActivityAssertions.isEmpty)
        }
    }

    /// The catalog-state revision moves only when events, assignments,
    /// rotations, or burst splits move: a mutation that changes nothing is
    /// not a change at all, and a settings write leaves the
    /// assignment-derived indexes alone.
    func testRevisionCountersSplitSettingsFromCatalogState() async throws {
        try await withTemporaryDirectoryAsync { root in
            let model = DashboardModel(
                jobs: [],
                configuration: AppConfiguration.defaults(applicationSupport: root),
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
            )
            let configRev = model.configurationRevision
            let catalogRev = model.catalogStateRevision

            // A no-op mutation is not a change — nothing to save or reload.
            model.updateConfiguration { _ in }
            XCTAssertEqual(model.configurationRevision, configRev)
            XCTAssertEqual(model.catalogStateRevision, catalogRev)

            // A settings write moves the settings revision only.
            model.updateConfiguration { $0.selectedDeviceID = "sony-a7v" }
            XCTAssertEqual(model.configurationRevision, configRev + 1)
            XCTAssertEqual(model.catalogStateRevision, catalogRev)

            // Catalog-owned state moves both.
            model.updateConfiguration { configuration in
                configuration.photoEventAssignments.append(PhotoEventAssignment(
                    sourceRootPath: "/Volumes/Card/DCIM",
                    relativePath: "DSC00001.ARW",
                    fileSize: 4_096,
                    modifiedAt: Date(),
                    eventID: UUID(),
                    deviceID: "sony-a7v"
                ))
            }
            XCTAssertEqual(model.configurationRevision, configRev + 2)
            XCTAssertEqual(model.catalogStateRevision, catalogRev + 1)
        }
    }

    /// A stale activation check must not pay for a reload when the config
    /// file is byte-for-byte what this process last read or wrote — and
    /// must still reload when something else did touch it.
    func testActivationReloadsOnlyWhenTheConfigFileMoved() async throws {
        try await withTemporaryDirectoryAsync { root in
            let store = ConfigurationStore(url: root.appendingPathComponent("config.json"))
            let model = DashboardModel(
                jobs: [],
                configuration: AppConfiguration.defaults(applicationSupport: root),
                configurationStore: store
            )
            let loadCounter = LoadCounterBox()
            model.configurationLoader = { url, defaults in
                loadCounter.mark()
                return try ConfigurationStore(url: url).load(defaults: defaults)
            }

            // Persist through the model so its recorded stamp matches the
            // file exactly.
            model.updateConfiguration { $0.selectedDeviceID = "sony-a7v" }
            model.flushConfigurationSave()
            model.lastRefreshedAt = Date.distantPast
            model.refreshAllIfStale(maxAge: 0)
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(loadCounter.loads, 0)
            XCTAssertFalse(model.isRefreshing)

            // An outside writer moves the file — the next check reloads.
            var onDisk = try store.load(defaults: AppConfiguration.defaults(applicationSupport: root))
            onDisk.selectedDeviceID = "dji-nano"
            try store.save(onDisk)
            model.lastRefreshedAt = Date.distantPast
            model.refreshAllIfStale(maxAge: 0)
            try await waitForCondition { loadCounter.loads == 1 }
        }
    }
}

/// How many times the injected configuration loader ran — counted off
/// the main actor, where the refresh's disk pass executes it.
private final class LoadCounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _loads = 0
    var loads: Int { lock.withLock { _loads } }
    func mark() { lock.withLock { _loads += 1 } }
}

@discardableResult
private func writeFile(_ url: URL, _ data: Data) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
}

private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CameraToolkitAppTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(root)
}

@MainActor
private func withTemporaryDirectoryAsync<T: Sendable>(
    _ body: @MainActor (URL) async throws -> T
) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CameraToolkitAppTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

private enum DashboardModelTestError: Error {
    case timedOutWaitingForJob
}

/// What the injected configuration loader observed inside the refresh's
/// disk pass: where it ran and at what priority.
private final class RefreshLoadProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _onMainThread = true
    private var _priority: TaskPriority?

    var started: Bool { lock.withLock { _started } }
    var onMainThread: Bool { lock.withLock { _onMainThread } }
    var priority: TaskPriority? { lock.withLock { _priority } }

    func mark() {
        lock.withLock {
            _started = true
            _onMainThread = Thread.isMainThread
            _priority = Task<Never, Never>.currentPriority
        }
    }
}

@MainActor
private func waitForCondition(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for condition")
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor
private func waitForIdle(_ model: DashboardModel, timeout: TimeInterval = 3) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while model.isBusy {
        if Date() > deadline {
            throw DashboardModelTestError.timedOutWaitingForJob
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}
