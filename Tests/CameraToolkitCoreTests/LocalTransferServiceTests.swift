import CameraToolkitCore
import Foundation
import XCTest

final class LocalTransferServiceTests: XCTestCase {
    func testImmutableCopyCopiesNewNestedFilesSkipsIdenticalAndExcludesJunk() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            let newBytes = Data.repeated("new-photo", count: 200)
            let sameBytes = Data.repeated("same-photo", count: 200)
            try writeFile(source.appendingPathComponent("DCIM/100MSDCF/new.ARW"), newBytes)
            try writeFile(source.appendingPathComponent("DCIM/100MSDCF/same.ARW"), sameBytes)
            try writeFile(destination.appendingPathComponent("DCIM/100MSDCF/same.ARW"), sameBytes)
            try writeFile(source.appendingPathComponent("DCIM/100MSDCF/.DS_Store"), "junk")
            try writeFile(source.appendingPathComponent("DCIM/100MSDCF/._new.ARW"), "appledouble")

            let result = try LocalTransferService().copyImmutable(source: source, destination: destination)

            XCTAssertEqual(result.copied, ["DCIM/100MSDCF/new.ARW"])
            XCTAssertEqual(result.skippedIdentical, ["DCIM/100MSDCF/same.ARW"])
            XCTAssertTrue(result.conflicts.isEmpty)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("DCIM/100MSDCF/new.ARW")), newBytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("DCIM/100MSDCF/.DS_Store").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("DCIM/100MSDCF/._new.ARW").path))
        }
    }

    func testImmutableCopyNeverOverwritesConflict() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            try writeFile(source.appendingPathComponent("a.ARW"), "new-bytes")
            try writeFile(destination.appendingPathComponent("a.ARW"), "archive-bytes")

            let result = try LocalTransferService().copyImmutable(source: source, destination: destination)

            XCTAssertEqual(result.conflicts, ["a.ARW"])
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("a.ARW")), Data("archive-bytes".utf8))
        }
    }

    func testSelectedCopyRejectsAnEarlyEndOfFileAndLeavesNoFinalOrTemporaryFile() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            let relativePath = "DCIM/clip.MP4"
            try writeFile(source.appendingPathComponent(relativePath), "short")

            XCTAssertThrowsError(
                try LocalTransferService().copyFiles(
                    source: source,
                    destination: destination,
                    files: [FileRecord(path: relativePath, size: 10, modifiedAt: Date())]
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("stopped early"))
                XCTAssertTrue(error.localizedDescription.contains("No camera file was deleted"))
            }

            let finalURL = destination.appendingPathComponent(relativePath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
            let parent = finalURL.deletingLastPathComponent()
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            XCTAssertFalse(leftovers.contains { $0.contains(".cttmp-") })
        }
    }

    func testSelectedCopyRemovesOnlyItsOwnStaleTemporaryCopiesBeforeRetry() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            let relativePath = "DCIM/photo.ARW"
            let bytes = Data("camera-photo".utf8)
            try writeFile(source.appendingPathComponent(relativePath), bytes)
            let destinationParent = destination.appendingPathComponent("DCIM", isDirectory: true)
            try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
            let stale = destinationParent.appendingPathComponent(".photo.ARW.cttmp-old-run")
            let unrelated = destinationParent.appendingPathComponent(".different.ARW.cttmp-keep")
            try writeFile(stale, "partial")
            try writeFile(unrelated, "other")

            let result = try LocalTransferService().copyFiles(
                source: source,
                destination: destination,
                files: [FileRecord(path: relativePath, size: Int64(bytes.count), modifiedAt: Date())]
            )

            XCTAssertEqual(result.copied, [relativePath])
            XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(relativePath)), bytes)
        }
    }

    func testSimulationWorkspaceRunsEndToEndInLocalFolders() throws {
        try withTemporaryDirectory { root in
            let workspace = SimulationWorkspace(root: root.appendingPathComponent("Simulation", isDirectory: true))
            let summary = try workspace.runFullSimulation()

            XCTAssertTrue(summary.manifestOK)
            XCTAssertGreaterThan(summary.copiedCount, 0)
            XCTAssertGreaterThan(summary.quarantinedCount, 0)
            XCTAssertEqual(summary.leftUnsafeCount, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.manifestURL.path))
        }
    }
}
