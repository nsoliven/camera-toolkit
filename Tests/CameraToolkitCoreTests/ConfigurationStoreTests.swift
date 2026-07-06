import CameraToolkitCore
import Foundation
import XCTest

final class ConfigurationStoreTests: XCTestCase {
    func testMissingConfigurationLoadsDefaults() throws {
        try withTemporaryDirectory { root in
            let defaults = AppConfiguration.defaults(applicationSupport: root)
            let store = ConfigurationStore(url: root.appendingPathComponent("config.json"))

            XCTAssertEqual(try store.load(defaults: defaults), defaults)
        }
    }

    func testSaveAndLoadRoundTripsConfiguration() throws {
        try withTemporaryDirectory { root in
            let store = ConfigurationStore(url: root.appendingPathComponent("config/config.json"))
            let configuration = AppConfiguration(
                demoRootPath: root.appendingPathComponent("Demo").path,
                importSourcePath: root.appendingPathComponent("Card").path,
                archivePath: root.appendingPathComponent("Archive").path,
                bufferPath: root.appendingPathComponent("Buffer").path,
                activityLogPath: root.appendingPathComponent("activity-log.jsonl").path,
                selectedDeviceID: "dji-mini-2",
                eventName: "Test Trip",
                importDestination: .drive
            )

            try store.save(configuration)

            XCTAssertEqual(try store.load(defaults: .defaults(applicationSupport: root)), configuration)
        }
    }
}
