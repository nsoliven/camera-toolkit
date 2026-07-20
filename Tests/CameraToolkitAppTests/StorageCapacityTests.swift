import Foundation
@testable import CameraToolkitApp
import XCTest

final class StorageCapacityTests: XCTestCase {
    func testMountedVolumeNameIdentifiesOnlyTheSpecificMountedVolume() {
        XCTAssertEqual(
            StorageCapacityReader.mountedVolumeName(for: "/Volumes/Photo NAS/library/originals"),
            "Photo NAS"
        )
        XCTAssertEqual(
            StorageCapacityReader.mountedVolumeName(for: "/Volumes/Other Disk/library"),
            "Other Disk"
        )
        XCTAssertNil(StorageCapacityReader.mountedVolumeName(for: "/tmp/example/Pictures"))
    }

    func testCapacityFractionsAreBoundedAndDescribeAvailableSpace() {
        let capacity = StorageCapacitySnapshot(availableBytes: 25, totalBytes: 100)

        XCTAssertEqual(capacity.usedFraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(capacity.availableFraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(StorageCapacitySnapshot(availableBytes: 200, totalBytes: 100).usedFraction, 0)
        XCTAssertEqual(StorageCapacitySnapshot(availableBytes: -1, totalBytes: 100).usedFraction, 1)
    }

    func testNetworkEstimateAndAuthoritativeNASCapacityStayDistinct() {
        let estimate = StorageCapacitySnapshot(
            availableBytes: 1_500,
            totalBytes: 1_500,
            source: .networkShareEstimate
        )
        let authoritative = StorageCapacitySnapshot(
            availableBytes: 600,
            totalBytes: 1_000,
            source: .trueNAS(
                dataset: "vault/photos",
                pool: "vault",
                poolAvailableBytes: 2_500,
                poolTotalBytes: 4_000,
                poolHealthy: true
            )
        )

        XCTAssertNotEqual(estimate, authoritative)
        XCTAssertEqual(estimate.usedFraction, 0)
        XCTAssertEqual(authoritative.usedFraction, 0.4, accuracy: 0.001)
    }

    func testSidebarCapacityUsesWholeAdaptiveUnits() {
        XCTAssertEqual(Int64(110_450_000_000).formattedWholeStorage, "110 GB")
        XCTAssertEqual(Int64(1_650_000_000_000).formattedWholeStorage, "2 TB")
        XCTAssertEqual(Int64(999_000_000).formattedWholeStorage, "999 MB")
    }

    func testReaderFindsCapacityForMountedTemporaryFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitCapacityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let capacity = try XCTUnwrap(StorageCapacityReader.read(path: root.path))

        XCTAssertGreaterThan(capacity.totalBytes, 0)
        XCTAssertGreaterThanOrEqual(capacity.availableBytes, 0)
        XCTAssertLessThanOrEqual(capacity.availableBytes, capacity.totalBytes)
    }
}
