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
                selectedDeviceID: "dji-mini-2",
                eventName: "Test Trip"
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
              "eventName": "Old Trip"
            }
            """
            try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try oldJSON.write(to: store.url, atomically: true, encoding: .utf8)

            let loaded = try store.load(defaults: .defaults(applicationSupport: root))

            XCTAssertEqual(loaded.immichServerURL, "")
            XCTAssertEqual(loaded.selectedLocation(for: .importSource)?.path, root.appendingPathComponent("Card").path)
            XCTAssertEqual(loaded.selectedLocation(for: .archive)?.path, root.appendingPathComponent("Archive").path)
            XCTAssertEqual(loaded.selectedLocation(for: .buffer)?.path, root.appendingPathComponent("Buffer").path)
            XCTAssertEqual(loaded.locations(role: .importSource).map(\.name), ["Card"])
            XCTAssertEqual(loaded.locations(role: .archive).map(\.name), ["Archive"])
            XCTAssertEqual(loaded.locations(role: .buffer).map(\.name), ["Buffer"])
            XCTAssertEqual(loaded.savedEvents.map(\.name), ["Old Trip"])
            XCTAssertEqual(loaded.selectedEventID, loaded.savedEvents.first?.id)
        }
    }

    func testSavedEventsAssignmentsAndPhotomatorFoldersRoundTrip() throws {
        try withTemporaryDirectory { root in
            let eventID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
            let eventDate = Date(timeIntervalSince1970: 1_752_124_800)
            let event = SavedCameraEvent(
                id: eventID,
                name: "Summer Portraits",
                eventDate: eventDate,
                createdAt: eventDate,
                lastUsedAt: eventDate,
                immichUploadEnabled: true,
                immichAlbumPolicy: .custom,
                immichAlbumName: "Client Delivery"
            )
            let assignment = PhotoEventAssignment(
                sourceRootPath: root.appendingPathComponent("Card").path,
                relativePath: "DCIM/100MSDCF/DSC00001.ARW",
                fileSize: 18_000_000,
                modifiedAt: eventDate,
                eventID: eventID,
                deviceID: "sony-a7v",
                immichUploadOverride: false
            )
            let configuration = AppConfiguration(
                demoRootPath: root.appendingPathComponent("Demo").path,
                importSourcePath: root.appendingPathComponent("Card").path,
                archivePath: root.appendingPathComponent("Archive").path,
                bufferPath: root.appendingPathComponent("Buffer").path,
                activityLogPath: root.appendingPathComponent("activity.jsonl").path,
                selectedDeviceID: "sony-a7v",
                eventName: event.name,
                batchID: "2025-07-10_120000_sony-a7v_test",
                savedEvents: [event],
                selectedEventID: eventID,
                photoEventAssignments: [assignment]
            )
            let store = ConfigurationStore(url: root.appendingPathComponent("config.json"))

            try store.save(configuration)
            let loaded = try store.load(defaults: .defaults(applicationSupport: root))

            XCTAssertEqual(loaded.savedEvents, [event])
            XCTAssertEqual(loaded.photoEventAssignments, [assignment])
            XCTAssertEqual(loaded.bufferEditsFolderPath(), root.appendingPathComponent("Buffer/2025/2025-07-10 Summer Portraits/Photomator").path)
            XCTAssertEqual(loaded.bufferExportFolderPath("Web"), root.appendingPathComponent("Buffer/2025/2025-07-10 Summer Portraits/Exports/Web").path)
            XCTAssertEqual(loaded.eventWorkspaceFolderPaths().count, 5)
        }
    }
}
