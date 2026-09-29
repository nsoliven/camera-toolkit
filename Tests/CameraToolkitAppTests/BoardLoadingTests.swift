import AppKit
import CameraToolkitCore
import Foundation
import XCTest
@testable import CameraToolkitApp

/// "When things need to load they should load instantly — fine to show a
/// blank image while it checks the NAS, but nothing should block."
@MainActor
final class BoardLoadingTests: XCTestCase {
    private func hangNASRoot(_ library: MoveLibrary, seconds: UInt32) {
        let nas = library.workspace.locations.nasRoot.path
        library.workspace.placeResponseProbe = { url in
            if url.path == nas { sleep(seconds) }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private func waitUntil(timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - First tiles never wait for the NAS

    func testFirstTilesDoNotWaitForAHungNASRoot() async throws {
        try await eachLibrary(MoveLibrary.Shape(parentOwn: 200, harbor: 0, island: 0, road: 0, elsewhere: 0, catalogBacked: false)) { library, mode in
        let workspace = library.workspace
        // The NAS root does not answer for 10 s and the check would wait
        // 8 s for it — before, the board stayed empty for all of that.
        workspace.placeResponseTimeout = 8
        hangNASRoot(library, seconds: 10)

        let start = ProcessInfo.processInfo.systemUptime
        let refresh = Task { await workspace.refreshEvent(library.parentID) }
        try await waitUntil { workspace.eventStacks[library.parentID]?.isEmpty == false }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("TIMING|hung NAS root, first tiles after \(elapsed * 1_000) ms")
        XCTAssertLessThan(elapsed, 3, "the first tiles waited for the NAS")
        // The reachability answer lands later and only gates what follows.
        XCTAssertNil(workspace.eventReachability[library.parentID])
        refresh.cancel()
        workspace.placeResponseTimeout = 0.2
        try await waitUntil(timeout: 30) { workspace.eventReachability[library.parentID] != nil }
        XCTAssertTrue(workspace.eventReachability[library.parentID]?.offlinePlaces.contains { $0.role == .nas } == true)
        }
    }

    func testTheWholeGridOfALargeEventDoesNotWaitForAHungNASRoot() async throws {
        try await eachLibrary(
            MoveLibrary.Shape(parentOwn: 3_000, harbor: 0, island: 0, road: 0, elsewhere: 0, catalogBacked: false),
            populateNAS: false
        ) { library, mode in
        let workspace = library.workspace
        workspace.placeResponseTimeout = 8
        hangNASRoot(library, seconds: 10)
        let start = ProcessInfo.processInfo.systemUptime
        let refresh = Task { await workspace.refreshEvent(library.parentID) }
        // Not just the first screen: the whole implied grid, which depends on
        // the mount table alone, is up long before the NAS answers.
        try await waitUntil { workspace.eventStacks[library.parentID]?.flatMap(\.files).count == 3_000 }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        XCTAssertNil(workspace.eventReachability[library.parentID], "the NAS check is still out")
        refresh.cancel()
        }
    }

    // MARK: - Family boards

    /// A parent with no files of its own used to publish an empty grid from
    /// its first screen, and the board turned that into "Drives Not
    /// Connected". Its first screen is now the family's earliest files.
    func testFamilyWithNoFilesOfItsOwnPublishesTilesAndNeverAnEmptyGrid() async throws {
        try await eachLibrary(MoveLibrary.Shape(parentOwn: 0, harbor: 400, island: 400, road: 400, elsewhere: 0, catalogBacked: false)) { library, mode in
        let workspace = library.workspace
        // Some place is offline, so the board is armed to say "not connected".
        workspace.placeResponseTimeout = 0.3
        hangNASRoot(library, seconds: 2)

        var published: [[OrganizeStack]] = []
        let refresh = Task { await workspace.refreshEvent(library.parentID) }
        var sawEmpty = false
        var sawPlaceholdersOrTiles = false
        while !(refresh.isCancelled) {
            let stacks = workspace.eventStacks[library.parentID]
            if let stacks {
                if stacks.isEmpty { sawEmpty = true } else if published.last?.count != stacks.count { published.append(stacks) }
            }
            if workspace.eventBoardShowsPlaceholders(library.parentID) || stacks?.isEmpty == false { sawPlaceholdersOrTiles = true }
            if workspace.eventsLoading.isEmpty, stacks != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        await refresh.value
        XCTAssertFalse(sawEmpty, "the board published an empty grid while its drive was up")
        XCTAssertTrue(sawPlaceholdersOrTiles)
        let first = try XCTUnwrap(published.first)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(workspace.eventStacks[library.parentID]?.flatMap(\.files).count, 1_200)
        }
    }

    func testPlaceholdersStandInWhileFilesAreOnTheirWayAndNeverOnceTheLoadFinished() async throws {
        try await eachLibrary(MoveLibrary.Shape(parentOwn: 0, harbor: 60, island: 60, road: 0, elsewhere: 0, catalogBacked: false)) { library, mode in
        let workspace = library.workspace
        // Nothing resolves to a path, so no tile can be drawn yet; the NAS
        // check parks the pipeline behind it.
        workspace.eventPathResolver = { _ in nil }
        workspace.placeResponseTimeout = 3
        hangNASRoot(library, seconds: 5)
        let refresh = Task { await workspace.refreshEvent(library.parentID) }
        try await waitUntil { workspace.eventsLoading.contains(library.parentID) }
        XCTAssertNil(workspace.eventStacks[library.parentID], "no empty grid is published")
        XCTAssertTrue(workspace.eventBoardShowsPlaceholders(library.parentID))
        await refresh.value
        // The load finished with nothing to show: now the verdict is honest.
        XCTAssertFalse(workspace.eventBoardShowsPlaceholders(library.parentID))
        XCTAssertTrue(workspace.eventsLoading.isEmpty)
        }
    }

    func testNoPlaceholdersWithoutAnyLoadOrWithoutCatalogFiles() async throws {
        try await eachLibrary(MoveLibrary.Shape(parentOwn: 0, harbor: 20, island: 0, road: 0, elsewhere: 0, catalogBacked: false)) { library, mode in
        let workspace = library.workspace
        // Nothing is loading: a board with no tiles is a finished answer.
        XCTAssertFalse(workspace.eventBoardShowsPlaceholders(library.parentID))
        workspace.eventsLoading = [library.parentID]
        XCTAssertTrue(workspace.eventBoardShowsPlaceholders(library.parentID))
        // A brand-new event has no catalog files to wait for.
        let empty = try XCTUnwrap(workspace.createEvent(name: "Nothing Yet", date: Date(), policy: .buffer))
        workspace.eventsLoading = [empty]
        XCTAssertFalse(workspace.eventBoardShowsPlaceholders(empty))
        // Tiles on screen mean no placeholders.
        workspace.eventsLoading = [library.parentID]
        await workspace.refreshEvent(library.parentID)
        workspace.eventsLoading = [library.parentID]
        XCTAssertFalse(workspace.eventBoardShowsPlaceholders(library.parentID))
        }
    }

    // MARK: - Buffer unplugged, everything on the NAS

    /// The user's screen: the Buffer drive is unplugged, the NAS is mounted,
    /// and a 1,856-file subevent lives only on the NAS. The board is the whole
    /// grid at once — drawn at each file's implied NAS mirror path, with no
    /// stat anywhere on the way — while the NAS check and the presence sweep
    /// run behind it.
    func testBufferOfflineOpensTheWholeGridFromTheNASMirrorWithoutAnyNASStat() async throws {
        try await eachLibrary(
            MoveLibrary.Shape(parentOwn: 0, harbor: 1_856, island: 0, road: 0, elsewhere: 0, catalogBacked: false),
            modes: [.nasOnly]
        ) { library, mode in
        let workspace = library.workspace
        let model = library.model
        // `.nasOnly`: the Buffer's volume is gone from the mount table and the
        // NAS stand-in holds every file at its mirror path.
        let locations = workspace.locations
        XCTAssertFalse(VolumeInfo.isAvailable(locations.bufferRoot), "the test's Buffer must be unmounted")
        XCTAssertEqual(model.configuration.photoEventAssignments.filter { $0.eventID == library.harborID }.count, 1_856)
        // Every NAS stat costs 20 ms, and the NAS check itself is slow enough
        // to hold the presence sweep back while the grid is inspected.
        let stats = MovePresenceProbe(nasRoot: locations.nasRoot.path, nasDelayMicroseconds: 20_000)
        workspace.presenceProbe = stats.probe
        let nas = locations.nasRoot.path
        workspace.placeResponseTimeout = 6
        workspace.placeResponseProbe = { url in
            if url.path == nas { usleep(1_500_000) }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        workspace.selection = .event(library.harborID)
        let start = ProcessInfo.processInfo.systemUptime
        let refresh = Task { await workspace.refreshEvent(library.harborID) }
        try await waitUntil { workspace.eventStacks[library.harborID]?.isEmpty == false }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("TIMING|Buffer unplugged, 1,856 files on the NAS: whole grid after \(elapsed * 1_000) ms, NAS stats so far \(stats.nasStats)")

        let stacks = try XCTUnwrap(workspace.eventStacks[library.harborID])
        // ~0.1 s on an idle machine; the budget leaves room for a loaded one and
        // is still far under the seconds the NAS check and sweep used to cost.
        XCTAssertLessThan(elapsed, 0.75, "the grid waited")
        XCTAssertEqual(stacks.flatMap(\.files).count, 1_856, "the first grid is the whole board")
        XCTAssertNil(workspace.eventBuildRemainders[library.harborID], "nothing is still to come")
        XCTAssertEqual(stats.nasStats, 0, "a NAS stat sat on the path to the first paint")
        XCTAssertTrue(stacks.flatMap(\.files).allSatisfy { $0.path.hasPrefix(nas + "/") }, "tiles point at the NAS mirror")
        XCTAssertFalse(workspace.eventBoardShowsPlaceholders(library.harborID), "no spinner over a grid that is up")
        XCTAssertNil(workspace.presence[library.harborID], "presence has not landed yet")
        // Grouping (scrolling) and selection work before presence finishes.
        let groups = workspace.eventBoardGroups(library.harborID, stacks: stacks, grouping: .day, sort: OrganizeStackSort(key: .captureTime, ascending: true))
        XCTAssertEqual(groups.flatMap(\.stacks).count, stacks.count)
        workspace.selectStacks(stacks.prefix(5).map(\.id))
        XCTAssertEqual(workspace.selectedStackIDs.count, 5)

        // Let the NAS answer and presence run (fast stats now).
        stats.nasDelayMicroseconds = 0
        await refresh.value
        XCTAssertEqual(workspace.presence[library.harborID]?.onArchive, 1_856, "the strip fills in behind the grid")
        XCTAssertEqual(
            workspace.eventStacks[library.harborID]?.flatMap(\.files).map(\.path).sorted(),
            stacks.flatMap(\.files).map(\.path).sorted(),
            "the grid was not re-laid out"
        )
        XCTAssertEqual(workspace.selectedStackIDs.count, 5, "selection survived the presence result")
        XCTAssertEqual(workspace.eventReachability[library.harborID]?.isOffline, false)
        }
    }

    /// Neither the Buffer nor the NAS is mounted: the catalog is all there
    /// is. The board is still its grid, drawn at the NAS mirror paths with
    /// blank tiles — no "not connected" screen, no spinner, no wait.
    func testNothingMountedStillDrawsTheWholeCatalogGrid() async throws {
        try await eachLibrary(
            MoveLibrary.Shape(parentOwn: 0, harbor: 700, island: 500, road: 0, elsewhere: 0, catalogBacked: false),
            modes: [.nothingMounted]
        ) { library, mode in
        let workspace = library.workspace
        let start = ProcessInfo.processInfo.systemUptime
        let refresh = Task { await workspace.refreshEvent(library.parentID) }
        try await waitUntil { workspace.eventStacks[library.parentID]?.isEmpty == false }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("TIMING|nothing mounted, 1,200 catalog files: grid after \(elapsed * 1_000) ms")
        XCTAssertLessThan(elapsed, 0.5)
        let stacks = try XCTUnwrap(workspace.eventStacks[library.parentID])
        XCTAssertEqual(stacks.flatMap(\.files).count, 1_200)
        XCTAssertFalse(workspace.eventBoardShowsPlaceholders(library.parentID))
        // Selection and grouping work with no place answering.
        workspace.selectStacks(stacks.prefix(4).map(\.id))
        XCTAssertEqual(workspace.selectedStackIDs.count, 4)
        await refresh.value
        // The verdict of the check is a chip and a status line, never the grid.
        XCTAssertEqual(workspace.eventReachability[library.parentID]?.isOffline, true)
        XCTAssertEqual(workspace.eventStacks[library.parentID]?.flatMap(\.files).count, 1_200, "an offline report must not empty the board")
        XCTAssertEqual(workspace.selectedStackIDs.count, 4)
        XCTAssertTrue(workspace.eventsLoading.isEmpty)
        }
    }

    // MARK: - Pass one reads nothing

    /// The first screen paints from the mount table and the capture-date
    /// cache only: no header read, and no rewrite of the whole cache file.
    func testFirstPaintReadsNoHeadersAndNeverRewritesTheCaptureDateCache() async throws {
        try await eachLibrary(MoveLibrary.Shape(parentOwn: 300, harbor: 0, island: 0, road: 0, elsewhere: 0, catalogBacked: false)) { library, mode in
        let workspace = library.workspace
        let reads = ReadCounter()
        workspace.captureDateReadProbe = { url in reads.note(url); return nil }
        // Park the pipeline behind reachability so nothing but pass one runs.
        workspace.placeResponseTimeout = 6
        hangNASRoot(library, seconds: 8)
        let cacheFile = library.root.appendingPathComponent("Support/capture-dates.json")

        let refresh = Task { await workspace.refreshEvent(library.parentID) }
        try await waitUntil { workspace.eventStacks[library.parentID]?.isEmpty == false }
        XCTAssertEqual(reads.count, 0, "pass one read a header")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path), "pass one rewrote the capture-date cache")
        refresh.cancel()
        }
    }

    // MARK: - No main-thread filesystem work from tiles or NAS status

    func testCachedImageNeverTouchesTheFilesystem() async throws {
        let calls = ThreadRecorder()
        let loader = TileImageLoader(fileExists: { path in calls.note(); return false })
        let missing = URL(filePath: "/Volumes/NAS/never/there.ARW", directoryHint: .notDirectory)
        for _ in 0..<50 {
            XCTAssertNil(loader.cachedImage(for: missing, maximumPixelSize: 384))
        }
        XCTAssertEqual(calls.total, 0, "cachedImage stat'ed a file")
        // The decode path does check — off the main thread.
        _ = await loader.image(for: missing, maximumPixelSize: 384, timeout: .seconds(2))
        XCTAssertGreaterThan(calls.total, 0)
        XCTAssertEqual(calls.onMain, 0, "the decode path stat'ed on the main thread")
    }

    func testConnectivityAnswersNeverStatOnTheMainThread() async throws {
        try await eachLibrary(.small, modes: [.bufferPlugged]) { library, mode in
        let workspace = library.workspace
        let calls = ThreadRecorder()
        // A folder on an external/network volume, the case a stale mount
        // can hang: the volume is "mounted", the check answers from a
        // background thread, and nothing on the way touches the disk.
        let volume = "/Volumes/CTConn-\(UUID().uuidString.prefix(8))"
        let mounted = VolumeInfo.mountedVolumePaths().union([volume])
        workspace.mountedVolumesProvider = { mounted }
        workspace.connectivityProbe = { _ in calls.note(); return false }
        let folder = URL(fileURLWithPath: "\(volume)/Photos", isDirectory: true)
        for _ in 0..<20 { _ = workspace.isConnected(folder: folder) }
        // The sidebar's answer is immediate (mount table), the truth follows
        // from a background check that redraws.
        XCTAssertTrue(workspace.isConnected(folder: folder))
        try await waitUntil { workspace.isConnected(folder: folder) == false }
        XCTAssertGreaterThan(calls.total, 0)
        XCTAssertEqual(calls.onMain, 0, "a connectivity check ran on the main thread")
        // One check per folder per connectivity revision, however often asked.
        let before = calls.total
        for _ in 0..<50 { _ = workspace.isConnected(folder: folder) }
        XCTAssertEqual(calls.total, before)
        }
    }

    func testAnUnmountedVolumeAnswersWithoutAnyCheck() async throws {
        try await eachLibrary(.small) { library, mode in
        let calls = ThreadRecorder()
        library.workspace.connectivityProbe = { _ in calls.note(); return true }
        XCTAssertFalse(library.workspace.isConnected(folder: URL(fileURLWithPath: "/Volumes/DefinitelyNotMounted-\(UUID().uuidString)/Photos", isDirectory: true)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.total, 0)
        }
    }

    // MARK: - Path resolver

    func testResolverOutputIsStringIdenticalToAppendingPathComponent() {
        let roots = [
            URL(fileURLWithPath: "/Volumes/Buffer Drive/Camera Buffer/2026/2026-08-26 Beach Day/Originals/Sony A7V", isDirectory: true),
            URL(fileURLWithPath: "/Users/someone/Pictures/Camera Buffer", isDirectory: true),
            URL(fileURLWithPath: "/tmp/ünïcode – folder/#hash %20 folder", isDirectory: true),
        ]
        let relatives = [
            "DSC00001.ARW", "B0007_DSC00012.ARW", "Transfer 1/100MSDCF/DSC00001.JPG", "sub/dir/with space/file name.ARW",
            "ünïcode/фото.JPG", "weird#name%20.ARW", "dots.in.name.tar.gz", "a/b/c/d/e/f/g.mov", "C0001M01.XML", "trail.ext ", "colon:name.ARW",
        ]
        for root in roots {
            for relative in relatives {
                XCTAssertEqual(
                    EventsWorkspace.resolvedPath(root: root, relativePath: relative),
                    root.appendingPathComponent(relative).path,
                    "\(root.path) + \(relative)"
                )
            }
        }
    }

    func testResolverSpeedBudgetOverAFamilyOfFilesAndNoStatPerPath() throws {
        let root = URL(fileURLWithPath: "/Volumes/DefinitelyNotMounted/Camera Buffer/2026/Event/Originals/Sony A7V", isDirectory: true)
        let relatives = (0..<50_000).map { "Transfer \($0 / 500)/DSC\(String(format: "%05d", $0)).ARW" }
        let start = ProcessInfo.processInfo.systemUptime
        var total = 0
        for relative in relatives { total &+= EventsWorkspace.resolvedPath(root: root, relativePath: relative).utf8.count }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("TIMING|resolver 50,000 paths \(elapsed * 1_000) ms")
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThan(elapsed, 2.0)
    }

    // MARK: - Boards already loaded are not re-verified

    func testSelectingALoadedBoardAgainDoesNoWork() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        let sweeps = SweepCounter()
        workspace.presenceProbe = sweeps.probe
        await workspace.refreshEvent(library.islandID)
        XCTAssertTrue(workspace.isBoardFresh(library.islandID))
        let statsAfterLoad = sweeps.count
        XCTAssertGreaterThan(statsAfterLoad, 0)

        // What an appearing board runs: nothing, because nothing changed.
        let stacks = workspace.eventStacks[library.islandID]
        await workspace.refreshEventIfStale(library.islandID)
        XCTAssertEqual(sweeps.count, statsAfterLoad)
        XCTAssertEqual(workspace.eventStacks[library.islandID], stacks)

        // Data that actually changed does re-check it.
        workspace.refreshConnectivity()
        XCTAssertFalse(workspace.isBoardFresh(library.islandID))
        await workspace.refreshEventIfStale(library.islandID)
        // (`refreshConnectivity` also re-reads every open board in the
        // background; wait for whichever refresh lands last.)
        try await waitUntil { workspace.isBoardFresh(library.islandID) }
        XCTAssertGreaterThan(sweeps.count, statsAfterLoad)

        // And an old proof is re-checked in the background.
        workspace.boardFreshnessInterval = 0
        XCTAssertFalse(workspace.isBoardFresh(library.islandID))
        }
    }

    // MARK: - Cached board math

    func testBoardGroupsAreReusedUntilTheirInputsChange() async throws {
        try await eachLibrary(.small) { library, mode in
        let workspace = library.workspace
        await workspace.refreshEvent(library.islandID)
        let stacks = try XCTUnwrap(workspace.eventStacks[library.islandID])
        let sort = OrganizeStackSort(key: .captureTime, ascending: true)
        let first = workspace.eventBoardGroups(library.islandID, stacks: stacks, grouping: .day, sort: sort)
        let again = workspace.eventBoardGroups(library.islandID, stacks: stacks, grouping: .day, sort: sort)
        XCTAssertEqual(first.map(\.id), again.map(\.id))
        XCTAssertEqual(first.flatMap(\.stacks).count, stacks.count)
        // A different grouping is a different answer.
        let byKind = workspace.eventBoardGroups(library.islandID, stacks: stacks, grouping: .kind, sort: sort)
        XCTAssertEqual(byKind.flatMap(\.stacks).count, stacks.count)
        // And a changed board is never served a stale grouping.
        let fewer = Array(stacks.dropFirst(5))
        let changed = workspace.eventBoardGroups(library.islandID, stacks: fewer, grouping: .day, sort: sort)
        XCTAssertEqual(changed.flatMap(\.stacks).count, fewer.count)
        }
    }
}

/// Counts capture-date header reads across threads.
final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func note(_ url: URL) { lock.withLock { _count += 1 } }
}

/// Records how many calls ran and how many of them on the main thread.
final class ThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _total = 0
    private var _onMain = 0
    var total: Int { lock.withLock { _total } }
    var onMain: Int { lock.withLock { _onMain } }
    func note() {
        let main = Thread.isMainThread
        lock.withLock {
            _total += 1
            if main { _onMain += 1 }
        }
    }
}

/// Counts presence-sweep stats.
final class SweepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    var probe: EventPresenceScanner.PresenceProbe {
        { [self] url, size, mounted in
            lock.withLock { _count += 1 }
            return EventPresenceScanner.state(url, size: size, mounted: mounted)
        }
    }
}
