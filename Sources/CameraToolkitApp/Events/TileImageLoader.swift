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

        init(url: URL, bucket: Int) {
            operation = TileDecodeOperation(url: url, maximumPixelSize: bucket)
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

    func cachedImage(for url: URL, maximumPixelSize: Int) -> CGImage? {
        cache.object(forKey: key(url, Self.bucket(for: maximumPixelSize)) as NSString)?.image
    }

    func image(for url: URL, maximumPixelSize: Int) async -> CGImage? {
        let bucket = Self.bucket(for: maximumPixelSize)
        let cacheKey = key(url, bucket)
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached.image
        }

        let group = joinGroup(cacheKey: cacheKey, url: url, bucket: bucket)
        let id = UUID()
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
    private func joinGroup(cacheKey: String, url: URL, bucket: Int) -> WaiterGroup {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlight[cacheKey] {
            existing.waiters += 1
            return existing
        }
        let group = WaiterGroup(url: url, bucket: bucket)
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

    private func key(_ url: URL, _ bucket: Int) -> String {
        "\(url.path)#\(bucket)"
    }

    static func decode(url: URL, maximumPixelSize: Int) -> CGImage? {
        let ext = url.pathExtension.lowercased()
        if OrganizeFileClassifier.rawExtensions.contains(ext) {
            let preference: EmbeddedJPEGPreviewPreference = maximumPixelSize > 1_700 ? .fullSize : .thumbnail
            if let data = try? EmbeddedJPEGPreviewExtractor().jpegData(from: url, preference: preference),
               let image = PreviewImageDecoder.cgImage(data: data, maximumPixelSize: maximumPixelSize) {
                return image
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
        return try? generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
    }
}

private final class TileDecodeOperation: Operation, @unchecked Sendable {
    let url: URL
    let maximumPixelSize: Int
    var result: CGImage?

    init(url: URL, maximumPixelSize: Int) {
        self.url = url
        self.maximumPixelSize = maximumPixelSize
    }

    override func main() {
        guard !isCancelled else { return }
        result = autoreleasepool {
            TileImageLoader.decode(url: url, maximumPixelSize: maximumPixelSize)
        }
    }
}
