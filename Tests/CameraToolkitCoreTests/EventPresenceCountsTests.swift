import Foundation
import XCTest
@testable import CameraToolkitCore

/// The storage strip, the sidebar rows, the inspector and the misplaced-files
/// notice all read one `EventPresenceCounts` per summary instead of walking
/// its ~15,000 rows on every render. It must agree with counting the rows
/// directly — for every state a row can be in — and follow the rows when they
/// are patched.
final class EventPresenceCountsTests: XCTestCase {
    private let states: [CatalogPresenceState] = [.unknown, .present, .missing, .unavailable]
    private let eventID = UUID()

    /// Rows covering every combination of the four places, both source
    /// flavors, legacy layouts and verification times.
    private func rows(_ count: Int) -> [EventAssetPresence] {
        (0..<count).map { index in
            let assignment = PhotoEventAssignment(
                sourceRootPath: "/card",
                relativePath: "DSC\(index).ARW",
                fileSize: 10,
                modifiedAt: Date(timeIntervalSince1970: Double(index)),
                eventID: eventID
            )
            return EventAssetPresence(
                id: "row-\(index)",
                assignment: assignment,
                sourcePath: "/card/DSC\(index).ARW",
                drivePath: "/buffer/DSC\(index).ARW",
                otherDrivePath: "/private/DSC\(index).ARW",
                archivePath: "/nas/DSC\(index).ARW",
                source: states[index % 4],
                drive: states[(index / 4) % 4],
                otherDrive: states[(index / 16) % 4],
                archive: states[(index / 64) % 4],
                sourceIsDriveCopy: index % 3 == 0,
                driveIsLegacyLayout: index % 5 == 0,
                otherDriveIsLegacyLayout: index % 7 == 0,
                archiveIsLegacyLayout: index % 11 == 0,
                archiveVerifiedAt: index % 2 == 0 ? Date(timeIntervalSince1970: 1_000 + Double(index % 13)) : nil
            )
        }
    }

    func testCountsAgreeWithCountingTheRowsDirectly() {
        let assets = rows(600)
        let counts = EventPresenceCounts(assets)
        let separate = assets.filter { !$0.sourceIsDriveCopy }
        XCTAssertEqual(counts.total, assets.count)
        XCTAssertEqual(counts.separateSource, separate.count)
        XCTAssertEqual(counts.onSource, separate.count { $0.source == .present })
        XCTAssertEqual(counts.sourceOffline, separate.count { $0.source == .unavailable })
        XCTAssertEqual(counts.freeable, separate.count { $0.source == .present && $0.drive == .present })
        XCTAssertEqual(counts.onDrive, assets.count { $0.drive == .present })
        XCTAssertEqual(counts.onOtherDrive, assets.count { $0.otherDrive == .present })
        XCTAssertEqual(counts.needsDrive, assets.count { $0.drive != .present && ($0.otherDrive == .present || $0.isOnSeparateSource) })
        XCTAssertEqual(counts.removable, assets.count { ($0.drive == .present || $0.otherDrive == .present) && $0.archiveIsTrusted })
        XCTAssertEqual(counts.onEitherDrive, assets.count { $0.drive == .present || $0.otherDrive == .present })
        XCTAssertEqual(counts.driveOffline, assets.contains { $0.drive == .unavailable })
        XCTAssertEqual(counts.onArchive, assets.count { $0.archive == .present })
        XCTAssertEqual(counts.onLegacyLayout, assets.count { ($0.drive == .present && $0.driveIsLegacyLayout) || ($0.otherDrive == .present && $0.otherDriveIsLegacyLayout) })
        XCTAssertEqual(counts.onLegacyArchiveLayout, assets.count { $0.archive == .present && $0.archiveIsLegacyLayout })
        XCTAssertEqual(counts.verifiedOnArchive, assets.count { $0.archive == .present && $0.archiveVerifiedAt != nil })
        XCTAssertEqual(counts.oldestArchiveVerification, assets.compactMap { $0.archive == .present ? $0.archiveVerifiedAt : nil }.min())
        XCTAssertEqual(counts.archiveOffline, assets.contains { $0.archive == .unavailable })
        XCTAssertEqual(counts.missingEverywhere, assets.count { $0.bestLocalPath == nil })
        XCTAssertGreaterThan(counts.onSource, 0)
        XCTAssertGreaterThan(counts.onLegacyLayout, 0)
        XCTAssertGreaterThan(counts.onLegacyArchiveLayout, 0)
        XCTAssertGreaterThan(counts.verifiedOnArchive, 0)
    }

    func testTheSummaryReadsItsCountsAndTheyFollowPatchedRows() {
        var summary = EventPresenceSummary(eventID: eventID, policy: .buffer, assets: rows(200), checkedAt: Date())
        XCTAssertEqual(summary.total, 200)
        XCTAssertEqual(summary.counts, EventPresenceCounts(summary.assets))
        XCTAssertEqual(summary.onDrive, summary.assets.count { $0.drive == .present })

        // A move patches rows: the counts follow without anyone recounting.
        var patched = summary.assets
        patched.removeLast(20)
        for index in patched.indices.prefix(30) {
            patched[index].archive = .present
            patched[index].archiveVerifiedAt = nil
        }
        summary.assets = patched
        XCTAssertEqual(summary.total, 180)
        XCTAssertEqual(summary.counts, EventPresenceCounts(patched))
        XCTAssertEqual(summary.onArchive, patched.count { $0.archive == .present })
        XCTAssertEqual(summary.verifiedOnArchive, patched.count { $0.archive == .present && $0.archiveVerifiedAt != nil })
    }

    func testAnEmptySummaryCountsNothing() {
        let summary = EventPresenceSummary(eventID: eventID, policy: .buffer, assets: [], checkedAt: Date())
        XCTAssertEqual(summary.counts, EventPresenceCounts())
        XCTAssertFalse(summary.driveOffline)
        XCTAssertFalse(summary.archiveOffline)
        XCTAssertNil(summary.oldestArchiveVerification)
    }
}
