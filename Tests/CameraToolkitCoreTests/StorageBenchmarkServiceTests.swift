import CameraToolkitCore
import Foundation
import XCTest

final class StorageBenchmarkServiceTests: XCTestCase {
    func testReadOnlyBenchmarkNeverChangesSourceFiles() throws {
        try withTemporaryDirectory { root in
            try writeFile(root.appendingPathComponent("clip-one.bin"), Data(repeating: 0x31, count: 3 * 1024 * 1024))
            try writeFile(root.appendingPathComponent("clip-two.bin"), Data(repeating: 0x72, count: 3 * 1024 * 1024))
            let before = try treeBytes(root)

            let result = try StorageBenchmarkService().benchmarkReadOnly(
                searchRoots: [root],
                byteLimit: 4 * 1024 * 1024
            )

            XCTAssertEqual(try treeBytes(root), before)
            XCTAssertEqual(result.read.bytes, 4 * 1024 * 1024)
            XCTAssertGreaterThan(result.read.bytesPerSecond, 0)
            XCTAssertNil(result.write)
            XCTAssertEqual(result.sampledFileCount, 2)
        }
    }

    func testReadWriteBenchmarkRemovesItsTemporaryFile() throws {
        try withTemporaryDirectory { root in
            let result = try StorageBenchmarkService().benchmarkReadWrite(
                directory: root,
                byteCount: 8 * 1024 * 1024
            )

            XCTAssertEqual(result.read.bytes, 8 * 1024 * 1024)
            XCTAssertEqual(result.write?.bytes, 8 * 1024 * 1024)
            XCTAssertGreaterThan(result.read.bytesPerSecond, 0)
            XCTAssertGreaterThan(result.write?.bytesPerSecond ?? 0, 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testReadOnlyBenchmarkExplainsWhyAnEmptySourceCannotBeTested() throws {
        try withTemporaryDirectory { root in
            XCTAssertThrowsError(
                try StorageBenchmarkService().benchmarkReadOnly(
                    searchRoots: [root],
                    byteLimit: 1024
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("Camera sources stay read-only"))
            }
        }
    }

    func testProgressIsCoalescedAndNamesBothDestinationPhases() throws {
        try withTemporaryDirectory { root in
            let phases = LockedStrings()
            _ = try StorageBenchmarkService().benchmarkReadWrite(
                directory: root,
                byteCount: 16 * 1024 * 1024
            ) { update in
                phases.append(update.phase)
            }

            XCTAssertTrue(phases.values.contains("Testing destination write speed"))
            XCTAssertTrue(phases.values.contains("Testing destination read speed"))
            XCTAssertLessThan(phases.values.count, 16)
        }
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
