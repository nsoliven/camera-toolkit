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

    private let cache = NSCache<NSString, Box>()
    private let queue: OperationQueue

    init() {
        cache.totalCostLimit = 768 * 1_024 * 1_024
        queue = OperationQueue()
        queue.name = "CameraToolkit.TileImageLoader"
        queue.maxConcurrentOperationCount = 6
        queue.qualityOfService = .userInitiated
    }

    static func bucket(for pixels: Int) -> Int {
        switch pixels {
        case ...384: 384
        case ...768: 768
        case ...1_280: 1_280
        default: 2_400
        }
    }

    func cachedImage(for url: URL, maximumPixelSize: Int) -> CGImage? {
        cache.object(forKey: key(url, Self.bucket(for: maximumPixelSize)))?.image
    }

    func image(for url: URL, maximumPixelSize: Int) async -> CGImage? {
        let bucket = Self.bucket(for: maximumPixelSize)
        let cacheKey = key(url, bucket)
        if let cached = cache.object(forKey: cacheKey) {
            return cached.image
        }
        let operation = TileDecodeOperation(url: url, maximumPixelSize: bucket)
        let image: CGImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                operation.completionBlock = {
                    continuation.resume(returning: operation.isCancelled ? nil : operation.result)
                }
                queue.addOperation(operation)
            }
        } onCancel: {
            operation.cancel()
        }
        if let image {
            cache.setObject(Box(image), forKey: cacheKey, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    private func key(_ url: URL, _ bucket: Int) -> NSString {
        "\(url.path)#\(bucket)" as NSString
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
