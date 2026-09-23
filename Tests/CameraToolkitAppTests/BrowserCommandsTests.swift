import AppKit
@testable import CameraToolkitApp
import XCTest

@MainActor
final class BrowserCommandsTests: XCTestCase {
    func testShortcutCatalogCoversOrganizePreviewWindowsAndSafety() {
        let sections = CameraToolkitShortcutCatalog.sections
        let sectionTitles = Set(sections.map(\.title))
        let actions = Set(sections.flatMap(\.shortcuts).map(\.action))

        XCTAssertEqual(sectionTitles, ["Organize", "Preview", "Windows", "Safety"])
        XCTAssertTrue(actions.contains("Select all"))
        XCTAssertTrue(actions.contains("Search the board"))
        XCTAssertTrue(actions.contains("Sort into a recent event"))
        XCTAssertTrue(actions.contains("New event"))
        XCTAssertTrue(actions.contains("Undo a sort"))
        XCTAssertTrue(actions.contains("Open in Photomator"))
        XCTAssertTrue(actions.contains("Reveal in Finder"))
        XCTAssertTrue(actions.contains("Move to Trash"))
        XCTAssertTrue(actions.contains("Open preview"))
        XCTAssertTrue(actions.contains("Previous or next frame"))
        XCTAssertTrue(actions.contains("Event Library"))
        XCTAssertTrue(actions.contains("People"))
        XCTAssertTrue(actions.contains("Jobs"))
        XCTAssertTrue(actions.contains("Move files to Trash"))
    }

    func testBoardCommandsMatchTheCasesTheOrganizerHandles() {
        XCTAssertEqual(
            Set(BrowserCommand.allCases),
            [
                .moveSelectionToTrash,
                .selectAll,
                .openSelection,
                .previewSelection,
                .revealSelection,
                .reload,
                .find,
            ]
        )
    }

    func testBoardCommandsOnlyTargetTheMainWindowWhenItIsKey() {
        XCTAssertTrue(BrowserCommand.targetsMainWindow(keyWindowIdentifier: BrowserCommand.mainWindowIdentifier))
        XCTAssertFalse(BrowserCommand.targetsMainWindow(keyWindowIdentifier: TrashWindowController.windowIdentifier))
        XCTAssertFalse(BrowserCommand.targetsMainWindow(keyWindowIdentifier: "CameraToolkitPeopleWindow"))
        XCTAssertFalse(BrowserCommand.targetsMainWindow(keyWindowIdentifier: nil))
    }
}
