import CameraToolkitCore
import Foundation
import XCTest

final class ManifestStoreTests: XCTestCase {
    func testManifestBuildWriteReadAndVerify() throws {
        try withTemporaryDirectory { root in
            let batch = root.appendingPathComponent("batch", isDirectory: true)
            try writeFile(batch.appendingPathComponent("DCIM/a.ARW"), Data.repeated("a", count: 100))
            try writeFile(batch.appendingPathComponent("DCIM/b.JPG"), Data.repeated("b", count: 10))
            try writeFile(batch.appendingPathComponent(".DS_Store"), "junk")

            let store = ManifestStore()
            let manifest = try store.build(root: batch, batchID: "batch-1", deviceID: "sony-a7v", source: "/fake/card")
            let manifestURL = batch.appendingPathComponent(Manifest.fileName)
            try store.write(manifest, to: manifestURL)

            let readBack = try store.read(from: manifestURL)
            let report = try store.verify(root: batch, manifest: readBack)

            XCTAssertEqual(readBack.fileCount, 2)
            XCTAssertTrue(readBack.files.allSatisfy { $0.sha256?.count == 64 })
            XCTAssertTrue(report.ok)
            XCTAssertEqual(report.verified, 2)
        }
    }

    func testManifestVerificationReportsMissingAndMismatchedFiles() throws {
        try withTemporaryDirectory { root in
            let batch = root.appendingPathComponent("batch", isDirectory: true)
            try writeFile(batch.appendingPathComponent("DCIM/a.ARW"), "original")
            try writeFile(batch.appendingPathComponent("DCIM/b.JPG"), "second")

            let store = ManifestStore()
            let manifest = try store.build(root: batch, batchID: "batch-1", deviceID: "sony-a7v", source: "/fake/card")

            try writeFile(batch.appendingPathComponent("DCIM/a.ARW"), "changed")
            try FileManager.default.removeItem(at: batch.appendingPathComponent("DCIM/b.JPG"))

            let report = try store.verify(root: batch, manifest: manifest)

            XCTAssertFalse(report.ok)
            XCTAssertEqual(report.mismatched, ["DCIM/a.ARW"])
            XCTAssertEqual(report.missing, ["DCIM/b.JPG"])
        }
    }
}
