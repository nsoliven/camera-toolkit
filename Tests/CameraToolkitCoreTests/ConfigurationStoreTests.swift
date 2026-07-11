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
                immichServerURL: "http://photos.local:2283",
                editorWorkingFolderPath: root.appendingPathComponent("Working Copies").path,
                externalEditor: .photomator,
                rcloneBinaryPath: "/opt/homebrew/bin/rclone",
                exiftoolBinaryPath: "/opt/homebrew/bin/exiftool",
                selectedDeviceID: "dji-mini-2",
                eventName: "Test Trip",
                importDestination: .drive
            )

            try store.save(configuration)

            XCTAssertEqual(try store.load(defaults: .defaults(applicationSupport: root)), configuration)
        }
    }

    func testOldConfigurationJSONMigratesToNewDefaults() throws {
        try withTemporaryDirectory { root in
            let store = ConfigurationStore(url: root.appendingPathComponent("config/config.json"))
            let oldJSON = """
            {
              "demoRootPath": "\(root.appendingPathComponent("Demo").path)",
              "importSourcePath": "\(root.appendingPathComponent("Card").path)",
              "archivePath": "\(root.appendingPathComponent("Archive").path)",
              "bufferPath": "\(root.appendingPathComponent("Buffer").path)",
              "activityLogPath": "\(root.appendingPathComponent("activity-log.jsonl").path)",
              "selectedDeviceID": "sony-a7v",
              "eventName": "Old Trip",
              "importDestination": "nas"
            }
            """
            try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try oldJSON.write(to: store.url, atomically: true, encoding: .utf8)

            let loaded = try store.load(defaults: .defaults(applicationSupport: root))

            XCTAssertEqual(loaded.immichServerURL, "")
            XCTAssertEqual(loaded.externalEditor, .preview)
            XCTAssertTrue(loaded.editorWorkingFolderPath.hasSuffix("Editor Working Copies"))
            XCTAssertEqual(loaded.rcloneBinaryPath, "rclone")
            XCTAssertEqual(loaded.exiftoolBinaryPath, "exiftool")
            XCTAssertEqual(loaded.selectedLocation(for: .importSource)?.path, root.appendingPathComponent("Card").path)
            XCTAssertEqual(loaded.selectedLocation(for: .archive)?.path, root.appendingPathComponent("Archive").path)
            XCTAssertEqual(loaded.selectedLocation(for: .buffer)?.path, root.appendingPathComponent("Buffer").path)
            XCTAssertEqual(loaded.locations(role: .importSource).map(\.name), ["Card"])
            XCTAssertEqual(loaded.locations(role: .archive).map(\.name), ["Archive"])
            XCTAssertEqual(loaded.locations(role: .buffer).map(\.name), ["Buffer"])
        }
    }
}
