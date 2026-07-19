import CameraToolkitCore
import Foundation
import XCTest

final class ArchivePlannerTests: XCTestCase {
    func testPlanCopyClassifiesNewExistingAndConflictFiles() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("src", isDirectory: true)
            let destination = root.appendingPathComponent("dst", isDirectory: true)

            try writeFile(source.appendingPathComponent("new.ARW"), Data(repeating: 0x6E, count: 10))
            try writeFile(source.appendingPathComponent("same.ARW"), Data(repeating: 0x73, count: 10))
            try writeFile(destination.appendingPathComponent("same.ARW"), Data(repeating: 0x73, count: 10))
            try writeFile(source.appendingPathComponent("conflict.ARW"), Data(repeating: 0x63, count: 20))
            try writeFile(destination.appendingPathComponent("conflict.ARW"), Data(repeating: 0x58, count: 5))
            try writeFile(source.appendingPathComponent("._junk.ARW"), "junk")

            let plan = try ArchivePlanner().planCopy(source: source, destination: destination, excludes: ["._*", ".DS_Store"])

            XCTAssertEqual(plan.new.map(\.path), ["new.ARW"])
            XCTAssertEqual(plan.existing.map(\.path), ["same.ARW"])
            XCTAssertEqual(plan.conflicts.map(\.path), ["conflict.ARW"])
            XCTAssertEqual(plan.newBytes, 10)
        }
    }

    func testMissingDestinationTreatsEverythingAsNew() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("src", isDirectory: true)
            try writeFile(source.appendingPathComponent("a.ARW"), "a")

            let plan = try ArchivePlanner().planCopy(source: source, destination: root.appendingPathComponent("missing"))

            XCTAssertEqual(plan.new.map(\.path), ["a.ARW"])
            XCTAssertTrue(plan.existing.isEmpty)
            XCTAssertTrue(plan.conflicts.isEmpty)
        }
    }

    func testCheckCatchesSingleByteCorruptionSameSize() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("src", isDirectory: true)
            let destination = root.appendingPathComponent("dst", isDirectory: true)
            try writeFile(source.appendingPathComponent("a.ARW"), Data(repeating: 0x61, count: 1_000))
            try writeFile(destination.appendingPathComponent("a.ARW"), Data(repeating: 0x61, count: 1_000))

            var corrupted = Data(repeating: 0x61, count: 1_000)
            corrupted[500] = 0x62
            try writeFile(destination.appendingPathComponent("a.ARW"), corrupted)

            let report = try LocalCheckService().check(source: source, destination: destination)

            XCTAssertFalse(report.ok)
            XCTAssertEqual(report.differ, ["a.ARW"])
            XCTAssertTrue(report.match.isEmpty)
        }
    }

    func testPlanCopyTreatsSameSizeDifferentBytesAsConflict() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("src", isDirectory: true)
            let destination = root.appendingPathComponent("dst", isDirectory: true)
            try writeFile(source.appendingPathComponent("DCIM/a.ARW"), Data(repeating: 0x41, count: 4096))
            try writeFile(destination.appendingPathComponent("DCIM/a.ARW"), Data(repeating: 0x42, count: 4096))

            let plan = try ArchivePlanner().planCopy(source: source, destination: destination)

            XCTAssertTrue(plan.new.isEmpty)
            XCTAssertTrue(plan.existing.isEmpty)
            XCTAssertEqual(plan.conflicts.map(\.path), ["DCIM/a.ARW"])
        }
    }

    func testSelectedFilePlanIgnoresUnassignedCardFiles() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("src", isDirectory: true)
            let destination = root.appendingPathComponent("dst", isDirectory: true)
            let includedData = Data(repeating: 0x41, count: 256)
            try writeFile(source.appendingPathComponent("DCIM/included.ARW"), includedData)
            try writeFile(source.appendingPathComponent("DCIM/other-event.ARW"), Data(repeating: 0x42, count: 2_048))
            try writeFile(destination.appendingPathComponent("DCIM/included.ARW"), includedData)

            let selected = [
                FileRecord(path: "DCIM/included.ARW", size: Int64(includedData.count), modifiedAt: .now)
            ]
            let plan = try ArchivePlanner().planCopy(
                source: source,
                destination: destination,
                files: selected
            )

            XCTAssertEqual(plan.existing.map(\.path), ["DCIM/included.ARW"])
            XCTAssertTrue(plan.new.isEmpty)
            XCTAssertTrue(plan.conflicts.isEmpty)
            XCTAssertFalse((plan.new + plan.existing + plan.conflicts).contains { $0.path.contains("other-event") })
        }
    }

    func testMetadataPreviewIsFastButDoesNotClaimChecksumVerification() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("src", isDirectory: true)
            let destination = root.appendingPathComponent("dst", isDirectory: true)
            try writeFile(source.appendingPathComponent("DCIM/a.ARW"), Data(repeating: 0x41, count: 4_096))
            try writeFile(destination.appendingPathComponent("DCIM/a.ARW"), Data(repeating: 0x42, count: 4_096))
            let selected = [
                FileRecord(path: "DCIM/a.ARW", size: 4_096, modifiedAt: .now)
            ]

            let preview = try ArchivePlanner().planCopyMetadata(
                source: source,
                destination: destination,
                files: selected
            )
            XCTAssertEqual(preview.existing.map(\.path), ["DCIM/a.ARW"])
            XCTAssertNil(preview.existing.first?.sha256)

            let verified = try ArchivePlanner().planCopy(
                source: source,
                destination: destination,
                files: selected
            )
            XCTAssertTrue(verified.existing.isEmpty)
            XCTAssertEqual(verified.conflicts.map(\.path), ["DCIM/a.ARW"])
        }
    }
}
