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
