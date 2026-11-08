import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

/// The workspace's NAS connection stays inert in tests: nothing mounts,
/// unmounts, or probes until the app shell starts it.
@MainActor
final class NASConnectionModelTests: XCTestCase {
    private func makeWorkspace() throws -> (EventsWorkspace, DashboardModel, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NASConnectionModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = AppConfiguration(
            demoRootPath: root.path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path,
            bufferPath: root.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: root.appendingPathComponent("Library").path,
            nasSMBURL: "smb://someone@nas.example/CTTestNAS",
            catalogDatabasePath: root.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path
        )
        let model = DashboardModel(
            jobs: [],
            configuration: configuration,
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
        )
        let workspace = EventsWorkspace(model: model, supportFolder: root.appendingPathComponent("Support", isDirectory: true))
        return (workspace, model, root)
    }

    func testNotStartedUntilTheShellStartsIt() throws {
        let (workspace, _, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.refreshConnectivity()
        XCTAssertFalse(workspace.nasConnection.isStarted)
        XCTAssertEqual(workspace.nasConnection.status.phase, .notConfigured)
        XCTAssertEqual(workspace.nasConnectionSettings.shareURL?.host(), "nas.example")
        XCTAssertTrue(workspace.nasConnectionSettings.automatic, "on by default")
    }

    func testANASJobStartsAtOnceWhenNothingNeedsFixing() throws {
        let (workspace, _, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        var started = false
        workspace.nasConnection.prepareForNASJob { started = true }
        XCTAssertTrue(started, "no reconnect pending: the job must not wait")
    }

    func testAnyRunningJobCountsAsUsingTheNAS() throws {
        let (workspace, model, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(workspace.nasIsInUse)
        XCTAssertFalse(workspace.nasConnection.isNASInUse())
        model.isBusy = true
        XCTAssertTrue(workspace.nasIsInUse)
        XCTAssertTrue(workspace.nasConnection.isNASInUse())
        model.isBusy = false
        model.isStorageBenchmarkRunning = true
        XCTAssertTrue(workspace.nasIsInUse)
    }

    func testAutoConnectSettingRoundTripsAndDefaultsOn() throws {
        var configuration = AppConfiguration(demoRootPath: "/tmp", importSourcePath: "", archivePath: "", bufferPath: "", activityLogPath: "")
        XCTAssertTrue(configuration.nasAutoConnect)
        configuration.nasAutoConnect = false
        let data = try JSONEncoder().encode(configuration)
        XCTAssertFalse(try JSONDecoder().decode(AppConfiguration.self, from: data).nasAutoConnect)
        // A configuration from before the setting turns it on.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "nasAutoConnect")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(try JSONDecoder().decode(AppConfiguration.self, from: legacy).nasAutoConnect)
    }

    func testAutoSwitchSettingRoundTripsDefaultsOnAndReachesTheController() throws {
        var configuration = AppConfiguration(demoRootPath: "/tmp", importSourcePath: "", archivePath: "", bufferPath: "", activityLogPath: "")
        XCTAssertTrue(configuration.nasAutoSwitchLink)
        configuration.nasAutoSwitchLink = false
        let data = try JSONEncoder().encode(configuration)
        XCTAssertFalse(try JSONDecoder().decode(AppConfiguration.self, from: data).nasAutoSwitchLink)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "nasAutoSwitchLink")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(try JSONDecoder().decode(AppConfiguration.self, from: legacy).nasAutoSwitchLink, "on for configurations from before the setting")

        let (workspace, model, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(workspace.nasConnectionSettings.autoSwitchLink)
        model.updateConfiguration { $0.nasAutoSwitchLink = false }
        XCTAssertFalse(workspace.nasConnectionSettings.autoSwitchLink)
        XCTAssertTrue(workspace.nasConnectionSettings.automatic, "auto-connect is its own setting")
    }

    // MARK: job boundaries

    /// A status whose route moved to Ethernet while the share is on Wi-Fi.
    private func pendingSwitchStatus(pending: Bool = true) -> NASConnectionStatus {
        var status = NASConnectionStatus()
        status.phase = .connected
        status.snapshot = NASConnectionSnapshot(
            mountPoint: "/Volumes/CTTestNAS",
            mount: .mounted(NASMountSource(host: "nas.example", share: "CTTestNAS")),
            sessionInterfaces: [NASNetworkInterface(bsdName: "en0", kind: .wifi)],
            routeInterface: NASNetworkInterface(bsdName: "en7", kind: .ethernet, linkSpeedMbps: 1000)
        )
        status.linkSwitchPending = pending
        return status
    }

    func testTheQueueKeepsGoingWhenNoSwitchIsWanted() throws {
        let (workspace, model, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(workspace.nasConnection.claimJobBoundary())
        var started: [String] = []
        model.enqueueFileJob(action: .freeUp, queuedNote: "A", detail: "") { _ in started.append("A") }
        XCTAssertEqual(started, ["A"])
    }

    func testAPendingSwitchTakesTheNextJobBoundary() throws {
        let (workspace, model, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.nasConnection.apply(pendingSwitchStatus())
        XCTAssertTrue(workspace.nasConnection.status.fasterLinkAvailable)

        // A job runs: the queue never asks, and the switch is not wanted mid-job.
        model.isBusy = true
        var started: [String] = []
        model.enqueueFileJob(action: .freeUp, queuedNote: "A", detail: "") { _ in started.append("A") }
        XCTAssertEqual(started, [])
        XCTAssertTrue(model.queuedFileJobs.count == 1)

        // The job ended: at this boundary the switch goes first and the
        // queued job waits for it.
        model.isBusy = false
        model.startNextQueuedFileJobIfPossible()
        XCTAssertEqual(started, [], "held for the link switch")
        XCTAssertEqual(model.queuedFileJobs.count, 1, "still queued, nothing dropped")

        // The switch finished (the status no longer wants one): the queue goes on.
        workspace.nasConnection.apply(pendingSwitchStatus(pending: false))
        model.startNextQueuedFileJobIfPossible()
        XCTAssertEqual(started, ["A"])
    }

    func testTheQueueIsNeverHeldWhileACardTransferRunsOrPastTheCap() throws {
        let (workspace, _, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.nasConnection.apply(pendingSwitchStatus())
        workspace.nasConnection.isNASInUse = { true }
        XCTAssertFalse(workspace.nasConnection.claimJobBoundary(), "something still copies: not a safe point")

        workspace.nasConnection.isNASInUse = { false }
        let start = Date()
        XCTAssertTrue(workspace.nasConnection.claimJobBoundary(now: start))
        XCTAssertTrue(workspace.nasConnection.claimJobBoundary(now: start.addingTimeInterval(30)))
        XCTAssertFalse(
            workspace.nasConnection.claimJobBoundary(now: start.addingTimeInterval(NASLinkSwitchGate.maximumQueueHold + 1)),
            "a switch that never runs lets the queue go"
        )
    }

    func testANASJobWaitsWhileTheRouteIsFasterThanTheShare() throws {
        let (workspace, _, root) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.nasConnection.apply(pendingSwitchStatus())
        var started = false
        // Not started (no controller): it starts at once rather than hang.
        workspace.nasConnection.prepareForNASJob { started = true }
        XCTAssertTrue(started)
    }
}
