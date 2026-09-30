import CameraToolkitCore
import Darwin
import Foundation
import XCTest
@testable import CameraToolkitApp

/// A library of the size Camera Toolkit is really used at, built in a temp
/// folder: a parent event whose family holds ~15.6k files across several
/// subevents, a few thousand files elsewhere, ~17k assignments in all, and
/// real one-byte files on a stand-in for the Buffer volume. Bursts carry
/// `B0007_` prefixes, so the stacker groups them without reading a capture
/// date; everything else is a single. Nothing touches the real Application
/// Support folder, `/Volumes`, or a NAS.
@MainActor
struct MoveLibrary {
    struct Shape {
        /// Files sitting directly in the parent event.
        var parentOwn = 9_846
        var beach = 1_931
        var city = 3_673
        var road = 160
        /// A second family the moves never touch.
        var elsewhere = 1_390
        /// Frames per burst; every third group of files is a burst.
        var burstFrames = 8
        /// Back the model with the SQLite catalog, like the live app.
        var catalogBacked = true

        static let realistic = Shape()
        /// The same structure at a size where the unit tests stay quick.
        static let small = Shape(parentOwn: 80, beach: 30, city: 60, road: 6, elsewhere: 20, catalogBacked: false)

        var family: Int { parentOwn + beach + city + road }
        var total: Int { family + elsewhere }
    }

    let root: URL
    let model: DashboardModel
    let workspace: EventsWorkspace
    let shape: Shape
    let parentID: UUID
    let beachID: UUID
    let cityID: UUID
    let roadID: UUID
    let elsewhereID: UUID
    /// The next event to move things into — a sibling in the same family.
    var targetID: UUID { beachID }
    /// The subevent a move leaves and the sibling it joins, by neutral names
    /// for tests that describe the move rather than the fixture's events.
    var sourceSubeventID: UUID { cityID }
    var targetSubeventID: UUID { beachID }

    var catalogURL: URL { root.appendingPathComponent("CameraToolkit/catalog.sqlite") }

    func tearDown() {
        CatalogDatabase.checkpointAndClose(url: catalogURL)
        try? FileManager.default.removeItem(at: root)
    }

    static func make(_ shape: Shape = .realistic) throws -> MoveLibrary {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitMoves-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let support = root.appendingPathComponent("CameraToolkit", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var configuration = AppConfiguration(
            demoRootPath: root.appendingPathComponent("Safety Test").path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path,
            bufferPath: root.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: root.appendingPathComponent("Library").path,
            catalogDatabasePath: support.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path,
            selectedDeviceID: "sony-a7v"
        )
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_772_000_000))
        let parent = SavedCameraEvent(name: "Trip 2026", eventDate: day, storagePolicy: .buffer)
        let beach = SavedCameraEvent(name: "Beach Day", eventDate: day, storagePolicy: .buffer, parentEventID: parent.id)
        let city = SavedCameraEvent(name: "City Weekend", eventDate: day.addingTimeInterval(4 * 86_400), storagePolicy: .buffer, parentEventID: parent.id)
        let road = SavedCameraEvent(name: "Road Trip", eventDate: day.addingTimeInterval(9 * 86_400), storagePolicy: .buffer, parentEventID: parent.id)
        let elsewhere = SavedCameraEvent(name: "Elsewhere", eventDate: day.addingTimeInterval(30 * 86_400), storagePolicy: .buffer)
        configuration.savedEvents = [parent, beach, city, road, elsewhere]

        let locations = EventStorageLocations(configuration: configuration)
        let unsorted = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
        var assignments: [PhotoEventAssignment] = []
        assignments.reserveCapacity(shape.total)
        var frame = 0
        var burst = 0
        let fileManager = FileManager.default
        for (event, count) in [
            (parent, shape.parentOwn), (beach, shape.beach), (city, shape.city),
            (road, shape.road), (elsewhere, shape.elsewhere)
        ] {
            let folder = locations.originalsRoot(for: event, deviceID: "sony-a7v", policy: .buffer)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            var made = 0
            var group = 0
            while made < count {
                let isBurst = group % 3 == 0
                let size = isBurst ? min(shape.burstFrames, count - made) : 1
                burst += isBurst ? 1 : 0
                for index in 0..<size {
                    frame += 1
                    let name = isBurst ? String(format: "B%04d_DSC%05d.ARW", burst, frame) : String(format: "DSC%05d.ARW", frame)
                    // Ten shooting days per event, thirty seconds apart.
                    let modifiedAt = event.eventDate.addingTimeInterval(Double((made + index) % 10) * 86_400 + Double(made + index) * 3)
                    XCTAssertTrue(fileManager.createFile(
                        atPath: folder.appendingPathComponent(name).path,
                        contents: Data([0x78]),
                        attributes: [.modificationDate: modifiedAt]
                    ))
                    assignments.append(PhotoEventAssignment(
                        sourceRootPath: unsorted.path,
                        relativePath: name,
                        fileSize: 1,
                        modifiedAt: modifiedAt,
                        eventID: event.id,
                        deviceID: "sony-a7v"
                    ))
                }
                made += size
                group += 1
            }
        }
        configuration.photoEventAssignments = assignments

        let configURL = support.appendingPathComponent("config.json")
        let store = ConfigurationStore(url: configURL)
        let model: DashboardModel
        if shape.catalogBacked {
            try store.save(configuration)
            let outcome = CatalogStateStartup.resolve(
                configurationURL: configURL,
                defaults: configuration,
                backups: { url in
                    CatalogBackupService(
                        catalogURL: url,
                        configurationURL: configURL,
                        localFolder: support.appendingPathComponent("Backups"),
                        remoteFolder: nil
                    )
                }
            )
            model = DashboardModel(jobs: [], configuration: outcome.configuration, configurationStore: store)
            model.adoptCatalogState(outcome)
            guard case .catalog = model.catalogStateMode else {
                throw NSError(domain: "MoveLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: "catalog mode expected: \(model.statusMessage)"])
            }
        } else {
            model = DashboardModel(jobs: [], configuration: configuration, configurationStore: store)
        }
        let workspace = EventsWorkspace(
            model: model,
            supportFolder: root.appendingPathComponent("Support", isDirectory: true),
            driveActivityGate: DriveActivityGate()
        )
        // Capture dates come from modification times here; a header read
        // per file would only slow the fixture down.
        workspace.captureDateReadProbe = { _ in nil }
        return MoveLibrary(
            root: root,
            model: model,
            workspace: workspace,
            shape: shape,
            parentID: parent.id,
            beachID: beach.id,
            cityID: city.id,
            roadID: road.id,
            elsewhereID: elsewhere.id
        )
    }

    /// The first `count` burst stacks of an event's open board.
    func bursts(in eventID: UUID, count: Int) -> [OrganizeStack] {
        Array((workspace.eventStacks[eventID] ?? []).filter(\.isBurst).prefix(count))
    }
}

/// Counts the presence sweep's stats by place and can slow the NAS ones
/// down the way an SMB round trip does.
final class MovePresenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _total = 0
    private var _nas = 0
    private let nasPrefix: String
    private var _nasDelay: UInt32

    init(nasRoot: String, nasDelayMicroseconds: UInt32 = 0) {
        self.nasPrefix = nasRoot
        self._nasDelay = nasDelayMicroseconds
    }

    /// Slows every NAS stat from now on.
    var nasDelayMicroseconds: UInt32 {
        get { lock.withLock { _nasDelay } }
        set { lock.withLock { _nasDelay = newValue } }
    }

    var total: Int { lock.withLock { _total } }
    var nasStats: Int { lock.withLock { _nas } }

    var probe: EventPresenceScanner.PresenceProbe {
        { [self] url, size, mounted in
            let isNAS = url.map { $0.path.hasPrefix(nasPrefix) } ?? false
            lock.withLock {
                _total += 1
                if isNAS { _nas += 1 }
            }
            let delay = nasDelayMicroseconds
            if isNAS, delay > 0 { usleep(delay) }
            return EventPresenceScanner.state(url, size: size, mounted: mounted)
        }
    }
}

/// Pings the main queue from a background thread and records how long each
/// ping waited — the time the main actor was blocked and could not draw or
/// answer input — and how much of that the main thread spent running (its own
/// CPU time), which stays put when the machine is busy and the thread waits
/// for a core.
final class MainStallMonitor: @unchecked Sendable {
    struct Stall {
        var startedAt: TimeInterval
        var duration: TimeInterval
        /// The main thread's user + system CPU time while the ping waited.
        var cpu: TimeInterval = 0
    }

    private let lock = NSLock()
    private var running = false
    private var origin = ProcessInfo.processInfo.systemUptime
    private var _stalls: [Stall] = []
    private var thread: Thread?
    private var mainThread: mach_port_t = 0

    /// Call from the main thread.
    func start() {
        mainThread = mach_thread_self()
        lock.withLock {
            running = true
            origin = ProcessInfo.processInfo.systemUptime
            _stalls = []
        }
        let mainThread = self.mainThread
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let sent = ProcessInfo.processInfo.systemUptime
                let cpuBefore = Self.cpuTime(of: mainThread)
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let waited = ProcessInfo.processInfo.systemUptime - sent
                if waited > 0.008 {
                    let cpu = Self.cpuTime(of: mainThread) - cpuBefore
                    lock.withLock { _stalls.append(Stall(startedAt: sent - origin, duration: waited, cpu: cpu)) }
                }
                usleep(1_000)
            }
        }
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Stalls of 8 ms or more since `start()`, longest first.
    func stop() -> [Stall] {
        lock.withLock { running = false }
        return lock.withLock { _stalls }.sorted { $0.duration > $1.duration }
    }

    private static func cpuTime(of thread: mach_port_t) -> TimeInterval {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        func seconds(_ time: time_value_t) -> TimeInterval { TimeInterval(time.seconds) + TimeInterval(time.microseconds) / 1_000_000 }
        return seconds(info.user_time) + seconds(info.system_time)
    }
}
