import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

@MainActor
final class DashboardModelTests: XCTestCase {
    func testPreviewImportUsesConfiguredArchiveInsteadOfSimulationArchive() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("Configured Source", isDirectory: true)
            let archive = root.appendingPathComponent("Configured Archive", isDirectory: true)
            let simulationRoot = root.appendingPathComponent("Simulation", isDirectory: true)
            let relativePath = "DCIM/100MSDCF/DSC00001.ARW"
            let bytes = Data("same-photo-bytes".utf8)
            try writeFile(source.appendingPathComponent(relativePath), bytes)
            try writeFile(archive.appendingPathComponent(relativePath), bytes)

            let model = DashboardModel(
                locations: [],
                activePlan: CopyPlan(),
                jobs: [],
                configuration: AppConfiguration(
                    demoRootPath: simulationRoot.path,
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

            model.previewImport()

            XCTAssertEqual(model.activePlan.existing.map(\.path), [relativePath])
            XCTAssertTrue(model.activePlan.new.isEmpty)
            XCTAssertTrue(model.activePlan.conflicts.isEmpty)
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
