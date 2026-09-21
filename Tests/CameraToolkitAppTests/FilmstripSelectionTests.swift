import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

/// Finder-style filmstrip selection: click anchors, ⇧-click ranges,
/// ⌘-click pins, ⇧←/⇧→ move the open edge.
final class FilmstripSelectionTests: XCTestCase {
    private var items: [OrganizeItem] { (1...6).map { Self.frame($0) } }

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func frame(_ index: Int) -> OrganizeItem {
        let path = "/s/DSC0000\(index).ARW"
        return OrganizeItem(
            primary: OrganizeFile(path: path, size: 10, modifiedAt: t0),
            kind: .raw,
            captureDate: t0.addingTimeInterval(Double(index)),
            hasCameraDate: true
        )
    }

    func testClickSelectsOneFrameAndAnchors() {
        var selection = FilmstripSelection()
        selection.select(2, in: items)
        XCTAssertEqual(selection.indexes(in: items), [2])
        XCTAssertEqual(selection.edge, 2)
        XCTAssertEqual(selection.anchor, 2)

        // A second click re-anchors and collapses to that frame.
        selection.select(4, in: items)
        XCTAssertEqual(selection.indexes(in: items), [4])
        XCTAssertEqual(selection.anchor, 4)
    }

    func testShiftClickSelectsTheInclusiveRangeFromTheAnchor() {
        var selection = FilmstripSelection()
        selection.select(1, in: items)
        selection.extendRange(to: 4, in: items)
        XCTAssertEqual(selection.indexes(in: items), [1, 2, 3, 4])
        // The preview follows the clicked end; the anchor stays for the
        // next ⇧-click.
        XCTAssertEqual(selection.edge, 4)
        XCTAssertEqual(selection.anchor, 1)

        // A second ⇧-click re-ranges from the same anchor — the range
        // shrinks back rather than unioning with the old one.
        selection.extendRange(to: 2, in: items)
        XCTAssertEqual(selection.indexes(in: items), [1, 2])

        // Ranges run backwards too.
        selection.extendRange(to: 0, in: items)
        XCTAssertEqual(selection.indexes(in: items), [0, 1])
        XCTAssertEqual(selection.edge, 0)
    }

    func testCommandClickTogglesPinsThatSurviveRangeMoves() {
        var selection = FilmstripSelection()
        selection.select(0, in: items)
        selection.toggle(4, in: items)
        XCTAssertEqual(selection.indexes(in: items), [0, 4])
        // ⌘-click re-anchors, so the next ⇧-click ranges from there.
        XCTAssertEqual(selection.anchor, 4)
        XCTAssertEqual(selection.edge, 4)

        selection.extendRange(to: 2, in: items)
        XCTAssertEqual(selection.indexes(in: items), [0, 2, 3, 4])

        // ⌘-click on a selected frame punches a hole; everything else stays.
        selection.toggle(3, in: items)
        XCTAssertEqual(selection.indexes(in: items), [0, 2, 4])
        XCTAssertEqual(selection.edge, 3)
    }

    func testShiftArrowsGrowAndShrinkTheRangeFromTheEdge() {
        var selection = FilmstripSelection()
        selection.select(1, in: items)
        selection.moveEdge(by: 1, in: items)
        selection.moveEdge(by: 1, in: items)
        XCTAssertEqual(selection.indexes(in: items), [1, 2, 3])
        XCTAssertEqual(selection.edge, 3)

        // Backing the edge up shrinks the range instead of reselecting.
        selection.moveEdge(by: -1, in: items)
        XCTAssertEqual(selection.indexes(in: items), [1, 2])

        // Past the anchor the range regrows the other way.
        selection.moveEdge(by: -1, in: items)
        selection.moveEdge(by: -1, in: items)
        XCTAssertEqual(selection.indexes(in: items), [0, 1])
        XCTAssertEqual(selection.edge, 0)

        // The edge clamps at the strip ends.
        selection.moveEdge(by: -5, in: items)
        XCTAssertEqual(selection.edge, 0)
        XCTAssertEqual(selection.indexes(in: items), [0, 1])
    }

    func testShiftArrowsLeaveCommandPinnedFramesAlone() {
        var selection = FilmstripSelection()
        selection.select(0, in: items)
        selection.toggle(5, in: items)
        selection.moveEdge(by: -1, in: items)
        selection.moveEdge(by: -1, in: items)
        XCTAssertEqual(selection.indexes(in: items), [0, 3, 4, 5])
        selection.moveEdge(by: 1, in: items)
        XCTAssertEqual(selection.indexes(in: items), [0, 4, 5])
    }

    func testSanitizeDropsDepartedFramesAndReanchorsAnEmptySelection() {
        var selection = FilmstripSelection()
        selection.select(1, in: items)
        selection.extendRange(to: 3, in: items)
        selection.toggle(0, in: items)
        XCTAssertEqual(selection.indexes(in: items), [0, 1, 2, 3])

        // Frames 1 and 3 left the stack (trash/split/rescan): the selection
        // follows the frames, not their old positions.
        let survivors = [items[0], items[2], items[4], items[5]]
        selection.sanitize(in: survivors)
        XCTAssertEqual(selection.indexes(in: survivors), [0, 1])
        XCTAssertEqual(selection.selectedItems(in: survivors).map(\.primary.name), ["DSC00001.ARW", "DSC00003.ARW"])

        // When every selected frame left, the frame that slid into the
        // edge's slot becomes the new selection.
        var wiped = FilmstripSelection()
        wiped.select(1, in: items)
        wiped.extendRange(to: 2, in: items)
        wiped.sanitize(in: [items[4]])
        XCTAssertEqual(wiped.edge, 0)
        XCTAssertEqual(wiped.indexes(in: [items[4]]), [0])
    }
}
