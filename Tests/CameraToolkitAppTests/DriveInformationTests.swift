@testable import CameraToolkitApp
import XCTest

final class DriveInformationTests: XCTestCase {
    func testSMARTHealthDistinguishesVerifiedUnsupportedAndFailure() {
        XCTAssertEqual(
            DriveInformationReader.smartHealth(status: "Verified", isNetworkShare: false),
            .verified
        )
        XCTAssertEqual(
            DriveInformationReader.smartHealth(status: "Not Supported", isNetworkShare: false),
            .notSupported
        )
        XCTAssertEqual(
            DriveInformationReader.smartHealth(status: "Failing", isNetworkShare: false),
            .failing("Failing")
        )
    }

    func testNetworkShareNeverPretendsToKnowPhysicalDiskSMARTHealth() {
        XCTAssertEqual(
            DriveInformationReader.smartHealth(status: "Verified", isNetworkShare: true),
            .unavailable
        )
    }

    func testSnapshotCalculatesUsedBytesFromCapacity() {
        let request = DriveInformationRequest(
            id: "buffer",
            name: "Buffer",
            path: "/Volumes/Buffer",
            symbol: "externaldrive.fill",
            role: "Buffer"
        )
        let snapshot = DriveInformationSnapshot(
            request: request,
            isMounted: true,
            capacity: StorageCapacitySnapshot(availableBytes: 25, totalBytes: 100),
            smartHealth: .notSupported,
            isNetworkShare: false,
            checkedAt: Date()
        )

        XCTAssertEqual(snapshot.usedBytes, 75)
    }

    func testOfflineExternalLocationDoesNotFallBackToInternalMacDrive() async {
        let request = DriveInformationRequest(
            id: "offline-camera",
            name: "Offline Camera",
            path: "/Volumes/CameraToolkit-Definitely-Not-Mounted",
            symbol: "camera.fill",
            role: "Camera Source"
        )

        let snapshot = await DriveInformationReader.read(request: request)

        XCTAssertFalse(snapshot.isMounted)
        XCTAssertNil(snapshot.mountPoint)
        XCTAssertNil(snapshot.model)
        XCTAssertEqual(snapshot.errorMessage, "This location is not currently mounted.")
    }
}
