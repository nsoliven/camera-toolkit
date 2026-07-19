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

    func previewImage(
        from url: URL,
        preference: EmbeddedJPEGPreviewPreference,
        maximumPixelSize: Int,
        priority: TaskPriority
    ) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let sourceKey = CacheKey(
            path: url.standardizedFileURL.path,
            preference: preference == .thumbnail ? "thumbnail" : "full"
        )
        let key = ImageCacheKey(source: sourceKey, maximumPixelSize: maximumPixelSize)
        if let cached = imageCache[key] { return cached }

        let image: CGImage?
        if CameraPreviewSupport.isEmbeddedSonyRAW(url) {
            guard let data = await jpegData(from: url, preference: preference),
                  !Task.isCancelled else { return nil }
            image = await Task.detached(priority: priority) {
                PreviewImageDecoder.cgImage(data: data, maximumPixelSize: maximumPixelSize)
            }.value
        } else {
            image = await Task.detached(priority: priority) {
                PreviewImageDecoder.cgImage(url: url, maximumPixelSize: maximumPixelSize)
            }.value
        }

        guard !Task.isCancelled, let image else { return nil }
        if let cached = imageCache[key] { return cached }
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
        return image
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

    static func image(url: URL, maximumPixelSize: Int) -> NSImage? {
        guard let image = cgImage(url: url, maximumPixelSize: maximumPixelSize) else { return nil }
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

private struct InteractivePreviewCanvas: View {
    let image: CGImage?
    let isLoading: Bool
    var unavailableTitle = "No Preview"
    var unavailableDescription = "No embedded JPEG was found."
    var onDismiss: (() -> Void)?

    @State private var zoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        GeometryReader { geometry in
            let effectiveZoom = clampedZoom(zoom * magnification)
            let proposedOffset = CGSize(
                width: panOffset.width + dragTranslation.width,
                height: panOffset.height + dragTranslation.height
            )
            let displayOffset = clampedOffset(
                proposedOffset,
                image: image,
                canvasSize: geometry.size,
                zoom: effectiveZoom
            )

            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(effectiveZoom)
                        .offset(displayOffset)
                        .padding(10)
                } else if isLoading {
                    ProgressView("Reading embedded JPEG…")
                        .tint(.white)
                        .foregroundStyle(.white)
                } else {
                    ContentUnavailableView(
                        unavailableTitle,
                        systemImage: "photo.badge.exclamationmark",
                        description: Text(unavailableDescription)
                    )
                    .foregroundStyle(.white)
                }

                if image != nil {
                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Button {
                                setZoom(zoom / 1.25, image: image, canvasSize: geometry.size)
                            } label: {
                                Image(systemName: "minus.magnifyingglass")
                            }
                            .accessibilityLabel("Zoom Out")
                            .help("Zoom Out")

                            Text("\(Int(effectiveZoom * 100))%")
                                .font(.caption.monospacedDigit())
                                .frame(minWidth: 42)

                            Button {
                                setZoom(zoom * 1.25, image: image, canvasSize: geometry.size)
                            } label: {
                                Image(systemName: "plus.magnifyingglass")
                            }
                            .accessibilityLabel("Zoom In")
                            .help("Zoom In")

                            Divider().frame(height: 16)

                            Button {
                                setZoom(1, image: image, canvasSize: geometry.size)
                            } label: {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                            }
                            .accessibilityLabel("Zoom to Fit")
                            .help("Zoom to Fit (Command-0)")
                            .keyboardShortcut("0", modifiers: .command)

                            Button {
                                setZoom(actualSizeZoom(image: image, canvasSize: geometry.size), image: image, canvasSize: geometry.size)
                            } label: {
                                Text("1:1")
                                    .font(.caption.bold())
                            }
                            .accessibilityLabel("Actual Size")
                            .help("Actual Size (Command-1)")
                            .keyboardShortcut("1", modifiers: .command)
                        }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(12)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragTranslation) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        let requestedOffset = CGSize(
                            width: panOffset.width + value.translation.width,
                            height: panOffset.height + value.translation.height
                        )
                        panOffset = clampedOffset(
                            requestedOffset,
                            image: image,
                            canvasSize: geometry.size,
                            zoom: zoom
                        )
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($magnification) { value, state, _ in
                        state = value.magnification
                    }
                    .onEnded { value in
                        setZoom(zoom * value.magnification, image: image, canvasSize: geometry.size)
                    }
            )
            .onTapGesture(count: 2) {
                let requestedZoom = zoom == 1 ? actualSizeZoom(image: image, canvasSize: geometry.size) : 1
                setZoom(requestedZoom, image: image, canvasSize: geometry.size)
            }
            .focusable(onDismiss != nil)
            .focused($hasKeyboardFocus)
            .focusEffectDisabled()
            .onAppear {
                if onDismiss != nil {
                    hasKeyboardFocus = true
                }
            }
            .onKeyPress(.space) {
                guard let onDismiss else { return .ignored }
                onDismiss()
                return .handled
            }
            .onKeyPress(.escape) {
                guard let onDismiss else { return .ignored }
                onDismiss()
                return .handled
            }
        }
        .clipped()
        .accessibilityLabel("Interactive Photo Preview")
        .accessibilityHint("Zoom, then drag to pan the photo")
    }

    private func setZoom(_ requestedZoom: CGFloat, image: CGImage?, canvasSize: CGSize) {
        zoom = clampedZoom(requestedZoom)
        if zoom == 1 {
            panOffset = .zero
        } else {
            panOffset = clampedOffset(panOffset, image: image, canvasSize: canvasSize, zoom: zoom)
        }
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, 1), 8)
    }

    private func actualSizeZoom(image: CGImage?, canvasSize: CGSize) -> CGFloat {
        guard let image, image.width > 0, image.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else {
            return 1
        }
        let usableSize = CGSize(width: max(1, canvasSize.width - 20), height: max(1, canvasSize.height - 20))
        let fitScale = min(usableSize.width / CGFloat(image.width), usableSize.height / CGFloat(image.height))
        return clampedZoom(1 / max(fitScale, 0.001))
    }

    private func clampedOffset(
        _ proposedOffset: CGSize,
        image: CGImage?,
        canvasSize: CGSize,
        zoom: CGFloat
    ) -> CGSize {
        guard let image, image.width > 0, image.height > 0 else { return .zero }
        let usableSize = CGSize(width: max(1, canvasSize.width - 20), height: max(1, canvasSize.height - 20))
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let fitScale = min(usableSize.width / imageWidth, usableSize.height / imageHeight)
        let displayedWidth = imageWidth * fitScale * zoom
        let displayedHeight = imageHeight * fitScale * zoom
        let maximumX = max(0, (displayedWidth - usableSize.width) / 2)
        let maximumY = max(0, (displayedHeight - usableSize.height) / 2)
        return CGSize(
            width: min(max(proposedOffset.width, -maximumX), maximumX),
            height: min(max(proposedOffset.height, -maximumY), maximumY)
        )
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

            InteractivePreviewCanvas(image: image, isLoading: isLoading)
                .id(url.path)
        }
        .task(id: url.path) {
            isLoading = true
            image = nil
            // Avoid starting card I/O for every row the user flicks through.
            // The spinner is immediate, while the actual preview work begins
            // only after the selection has remained stable briefly.
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            if CameraPreviewSupport.canDecode(url) {
                image = await EmbeddedPreviewStore.shared.previewImage(
                    from: url,
                    preference: .thumbnail,
                    maximumPixelSize: 1_600,
                    priority: .userInitiated
                )
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
    private static let minimumContentSize = NSSize(width: 640, height: 440)
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
            window.contentMinSize = Self.minimumContentSize
            window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)).size
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
        window.contentMinSize = Self.minimumContentSize
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize)).size
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content)
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
                unavailableTitle: "No Embedded Preview",
                unavailableDescription: "Camera Toolkit could not find a JPEG preview in this RAW file.",
                onDismiss: { EmbeddedPreviewWindowController.shared.close() }
            )
            .id(currentURL.path)
        }
        .task(id: currentURL.path) {
            isLoading = true
            image = nil
            if CameraPreviewSupport.canDecode(currentURL) {
                image = await EmbeddedPreviewStore.shared.previewImage(
                    from: currentURL,
                    preference: .fullSize,
                    maximumPixelSize: 2_048,
                    priority: .userInitiated
                )
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

private enum PhotomatorLauncher {
    static func open(_ url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.pixelmatorteam.pixelmator.touch.x.photo"
        ) else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
    }
}
