import AppKit
import CameraToolkitCore
import SwiftUI

/// A zoom action a parent pushes into the canvas — used for keyboard
/// shortcuts (such as `+`, `-`, `0`, `⌘1`) that the canvas does not own.
enum PreviewZoomCommand: Equatable {
    case zoomIn
    case zoomOut
    case fit
    case actualSize
}

/// Pure geometry for `InteractivePreviewCanvas`, kept free of SwiftUI state
/// so the math is directly testable.
enum PreviewZoomMath {
    static let maximumZoom: CGFloat = 8
    /// Points of padding around the image inside the canvas.
    static let padding: CGFloat = 10

    static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, 1), maximumZoom)
    }

    /// The scale that fits an image (in points) inside the canvas's usable area.
    static func fitScale(imageSize: CGSize, canvasSize: CGSize) -> CGFloat {
        let usable = usableSize(canvasSize)
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return min(usable.width / imageSize.width, usable.height / imageSize.height)
    }

    /// Zoom that shows one image pixel per screen point. `imageScale` is the
    /// image's pixels-per-point (2 for a 4800 px decode shown at a 2400 pt
    /// layout), so 1:1 always means real pixels regardless of decode size.
    static func actualSizeZoom(imageSize: CGSize, imageScale: CGFloat, canvasSize: CGSize) -> CGFloat {
        let fit = fitScale(imageSize: imageSize, canvasSize: canvasSize)
        return clampedZoom(max(imageScale, 0.001) / max(fit, 0.001))
    }

    /// Pan offset after zooming `fromZoom` to `toZoom` while keeping the
    /// canvas point `anchor` over the same image pixel.
    static func anchoredOffset(
        anchor: CGPoint,
        canvasSize: CGSize,
        offset: CGSize,
        fromZoom: CGFloat,
        toZoom: CGFloat
    ) -> CGSize {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let ratio = toZoom / max(fromZoom, 0.001)
        return CGSize(
            width: (anchor.x - center.x) - ((anchor.x - center.x) - offset.width) * ratio,
            height: (anchor.y - center.y) - ((anchor.y - center.y) - offset.height) * ratio
        )
    }

    /// Clamps a pan offset so the displayed image never leaves a gap inside
    /// the usable canvas area.
    static func clampedOffset(
        _ proposedOffset: CGSize,
        imageSize: CGSize,
        canvasSize: CGSize,
        zoom: CGFloat
    ) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let usable = usableSize(canvasSize)
        let fit = fitScale(imageSize: imageSize, canvasSize: canvasSize)
        let displayedWidth = imageSize.width * fit * zoom
        let displayedHeight = imageSize.height * fit * zoom
        let maximumX = max(0, (displayedWidth - usable.width) / 2)
        let maximumY = max(0, (displayedHeight - usable.height) / 2)
        return CGSize(
            width: min(max(proposedOffset.width, -maximumX), maximumX),
            height: min(max(proposedOffset.height, -maximumY), maximumY)
        )
    }

    private static func usableSize(_ canvasSize: CGSize) -> CGSize {
        CGSize(
            width: max(1, canvasSize.width - padding * 2),
            height: max(1, canvasSize.height - padding * 2)
        )
    }
}

/// Zoomable, pannable image canvas shared by the file-browser previews and
/// the burst review overlay. Pinch or the pill buttons zoom, a click toggles
/// zoom anchored at the pointer, and dragging pans while zoomed.
struct InteractivePreviewCanvas: View {
    let image: CGImage?
    var isLoading: Bool
    /// Pixels per point of `image`. A higher-resolution decode swapped in
    /// under an existing layout uses e.g. 2, so zoom level and pan offset are
    /// preserved exactly.
    var imageScale: CGFloat = 1
    /// The file being read — drives the spinner text ("Reading PNG…" vs
    /// "Reading embedded JPEG…") and the bounded-wait debug event.
    var file: URL? = nil
    /// Longest the spinner may run before the failure UI replaces it. A read
    /// stuck on a dead or sleeping volume would otherwise spin forever; the
    /// load itself is never cancelled here — a late image still paints over
    /// the failure UI.
    var loadingTimeout: Duration = .seconds(20)
    var unavailableTitle = "No Preview"
    var unavailableDescription = "No embedded JPEG was found."
    var onDismiss: (() -> Void)?
    /// Parent-driven zoom commands; the canvas performs each one and clears
    /// the binding back to nil.
    var zoomCommand: Binding<PreviewZoomCommand?> = .constant(nil)
    /// Reports the effective zoom whenever it changes, including mid-pinch,
    /// so the parent can upgrade the decode for deep zooming.
    var onZoomChange: ((CGFloat) -> Void)?

    @State private var zoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var loadingTimedOut = false
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @FocusState private var hasKeyboardFocus: Bool

    /// True while the canvas is waiting on a first decode — the state that
    /// must not be allowed to spin forever.
    private var waitingForImage: Bool {
        image == nil && isLoading
    }

    private var loadingTitle: String {
        PreviewLoadMessage.title(for: file)
    }

    /// The image's size in screen points.
    private var imagePointSize: CGSize {
        guard let image else { return .zero }
        let scale = max(imageScale, 0.001)
        return CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    var body: some View {
        GeometryReader { geometry in
            let effectiveZoom = PreviewZoomMath.clampedZoom(zoom * magnification)
            let proposedOffset = CGSize(
                width: panOffset.width + dragTranslation.width,
                height: panOffset.height + dragTranslation.height
            )
            let displayOffset = PreviewZoomMath.clampedOffset(
                proposedOffset,
                imageSize: imagePointSize,
                canvasSize: geometry.size,
                zoom: effectiveZoom
            )

            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: imageScale)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(effectiveZoom)
                        .offset(displayOffset)
                        .padding(PreviewZoomMath.padding)
                } else if isLoading && !loadingTimedOut {
                    ProgressView { Text(loadingTitle) }
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
                                perform(.zoomOut, canvasSize: geometry.size)
                            } label: {
                                Image(systemName: "minus.magnifyingglass")
                            }
                            .accessibilityLabel("Zoom Out")
                            .help("Zoom Out (-)")

                            Text("\(Int(effectiveZoom * 100))%")
                                .font(.caption.monospacedDigit())
                                .frame(minWidth: 42)

                            Button {
                                perform(.zoomIn, canvasSize: geometry.size)
                            } label: {
                                Image(systemName: "plus.magnifyingglass")
                            }
                            .accessibilityLabel("Zoom In")
                            .help("Zoom In (+)")

                            Divider().frame(height: 16)

                            Button {
                                perform(.fit, canvasSize: geometry.size)
                            } label: {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                            }
                            .accessibilityLabel("Zoom to Fit")
                            .help("Zoom to Fit (0)")
                            .keyboardShortcut("0", modifiers: .command)

                            Button {
                                perform(.actualSize, canvasSize: geometry.size)
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
                        let translation = value.translation
                        if abs(translation.width) < 4, abs(translation.height) < 4 {
                            // A drag that never moved is a click: toggle zoom
                            // anchored at the pointer.
                            toggleZoom(at: value.location, canvasSize: geometry.size)
                        } else {
                            let requestedOffset = CGSize(
                                width: panOffset.width + translation.width,
                                height: panOffset.height + translation.height
                            )
                            panOffset = PreviewZoomMath.clampedOffset(
                                requestedOffset,
                                imageSize: imagePointSize,
                                canvasSize: geometry.size,
                                zoom: zoom
                            )
                        }
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($magnification) { value, state, _ in
                        state = value.magnification
                    }
                    .onEnded { value in
                        setZoom(zoom * value.magnification, canvasSize: geometry.size)
                    }
            )
            .focusable(onDismiss != nil)
            .focused($hasKeyboardFocus)
            .focusEffectDisabled()
            .onAppear {
                if onDismiss != nil {
                    hasKeyboardFocus = true
                }
                // A command stranded across a remount (`.id` change) would
                // never fire onChange — drop it so it can't wedge; the fresh
                // canvas is already at fit.
                zoomCommand.wrappedValue = nil
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
            .onKeyPress(phases: .down) { press in
                // Only reachable while the canvas itself holds focus (the
                // pop-out preview window); embedded use forwards commands
                // through `zoomCommand` instead.
                guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
                switch press.characters {
                case "+", "=":
                    perform(.zoomIn, canvasSize: geometry.size)
                case "-", "_":
                    perform(.zoomOut, canvasSize: geometry.size)
                case "0":
                    perform(.fit, canvasSize: geometry.size)
                default:
                    return .ignored
                }
                return .handled
            }
            .onChange(of: effectiveZoom) { _, newZoom in
                onZoomChange?(newZoom)
            }
            .onChange(of: zoomCommand.wrappedValue) { _, command in
                guard let command else { return }
                perform(command, canvasSize: geometry.size)
                zoomCommand.wrappedValue = nil
            }
        }
        .clipped()
        .accessibilityLabel("Interactive Photo Preview")
        .accessibilityHint("Click or pinch to zoom, then drag to pan the photo")
        .task(id: "\(waitingForImage)#\(file?.path ?? "")") {
            if waitingForImage {
                loadingTimedOut = false
                try? await Task.sleep(for: loadingTimeout)
                guard !Task.isCancelled else { return }
                loadingTimedOut = true
                DebugLog.shared.log(
                    "wait.timeout",
                    subsystem: .preview,
                    level: .warning,
                    outcome: .timeout,
                    duration: loadingTimeout,
                    url: file,
                    detail: "spinner replaced by failure UI"
                )
            } else {
                loadingTimedOut = false
            }
        }
    }

    private func toggleZoom(at location: CGPoint, canvasSize: CGSize) {
        guard image != nil else { return }
        if zoom == 1 {
            let target = PreviewZoomMath.actualSizeZoom(
                imageSize: imagePointSize,
                imageScale: imageScale,
                canvasSize: canvasSize
            )
            guard target > 1 else { return }
            zoom = target
            panOffset = PreviewZoomMath.clampedOffset(
                PreviewZoomMath.anchoredOffset(
                    anchor: location,
                    canvasSize: canvasSize,
                    offset: panOffset,
                    fromZoom: 1,
                    toZoom: target
                ),
                imageSize: imagePointSize,
                canvasSize: canvasSize,
                zoom: zoom
            )
        } else {
            setZoom(1, canvasSize: canvasSize)
        }
    }

    private func perform(_ command: PreviewZoomCommand, canvasSize: CGSize) {
        switch command {
        case .zoomIn:
            setZoom(zoom * 1.25, canvasSize: canvasSize)
        case .zoomOut:
            setZoom(zoom / 1.25, canvasSize: canvasSize)
        case .fit:
            setZoom(1, canvasSize: canvasSize)
        case .actualSize:
            setZoom(
                PreviewZoomMath.actualSizeZoom(
                    imageSize: imagePointSize,
                    imageScale: imageScale,
                    canvasSize: canvasSize
                ),
                canvasSize: canvasSize
            )
        }
    }

    private func setZoom(_ requestedZoom: CGFloat, canvasSize: CGSize) {
        zoom = PreviewZoomMath.clampedZoom(requestedZoom)
        if zoom == 1 {
            panOffset = .zero
        } else {
            panOffset = PreviewZoomMath.clampedOffset(
                panOffset,
                imageSize: imagePointSize,
                canvasSize: canvasSize,
                zoom: zoom
            )
        }
    }
}
