import AVFoundation
import AppKit
import CameraToolkitCore
import ImageIO

/// Decodes grid tiles and large previews off the main thread with a bounded
/// queue and a cost-limited cache. RAW files use their embedded JPEG, so a
/// tile never decodes sensor data.
final class TileImageLoader: @unchecked Sendable {
    static let shared = TileImageLoader()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// One in-flight decode plus every continuation waiting on it. Requests
    /// for an already-running path+bucket join the group instead of decoding
    /// twice; a waiter that cancels leaves early while the decode finishes
    /// for the rest.
    private final class WaiterGroup: @unchecked Sendable {
        let operation: TileDecodeOperation
        /// The cache/in-flight key this decode reports under. A rename can
        /// move it mid-flight so the result lands at the file's new path.
        var cacheKey: String
        var waiters = 0
        var continuations: [UUID: CheckedContinuation<CGImage?, Never>] = [:]
        var finished = false
        var result: CGImage?

        init(url: URL, bucket: Int, orientation: Int, priority: Operation.QueuePriority, cacheKey: String, gate: DriveActivityGate) {
            self.cacheKey = cacheKey
            operation = TileDecodeOperation(url: url, maximumPixelSize: bucket, orientation: orientation, gate: gate)
            operation.queuePriority = priority
            operation.qualityOfService = TileImageLoader.qos(for: priority)
        }

        /// A hero-frame request joining a queued filmstrip decode pulls it
        /// ahead of other tiles — the shared decode would satisfy both anyway.
        func boost(_ priority: Operation.QueuePriority) {
            guard priority.rawValue > operation.queuePriority.rawValue else { return }
            operation.queuePriority = priority
            operation.qualityOfService = TileImageLoader.qos(for: priority)
        }
    }

    private let cache = NSCache<NSString, Box>()
    /// The 4800-px zoom decodes live apart from the tile cache: one hero
    /// bitmap costs as much as ~25 filmstrip tiles, and letting it evict
    /// them — or letting filmstrip churn evict it — makes both feel broken.
    /// A small separate limit keeps a couple of zoomed frames on hand.
    private let previewCache = NSCache<NSString, Box>()
    private let queue: OperationQueue
    private let lock = NSLock()
    private var inFlight: [String: WaiterGroup] = [:]
    /// Decodes wait at this gate while a speed test is measuring the volume
    /// the file lives on — a tile read should never contend with, or pile
    /// onto, a drive the benchmark may be about to report as stalled.
    private let driveActivityGate: DriveActivityGate
    /// Standardized paths a completed rename left vacant, mapped to where
    /// each file landed. Only consulted while the asked-for path is really
    /// missing, so a name another file later reuses is never rerouted.
    private var redirects: [String: String] = [:]
    /// Held for the lifetime of the loader — dispatch sources need a strong
    /// reference to keep delivering.
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    init(driveActivityGate: DriveActivityGate = .shared) {
        self.driveActivityGate = driveActivityGate
        cache.totalCostLimit = 320 * 1_024 * 1_024
        previewCache.totalCostLimit = 192 * 1_024 * 1_024
        queue = OperationQueue()
        queue.name = "CameraToolkit.TileImageLoader"
        queue.maxConcurrentOperationCount = 6
        queue.qualityOfService = .userInitiated
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.purgeForMemoryPressure()
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Decode sizes are bucketed so tile and preview requests share cache
    /// entries. The 4800 bucket exists for the burst review overlay, which
    /// upgrades the displayed frame once the user zooms past fit — roughly
    /// 60–90 MB decoded per frame inside the cost-limited NSCache.
    static let buckets: [Int] = [384, 512, 768, 1_280, 2_400, 4_800]

    static func bucket(for pixels: Int) -> Int {
        switch pixels {
        case ...384: 384
        case ...512: 512
        case ...768: 768
        case ...1_280: 1_280
        case ...2_400: 2_400
        default: 4_800
        }
    }

    /// The cache a bucket belongs to: the big zoom decodes get the small
    /// preview cache, everything else shares the tile cache.
    private func store(for bucket: Int) -> NSCache<NSString, Box> {
        bucket >= 4_800 ? previewCache : cache
    }

    /// Drops every cached bitmap — called from the memory-pressure dispatch
    /// source (and tests). On-screen tiles hold their own `@State` image, so
    /// purging only re-decodes what scrolls back into view.
    func purgeForMemoryPressure() {
        cache.removeAllObjects()
        previewCache.removeAllObjects()
    }

    /// Test/debug readouts of the configured limits.
    var tileCacheCostLimit: Int { cache.totalCostLimit }
    var previewCacheCostLimit: Int { previewCache.totalCostLimit }

    /// `orientation` is the display rotation in quarter-turns clockwise (see
    /// `DisplayRotation`). It is part of the cache key so a rotated decode
    /// never joins or reuses an unrotated one. The asked-for path is checked
    /// before `resolvedURL` — its `fileExists` stat is only worth paying on
    /// a miss.
    func cachedImage(for url: URL, maximumPixelSize: Int, orientation: Int = 0) -> CGImage? {
        let bucket = Self.bucket(for: maximumPixelSize)
        if let hit = store(for: bucket).object(forKey: key(url, bucket, orientation) as NSString) {
            return hit.image
        }
        let resolved = resolvedURL(for: url)
        guard resolved != url else { return nil }
        return store(for: bucket).object(forKey: key(resolved, bucket, orientation) as NSString)?.image
    }

    /// Wall-clock bound on a single decode wait. A read stuck on a dead or
    /// sleeping volume never resolves, so the waiter is released with nil
    /// after this and the failure UI can replace the spinner. The decode
    /// itself keeps running — a late finish still lands in the cache.
    static let waitTimeout: Duration = .seconds(15)

    /// `priority` maps onto the decode operation's queue priority: the
    /// on-screen frame requests `.veryHigh`/`.high` so it never waits behind
    /// filmstrip tiles (`.normal`) or prefetch (`.low`) on a slow volume.
    /// Joining an already-queued decode boosts it to the higher priority.
    /// `timeout` bounds the wait; the shared decode operation is not
    /// cancelled — an uninterruptible filesystem read would ignore it anyway.
    func image(
        for url: URL,
        maximumPixelSize: Int,
        orientation: Int = 0,
        priority: Operation.QueuePriority = .normal,
        timeout: Duration = TileImageLoader.waitTimeout
    ) async -> CGImage? {
        let bucket = Self.bucket(for: maximumPixelSize)
        let askedKey = key(url, bucket, orientation)
        let store = store(for: bucket)
        if let cached = store.object(forKey: askedKey as NSString) {
            return cached.image
        }
        // Only a miss pays for `resolvedURL`'s existence check — a rename
        // redirect, or the asked-for path itself, decides the decode key.
        let resolved = resolvedURL(for: url)
        let cacheKey = resolved == url ? askedKey : key(resolved, bucket, orientation)
        if cacheKey != askedKey, let cached = store.object(forKey: cacheKey as NSString) {
            return cached.image
        }

        let group = joinGroup(cacheKey: cacheKey, url: resolved, bucket: bucket, orientation: orientation, priority: priority)
        let id = UUID()
        let timeoutTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.timeoutWaiter(id: id, url: resolved, bucket: bucket, in: group, after: timeout)
        }
        defer { timeoutTask.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                park(continuation, id: id, in: group)
            }
        } onCancel: {
            cancelWaiter(id: id, in: group)
        }
    }

    /// Lock-guarded join: returns the in-flight decode for `cacheKey`,
    /// creating and queueing one when none exists.
    private func joinGroup(
        cacheKey: String,
        url: URL,
        bucket: Int,
        orientation: Int,
        priority: Operation.QueuePriority
    ) -> WaiterGroup {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlight[cacheKey] {
            existing.waiters += 1
            existing.boost(priority)
            return existing
        }
        let group = WaiterGroup(url: url, bucket: bucket, orientation: orientation, priority: priority, cacheKey: cacheKey, gate: driveActivityGate)
        group.waiters = 1
        inFlight[cacheKey] = group
        group.operation.completionBlock = { [weak self] in
            self?.finish(group: group)
        }
        queue.addOperation(group.operation)
        return group
    }

    /// Lock-guarded wait registration: parks the continuation on the group,
    /// or resumes it immediately when the decode finished in the gap between
    /// `joinGroup` and this call.
    private func park(
        _ continuation: CheckedContinuation<CGImage?, Never>,
        id: UUID,
        in group: WaiterGroup
    ) {
        lock.lock()
        if group.finished {
            let result = group.result
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            group.continuations[id] = continuation
            lock.unlock()
        }
    }

    /// Lock-guarded cancellation: drops the waiter and resumes it with nil.
    /// When the last waiter leaves before the decode finished, the shared
    /// operation is cancelled so it exits early instead of decoding for no
    /// one; its completion block still drains any continuations left.
    private func cancelWaiter(id: UUID, in group: WaiterGroup) {
        lock.lock()
        guard let continuation = group.continuations.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        group.waiters -= 1
        let shouldCancel = group.waiters == 0 && !group.finished
        if shouldCancel, inFlight[group.cacheKey] === group {
            inFlight.removeValue(forKey: group.cacheKey)
        }
        lock.unlock()
        continuation.resume(returning: nil)
        if shouldCancel {
            group.operation.cancel()
        }
    }

    /// Lock-guarded timeout: drops the waiter and resumes it with nil so a
    /// decode parked in an uninterruptible read can't hold the caller — and
    /// its spinner — forever. Unlike `cancelWaiter` the operation is left
    /// alone: it may be slow rather than dead, and a late finish still fills
    /// the cache for the next request.
    private func timeoutWaiter(id: UUID, url: URL, bucket: Int, in group: WaiterGroup, after timeout: Duration) {
        lock.lock()
        guard let continuation = group.continuations.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        group.waiters -= 1
        lock.unlock()
        continuation.resume(returning: nil)
        DebugLog.shared.log(
            "decode.timeout",
            subsystem: .tile,
            level: .warning,
            outcome: .timeout,
            duration: timeout,
            url: url,
            detail: "waiter released; \(bucket) px decode still running"
        )
    }

    /// Runs once when the shared decode operation finishes: fills the cache
    /// under the group's current key — which a rename may have moved — drops
    /// the in-flight slot, and resumes every waiter with the result (nil
    /// when the operation was cancelled).
    private func finish(group: WaiterGroup) {
        lock.lock()
        group.finished = true
        let result = group.operation.isCancelled ? nil : group.operation.result
        group.result = result
        if inFlight[group.cacheKey] === group {
            inFlight.removeValue(forKey: group.cacheKey)
        }
        if let result {
            store(for: Self.bucket(for: group.operation.maximumPixelSize))
                .setObject(Box(result), forKey: group.cacheKey as NSString, cost: result.bytesPerRow * result.height)
        }
        let continuations = Array(group.continuations.values)
        group.continuations.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(returning: result)
        }
    }

    /// A rename batch landed: a decode asked for a path the move vacated
    /// resolves to the destination instead of failing on a file that is no
    /// longer there, cached bitmaps move to the new path's keys, and an
    /// in-flight decode's result lands there too. Called once per move
    /// report — a path this move vacated is not a decode failure.
    ///
    /// `standardized` says the paths are already standardized — the paths of
    /// files on the NAS, which must not be resolved on the main actor.
    func retarget(moves: [DriveMove], standardized: Bool = false) {
        guard !moves.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for move in moves {
            let source = standardized ? move.sourcePath : URL(fileURLWithPath: move.sourcePath).standardizedFileURL.path
            let destination = standardized ? move.destinationPath : URL(fileURLWithPath: move.destinationPath).standardizedFileURL.path
            guard source != destination else { continue }
            // Chained moves collapse: anything that pointed at the path this
            // move just vacated now points where the file actually landed.
            for key in redirects.filter({ $0.value == source }).map(\.key) {
                redirects[key] = destination
            }
            redirects[source] = destination
            let sourceURL = URL(filePath: source, directoryHint: .notDirectory)
            let destinationURL = URL(filePath: destination, directoryHint: .notDirectory)
            for bucket in Self.buckets {
                let store = store(for: bucket)
                for orientation in 0..<4 {
                    let oldKey = key(sourceURL, bucket, orientation)
                    let newKey = key(destinationURL, bucket, orientation)
                    if let box = store.object(forKey: oldKey as NSString) {
                        store.setObject(box, forKey: newKey as NSString, cost: box.image.bytesPerRow * box.image.height)
                        store.removeObject(forKey: oldKey as NSString)
                    }
                    if let group = inFlight.removeValue(forKey: oldKey) {
                        group.cacheKey = newKey
                        inFlight[newKey] = group
                    }
                }
            }
        }
    }

    /// The path a decode should actually read. A file still where it was
    /// asked for is never rerouted; a path a move left vacant follows the
    /// redirect to wherever the file landed — a request for it decodes the
    /// destination, so the vacated path never reports a decode failure.
    private func resolvedURL(for url: URL) -> URL {
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        lock.lock()
        var path = url.path
        var hops = 0
        while let next = redirects[path], next != path, hops < 8 {
            path = next
            hops += 1
        }
        lock.unlock()
        return path == url.path ? url : URL(filePath: path, directoryHint: .notDirectory)
    }

    /// Drops every cached decode of `url` — all size buckets and all
    /// orientations — so a display-rotation change frees its stale bitmaps
    /// instead of waiting for the cost limit to evict them.
    func invalidate(url: URL) {
        let url = resolvedURL(for: url)
        for bucket in Self.buckets {
            let store = store(for: bucket)
            for orientation in 0..<4 {
                store.removeObject(forKey: key(url, bucket, orientation) as NSString)
            }
        }
    }

    private func key(_ url: URL, _ bucket: Int, _ orientation: Int) -> String {
        "\(url.path)#\(bucket)#\(DisplayRotation.normalized(orientation))"
    }

    /// Thread QoS matching a queue priority: hero decodes get user-interactive
    /// threads, prefetch drops to utility so it never competes with tiles.
    private static func qos(for priority: Operation.QueuePriority) -> QualityOfService {
        switch priority {
        case .veryHigh, .high: .userInteractive
        case .normal: .userInitiated
        default: .utility
        }
    }

    static func decode(url: URL, maximumPixelSize: Int, orientation: Int = 0) -> CGImage? {
        let image = decodeUnrotated(url: url, maximumPixelSize: maximumPixelSize)
        guard let image, DisplayRotation.normalized(orientation) != 0 else { return image }
        return DisplayRotation.rotate(image, quarterTurnsCW: orientation)
    }

    private static func decodeUnrotated(url: URL, maximumPixelSize: Int) -> CGImage? {
        let ext = url.pathExtension.lowercased()
        if OrganizeFileClassifier.rawExtensions.contains(ext) {
            let preference: EmbeddedJPEGPreviewPreference = maximumPixelSize > 1_700 ? .fullSize : .thumbnail
            do {
                if let data = try EmbeddedJPEGPreviewExtractor().jpegData(from: url, preference: preference),
                   let image = PreviewImageDecoder.cgImage(data: data, maximumPixelSize: maximumPixelSize) {
                    return image
                }
            } catch {
                DebugLog.shared.log(
                    "extract.error",
                    subsystem: .tile,
                    level: .warning,
                    outcome: .error,
                    url: url,
                    error: DebugLog.describe(error)
                )
            }
            return PreviewImageDecoder.cgImage(url: url, maximumPixelSize: maximumPixelSize)
        }
        if DJI360Media.clipExtensions.contains(ext) {
            return dji360Thumbnail(url: url, maximumPixelSize: maximumPixelSize)
        }
        if OrganizeFileClassifier.videoExtensions.contains(ext) || DJI360Media.proxyExtensions.contains(ext) {
            return videoFrame(url: url, maximumPixelSize: maximumPixelSize)
        }
        if OrganizeFileClassifier.photoExtensions.contains(ext) {
            return PreviewImageDecoder.cgImage(url: url, maximumPixelSize: maximumPixelSize)
        }
        return nil
    }

    /// An Osmo 360 OSV never decodes its 3840² fisheye streams when it can
    /// help it: tiles read the clip's embedded 688×344 equirectangular
    /// cover, larger posters a frame of the sibling LRF proxy, and only a
    /// clip with neither falls back to one lens of the original
    /// (`DJI360Media.thumbnailSourceOrder`). Results land in the ordinary
    /// in-memory cache under the OSV's own key; nothing is written to disk.
    static func dji360Thumbnail(url: URL, maximumPixelSize: Int) -> CGImage? {
        DJI360Media.thumbnail(forClipAt: url, maximumPixelSize: maximumPixelSize) { source in
            switch source {
            case .embeddedCover(let clip):
                return QuickTimeCoverArtReader.image(from: clip, maximumPixelSize: maximumPixelSize)
            case .proxyFrame(let proxy):
                return videoFrame(url: proxy, maximumPixelSize: maximumPixelSize)
            case .lensFrame(let clip):
                return videoFrame(url: clip, maximumPixelSize: maximumPixelSize)
            }
        }
    }

    private static func videoFrame(url: URL, maximumPixelSize: Int) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: CameraVideoAsset.asset(for: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        DebugLog.shared.log("frame.start", subsystem: .video, url: url)
        let start = ContinuousClock.now
        do {
            let frame = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
            DebugLog.shared.log(
                "frame.finish",
                subsystem: .video,
                outcome: .ok,
                duration: ContinuousClock.now - start,
                url: url
            )
            return frame
        } catch {
            DebugLog.shared.log(
                "frame.finish",
                subsystem: .video,
                level: .warning,
                outcome: .error,
                duration: ContinuousClock.now - start,
                url: url,
                error: DebugLog.describe(error)
            )
            return nil
        }
    }
}

private final class TileDecodeOperation: Operation, @unchecked Sendable {
    let url: URL
    let maximumPixelSize: Int
    let orientation: Int
    let gate: DriveActivityGate
    var result: CGImage?

    init(url: URL, maximumPixelSize: Int, orientation: Int, gate: DriveActivityGate) {
        self.url = url
        self.maximumPixelSize = maximumPixelSize
        self.orientation = orientation
        self.gate = gate
    }

    override func main() {
        guard !isCancelled else { return }
        // Wait out a speed test measuring this volume rather than reading
        // through it; a cancelled decode returns instead of waiting.
        guard gate.waitIfPaused(for: url, shouldStop: { [self] in isCancelled }) else { return }
        guard !isCancelled else { return }
        // Start is logged before any file I/O — including the size `stat` —
        // so a decode stuck on a dead volume still leaves a "started, never
        // finished" trail in debug.jsonl.
        DebugLog.shared.log(
            "decode.start",
            subsystem: .tile,
            url: url,
            detail: "bucket \(maximumPixelSize)"
        )
        let start = ContinuousClock.now
        let size = DebugLog.fileSize(of: url)
        result = autoreleasepool {
            TileImageLoader.decode(url: url, maximumPixelSize: maximumPixelSize, orientation: orientation)
        }
        DebugLog.shared.log(
            "decode.finish",
            subsystem: .tile,
            level: result == nil && !isCancelled ? .warning : .debug,
            outcome: isCancelled ? .cancel : (result == nil ? .error : .ok),
            duration: ContinuousClock.now - start,
            url: url,
            size: size,
            error: result == nil && !isCancelled ? "decode produced no image" : nil
        )
    }
}
