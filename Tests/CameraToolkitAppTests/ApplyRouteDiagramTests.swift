import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

final class ApplyRouteDiagramTests: XCTestCase {
    private func move(_ source: String, _ destination: String, bytes: Int64 = 100) -> DriveMove {
        DriveMove(sourcePath: source, destinationPath: destination, byteCount: bytes)
    }

    private func eventGroup(
        name: String = "Beach Day",
        moves: [DriveMove] = [],
        copies: [OrganizeApplyPlan.CopyBatch] = [],
        alreadyThere: Int = 0,
        unavailable: Int = 0,
        destination: String = "/Drive/Camera Buffer/2026/2026-08-26 Beach Day",
        isPrivate: Bool = false
    ) -> OrganizeApplyPlan.EventGroup {
        OrganizeApplyPlan.EventGroup(
            event: SavedCameraEvent(name: name, eventDate: Date(), storagePolicy: isPrivate ? .archiveOnly : .buffer),
            moves: moves,
            copies: copies,
            alreadyThere: alreadyThere,
            unavailable: unavailable,
            destinationFolder: destination,
            isPrivate: isPrivate,
            byteCount: moves.reduce(Int64(0)) { $0 + $1.byteCount }
                + copies.reduce(Int64(0)) { $0 + $1.files.reduce(Int64(0)) { $0 + $1.size } }
        )
    }

    func testMovesMergeIntoOneRowPerSourceFolder() {
        let group = eventGroup(moves: [
            move("/Volumes/A7V/DCIM/Transfer 1/B0001_DSC00001.ARW", "/Drive/Buffer/Beach/Sony A7V/Card Copy/B0001_DSC00001.ARW"),
            move("/Volumes/A7V/DCIM/Transfer 1/B0001_DSC00002.ARW", "/Drive/Buffer/Beach/Sony A7V/Card Copy/B0001_DSC00002.ARW"),
            move("/Volumes/A7V/DCIM/Transfer 2/C0001.ARW", "/Drive/Buffer/Beach/Sony A7V/Card Copy/C0001.ARW"),
        ], destination: "/Drive/Buffer/Beach")

        let routes = ApplyRouteDiagram.routes(for: group)
        XCTAssertEqual(routes.count, 2)
        let transfer1 = routes.first { $0.sourcePath.hasSuffix("Transfer 1") }
        XCTAssertEqual(transfer1?.fileCount, 2)
        XCTAssertEqual(transfer1?.method, .rename)
        XCTAssertEqual(transfer1?.sourceLabel, "A7V ▸ DCIM ▸ Transfer 1")
        XCTAssertEqual(transfer1?.destinationLabel, "Sony A7V ▸ Card Copy")
        XCTAssertEqual(transfer1?.fileNames.sorted(), ["B0001_DSC00001.ARW", "B0001_DSC00002.ARW"])
    }

    func testVideoMovesAreCountedAsVideos() {
        let group = eventGroup(moves: [
            move("/Card/DCIM/DSC00001.ARW", "/E/Card Copy/DSC00001.ARW"),
            move("/Card/DCIM/C0001.MP4", "/E/Card Copy/C0001.MP4", bytes: 400),
            move("/Card/DCIM/DSC00001.xmp", "/E/Card Copy/DSC00001.xmp"),
        ], destination: "/E")

        let route = ApplyRouteDiagram.routes(for: group).first
        XCTAssertEqual(route?.fileCount, 3)
        XCTAssertEqual(route?.photoCount, 1)
        XCTAssertEqual(route?.videoCount, 1)
        XCTAssertEqual(route?.otherCount, 1)
        XCTAssertEqual(route?.byteCount, 600)
        XCTAssertTrue(route?.fileSummary.contains("1 video") ?? false)
    }

    func testCopyBatchesBecomeVerifiedCopyRows() {
        let batch = OrganizeApplyPlan.CopyBatch(
            sourceRoot: "/Volumes/LEXAR/DCIM",
            destinationRoot: "/E/Sony A7V/Card Copy",
            deviceID: "sony-a7v",
            files: [
                FileRecord(path: "DCIM/100MSDCF/DSC00001.ARW", size: 10, modifiedAt: Date()),
                FileRecord(path: "DCIM/100MSDCF/C0002.MP4", size: 30, modifiedAt: Date()),
            ]
        )
        let group = eventGroup(copies: [batch], destination: "/E")

        let routes = ApplyRouteDiagram.routes(for: group)
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].method, .verifiedCopy)
        XCTAssertEqual(routes[0].fileCount, 2)
        XCTAssertEqual(routes[0].videoCount, 1)
        XCTAssertEqual(routes[0].byteCount, 40)
        XCTAssertEqual(routes[0].sourceLabel, "LEXAR ▸ DCIM")
        XCTAssertEqual(routes[0].destinationLabel, "Sony A7V ▸ Card Copy")
        XCTAssertEqual(routes[0].fileNames, ["DCIM/100MSDCF/C0002.MP4", "DCIM/100MSDCF/DSC00001.ARW"])
    }

    func testRenamesSortBeforeVerifiedCopies() {
        let batch = OrganizeApplyPlan.CopyBatch(
            sourceRoot: "/Volumes/AAA",
            destinationRoot: "/E/Card Copy",
            deviceID: "sony-a7v",
            files: [FileRecord(path: "A.ARW", size: 1, modifiedAt: Date())]
        )
        let group = eventGroup(
            moves: [move("/Volumes/ZZZ/B.ARW", "/E/Card Copy/B.ARW")],
            copies: [batch],
            destination: "/E"
        )
        let routes = ApplyRouteDiagram.routes(for: group)
        XCTAssertEqual(routes.map(\.method), [.rename, .verifiedCopy])
    }

    func testBannerRoutesPrefixTheEventName() {
        let group = eventGroup(moves: [
            move("/Volumes/A7V/DCIM/A.ARW", "/E/Sony A7V/Card Copy/A.ARW"),
        ], destination: "/E")
        let running = RunningApplyPlan(jobID: UUID(), title: "Apply", groups: [group])

        let routes = ApplyRouteDiagram.routes(for: running)
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].destinationLabel, "Beach Day ▸ Sony A7V ▸ Card Copy")
        XCTAssertTrue(routes[0].id.hasPrefix(group.id.uuidString))
    }

    func testBannerRouteForFileLandingAtEventRoot() {
        let group = eventGroup(moves: [
            move("/Volumes/A7V/DCIM/A.ARW", "/E/A.ARW"),
        ], destination: "/E")
        let running = RunningApplyPlan(jobID: UUID(), title: "Apply", groups: [group])
        let routes = ApplyRouteDiagram.routes(for: running)
        XCTAssertEqual(routes[0].destinationLabel, "Beach Day")
    }

    func testEmptyGroupProducesNoRoutes() {
        XCTAssertTrue(ApplyRouteDiagram.routes(for: eventGroup()).isEmpty)
    }

    func testPlanSummaryListsEveryEventWithBalancedCounts() {
        let first = eventGroup(name: "Trip 2026", moves: [
            move("/Card/DCIM/DSC00001.ARW", "/E1/Sony A7V/Card Copy/DSC00001.ARW", bytes: 200),
            move("/Card/DCIM/DSC00002.ARW", "/E1/Sony A7V/Card Copy/DSC00002.ARW", bytes: 200),
            move("/Card/DCIM/C0001.MP4", "/E1/Sony A7V/Card Copy/C0001.MP4", bytes: 900),
            move("/Card/DCIM/DSC00001.xmp", "/E1/Sony A7V/Card Copy/DSC00001.xmp"),
        ], destination: "/E1")
        let batch = OrganizeApplyPlan.CopyBatch(
            sourceRoot: "/Volumes/LEXAR/DCIM",
            destinationRoot: "/E2/Card Copy",
            deviceID: "sony-a7v",
            files: [
                FileRecord(path: "DCIM/100MSDCF/DSC00003.ARW", size: 50, modifiedAt: Date()),
                FileRecord(path: "DCIM/100MSDCF/DSC00004.ARW", size: 50, modifiedAt: Date()),
            ]
        )
        let second = eventGroup(name: "Second Event", copies: [batch], destination: "/E2")
        let plan = OrganizeApplyPlan(title: "Apply", groups: [first, second], pruneBoundaries: [])

        let summaries = ApplyRouteDiagram.eventSummaries(for: plan)
        XCTAssertEqual(summaries.map(\.event.name), ["Trip 2026", "Second Event"])

        for row in summaries {
            XCTAssertEqual(row.imageCount + row.videoCount + row.otherCount, row.fileCount)
        }
        XCTAssertEqual(summaries[0].fileCount, 4)
        XCTAssertEqual(summaries[0].imageCount, 2)
        XCTAssertEqual(summaries[0].videoCount, 1)
        XCTAssertEqual(summaries[0].otherCount, 1)
        XCTAssertEqual(summaries[0].byteCount, 1_400)
        XCTAssertEqual(summaries[1].fileCount, 2)
        XCTAssertEqual(summaries[1].imageCount, 2)
        XCTAssertEqual(summaries[1].videoCount, 0)
        XCTAssertEqual(summaries[1].otherCount, 0)

        XCTAssertEqual(summaries.reduce(0) { $0 + $1.fileCount }, plan.fileCount)
        XCTAssertEqual(summaries.reduce(Int64(0)) { $0 + $1.byteCount }, plan.byteCount)
    }
}
