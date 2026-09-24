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

    func testShortPathPartsElideTheMiddleNotTheFinalFolder() {
        let parts = ApplyPathLabel.shortParts("/Volumes/Crucial/Camera Buffer/2026/2026-08-23 Long Final Folder Name")
        XCTAssertEqual(parts.lead, "Crucial ▸ … ▸ ")
        XCTAssertEqual(parts.leaf, "2026-08-23 Long Final Folder Name")
        XCTAssertEqual(parts.text, ApplyPathLabel.short("/Volumes/Crucial/Camera Buffer/2026/2026-08-23 Long Final Folder Name"))

        let whole = ApplyPathLabel.shortParts("/Volumes/Crucial/Buffer/Beach")
        XCTAssertEqual(whole, ApplyPathLabel.ShortPath(lead: "Crucial ▸ Buffer ▸ ", leaf: "Beach"))

        let full = ApplyPathLabel.shortParts("/Volumes/Crucial/Camera Buffer/2026/Beach", maxComponents: .max)
        XCTAssertEqual(full.lead, "Crucial ▸ Camera Buffer ▸ 2026 ▸ ")
        XCTAssertEqual(full.leaf, "Beach")

        XCTAssertEqual(parts.fallbackLeads, ["Crucial ▸ … ▸ ", "… ▸ "])
        XCTAssertEqual(full.fallbackLeads, ["Crucial ▸ Camera Buffer ▸ 2026 ▸ ", "Crucial ▸ … ▸ ", "… ▸ "])
        XCTAssertEqual(whole.fallbackLeads, ["Crucial ▸ Buffer ▸ ", "Crucial ▸ … ▸ ", "… ▸ "])
        XCTAssertEqual(
            ApplyPathLabel.shortParts("/Volumes/Crucial/Beach").fallbackLeads,
            ["Crucial ▸ ", "… ▸ "]
        )

        let drive = ApplyPathLabel.shortParts("/Volumes/Crucial")
        XCTAssertEqual(drive, ApplyPathLabel.ShortPath(lead: "", leaf: "Crucial"))
        XCTAssertEqual(drive.fallbackLeads, [""])
    }

    // MARK: - Sentence

    func testMoveOnlySentenceSaysNothingIsCopied() {
        let sentence = ApplyPlanOverview.sentence(
            moveCount: 40, copyCount: 0, sourceNames: ["Unsorted A7V"],
            eventCount: 2, destinationDrives: ["Buffer"]
        )
        XCTAssertEqual(
            sentence,
            "40 files move from “Unsorted A7V” into 2 events on Buffer. They are renamed on the same drive, so no files are copied or deleted."
        )
    }

    func testSingularMoveSentence() {
        let sentence = ApplyPlanOverview.sentence(
            moveCount: 1, copyCount: 0, sourceNames: ["Card"],
            eventCount: 1, destinationDrives: ["C"]
        )
        XCTAssertTrue(sentence.hasPrefix("1 file moves from “Card” into 1 event on C. It is renamed"))
    }

    func testCopyOnlySentenceKeepsOriginals() {
        let sentence = ApplyPlanOverview.sentence(
            moveCount: 0, copyCount: 12, sourceNames: ["LEXAR"],
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
            moveCount: 28, copyCount: 3, sourceNames: ["A", "B", "C", "D"],
            eventCount: 3, destinationDrives: ["A", "B"]
        )
        XCTAssertTrue(sentence.hasPrefix("28 files move and 3 are copied from 4 folders into 3 events on 2 drives."))
        XCTAssertTrue(sentence.contains("checksum-verified"))
        XCTAssertTrue(sentence.contains("originals in place"))
    }

    func testSentenceNamesEveryFolderWhenThereAreFew() {
        let two = ApplyPlanOverview.sentence(
            moveCount: 40, copyCount: 0, sourceNames: ["Folder A", "Folder B"],
            eventCount: 2, destinationDrives: ["Drive"]
        )
        XCTAssertTrue(two.hasPrefix("40 files move from “Folder A” and “Folder B” into 2 events on Drive."), two)

        XCTAssertEqual(ApplyPlanOverview.fromPhrase(sourceNames: ["A", "B", "C"]), " from “A”, “B” and “C”")
        XCTAssertEqual(ApplyPlanOverview.fromPhrase(sourceNames: ["A", "B", "C", "D"]), " from 4 folders")
        XCTAssertEqual(ApplyPlanOverview.fromPhrase(sourceNames: ["Transfer 1", "Transfer 1"]), " from 2 folders")
        XCTAssertEqual(ApplyPlanOverview.fromPhrase(sourceNames: ["A"]), " from “A”")
        XCTAssertEqual(ApplyPlanOverview.fromPhrase(sourceNames: []), "")
    }

    func testEmptySentence() {
        let sentence = ApplyPlanOverview.sentence(
            moveCount: 0, copyCount: 0, sourceNames: [],
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
        XCTAssertEqual(overview.primaryActionTitle, "Move & Copy 3 Files")
        XCTAssertTrue(
            overview.sentence.hasPrefix("2 files move and 1 is copied from “Transfer 1” and “DCIM” into 2 events on Crucial."),
            overview.sentence
        )
        XCTAssertEqual(overview.destinations.map { $0.routes.count }, [1, 1, 0])
        assertRoutesAddUp(overview)
    }

    // MARK: - Routes (many-to-many)

    private let unsorted = "/Volumes/Drive/Unsorted"
    private let eventX = "/Volumes/Drive/Buffer/2026/2026-01-02 Event X"
    private let eventY = "/Volumes/Drive/.private/2026-01-02 Subevent Y"

    private func moves(_ count: Int, from folder: String, into destination: String, prefix: String, ext: String = "ARW", bytes: Int64 = 10) -> [DriveMove] {
        (1...count).map { index in
            move("\(folder)/\(prefix)\(index).\(ext)", "\(destination)/Cam/\(prefix)\(index).\(ext)", bytes: bytes)
        }
    }

    /// Folder A (5 files) splits: 1 video to X, 4 files to Y. Folder B
    /// (35 files) all go to Y. A card on another drive copies into both.
    private func manyToManyPlan() -> OrganizeApplyPlan {
        let folderA = unsorted + "/Folder A"
        let folderB = unsorted + "/Folder B"
        let card = OrganizeApplyPlan.CopyBatch(
            sourceRoot: "/Volumes/Card/DCIM",
            destinationRoot: eventX + "/Cam",
            deviceID: "cam",
            files: [
                FileRecord(path: "DCIM/100/C1.JPG", size: 7, modifiedAt: Date()),
                FileRecord(path: "DCIM/100/C2.JPG", size: 7, modifiedAt: Date()),
            ]
        )
        let cardToY = OrganizeApplyPlan.CopyBatch(
            sourceRoot: "/Volumes/Card/DCIM",
            destinationRoot: eventY + "/Cam",
            deviceID: "cam",
            files: [FileRecord(path: "DCIM/100/C3.JPG", size: 7, modifiedAt: Date())]
        )
        let x = group(
            name: "Event X",
            moves: moves(1, from: folderA, into: eventX, prefix: "AV", ext: "MP4", bytes: 2_000),
            copies: [card],
            destination: eventX
        )
        let y = group(
            name: "Subevent Y",
            moves: moves(3, from: folderA, into: eventY, prefix: "A", bytes: 50)
                + [move(folderA + "/A4.XMP", eventY + "/Sidecars/A4.XMP", bytes: 1)]
                + moves(32, from: folderB, into: eventY, prefix: "B", bytes: 40)
                + moves(3, from: folderB, into: eventY, prefix: "BV", ext: "MP4", bytes: 100),
            copies: [cardToY],
            destination: eventY,
            isPrivate: true
        )
        return OrganizeApplyPlan(title: "Apply", groups: [x, y], pruneBoundaries: [])
    }

    /// Every route adds up to its source's total and to its event's total,
    /// and the whole set adds up to the plan.
    private func assertRoutesAddUp(_ overview: ApplyPlanOverview, file: StaticString = #filePath, line: UInt = #line) {
        for source in overview.sources {
            let routes = overview.routes.filter { $0.sourcePath == source.path }
            XCTAssertEqual(routes.reduce(0) { $0 + $1.moveCount }, source.moveCount, "moves from \(source.name)", file: file, line: line)
            XCTAssertEqual(routes.reduce(0) { $0 + $1.copyCount }, source.copyCount, "copies from \(source.name)", file: file, line: line)
            XCTAssertEqual(routes.reduce(Int64(0)) { $0 + $1.byteCount }, source.byteCount, "bytes from \(source.name)", file: file, line: line)
            XCTAssertEqual(routes.count { $0.fileCount > 0 }, source.eventCount, file: file, line: line)
            for route in routes {
                XCTAssertEqual(route.sourceFileCount, source.fileCount, file: file, line: line)
                XCTAssertEqual(route.sourceEventCount, source.eventCount, file: file, line: line)
            }
        }
        for (index, destination) in overview.destinations.enumerated() {
            let routes = destination.routes
            XCTAssertEqual(routes, overview.routes.filter { $0.destinationIndex == index }, file: file, line: line)
            let summary = destination.summary
            XCTAssertEqual(routes.reduce(0) { $0 + $1.fileCount }, summary.fileCount, "files into \(summary.event.name)", file: file, line: line)
            XCTAssertEqual(routes.reduce(0) { $0 + $1.moveCount }, destination.moveCount, file: file, line: line)
            XCTAssertEqual(routes.reduce(0) { $0 + $1.copyCount }, destination.copyCount, file: file, line: line)
            XCTAssertEqual(routes.reduce(0) { $0 + $1.photoCount }, summary.imageCount, file: file, line: line)
            XCTAssertEqual(routes.reduce(0) { $0 + $1.videoCount }, summary.videoCount, file: file, line: line)
            XCTAssertEqual(routes.reduce(0) { $0 + $1.otherCount }, summary.otherCount, file: file, line: line)
            XCTAssertEqual(routes.reduce(Int64(0)) { $0 + $1.byteCount }, summary.byteCount, "bytes into \(summary.event.name)", file: file, line: line)
        }
        XCTAssertEqual(overview.routes.reduce(0) { $0 + $1.fileCount }, overview.fileCount, file: file, line: line)
        XCTAssertEqual(overview.routes.reduce(Int64(0)) { $0 + $1.byteCount }, overview.byteCount, file: file, line: line)
    }

    func testManyToManyRoutesMatchTheRealSplit() throws {
        let overview = ApplyPlanOverview(plan: manyToManyPlan())
        assertRoutesAddUp(overview)

        let a = try XCTUnwrap(overview.sources.first { $0.name == "Folder A" })
        XCTAssertEqual(a.fileCount, 5)
        XCTAssertEqual(a.byteCount, 2_000 + 3 * 50 + 1)
        XCTAssertEqual(a.eventCount, 2)
        XCTAssertEqual(a.splitHint, "“Folder A” → 2 events")
        let b = try XCTUnwrap(overview.sources.first { $0.name == "Folder B" })
        XCTAssertEqual(b.fileCount, 35)
        XCTAssertEqual(b.eventCount, 1)
        XCTAssertNil(b.splitHint)
        let card = try XCTUnwrap(overview.sources.first { $0.name == "DCIM" })
        XCTAssertEqual(card.copyCount, 3)
        XCTAssertEqual(card.eventCount, 2)

        let x = overview.destinations[0]
        XCTAssertEqual(x.routes.map(\.sourceName), ["DCIM", "Folder A"])
        let aToX = try XCTUnwrap(x.routes.first { $0.sourceName == "Folder A" })
        XCTAssertEqual(aToX.fileCount, 1)
        XCTAssertEqual(aToX.videoCount, 1)
        XCTAssertEqual(aToX.methods, [.rename])
        XCTAssertEqual(aToX.countsLine, "1 of 5 files · \(Int64(2_000).formattedBytes)")
        XCTAssertEqual(aToX.splitHint, "“Folder A” → 2 events")
        XCTAssertEqual(x.routes.first { $0.sourceName == "DCIM" }?.methods, [.verifiedCopy])

        let y = overview.destinations[1]
        XCTAssertTrue(y.summary.isPrivate)
        XCTAssertEqual(y.routes.map(\.sourceName), ["DCIM", "Folder A", "Folder B"])
        // A's photos and its sidecar land in two subfolders but one route.
        let aToY = try XCTUnwrap(y.routes.first { $0.sourceName == "Folder A" })
        XCTAssertEqual(aToY.fileCount, 4)
        XCTAssertEqual(aToY.photoCount, 3)
        XCTAssertEqual(aToY.otherCount, 1)
        XCTAssertEqual(aToY.countsLine, "4 of 5 files · \(Int64(151).formattedBytes)")
        let bToY = try XCTUnwrap(y.routes.first { $0.sourceName == "Folder B" })
        XCTAssertEqual(bToY.countsLine, "35 files · \(Int64(32 * 40 + 300).formattedBytes)")
        XCTAssertNil(bToY.splitHint)

        XCTAssertTrue(overview.sentence.hasPrefix("40 files move and 3 are copied from “DCIM”, “Folder A” and “Folder B” into 2 events on Drive."), overview.sentence)
    }

    func testOneToOneRoute() {
        let plan = OrganizeApplyPlan(title: "Apply", groups: [
            group(name: "X", moves: moves(3, from: unsorted + "/A", into: eventX, prefix: "A"), destination: eventX),
        ], pruneBoundaries: [])
        let overview = ApplyPlanOverview(plan: plan)
        XCTAssertEqual(overview.routes.count, 1)
        XCTAssertEqual(overview.routes[0].countsLine, "3 files · \(Int64(30).formattedBytes)")
        XCTAssertNil(overview.routes[0].splitHint)
        assertRoutesAddUp(overview)
    }

    func testOneFolderToManyEvents() {
        let plan = OrganizeApplyPlan(title: "Apply", groups: [
            group(name: "X", moves: moves(2, from: unsorted + "/A", into: eventX, prefix: "A"), destination: eventX),
            group(name: "Y", moves: moves(3, from: unsorted + "/A", into: eventY, prefix: "B"), destination: eventY),
        ], pruneBoundaries: [])
        let overview = ApplyPlanOverview(plan: plan)
        XCTAssertEqual(overview.sources.count, 1)
        XCTAssertEqual(overview.routes.map(\.fileCount), [2, 3])
        XCTAssertEqual(overview.routes.map(\.destinationIndex), [0, 1])
        XCTAssertEqual(overview.routes.map(\.splitHint), ["“A” → 2 events", "“A” → 2 events"])
        XCTAssertTrue(overview.sentence.hasPrefix("5 files move from “A” into 2 events"), overview.sentence)
        assertRoutesAddUp(overview)
    }

    func testManyFoldersToOneEvent() {
        let plan = OrganizeApplyPlan(title: "Apply", groups: [
            group(
                name: "X",
                moves: moves(2, from: unsorted + "/B", into: eventX, prefix: "B")
                    + moves(1, from: unsorted + "/A", into: eventX, prefix: "A"),
                destination: eventX
            ),
        ], pruneBoundaries: [])
        let overview = ApplyPlanOverview(plan: plan)
        XCTAssertEqual(overview.destinations[0].routes.map(\.sourceName), ["A", "B"])
        XCTAssertEqual(overview.destinations[0].routes.map(\.fileCount), [1, 2])
        XCTAssertTrue(overview.routes.allSatisfy { $0.splitHint == nil })
        assertRoutesAddUp(overview)
    }

    func testRouteOverflowSumsTheHiddenRows() throws {
        let groupMoves = (1...7).flatMap { index in
            moves(index, from: "\(unsorted)/F\(index)", into: eventX, prefix: "F\(index)-")
        }
        let overview = ApplyPlanOverview(plan: OrganizeApplyPlan(
            title: "Apply", groups: [group(name: "X", moves: groupMoves, destination: eventX)], pruneBoundaries: []
        ))
        let destination = overview.destinations[0]
        let display = destination.routeDisplay(limit: 5)
        XCTAssertEqual(display.visible.count, 4)
        let overflow = try XCTUnwrap(display.overflow)
        XCTAssertEqual(overflow.folderCount, 3)
        XCTAssertEqual(display.visible.reduce(0) { $0 + $1.fileCount } + overflow.fileCount, destination.summary.fileCount)
        XCTAssertEqual(display.visible.reduce(Int64(0)) { $0 + $1.byteCount } + overflow.byteCount, destination.summary.byteCount)
        XCTAssertEqual(overflow.line, "+ 3 more folders · 18 files · \(Int64(180).formattedBytes)")

        let fits = destination.routeDisplay(limit: 7)
        XCTAssertEqual(fits.visible.count, 7)
        XCTAssertNil(fits.overflow)
    }
}
