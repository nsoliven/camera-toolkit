@testable import CameraToolkitApp
import CameraToolkitCore
import XCTest

final class OrganizerSheetsTests: XCTestCase {
    /// The verified-removal button unlocks only on the exact token — a
    /// restyle must never loosen it into a case-folded or trimmed match.
    func testRemovalUnlocksOnlyOnTheExactToken() {
        let token = VerifiedRemovalService.confirmationToken
        XCTAssertEqual(token, "REMOVE")
        XCTAssertTrue(RemovalConfirmSheet.isConfirmed(token))
        XCTAssertFalse(RemovalConfirmSheet.isConfirmed(""))
        XCTAssertFalse(RemovalConfirmSheet.isConfirmed(token.lowercased()))
        XCTAssertFalse(RemovalConfirmSheet.isConfirmed(" \(token)"))
        XCTAssertFalse(RemovalConfirmSheet.isConfirmed("\(token) "))
        XCTAssertFalse(RemovalConfirmSheet.isConfirmed("REMOV"))
    }
}
