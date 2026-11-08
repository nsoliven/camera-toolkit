import CameraToolkitCore
import CoreGraphics
import Foundation

/// Makes the thumbnails tiles will ask for before they ask, so a board opens
/// from this Mac instead of from the NAS.
///
/// Strictly read-only on photos: it stats and decodes the files it is given
/// and writes only through `ThumbnailDiskCache`, which keeps to its own
/// folder under Caches. It never renames, touches, moves or deletes a source
/// file and never writes a sidecar.
///
/// Everything it needs from the outside comes through `Hooks`. It holds no
/// queue on disk: what is already cached is skipped, so a restart resumes by
/// looking, and a new plan restarts at the top with what it already knows.
final class ThumbnailWarmer: @unchecked Sendable {
    /// One thumbnail to make, and where the photo can be read from, best
    /// place first.
    struct Item: Sendable, Hashable {
        let key: String
        let sources: [String]
        let bucket: Int
        /// The saved rotation, or nil to use the camera's.
        let orientation: Int?
    }

    struct Hooks: Sendable {
        /// True while warming must wait: a job, a tile load, a scroll.
        var isHeld: @Sendable () async -> Bool = { false }
        /// False when there is no room for more thumbnails.
        var hasRoom: @Sendable () -> Bool = { true }
        /// Whether the volume a path lives on is mounted.
        var isAvailable: @Sendable (String) -> Bool
        var fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        var decode: @Sendable (_ path: String, _ bucket: Int, _ orientation: Int?) -> TileImageLoader.DecodedTile?
    }

    struct Timing: Sendable {
        /// How often a held warmer looks again.
        var holdPoll: Duration = .milliseconds(500)
        /// How often an idle warmer looks for a new plan.
        var idlePoll: Duration = .seconds(1)
        /// How long after a pass that found a source away before trying again.
        var awayRetry: Duration = .seconds(15)
        /// How long a file that could not be read is left alone.
        var failureCooldown: Duration = .seconds(3_600)
    }

    struct Counts: Equatable, Sendable {
        var saved = 0
        var alreadyCached = 0
        var failed = 0
        var passes = 0
    }

    /// At most this many photos are read at once.
    static let maxConcurrent = 2

    private enum Outcome {
        case saved
        case failed
        case sourceAway
        case storeFailed
    }

    private let cache: ThumbnailDiskCache
    private let hooks: Hooks
    private let timing: Timing
    private let readQueue = DispatchQueue(label: "CameraToolkit.ThumbnailWarmer", qos: .utility, attributes: .concurrent)

    private let lock = NSLock()
    private var plan: [Item] = []
    private var generation = 0
    private var cursor = 0
    private var completed: Set<String> = []
    private var failedUntil: [String: ContinuousClock.Instant] = [:]
    private var sawSourceAway = false
    private var abandonedGeneration: Int?
    private var counts = Counts()
    private var task: Task<Void, Never>?

    init(cache: ThumbnailDiskCache, hooks: Hooks, timing: Timing = Timing()) {
        self.cache = cache
        self.hooks = hooks
        self.timing = timing
    }

    var currentCounts: Counts { lock.withLock { counts } }

    func start() {
        lock.withLock {
            guard task == nil else { return }
            task = Task.detached(priority: .utility) { [weak self] in await self?.run() }
        }
    }

    /// Stops starting new reads. A read already under way finishes and is
    /// kept; it cannot be interrupted and its thumbnail is still good.
    func stop() {
        let running = lock.withLock {
            defer { task = nil }
            return task
        }
        running?.cancel()
    }

    /// Takes a new order of work and restarts from its top. What this
    /// session has finished stays finished, and what failed stays failed
    /// until its cooldown ends, so a new selection is cheap.
    func replacePlan(_ items: [Item]) {
        lock.withLock {
            plan = items
            generation &+= 1
            cursor = 0
        }
    }

    // MARK: The loop

    private func run() async {
        var drained = -1
        var retryAt: ContinuousClock.Instant?
        while !Task.isCancelled {
            let generation = lock.withLock { self.generation }
            let retryDue = retryAt.map { ContinuousClock.now >= $0 } ?? false
            guard generation != drained || retryDue else {
                try? await Task.sleep(for: timing.idlePoll)
                continue
            }
            beginPass()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.maxConcurrent {
                    group.addTask { [self] in await worker(generation: generation) }
                }
            }
            guard !Task.isCancelled else { return }
            let (current, away) = lock.withLock { (self.generation, sawSourceAway) }
            guard current == generation else { continue }
            drained = generation
            retryAt = away ? ContinuousClock.now + timing.awayRetry : nil
        }
    }

    private func beginPass() {
        lock.withLock {
            cursor = 0
            sawSourceAway = false
            counts.passes += 1
        }
    }

    private func worker(generation: Int) async {
        while !Task.isCancelled {
            guard await waitWhileHeld(generation: generation),
                  let item = claimNext(generation: generation) else { return }
            let outcome = await process(item)
            record(outcome, for: item, generation: generation)
        }
    }

    /// False when this pass should end instead of waiting any longer.
    private func waitWhileHeld(generation: Int) async -> Bool {
        while !Task.isCancelled {
            guard isCurrent(generation) else { return false }
            let held = await hooks.isHeld()
            if !held, hooks.hasRoom() { return true }
            try? await Task.sleep(for: timing.holdPoll)
        }
        return false
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.withLock { self.generation == generation && abandonedGeneration != generation }
    }

    /// The next item that needs a read, or nil when the pass is over. Each
    /// skip is a set lookup or one local stat; the source is not touched.
    private func claimNext(generation: Int) -> Item? {
        while !Task.isCancelled {
            enum Step { case done, skip, check(Item) }
            let step: Step = lock.withLock {
                guard self.generation == generation, abandonedGeneration != generation, cursor < plan.count else { return .done }
                let item = plan[cursor]
                cursor += 1
                if completed.contains(item.key) { return .skip }
                if let until = failedUntil[item.key], ContinuousClock.now < until { return .skip }
                return .check(item)
            }
            switch step {
            case .done:
                return nil
            case .skip:
                continue
            case .check(let item):
                guard item.sources.contains(where: hooks.isAvailable) else {
                    lock.withLock { sawSourceAway = true }
                    continue
                }
                if cache.contains(key: item.key) {
                    lock.withLock {
                        completed.insert(item.key)
                        counts.alreadyCached += 1
                    }
                    continue
                }
                return item
            }
        }
        return nil
    }

    /// Reads on the warmer's own low-priority queue, never the tile queues,
    /// so a tile is never queued behind a read made in advance.
    private func process(_ item: Item) async -> Outcome {
        await withCheckedContinuation { continuation in
            readQueue.async { [self] in
                continuation.resume(returning: autoreleasepool { readAndStore(item) })
            }
        }
    }

    private func readAndStore(_ item: Item) -> Outcome {
        for source in item.sources where hooks.isAvailable(source) && hooks.fileExists(source) {
            guard let decoded = hooks.decode(source, item.bucket, item.orientation) else { continue }
            return cache.storeAndWait(decoded.image, cameraTurns: decoded.cameraTurns, forKey: item.key) ? .saved : .storeFailed
        }
        // Asked after the reads: a volume that left during one is an absence
        // to wait out, not a bad file.
        return item.sources.contains(where: hooks.isAvailable) ? .failed : .sourceAway
    }

    private func record(_ outcome: Outcome, for item: Item, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        switch outcome {
        case .saved:
            completed.insert(item.key)
            counts.saved += 1
        case .failed:
            failedUntil[item.key] = ContinuousClock.now + timing.failureCooldown
            counts.failed += 1
        case .sourceAway:
            sawSourceAway = true
        case .storeFailed:
            // The disk is the problem, so the next photo would fail the same
            // way after a read for nothing. Done until the plan changes.
            abandonedGeneration = generation
        }
    }
}

/// The mount table, looked up at most once a second however many paths are
/// asked about: a pass over a library on an unplugged drive asks once per
/// photo.
final class ThumbnailWarmMountTable: @unchecked Sendable {
    private let lock = NSLock()
    private let maxAge: Duration
    private var mounted: Set<String> = []
    private var readAt: ContinuousClock.Instant?

    init(maxAge: Duration = .seconds(1)) {
        self.maxAge = maxAge
    }

    func isAvailable(_ path: String) -> Bool {
        let snapshot = lock.withLock { () -> Set<String> in
            if let readAt, ContinuousClock.now - readAt < maxAge { return mounted }
            mounted = VolumeInfo.mountedVolumePaths()
            readAt = .now
            return mounted
        }
        return VolumeInfo.isAvailable(URL(filePath: path, directoryHint: .notDirectory), mountedVolumes: snapshot)
    }
}
