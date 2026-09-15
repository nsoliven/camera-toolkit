import CameraToolkitCore
import Foundation
import XCTest

final class UnsortedFolderDiscoveryTests: XCTestCase {
    func testFindsCardDumpsAndCardsButNotBufferEmptyOrKnownFolders() throws {
        try withTemporaryDirectory { root in
            let drive = root.appendingPathComponent("Travel Drive", isDirectory: true)
            try writeFile(drive.appendingPathComponent("Unparsed Camera/Transfer 1/DSC00001.ARW"), "raw")
            try writeFile(drive.appendingPathComponent("Unparsed Camera/Transfer 1/DSC00001.xmp"), "sidecar")
            try writeFile(drive.appendingPathComponent("Harbor Trip Copy/DSC00002.JPG"), "jpg")
            try writeFile(drive.appendingPathComponent("Camera Buffer/2026/2026-08-01 Beach/Sony A7V/Card Copy/DSC00003.ARW"), "raw")
            try writeFile(drive.appendingPathComponent("Already Added/C0001.MP4"), "video")
            try writeFile(drive.appendingPathComponent("Notes/readme.txt"), "text")
            try FileManager.default.createDirectory(at: drive.appendingPathComponent("untitled folder"), withIntermediateDirectories: true)
            try writeFile(drive.appendingPathComponent("$RECYCLE.BIN/DSC9.ARW"), "raw")

            let card = root.appendingPathComponent("CARD", isDirectory: true)
            try writeFile(card.appendingPathComponent("DCIM/100MSDCF/DSC00010.ARW"), "raw")
            try writeFile(card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0002.MP4"), "video")

            let found = UnsortedFolderDiscovery.candidates(
                volumeRoots: [drive, card],
                excludedRoots: [drive.appendingPathComponent("Camera Buffer")],
                alreadyAddedPaths: [drive.appendingPathComponent("Already Added").path]
            )

            XCTAssertEqual(found.map(\.name), ["CARD", "Unparsed Camera", "Harbor Trip Copy"])
            let cardCandidate = try XCTUnwrap(found.first { $0.name == "CARD" })
            XCTAssertTrue(cardCandidate.isCameraCard)
            XCTAssertEqual(cardCandidate.cameraFileCount, 2)
            let dump = try XCTUnwrap(found.first { $0.name == "Unparsed Camera" })
            XCTAssertTrue(dump.isSuggested)
            XCTAssertEqual(dump.cameraFileCount, 1)
            XCTAssertEqual(dump.volumeName, "Travel Drive")
            XCTAssertFalse(try XCTUnwrap(found.first { $0.name == "Harbor Trip Copy" }).isSuggested)
        }
    }

    func testSkipsAFolderThatContainsTheBuffer() throws {
        try withTemporaryDirectory { root in
            let drive = root.appendingPathComponent("Drive", isDirectory: true)
            try writeFile(drive.appendingPathComponent("Photos/Camera Buffer/2026/DSC00001.ARW"), "raw")
            let found = UnsortedFolderDiscovery.candidates(
                volumeRoots: [drive],
                excludedRoots: [drive.appendingPathComponent("Photos/Camera Buffer")],
                alreadyAddedPaths: []
            )
            XCTAssertTrue(found.isEmpty)
        }
    }
}
