import CameraToolkitCore
@testable import CameraToolkitApp
import Foundation
import XCTest

/// Move to Event's status line and the Duplicates window's sentences:
/// singular and plural said properly, never "file(s)".
final class EventMoveWordingTests: XCTestCase {
    private func item(_ name: String) -> EventMoveItem {
        let assignment = PhotoEventAssignment(
            sourceRootPath: "/Drive/Unsorted",
            relativePath: name,
            fileSize: 10,
            modifiedAt: Date(timeIntervalSince1970: 0),
            eventID: UUID()
        )
        return EventMoveItem(removed: assignment, added: assignment, move: nil, currentPath: nil)
    }

    func testPlainMoveSaysPhotoOrPhotos() {
        var outcome = EventMoveOutcome()
        outcome.moved = [item("DSC00001.ARW")]
        XCTAssertEqual(EventMoveWording.summary(outcome, from: "Hotel", to: "Beach"), "Moved 1 photo to Beach.")
        outcome.moved.append(item("DSC00002.ARW"))
        XCTAssertEqual(EventMoveWording.summary(outcome, from: "Hotel", to: "Beach"), "Moved 2 photos to Beach.")
        outcome.moved.append(item("DSC00002.xmp"))
        XCTAssertEqual(EventMoveWording.summary(outcome, from: "Hotel", to: "Beach"), "Moved 3 files to Beach.")
    }

    func testMergesKeepBothAndStaysReadAsOneLine() {
        var outcome = EventMoveOutcome()
        outcome.moved = (1...36).map { item(String(format: "DSC%05d.ARW", $0)) }
        outcome.merged = (37...40).map { item(String(format: "DSC%05d.ARW", $0)) }
        outcome.mergedToTrash = 4
        outcome.keptBoth = [
            EventMoveKeptBoth(item: item("DSC06987.ARW"), newName: "DSC06987 (2).ARW"),
            EventMoveKeptBoth(item: item("DSC06988.ARW"), newName: "DSC06988 (2).ARW"),
        ]
        outcome.stayed = [EventMoveStay(item: item("DSC09999.ARW"), reason: "DSC09999.ARW could not be read to compare: I/O error.")]
        XCTAssertEqual(
            EventMoveWording.summary(outcome, from: "Hotel", to: "Beach"),
            "Moved 42 photos to Beach (4 were already there, so their extra copies went to Trash). 2 had the same name as different photos and were kept with a new name. 1 stayed in Hotel: DSC09999.ARW could not be read to compare: I/O error."
        )
    }

    func testOnlyMergesAndNothingMoved() {
        var outcome = EventMoveOutcome()
        outcome.merged = [item("DSC00001.ARW")]
        outcome.mergedToTrash = 1
        XCTAssertEqual(
            EventMoveWording.summary(outcome, from: "Hotel", to: "Beach"),
            "1 photo was already in Beach, so its extra copy went to Trash."
        )
        outcome.merged.append(item("DSC00002.ARW"))
        XCTAssertEqual(
            EventMoveWording.summary(outcome, from: "Hotel", to: "Beach"),
            "2 photos were already in Beach; 1 extra copy went to Trash."
        )
        outcome.mergedToTrash = 0
        outcome.stayed = [
            EventMoveStay(item: item("DSC00003.ARW"), reason: "first reason"),
            EventMoveStay(item: item("DSC00004.ARW"), reason: "second reason"),
        ]
        XCTAssertEqual(
            EventMoveWording.summary(outcome, from: "Hotel", to: "Beach"),
            "2 photos were already in Beach. 2 stayed in Hotel, for example: first reason."
        )
    }

    func testDuplicateBoardNoticeAndSummaries() {
        XCTAssertEqual(
            DuplicateReviewWording.boardNotice(count: 71, partners: ["Trip / Hotel"]),
            "71 photos here are identical copies of ones in Trip / Hotel."
        )
        XCTAssertEqual(
            DuplicateReviewWording.boardNotice(count: 1, partners: ["A", "B", "C"]),
            "1 photo here is an identical copy of one in A and 2 other places."
        )
        XCTAssertEqual(DuplicateReviewWording.resolutionSummary(DuplicateResolutionOutcome()), "Nothing changed.")
        XCTAssertEqual(DuplicateReviewWording.copies(1), "1 copy")
        XCTAssertEqual(DuplicateReviewWording.copies(3), "3 copies")
    }
}
