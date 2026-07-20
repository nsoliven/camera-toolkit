import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

@MainActor
final class StorageBenchmarkModelTests: XCTestCase {
    func testCurrentTransferSourceWinsOverTheFirstConfiguredCamera() {
        let lexar = target(id: "lexar", root: "/Volumes/LEXAR")
        let osmo = target(id: "osmo", root: "/Volumes/Osmo360")
        let queue = TransferQueueSnapshot(
            sourcePath: "/Volumes/Osmo360/DCIM/CAM_001",
            destinationPath: "/Volumes/Buffer/Card Copy",
            items: [],
            totalBytes: 0
        )

        let selected = StorageBenchmarkTargetDiscovery.currentSourceTarget(
            in: [lexar, osmo],
            transferQueue: queue
        )

        XCTAssertEqual(selected?.id, "osmo")
    }

    func testSafetySimulationSourceIsNotPresentedAsAPhysicalDrive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitBenchmarkTargets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let demo = root.appendingPathComponent("Safety Test", isDirectory: true)
        let source = demo.appendingPathComponent("Source Card", isDirectory: true)
        let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)

        let configuration = AppConfiguration(
            demoRootPath: demo.path,
            importSourcePath: source.path,
            archivePath: root.appendingPathComponent("Library").path,
            bufferPath: buffer.path,
            configuredLocations: [
                ConfiguredLocation(role: .importSource, name: "Safety Test Card", path: source.path),
                ConfiguredLocation(role: .buffer, name: "Buffer", path: buffer.path)
            ],
            activityLogPath: root.appendingPathComponent("activity.jsonl").path
        )

        let targets = StorageBenchmarkTargetDiscovery.discover(
            configuration: configuration,
            transferQueue: nil
        )

        XCTAssertFalse(targets.contains { $0.roleNames.contains("Camera Source") })
        XCTAssertTrue(targets.contains { $0.roleNames.contains("Buffer") })
    }

    private func target(id: String, root: String) -> StorageBenchmarkTarget {
        let url = URL(fileURLWithPath: root, isDirectory: true)
        return StorageBenchmarkTarget(
            id: id,
            name: id,
            volumeRoot: url,
            searchRoots: [url],
            writeDirectory: nil,
            roleNames: ["Camera Source"],
            access: .readOnly,
            isAvailable: true,
            totalCapacity: nil
        )
    }
}
