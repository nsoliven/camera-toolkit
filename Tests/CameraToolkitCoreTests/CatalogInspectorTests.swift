import CameraToolkitCore
import Foundation
import XCTest

final class CatalogInspectorTests: XCTestCase {
    func testInspectorListsCatalogTablesRunsBoundedQueriesAndRejectsWrites() throws {
        try withTemporaryDirectory { root in
            let databaseURL = root.appendingPathComponent("catalog.sqlite")
            let eventID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
            let date = Date(timeIntervalSince1970: 1_752_124_800)
            let assignment = PhotoEventAssignment(
                sourceRootPath: root.appendingPathComponent("Card").path,
                relativePath: "DCIM/DSC00001.ARW",
                fileSize: 17_000_000,
                modifiedAt: date,
                eventID: eventID,
                deviceID: "sony-a7v",
                immichUploadOverride: false
            )
            let configuration = AppConfiguration(
                demoRootPath: root.appendingPathComponent("Demo").path,
                importSourcePath: root.appendingPathComponent("Card").path,
                archivePath: root.appendingPathComponent("Library/Originals").path,
                bufferPath: root.appendingPathComponent("Buffer").path,
                cameraLibraryRootPath: root.appendingPathComponent("Library").path,
                catalogDatabasePath: databaseURL.path,
                activityLogPath: root.appendingPathComponent("activity.jsonl").path,
                savedEvents: [
                    SavedCameraEvent(
                        id: eventID,
                        name: "Portraits",
                        eventDate: date,
                        immichUploadEnabled: true,
                        immichAlbumPolicy: ImmichAlbumPolicy.none
                    )
                ],
                selectedEventID: eventID,
                photoEventAssignments: [assignment]
            )
            _ = try CatalogStore(url: databaseURL).bootstrap(configuration: configuration, createBackup: false)

            let inspector = CatalogInspector(url: databaseURL)
            let objects = try inspector.objects()
            XCTAssertTrue(objects.contains { $0.name == "events" })
            XCTAssertTrue(objects.contains { $0.name == "event_assets" })
            XCTAssertTrue(objects.contains { $0.name == "event_asset_locations" })
            XCTAssertTrue(objects.contains { $0.name == "immich_assets" })

            let result = try inspector.query("SELECT name, immich_upload_enabled FROM events")
            XCTAssertEqual(result.columns, ["name", "immich_upload_enabled"])
            XCTAssertEqual(result.rows, [["Portraits", "1"]])
            XCTAssertThrowsError(try inspector.query("DELETE FROM events"))

            let eventAssetID = CatalogStore.eventAssetID(assignment)
            let initialAsset = try XCTUnwrap(inspector.eventAssets(eventID: eventID).first)
            XCTAssertEqual(initialAsset.assignment, assignment)
            XCTAssertNil(initialAsset.sourcePresence)

            let checkedAt = Date(timeIntervalSince1970: 1_752_125_400)
            try inspector.savePresenceObservations([
                CatalogPresenceObservation(
                    eventAssetID: eventAssetID,
                    location: .source,
                    state: .present,
                    checkedAt: checkedAt
                ),
                CatalogPresenceObservation(
                    eventAssetID: eventAssetID,
                    location: .archive,
                    state: .unavailable,
                    checkedAt: checkedAt
                )
            ])
            let observedAsset = try XCTUnwrap(inspector.eventAssets(eventID: eventID).first)
            XCTAssertEqual(observedAsset.sourcePresence?.state, .present)
            XCTAssertEqual(observedAsset.sourcePresence?.checkedAt, checkedAt)
            XCTAssertEqual(observedAsset.archivePresence?.state, .unavailable)
            XCTAssertNil(observedAsset.bufferPresence)

            try inspector.saveImmichStatuses([
                ImmichCatalogStatus(
                    eventAssetID: eventAssetID,
                    status: "present",
                    immichAssetID: "immich-asset",
                    checksumSHA1: "abc123"
                )
            ])
            _ = try CatalogStore(url: databaseURL).bootstrap(configuration: configuration, createBackup: false)
            XCTAssertEqual(try inspector.immichStatuses(eventID: eventID)[eventAssetID]?.status, "present")
            XCTAssertEqual(try inspector.eventAssets(eventID: eventID).first?.sourcePresence?.state, .present)
        }
    }

    func testInspectorStopsAtTheRequestedRowLimit() throws {
        try withTemporaryDirectory { root in
            let databaseURL = root.appendingPathComponent("catalog.sqlite")
            let configuration = AppConfiguration(
                demoRootPath: root.appendingPathComponent("Demo").path,
                importSourcePath: root.appendingPathComponent("Card").path,
                archivePath: root.appendingPathComponent("Library/Originals").path,
                bufferPath: root.appendingPathComponent("Buffer").path,
                cameraLibraryRootPath: root.appendingPathComponent("Library").path,
                catalogDatabasePath: databaseURL.path,
                activityLogPath: root.appendingPathComponent("activity.jsonl").path
            )
            _ = try CatalogStore(url: databaseURL).bootstrap(
                configuration: configuration,
                createBackup: false,
                createLibraryFolders: false
            )

            let result = try CatalogInspector(url: databaseURL).query(
                """
                WITH RECURSIVE sequence(value) AS (
                    SELECT 1
                    UNION ALL
                    SELECT value + 1 FROM sequence WHERE value < 5000
                )
                SELECT value FROM sequence
                """,
                rowLimit: 7
            )

            XCTAssertEqual(result.rows.count, 7)
            XCTAssertEqual(result.rows.first, ["1"])
            XCTAssertEqual(result.rows.last, ["7"])
        }
    }

    func testFileSHA1StreamsKnownDigest() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("sample.bin")
            try Data("abc".utf8).write(to: url)
            XCTAssertEqual(try FileSHA1.hexDigest(of: url, chunkSize: 2), "a9993e364706816aba3e25717850c26c9cd0d89d")
        }
    }
}
