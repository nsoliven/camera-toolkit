import Foundation
@testable import CameraToolkitCore
import XCTest

final class OrganizedArchiveServiceTests: XCTestCase {
    func testLayoutCreatesReadableEventCameraAndMediaFolders() throws {
        let layout = OrganizedArchiveLayout(
            eventDate: "2026-07-11",
            eventName: "Lee Canyon",
            deviceID: "sony-a7v"
        )

        XCTAssertEqual(
            try layout.destinationRelativePath(for: "DCIM/100MSDCF/DSC0001.ARW"),
            "Originals/2026/2026-07-11 Lee Canyon/Sony A7V/RAW/DSC0001.ARW"
        )
        XCTAssertEqual(
            try layout.destinationRelativePath(for: "M4ROOT/CLIP/C0001.MP4"),
            "Originals/2026/2026-07-11 Lee Canyon/Sony A7V/Video/C0001.MP4"
        )
        XCTAssertEqual(layout.mediaFolder(for: "DCIM/100MSDCF/DSC0001.XMP"), .raw)
        XCTAssertTrue(layout.requiredFolders(for: ["photo.ARW"]).contains("Edited/2026/2026-07-11 Lee Canyon/Masters"))
        XCTAssertTrue(layout.requiredFolders(for: ["photo.ARW"]).contains("System/Manifests"))
    }

    func testOsmoDNGAndJPEGSharePhotosFolder() throws {
        let layout = OrganizedArchiveLayout(eventDate: "2026-07-11", eventName: "Trip", deviceID: "osmo-360")
        XCTAssertEqual(layout.mediaFolder(for: "DCIM/IMG_001.DNG"), .photos)
        XCTAssertEqual(layout.mediaFolder(for: "DCIM/IMG_001.JPG"), .photos)
        XCTAssertEqual(layout.mediaFolder(for: "DCIM/VID_001.INSV"), .video)
    }

    func testArchiveCopiesVerifiesWritesManifestAndNeverOverwritesConflict() throws {
        try withTemporaryDirectory { root in
            let workspace = root.appendingPathComponent("Crucial/Card Copy", isDirectory: true)
            let library = root.appendingPathComponent("NAS/Camera", isDirectory: true)
            let layout = OrganizedArchiveLayout(eventDate: "2026-07-11", eventName: "Lee Canyon", deviceID: "sony-a7v")
            try writeFile(workspace.appendingPathComponent("DCIM/PHOTO.ARW"), Data("raw-original".utf8))
            try writeFile(workspace.appendingPathComponent("PRIVATE/NOTE.DAT"), Data("camera-support".utf8))

            let planner = OrganizedArchivePlanner()
            let initial = try planner.plan(source: workspace, libraryRoot: library, layout: layout)
            XCTAssertEqual(initial.new.count, 2)
            XCTAssertTrue(initial.conflicts.isEmpty)

            let result = try OrganizedArchiveService().archive(source: workspace, libraryRoot: library, plan: initial)
            XCTAssertEqual(result.copied.count, 2)
            let raw = library.appendingPathComponent("Originals/2026/2026-07-11 Lee Canyon/Sony A7V/RAW/PHOTO.ARW")
            let support = library.appendingPathComponent("Originals/2026/2026-07-11 Lee Canyon/Sony A7V/Camera Support/NOTE.DAT")
            XCTAssertEqual(try Data(contentsOf: raw), Data("raw-original".utf8))
            XCTAssertEqual(try Data(contentsOf: support), Data("camera-support".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.manifestPath)))

            try Data("different-existing-file".utf8).write(to: raw, options: .atomic)
            let conflict = try planner.plan(source: workspace, libraryRoot: library, layout: layout)
            XCTAssertEqual(conflict.conflicts.map(\.destinationPath), ["Originals/2026/2026-07-11 Lee Canyon/Sony A7V/RAW/PHOTO.ARW"])
            _ = try OrganizedArchiveService().archive(source: workspace, libraryRoot: library, plan: conflict)
            XCTAssertEqual(try Data(contentsOf: raw), Data("different-existing-file".utf8))
        }
    }

    func testMetadataArchivePreviewCannotBeMistakenForVerifiedArchive() throws {
        try withTemporaryDirectory { root in
            let library = root.appendingPathComponent("NAS/Camera", isDirectory: true)
            let layout = OrganizedArchiveLayout(eventDate: "2026-07-11", eventName: "Event", deviceID: "sony-a7v")
            let destination = library.appendingPathComponent(
                "Originals/2026/2026-07-11 Event/Sony A7V/RAW/PHOTO.ARW"
            )
            try writeFile(destination, Data(repeating: 0x42, count: 1_024))
            let files = [FileRecord(path: "DCIM/PHOTO.ARW", size: 1_024, modifiedAt: .now)]

            let preview = try OrganizedArchivePlanner().planMetadata(
                sourceFiles: files,
                libraryRoot: library,
                layout: layout
            )

            XCTAssertEqual(preview.existing.map(\.sourcePath), ["DCIM/PHOTO.ARW"])
            XCTAssertEqual(preview.existing.first?.sha256, "")
            XCTAssertFalse(preview.isVerified)
        }
    }
}
