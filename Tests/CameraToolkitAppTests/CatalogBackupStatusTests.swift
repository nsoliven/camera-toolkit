@testable import CameraToolkitApp
import CameraToolkitCore
import XCTest

@MainActor
final class CatalogBackupStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testDescribesLocalAndNAS() {
        let summary = CatalogBackupSummary(
            lastLocal: now - 3600, lastRemote: now - 3600,
            remoteReachable: true, remoteConfigured: true, lastError: nil, lastErrorAt: nil
        )
        XCTAssertTrue(DashboardModel.catalogBackupDescription(summary, now: now).hasSuffix("local and NAS"))
        XCTAssertNil(DashboardModel.catalogBackupWarning(summary, now: now))
    }

    func testOfflineNASIsDescribedWithoutAlarm() {
        let summary = CatalogBackupSummary(
            lastLocal: now - 3600, lastRemote: now - 3 * 86_400,
            remoteReachable: false, remoteConfigured: true, lastError: nil, lastErrorAt: nil
        )
        XCTAssertTrue(DashboardModel.catalogBackupDescription(summary, now: now).hasSuffix("NAS offline"))
        XCTAssertNil(DashboardModel.catalogBackupWarning(summary, now: now))
    }

    func testWarnsWhenStaleFailedOrMissing() {
        let stale = CatalogBackupSummary(
            lastLocal: now - 3 * 86_400, lastRemote: nil,
            remoteReachable: false, remoteConfigured: false, lastError: nil, lastErrorAt: nil
        )
        XCTAssertNotNil(DashboardModel.catalogBackupWarning(stale, now: now))
        var failed = stale
        failed.lastLocal = now
        failed.lastError = "disk full"
        XCTAssertEqual(DashboardModel.catalogBackupWarning(failed, now: now), "The last backup attempt failed: disk full")
        let never = CatalogBackupSummary(
            lastLocal: nil, lastRemote: nil,
            remoteReachable: false, remoteConfigured: false, lastError: nil, lastErrorAt: nil
        )
        XCTAssertEqual(DashboardModel.catalogBackupDescription(never, now: now), "No verified backup yet.")
        XCTAssertEqual(DashboardModel.catalogBackupWarning(never, now: now), "The photo list has never been backed up.")
    }
}
