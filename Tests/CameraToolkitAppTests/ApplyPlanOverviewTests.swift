import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

final class ApplyPlanOverviewTests: XCTestCase {
    private func group(
        name: String,
        moves: [DriveMove] = [],
        copies: [OrganizeApplyPlan.CopyBatch] = [],
        unavailable: Int = 0,
        destination: String,
        isPrivate: Bool = false
    ) -> OrganizeApplyPlan.EventGroup {
        OrganizeApplyPlan.EventGroup(
            event: SavedCameraEvent(name: name, eventDate: Date(), storagePolicy: isPrivate ? .archiveOnly : .buffer),
            moves: moves,
            copies: copies,
            alreadyThere: 0,
            unavailable: unavailable,
            destinationFolder: destination,
            isPrivate: isPrivate,
            byteCount: moves.reduce(Int64(0)) { $0 + $1.byteCount }
                + copies.reduce(Int64(0)) { $0 + $1.files.reduce(Int64(0)) { $0 + $1.size } }
        )
    }

    private func move(_ source: String, _ destination: String, bytes: Int64 = 100) -> DriveMove {
        DriveMove(sourcePath: source, destinationPath: destination, byteCount: bytes)
    }

    // MARK: - Path shortening

    func testShortPathKeepsDriveAndFinalFolder() {
        XCTAssertEqual(
            ApplyPathLabel.short("/Volumes/Crucial/Camera Buffer/2026/2026-08-23 Beach Day"),
            "Crucial ▸ … ▸ 2026-08-23 Beach Day"
        )
    }

    func testShortPathLeavesShortPathsWhole() {
        XCTAssertEqual(ApplyPathLabel.short("/Volumes/Crucial/Beach Day"), "Crucial ▸ Beach Day")
        XCTAssertEqual(ApplyPathLabel.short("/Volumes/Crucial/Buffer/Beach"), "Crucial ▸ Buffer ▸ Beach")
    }

    func testDriveNameFromPath() {
        XCTAssertEqual(ApplyPathLabel.driveName(for: "/Volumes/Buffer/Camera Buffer"), "Buffer")
        XCTAssertEqual(ApplyPathLabel.driveName(for: "/Drive/Camera Buffer"), "this Mac")
    }

    func testCommonFolderName() {
        XCTAssertEqual(ApplyPathLabel.commonFolderName(of: [
            "/Volumes/C/Unsorted A7V/Transfer 1",
            "/Volumes/C/Unsorted A7V/Transfer 2",
        ]), "Unsorted A7V")
        XCTAssertEqual(ApplyPathLabel.commonFolderName(of: ["/Volumes/C/Unsorted A7V/Transfer 1"]), "Transfer 1")
        XCTAssertEqual(ApplyPathLabel.commonFolderName(of: ["/Volumes/C/A", "/Volumes/C/B"]), "C")
        XCTAssertNil(ApplyPathLabel.commonFolderName(of: ["/Volumes/C/A", "/Volumes/D/B"]))
        XCTAssertNil(ApplyPathLabel.commonFolderName(of: []))
    }

    // MARK: - Sentence

    func testMoveOnlySentenceSaysNothingIsCopied() {
        let sentence = ApplyPlanOverview.sentence(
            moveCount: 40, copyCount: 0, sourceName: "Unsorted A7V", sourceFolderCount: 1,
            eventCount: 2, destinationDrives: ["Buffer"]
        )
        XCTAssertEqual(
            sentence,
            "40 files move from “Unsorted A7V” into 2 events on Buffer. They are renamed on the same drive, so no files are copied or deleted."
        )
    }

    func testSingularMoveSentence() {
        let sentence = ApplyPlanOverview.sentence(
            moveCount: 1, copyCount: 0, sourceName: "Card", sourceFolderCount: 1,
            eventCount: 1, destinationDrives: ["C"]
        )
        XCTAssertTrue(sentence.hasPrefix("1 file moves from “Card” into 1 event on C. It is renamed"))
    }

    func testCopyOnlySentenceKeepsOriginals() {
        let sentence = ApplyPlanOverview.sentence(
            moveCount: 0, copyCount: 12, sourceName: "LEXAR", sourceFolderCount: 1,
            eventCount: 1, destinationDrives: ["Crucial"]
        )
        XCTAssertEqual(
            sentence,
            "12 files are copied from “LEXAR” into 1 event on Crucial and checksum-verified. The originals stay where they are."
        )
        XCTAssertFalse(sentence.contains("move"))
    }

    func testMixedSentenceNamesBothOperations() {
        let sentence = ApplyPlanOverview.sentence(
            moveCount: 28, copyCount: 3, sourceName: nil, sourceFolderCount: 2,
            eventCount: 3, destinationDrives: ["A", "B"]
        )
        XCTAssertTrue(sentence.hasPrefix("28 files move and 3 are copied from 2 folders into 3 events on 2 drives."))
        XCTAssertTrue(sentence.contains("checksum-verified"))
        XCTAssertTrue(sentence.contains("originals in place"))
    }

    func testEmptySentence() {
        let sentence = ApplyPlanOverview.sentence(
            moveCount: 0, copyCount: 0, sourceName: nil, sourceFolderCount: 0,
            eventCount: 0, destinationDrives: []
        )
        XCTAssertTrue(sentence.hasPrefix("Nothing needs to move"))
    }

    // MARK: - Button, labels, safety lines

    func testPrimaryActionTitleNamesTheAction() {
        XCTAssertEqual(ApplyPlanOverview.primaryActionTitle(moveCount: 40, copyCount: 0), "Move 40 Files")
        XCTAssertEqual(ApplyPlanOverview.primaryActionTitle(moveCount: 1, copyCount: 0), "Move 1 File")
        XCTAssertEqual(ApplyPlanOverview.primaryActionTitle(moveCount: 0, copyCount: 1), "Copy 1 File")
        XCTAssertEqual(ApplyPlanOverview.primaryActionTitle(moveCount: 40, copyCount: 3), "Move & Copy 43 Files")
        XCTAssertEqual(ApplyPlanOverview.primaryActionTitle(moveCount: 0, copyCount: 0), "Apply")
    }

    func testMethodLabelsSayMoveAndCopy() {
        XCTAssertEqual(ApplyRouteMethod.rename.label, "Move")
        XCTAssertEqual(ApplyRouteMethod.rename.shortDetail, "instant · same drive")
        XCTAssertEqual(ApplyRouteMethod.verifiedCopy.label, "Copy + verify")
        XCTAssertEqual(ApplyRouteMethod.verifiedCopy.shortDetail, "other drive · originals kept")
    }

    func testSafetyFactsDependOnOperations() {
        let movesOnly = ApplyPlanOverview.safetyFacts(moveCount: 5, copyCount: 0).map(\.symbol)
        XCTAssertEqual(movesOnly, ["checkmark.circle", "arrow.uturn.backward"])
        let copiesOnly = ApplyPlanOverview.safetyFacts(moveCount: 0, copyCount: 5).map(\.symbol)
        XCTAssertEqual(copiesOnly, ["checkmark.circle", "checkmark.shield"])
        let both = ApplyPlanOverview.safetyFacts(moveCount: 1, copyCount: 1)
        XCTAssertEqual(both.count, 3)
    }

    func testCountsLine() {
        XCTAssertEqual(
            ApplyPlanOverview.countsLine(photos: 33, videos: 3, sidecars: 1, byteCount: 0),
            "33 photos · 3 videos · 1 sidecar · \(Int64(0).formattedBytes)"
        )
        XCTAssertTrue(ApplyPlanOverview.countsLine(photos: 1, videos: 0, sidecars: 0, byteCount: 10).hasPrefix("1 photo · "))
    }

    // MARK: - Built from a plan

    func testOverviewFromMixedPlan() {
        let beach = group(name: "Beach Day", moves: [
            move("/Volumes/Crucial/Unsorted A7V/Transfer 1/DSC00001.ARW", "/Volumes/Crucial/Camera Buffer/2026/2026-08-26 Beach Day/Sony A7V/Card Copy/DSC00001.ARW"),
            move("/Volumes/Crucial/Unsorted A7V/Transfer 1/C0001.MP4", "/Volumes/Crucial/Camera Buffer/2026/2026-08-26 Beach Day/Sony A7V/Card Copy/C0001.MP4", bytes: 500),
        ], destination: "/Volumes/Crucial/Camera Buffer/2026/2026-08-26 Beach Day")
        let batch = OrganizeApplyPlan.CopyBatch(
            sourceRoot: "/Volumes/LEXAR/DCIM",
            destinationRoot: "/Volumes/Crucial/.private/Client/Sony A7V/Card Copy",
            deviceID: "sony-a7v",
            files: [FileRecord(path: "DCIM/100MSDCF/DSC00009.ARW", size: 50, modifiedAt: Date())]
        )
        let client = group(name: "Client", copies: [batch], destination: "/Volumes/Crucial/.private/Client", isPrivate: true)
        let offline = group(name: "Offline", unavailable: 4, destination: "/Volumes/Other/Buffer/Offline")
        let plan = OrganizeApplyPlan(title: "Apply", groups: [beach, client, offline], pruneBoundaries: [])

        let overview = ApplyPlanOverview(plan: plan)
        XCTAssertEqual(overview.moveCount, 2)
        XCTAssertEqual(overview.copyCount, 1)
        XCTAssertEqual(overview.eventCount, 2)
        // The disconnected-only event gets a card but is not a destination drive.
        XCTAssertEqual(overview.destinations.count, 3)
        XCTAssertEqual(overview.destinationDrives, ["Crucial"])
        XCTAssertEqual(overview.destinations.map(\.methods), [[.rename], [.verifiedCopy], []])
        XCTAssertTrue(overview.destinations[1].summary.isPrivate)
        XCTAssertEqual(overview.destinations[0].shortPath, "Crucial ▸ … ▸ 2026-08-26 Beach Day")
        XCTAssertEqual(overview.destinations[0].countsLine, "1 photo · 1 video · \(Int64(600).formattedBytes)")

        XCTAssertEqual(overview.sources.map(\.name), ["Transfer 1", "DCIM"])
        XCTAssertEqual(overview.sources.map(\.driveName), ["Crucial", "LEXAR"])
        XCTAssertEqual(overview.sources[0].fateLine, "Files move out of this folder")
        XCTAssertEqual(overview.sources[1].fateLine, "Originals stay here")
        XCTAssertNil(overview.sourceName)
        XCTAssertEqual(overview.primaryActionTitle, "Move & Copy 3 Files")
        XCTAssertTrue(overview.sentence.hasPrefix("2 files move and 1 is copied from 2 folders into 2 events on Crucial."))
    }
}
