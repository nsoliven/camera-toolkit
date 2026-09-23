import AppKit
@testable import CameraToolkitApp
import XCTest

final class BoardTileStyleTests: XCTestCase {
    func testSelectionIsEmphasizedOnlyWhenTheBoardHasFocusInTheActiveWindow() {
        XCTAssertTrue(BoardSelectionStyle.isEmphasized(windowIsActive: true, boardHasFocus: true))
        XCTAssertFalse(BoardSelectionStyle.isEmphasized(windowIsActive: true, boardHasFocus: false))
        XCTAssertFalse(BoardSelectionStyle.isEmphasized(windowIsActive: false, boardHasFocus: true))
        XCTAssertFalse(BoardSelectionStyle.isEmphasized(windowIsActive: false, boardHasFocus: false))
    }

    func testSelectionColourFollowsTheSystemEmphasizedAndUnemphasizedColours() {
        XCTAssertEqual(BoardSelectionStyle.selectionNSColor(isEmphasized: true), .selectedContentBackgroundColor)
        XCTAssertEqual(BoardSelectionStyle.selectionNSColor(isEmphasized: false), .unemphasizedSelectedContentBackgroundColor)
    }

    func testSelectedRowTextTurnsWhiteOnlyOnTheAccentHighlight() {
        XCTAssertEqual(BoardSelectionStyle.selectedTextNSColor(isEmphasized: true), .alternateSelectedControlTextColor)
        XCTAssertEqual(BoardSelectionStyle.selectedTextNSColor(isEmphasized: false), .labelColor)
    }

    func testSelectionRingSitsOutsideThePhoto() {
        XCTAssertGreaterThan(BoardMetrics.selectionRingGap, 0)
        XCTAssertGreaterThanOrEqual(BoardMetrics.badgeMinHitSize, 22)
    }

    func testLightPaletteEntriesGetDarkChipText() {
        var sawLight = false
        var sawDark = false
        for _ in 0..<200 {
            let id = UUID()
            let light = EventPalette.prefersDarkText(for: id)
            if light { sawLight = true } else { sawDark = true }
            // The choice is stable for an id.
            XCTAssertEqual(light, EventPalette.prefersDarkText(for: id))
        }
        XCTAssertTrue(sawLight)
        XCTAssertTrue(sawDark)
    }

    @MainActor
    func testRowHoverTracksOnlyTheLatestRowAndClearsOnItsOwnExit() {
        let hover = BoardHoverState()
        hover.set("a", hovering: true)
        XCTAssertEqual(hover.rowID, "a")
        hover.set("b", hovering: true)
        XCTAssertEqual(hover.rowID, "b")
        // A late exit from the previous row must not hide the new row's menu.
        hover.set("a", hovering: false)
        XCTAssertEqual(hover.rowID, "b")
        hover.set("b", hovering: false)
        XCTAssertNil(hover.rowID)
    }
}
