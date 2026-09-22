import AppKit
import CameraToolkitCore
import ImageIO
import SwiftUI

actor EmbeddedPreviewStore {
    static let shared = EmbeddedPreviewStore()

    private struct CacheKey: Hashable {
        var path: String
        var preference: String
    }

    private struct ImageCacheKey: Hashable {
        var source: CacheKey
        var maximumPixelSize: Int
    }

    private let extractor = EmbeddedJPEGPreviewExtractor()
    private var cache: [CacheKey: Data] = [:]
    private var cacheOrder: [CacheKey] = []
    private var cachedBytes = 0
    private var imageCache: [ImageCacheKey: CGImage] = [:]
    private var imageCacheOrder: [ImageCacheKey] = []
    private var cachedImageBytes = 0
    // Compressed JPEG bytes only. Decoded display images are downsampled below,
    // so scrolling never leaves full-resolution 33 MP bitmaps in row views.
    private let maximumCachedBytes = 32 * 1_024 * 1_024
    // Decoded images are also bounded. This comfortably holds all visible row
    // thumbnails plus a few recent side/full previews without retaining an
    // entire card's decoded photos.
    private let maximumCachedImageBytes = 64 * 1_024 * 1_024

    func jpegData(from url: URL, preference: EmbeddedJPEGPreviewPreference) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let key = CacheKey(
            path: url.standardizedFileURL.path,
            preference: preference == .thumbnail ? "thumbnail" : "full"
        )
        if let cached = cache[key] { return cached }

        let extractor = extractor
        let priority: TaskPriority = preference == .thumbnail ? .utility : .userInitiated
        let data = await Task.detached(priority: priority) {
            try? extractor.jpegData(from: url, preference: preference)
        }.value
        guard !Task.isCancelled, let data else { return nil }
        if let cached = cache[key] { return cached }
        cache[key] = data
        cacheOrder.append(key)
        cachedBytes += data.count
        while cachedBytes > maximumCachedBytes, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) {
                cachedBytes -= removed.count
            }
        }
        return data
    }

    /// Wall-clock bound on a preview decode wait. A read stuck on a dead or
    /// sleeping volume never resolves, so the caller is released after this
    /// and the failure UI can replace the spinner. The decode keeps running
    /// in the background — a late finish still lands in the cache.
    static let decodeTimeout: Duration = .seconds(15)

    func previewImage(
        from url: URL,
        preference: EmbeddedJPEGPreviewPreference,
        maximumPixelSize: Int,
        priority: TaskPriority,
        timeout: Duration = EmbeddedPreviewStore.decodeTimeout
    ) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let sourceKey = CacheKey(
            path: url.standardizedFileURL.path,
            preference: preference == .thumbnail ? "thumbnail" : "full"
        )
        let key = ImageCacheKey(source: sourceKey, maximumPixelSize: maximumPixelSize)
        if let cached = imageCache[key] { return cached }

        DebugLog.shared.log(
            "decode.start",
            subsystem: .preview,
            url: url,
            detail: "\(maximumPixelSize) px"
        )
        let start = ContinuousClock.now
        let pending = PendingDecode()
        // Detached rather than a task-group child: a group scope waits for
        // every child, so a decode parked in an uninterruptible read would
        // hold the group — and the caller — open forever. The size stat runs
        // inside the worker for the same reason: it can hang on a dead
        // volume, and the waiter must still be released by the timer.
        _ = Task.detached(priority: priority) { [self] in
            pending.size = DebugLog.fileSize(of: url)
            let decoded = await self.decodeImage(
                url: url,
                preference: preference,
                maximumPixelSize: maximumPixelSize,
                priority: priority
            )
            if let decoded { await self.store(decoded, for: key) }
            pending.resolve(.decoded(decoded))
        }
        let timer = Task.detached {
            try? await Task.sleep(for: timeout)
            pending.resolve(.timeout)
        }
        let resolution = await withTaskCancellationHandler {
            await withCheckedContinuation { pending.arm($0) }
        } onCancel: {
            pending.resolve(.cancelled)
        }
        timer.cancel()
        let elapsed = ContinuousClock.now - start

        switch resolution {
        case .decoded(let image):
            DebugLog.shared.log(
                "decode.finish",
                subsystem: .preview,
                level: image == nil ? .warning : .debug,
                outcome: image == nil ? .error : .ok,
                duration: elapsed,
                url: url,
                size: pending.size,
                error: image == nil ? "decode produced no image" : nil
            )
            return Task.isCancelled ? nil : image
        case .timeout:
            DebugLog.shared.log(
                "decode.timeout",
                subsystem: .preview,
                level: .warning,
                outcome: .timeout,
                duration: elapsed,
                url: url,
                size: pending.size,
                detail: "wait released; decode still running in background"
            )
            return nil
        case .cancelled:
            DebugLog.shared.log(
                "decode.finish",
                subsystem: .preview,
                outcome: .cancel,
                duration: elapsed,
                url: url
            )
            return nil
        }
    }

    private func decodeImage(
        url: URL,
        preference: EmbeddedJPEGPreviewPreference,
        maximumPixelSize: Int,
        priority: TaskPriority
    ) async -> CGImage? {
        if CameraPreviewSupport.isEmbeddedSonyRAW(url) {
            guard let data = await jpegData(from: url, preference: preference) else { return nil }
            return await Task.detached(priority: priority) {
                PreviewImageDecoder.cgImage(data: data, maximumPixelSize: maximumPixelSize)
            }.value
        }
        return await Task.detached(priority: priority) {
            PreviewImageDecoder.cgImage(url: url, maximumPixelSize: maximumPixelSize)
        }.value
    }

    /// Cache insert shared by the caller's own decode and a decode that
    /// finishes after its waiter already timed out.
    private func store(_ image: CGImage, for key: ImageCacheKey) {
        if imageCache[key] != nil { return }
        imageCache[key] = image
        imageCacheOrder.append(key)
        cachedImageBytes += image.bytesPerRow * image.height
        while cachedImageBytes > maximumCachedImageBytes,
              let oldest = imageCacheOrder.first {
            imageCacheOrder.removeFirst()
            if let removed = imageCache.removeValue(forKey: oldest) {
                cachedImageBytes -= removed.bytesPerRow * removed.height
            }
        }
    }
}

/// First-wins resume box bounding a wait on a decode that may be parked in
/// an uninterruptible filesystem call: the waiter is released on timeout or
/// cancellation while the worker keeps running in the background.
private final class PendingDecode: @unchecked Sendable {
    enum Resolution {
        case decoded(CGImage?)
        case timeout
        case cancelled
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Resolution, Never>?
    private var resolution: Resolution?
    private var reportedSize: Int64?

    /// File size captured by the worker before decoding, so timeout and
    /// finish events can report it when the `stat` got through.
    var size: Int64? {
        get { lock.lock(); defer { lock.unlock() }; return reportedSize }
        set { lock.lock(); reportedSize = newValue; lock.unlock() }
    }

    func arm(_ continuation: CheckedContinuation<Resolution, Never>) {
        lock.lock()
        if let resolution {
            lock.unlock()
            continuation.resume(returning: resolution)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// First call wins; a resolve that lands before `arm` is stashed so the
    /// continuation still resumes instead of parking forever.
    func resolve(_ resolution: Resolution) {
        lock.lock()
        guard self.resolution == nil else {
            lock.unlock()
            return
        }
        self.resolution = resolution
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: resolution)
        } else {
            lock.unlock()
        }
    }
}

enum CameraPreviewSupport {
    private static let ordinaryImageExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp"
    ]

    static func canDecode(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "arw" || ordinaryImageExtensions.contains(ext)
    }

    static func isEmbeddedSonyRAW(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "arw"
    }
}

/// Spinner text that names what the file actually is — a PNG reads as
/// "PNG", a RAW reads its embedded JPEG — so a stalled read on screen says
/// something truthful about the file it's stuck on.
enum PreviewLoadMessage {
    static func title(for url: URL?) -> String {
        guard let ext = url?.pathExtension.lowercased(), !ext.isEmpty else {
            return "Reading preview…"
        }
        if OrganizeFileClassifier.rawExtensions.contains(ext) {
            return "Reading embedded JPEG…"
        }
        switch ext {
        case "jpg", "jpeg": return "Reading JPEG…"
        case "png": return "Reading PNG…"
        case "heic", "heif": return "Reading HEIC…"
        case "tif", "tiff": return "Reading TIFF…"
        case "webp": return "Reading WebP…"
        default:
            return OrganizeFileClassifier.videoExtensions.contains(ext)
                ? "Reading video frame…"
                : "Reading preview…"
        }
    }
}

enum PreviewImageDecoder {
    static func cgImage(data: Data, maximumPixelSize: Int) -> CGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return cgImage(source: source, maximumPixelSize: maximumPixelSize)
        }
    }

    static func cgImage(url: URL, maximumPixelSize: Int) -> CGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return cgImage(source: source, maximumPixelSize: maximumPixelSize)
        }
    }

    static func image(data: Data, maximumPixelSize: Int) -> NSImage? {
        guard let image = cgImage(data: data, maximumPixelSize: maximumPixelSize) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func cgImage(source: CGImageSource, maximumPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

struct CameraFileThumbnail: View {
    let url: URL
    let fallbackSymbol: String
    let height: CGFloat

    @State private var image: CGImage?
    @State private var finishedLoading = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .scaledToFit()
                    .padding(max(5, height * 0.18))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: BrowserThumbnailSizing.width(for: height), height: height)
        .background(Color.black.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .overlay {
            if !finishedLoading && CameraPreviewSupport.canDecode(url) {
                ProgressView()
                    .controlSize(.mini)
                    .padding(4)
                    .background(.regularMaterial, in: Circle())
            }
        }
        .task(id: "\(url.path)-\(Int(height.rounded()))") {
            image = nil
            finishedLoading = false
            if CameraPreviewSupport.canDecode(url) {
                image = await EmbeddedPreviewStore.shared.previewImage(
                    from: url,
                    preference: .thumbnail,
                    maximumPixelSize: BrowserThumbnailSizing.maximumPixelSize(for: height),
                    priority: .utility
                )
            }
            if !Task.isCancelled {
                finishedLoading = true
            }
        }
        .help(image == nil && finishedLoading ? "No embedded preview found" : url.lastPathComponent)
    }
}

struct CameraSelectionPreview: View {
    let url: URL

    @State private var image: CGImage?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Embedded camera preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    PhotomatorLauncher.open(url)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Open in Photomator")
                .help("Open in Photomator")
            }
            .buttonStyle(.borderless)
            .padding(10)
            .background(.bar)

            InteractivePreviewCanvas(image: image, isLoading: isLoading, file: url)
                .id(url.path)
        }
        .task(id: url.path) {
            isLoading = true
            // Paint any tile decode already in the loader's cache — cheaper
            // and instant — while the full preview reads underneath.
            image = TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 2_400)
                ?? TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 1_280)
                ?? TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 768)
                ?? TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 384)
            // Avoid starting card I/O for every row the user flicks through.
            // The spinner is immediate, while the actual preview work begins
            // only after the selection has remained stable briefly.
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            if CameraPreviewSupport.canDecode(url) {
                let decoded = await EmbeddedPreviewStore.shared.previewImage(
                    from: url,
                    preference: .thumbnail,
                    maximumPixelSize: 1_600,
                    priority: .userInitiated
                )
                if let decoded { image = decoded }
            }
            if !Task.isCancelled {
                isLoading = false
            }
        }
    }
}

@MainActor
final class EmbeddedPreviewWindowController {
    static let shared = EmbeddedPreviewWindowController()
    private static let minimumContentSize = CameraToolkitPopOutWindow.preview.minimumContentSize
    private static let defaultContentSize = NSSize(width: 1_080, height: 760)

    private var window: NSWindow?

    func show(urls: [URL], startingAt selectedURL: URL? = nil) {
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        let startingIndex = selectedURL.flatMap { selected in
            files.firstIndex { $0.standardizedFileURL == selected.standardizedFileURL }
        } ?? 0

        let content = EmbeddedPreviewView(urls: files, startingAt: startingIndex)
            .frame(
                minWidth: Self.minimumContentSize.width,
                minHeight: Self.minimumContentSize.height
            )
        if let window {
            let previousFrame = window.frame
            let hadCollapsedFrame = previousFrame.width < Self.minimumContentSize.width
                || previousFrame.height < Self.minimumContentSize.height
            window.contentViewController = NSHostingController(rootView: content)
            CameraToolkitWindowSizing.configure(window, as: .preview)
            if hadCollapsedFrame {
                window.setContentSize(Self.defaultContentSize)
                window.center()
            } else {
                // Replacing an NSHostingController can make AppKit adopt the
                // new SwiftUI view's temporary fitting size. Restore the
                // user's last valid preview frame after the replacement.
                window.setFrame(previousFrame, display: true)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Camera Toolkit Preview"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content)
        CameraToolkitWindowSizing.configure(window, as: .preview)
        // Assigning the hosting controller makes AppKit adopt SwiftUI's
        // minimum fitting size. Re-apply the intended first-open size after
        // that assignment so a new preview starts comfortably large.
        window.setContentSize(Self.defaultContentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.orderOut(nil)
    }
}

private struct EmbeddedPreviewView: View {
    let urls: [URL]

    @State private var index: Int
    @State private var image: CGImage?
    @State private var isLoading = true

    private var currentURL: URL { urls[index] }

    init(urls: [URL], startingAt index: Int) {
        self.urls = urls
        _index = State(initialValue: min(max(index, 0), max(0, urls.count - 1)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: previous) { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button(action: next) { Image(systemName: "chevron.right") }
                    .disabled(index + 1 >= urls.count)
                    .keyboardShortcut(.rightArrow, modifiers: [])

                VStack(alignment: .leading, spacing: 1) {
                    Text(currentURL.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                    Text(urls.count == 1 ? "Embedded camera preview" : "\(index + 1) of \(urls.count) · Embedded camera preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open in Photomator") {
                    openInPhotomator(currentURL)
                }
            }
            .buttonStyle(.borderless)
            .padding(12)
            .background(.bar)

            InteractivePreviewCanvas(
                image: image,
                isLoading: isLoading,
                file: currentURL,
                unavailableTitle: "No Embedded Preview",
                unavailableDescription: "Camera Toolkit could not find a JPEG preview in this RAW file.",
                onDismiss: { EmbeddedPreviewWindowController.shared.close() }
            )
            .id(currentURL.path)
        }
        .task(id: currentURL.path) {
            isLoading = true
            image = TileImageLoader.shared.cachedImage(for: currentURL, maximumPixelSize: 2_400)
                ?? TileImageLoader.shared.cachedImage(for: currentURL, maximumPixelSize: 1_280)
                ?? TileImageLoader.shared.cachedImage(for: currentURL, maximumPixelSize: 768)
                ?? TileImageLoader.shared.cachedImage(for: currentURL, maximumPixelSize: 384)
            if CameraPreviewSupport.canDecode(currentURL) {
                let decoded = await EmbeddedPreviewStore.shared.previewImage(
                    from: currentURL,
                    preference: .fullSize,
                    maximumPixelSize: 2_048,
                    priority: .userInitiated
                )
                if let decoded { image = decoded }
            }
            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    private func previous() {
        guard index > 0 else { return }
        index -= 1
    }

    private func next() {
        guard index + 1 < urls.count else { return }
        index += 1
    }

    private func openInPhotomator(_ url: URL) {
        PhotomatorLauncher.open(url)
    }
}

enum PhotomatorLauncher {
    static func open(_ url: URL) {
        open([url])
    }

    static func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let app = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.pixelmatorteam.pixelmator.touch.x.photo"
        ) else {
            urls.forEach { NSWorkspace.shared.open($0) }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
    }
}
