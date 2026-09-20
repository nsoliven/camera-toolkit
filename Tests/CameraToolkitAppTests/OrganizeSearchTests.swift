import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

final class OrganizeSearchTests: XCTestCase {
    private func item(_ path: String) -> OrganizeItem {
        OrganizeItem(
            primary: OrganizeFile(path: path, size: 1, modifiedAt: Date()),
            kind: .raw,
            captureDate: Date(),
            hasCameraDate: true
        )
    }

    func testNeedleTrimsAndLowercases() {
        XCTAssertEqual(OrganizeSearch.needle("  PHIL \n"), "phil")
        XCTAssertEqual(OrganizeSearch.needle("   "), "")
        XCTAssertEqual(OrganizeSearch.needle(""), "")
    }

    func testEmptyNeedleMatchesEveryStack() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: "", rootPath: "/Card", eventTitle: nil))
    }

    func testMatchesAnyFileNameInAStack() {
        let stack = OrganizeStack(items: [
            item("/Card/DCIM/B0001_DSC00001.ARW"),
            item("/Card/DCIM/B0001_DSC00002.ARW"),
        ])
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: "dsc00002", rootPath: "/Card", eventTitle: nil))
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: ".arw", rootPath: "/Card", eventTitle: nil))
        XCTAssertFalse(OrganizeSearch.matches(stack: stack, needle: "dsc00999", rootPath: "/Card", eventTitle: nil))
    }

    func testMatchesCompanionFileName() {
        var pair = item("/Card/DSC00001.ARW")
        pair.companions = [OrganizeFile(path: "/Card/DSC00001.xmp", size: 1, modifiedAt: Date())]
        let stack = OrganizeStack(items: [pair])
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: ".xmp", rootPath: "/Card", eventTitle: nil))
    }

    func testMatchesBurstLabel() {
        let stack = OrganizeStack(items: [item("/Card/B0007_DSC00001.ARW")])
        XCTAssertEqual(stack.burstLabel, "B0007")
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: "b0007", rootPath: "/Card", eventTitle: nil))
    }

    func testMatchesOriginSubfolderRelativeToScanRoot() {
        let stack = OrganizeStack(items: [item("/Card/Transfer 1/100MSDCF/DSC00001.ARW")])
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: "transfer 1/100", rootPath: "/Card", eventTitle: nil))
        // The same folder outside the scanned root is not an origin subfolder.
        XCTAssertFalse(OrganizeSearch.matches(stack: stack, needle: "transfer", rootPath: "/Other", eventTitle: nil))
        XCTAssertFalse(OrganizeSearch.matches(stack: stack, needle: "transfer", rootPath: nil, eventTitle: nil))
    }

    func testMatchesAssignedEventBreadcrumbTitle() {
        let stack = OrganizeStack(items: [item("/Card/DSC00001.ARW")])
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: "phil", rootPath: "/Card", eventTitle: "PHIL2026 / Matcha"))
        XCTAssertTrue(OrganizeSearch.matches(stack: stack, needle: "matcha", rootPath: "/Card", eventTitle: "PHIL2026 / Matcha"))
        XCTAssertFalse(OrganizeSearch.matches(stack: stack, needle: "phil", rootPath: "/Card", eventTitle: nil))
    }
}
