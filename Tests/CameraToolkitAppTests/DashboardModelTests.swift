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
    }

    func testStartupMatchesCameraToAlreadySelectedSource() throws {
        try withTemporaryDirectory { root in
            let source = ConfiguredLocation(
                role: .importSource,
                name: "Osmo360 · DJI Osmo 360",
                path: root.appendingPathComponent("Osmo360").path
            )
            let configuration = AppConfiguration(
                demoRootPath: root.appendingPathComponent("Safety Test").path,
                importSourcePath: source.path,
                archivePath: root.appendingPathComponent("Library/Originals").path,
                bufferPath: root.appendingPathComponent("Buffer").path,
                configuredLocations: [source],
                selectedImportSourceID: source.id,
                activityLogPath: root.appendingPathComponent("activity.jsonl").path,
                selectedDeviceID: "sony-a7v"
            )
            let model = DashboardModel(
                activePlan: CopyPlan(),
                jobs: [],
                configuration: configuration,
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
            )

            model.matchCameraToSelectedImportSource()

            XCTAssertEqual(model.configuration.selectedDeviceID, "osmo-360")
            XCTAssertTrue(model.statusMessage.contains("DJI Osmo 360"))
        }
    }

    func testPreviewImportUsesBufferBatchInsteadOfArchiveOrTestData() async throws {
        try await withTemporaryDirectoryAsync { root in
            let source = root.appendingPathComponent("Configured Source", isDirectory: true)
            let archive = root.appendingPathComponent("Configured Archive", isDirectory: true)
            let buffer = root.appendingPathComponent("Configured Buffer", isDirectory: true)
            let testDataRoot = root.appendingPathComponent("Safety Test", isDirectory: true)
            let relativePath = "DCIM/100MSDCF/DSC00001.ARW"
            let bytes = Data("same-photo-bytes".utf8)
            try writeFile(source.appendingPathComponent(relativePath), bytes)
            try writeFile(buffer.appendingPathComponent("2026/2026-07-10 Test Batch/Sony A7V/Card Copy").appendingPathComponent(relativePath), bytes)

            let model = DashboardModel(
                activePlan: CopyPlan(),
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: testDataRoot.path,
                    importSourcePath: source.path,
                    archivePath: archive.path,
                    bufferPath: buffer.path,
                    activityLogPath: root.appendingPathComponent("activity-log.jsonl").path,
                    immichServerURL: "",
                    selectedDeviceID: "sony-a7v",
                    eventName: "Test Batch",
                    batchID: "2026-07-10_120000_sony-a7v_test"
                ),
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
            )

            model.previewImport()
            try await waitForIdle(model)

            XCTAssertEqual(model.activePlan.existing.map(\.path), [relativePath])
            XCTAssertTrue(model.activePlan.new.isEmpty)
            XCTAssertTrue(model.activePlan.conflicts.isEmpty)
            XCTAssertEqual(model.jobs.first?.action, .previewFiles)
        }
    }

    func testCopySourceToBufferCopiesOnlyIntoBufferBatch() async throws {
        try await withTemporaryDirectoryAsync { root in
            let source = root.appendingPathComponent("Card", isDirectory: true)
            let archive = root.appendingPathComponent("Archive", isDirectory: true)
            let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
            let testDataRoot = root.appendingPathComponent("Safety Test", isDirectory: true)
            let relativePath = "DCIM/100MSDCF/DSC00001.ARW"
            let bytes = Data("photo".utf8)
            try writeFile(source.appendingPathComponent(relativePath), bytes)

            let model = DashboardModel(
                activePlan: CopyPlan(),
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: testDataRoot.path,
                    importSourcePath: source.path,
                    archivePath: archive.path,
                    bufferPath: buffer.path,
                    activityLogPath: root.appendingPathComponent("activity-log.jsonl").path,
                    immichServerURL: "",
                    selectedDeviceID: "sony-a7v",
                    eventName: "Test Batch",
                    batchID: "2026-07-10_120000_sony-a7v_test"
                ),
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
            )

            model.copySourceToBuffer()
            try await waitForIdle(model)

            let bufferedFile = buffer
                .appendingPathComponent("2026/2026-07-10 Test Batch/Sony A7V/Card Copy")
                .appendingPathComponent(relativePath)
            XCTAssertEqual(try Data(contentsOf: bufferedFile), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: archive.appendingPathComponent(relativePath).path))
            XCTAssertEqual(model.activePlan.existing.map(\.path), [relativePath])
        }
    }

    func testPreviewImportUsesSourceOnlyForCatalogBackedLibrary() async throws {
        try await withTemporaryDirectoryAsync { root in
            let source = root.appendingPathComponent("Card", isDirectory: true)
            let libraryRoot = root.appendingPathComponent("Camera", isDirectory: true)
            let catalog = root.appendingPathComponent("catalog.sqlite")
            let testDataRoot = root.appendingPathComponent("Safety Test", isDirectory: true)
            let relativePath = "DCIM/100MSDCF/DSC00001.ARW"
            try writeFile(source.appendingPathComponent(relativePath), Data("photo".utf8))
            try writeFile(catalog, Data())

            let model = DashboardModel(
                activePlan: CopyPlan(),
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: testDataRoot.path,
                    importSourcePath: source.path,
                    archivePath: libraryRoot.appendingPathComponent("Originals", isDirectory: true).path,
                    bufferPath: root.appendingPathComponent("Buffer", isDirectory: true).path,
                    cameraLibraryRootPath: libraryRoot.path,
                    catalogDatabasePath: catalog.path,
                    activityLogPath: root.appendingPathComponent("activity-log.jsonl").path
                ),
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
            )

            model.previewImport()
            try await waitForIdle(model)

            XCTAssertEqual(model.activePlan.new.map(\.path), [relativePath])
            XCTAssertTrue(model.activePlan.existing.isEmpty)
            XCTAssertTrue(model.activePlan.conflicts.isEmpty)
            XCTAssertTrue(model.statusMessage.contains("Preview ready"))
        }
    }

    func testSavedEventCopiesOnlyAssignedCardFilesAndCreatesEditingFolders() async throws {
        try await withTemporaryDirectoryAsync { root in
            let card = root.appendingPathComponent("Camera Card", isDirectory: true)
            let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
            let library = root.appendingPathComponent("Library", isDirectory: true)
            let includedPath = "DCIM/100MSDCF/INCLUDED.ARW"
            let otherPath = "DCIM/100MSDCF/OTHER-EVENT.ARW"
            try writeFile(card.appendingPathComponent(includedPath), Data("included-event".utf8))
            try writeFile(card.appendingPathComponent(otherPath), Data("different-event".utf8))
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

            let configuration = AppConfiguration(
                demoRootPath: root.appendingPathComponent("Safety Test").path,
                importSourcePath: card.path,
                archivePath: library.appendingPathComponent("Originals").path,
                bufferPath: buffer.path,
                cameraLibraryRootPath: library.path,
                activityLogPath: root.appendingPathComponent("activity.jsonl").path,
                selectedDeviceID: "sony-a7v"
            )
            let model = DashboardModel(
                activePlan: CopyPlan(),
                jobs: [],
                configuration: configuration,
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
            )
            let eventDate = try XCTUnwrap(
                Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 19, hour: 12))
            )

            model.createEvent(named: "Portrait Session", on: eventDate)
            model.assignFilesToSelectedEvent([
                FileRecord(path: includedPath, size: 14, modifiedAt: try XCTUnwrap(
                    card.appendingPathComponent(includedPath).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                ))
            ])

            XCTAssertEqual(model.selectedEventFiles.map(\.path), [includedPath])
            XCTAssertTrue(FileManager.default.fileExists(atPath: model.expandedBufferEditsPath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: model.configuration.bufferExportFolderPath("Masters")))

            model.previewSelectedEventImport()
            try await waitForIdle(model)
            XCTAssertEqual(model.activePlan.new.map(\.path), [includedPath])
            XCTAssertFalse(model.activePlan.new.contains { $0.path == otherPath })

            model.copyQueuedFilesToBuffer()
            try await waitForIdle(model)

            XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: model.expandedBufferIngestPath).appendingPathComponent(includedPath).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: model.expandedBufferIngestPath).appendingPathComponent(otherPath).path))
            XCTAssertTrue(model.isBufferVerifiedForArchive)
        }
    }

    func testFailedEventCopyKeepsAPersistentActionableTransferQueue() async throws {
        try await withTemporaryDirectoryAsync { root in
            let card = root.appendingPathComponent("Camera Card", isDirectory: true)
            let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
            let relativePath = "DCIM/100MSDCF/TRUNCATED.ARW"
            try writeFile(card.appendingPathComponent(relativePath), Data("short".utf8))
            let configStore = ConfigurationStore(url: root.appendingPathComponent("config.json"))
            let queueStore = TransferQueueStore(url: root.appendingPathComponent("transfer-queue.json"))
            let model = DashboardModel(
                activePlan: CopyPlan(),
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: root.appendingPathComponent("Safety Test").path,
                    importSourcePath: card.path,
                    archivePath: root.appendingPathComponent("Library/Originals").path,
                    bufferPath: buffer.path,
                    activityLogPath: root.appendingPathComponent("activity.jsonl").path,
                    selectedDeviceID: "sony-a7v"
                ),
                configurationStore: configStore,
                transferQueueStore: queueStore
            )

            model.createEvent(named: "Transfer Failure Test", on: Date())
            model.assignFilesToSelectedEvent([
                FileRecord(path: relativePath, size: 500, modifiedAt: Date())
            ])
            model.copySelectedEventFilesToBuffer()
            try await waitForIdle(model)

            let queue = try XCTUnwrap(model.transferQueue)
            XCTAssertEqual(queue.state, .failed)
            XCTAssertEqual(queue.items.first?.state, .failed)
            XCTAssertTrue(try XCTUnwrap(queue.message).contains("Camera originals were untouched"))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: model.expandedBufferIngestPath)
                    .appendingPathComponent(relativePath).path
            ))

            let restored = try XCTUnwrap(try queueStore.load())
            XCTAssertEqual(restored.state, .failed)
            XCTAssertEqual(restored.items.map(\.relativePath), [relativePath])
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
                activePlan: CopyPlan(),
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
                activePlan: CopyPlan(),
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

    func testEventSelectionCanSpanMultipleSourceRootsWithoutMisattribution() throws {
        try withTemporaryDirectory { root in
            let firstCard = root.appendingPathComponent("Camera Card A", isDirectory: true)
            let secondCard = root.appendingPathComponent("Camera Card B", isDirectory: true)
            let firstFile = FileRecord(
                path: "DCIM/100MSDCF/FIRST.ARW",
                size: 10,
                modifiedAt: Date(timeIntervalSince1970: 100)
            )
            let secondFile = FileRecord(
                path: "DCIM/200MSDCF/SECOND.DNG",
                size: 20,
                modifiedAt: Date(timeIntervalSince1970: 200)
            )
            let model = DashboardModel(
                activePlan: CopyPlan(),
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: root.appendingPathComponent("Safety Test").path,
                    importSourcePath: firstCard.path,
                    archivePath: root.appendingPathComponent("Archive").path,
                    bufferPath: root.appendingPathComponent("Buffer").path,
                    activityLogPath: root.appendingPathComponent("activity.jsonl").path
                ),
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
            )

            model.createEvent(named: "All Day Event", on: Date(timeIntervalSince1970: 300))
            model.assignFilesToSelectedEvent([
                EventFileSelection(sourceRootPath: firstCard.path, file: firstFile),
                EventFileSelection(sourceRootPath: secondCard.path, file: secondFile),
            ])

            XCTAssertEqual(model.configuration.photoEventAssignments.count, 2)
            XCTAssertEqual(
                Set(model.configuration.photoEventAssignments.map(\.sourceRootPath)),
                Set([firstCard.standardizedFileURL.path, secondCard.standardizedFileURL.path])
            )
            XCTAssertEqual(model.selectedEventFiles, [firstFile])
            XCTAssertEqual(model.queuedFilePaths, [firstFile.path])
            XCTAssertTrue(model.statusMessage.contains("2 camera sources"))
        }
    }

    func testTwoButtonImportCopiesToBufferThenOrganizesVerifiedLibraryOriginals() async throws {
        try await withTemporaryDirectoryAsync { root in
            let card = root.appendingPathComponent("Camera Card", isDirectory: true)
            let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
            let library = root.appendingPathComponent("Library", isDirectory: true)
            try writeFile(card.appendingPathComponent("DCIM/100MSDCF/PHOTO.ARW"), Data("raw-photo".utf8))
            try writeFile(card.appendingPathComponent("M4ROOT/CLIP/VIDEO.MP4"), Data("video".utf8))
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

            let configuration = AppConfiguration(
                demoRootPath: root.appendingPathComponent("Safety Test").path,
                importSourcePath: card.path,
                archivePath: library.appendingPathComponent("Originals").path,
                bufferPath: buffer.path,
                cameraLibraryRootPath: library.path,
                activityLogPath: root.appendingPathComponent("activity.jsonl").path,
                selectedDeviceID: "sony-a7v",
                eventName: "Lee Canyon",
                batchID: "2026-07-11_120000_sony-a7v_test"
            )
            let model = DashboardModel(
                activePlan: CopyPlan(),
                jobs: [],
                configuration: configuration,
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
            )

            model.copySourceToBuffer()
            try await waitForIdle(model)
            XCTAssertTrue(model.isBufferVerifiedForArchive)

            model.archiveBufferToLibrary()
            try await waitForIdle(model)

            let raw = library.appendingPathComponent("Originals/2026/2026-07-11 Lee Canyon/Sony A7V/RAW/PHOTO.ARW")
            let video = library.appendingPathComponent("Originals/2026/2026-07-11 Lee Canyon/Sony A7V/Video/VIDEO.MP4")
            XCTAssertEqual(try Data(contentsOf: raw), Data("raw-photo".utf8))
            XCTAssertEqual(try Data(contentsOf: video), Data("video".utf8))
            XCTAssertTrue(model.organizedArchivePlan.isVerified)
            XCTAssertTrue(model.statusMessage.contains("Library archive verified"))
        }
    }
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
