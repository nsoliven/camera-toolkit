@testable import CameraToolkitApp
import XCTest

final class OrganizeChromeSizingTests: XCTestCase {
    func testStorageStripRestsCollapsed() {
        XCTAssertEqual(OrganizeChromeSizing.collapsedStorageStripHeight, 40)
        XCTAssertTrue(OrganizeChromeSizing.storageStripIsCollapsed(OrganizeChromeSizing.collapsedStorageStripHeight))
    }

    func testStorageStripDragSnapsToCollapsedBelowThreshold() {
        XCTAssertEqual(OrganizeChromeSizing.coercedStorageStripHeight(39), 40)
        XCTAssertEqual(OrganizeChromeSizing.coercedStorageStripHeight(95.9), 40)
        XCTAssertEqual(OrganizeChromeSizing.coercedStorageStripHeight(-200), 40)
    }

    func testStorageStripDragOpensIntoCardRange() {
        // Crossing the snap threshold lands on the expanded floor, never in
        // the dead zone where cards would clip.
        XCTAssertEqual(OrganizeChromeSizing.coercedStorageStripHeight(96), OrganizeChromeSizing.minimumExpandedStorageStripHeight)
        XCTAssertEqual(OrganizeChromeSizing.coercedStorageStripHeight(120), OrganizeChromeSizing.minimumExpandedStorageStripHeight)
        XCTAssertEqual(OrganizeChromeSizing.coercedStorageStripHeight(240), 240)
        XCTAssertEqual(OrganizeChromeSizing.coercedStorageStripHeight(9999), OrganizeChromeSizing.maximumStorageStripHeight)
    }

    func testStorageStripOrderingIsSane() {
        XCTAssertLessThan(OrganizeChromeSizing.collapsedStorageStripHeight, OrganizeChromeSizing.storageStripSnapThreshold)
        XCTAssertLessThan(OrganizeChromeSizing.storageStripSnapThreshold, OrganizeChromeSizing.minimumExpandedStorageStripHeight)
        XCTAssertLessThan(OrganizeChromeSizing.minimumExpandedStorageStripHeight, OrganizeChromeSizing.defaultExpandedStorageStripHeight)
        XCTAssertLessThan(OrganizeChromeSizing.defaultExpandedStorageStripHeight, OrganizeChromeSizing.maximumStorageStripHeight)
    }

    func testSidebarWidthClamps() {
        XCTAssertEqual(OrganizeChromeSizing.clampedSidebarWidth(300), 300)
        XCTAssertEqual(OrganizeChromeSizing.clampedSidebarWidth(10), OrganizeChromeSizing.sidebarWidthRange.lowerBound)
        XCTAssertEqual(OrganizeChromeSizing.clampedSidebarWidth(5000), OrganizeChromeSizing.sidebarWidthRange.upperBound)
        XCTAssertTrue(OrganizeChromeSizing.sidebarWidthRange.contains(OrganizeChromeSizing.defaultSidebarWidth))
    }
}
