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
}
