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
