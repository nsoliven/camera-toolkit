@testable import CameraToolkitApp
import CameraToolkitCore
import XCTest

/// The model once the catalog owns events and assignments: edits reach the
/// catalog row by row, config.json keeps settings only, and a refresh
/// never drops events.
@MainActor
final class CatalogStateModelTests: XCTestCase {
    private func makeModel(root: URL) throws -> (DashboardModel, URL, URL) {
        let support = root.appendingPathComponent("CameraToolkit", isDirectory: true)
        let configURL = support.appendingPathComponent("config.json")
        let catalogURL = support.appendingPathComponent("catalog.sqlite")
        var configuration = AppConfiguration(
            demoRootPath: root.appendingPathComponent("Demo").path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path,
            bufferPath: root.appendingPathComponent("Buffer").path,
            catalogDatabasePath: catalogURL.path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path
        )
        let event = SavedCameraEvent(name: "Trip", eventDate: Date(timeIntervalSince1970: 1_750_000_000))
        configuration.savedEvents = [event]
        configuration.photoEventAssignments = (0..<40).map {
            PhotoEventAssignment(
                sourceRootPath: "/cards/a",
                relativePath: "DSC\($0).ARW",
                fileSize: Int64($0 + 1),
                modifiedAt: Date(timeIntervalSince1970: 1_750_000_000 + Double($0)),
                eventID: event.id
            )
        }
        try ConfigurationStore(url: configURL).save(configuration)

        let store = ConfigurationStore(url: configURL)
        let outcome = CatalogStateStartup.resolve(
            configurationURL: configURL,
            defaults: configuration,
            backups: { url in
                CatalogBackupService(
                    catalogURL: url,
                    configurationURL: configURL,
                    localFolder: support.appendingPathComponent("Backups"),
                    remoteFolder: nil
                )
            }
        )
        let model = DashboardModel(jobs: [], configuration: outcome.configuration, configurationStore: store)
        model.adoptCatalogState(outcome)
        return (model, configURL, catalogURL)
    }

    func testEditsReachTheCatalogAndConfigJSONKeepsSettingsOnly() throws {
        try withTemporaryFolder { root in
            let (model, configURL, catalogURL) = try makeModel(root: root)
            guard case .catalog = model.catalogStateMode else { return XCTFail("expected catalog mode: \(model.statusMessage)") }
            XCTAssertTrue(ConfigurationStore.isSettingsOnly(try Data(contentsOf: configURL)), "shrunk right after the migration")

            let eventID = model.configuration.savedEvents[0].id
            model.updateConfiguration { configuration in
                configuration.photoEventAssignments.removeFirst(5)
                configuration.savedEvents.append(SavedCameraEvent(name: "New", eventDate: Date()))
                configuration.displayOrientations["DSC1.ARW|2|3"] = 2
            }
            model.setEventImmichUploadEnabled(eventID, enabled: true)
            model.flushConfigurationSave()

            let stored = try CatalogStateStore(url: catalogURL).load()
            XCTAssertEqual(stored.photoEventAssignments.count, 35)
            XCTAssertEqual(stored.savedEvents.count, 2)
            XCTAssertEqual(stored.savedEvents.first { $0.id == eventID }?.immichUploadEnabled, true)
            XCTAssertEqual(stored.displayOrientations["DSC1.ARW|2|3"], 2)
            let json = try Data(contentsOf: configURL)
            XCTAssertTrue(ConfigurationStore.isSettingsOnly(json))
            XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("DSC1.ARW"))
            CatalogDatabase.checkpointAndClose(url: catalogURL)
        }
    }

    func testRefreshReloadsSettingsButKeepsEvents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, configURL, catalogURL) = try makeModel(root: root)
        var onDisk = model.configuration
        onDisk.immichServerURL = "https://edited.example"
        try ConfigurationStore(url: configURL).save(onDisk, settingsOnly: true)

        model.refreshAll()
        let deadline = Date().addingTimeInterval(15)
        while model.isRefreshing, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(model.configuration.immichServerURL, "https://edited.example")
        XCTAssertEqual(model.configuration.photoEventAssignments.count, 40)
        XCTAssertEqual(model.configuration.savedEvents.count, 1)
        XCTAssertEqual(model.configuration.selectedEventID, model.configuration.savedEvents[0].id)
        CatalogDatabase.checkpointAndClose(url: catalogURL)
    }

    func testTheCatalogFileCannotBeSwitchedWhileItHoldsTheEvents() throws {
        try withTemporaryFolder { root in
            let (model, _, catalogURL) = try makeModel(root: root)
            model.setConfigPath(\.catalogDatabasePath, to: root.appendingPathComponent("other.sqlite").path)
            XCTAssertEqual(model.configuration.catalogDatabasePath, catalogURL.path)
            CatalogDatabase.checkpointAndClose(url: catalogURL)
        }
    }

    func testSuspendedModeWritesNothing() throws {
        try withTemporaryFolder { root in
            let configURL = root.appendingPathComponent("config.json")
            try Data("{ broken".utf8).write(to: configURL)
            let defaults = AppConfiguration.defaults(applicationSupport: root)
            let outcome = CatalogStateStartup.resolve(
                configurationURL: configURL,
                defaults: defaults,
                backups: { url in
                    CatalogBackupService(catalogURL: url, configurationURL: nil, localFolder: root, remoteFolder: nil)
                }
            )
            let model = DashboardModel(jobs: [], configuration: outcome.configuration, configurationStore: ConfigurationStore(url: configURL))
            model.adoptCatalogState(outcome)
            model.updateConfiguration { $0.immichServerURL = "https://x.example" }
            model.flushConfigurationSave()
            XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), "{ broken")
        }
    }

    private func withTemporaryFolder(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
