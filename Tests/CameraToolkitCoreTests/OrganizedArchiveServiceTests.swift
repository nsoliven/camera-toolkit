import Foundation
@testable import CameraToolkitCore
import XCTest

final class OrganizedArchiveServiceTests: XCTestCase {
    func testMirrorLayoutKeepsTheDriveRelativePathAndSubfolders() throws {
        let layout = OrganizedArchiveLayout(
            eventDate: "2026-07-11",
            eventName: "Mountain Trip",
            deviceID: "sony-a7v"
        )

        // The mirror: the drive's <year>/<event>/Originals/<Camera>/<subpath>.
        XCTAssertEqual(
            try layout.mirrorRelativePath(for: "DSC0001.ARW"),
            "2026/2026-07-11 Mountain Trip/Originals/Sony A7V/DSC0001.ARW"
        )
        XCTAssertEqual(
            try layout.mirrorRelativePath(for: "Transfer 2/100MSDCF/DSC0001.ARW"),
            "2026/2026-07-11 Mountain Trip/Originals/Sony A7V/Transfer 2/100MSDCF/DSC0001.ARW"
        )
        XCTAssertEqual(
            layout.requiredFolders(for: ["DSC0001.ARW", "Transfer 2/DSC0001.ARW"]),
            ["2026/2026-07-11 Mountain Trip/Originals/Sony A7V", "2026/2026-07-11 Mountain Trip/Originals/Sony A7V/Transfer 2"]
        )
        // The legacy archive layout the presence fallback still reads.
        XCTAssertEqual(
            try layout.legacyArchiveRelativePath(for: "DCIM/100MSDCF/DSC0001.ARW"),
            "Originals/2026/2026-07-11 Mountain Trip/Sony A7V/RAW/DSC0001.ARW"
        )
        XCTAssertEqual(
            try layout.legacyArchiveRelativePath(for: "M4ROOT/CLIP/C0001.MP4"),
            "Originals/2026/2026-07-11 Mountain Trip/Sony A7V/Video/C0001.MP4"
        )
        XCTAssertEqual(layout.mediaFolder(for: "DCIM/100MSDCF/DSC0001.XMP"), .raw)
        XCTAssertThrowsError(try layout.mirrorRelativePath(for: "../escape.ARW"))
    }

    func testMirrorLayoutNestsSubeventsUnderTheRootYear() throws {
        let layout = OrganizedArchiveLayout(
            eventDate: "2027-01-02",
            eventName: "Second Day",
            deviceID: "osmo-360",
            parentEventFolders: ["2026-12-31 Winter Trip"],
            year: "2026"
        )
        XCTAssertEqual(
            try layout.mirrorRelativePath(for: "CAM_0001.OSV"),
            "2026/2026-12-31 Winter Trip/2027-01-02 Second Day/Originals/Osmo 360/CAM_0001.OSV"
        )
        XCTAssertEqual(
            try layout.legacyArchiveRelativePath(for: "CAM_0001.OSV"),
            "Originals/2026/2026-12-31 Winter Trip/2027-01-02 Second Day/DJI Osmo 360/Video/CAM_0001.OSV"
        )
    }

    func testOsmoDNGAndJPEGSharePhotosFolder() throws {
        let layout = OrganizedArchiveLayout(eventDate: "2026-07-11", eventName: "Trip", deviceID: "osmo-360")
        XCTAssertEqual(layout.mediaFolder(for: "DCIM/IMG_001.DNG"), .photos)
        XCTAssertEqual(layout.mediaFolder(for: "DCIM/IMG_001.JPG"), .photos)
        XCTAssertEqual(layout.mediaFolder(for: "DCIM/VID_001.INSV"), .video)
        XCTAssertEqual(layout.mediaFolder(for: "DCIM/CAM_0001.OSV"), .video)
        XCTAssertEqual(layout.mediaFolder(for: "DCIM/CAM_0001.LRF"), .video)
    }

    func testNanoVideoLandsUnderDJINano() throws {
        let layout = OrganizedArchiveLayout(eventDate: "2026-07-11", eventName: "Road Trip", deviceID: "dji-nano")
        XCTAssertEqual(layout.deviceFolder, "DJI Nano")
        XCTAssertEqual(
            try layout.legacyArchiveRelativePath(for: "DJI_001/DJI_20260802_0035_D.MP4"),
            "Originals/2026/2026-07-11 Road Trip/DJI Nano/Video/DJI_20260802_0035_D.MP4"
        )
        XCTAssertEqual(
            try layout.mirrorRelativePath(for: "DJI_20260802_0035_D.MP4"),
            "2026/2026-07-11 Road Trip/Originals/Osmo Nano/DJI_20260802_0035_D.MP4"
        )
        XCTAssertEqual(layout.mediaFolder(for: "DJI_001/DJI_20260802_0035_D.LRF"), .video)
    }

    func testArchiveCopiesVerifiesWritesManifestAndNeverOverwritesConflict() throws {
        try withTemporaryDirectory { root in
            let workspace = root.appendingPathComponent("Buffer/2026/2026-07-11 Mountain Trip/Originals/Sony A7V", isDirectory: true)
            let library = root.appendingPathComponent("Library", isDirectory: true)
            let manifests = root.appendingPathComponent("Manifests", isDirectory: true)
            let layout = OrganizedArchiveLayout(eventDate: "2026-07-11", eventName: "Mountain Trip", deviceID: "sony-a7v")
            try writeFile(workspace.appendingPathComponent("DCIM/PHOTO.ARW"), Data("raw-original".utf8))
            try writeFile(workspace.appendingPathComponent("PRIVATE/NOTE.DAT"), Data("camera-support".utf8))
            // The same name in another subfolder: the flattened legacy
            // layout collided here, the mirror keeps both.
            try writeFile(workspace.appendingPathComponent("PRIVATE/DCIM/PHOTO.ARW"), Data("second-card-original".utf8))

            let planner = OrganizedArchivePlanner()
            let initial = try planner.plan(source: workspace, archiveRoot: library, layout: layout)
            XCTAssertEqual(initial.new.count, 3)
            XCTAssertTrue(initial.conflicts.isEmpty)

            let result = try OrganizedArchiveService().archive(source: workspace, archiveRoot: library, plan: initial, manifestFolder: manifests)
            XCTAssertEqual(result.copied.count, 3)
            let raw = library.appendingPathComponent("2026/2026-07-11 Mountain Trip/Originals/Sony A7V/DCIM/PHOTO.ARW")
            let second = library.appendingPathComponent("2026/2026-07-11 Mountain Trip/Originals/Sony A7V/PRIVATE/DCIM/PHOTO.ARW")
            let support = library.appendingPathComponent("2026/2026-07-11 Mountain Trip/Originals/Sony A7V/PRIVATE/NOTE.DAT")
            XCTAssertEqual(try Data(contentsOf: raw), Data("raw-original".utf8))
            XCTAssertEqual(try Data(contentsOf: second), Data("second-card-original".utf8))
            XCTAssertEqual(try Data(contentsOf: support), Data("camera-support".utf8))
            let manifestPath = try XCTUnwrap(result.manifestPath)
            XCTAssertTrue(manifestPath.hasPrefix(manifests.path + "/"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: manifestPath))

            try Data("different-existing-file".utf8).write(to: raw, options: .atomic)
            let conflict = try planner.plan(source: workspace, archiveRoot: library, layout: layout)
            XCTAssertEqual(conflict.conflicts.map(\.destinationPath), ["2026/2026-07-11 Mountain Trip/Originals/Sony A7V/DCIM/PHOTO.ARW"])
            _ = try OrganizedArchiveService().archive(source: workspace, archiveRoot: library, plan: conflict, manifestFolder: manifests)
            XCTAssertEqual(try Data(contentsOf: raw), Data("different-existing-file".utf8))
        }
    }

    func testMetadataArchivePreviewCannotBeMistakenForVerifiedArchive() throws {
        try withTemporaryDirectory { root in
            let library = root.appendingPathComponent("Library", isDirectory: true)
            let layout = OrganizedArchiveLayout(eventDate: "2026-07-11", eventName: "Event", deviceID: "sony-a7v")
            let destination = library.appendingPathComponent(
                "2026/2026-07-11 Event/Originals/Sony A7V/DCIM/PHOTO.ARW"
            )
            try writeFile(destination, Data(repeating: 0x42, count: 1_024))
            let files = [FileRecord(path: "DCIM/PHOTO.ARW", size: 1_024, modifiedAt: .now)]

            let preview = try OrganizedArchivePlanner().planMetadata(
                sourceFiles: files,
                archiveRoot: library,
                layout: layout
            )

            XCTAssertEqual(preview.existing.map(\.sourcePath), ["DCIM/PHOTO.ARW"])
            XCTAssertEqual(preview.existing.first?.sha256, "")
            XCTAssertFalse(preview.isVerified)
        }
    }
}
