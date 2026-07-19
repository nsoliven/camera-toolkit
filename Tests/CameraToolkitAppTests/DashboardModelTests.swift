import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

@MainActor
final class DashboardModelTests: XCTestCase {
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
                locations: [],
                activePlan: CopyPlan(),
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: testDataRoot.path,
                    importSourcePath: source.path,
                    archivePath: archive.path,
                    bufferPath: buffer.path,
                    activityLogPath: root.appendingPathComponent("activity-log.jsonl").path,
                    immichServerURL: "",
                    editorWorkingFolderPath: root.appendingPathComponent("Working Copies", isDirectory: true).path,
                    externalEditor: .preview,
                    rcloneBinaryPath: "rclone",
                    exiftoolBinaryPath: "exiftool",
                    selectedDeviceID: "sony-a7v",
                    eventName: "Test Batch",
                    batchID: "2026-07-10_120000_sony-a7v_test",
                    importDestination: .nas
                ),
                safetyChecks: [],
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
                locations: [],
                activePlan: CopyPlan(),
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: testDataRoot.path,
                    importSourcePath: source.path,
                    archivePath: archive.path,
                    bufferPath: buffer.path,
                    activityLogPath: root.appendingPathComponent("activity-log.jsonl").path,
                    immichServerURL: "",
                    editorWorkingFolderPath: root.appendingPathComponent("Working Copies", isDirectory: true).path,
                    externalEditor: .preview,
                    rcloneBinaryPath: "rclone",
                    exiftoolBinaryPath: "exiftool",
                    selectedDeviceID: "sony-a7v",
                    eventName: "Test Batch",
                    batchID: "2026-07-10_120000_sony-a7v_test",
                    importDestination: .nas
                ),
                safetyChecks: [],
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

    func testCopyQueuedFilesToBufferCopiesOnlyQueuedFiles() async throws {
        try await withTemporaryDirectoryAsync { root in
            let source = root.appendingPathComponent("Card", isDirectory: true)
            let archive = root.appendingPathComponent("Archive", isDirectory: true)
            let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
            let testDataRoot = root.appendingPathComponent("Safety Test", isDirectory: true)
            let queuedPath = "DCIM/100MSDCF/QUEUED.ARW"
            let unqueuedPath = "DCIM/100MSDCF/UNQUEUED.ARW"
            try writeFile(source.appendingPathComponent(queuedPath), Data("queued".utf8))
            try writeFile(source.appendingPathComponent(unqueuedPath), Data("not-yet".utf8))

            let model = DashboardModel(
                locations: [],
                activePlan: CopyPlan(),
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: testDataRoot.path,
                    importSourcePath: source.path,
                    archivePath: archive.path,
                    bufferPath: buffer.path,
                    activityLogPath: root.appendingPathComponent("activity-log.jsonl").path,
                    immichServerURL: "",
                    editorWorkingFolderPath: root.appendingPathComponent("Working Copies", isDirectory: true).path,
                    externalEditor: .preview,
                    rcloneBinaryPath: "rclone",
                    exiftoolBinaryPath: "exiftool",
                    selectedDeviceID: "sony-a7v",
                    eventName: "Test Batch",
                    batchID: "2026-07-10_120000_sony-a7v_test",
                    importDestination: .nas
                ),
                safetyChecks: [],
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
            )

            model.previewImport()
            try await waitForIdle(model)
            XCTAssertEqual(Set(model.queuedFiles.map(\.path)), [queuedPath, unqueuedPath])

            let unqueued = try XCTUnwrap(model.activePlan.new.first { $0.path == unqueuedPath })
            model.toggleQueuedFile(unqueued)

            model.copyQueuedFilesToBuffer()
            try await waitForIdle(model)

            let bufferRoot = buffer.appendingPathComponent("2026/2026-07-10 Test Batch/Sony A7V/Card Copy")
            XCTAssertTrue(FileManager.default.fileExists(atPath: bufferRoot.appendingPathComponent(queuedPath).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: bufferRoot.appendingPathComponent(unqueuedPath).path))
            XCTAssertTrue(model.queuedFiles.isEmpty)
        }
    }

    func testPlanFileSourceURLRequiresExistingSafeRelativePath() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("Configured Source", isDirectory: true)
            let archive = root.appendingPathComponent("Configured Archive", isDirectory: true)
            let testDataRoot = root.appendingPathComponent("Safety Test", isDirectory: true)
            let relativePath = "DCIM/100MSDCF/DSC00001.ARW"
            try writeFile(source.appendingPathComponent(relativePath), Data("photo".utf8))

            let model = DashboardModel(
                locations: [],
                activePlan: CopyPlan(),
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: testDataRoot.path,
                    importSourcePath: source.path,
                    archivePath: archive.path,
                    bufferPath: root.appendingPathComponent("Configured Buffer", isDirectory: true).path,
                    activityLogPath: root.appendingPathComponent("activity-log.jsonl").path,
                    immichServerURL: "",
                    editorWorkingFolderPath: root.appendingPathComponent("Working Copies", isDirectory: true).path,
                    externalEditor: .preview,
                    rcloneBinaryPath: "rclone",
                    exiftoolBinaryPath: "exiftool",
                    selectedDeviceID: "sony-a7v",
                    eventName: "Test Batch",
                    importDestination: .nas
                ),
                safetyChecks: [],
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
            )

            XCTAssertEqual(
                model.planFileSourceURL(FileRecord(path: relativePath, size: 5, modifiedAt: .now))?.path,
                source.appendingPathComponent(relativePath).path
            )
            XCTAssertNil(model.planFileSourceURL(FileRecord(path: "../secret.ARW", size: 5, modifiedAt: .now)))
            XCTAssertNil(model.planFileSourceURL(FileRecord(path: "missing.ARW", size: 5, modifiedAt: .now)))
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
                locations: [],
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
                safetyChecks: [],
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

    func testCamera CardPresetSelectsSafePhotoFolderAndCrucialBufferWithoutMovingFiles() throws {
        try withTemporaryDirectory { root in
            let configURL = root.appendingPathComponent("config.json")
            let store = ConfigurationStore(url: configURL)
            let model = DashboardModel(
                locations: [],
                activePlan: CopyPlan(new: [FileRecord(path: "old.ARW", size: 3, modifiedAt: .now)]),
                jobs: [],
                configuration: .defaults(applicationSupport: root),
                safetyChecks: [],
                configurationStore: store
            )
            model.queuedFilePaths = ["old.ARW"]

            let preset = try XCTUnwrap(CameraSetupPreset.defaults.first { $0.id == "lexar-sony-buffer" })
            model.applySetupPreset(preset)

            XCTAssertEqual(model.configuration.importSourcePath, "/Volumes/CAMERA_CARD")
            XCTAssertEqual(model.configuration.bufferPath, "/Volumes/PHOTO_WORKSPACE/Camera Buffer")
            XCTAssertEqual(model.configuration.selectedDeviceID, "sony-a7v")
            XCTAssertEqual(model.configuration.importDestination, .drive)
            XCTAssertTrue(model.activePlan.isEmpty)
            XCTAssertTrue(model.queuedFilePaths.isEmpty)
            XCTAssertTrue(model.statusMessage.contains("No files were moved"))

            let saved = try store.load(defaults: .defaults(applicationSupport: root))
            XCTAssertEqual(saved.importSourcePath, "/Volumes/CAMERA_CARD")
            XCTAssertEqual(saved.bufferPath, "/Volumes/PHOTO_WORKSPACE/Camera Buffer")
        }
    }

    func testIngestPresetsMatchTheEstablishedCardAndBufferContract() throws {
        let presets = CameraSetupPreset.defaults

        XCTAssertEqual(Set(presets.map(\.id)), [
            "lexar-sony-buffer",
            "osmo-360-buffer"
        ])
        XCTAssertTrue(presets.allSatisfy { !$0.effect.isEmpty && !$0.requiredPaths.isEmpty })
        XCTAssertEqual(
            presets.first { $0.id == "osmo-360-buffer" }?.sourcePath,
            "/Volumes/ACTION_CAMERA"
        )
        XCTAssertEqual(
            presets.first { $0.id == "lexar-sony-buffer" }?.bufferPath,
            "/Volumes/PHOTO_WORKSPACE/Camera Buffer"
        )
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
                locations: [],
                activePlan: CopyPlan(),
                jobs: [],
                configuration: configuration,
                safetyChecks: [],
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

    func testEventSelectionCanSpanMultipleSourceRootsWithoutMisattribution() throws {
        try withTemporaryDirectory { root in
            let firstCard = root.appendingPathComponent("Camera Card", isDirectory: true)
            let secondCard = root.appendingPathComponent("OSMO", isDirectory: true)
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
                locations: [],
                activePlan: CopyPlan(),
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: root.appendingPathComponent("Safety Test").path,
                    importSourcePath: firstCard.path,
                    archivePath: root.appendingPathComponent("Archive").path,
                    bufferPath: root.appendingPathComponent("Buffer").path,
                    activityLogPath: root.appendingPathComponent("activity.jsonl").path
                ),
                safetyChecks: [],
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

    func testTwoButtonImportCopiesToCrucialThenOrganizesVerifiedNASOriginals() async throws {
        try await withTemporaryDirectoryAsync { root in
            let card = root.appendingPathComponent("Camera Card", isDirectory: true)
            let crucial = root.appendingPathComponent("Photo Workspace", isDirectory: true)
            let library = root.appendingPathComponent("NAS/Camera", isDirectory: true)
            try writeFile(card.appendingPathComponent("DCIM/100MSDCF/PHOTO.ARW"), Data("raw-photo".utf8))
            try writeFile(card.appendingPathComponent("M4ROOT/CLIP/VIDEO.MP4"), Data("video".utf8))
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

            let configuration = AppConfiguration(
                demoRootPath: root.appendingPathComponent("Safety Test").path,
                importSourcePath: card.path,
                archivePath: library.appendingPathComponent("Originals").path,
                bufferPath: crucial.path,
                cameraLibraryRootPath: library.path,
                activityLogPath: root.appendingPathComponent("activity.jsonl").path,
                selectedDeviceID: "sony-a7v",
                eventName: "Lee Canyon",
                batchID: "2026-07-11_120000_sony-a7v_test"
            )
            let model = DashboardModel(
                locations: [],
                activePlan: CopyPlan(),
                jobs: [],
                configuration: configuration,
                safetyChecks: [],
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
            XCTAssertTrue(model.statusMessage.contains("NAS archive verified"))
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
private func withTemporaryDirectoryAsync<T>(_ body: (URL) async throws -> T) async throws -> T {
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
