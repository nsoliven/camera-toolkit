import AppKit
import CameraToolkitCore
import Foundation

/// Knows whether someone is scrolling a board, from the scroll views' own
/// live-scroll notifications, so a board needs no code of its own for this.
final class ThumbnailWarmScrollMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var scrolling = 0
    private var lastEnded: ContinuousClock.Instant?
    private var observers: [NSObjectProtocol] = []
    private let center: NotificationCenter

    init(center: NotificationCenter = .default) {
        self.center = center
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: nil) { [weak self] _ in
            self?.lock.withLock { self?.scrolling += 1 }
        })
        observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            lock.withLock {
                scrolling = max(0, scrolling - 1)
                lastEnded = .now
            }
        })
    }

    deinit {
        observers.forEach(center.removeObserver)
    }

    func isQuiet(for quiet: Duration) -> Bool {
        lock.withLock {
            guard scrolling == 0 else { return false }
            guard let lastEnded else { return true }
            return ContinuousClock.now - lastEnded >= quiet
        }
    }
}

/// Runs the app's one `ThumbnailWarmer`: watches which event is open and
/// when the catalog changes, and says when warming has to wait.
@MainActor
final class ThumbnailWarmingCoordinator {
    private static var current: ThumbnailWarmingCoordinator?

    /// How long tiles and scrolling must be still before warming goes on.
    nonisolated private static let foregroundQuiet: Duration = .seconds(2)
    /// Warming writes nothing while the disk has less than this free.
    nonisolated private static let minimumFreeBytes: Int64 = 10 * 1_024 * 1_024 * 1_024
    /// Lets the launch's own NAS and catalog work finish first.
    private static let startDelay: Duration = .seconds(10)
    private static let tickInterval: Duration = .seconds(2)

    /// Starts warming in the real app only: tests and previews build models
    /// too, and must never reach the real Caches folder.
    static func startIfLive(workspace: EventsWorkspace) {
        guard current == nil, workspace.model.jobHistoryEnabled, let cache = ThumbnailDiskCache.appDefault else { return }
        cache.removeOlderLayouts()
        let coordinator = ThumbnailWarmingCoordinator(workspace: workspace, cache: cache)
        current = coordinator
        coordinator.start()
    }

    private struct Signature: Equatable {
        var selectedEventID: UUID?
        var catalogRevision: Int
        var assignmentCount: Int
        var bucket: Int
    }

    private let workspace: EventsWorkspace
    private let warmer: ThumbnailWarmer
    private var ticker: Task<Void, Never>?
    private var planning: Task<Void, Never>?
    private var signature: Signature?

    private init(workspace: EventsWorkspace, cache: ThumbnailDiskCache) {
        self.workspace = workspace
        let loader = TileImageLoader.shared
        let scrolls = ThumbnailWarmScrollMonitor()
        let mounts = ThumbnailWarmMountTable()
        let gate = DriveActivityGate.shared
        let hooks = ThumbnailWarmer.Hooks(
            isHeld: { [weak workspace] in
                guard loader.isForegroundQuiet(for: Self.foregroundQuiet), scrolls.isQuiet(for: Self.foregroundQuiet) else { return true }
                guard let workspace else { return true }
                return await Self.jobsHold(workspace)
            },
            hasRoom: { !cache.isNearLimit && Self.hasFreeSpace() },
            isAvailable: { mounts.isAvailable($0) },
            decode: { path, bucket, orientation in
                let url = URL(filePath: path, directoryHint: .notDirectory)
                gate.waitIfPaused(for: url)
                return TileImageLoader.decode(url: url, maximumPixelSize: bucket, orientation: orientation)
            }
        )
        warmer = ThumbnailWarmer(cache: cache, hooks: hooks)
    }

    /// True while a job, a queued move, a speed test or a board refresh is
    /// running: copies, syncs, card clears and moves all hold the job gate.
    static func jobsHold(_ workspace: EventsWorkspace) -> Bool {
        !workspace.isQuiet || workspace.model.isStorageBenchmarkRunning
    }

    private nonisolated static func hasFreeSpace() -> Bool {
        let values = try? URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let free = values?.volumeAvailableCapacity else { return false }
        return Int64(free) >= minimumFreeBytes
    }

    private func start() {
        warmer.start()
        ticker = Task { [weak self] in
            try? await Task.sleep(for: Self.startDelay)
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    /// Reads a few values and compares them; only a change costs anything.
    private func tick() {
        let model = workspace.model
        var selectedEventID: UUID?
        if case .event(let id) = workspace.selection { selectedEventID = id }
        let tileWidth = UserDefaults.standard.object(forKey: "CameraToolkit.organize.tileWidth") as? Double ?? 220
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let bucket = TileImageLoader.bucket(for: Int(tileWidth * scale))
        let next = Signature(
            selectedEventID: selectedEventID,
            catalogRevision: model.catalogStateRevision,
            assignmentCount: model.configuration.photoEventAssignments.count,
            bucket: bucket
        )
        guard next != signature else { return }
        signature = next
        let input = ThumbnailWarmPlan.Input(
            configuration: model.configuration,
            selectedEventID: selectedEventID,
            orientations: model.orientationsForDisplay,
            bucket: bucket
        )
        planning?.cancel()
        planning = Task.detached(priority: .utility) { [warmer] in
            let items = ThumbnailWarmPlan.items(for: input)
            guard !Task.isCancelled else { return }
            warmer.replacePlan(items)
        }
    }
}
