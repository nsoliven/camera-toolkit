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
            "A different DSC00001.ARW is already in Beach Day. Choose what to do with yours."
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
            "Moved 0 files (Zero KB) into their events. 1 photo is already in Beach Day (identical copy) — open Apply to resolve."
        )
        // A name taken between planning and the rename still points at Apply.
        let raced = DriveMoveIssue(
            move: DriveMove(sourcePath: "/a", destinationPath: "/b", byteCount: 1),
            reason: "A file already exists at the destination. Nothing was replaced."
        )
        XCTAssertEqual(
            ApplyStatusWording.afterApply(movedCount: 2, movedBytes: 0, skipped: [raced], plan: self.plan()),
            "Moved 2 files (Zero KB) into their events. 1 left in place: a file with the same name is already in the event — open Apply to resolve."
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

    // MARK: - Decisions

    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func facts(_ captured: String?, bytes: Int64? = 100) -> ApplyCollisionFileFacts {
        ApplyCollisionFileFacts(byteCount: bytes, captureDate: captured.map(date), modifiedAt: nil)
    }

    func testItemsAttachSidecarsAndDefaultToTheRecommendedChoice() {
        let plan = plan(
            duplicates: [collision(.identicalCopy, "D1.ARW")],
            conflicts: [collision(.nameConflict, "C1.ARW"), collision(.travelsWithConflict, "C1.XMP")]
        )
        let items = ApplyCollisionResolution.items(for: plan)
        XCTAssertEqual(items.map(\.fileName), ["C1.ARW", "D1.ARW"])
        XCTAssertEqual(items[0].companions.map(\.fileName), ["C1.XMP"])
        XCTAssertEqual(items[0].fileCount, 2)
        XCTAssertTrue(items[1].companions.isEmpty)
        XCTAssertEqual(items[0].choices, [.keepBoth, .leave])
        XCTAssertEqual(items[1].choices, [.trash, .leave], "Trash is offered only for an identical copy")

        let defaults = ApplyCollisionResolution.defaultChoices(for: items)
        XCTAssertEqual(defaults[items[0].id], .keepBoth)
        XCTAssertEqual(defaults[items[1].id], .trash)

        let decisions = ApplyCollisionResolution.decisions(for: items, choices: defaults)
        XCTAssertEqual(decisions.keepBoth.map(\.fileName), ["C1.ARW", "C1.XMP"], "the sidecar keeps both with its photo")
        XCTAssertEqual(decisions.keepBothConflictCount, 1)
        XCTAssertEqual(decisions.trash.map(\.fileName), ["D1.ARW"])
    }

    func testLeaveSkipsARowAndAChoiceARowDoesNotOfferFallsBack() {
        let plan = plan(
            duplicates: [collision(.identicalCopy, "D1.ARW")],
            conflicts: [collision(.nameConflict, "C1.ARW"), collision(.travelsWithConflict, "C1.XMP")]
        )
        let items = ApplyCollisionResolution.items(for: plan)
        let left = ApplyCollisionResolution.decisions(for: items, choices: ApplyCollisionResolution.leaveAll(items))
        XCTAssertTrue(left.isEmpty)

        // A different photo can never be sent to Trash, whatever is stored.
        let bogus = [items[0].id: ApplyCollisionChoice.trash, items[1].id: .keepBoth]
        XCTAssertEqual(ApplyCollisionResolution.choice(for: items[0], in: bogus), .keepBoth)
        XCTAssertEqual(ApplyCollisionResolution.choice(for: items[1], in: bogus), .trash)
        let decisions = ApplyCollisionResolution.decisions(for: items, choices: bogus)
        XCTAssertEqual(decisions.trash.map(\.fileName), ["D1.ARW"])
        XCTAssertFalse(decisions.keepBoth.contains { $0.kind == .identicalCopy })
    }

    func testKeepBothForAllDifferentLeavesIdenticalCopiesAlone() {
        let plan = plan(
            duplicates: [collision(.identicalCopy, "D1.ARW")],
            conflicts: [collision(.nameConflict, "C1.ARW"), collision(.nameConflict, "C2.ARW")]
        )
        let items = ApplyCollisionResolution.items(for: plan)
        var choices = ApplyCollisionResolution.leaveAll(items)
        choices = ApplyCollisionResolution.keepBothForAllDifferent(items, choices)
        XCTAssertEqual(items.map { ApplyCollisionResolution.choice(for: $0, in: choices) }, [.keepBoth, .keepBoth, .leave])
    }

    func testVerdictNamesTheEvidence() {
        XCTAssertEqual(
            ApplyCollisionResolution.verdict(isIdentical: true, isPhoto: true, source: nil, existing: nil),
            "Identical copy"
        )
        XCTAssertEqual(
            ApplyCollisionResolution.verdict(
                isIdentical: false, isPhoto: true,
                source: facts("2026-08-19T10:00:00Z"), existing: facts("2026-08-29T18:30:00Z"),
                calendar: utc, locale: Locale(identifier: "en_US")
            ),
            "Different photos with the same name (taken Aug 19 vs Aug 29)"
        )
        XCTAssertEqual(
            ApplyCollisionResolution.verdict(
                isIdentical: false, isPhoto: true,
                source: facts("2025-12-30T10:00:00Z"), existing: facts("2026-01-02T10:00:00Z"),
                calendar: utc, locale: Locale(identifier: "en_US")
            ),
            "Different photos with the same name (taken Dec 30, 2025 vs Jan 2, 2026)"
        )
        let sameDay = ApplyCollisionResolution.verdict(
            isIdentical: false, isPhoto: true,
            source: facts("2026-08-19T14:05:00Z"), existing: facts("2026-08-19T17:40:00Z"),
            calendar: utc, locale: Locale(identifier: "en_US")
        )
        XCTAssertTrue(sameDay.hasPrefix("Different photos with the same name (taken 2:05"), sameDay)
        XCTAssertTrue(sameDay.contains("vs 5:40"), sameDay)
        XCTAssertEqual(
            ApplyCollisionResolution.verdict(
                isIdentical: false, isPhoto: false,
                source: facts(nil, bytes: 2_000_000), existing: facts(nil, bytes: 3_000_000)
            ),
            "Different files with the same name (\(Int64(2_000_000).formattedBytes) vs \(Int64(3_000_000).formattedBytes))"
        )
        XCTAssertEqual(
            ApplyCollisionResolution.verdict(isIdentical: false, isPhoto: true, source: nil, existing: nil),
            "Different photos with the same name"
        )
    }

    func testRecommendationSaysWhatToDoInPlainWords() {
        let plan = plan(
            duplicates: [collision(.identicalCopy, "D1.ARW")],
            conflicts: [collision(.nameConflict, "DSC00001.ARW"), collision(.travelsWithConflict, "DSC00001.XMP")]
        )
        let items = ApplyCollisionResolution.items(for: plan)
        XCTAssertEqual(
            ApplyCollisionResolution.recommendation(for: items[1], keepBothName: nil),
            "These are different photos. Keep both. Yours will be saved as DSC00001 (2).ARW. Its sidecar moves with it under the same number."
        )
        XCTAssertEqual(
            ApplyCollisionResolution.recommendation(for: items[1], keepBothName: "DSC00001 (3).ARW").contains("saved as DSC00001 (3).ARW."),
            true
        )
        XCTAssertEqual(
            ApplyCollisionResolution.recommendation(for: items[0], keepBothName: nil),
            "This exact photo is already there. You don’t need this copy."
        )
        XCTAssertEqual(
            ApplyCollisionResolution.outcome(for: items[0], choice: .trash, keepBothName: nil),
            "Goes to the drive’s _Trash after you confirm. The copy in Beach Day stays."
        )
        XCTAssertEqual(
            ApplyCollisionResolution.decisionSentence(for: items),
            "2 files need a decision: the same names are already in Beach Day."
        )
        XCTAssertEqual(
            ApplyCollisionResolution.decisionSentence(for: [items[0]]),
            "D1.ARW is already in Beach Day as an identical copy."
        )
    }

    func testPrimaryButtonNamesTheRecommendedAction() {
        func title(_ moves: Int, _ copies: Int = 0, keep files: Int = 0, _ conflicts: Int = 0, trash: Int = 0) -> String {
            ApplyPlanOverview.primaryActionTitle(moveCount: moves, copyCount: copies, keepBothFiles: files, keepBothConflicts: conflicts, trashCount: trash)
        }
        XCTAssertEqual(title(0, keep: 1, 1), "Keep Both & Move 1 File")
        XCTAssertEqual(title(0, keep: 2, 1), "Keep Both & Move 2 Files", "a sidecar moves with its photo")
        XCTAssertEqual(title(40, keep: 1, 1), "Move 41 Files (Keep Both for 1)")
        XCTAssertEqual(title(40, 3, keep: 1, 1), "Move & Copy 44 Files (Keep Both for 1)")
        XCTAssertEqual(title(0, trash: 1), "Move Duplicate to Trash…")
        XCTAssertEqual(title(0, trash: 2), "Move Duplicates to Trash…")
        XCTAssertEqual(title(40, trash: 2), "Move 40 Files, Then Trash 2 Duplicates…")
        XCTAssertEqual(title(0, keep: 1, 1, trash: 1), "Keep Both & Move 1 File, Then Trash 1 Duplicate…")
        XCTAssertEqual(title(40), "Move 40 Files")
        XCTAssertEqual(title(0), "Nothing to Move")
    }

    func testSheetButtonsForAllConflictAndMixedPlans() {
        let blocked = ApplyPlanOverview(plan: plan(conflicts: [collision(.nameConflict, "DSC00001.ARW")]))
        let blockedDefaults = ApplyCollisionResolution.decisions(
            for: blocked.collisionItems,
            choices: ApplyCollisionResolution.defaultChoices(for: blocked.collisionItems)
        )
        XCTAssertEqual(blocked.primaryActionTitle(with: blockedDefaults), "Keep Both & Move 1 File")
        XCTAssertTrue(blocked.isPrimaryEnabled(with: blockedDefaults))
        XCTAssertFalse(blocked.isPrimaryEnabled(with: ApplyCollisionDecisions()))
        XCTAssertNil(blocked.skipActionTitle(with: blockedDefaults), "nothing else to apply")
        XCTAssertEqual(blocked.cancelTitle, "Leave Here")

        let moves = (1...40).map { DriveMove(sourcePath: "/Volumes/Drive/Found/F\($0).ARW", destinationPath: "/Volumes/Drive/Buffer/Event/F\($0).ARW", byteCount: 10) }
        let mixed = ApplyPlanOverview(plan: plan(moves: moves, conflicts: [collision(.nameConflict, "DSC00001.ARW")]))
        let mixedDefaults = ApplyCollisionResolution.decisions(
            for: mixed.collisionItems,
            choices: ApplyCollisionResolution.defaultChoices(for: mixed.collisionItems)
        )
        XCTAssertEqual(mixed.primaryActionTitle(with: mixedDefaults), "Move 41 Files (Keep Both for 1)")
        XCTAssertEqual(mixed.skipActionTitle(with: mixedDefaults), "Skip These, Move 40 Files")
        XCTAssertNil(mixed.skipActionTitle(with: ApplyCollisionDecisions()), "already skipping")
        XCTAssertEqual(mixed.cancelTitle, "Cancel")

        let duplicateOnly = ApplyPlanOverview(plan: plan(duplicates: [collision(.identicalCopy, "D1.ARW")]))
        let trash = ApplyCollisionResolution.decisions(
            for: duplicateOnly.collisionItems,
            choices: ApplyCollisionResolution.defaultChoices(for: duplicateOnly.collisionItems)
        )
        XCTAssertEqual(duplicateOnly.primaryActionTitle(with: trash), "Move Duplicate to Trash…")
        XCTAssertTrue(ApplyPlanOverview.safetyFacts(moveCount: 0, copyCount: 0, trashCount: 1).contains { $0.symbol == "trash" })
    }
}
