@testable import CameraToolkitCore
import Foundation
import XCTest

final class TrueNASClientTests: XCTestCase {
    func testNormalizesSecureServerURLToCurrentWebSocketAPI() {
        XCTAssertEqual(
            TrueNASClient.normalizedWebSocketURL("nas.example.com")?.absoluteString,
            "wss://nas.example.com/api/current"
        )
        XCTAssertEqual(
            TrueNASClient.normalizedWebSocketURL("https://nas.example.com/ui/")?.absoluteString,
            "wss://nas.example.com/api/current"
        )
        XCTAssertNil(TrueNASClient.normalizedWebSocketURL("http://nas.example.com"))
        XCTAssertNil(TrueNASClient.normalizedWebSocketURL(""))
    }

    func testParsesExactDatasetAndUnderlyingPoolCapacity() throws {
        let report = try TrueNASClient.capacityReport(
            dataset: "vault/photos",
            versionResult: .string("TrueNAS-SCALE-25.04.2"),
            datasetResult: .object([
                "id": .string("vault/photos"),
                "mountpoint": .object(["value": .string("/mnt/vault/photos")]),
                "used": .object(["value": .int(400_000_000_000)]),
                "available": .object(["value": .int(600_000_000_000)])
            ]),
            poolResult: .object([
                "name": .string("vault"),
                "status": .string("ONLINE"),
                "healthy": .bool(true),
                "size": .int(4_000_000_000_000),
                "free": .int(2_500_000_000_000)
            ])
        )

        XCTAssertEqual(report.serverVersion, "TrueNAS-SCALE-25.04.2")
        XCTAssertEqual(report.dataset, "vault/photos")
        XCTAssertEqual(report.datasetMountpoint, "/mnt/vault/photos")
        XCTAssertEqual(report.datasetUsedBytes, 400_000_000_000)
        XCTAssertEqual(report.datasetAvailableBytes, 600_000_000_000)
        XCTAssertEqual(report.datasetTotalBytes, 1_000_000_000_000)
        XCTAssertEqual(report.poolName, "vault")
        XCTAssertEqual(report.poolStatus, "ONLINE")
        XCTAssertTrue(report.poolHealthy)
        XCTAssertEqual(report.poolTotalBytes, 4_000_000_000_000)
        XCTAssertEqual(report.poolFreeBytes, 2_500_000_000_000)
    }

    func testRejectsMissingDatasetCapacityInsteadOfInventingAValue() {
        XCTAssertThrowsError(
            try TrueNASClient.capacityReport(
                dataset: "vault/photos",
                versionResult: .string("TrueNAS"),
                datasetResult: .object(["id": .string("vault/photos")]),
                poolResult: .object([
                    "name": .string("vault"),
                    "size": .int(1_000),
                    "free": .int(500)
                ])
            )
        )
    }

    func testDetectsDeepestDatasetContainingSMBSharePath() {
        let datasets: TrueNASJSONValue = .array([
            .object([
                "id": .string("vault"),
                "mountpoint": .object(["value": .string("/mnt/vault")])
            ]),
            .object([
                "id": .string("vault/photos"),
                "mountpoint": .object(["value": .string("/mnt/vault/photos")])
            ]),
            .object([
                "id": .string("vault/photos/archive"),
                "mountpoint": .object(["value": .string("/mnt/vault/photos/archive")])
            ])
        ])

        XCTAssertEqual(
            TrueNASClient.matchingDataset(in: datasets, sharePath: "/mnt/vault/photos/users"),
            .object([
                "id": .string("vault/photos"),
                "mountpoint": .object(["value": .string("/mnt/vault/photos")])
            ])
        )
    }

    func testDoesNotMatchDatasetWithOnlyACommonPathPrefix() {
        let datasets: TrueNASJSONValue = .array([
            .object([
                "id": .string("vault/photo"),
                "mountpoint": .object(["value": .string("/mnt/vault/photo")])
            ])
        ])

        XCTAssertNil(TrueNASClient.matchingDataset(in: datasets, sharePath: "/mnt/vault/photos"))
    }
}
