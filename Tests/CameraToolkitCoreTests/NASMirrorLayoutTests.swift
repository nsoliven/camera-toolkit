import CameraToolkitCore
import Foundation
import XCTest

/// The NAS mirror layout: a drive file's archive copy sits at the same
/// `<year>/<event>/…` relative path under the NAS root.
final class NASMirrorLayoutTests: XCTestCase {
    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(DateFormatter.yyyyMMdd.date(from: text))
    }

    func testMirrorRootIsDerivedFromTheLibraryRootWithoutADoubleOriginals() {
        XCTAssertEqual(AppConfiguration.derivedArchiveLayoutRoot(cameraLibraryRootPath: "/Volumes/Share/Media/Camera"), "/Volumes/Share/Media/Camera")
        XCTAssertEqual(AppConfiguration.derivedArchiveLayoutRoot(cameraLibraryRootPath: "/Volumes/Share/Media/Camera/Originals"), "/Volumes/Share/Media/Camera")
        XCTAssertEqual(AppConfiguration.derivedArchiveLayoutRoot(cameraLibraryRootPath: "/Volumes/Share/Media/Camera/Originals/"), "/Volumes/Share/Media/Camera")
        XCTAssertEqual(AppConfiguration.derivedArchiveLayoutRoot(cameraLibraryRootPath: ""), "")
    }

    func testConfigurationFromBeforeTheMirrorLayoutGetsTheDerivedRootAndKeepsAnExplicitOne() throws {
        try withTemporaryDirectory { root in
            var configuration = testConfiguration(root: root)
            XCTAssertEqual(configuration.archiveLayoutRootPath, root.appendingPathComponent("Library").standardizedFileURL.path)

            // An older config.json has neither key: the derived root is
            // filled in on load and written out on the next save.
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as! [String: Any]
            json.removeValue(forKey: "archiveLayoutRootPath")
            json.removeValue(forKey: "nasSMBURL")
            let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.archiveLayoutRootPath, root.appendingPathComponent("Library").standardizedFileURL.path)
            XCTAssertEqual(decoded.nasSMBURL, "")
            let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
            XCTAssertEqual(reencoded["archiveLayoutRootPath"] as? String, decoded.archiveLayoutRootPath)

            configuration.archiveLayoutRootPath = root.appendingPathComponent("Mirror").path
            configuration.nasSMBURL = "smb://nas.local/files"
            let roundTrip = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
            XCTAssertEqual(roundTrip.archiveLayoutRootPath, root.appendingPathComponent("Mirror").path)
            XCTAssertEqual(roundTrip.nasSMBURL, "smb://nas.local/files")
            XCTAssertEqual(EventStorageLocations(configuration: roundTrip).nasRoot.lastPathComponent, "Mirror")
        }
    }

    func testMirrorPathsForSharedPrivateAndSubevents() throws {
        try withTemporaryDirectory { root in
            var configuration = testConfiguration(root: root)
            let parent = SavedCameraEvent(name: "Winter Trip", eventDate: try date("2026-12-30"))
            let child = SavedCameraEvent(name: "Second Day", eventDate: try date("2027-01-02"), parentEventID: parent.id)
            var hidden = SavedCameraEvent(name: "Quiet Dinner", eventDate: try date("2026-08-02"))
            hidden.storagePolicy = .archiveOnly
            // A private subevent of a shared parent.
            var privateChild = SavedCameraEvent(name: "Family Only", eventDate: try date("2026-12-31"), parentEventID: parent.id)
            privateChild.storagePolicy = .archiveOnly
            configuration.savedEvents = [parent, child, hidden, privateChild]
            let locations = EventStorageLocations(configuration: configuration)
            let library = root.appendingPathComponent("Library").standardizedFileURL.path

            func assignment(_ event: SavedCameraEvent, _ relative: String, _ device: String) -> PhotoEventAssignment {
                PhotoEventAssignment(sourceRootPath: "/Volumes/Card/DCIM", relativePath: relative, fileSize: 1, modifiedAt: Date(), eventID: event.id, deviceID: device)
            }

            XCTAssertEqual(
                locations.archiveURL(for: assignment(parent, "DSC00001.ARW", "sony-a7v"), event: parent)?.path,
                library + "/2026/2026-12-30 Winter Trip/Originals/Sony A7V/DSC00001.ARW"
            )
            // A subevent nests under its parent and the root ancestor's year.
            XCTAssertEqual(
                locations.archiveURL(for: assignment(child, "Transfer 2/CAM_0001.OSV", "osmo-360"), event: child)?.path,
                library + "/2026/2026-12-30 Winter Trip/2027-01-02 Second Day/Originals/Osmo 360/Transfer 2/CAM_0001.OSV"
            )
            // A private event is not hidden on the NAS: same mirror path.
            XCTAssertEqual(
                locations.archiveURL(for: assignment(hidden, "DSC00002.ARW", "sony-a7v"), event: hidden)?.path,
                library + "/2026/2026-08-02 Quiet Dinner/Originals/Sony A7V/DSC00002.ARW"
            )
            XCTAssertEqual(locations.nasEditedRoot(for: hidden).path, library + "/2026/2026-08-02 Quiet Dinner/Edited")
            XCTAssertEqual(
                locations.nasOriginalsRoot(for: privateChild, deviceID: "dji-nano").path,
                library + "/2026/2026-12-30 Winter Trip/2026-12-31 Family Only/Originals/Osmo Nano"
            )
            XCTAssertEqual(
                locations.legacyArchiveEventFolder(for: child).path,
                library + "/Originals/2026/2026-12-30 Winter Trip/2027-01-02 Second Day"
            )
            // …and it still stays out of the shared Buffer.
            XCTAssertEqual(locations.resolvedPolicy(for: hidden), .archiveOnly)

            // Any drive path maps to the same relative path under the NAS
            // root, from the Buffer or from private staging.
            let bufferFile = locations.editedRoot(for: parent, policy: .buffer).appendingPathComponent("Web/DSC00001-edit.jpg").path
            XCTAssertEqual(locations.mirrorRelativePath(forDrivePath: bufferFile), "2026/2026-12-30 Winter Trip/Edited/Web/DSC00001-edit.jpg")
            let privateFile = locations.originalsRoot(for: privateChild, deviceID: "sony-a7v", policy: .archiveOnly).appendingPathComponent("DSC00003.ARW").path
            XCTAssertEqual(
                locations.nasMirrorURL(forDrivePath: privateFile)?.path,
                library + "/2026/2026-12-30 Winter Trip/2026-12-31 Family Only/Originals/Sony A7V/DSC00003.ARW"
            )
            XCTAssertNil(locations.mirrorRelativePath(forDrivePath: root.appendingPathComponent("Elsewhere/x.ARW").path))
        }
    }

    func testPresenceFallsBackToTheLegacyArchiveLayout() throws {
        try withTemporaryDirectory { root in
            let configuration = testConfiguration(root: root)
            let locations = EventStorageLocations(configuration: configuration)
            let event = SavedCameraEvent(name: "City Walk", eventDate: try date("2026-08-29"))
            let bytes = Data(repeating: 7, count: 64)
            let a = PhotoEventAssignment(sourceRootPath: root.appendingPathComponent("Card").path, relativePath: "DSC00001.ARW", fileSize: 64, modifiedAt: Date(), eventID: event.id, deviceID: "sony-a7v")
            let b = PhotoEventAssignment(sourceRootPath: root.appendingPathComponent("Card").path, relativePath: "DSC00002.ARW", fileSize: 64, modifiedAt: Date(), eventID: event.id, deviceID: "sony-a7v")

            // a: archived the old way only. b: in the mirror layout.
            let legacy = try XCTUnwrap(locations.legacyArchiveURL(for: a, event: event))
            try writeFile(legacy, bytes)
            let mirror = try XCTUnwrap(locations.archiveURL(for: b, event: event))
            try writeFile(mirror, bytes)

            let summary = try XCTUnwrap(EventPresenceScanner.scan(event: event, assignments: [a, b], locations: locations))
            XCTAssertEqual(summary.onArchive, 2)
            XCTAssertEqual(summary.onLegacyArchiveLayout, 1)
            let first = try XCTUnwrap(summary.assets.first { $0.assignment.relativePath == "DSC00001.ARW" })
            XCTAssertTrue(first.archiveIsLegacyLayout)
            XCTAssertEqual(first.archivePath, legacy.standardizedFileURL.path)
            let second = try XCTUnwrap(summary.assets.first { $0.assignment.relativePath == "DSC00002.ARW" })
            XCTAssertFalse(second.archiveIsLegacyLayout)
            XCTAssertEqual(second.archivePath, mirror.standardizedFileURL.path)

            // Once both layouts hold it, the mirror copy wins.
            try writeFile(try XCTUnwrap(locations.archiveURL(for: a, event: event)), bytes)
            let migrated = try XCTUnwrap(EventPresenceScanner.scan(event: event, assignments: [a], locations: locations))
            XCTAssertEqual(migrated.onLegacyArchiveLayout, 0)
            XCTAssertEqual(migrated.onArchive, 1)
        }
    }

    func testNASPlaceIsTheMirrorRoot() throws {
        try withTemporaryDirectory { root in
            var configuration = testConfiguration(root: root)
            configuration.archiveLayoutRootPath = root.appendingPathComponent("Mirror").path
            let locations = EventStorageLocations(configuration: configuration)
            let event = SavedCameraEvent(name: "E", eventDate: try date("2026-01-01"))
            let places = EventReachability.places(members: [event], assignments: [], locations: locations)
            XCTAssertEqual(places.first { $0.role == .nas }?.root.path, root.appendingPathComponent("Mirror").standardizedFileURL.path)
        }
    }
}
