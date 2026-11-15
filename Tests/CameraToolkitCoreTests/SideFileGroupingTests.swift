@testable import CameraToolkitCore
import Foundation
import XCTest

/// Side files share their photo's tile. That is display only: pairing,
/// planners, Sync and removal below all still treat each one as a file.
final class SideFileGroupingTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    private func file(_ name: String, size: Int64 = 10, modifiedAt: Date? = nil) -> OrganizeFile {
        OrganizeFile(path: "/Card/\(name)", size: size, modifiedAt: modifiedAt ?? day)
    }

    private func byPrimary(_ pairings: [OrganizeFileClassifier.Pairing]) -> [String: OrganizeFileClassifier.Pairing] {
        Dictionary(uniqueKeysWithValues: pairings.map { ($0.primary.name, $0) })
    }

    private func ownership(_ owners: [(OrganizeFile, UUID)]) -> SideFileOwnership {
        SideFileOwnership(owners: Dictionary(uniqueKeysWithValues: owners.map {
            ($0.0.pathKey, SideFileOwnership.Owner(eventID: $0.1, fileSize: $0.0.size))
        }))
    }

    // MARK: Pairing

    func testScreenPreviewAndTelemetryJoinTheirClip() {
        let clip = file("CAM_0001_D.OSV")
        let pairings = OrganizeFileClassifier.pair([
            clip, file("CAM_0001_D.SCR"), file("CAM_0001_D.LRF"), file("CAM_0001_D.THM"), file("CAM_0001_D.MET")
        ])
        XCTAssertEqual(pairings.count, 1)
        XCTAssertEqual(pairings[0].primary, clip)
        XCTAssertEqual(pairings[0].kind, .video)
        XCTAssertEqual(pairings[0].companions.map(\.name), ["CAM_0001_D.LRF", "CAM_0001_D.MET", "CAM_0001_D.SCR", "CAM_0001_D.THM"])
    }

    func testAFinderClippingJoinsThePhotoOfItsName() {
        let pairings = OrganizeFileClassifier.pair([file("clip (1).jpg"), file("clip (1).textClipping")])
        XCTAssertEqual(pairings.count, 1)
        XCTAssertEqual(pairings[0].companions.map(\.name), ["clip (1).textClipping"])
    }

    func testASideFileWithNoPartnerKeepsItsOwnItem() {
        let pairings = OrganizeFileClassifier.pair([file("CAM_0002_D.SCR"), file("CAM_0003_D.MET"), file("DSC00001.ARW")])
        XCTAssertEqual(pairings.map(\.primary.name), ["CAM_0002_D.SCR", "CAM_0003_D.MET", "DSC00001.ARW"])
        XCTAssertEqual(pairings[0].kind, .other)
    }

    func testAPartnerInAnotherFolderDoesNotCombine() {
        let pairings = OrganizeFileClassifier.pair([
            OrganizeFile(path: "/Card/A/CAM_0001_D.OSV", size: 1, modifiedAt: day),
            OrganizeFile(path: "/Card/B/CAM_0001_D.SCR", size: 1, modifiedAt: day)
        ])
        XCTAssertEqual(pairings.count, 2)
    }

    func testAScreenPreviewWithNoClipTakesItsLeftoverSideFilesIntoOneTile() {
        let pairing = byPrimary(OrganizeFileClassifier.pair([file("CAM_0004_D.SCR"), file("CAM_0004_D.THM"), file("CAM_0005_D.THM")]))
        XCTAssertEqual(pairing.count, 2)
        XCTAssertEqual(pairing["CAM_0004_D.SCR"]?.companions.map(\.name), ["CAM_0004_D.THM"])
        XCTAssertEqual(pairing["CAM_0004_D.SCR"]?.kind, .other)
        XCTAssertEqual(pairing["CAM_0005_D.THM"]?.companions, [])
    }

    func testRealMediaBesideAClipIsNeverASideFile() {
        for name in ["CAM_0001_D.JPG", "CAM_0001_D.ARW", "CAM_0001_D.HIF", "CAM_0001_D.WAV", "CAM_0001_D.html"] {
            XCTAssertFalse(OrganizeFileClassifier.companionExtensions.contains(file(name).fileExtension), name)
        }
    }

    func testHIFIsAPhotoAloneAndATwinBesideARAW() {
        XCTAssertEqual(OrganizeFileClassifier.kind(forExtension: "HIF"), .photo)
        XCTAssertTrue(CaptureDateReader.canRead(URL(fileURLWithPath: "/Card/DSC00001.HIF")))
        XCTAssertEqual(OrganizeFileClassifier.pair([file("DSC00001.HIF")])[0].kind, .photo)
        let pairing = OrganizeFileClassifier.pair([file("DSC00002.ARW"), file("DSC00002.HIF")])
        XCTAssertEqual(pairing.count, 1)
        XCTAssertEqual(pairing[0].primary.name, "DSC00002.ARW")
        XCTAssertEqual(pairing[0].companions.map(\.name), ["DSC00002.HIF"])
    }

    // MARK: Existing assignments, decided at read time

    func testDifferentEventsStaySeparate() {
        let clip = file("CAM_0001_D.OSV"), preview = file("CAM_0001_D.SCR")
        let rules = ownership([(clip, UUID()), (preview, UUID())])
        let pairings = OrganizeFileClassifier.pair([clip, preview], keepApart: rules.keepsApart)
        XCTAssertEqual(pairings.map(\.primary.name).sorted(), ["CAM_0001_D.OSV", "CAM_0001_D.SCR"])
        XCTAssertTrue(pairings.allSatisfy(\.companions.isEmpty))
    }

    func testASortedClipDoesNotSwallowAnUnsortedPreview() {
        let clip = file("CAM_0001_D.OSV"), preview = file("CAM_0001_D.SCR")
        let rules = ownership([(clip, UUID())])
        XCTAssertEqual(OrganizeFileClassifier.pair([clip, preview], keepApart: rules.keepsApart).count, 2)
    }

    func testTheSameEventAndNoEventBothCombine() {
        let clip = file("CAM_0001_D.OSV"), preview = file("CAM_0001_D.SCR")
        let event = UUID()
        let same = ownership([(clip, event), (preview, event)])
        XCTAssertEqual(OrganizeFileClassifier.pair([clip, preview], keepApart: same.keepsApart).count, 1)
        XCTAssertEqual(OrganizeFileClassifier.pair([clip, preview], keepApart: SideFileOwnership().keepsApart).count, 1)
    }

    func testAReusedCardNumberIsNotTheOldFilesAssignment() {
        let clip = file("CAM_0001_D.OSV"), preview = file("CAM_0001_D.SCR", size: 99)
        let event = UUID()
        let stale = SideFileOwnership(owners: [
            clip.pathKey: .init(eventID: event, fileSize: clip.size),
            preview.pathKey: .init(eventID: event, fileSize: 5)
        ])
        XCTAssertNil(stale.owner(of: preview))
        XCTAssertEqual(OrganizeFileClassifier.pair([clip, preview], keepApart: stale.keepsApart).count, 2)
    }

    func testAlwaysCombinedSidecarsAreNotDrawnApart() {
        let clip = file("CAM_0001_D.OSV"), proxy = file("CAM_0001_D.LRF")
        let rules = ownership([(clip, UUID())])
        XCTAssertEqual(OrganizeFileClassifier.pair([clip, proxy], keepApart: rules.keepsApart).count, 1)
    }

    func testAHIFInAnotherEventThanItsRAWStaysSeparate() {
        let raw = file("DSC00001.ARW"), twin = file("DSC00001.HIF")
        let rules = ownership([(raw, UUID()), (twin, UUID())])
        XCTAssertEqual(OrganizeFileClassifier.pair([raw, twin], keepApart: rules.keepsApart).count, 2)
    }

    func testLeftoverSideFilesInDifferentEventsStaySeparate() {
        let preview = file("CAM_0004_D.SCR"), thumb = file("CAM_0004_D.THM")
        let rules = ownership([(preview, UUID()), (thumb, UUID())])
        XCTAssertEqual(OrganizeFileClassifier.pair([preview, thumb], keepApart: rules.keepsApart).count, 2)
    }

    // MARK: Date, counts and sizes

    func testTheCombinedTileTakesItsPrimarysDateAndCountsEveryByte() {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let end = start.addingTimeInterval(900)
        let built = OrganizeScanner.items(
            for: [file("CAM_0001_D.OSV", size: 1_000, modifiedAt: end), file("CAM_0001_D.SCR", size: 7, modifiedAt: start)],
            cache: nil
        ).items
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built[0].captureDate, end)
        XCTAssertEqual(built[0].byteCount, 1_007)
        let stacks = OrganizeStacker.stacks(for: built)
        XCTAssertEqual(stacks.first?.fileCount, 2)
        let day = OrganizeStacker.days(for: stacks).first
        XCTAssertEqual(day?.frameCount, 1)
        XCTAssertEqual(day?.byteCount, 1_007)
    }

    // MARK: Files that stay when their partner leaves

    func testASurvivingCompanionBecomesItsOwnItem() {
        let clip = file("CAM_0001_D.OSV"), preview = file("CAM_0001_D.SCR"), twin = file("CAM_0001_D.JPG")
        let item = OrganizeItem(primary: clip, companions: [preview, twin], kind: .video, captureDate: day, hasCameraDate: false)
        let left = item.removingFiles { $0 == clip }
        XCTAssertEqual(left.map(\.primary), [preview, twin])
        XCTAssertEqual(left.map(\.kind), [.other, .photo])
        XCTAssertEqual(item.removingFiles { $0 == preview }.first?.companions, [twin])
        XCTAssertEqual(item.removingFiles { _ in true }, [])
    }

    func testRemovingAScannedClipLeavesItsPreviewOnTheBoard() {
        let clip = file("CAM_0001_D.OSV"), preview = file("CAM_0001_D.SCR")
        let items = OrganizeScanner.items(for: [clip, preview], cache: nil).items
        let stacks = OrganizeStacker.stacks(for: items)
        let result = OrganizeScanResult(
            rootPath: "/Card", items: items, stacks: stacks, days: OrganizeStacker.days(for: stacks),
            duplicateNames: [], clockOffset: 0, scannedAt: day
        )
        let after = result.removingFiles(withPathKeys: [clip.pathKey])
        XCTAssertEqual(after.items.map(\.primary.name), ["CAM_0001_D.SCR"])
        XCTAssertEqual(after.stacks.count, 1)
    }

    // MARK: Layout migrations

    func testBothMigrationPlannersCallSideFilesSidecars() {
        for name in ["CAM_0001_D.SCR", "CAM_0001_D.MET", "clip (1).textClipping", "CAM_0001_D.LRF", "DSC00001.xmp"] {
            XCTAssertEqual(LayoutMigrationPlanner.kind(of: name), .sidecar, name)
            XCTAssertEqual(NASLayoutMigrationPlanner.kind(of: name), .sidecar, name)
        }
        XCTAssertEqual(LayoutMigrationPlanner.kind(of: "DSC00001.HIF"), .media)
        XCTAssertEqual(NASLayoutMigrationPlanner.kind(of: "DSC00001.HIF"), .media)
    }

    // MARK: NAS

    func testSyncCopiesVerifiesAndCountsAPreviewLikeAnyOtherFile() throws {
        try withTemporaryDirectory { root in
            let world = try NASSafetyWorld.make(root.resolvingSymlinksInPath())
            let clip = NASSafetyFixtures.bytes(1), preview = NASSafetyFixtures.bytes(2, 300)
            try writeFile(world.drivePath(world.a, "CAM_0001_D.OSV"), clip)
            try writeFile(world.drivePath(world.a, "CAM_0001_D.SCR"), preview)

            let plan = world.plan()
            XCTAssertEqual(plan.items.map { ($0.relativePath as NSString).lastPathComponent }.sorted(), ["CAM_0001_D.OSV", "CAM_0001_D.SCR"])

            let before = NASPresenceIndex.report(plan: plan, records: [:], listing: nil)
            XCTAssertEqual(before.total.pendingFiles, 2, "Sync All counts the preview")

            let report = try world.sync()
            XCTAssertEqual(report.failed.count, 0)
            let relative = world.mirror(world.a, "CAM_0001_D.SCR")
            XCTAssertTrue(world.exists(relative))
            let record = try XCTUnwrap(world.record(relative))
            XCTAssertEqual(record.state, .verified)
            XCTAssertEqual(record.sha256, NASSafetyFixtures.sha(preview))
            XCTAssertNotNil(record.verifiedAt)
            XCTAssertEqual(try Data(contentsOf: world.nas.appendingPathComponent(relative)), preview)
        }
    }
}
