import CameraToolkitCore
import XCTest

final class PathSafetyTests: XCTestCase {
    func testCheckoutStylePathEscapeIsBlocked() throws {
        XCTAssertNoThrow(try PathSafety.validateRelativePath("2026/Trip/Sony-A7V/batch"))

        for bad in ["../../../etc", "/Volumes/nas", "", "safe/../../bad"] {
            XCTAssertThrowsError(try PathSafety.validateRelativePath(bad))
        }
    }

    func testJunkFilePolicyIsConservative() {
        XCTAssertTrue(JunkPolicy.isJunkFile(".DS_Store"))
        XCTAssertTrue(JunkPolicy.isJunkFile("._DSC0001.ARW"))
        XCTAssertFalse(JunkPolicy.isJunkFile("DSC0001.ARW"))
        XCTAssertFalse(JunkPolicy.isJunkFile(".DS_Store_backup"))
        XCTAssertFalse(JunkPolicy.isJunkFile("photo._weird.jpg"))
    }
}
