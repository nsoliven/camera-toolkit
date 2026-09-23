@testable import CameraToolkitApp
import XCTest

final class OrganizeChromeSizingTests: XCTestCase {
    func testSidebarWidthClamps() {
        XCTAssertEqual(OrganizeChromeSizing.clampedSidebarWidth(300), 300)
        XCTAssertEqual(OrganizeChromeSizing.clampedSidebarWidth(10), OrganizeChromeSizing.sidebarWidthRange.lowerBound)
        XCTAssertEqual(OrganizeChromeSizing.clampedSidebarWidth(5000), OrganizeChromeSizing.sidebarWidthRange.upperBound)
        XCTAssertTrue(OrganizeChromeSizing.sidebarWidthRange.contains(OrganizeChromeSizing.defaultSidebarWidth))
    }

    func testStoredSidebarWidthDefaultsAndClamps() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OrganizeChromeSizingTests-\(UUID().uuidString)"))
        XCTAssertEqual(OrganizeChromeSizing.storedSidebarWidth(in: defaults), OrganizeChromeSizing.defaultSidebarWidth)
        defaults.set(350.0, forKey: OrganizeChromeSizing.sidebarWidthDefaultsKey)
        XCTAssertEqual(OrganizeChromeSizing.storedSidebarWidth(in: defaults), 350)
        defaults.set(5.0, forKey: OrganizeChromeSizing.sidebarWidthDefaultsKey)
        XCTAssertEqual(OrganizeChromeSizing.storedSidebarWidth(in: defaults), OrganizeChromeSizing.sidebarWidthRange.lowerBound)
    }

    func testCollapsingSidebarWidthIsNotPersisted() {
        XCTAssertNil(OrganizeChromeSizing.persistableSidebarWidth(0))
        XCTAssertNil(OrganizeChromeSizing.persistableSidebarWidth(120))
        XCTAssertNil(OrganizeChromeSizing.persistableSidebarWidth(.nan))
        XCTAssertEqual(OrganizeChromeSizing.persistableSidebarWidth(349.6), 350)
        XCTAssertEqual(OrganizeChromeSizing.persistableSidebarWidth(9_000), OrganizeChromeSizing.sidebarWidthRange.upperBound)
    }
}
