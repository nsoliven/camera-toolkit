import AppKit
import CameraToolkitCore
import Foundation
@testable import CameraToolkitApp
import XCTest

/// Background thumbnail warming: what order it works in, what it skips, when
/// it waits, and that it reads photos without changing them. Everything is
/// in temporary folders; "volumes" are paths a hook calls mounted or not.
final class ThumbnailWarmerTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }

    private func scratch(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CameraToolkitWarm-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func makeCache(_ name: String = "cache", limit: Int64 = 50_000_000) -> ThumbnailDiskCache {
        ThumbnailDiskCache(folder: scratch(name), byteLimit: limit)
    }

    private static func makeImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 64, height: 43, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 43))
        return context.makeImage()!
    }

    private func item(_ name: String, sources: [String]? = nil) -> ThumbnailWarmer.Item {
        ThumbnailWarmer.Item(key: "\(name)#512#0", sources: sources ?? ["/Volumes/Buffer/\(name)"], bucket: 512, orientation: 0)
    }

    /// A flag and a log the hooks and the test share.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _decoded: [String] = []
        private var _held = false
        private var _mounted = true
        private var _room = true

        var decoded: [String] { lock.withLock { _decoded } }
        var held: Bool {
            get { lock.withLock { _held } }
            set { lock.withLock { _held = newValue } }
        }
        var mounted: Bool {
            get { lock.withLock { _mounted } }
            set { lock.withLock { _mounted = newValue } }
        }
        var room: Bool {
            get { lock.withLock { _room } }
            set { lock.withLock { _room = newValue } }
        }
        func noteDecode(_ path: String) { lock.withLock { _decoded.append(path) } }
    }

    private let fastTiming = ThumbnailWarmer.Timing(
        holdPoll: .milliseconds(5),
        idlePoll: .milliseconds(5),
        awayRetry: .milliseconds(25)
    )

    private func makeWarmer(
        cache: ThumbnailDiskCache,
        probe: Probe,
        decode: (@Sendable (String) -> CGImage?)? = nil,
        exists: @escaping @Sendable (String) -> Bool = { _ in true }
    ) -> ThumbnailWarmer {
        let decoder: @Sendable (String) -> CGImage? = decode ?? { _ in Self.makeImage() }
        return ThumbnailWarmer(
            cache: cache,
            hooks: ThumbnailWarmer.Hooks(
                isHeld: { probe.held },
                hasRoom: { probe.room },
                isAvailable: { _ in probe.mounted },
                fileExists: exists,
                decode: { path, _, _ in
                    probe.noteDecode(path)
                    return decoder(path).map { TileImageLoader.DecodedTile(image: $0, cameraTurns: nil) }
                }
            ),
            timing: fastTiming
        )
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out waiting", file: file, line: line)
    }

    /// Long enough for a warmer that was going to do something to do it.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    // MARK: The order

    private func event(_ name: String, day: Double, parent: UUID? = nil) -> SavedCameraEvent {
        SavedCameraEvent(name: name, eventDate: Date(timeIntervalSince1970: 1_700_000_000 + day * 86_400), storagePolicy: .buffer, parentEventID: parent)
    }

    func testTheOpenEventComesFirstThenItsFamilyThenTheNewestEvents() {
        let oldest = event("Old Hike", day: 0)
        let trip = event("Trip 2026", day: 10)
        let beach = event("Beach Day", day: 11, parent: trip.id)
        let beachSunset = event("Sunset", day: 12, parent: beach.id)
        let city = event("City Weekend", day: 13, parent: trip.id)
        let party = event("Family Party", day: 40)
        let concert = event("Concert", day: 50)

        let order = ThumbnailWarmPlan.eventOrder(
            events: [oldest, trip, beach, beachSunset, city, party, concert],
            selectedEventID: beach.id
        ).map(\.name)

        XCTAssertEqual(order, ["Beach Day", "Sunset", "Trip 2026", "City Weekend", "Concert", "Family Party", "Old Hike"])
    }

    func testWithNothingOpenTheNewestEventsComeFirst() {
        let older = event("Older", day: 1)
        let newer = event("Newer", day: 2)
        XCTAssertEqual(ThumbnailWarmPlan.eventOrder(events: [older, newer], selectedEventID: nil).map(\.name), ["Newer", "Older"])
    }

    private func configuration(events: [SavedCameraEvent], assignments: [PhotoEventAssignment]) -> AppConfiguration {
        var configuration = AppConfiguration(
            demoRootPath: "/tmp/ct-demo",
            importSourcePath: "/Volumes/CARD",
            archivePath: "/Volumes/nas_share/Library/Originals",
            bufferPath: "/Volumes/Buffer/Camera Buffer",
            cameraLibraryRootPath: "/Volumes/nas_share/Library",
            catalogDatabasePath: "/tmp/ct-demo/catalog.sqlite",
            activityLogPath: "/tmp/ct-demo/activity.jsonl",
            selectedDeviceID: "cam-a"
        )
        configuration.savedEvents = events
        configuration.photoEventAssignments = assignments
        return configuration
    }

    private func assignment(_ path: String, event: SavedCameraEvent) -> PhotoEventAssignment {
        PhotoEventAssignment(
            sourceRootPath: "/Volumes/CARD",
            relativePath: path,
            fileSize: 1_000,
            modifiedAt: Date(timeIntervalSince1970: 1_772_000_000),
            eventID: event.id,
            deviceID: "cam-a"
        )
    }

    func testARawJpegPairIsOneThumbnailReadFromTheBufferThenTheNAS() throws {
        let trip = event("Trip 2026", day: 1)
        let input = ThumbnailWarmPlan.Input(
            configuration: configuration(events: [trip], assignments: [
                assignment("DSC00001.ARW", event: trip),
                assignment("DSC00001.JPG", event: trip),
                assignment("DSC00001.XMP", event: trip)
            ]),
            selectedEventID: trip.id,
            orientations: [:],
            bucket: 512
        )

        let items = ThumbnailWarmPlan.items(for: input)

        XCTAssertEqual(items.count, 1, "a pair and its sidecar draw one tile")
        let only = try XCTUnwrap(items.first)
        XCTAssertEqual(only.sources.count, 2)
        XCTAssertTrue(only.sources[0].hasPrefix("/Volumes/Buffer/"), "the Buffer drive is asked first")
        XCTAssertTrue(only.sources[1].hasPrefix("/Volumes/nas_share/"), "then the NAS")
        XCTAssertTrue(only.sources.allSatisfy { $0.hasSuffix("DSC00001.ARW") }, "the RAW is the file its tile shows")
        let identity = ThumbnailDiskCache.fileIdentity(OrganizeFile(path: only.sources[0], size: 1_000, modifiedAt: Date(timeIntervalSince1970: 1_772_000_000)))
        XCTAssertEqual(only.key, ThumbnailDiskCache.key(fileIdentity: identity, bucket: 512, orientation: nil), "the key is the one the tile will look up")
    }

    func testARotatedPhotoIsWarmedAtItsRotation() throws {
        let trip = event("Trip 2026", day: 1)
        let file = OrganizeFile(path: "/x/DSC00002.JPG", size: 1_000, modifiedAt: Date(timeIntervalSince1970: 1_772_000_000))
        let input = ThumbnailWarmPlan.Input(
            configuration: configuration(events: [trip], assignments: [assignment("DSC00002.JPG", event: trip)]),
            selectedEventID: nil,
            orientations: [DisplayRotation.fileKey(for: file): 1],
            bucket: 512
        )
        XCTAssertEqual(ThumbnailWarmPlan.items(for: input).first?.orientation, 1)
    }

    func testASizeTooBigToKeepPlansNothing() {
        let trip = event("Trip 2026", day: 1)
        let input = ThumbnailWarmPlan.Input(
            configuration: configuration(events: [trip], assignments: [assignment("DSC00003.JPG", event: trip)]),
            selectedEventID: nil,
            orientations: [:],
            bucket: 1_280
        )
        XCTAssertTrue(ThumbnailWarmPlan.items(for: input).isEmpty)
    }

    func testItemsAreReadInPlanOrder() async {
        let cache = makeCache()
        let probe = Probe()
        let warmer = makeWarmer(cache: cache, probe: probe)
        let names = (0..<12).map { "photo\($0)" }
        warmer.replacePlan(names.map { item($0) })
        warmer.start()
        defer { warmer.stop() }
        await waitUntil { warmer.currentCounts.saved == 12 }

        let decoded = probe.decoded
        XCTAssertEqual(Set(decoded), Set(names.map { "/Volumes/Buffer/\($0)" }))
        // Two readers may swap neighbours, never reach further.
        for (index, path) in decoded.enumerated() {
            let wanted = names.firstIndex { path.hasSuffix("/\($0)") }!
            XCTAssertLessThanOrEqual(abs(index - wanted), Self.reorderSlack, path)
        }
    }

    private static let reorderSlack = ThumbnailWarmer.maxConcurrent

    // MARK: Resuming

    func testWhatIsAlreadyCachedIsSkippedWithoutReadingThePhoto() async {
        let cache = makeCache()
        XCTAssertTrue(cache.storeAndWait(Self.makeImage(), forKey: item("done1").key))
        XCTAssertTrue(cache.storeAndWait(Self.makeImage(), forKey: item("done2").key))
        let probe = Probe()
        let warmer = makeWarmer(cache: cache, probe: probe)
        warmer.replacePlan(["done1", "new1", "done2", "new2"].map { item($0) })
        warmer.start()
        defer { warmer.stop() }

        await waitUntil { warmer.currentCounts.saved + warmer.currentCounts.alreadyCached == 4 }

        XCTAssertEqual(warmer.currentCounts.saved, 2)
        XCTAssertEqual(warmer.currentCounts.alreadyCached, 2)
        XCTAssertEqual(Set(probe.decoded), ["/Volumes/Buffer/new1", "/Volumes/Buffer/new2"])
    }

    func testAFreshWarmerPicksUpWhereTheLastOneStopped() async {
        let cache = makeCache()
        let plan = (0..<6).map { item("photo\($0)") }

        let firstProbe = Probe()
        let first = makeWarmer(cache: cache, probe: firstProbe)
        first.replacePlan(plan)
        first.start()
        await waitUntil { first.currentCounts.saved == 6 }
        first.stop()

        let secondProbe = Probe()
        let second = makeWarmer(cache: cache, probe: secondProbe)
        second.replacePlan(plan)
        second.start()
        defer { second.stop() }
        await waitUntil { second.currentCounts.alreadyCached == 6 }
        XCTAssertTrue(secondProbe.decoded.isEmpty, "nothing already on disk is read again")
    }

    func testANewPlanRestartsAtItsTopWithoutRedoingFinishedWork() async {
        let cache = makeCache()
        let probe = Probe()
        let warmer = makeWarmer(cache: cache, probe: probe)
        warmer.replacePlan([item("a"), item("b")])
        warmer.start()
        defer { warmer.stop() }
        await waitUntil { warmer.currentCounts.saved == 2 }

        warmer.replacePlan([item("c"), item("a"), item("b")])
        await waitUntil { warmer.currentCounts.saved == 3 }
        await settle()

        XCTAssertEqual(probe.decoded.filter { $0.hasSuffix("/a") }.count, 1)
        XCTAssertEqual(probe.decoded.filter { $0.hasSuffix("/c") }.count, 1)
    }

    // MARK: Waiting

    func testNothingIsReadWhileAJobHoldsItAndWorkResumesAfter() async {
        let cache = makeCache()
        let probe = Probe()
        probe.held = true
        let warmer = makeWarmer(cache: cache, probe: probe)
        warmer.replacePlan([item("a"), item("b")])
        warmer.start()
        defer { warmer.stop() }

        await settle()
        XCTAssertTrue(probe.decoded.isEmpty, "held: no read starts")
        XCTAssertEqual(warmer.currentCounts.saved, 0)

        probe.held = false
        await waitUntil { warmer.currentCounts.saved == 2 }
    }

    func testAJobStartingMidPassStopsTheNextRead() async {
        let cache = makeCache()
        let probe = Probe()
        let warmer = makeWarmer(cache: cache, probe: probe) { path in
            if path.hasSuffix("/photo0") { probe.held = true }
            return Self.makeImage()
        }
        warmer.replacePlan((0..<20).map { item("photo\($0)") })
        warmer.start()
        defer { warmer.stop() }

        await waitUntil { probe.held }
        await settle()
        let readsDuringHold = probe.decoded.count
        XCTAssertLessThanOrEqual(readsDuringHold, ThumbnailWarmer.maxConcurrent + 1, "only reads already under way finish")
        await settle()
        XCTAssertEqual(probe.decoded.count, readsDuringHold)

        probe.held = false
        await waitUntil { warmer.currentCounts.saved == 20 }
    }

    @MainActor
    func testRunningJobsSpeedTestsAndQueuedWorkAllHoldWarming() throws {
        let support = scratch("support")
        let model = DashboardModel(
            jobs: [],
            configuration: .defaults(applicationSupport: support),
            configurationStore: ConfigurationStore(url: support.appendingPathComponent("config.json"))
        )
        let workspace = EventsWorkspace(model: model)
        XCTAssertFalse(ThumbnailWarmingCoordinator.jobsHold(workspace), "a quiet app does not hold it")

        model.isBusy = true
        XCTAssertTrue(ThumbnailWarmingCoordinator.jobsHold(workspace), "any copy, sync, clear or move holds the job gate")
        model.isBusy = false
        XCTAssertFalse(ThumbnailWarmingCoordinator.jobsHold(workspace))

        model.isStorageBenchmarkRunning = true
        XCTAssertTrue(ThumbnailWarmingCoordinator.jobsHold(workspace))
    }

    func testAFullCacheOrFullDiskStopsNewReads() async {
        let cache = makeCache()
        let probe = Probe()
        probe.room = false
        let warmer = makeWarmer(cache: cache, probe: probe)
        warmer.replacePlan([item("a")])
        warmer.start()
        defer { warmer.stop() }
        await settle()
        XCTAssertTrue(probe.decoded.isEmpty)
        probe.room = true
        await waitUntil { warmer.currentCounts.saved == 1 }
    }

    func testAWriteThatFailsEndsThePassInsteadOfReadingEveryPhoto() async throws {
        let parent = scratch("blocked")
        let blocked = parent.appendingPathComponent("file-not-folder")
        try Data("x".utf8).write(to: blocked)
        let cache = ThumbnailDiskCache(folder: blocked, byteLimit: 1_000_000)
        let probe = Probe()
        let warmer = makeWarmer(cache: cache, probe: probe)
        warmer.replacePlan((0..<30).map { item("photo\($0)") })
        warmer.start()
        defer { warmer.stop() }
        await waitUntil { !probe.decoded.isEmpty }
        await settle()
        XCTAssertLessThanOrEqual(probe.decoded.count, ThumbnailWarmer.maxConcurrent, "not one read per remaining photo")
    }

    func testAStopEndsNewReads() async {
        let cache = makeCache()
        let probe = Probe()
        let warmer = makeWarmer(cache: cache, probe: probe) { _ in
            Thread.sleep(forTimeInterval: 0.01)
            return Self.makeImage()
        }
        warmer.replacePlan((0..<500).map { item("photo\($0)") })
        warmer.start()
        await waitUntil { probe.decoded.count >= 2 }
        warmer.stop()
        await settle()
        let afterStop = probe.decoded.count
        await settle()
        XCTAssertEqual(probe.decoded.count, afterStop, "nothing new starts after a stop")
        XCTAssertLessThan(afterStop, 500)
    }

    // MARK: Foreground first

    func testATileLoadingHoldsWarmingUntilItAndAQuietSpellAreOver() async throws {
        let volume = scratch("volume")
        let source = volume.appendingPathComponent("DSC00001.JPG")
        let bitmap = NSBitmapImageRep(cgImage: Self.makeImage())
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: source)

        let release = DispatchSemaphore(value: 0)
        let loader = TileImageLoader(
            driveActivityGate: DriveActivityGate(),
            willRead: { _ in release.wait() },
            purgesOnMemoryPressure: false,
            networkVolumeCheck: { _ in true }
        )
        XCTAssertTrue(loader.isForegroundQuiet(for: .seconds(1)), "nothing asked yet")

        let cache = makeCache()
        let probe = Probe()
        let warmer = ThumbnailWarmer(
            cache: cache,
            hooks: ThumbnailWarmer.Hooks(
                isHeld: { !loader.isForegroundQuiet(for: .milliseconds(100)) },
                isAvailable: { _ in true },
                fileExists: { _ in true },
                decode: { path, _, _ in
                    probe.noteDecode(path)
                    return TileImageLoader.DecodedTile(image: Self.makeImage(), cameraTurns: nil)
                }
            ),
            timing: fastTiming
        )

        let tile = Task { await loader.image(for: source, maximumPixelSize: 512) }
        await waitUntil { !loader.isForegroundQuiet(for: .milliseconds(100)) }

        warmer.replacePlan([item("a")])
        warmer.start()
        defer { warmer.stop() }
        await settle()
        XCTAssertTrue(probe.decoded.isEmpty, "the tile's decode is still running")

        release.signal()
        let decoded = await tile.value
        XCTAssertNotNil(decoded, "the tile got its picture first")
        await waitUntil { warmer.currentCounts.saved == 1 }
    }

    func testALateRequestKeepsTheLoaderBusyEvenWhenNothingIsDecoding() async throws {
        let loader = TileImageLoader(driveActivityGate: DriveActivityGate(), purgesOnMemoryPressure: false)
        let missing = scratch("gone").appendingPathComponent("DSC00009.JPG")
        _ = await loader.image(for: missing, maximumPixelSize: 512)
        XCTAssertFalse(loader.isForegroundQuiet(for: .seconds(30)), "a request just happened")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(loader.isForegroundQuiet(for: .milliseconds(20)))
    }

    @MainActor
    func testScrollingHoldsWarmingUntilItEnds() async throws {
        let center = NotificationCenter()
        let monitor = ThumbnailWarmScrollMonitor(center: center)
        XCTAssertTrue(monitor.isQuiet(for: .seconds(5)))
        let scrollView = NSScrollView()

        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        XCTAssertFalse(monitor.isQuiet(for: .zero), "a live scroll is running")

        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        XCTAssertFalse(monitor.isQuiet(for: .seconds(30)), "too soon after it ended")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(monitor.isQuiet(for: .milliseconds(20)))
    }

    // MARK: Sources

    func testAMissingSourceStopsWithoutReadingAndPicksUpWhenItReturns() async {
        let cache = makeCache()
        let probe = Probe()
        probe.mounted = false
        let warmer = makeWarmer(cache: cache, probe: probe)
        warmer.replacePlan((0..<5).map { item("photo\($0)") })
        warmer.start()
        defer { warmer.stop() }

        await settle()
        await settle()
        XCTAssertTrue(probe.decoded.isEmpty, "no read of a volume that is not there")
        XCTAssertEqual(warmer.currentCounts.saved, 0)
        XCTAssertEqual(warmer.currentCounts.failed, 0, "absent is not failed")
        // 240 ms at one look per 25 ms: a timer, not a spin.
        XCTAssertLessThanOrEqual(warmer.currentCounts.passes, 16, "looks again on a timer, never in a tight loop")

        probe.mounted = true
        await waitUntil { warmer.currentCounts.saved == 5 }
    }

    func testAVolumeLeavingMidReadIsNotCountedAsABadFile() async {
        let cache = makeCache()
        let probe = Probe()
        let warmer = makeWarmer(cache: cache, probe: probe) { path in
            if path.hasSuffix("/photo0") {
                probe.mounted = false
                return nil
            }
            return Self.makeImage()
        }
        warmer.replacePlan([item("photo0")])
        warmer.start()
        defer { warmer.stop() }
        await waitUntil { !probe.decoded.isEmpty }
        await settle()
        XCTAssertEqual(warmer.currentCounts.failed, 0)
        XCTAssertEqual(probe.decoded.count, 1, "nothing is read while it is away")

        // Back again, the same photo now reads.
        let back = makeWarmer(cache: cache, probe: probe)
        probe.mounted = true
        back.replacePlan([item("photo0")])
        back.start()
        defer { back.stop() }
        await waitUntil { back.currentCounts.saved == 1 }
    }

    func testAFileThatCannotBeReadIsSkippedAndNotTriedAgain() async {
        let cache = makeCache()
        let probe = Probe()
        let warmer = makeWarmer(cache: cache, probe: probe) { path in
            path.hasSuffix("/bad") ? nil : Self.makeImage()
        }
        let plan = [item("bad"), item("good")]
        warmer.replacePlan(plan)
        warmer.start()
        defer { warmer.stop() }
        await waitUntil { warmer.currentCounts.saved == 1 && warmer.currentCounts.failed == 1 }

        for _ in 0..<5 {
            warmer.replacePlan(plan)
            await settle()
        }
        XCTAssertEqual(probe.decoded.filter { $0.hasSuffix("/bad") }.count, 1, "a bad file is not retried")
        XCTAssertEqual(warmer.currentCounts.failed, 1)
    }

    func testTheBufferIsPreferredAndTheNASIsTheFallback() async {
        let cache = makeCache()
        let probe = Probe()
        let buffer = "/Volumes/Buffer/2026/DSC00001.ARW"
        let nas = "/Volumes/nas_share/2026/DSC00001.ARW"
        let onlyNAS = "/Volumes/Buffer/2026/DSC00002.ARW"
        let warmer = makeWarmer(cache: cache, probe: probe, exists: { $0 != onlyNAS })
        warmer.replacePlan([
            item("one", sources: [buffer, nas]),
            item("two", sources: [onlyNAS, "/Volumes/nas_share/2026/DSC00002.ARW"])
        ])
        warmer.start()
        defer { warmer.stop() }
        await waitUntil { warmer.currentCounts.saved == 2 }

        XCTAssertEqual(Set(probe.decoded), [buffer, "/Volumes/nas_share/2026/DSC00002.ARW"], "the Buffer when it has the file, the NAS when not")
    }

    // MARK: Safety

    func testWarmingChangesNothingBesideThePhotosAndWritesOnlyToTheCache() async throws {
        let volume = scratch("buffer")
        var sources: [URL] = []
        for index in 0..<4 {
            let url = volume.appendingPathComponent(String(format: "DSC%05d.JPG", index))
            try XCTUnwrap(NSBitmapImageRep(cgImage: Self.makeImage()).representation(using: .jpeg, properties: [:])).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_772_000_000 + Double(index))], ofItemAtPath: url.path)
            sources.append(url)
        }
        func snapshot() throws -> [String: [String]] {
            var result: [String: [String]] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: volume.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: volume.appendingPathComponent(name).path)
                result[name] = ["\(attributes[.size] ?? "")", "\(attributes[.modificationDate] ?? "")"]
            }
            return result
        }
        let before = try snapshot()
        let cacheFolder = scratch("cache")
        let cache = ThumbnailDiskCache(folder: cacheFolder, byteLimit: 50_000_000)
        let warmer = ThumbnailWarmer(
            cache: cache,
            hooks: ThumbnailWarmer.Hooks(
                isAvailable: { _ in true },
                decode: { TileImageLoader.decode(url: URL(filePath: $0, directoryHint: .notDirectory), maximumPixelSize: $1, orientation: $2) }
            ),
            timing: fastTiming
        )
        warmer.replacePlan(sources.map { item($0.lastPathComponent, sources: [$0.path]) })
        warmer.start()
        defer { warmer.stop() }
        await waitUntil { warmer.currentCounts.saved == 4 }

        XCTAssertEqual(try snapshot(), before, "no photo renamed, touched or removed, no sidecar added")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: volume.path).count, 4)
        XCTAssertGreaterThan(cache.measuredBytes(), 0, "the thumbnails are in the cache folder")
    }
}
