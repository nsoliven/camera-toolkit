import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

final class ApplyCollisionWordingTests: XCTestCase {
    private func collision(_ kind: ApplyCollision.Kind, _ name: String, bytes: Int64 = 100) -> ApplyCollision {
        ApplyCollision(
            kind: kind,
            move: DriveMove(sourcePath: "/Volumes/Drive/Found/\(name)", destinationPath: "/Volumes/Drive/Buffer/Event/\(name)", byteCount: bytes),
            assignment: nil,
            existingByteCount: kind == .travelsWithConflict ? nil : bytes + 1
        )
    }

    private func plan(
        moves: [DriveMove] = [],
        duplicates: [ApplyCollision] = [],
        conflicts: [ApplyCollision] = [],
        alreadyThere: Int = 0,
        name: String = "Beach Day"
    ) -> OrganizeApplyPlan {
        OrganizeApplyPlan(
            title: "Apply",
            groups: [OrganizeApplyPlan.EventGroup(
                event: SavedCameraEvent(name: name, eventDate: Date(), storagePolicy: .buffer),
                moves: moves,
                copies: [],
                alreadyThere: alreadyThere,
                unavailable: 0,
                destinationFolder: "/Volumes/Drive/Buffer/2026/2026-08-23 \(name)",
                isPrivate: false,
                byteCount: moves.reduce(Int64(0)) { $0 + $1.byteCount },
                duplicates: duplicates,
                conflicts: conflicts
            )],
            pruneBoundaries: []
        )
    }

    func testAllConflictPlanNeverOffersToMove() {
        let plan = plan(conflicts: [collision(.nameConflict, "DSC00001.ARW")], alreadyThere: 127)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.hasCollisions)
        let overview = ApplyPlanOverview(plan: plan)
        XCTAssertEqual(overview.moveCount, 0)
        XCTAssertEqual(overview.primaryActionTitle, "Nothing to Move")
        XCTAssertEqual(
            overview.sentence,
            "Nothing can move yet. 1 file can’t move: a different DSC00001.ARW is already in Beach Day."
        )
        XCTAssertEqual(overview.collisions.first?.keepBothExample, "DSC00001 (2).ARW")
    }

    func testCollisionsAreNotCountedInMoveTotals() {
        let moves = (1...3).map { DriveMove(sourcePath: "/Volumes/Drive/Found/F\($0).ARW", destinationPath: "/Volumes/Drive/Buffer/Event/F\($0).ARW", byteCount: 10) }
        let plan = plan(
            moves: moves,
            duplicates: [collision(.identicalCopy, "D1.ARW"), collision(.identicalCopy, "D2.JPG")],
            conflicts: [collision(.nameConflict, "C1.ARW"), collision(.travelsWithConflict, "C1.XMP")]
        )
        let overview = ApplyPlanOverview(plan: plan)
        XCTAssertEqual(overview.moveCount, 3)
        XCTAssertEqual(overview.byteCount, 30)
        XCTAssertEqual(overview.primaryActionTitle, "Move 3 Files")
        XCTAssertEqual(overview.duplicateCount, 2)
        XCTAssertEqual(overview.conflictCount, 1, "a sidecar held with its photo is not a second conflict")
        XCTAssertEqual(overview.destinations.first?.moveCount, 3)
        let summary = overview.collisions.first
        XCTAssertEqual(summary?.duplicateLine, "2 photos are already in Beach Day (identical copies)")
        XCTAssertEqual(summary?.conflictLine, "1 file can’t move: a different C1.ARW is already in Beach Day")
        XCTAssertEqual(summary?.heldBackLine, "1 sidecar waits with it, so pairs stay together.")
        XCTAssertTrue(ApplyPlanOverview.sentence(moveCount: 3, copyCount: 0, sourceNames: ["Found"], eventCount: 1, destinationDrives: ["Drive"]).hasPrefix("3 files move"))
    }

    func testStatusLineAfterApplySaysWhyFilesStayed() {
        let plan = plan(duplicates: [collision(.identicalCopy, "DSC00002.ARW")])
        XCTAssertEqual(
            ApplyStatusWording.afterApply(movedCount: 0, movedBytes: 0, skipped: [], plan: plan),
            "Moved 0 file(s) (Zero KB) into their events. 1 photo is already in Beach Day (identical copy) — open Apply to resolve."
        )
        // A name taken between planning and the rename still points at Apply.
        let raced = DriveMoveIssue(
            move: DriveMove(sourcePath: "/a", destinationPath: "/b", byteCount: 1),
            reason: "A file already exists at the destination. Nothing was replaced."
        )
        XCTAssertEqual(
            ApplyStatusWording.afterApply(movedCount: 2, movedBytes: 0, skipped: [raced], plan: self.plan()),
            "Moved 2 file(s) (Zero KB) into their events. 1 left in place: a file with the same name is already in the event — open Apply to resolve."
        )
    }

    func testBoardHintSeparatesSpareCopiesFromPendingFiles() {
        XCTAssertNil(ApplyStatusWording.boardHint(sortedFiles: 0, sortedBytes: 0, duplicates: 0, conflicts: 0))
        XCTAssertTrue(ApplyStatusWording.boardHint(sortedFiles: 2, sortedBytes: 10, duplicates: 0, conflicts: 0)?.hasSuffix("nothing moves until you Apply") == true)
        XCTAssertEqual(
            ApplyStatusWording.boardHint(sortedFiles: 0, sortedBytes: 0, duplicates: 1, conflicts: 0),
            "1 already in its event (identical copy) — open Apply to resolve"
        )
        XCTAssertEqual(
            ApplyStatusWording.boardHint(sortedFiles: 3, sortedBytes: 30, duplicates: 0, conflicts: 1),
            "2 sorted files still here · 1 can’t move: the name is taken — open Apply to resolve"
        )
    }
}
