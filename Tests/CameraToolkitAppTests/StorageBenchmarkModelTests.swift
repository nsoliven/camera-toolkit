import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

@MainActor
final class StorageBenchmarkModelTests: XCTestCase {
    func testCurrentTransferSourceWinsOverTheFirstConfiguredCamera() {
        let lexar = target(id: "lexar", root: "/Volumes/LEXAR")
        let osmo = target(id: "osmo", root: "/Volumes/Osmo360")
        let queue = TransferQueueSnapshot(
            sourcePath: "/Volumes/Osmo360/DCIM/CAM_001",
            destinationPath: "/Volumes/Buffer/Card Copy",
            items: [],
            totalBytes: 0
        )

        let selected = StorageBenchmarkTargetDiscovery.currentSourceTarget(
            in: [lexar, osmo],
            transferQueue: queue
        )

        XCTAssertEqual(selected?.id, "osmo")
    }

    func testSafetySimulationSourceIsNotPresentedAsAPhysicalDrive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitBenchmarkTargets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let demo = root.appendingPathComponent("Safety Test", isDirectory: true)
        let source = demo.appendingPathComponent("Source Card", isDirectory: true)
        let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)

        let configuration = AppConfiguration(
            demoRootPath: demo.path,
            importSourcePath: source.path,
            archivePath: root.appendingPathComponent("Library").path,
            bufferPath: buffer.path,
            configuredLocations: [
                ConfiguredLocation(role: .importSource, name: "Safety Test Card", path: source.path),
                ConfiguredLocation(role: .buffer, name: "Buffer", path: buffer.path)
            ],
            activityLogPath: root.appendingPathComponent("activity.jsonl").path
        )

        let targets = StorageBenchmarkTargetDiscovery.discover(
            configuration: configuration,
            transferQueue: nil,
            mountedVolumes: []
        )

        XCTAssertFalse(targets.contains { $0.roleNames.contains("Camera Source") })
        XCTAssertTrue(targets.contains { $0.roleNames.contains("Buffer") })
    }

    func testBufferThatIsAlsoACameraSourceGetsReadAndWrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitBenchmark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card Drop", isDirectory: true)
        let buffer = root.appendingPathComponent("Toolkit Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)

        let volume = MountedVolumeInfo(
            url: root,
            name: "Buffer",
            fileSystemType: "exfat",
            mountSource: "/dev/disk8s2",
            isRemovable: true,
            isEjectable: true,
            isReadOnly: false,
            isDiskImage: false,
            totalCapacity: 1_000_000_000_000
        )
        let configuration = AppConfiguration(
            demoRootPath: root.appendingPathComponent("Safety Test").path,
            importSourcePath: source.path,
            archivePath: root.appendingPathComponent("Library").path,
            bufferPath: buffer.path,
            configuredLocations: [
                ConfiguredLocation(role: .importSource, name: "Card Drop", path: source.path),
                ConfiguredLocation(role: .buffer, name: "Buffer", path: buffer.path)
            ],
            activityLogPath: root.appendingPathComponent("activity.jsonl").path
        )

        let targets = StorageBenchmarkTargetDiscovery.discover(
            configuration: configuration,
            transferQueue: nil,
            mountedVolumes: [volume]
        )

        let drive = try XCTUnwrap(targets.first { $0.roleNames.contains("Buffer") })
        XCTAssertEqual(drive.id, root.path)
        XCTAssertEqual(drive.access, .readWrite)
        XCTAssertEqual(drive.writeDirectory?.standardizedFileURL, buffer.standardizedFileURL)
        XCTAssertTrue(drive.roleNames.contains("Camera Source"))
        // The sampler falls back to the whole volume so a configured source
        // folder with no media cannot make the drive look untestable.
        XCTAssertTrue(drive.searchRoots.contains(source.standardizedFileURL))
        XCTAssertTrue(drive.searchRoots.contains(root.standardizedFileURL))
    }

    func testCameraCardNeverGetsAWriteTest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitBenchmark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let card = root.appendingPathComponent("LEXAR", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)

        let volume = MountedVolumeInfo(
            url: card,
            name: "LEXAR",
            fileSystemType: "exfat",
            mountSource: "/dev/disk9s1",
            isRemovable: true,
            isEjectable: true,
            isReadOnly: false,
            isDiskImage: false,
            totalCapacity: 256_000_000_000
        )
        let configuration = AppConfiguration(
            demoRootPath: root.appendingPathComponent("Safety Test").path,
            importSourcePath: card.path,
            archivePath: root.appendingPathComponent("Library").path,
            bufferPath: root.appendingPathComponent("Buffer").path,
            configuredLocations: [
                ConfiguredLocation(role: .importSource, name: "LEXAR", path: card.path)
            ],
            activityLogPath: root.appendingPathComponent("activity.jsonl").path
        )

        let targets = StorageBenchmarkTargetDiscovery.discover(
            configuration: configuration,
            transferQueue: nil,
            mountedVolumes: [volume]
        )

        let drive = try XCTUnwrap(targets.first { $0.roleNames.contains("Camera Source") })
        XCTAssertEqual(drive.access, .readOnly)
        XCTAssertNil(drive.writeDirectory)
    }

    func testMountedDiskImagesAndVirtualVolumesAreHidden() throws {
        let dmg = MountedVolumeInfo(
            url: URL(fileURLWithPath: "/Volumes/GatherV2 0.54.0-universal", isDirectory: true),
            name: "GatherV2 0.54.0-universal",
            fileSystemType: "hfs",
            mountSource: "/dev/disk11s1",
            isRemovable: true,
            isEjectable: true,
            isReadOnly: true,
            isDiskImage: true,
            totalCapacity: 18_000_000
        )
        let virtual = MountedVolumeInfo(
            url: URL(fileURLWithPath: "/Volumes/SyntheticThing", isDirectory: true),
            name: "SyntheticThing",
            fileSystemType: "autofs",
            mountSource: "map auto",
            isRemovable: false,
            isEjectable: false,
            isReadOnly: true,
            isDiskImage: false,
            totalCapacity: nil
        )
        let configuration = AppConfiguration(
            demoRootPath: "/tmp/ct-demo",
            importSourcePath: "/tmp/ct-demo/From Folder",
            archivePath: "/tmp/ct-lib/Originals",
            bufferPath: "/tmp/ct-buf",
            configuredLocations: [],
            activityLogPath: "/tmp/ct-activity.jsonl"
        )

        let targets = StorageBenchmarkTargetDiscovery.discover(
            configuration: configuration,
            transferQueue: nil,
            mountedVolumes: [dmg, virtual]
        )

        XCTAssertFalse(targets.contains { $0.volumeInfo?.isDiskImage == true })
        XCTAssertFalse(targets.contains { $0.name == "GatherV2 0.54.0-universal" })
        XCTAssertFalse(targets.contains { $0.name == "SyntheticThing" })
    }

    /// While a write test owns a volume, `DriveActivityGate` holds the
    /// app's background disk work off it — and Stop still returns promptly
    /// even with the writer parked inside a chunk the way the enclosure's
    /// fsync stalled.
    func testRunningAWriteTestPausesBackgroundWorkOnThatVolume() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = root.appendingPathComponent("Drive", isDirectory: true)
        let buffer = drive.appendingPathComponent("Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)

        let gate = DriveActivityGate()
        let sink = BlockingBenchmarkSink()
        defer { sink.release() }
        let viewModel = StorageBenchmarkViewModel(
            driveActivityGate: gate,
            makeService: { StorageBenchmarkService(sinkFactory: { _, _ in sink }, stallTimeout: 30) }
        )
        let model = DashboardModel(
            jobs: [],
            configuration: AppConfiguration(
                demoRootPath: root.appendingPathComponent("Safety Test").path,
                importSourcePath: root.appendingPathComponent("Card").path,
                archivePath: root.appendingPathComponent("Library").path,
                bufferPath: buffer.path,
                configuredLocations: [
                    ConfiguredLocation(role: .buffer, name: "Buffer", path: buffer.path)
                ],
                activityLogPath: root.appendingPathComponent("activity.jsonl").path
            ),
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
        )
        viewModel.dashboardModel = model
        let target = StorageBenchmarkTarget(
            id: drive.path,
            name: "Drive",
            volumeRoot: drive,
            searchRoots: [drive],
            writeDirectory: buffer,
            roleNames: ["Buffer"],
            access: .readWrite,
            isAvailable: true,
            totalCapacity: nil
        )

        viewModel.run(target, kind: .write)
        // The fake sink parks inside its first chunk — the run is mid-write.
        try await waitForTrue { sink.writeCallCount > 0 }
        XCTAssertTrue(viewModel.isRunning)
        XCTAssertTrue(gate.isPaused(for: drive))
        XCTAssertTrue(gate.isPaused(for: buffer.appendingPathComponent("deep.bin")))
        XCTAssertFalse(gate.isPaused(for: root.appendingPathComponent("Elsewhere", isDirectory: true)))
        XCTAssertTrue(model.isStorageBenchmarkRunning)

        let started = Date()
        viewModel.cancel()
        try await waitForTrue { !viewModel.isRunning }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertFalse(gate.isPaused(for: drive))
        XCTAssertFalse(model.isStorageBenchmarkRunning)
        XCTAssertEqual(
            viewModel.errors[target.id],
            "Cancelled. Any temporary speed-test file was removed."
        )
    }

    /// Launch cleanup removes `.CameraToolkit-SpeedTest-*.tmp` files — and
    /// `._` twins — from configured Buffer and Photo Library folders only.
    func testLaunchSweepRemovesStaleSpeedTestFilesFromConfiguredFolders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let buffer = root.appendingPathComponent("Buffer", isDirectory: true)
        let library = root.appendingPathComponent("Library/Originals", isDirectory: true)
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let prefix = StorageBenchmarkService.temporaryFilePrefix

        let staleBuffer = try writeTempFile(buffer.appendingPathComponent("\(prefix)abc.tmp"))
        let staleTwin = try writeTempFile(buffer.appendingPathComponent("._\(prefix)abc.tmp"))
        let staleLibrary = try writeTempFile(library.appendingPathComponent("\(prefix)def.tmp"))
        let keeper = try writeTempFile(buffer.appendingPathComponent("keep.tmp"))
        // Not a configured folder — out of scope, must survive.
        let untouched = try writeTempFile(elsewhere.appendingPathComponent("\(prefix)zzz.tmp"))

        let model = DashboardModel(
            jobs: [],
            configuration: AppConfiguration(
                demoRootPath: root.appendingPathComponent("Safety Test").path,
                importSourcePath: root.appendingPathComponent("Card").path,
                archivePath: library.path,
                bufferPath: buffer.path,
                configuredLocations: [
                    ConfiguredLocation(role: .buffer, name: "Buffer", path: buffer.path),
                    ConfiguredLocation(role: .archive, name: "Library", path: library.path)
                ],
                activityLogPath: root.appendingPathComponent("activity.jsonl").path
            ),
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
        )

        model.removeStaleSpeedTestFiles()

        try await waitForTrue { !FileManager.default.fileExists(atPath: staleBuffer.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTwin.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleLibrary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.path))
    }

    private func target(id: String, root: String) -> StorageBenchmarkTarget {
        let url = URL(fileURLWithPath: root, isDirectory: true)
        return StorageBenchmarkTarget(
            id: id,
            name: id,
            volumeRoot: url,
            searchRoots: [url],
            writeDirectory: nil,
            roleNames: ["Camera Source"],
            access: .readOnly,
            isAvailable: true,
            totalCapacity: nil
        )
    }

    private func waitForTrue(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for the speed test")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@discardableResult
private func writeTempFile(_ url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: url)
    return url
}

/// The benchmark's device sink, faked to park inside every `writeChunk`
/// until released — the same place a stalled enclosure parks an `fsync`.
private final class BlockingBenchmarkSink: SpeedTestDeviceSink, @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var writeCalls = 0

    var writeCallCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return writeCalls
    }

    func writeChunk(_ bytes: UnsafeRawBufferPointer) throws {
        condition.lock()
        writeCalls += 1
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func close() {}
}
