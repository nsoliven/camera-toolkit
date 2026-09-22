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
        var waiters = 0
        var continuations: [UUID: CheckedContinuation<CGImage?, Never>] = [:]
        var finished = false
        var result: CGImage?

        init(url: URL, bucket: Int, orientation: Int, priority: Operation.QueuePriority) {
            operation = TileDecodeOperation(url: url, maximumPixelSize: bucket, orientation: orientation)
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
    private let queue: OperationQueue
    private let lock = NSLock()
    private var inFlight: [String: WaiterGroup] = [:]

    init() {
        cache.totalCostLimit = 768 * 1_024 * 1_024
        queue = OperationQueue()
        queue.name = "CameraToolkit.TileImageLoader"
        queue.maxConcurrentOperationCount = 6
        queue.qualityOfService = .userInitiated
    }

    /// Decode sizes are bucketed so tile and preview requests share cache
    /// entries. The 4800 bucket exists for the burst review overlay, which
    /// upgrades the displayed frame once the user zooms past fit — roughly
    /// 60–90 MB decoded per frame inside the cost-limited NSCache.
    static func bucket(for pixels: Int) -> Int {
        switch pixels {
        case ...384: 384
        case ...768: 768
        case ...1_280: 1_280
        case ...2_400: 2_400
        default: 4_800
        }
    }

    /// `orientation` is the display rotation in quarter-turns clockwise (see
    /// `DisplayRotation`). It is part of the cache key so a rotated decode
    /// never joins or reuses an unrotated one.
    func cachedImage(for url: URL, maximumPixelSize: Int, orientation: Int = 0) -> CGImage? {
        cache.object(forKey: key(url, Self.bucket(for: maximumPixelSize), orientation) as NSString)?.image
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
        let cacheKey = key(url, bucket, orientation)
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached.image
        }

        let group = joinGroup(cacheKey: cacheKey, url: url, bucket: bucket, orientation: orientation, priority: priority)
        let id = UUID()
        let timeoutTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.timeoutWaiter(id: id, url: url, bucket: bucket, in: group, after: timeout)
        }
        defer { timeoutTask.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                park(continuation, id: id, in: group)
            }
        } onCancel: {
            cancelWaiter(id: id, cacheKey: cacheKey, in: group)
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
        let group = WaiterGroup(url: url, bucket: bucket, orientation: orientation, priority: priority)
        group.waiters = 1
        inFlight[cacheKey] = group
        group.operation.completionBlock = { [weak self] in
            self?.finish(cacheKey: cacheKey, group: group)
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
    private func cancelWaiter(id: UUID, cacheKey: String, in group: WaiterGroup) {
        lock.lock()
        guard let continuation = group.continuations.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        group.waiters -= 1
        let shouldCancel = group.waiters == 0 && !group.finished
        if shouldCancel {
            inFlight.removeValue(forKey: cacheKey)
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

    /// Runs once when the shared decode operation finishes: fills the cache,
    /// drops the in-flight slot, and resumes every waiter with the result
    /// (nil when the operation was cancelled).
    private func finish(cacheKey: String, group: WaiterGroup) {
        lock.lock()
        group.finished = true
        let result = group.operation.isCancelled ? nil : group.operation.result
        group.result = result
        if let result {
            cache.setObject(Box(result), forKey: cacheKey as NSString, cost: result.bytesPerRow * result.height)
        }
        inFlight.removeValue(forKey: cacheKey)
        let continuations = Array(group.continuations.values)
        group.continuations.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.resume(returning: result)
        }
    }

    /// Drops every cached decode of `url` — all size buckets and all
    /// orientations — so a display-rotation change frees its stale bitmaps
    /// instead of waiting for the cost limit to evict them.
    func invalidate(url: URL) {
        for bucket in [384, 768, 1_280, 2_400, 4_800] {
            for orientation in 0..<4 {
                cache.removeObject(forKey: key(url, bucket, orientation) as NSString)
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
        if OrganizeFileClassifier.videoExtensions.contains(ext) {
            return videoFrame(url: url, maximumPixelSize: maximumPixelSize)
        }
        if OrganizeFileClassifier.photoExtensions.contains(ext) {
            return PreviewImageDecoder.cgImage(url: url, maximumPixelSize: maximumPixelSize)
        }
        return nil
    }

    private static func videoFrame(url: URL, maximumPixelSize: Int) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
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
    var result: CGImage?

    init(url: URL, maximumPixelSize: Int, orientation: Int) {
        self.url = url
        self.maximumPixelSize = maximumPixelSize
        self.orientation = orientation
    }

    override func main() {
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
