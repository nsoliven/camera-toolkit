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
            try writeFile(buffer.appendingPathComponent("Test Batch/sony-a7v/Configured Source/Originals").appendingPathComponent(relativePath), bytes)

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
                    importDestination: .nas
                ),
                safetyChecks: [],
                configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
            )

            model.copySourceToBuffer()
            try await waitForIdle(model)

            let bufferedFile = buffer
                .appendingPathComponent("Test Batch/sony-a7v/Card/Originals")
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

            let bufferRoot = buffer.appendingPathComponent("Test Batch/sony-a7v/Card/Originals")
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

            XCTAssertEqual(model.configuration.importSourcePath, "/Volumes/CAMERA_CARD/TEMP")
            XCTAssertEqual(model.configuration.bufferPath, "/Volumes/PHOTO_WORKSPACE/Photos")
            XCTAssertEqual(model.configuration.selectedDeviceID, "sony-a7v")
            XCTAssertEqual(model.configuration.importDestination, .drive)
            XCTAssertTrue(model.activePlan.isEmpty)
            XCTAssertTrue(model.queuedFilePaths.isEmpty)
            XCTAssertTrue(model.statusMessage.contains("No files were moved"))

            let saved = try store.load(defaults: .defaults(applicationSupport: root))
            XCTAssertEqual(saved.importSourcePath, "/Volumes/CAMERA_CARD/TEMP")
            XCTAssertEqual(saved.bufferPath, "/Volumes/PHOTO_WORKSPACE/Photos")
        }
    }

    func testHardwarePresetsExplainEveryKnownStorageRole() throws {
        let presets = CameraSetupPreset.defaults

        XCTAssertEqual(Set(presets.map(\.id)), [
            "lexar-sony-buffer",
            "osmo-360-buffer",
            "crucial-buffer",
            "home-photo-library"
        ])
        XCTAssertTrue(presets.allSatisfy { !$0.effect.isEmpty && !$0.requiredPaths.isEmpty })
        XCTAssertEqual(
            presets.first { $0.id == "osmo-360-buffer" }?.sourcePath,
            "/Volumes/ACTION_CAMERA/DCIM/CAM_001"
        )
        XCTAssertEqual(
            presets.first { $0.id == "home-photo-library" }?.libraryRootPath,
            "/Volumes/PHOTO_LIBRARY"
        )
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
