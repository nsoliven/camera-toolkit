@testable import CameraToolkitApp
import XCTest

final class KeyboardShortcutFilterTests: XCTestCase {
    private let sections = CameraToolkitShortcutCatalog.sections

    func testEmptyQueryKeepsEverySection() {
        XCTAssertEqual(KeyboardShortcutFilter.sections(sections, matching: "  "), sections)
    }

    func testQueryKeepsOnlyMatchingShortcuts() {
        let result = KeyboardShortcutFilter.sections(sections, matching: "photomator")
        XCTAssertFalse(result.isEmpty)
        for section in result {
            XCTAssertTrue(section.shortcuts.allSatisfy {
                $0.action.localizedCaseInsensitiveContains("photomator")
                    || $0.detail.localizedCaseInsensitiveContains("photomator")
            })
        }
    }

    func testSectionTitleKeepsTheWholeSection() {
        let result = KeyboardShortcutFilter.sections(sections, matching: "Safety")
        let safety = sections.first { $0.title == "Safety" }
        XCTAssertEqual(result.first { $0.title == "Safety" }, safety)
    }

    func testNoMatchIsEmpty() {
        XCTAssertTrue(KeyboardShortcutFilter.sections(sections, matching: "zzqqxx").isEmpty)
    }
}
