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

    func testSamplerFindsMediaInsideNestedFolders() throws {
        try withTemporaryDirectory { root in
            let deep = root
                .appendingPathComponent("2026", isDirectory: true)
                .appendingPathComponent("09_September", isDirectory: true)
                .appendingPathComponent("Wedding", isDirectory: true)
                .appendingPathComponent("Card Copy", isDirectory: true)
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            try writeFile(deep.appendingPathComponent("DSC_0001.ARW"), Data(repeating: 0x41, count: 2 * 1024 * 1024))
            try writeFile(deep.appendingPathComponent("DSC_0002.ARW"), Data(repeating: 0x42, count: 2 * 1024 * 1024))
            try writeFile(deep.appendingPathComponent("._DSC_0001.ARW"), Data(repeating: 0x43, count: 4096))

            let result = try StorageBenchmarkService().benchmarkReadOnly(
                searchRoots: [root],
                byteLimit: 3 * 1024 * 1024
            )

            XCTAssertEqual(result.read.bytes, 3 * 1024 * 1024)
            XCTAssertEqual(result.sampledFileCount, 2)
        }
    }

    func testSamplerFallsBackToLaterRootsWhenAConfiguredSourceIsMissing() throws {
        try withTemporaryDirectory { root in
            try writeFile(root.appendingPathComponent("clip.mp4"), Data(repeating: 0x51, count: 2 * 1024 * 1024))
            let missing = root.appendingPathComponent("Not There", isDirectory: true)

            let result = try StorageBenchmarkService().benchmarkReadOnly(
                searchRoots: [missing, root],
                byteLimit: 1024 * 1024
            )

            XCTAssertEqual(result.read.bytes, 1024 * 1024)
            XCTAssertEqual(result.sampledFileCount, 1)
        }
    }

    func testOverlappingRootsDoNotSampleTheSameFileTwice() throws {
        try withTemporaryDirectory { root in
            let sub = root.appendingPathComponent("DCIM", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try writeFile(sub.appendingPathComponent("a.raw"), Data(repeating: 0x61, count: 2 * 1024 * 1024))
            try writeFile(root.appendingPathComponent("b.raw"), Data(repeating: 0x62, count: 2 * 1024 * 1024))

            let result = try StorageBenchmarkService().benchmarkReadOnly(
                searchRoots: [sub, root],
                byteLimit: 4 * 1024 * 1024
            )

            XCTAssertEqual(result.sampledFileCount, 2)
            XCTAssertEqual(result.read.bytes, 4 * 1024 * 1024)
        }
    }

    // MARK: - Write-path supervision

    /// The reported write rate counts the time the device takes to accept
    /// each chunk. The fake sink advances an injected clock per chunk, so a
    /// run can only be as fast as the "device" pretends to be — a page-cache
    /// measurement would report ~0 s and an impossible multi-GB/s rate.
    func testWriteMeasurementCountsDeviceFlushTimeNotCacheSpeed() throws {
        try withTemporaryDirectory { root in
            let clock = BenchmarkFakeClock()
            let service = StorageBenchmarkService(
                sinkFactory: { url, _ in
                    let sink = try FakeDeviceSink(url: url)
                    sink.beforeWrite = { clock.advance(by: 0.05) }
                    return sink
                },
                uptime: { clock.now }
            )
            let byteCount = StorageBenchmarkService.writeChunkByteCount * 4
            let result = try service.benchmarkReadWrite(directory: root, byteCount: byteCount)

            let write = try XCTUnwrap(result.write)
            XCTAssertEqual(write.bytes, byteCount)
            XCTAssertEqual(write.duration, 0.2, accuracy: 0.001)
            XCTAssertEqual(write.bytesPerSecond, Double(byteCount) / 0.2, accuracy: 1)
        }
    }

    /// Stop mid-write: the supervisor abandons the run without waiting for
    /// the parked sink, the temporary file is removed, and the call returns
    /// promptly instead of hanging the way the fsync stall did.
    func testCancelDuringAStalledWriteReturnsPromptlyAndRemovesTheFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sinkBox = SinkBox()
        defer { sinkBox.sink?.release() }
        let service = StorageBenchmarkService(
            sinkFactory: { url, _ in
                let sink = try FakeDeviceSink(url: url)
                sink.stallAfter = 0
                sinkBox.set(sink)
                return sink
            },
            stallTimeout: 60
        )
        let run = Task {
            try service.benchmarkReadWrite(directory: root, byteCount: 8 * 1024 * 1024)
        }
        let deadline = Date().addingTimeInterval(10)
        while (sinkBox.sink?.writeCallCount ?? 0) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(sinkBox.sink?.writeCallCount ?? 0, 0)

        let started = Date()
        run.cancel()
        let result = await run.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        guard case .failure(let error) = result else {
            return XCTFail("A cancelled write test must not produce a result")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    /// A sink that never finishes a chunk trips the watchdog, which reports
    /// the drive stopped responding in plain words — and still removes the
    /// temporary file.
    func testWatchdogAbortsAStalledWriteAndRemovesTheFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sinkBox = SinkBox()
        defer { sinkBox.sink?.release() }
        let service = StorageBenchmarkService(
            sinkFactory: { url, _ in
                let sink = try FakeDeviceSink(url: url)
                sink.stallAfter = 0
                sinkBox.set(sink)
                return sink
            },
            stallTimeout: 0.4
        )
        let started = Date()
        let result = await Task {
            try service.benchmarkReadWrite(directory: root, byteCount: 8 * 1024 * 1024)
        }.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        guard case .failure(let error) = result else {
            return XCTFail("A stalled write test must not produce a result")
        }
        XCTAssertTrue(error.localizedDescription.contains("stopped responding"))
        XCTAssertTrue(error.localizedDescription.contains("underpowered enclosure or cable"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    /// exFAT can drop a `._` AppleDouble twin next to the temp file; a
    /// finished run removes both.
    func testSuccessfulWriteRemovesAnyAppleDoubleTwin() throws {
        try withTemporaryDirectory { root in
            let service = StorageBenchmarkService(
                sinkFactory: { url, _ in
                    let sink = try FakeDeviceSink(url: url)
                    sink.dropsAppleDoubleTwin = true
                    return sink
                }
            )
            let result = try service.benchmarkReadWrite(directory: root, byteCount: 8 * 1024 * 1024)
            XCTAssertEqual(result.write?.bytes, 8 * 1024 * 1024)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    /// The launch sweep deletes only `.CameraToolkit-SpeedTest-*.tmp` names —
    /// and their `._` twins — inside the folders it is given.
    func testStaleTemporaryFilesAreSweptByExactPrefixOnly() throws {
        try withTemporaryDirectory { root in
            let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
            let library = root.appendingPathComponent("Library", isDirectory: true)
            try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let prefix = StorageBenchmarkService.temporaryFilePrefix

            let stale = try writeFile(buffer.appendingPathComponent("\(prefix)abc.tmp"), "x")
            let twin = try writeFile(buffer.appendingPathComponent("._\(prefix)abc.tmp"), "x")
            let staleLibrary = try writeFile(library.appendingPathComponent("\(prefix)def.tmp"), "x")
            let keepers = [
                try writeFile(buffer.appendingPathComponent("\(prefix)notes.txt"), "x"),
                try writeFile(buffer.appendingPathComponent("CameraToolkit-SpeedTest-abc.tmp"), "x"),
                try writeFile(buffer.appendingPathComponent("keep.tmp"), "x"),
                try writeFile(buffer.appendingPathComponent("._DSC00001.ARW"), "x"),
            ]
            // A directory wearing the name is not a stale temp file either.
            let folder = buffer.appendingPathComponent("\(prefix)folder.tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let removed = StorageBenchmarkService().removeStaleTemporaryFiles(in: [buffer, library])

            XCTAssertEqual(
                Set(removed.map(\.lastPathComponent)),
                Set([stale.lastPathComponent, twin.lastPathComponent, staleLibrary.lastPathComponent])
            )
            for url in [stale, twin, staleLibrary] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            }
            for url in keepers + [folder] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }
}

/// A lock-step clock the test advances — lets a fake sink charge real
/// "device time" per chunk without slowing the test run.
private final class BenchmarkFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 1_000

    var now: TimeInterval { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

/// Lets a test reach the sink the service builds inside its worker.
private final class SinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FakeDeviceSink?

    var sink: FakeDeviceSink? { lock.withLock { stored } }

    func set(_ value: FakeDeviceSink) {
        lock.withLock { stored = value }
    }
}

/// The benchmark's device sink, faked: writes land in a real file so the
/// read-back phase still works, but the test controls how long a chunk
/// takes — and can park `writeChunk` the way a hung enclosure parks an
/// `fsync`.
private final class FakeDeviceSink: SpeedTestDeviceSink, @unchecked Sendable {
    private let url: URL
    private var handle: FileHandle?
    private let condition = NSCondition()
    private var released = false
    private var writeCalls = 0
    /// Chunks allowed to complete before `writeChunk` starts parking.
    var stallAfter = Int.max
    /// Runs before each chunk completes — the device-time test hooks the
    /// fake clock here.
    var beforeWrite: (@Sendable () -> Void)?
    /// When set, the first chunk also drops a `._` AppleDouble twin beside
    /// the temp file, like an exFAT mount would.
    var dropsAppleDoubleTwin = false

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    var writeCallCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return writeCalls
    }

    func writeChunk(_ bytes: UnsafeRawBufferPointer) throws {
        condition.lock()
        writeCalls += 1
        let calls = writeCalls
        while calls > stallAfter, !released {
            condition.wait()
        }
        condition.unlock()
        beforeWrite?()
        if dropsAppleDoubleTwin, calls == 1 {
            let twin = url.deletingLastPathComponent()
                .appendingPathComponent("._\(url.lastPathComponent)")
            FileManager.default.createFile(atPath: twin.path, contents: Data(count: 128))
        }
        try handle?.write(contentsOf: Data(bytes))
        try handle?.synchronize()
    }

    /// Lets a parked `writeChunk` return so the abandoned worker can exit.
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        try? handle?.close()
        handle = nil
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
