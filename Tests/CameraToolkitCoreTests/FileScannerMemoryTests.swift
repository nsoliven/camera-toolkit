import CameraToolkitCore
import Darwin
import Foundation
import XCTest

final class FileScannerMemoryTests: XCTestCase {
    func testHashingLargeSparseFileKeepsResidentMemoryBounded() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("large-camera-file.bin")
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 256 * 1024 * 1024)
            try handle.close()

            let before = residentBytes()
            let digest = try FileScanner.sha256(file)
            let growth = residentBytes() - before

            XCTAssertEqual(digest.count, 64)
            XCTAssertLessThan(
                growth,
                64 * 1024 * 1024,
                "Hashing must stream through a bounded buffer instead of retaining bytes from the whole camera file"
            )
        }
    }

    func testLargeFileHashingCoalescesProgressUpdates() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("large-camera-file.bin")
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 256 * 1024 * 1024)
            try handle.close()
            let counter = LockedCounter()

            _ = try FileScanner().scan(root: root, hashing: true) { _ in
                counter.increment()
            }

            XCTAssertLessThan(
                counter.value,
                32,
                "Hashing one large file must not enqueue one UI update for every 1 MiB chunk"
            )
        }
    }

    private func residentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        return Int64(info.resident_size)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
