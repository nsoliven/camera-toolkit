@testable import CameraToolkitApp
import XCTest

final class OrganizeFolderLabelTests: XCTestCase {
    // MARK: - subfolder

    func testSubfolderReturnsPathBelowRoot() {
        XCTAssertEqual(
            OrganizeFolderLabel.subfolder(
                forFolderPath: "/Volumes/Card/DCIM/100MSDCF",
                rootPath: "/Volumes/Card"
            ),
            "DCIM/100MSDCF"
        )
    }

    func testSubfolderIsNilWhenItemSitsInRoot() {
        XCTAssertNil(
            OrganizeFolderLabel.subfolder(
                forFolderPath: "/Volumes/Card",
                rootPath: "/Volumes/Card"
            )
        )
    }

    func testSubfolderIsNilOutsideRoot() {
        XCTAssertNil(
            OrganizeFolderLabel.subfolder(
                forFolderPath: "/Other/DCIM",
                rootPath: "/Volumes/Card"
            )
        )
    }

    func testSubfolderRespectsPathComponentBoundary() {
        // "/Volumes/Card2" must not match root "/Volumes/Card".
        XCTAssertNil(
            OrganizeFolderLabel.subfolder(
                forFolderPath: "/Volumes/Card2/DCIM",
                rootPath: "/Volumes/Card"
            )
        )
    }

    func testSubfolderMatchesRootCaseInsensitively() {
        XCTAssertEqual(
            OrganizeFolderLabel.subfolder(
                forFolderPath: "/volumes/card/DCIM",
                rootPath: "/Volumes/Card"
            ),
            "DCIM"
        )
    }

    func testSubfolderIsNilWithoutRoot() {
        XCTAssertNil(
            OrganizeFolderLabel.subfolder(
                forFolderPath: "/Volumes/Card/DCIM",
                rootPath: nil
            )
        )
    }

    // MARK: - title

    func testTitleIsRootNamePlusSubfolder() {
        XCTAssertEqual(
            OrganizeFolderLabel.title(
                forFolderPath: "/Volumes/Transfer 3 (Lola Tessie BDay)/100MSDCF",
                rootPath: "/Volumes/Transfer 3 (Lola Tessie BDay)"
            ),
            "Transfer 3 (Lola Tessie BDay)/100MSDCF"
        )
    }

    func testTitleIsRootNameForItemsInRoot() {
        XCTAssertEqual(
            OrganizeFolderLabel.title(
                forFolderPath: "/Volumes/Card",
                rootPath: "/Volumes/Card"
            ),
            "Card"
        )
    }

    func testTitleFallsBackToFolderNameOutsideRoot() {
        XCTAssertEqual(
            OrganizeFolderLabel.title(
                forFolderPath: "/Other Drive/DCIM",
                rootPath: "/Volumes/Card"
            ),
            "DCIM"
        )
    }

    func testTitleIsFolderNameWithoutRoot() {
        XCTAssertEqual(
            OrganizeFolderLabel.title(
                forFolderPath: "/Volumes/Card/DCIM",
                rootPath: nil
            ),
            "DCIM"
        )
    }
}
