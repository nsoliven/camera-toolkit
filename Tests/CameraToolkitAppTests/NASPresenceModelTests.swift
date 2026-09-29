import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

/// Sync All to NAS's numbers: when the background check lists the NAS,
/// what it counts, and the words the sidebar and confirmation show.
@MainActor
final class NASPresenceModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Throttle

    func testScheduleListsOnceThenThrottlesAutomaticTriggers() {
        func decide(_ trigger: NASPresenceTrigger, last: Date?, at now: Date, available: Bool = true, job: Bool = false, checking: Bool = false) -> NASPresenceSchedule.Decision {
            NASPresenceSchedule.decide(trigger: trigger, now: now, lastListingAttempt: last, nasAvailable: available, nasJobRunning: job, isChecking: checking)
        }
        // Never listed: any trigger lists.
        XCTAssertEqual(decide(.boardOpened, last: nil, at: t0), .list)
        XCTAssertEqual(decide(.mounted, last: nil, at: t0), .list)
        // Listed a minute ago: automatic triggers wait out the interval…
        let minuteAgo = t0.addingTimeInterval(-60)
        XCTAssertEqual(decide(.mounted, last: minuteAgo, at: t0), .skip("Checked 1 min ago."))
        XCTAssertEqual(decide(.boardOpened, last: minuteAgo, at: t0), .skip("Checked 1 min ago."))
        XCTAssertEqual(decide(.jobFinished, last: minuteAgo, at: t0), .skip("Checked 1 min ago."))
        XCTAssertEqual(decide(.launch, last: minuteAgo, at: t0), .skip("Checked 1 min ago."))
        // … Check Again and a finished sync do not.
        XCTAssertEqual(decide(.manual, last: minuteAgo, at: t0), .list)
        XCTAssertEqual(decide(.syncFinished, last: minuteAgo, at: t0), .list)
        XCTAssertEqual(decide(.mounted, last: t0.addingTimeInterval(-NASPresenceSchedule.automaticInterval), at: t0), .list)
        // A NAS job or a running check always waits — even Check Again.
        XCTAssertEqual(decide(.manual, last: nil, at: t0, job: true), .wait)
        XCTAssertEqual(decide(.syncFinished, last: nil, at: t0, checking: true), .wait)
        // An offline NAS is never listed.
        XCTAssertEqual(decide(.manual, last: nil, at: t0, available: false), .skip("The NAS is not connected."))
    }

    func testRecountsWithoutListingOnlyWhenDriveFilesMayHaveChanged() {
        XCTAssertTrue(NASPresenceTrigger.launch.recountsWithoutListing)
        XCTAssertTrue(NASPresenceTrigger.jobFinished.recountsWithoutListing)
        XCTAssertFalse(NASPresenceTrigger.boardOpened.recountsWithoutListing)
        XCTAssertFalse(NASPresenceTrigger.mounted.recountsWithoutListing)
    }

    func testWaitingRequestsMergeToTheBroaderScopeAndStrongerTrigger() {
        let a = SavedCameraEvent(name: "A", eventDate: t0)
        let b = SavedCameraEvent(name: "B", eventDate: t0)
        typealias Request = NASPresenceModel.Request
        let scoped = Request(trigger: .syncFinished, scope: [a]).merged(with: Request(trigger: .boardOpened, scope: [b, a]))
        XCTAssertEqual(scoped.trigger, .syncFinished)
        XCTAssertEqual(scoped.scope?.map(\.id), [a.id, b.id])
        let everything = Request(trigger: .syncFinished, scope: [a]).merged(with: Request(trigger: .mounted, scope: nil))
        XCTAssertNil(everything.scope)
        XCTAssertEqual(Request(trigger: .jobFinished, scope: nil).merged(with: Request(trigger: .manual, scope: nil)).trigger, .manual)
    }

    // MARK: Words

    func testBadgeAndDetailText() {
        XCTAssertEqual(NASPendingText.badge(7), "7")
        XCTAssertEqual(NASPendingText.badge(999), "999")
        XCTAssertEqual(NASPendingText.badge(1_000), "1k")
        XCTAssertEqual(NASPendingText.badge(1_250), "1.2k")
        XCTAssertEqual(NASPendingText.badge(12_345), "12k")
        XCTAssertEqual(NASPendingText.files(1), "1 file")

        XCTAssertEqual(NASPendingText.syncAllDetail(report: nil, isChecking: true, nasAvailable: true), "Checking what is not on the NAS…")
        XCTAssertEqual(NASPendingText.syncAllDetail(report: nil, isChecking: false, nasAvailable: false), "NAS not connected")

        var listed = NASPresenceReport(listedAt: t0, method: .ssh)
        listed.total.files = 400
        listed.total.pendingFiles = 312
        listed.total.pendingBytes = 48_000_000_000
        XCTAssertEqual(NASPendingText.syncAllDetail(report: listed, isChecking: false, nasAvailable: true), "312 files · \(Int64(48_000_000_000).formattedBytes) not on NAS")

        // Records only: nothing listed the NAS, so "not verified" is all we know.
        var recordsOnly = listed
        recordsOnly.listedAt = nil
        recordsOnly.total.unknownFiles = 312
        XCTAssertTrue(NASPendingText.syncAllDetail(report: recordsOnly, isChecking: false, nasAvailable: false).hasSuffix("not verified on NAS"))

        var synced = NASPresenceReport(listedAt: t0, method: .smb)
        synced.total.files = 10
        synced.total.verifiedFiles = 10
        XCTAssertEqual(NASPendingText.syncAllDetail(report: synced, isChecking: false, nasAvailable: true), "Everything is on the NAS")
        synced.total.differentFiles = 2
        XCTAssertEqual(NASPendingText.syncAllDetail(report: synced, isChecking: false, nasAvailable: true), "2 files differ on the NAS")

        XCTAssertEqual(NASPendingText.freshness(listed, now: t0.addingTimeInterval(5 * 60 + 5)), "listed on the NAS over SSH 5 min ago")
        XCTAssertEqual(NASPendingText.freshness(synced, now: t0), "listed over SMB just now")
        XCTAssertTrue(NASPendingText.freshness(recordsOnly, now: t0).contains("records"))
    }

    func testConfirmationRowsListOnlyEventsWithWorkMostBytesFirst() {
        let small = SavedCameraEvent(name: "Small", eventDate: t0)
        let big = SavedCameraEvent(name: "Big", eventDate: t0)
        var secret = SavedCameraEvent(name: "Secret", eventDate: t0)
        secret.storagePolicy = .archiveOnly
        let done = SavedCameraEvent(name: "Done", eventDate: t0)
        func totals(pending: Int, bytes: Int64, different: Int = 0) -> NASPresenceTotals {
            var totals = NASPresenceTotals()
            totals.files = pending + different + 1
            totals.pendingFiles = pending
            totals.pendingBytes = bytes
            totals.differentFiles = different
            totals.verifiedFiles = 1
            return totals
        }
        let report = NASPresenceReport(byEvent: [
            small.id: totals(pending: 3, bytes: 30),
            big.id: totals(pending: 1, bytes: 9_000),
            secret.id: totals(pending: 0, bytes: 0, different: 2),
            done.id: totals(pending: 0, bytes: 0),
        ])
        let rows = NASSyncAllRow.rows(report: report, events: [small, big, secret, done], title: \.name, isPrivate: { $0.storagePolicy == .archiveOnly })
        XCTAssertEqual(rows.map(\.title), ["Big", "Small", "Secret"])
        XCTAssertEqual(rows.last?.isPrivate, true)
        XCTAssertEqual(rows.last?.differentFiles, 2)
    }

    // MARK: The model

    private struct Fixture {
        var root: URL
        var configuration: AppConfiguration
        var locations: EventStorageLocations
        var event: SavedCameraEvent
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NASPresenceModelTests-\(UUID().uuidString)", isDirectory: true)
        let event = SavedCameraEvent(name: "Trip", eventDate: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-26T12:00:00Z")))
        let configuration = AppConfiguration(
            demoRootPath: root.path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path,
            bufferPath: root.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: root.appendingPathComponent("Library").path,
            catalogDatabasePath: root.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path,
            savedEvents: [event]
        )
        let locations = EventStorageLocations(configuration: configuration)
        let originals = locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locations.nasRoot, withIntermediateDirectories: true)
        for (name, size) in [("A.ARW", 10), ("B.ARW", 20), ("C.ARW", 30)] {
            try Data(repeating: 1, count: size).write(to: originals.appendingPathComponent(name))
        }
        // A.ARW is on the NAS already; C.ARW is there with another size.
        let nasOriginals = locations.nasOriginalsRoot(for: event, deviceID: "sony-a7v")
        try FileManager.default.createDirectory(at: nasOriginals, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: nasOriginals.appendingPathComponent("A.ARW"))
        try Data(repeating: 2, count: 31).write(to: nasOriginals.appendingPathComponent("C.ARW"))
        return Fixture(root: root, configuration: configuration, locations: locations, event: event)
    }

    private final class Flags: @unchecked Sendable {
        var available = true
        var jobRunning = false
    }

    private func model(_ f: Fixture, flags: Flags) -> NASPresenceModel {
        let presence = NASPresenceModel()
        presence.isEnabled = true
        presence.context = {
            NASPresenceContext(
                events: f.configuration.savedEvents,
                locations: f.locations,
                catalogURL: URL(fileURLWithPath: f.configuration.catalogDatabasePath),
                configuration: f.configuration,
                nasAvailable: flags.available,
                nasJobRunning: flags.jobRunning
            )
        }
        return presence
    }

    private func settle(_ presence: NASPresenceModel) async throws {
        for _ in 0..<500 where presence.isChecking {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(presence.isChecking, "the check finished")
    }

    func testLaunchCountsFromTheListingAndBoardOpensDoNotRelist() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let flags = Flags()
        let presence = model(f, flags: flags)
        var changes = 0
        presence.onReportChanged = { _, _ in changes += 1 }

        presence.refresh(.launch)
        XCTAssertTrue(presence.isChecking)
        try await settle(presence)
        let report = try XCTUnwrap(presence.report)
        XCTAssertEqual(report.byEvent[f.event.id]?.pendingFiles, 1, "B.ARW")
        XCTAssertEqual(report.byEvent[f.event.id]?.pendingBytes, 20)
        XCTAssertEqual(report.byEvent[f.event.id]?.differentFiles, 1, "C.ARW")
        XCTAssertEqual(report.byEvent[f.event.id]?.unverifiedFiles, 1, "A.ARW")
        XCTAssertEqual(report.method, .smb)
        XCTAssertNotNil(presence.boardListing())
        XCTAssertEqual(changes, 1)

        // Opening a board right after is throttled: no second check.
        presence.refresh(.boardOpened)
        XCTAssertFalse(presence.isChecking)
        XCTAssertEqual(changes, 1)
    }

    func testOfflineLaunchCountsFromRecordsThenListsOnMount() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let flags = Flags()
        flags.available = false
        let presence = model(f, flags: flags)

        presence.refresh(.launch)
        try await settle(presence)
        let offline = try XCTUnwrap(presence.report)
        XCTAssertNil(offline.listedAt)
        XCTAssertEqual(offline.total.pendingFiles, 3, "nothing verified yet: all not verified on the NAS")
        XCTAssertNil(presence.boardListing())

        // The NAS mounts: never listed yet, so it lists now.
        flags.available = true
        presence.refresh(.mounted)
        XCTAssertTrue(presence.isChecking)
        try await settle(presence)
        XCTAssertEqual(presence.report?.total.pendingFiles, 1)
        XCTAssertNotNil(presence.report?.listedAt)
    }

    func testAJobDefersTheCheckUntilItFinishes() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let flags = Flags()
        flags.jobRunning = true
        let presence = model(f, flags: flags)

        presence.refresh(.manual)
        XCTAssertFalse(presence.isChecking, "never competes with a running job")
        XCTAssertNil(presence.report)

        flags.jobRunning = false
        presence.jobFinished(.organize)
        XCTAssertTrue(presence.isChecking, "the waiting Check Again runs once the job ends")
        try await settle(presence)
        XCTAssertEqual(presence.report?.total.pendingFiles, 1)

        // A starting job stops a running check; it runs again afterwards.
        presence.refresh(.manual)
        XCTAssertTrue(presence.isChecking)
        presence.pauseForJob()
        XCTAssertFalse(presence.isChecking)
        presence.jobFinished(.organize)
        XCTAssertTrue(presence.isChecking)
        try await settle(presence)
    }

    func testSyncedFilesCountAtOnceAndBoardListingGoesStale() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let flags = Flags()
        let clock = Clock(t0)
        let presence = model(f, flags: flags)
        presence.now = { clock.now }
        presence.refresh(.launch)
        try await settle(presence)
        let listing = try XCTUnwrap(presence.listing)
        let relative = "2026/2026-08-26 Trip/Originals/Sony A7V/B.ARW"
        XCTAssertTrue(listing.covers(relative))
        XCTAssertNil(listing.entry(relative))

        XCTAssertEqual(presence.report?.total.pendingFiles, 1)
        presence.noteSynced([NASSyncItem(sourcePath: "/drive/B.ARW", relativePath: relative, byteCount: 20, modifiedAt: 0, eventID: f.event.id)])
        XCTAssertEqual(presence.listing?.entry(relative)?.size, 20)
        // Recounted from the patched listing, without listing the NAS.
        XCTAssertTrue(presence.isChecking)
        try await settle(presence)
        XCTAssertEqual(presence.report?.total.pendingFiles, 0)
        XCTAssertEqual(presence.report?.listedAt, t0, "the listing was not taken again")

        clock.now = t0.addingTimeInterval(NASPresenceSchedule.boardTrust + 1)
        XCTAssertNil(presence.boardListing(), "an old listing is not trusted by the board")
    }

    func testWorkspaceKeepsTheCheckInertUntilTheAppStartsIt() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let model = DashboardModel(
            jobs: [],
            configuration: f.configuration,
            configurationStore: ConfigurationStore(url: f.root.appendingPathComponent("config.json"))
        )
        let workspace = EventsWorkspace(model: model, supportFolder: f.root.appendingPathComponent("Support", isDirectory: true))
        workspace.refreshConnectivity()
        workspace.selection = .event(f.event.id)
        XCTAssertFalse(workspace.nasPresence.isEnabled)
        XCTAssertFalse(workspace.nasPresence.isChecking)
        XCTAssertNil(workspace.nasPendingTotals(for: f.event.id))
    }

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
}
