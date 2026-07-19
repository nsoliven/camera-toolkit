@testable import CameraToolkitCore
import XCTest

final class EventNamePolicyTests: XCTestCase {
    func testSpacesAndCommonPunctuationAreAccepted() {
        let validation = EventNamePolicy.validate("  Alex & Sam's (Reception) #2  ")

        XCTAssertTrue(validation.isValid)
        XCTAssertEqual(validation.normalizedName, "Alex & Sam's (Reception) #2")
        XCTAssertEqual(validation.folderName, "Alex & Sam's (Reception) #2")
    }

    func testWhitespaceIsNormalizedWithoutRemovingWordSeparators() {
        let validation = EventNamePolicy.validate("Summer   Beach\tPortraits")

        XCTAssertTrue(validation.isValid)
        XCTAssertEqual(validation.normalizedName, "Summer Beach Portraits")
    }

    func testNASReservedCharactersReturnClearDashSuggestion() {
        let validation = EventNamePolicy.validate("Summer/Beach:Portraits")

        XCTAssertFalse(validation.isValid)
        XCTAssertEqual(validation.suggestion, "Summer-Beach-Portraits")
        XCTAssertTrue(validation.errorMessage?.contains("Use a dash instead") == true)
    }

    func testEmptyDotsAndTrailingPeriodsAreRejectedWithGuidance() {
        XCTAssertFalse(EventNamePolicy.validate("   ").isValid)
        XCTAssertEqual(EventNamePolicy.validate("..").suggestion, "Photo-Event")
        XCTAssertEqual(EventNamePolicy.validate("Launch Night.").suggestion, "Launch Night")
    }

    func testFolderNameSafelyRepairsLegacyInvalidNames() {
        XCTAssertEqual(
            EventNamePolicy.folderName(for: "YouTube/Studio:Test", fallback: "Import"),
            "YouTube-Studio-Test"
        )
    }
}
