import AVFoundation
import CoreImage
import Foundation

/// Applies grades with Core Image. Colour management is off on purpose:
/// a log curve is defined on the camera's code values, and a colour-managed
/// pipeline would first "linearize" those values as if they were Rec.709.
/// Frames go in as decoded values and come out as Rec.709 code values,
/// tagged the way AVFoundation tags Rec.709 video, so a graded still and
/// graded playback look the same.
public final class GradeRenderer: @unchecked Sendable {
    public static let shared = GradeRenderer()

    /// The cube size for previews and tiles; renders use `renderCubeSize`.
    public static let previewCubeSize = 33
    public static let renderCubeSize = 64

    /// Unmanaged: values pass through untouched.
    public let context: CIContext
    /// What graded output is tagged as.
    public static let outputColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.coreMedia709) ?? CGColorSpace(name: CGColorSpace.itur_709)!

    private let lock = NSLock()
    private var cubes: [String: Data] = [:]
    private var cubeOrder: [String] = []
    private var ranges: [String: VideoSignalRange] = [:]
    /// Imported LUTs by id; set by the app.
    public var lutProvider: @Sendable (String) -> CubeLUT? = { _ in nil }

    private let managedContext = CIContext(options: [.cacheIntermediates: false, .name: "CameraToolkit.GradeMatch"])

    public init() {
        context = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
            .name: "CameraToolkit.Grade",
        ])
    }

    // MARK: Cubes

    public func pipeline(for recipe: GradeRecipe) -> GradePipeline {
        var conversion: CubeLUT?
        var look: CubeLUT?
        if case .lut(let id) = recipe.conversion { conversion = lutProvider(id) }
        if case .lut(let id) = recipe.grade.look { look = lutProvider(id) }
        return GradePipeline(recipe: recipe, conversionLUT: conversion, lookLUT: look)
    }

    /// The baked cube for a recipe, computed once and kept (a few dozen).
    public func cube(for recipe: GradeRecipe, size: Int = GradeRenderer.previewCubeSize) -> Data {
        let key = "\(size)|\(recipe.fingerprint)|\(lutStamp(recipe))"
        lock.lock()
        if let cached = cubes[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let floats = pipeline(for: recipe).cubeData(size: size)
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        if cubes[key] == nil {
            cubes[key] = data
            cubeOrder.append(key)
            if cubeOrder.count > 48 {
                cubes[cubeOrder.removeFirst()] = nil
            }
        }
        lock.unlock()
        return data
    }

    /// A missing LUT draws as no look; the stamp keeps a cube baked while
    /// it was missing from being reused once it is imported again.
    private func lutStamp(_ recipe: GradeRecipe) -> String {
        var stamp = ""
        if case .lut(let id) = recipe.conversion { stamp += lutProvider(id) == nil ? "c-missing" : "c-ok" }
        if case .lut(let id) = recipe.grade.look { stamp += lutProvider(id) == nil ? "l-missing" : "l-ok" }
        return stamp
    }

    public func forgetCubes() {
        lock.lock()
        cubes.removeAll()
        cubeOrder.removeAll()
        lock.unlock()
    }

    public static func colorCube(_ data: Data, size: Int) -> CIFilter? {
        let filter = CIFilter(name: "CIColorCube")
        filter?.setValue(size, forKey: "inputCubeDimension")
        filter?.setValue(data, forKey: "inputCubeData")
        return filter
    }

    /// The image with the recipe's cube applied (no colour management).
    public func apply(_ recipe: GradeRecipe, to image: CIImage, cubeSize: Int = GradeRenderer.previewCubeSize) -> CIImage {
        guard !recipe.isIdentity, let filter = Self.colorCube(cube(for: recipe, size: cubeSize), size: cubeSize) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }

    // MARK: Stills

    /// A decoded frame (raw code values in a CGImage, as
    /// `AVAssetImageGenerator` returns them) graded and tagged Rec.709.
    public func grade(_ image: CGImage, recipe: GradeRecipe) -> CGImage? {
        guard let source = codeValueImage(image) else { return nil }
        let input = CIImage(cgImage: source, options: [.colorSpace: NSNull()])
        let output = apply(recipe, to: input)
        return render(output, extent: input.extent)
    }

    /// A video frame from `AVAssetImageGenerator` carries the decoded
    /// values tagged `CoreMedia709`: used as is. Anything else (a poster
    /// that went through the JPEG thumbnail cache, say) is colour-matched
    /// back into that space first, which recovers the same values.
    func codeValueImage(_ image: CGImage) -> CGImage? {
        if image.colorSpace?.name == CGColorSpace.coreMedia709 || image.colorSpace == nil { return image }
        let managed = CIImage(cgImage: image)
        return managedContext.createCGImage(managed, from: managed.extent, format: .RGBA16, colorSpace: Self.outputColorSpace)
    }

    /// A frame straight from the decoder (`AVAssetImageGenerator`) is
    /// code values whatever it is tagged — `CoreMedia709`, or an unnamed
    /// "QuickTime 'nclc' Video (9,1,9)" space for a clip tagged BT.2020.
    /// Retagging (never colour matching) keeps those values: matching a
    /// BT.2020-tagged log frame into Rec.709 expanded its gamut a second
    /// time on top of the S-Gamut3.Cine conversion, pushing reds and skin
    /// toward magenta.
    public static func codeValues(ofDecodedFrame image: CGImage) -> CGImage {
        guard image.colorSpace?.name != CGColorSpace.coreMedia709, image.colorSpace?.model == .rgb else { return image }
        return image.copy(colorSpace: outputColorSpace) ?? image
    }

    public func render(_ image: CIImage, extent: CGRect) -> CGImage? {
        guard let rendered = context.createCGImage(image, from: extent, format: .RGBA16, colorSpace: nil) else { return nil }
        return rendered.copy(colorSpace: Self.outputColorSpace) ?? rendered
    }

    // MARK: Signal range

    /// Whether a clip's video is full- or video-range, from its format
    /// description (cached by path), or nil when the file has no readable
    /// video track. Sony log clips are full range.
    public func signalRange(of url: URL) async -> VideoSignalRange? {
        if let known = lock.withLock({ ranges[url.path] }) { return known }
        let asset = CameraVideoAsset.asset(for: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let description = try? await track.load(.formatDescriptions).first else { return nil }
        let range = Self.signalRange(of: description)
        lock.withLock { ranges[url.path] = range }
        return range
    }

    public func knownSignalRange(of url: URL) -> VideoSignalRange? {
        lock.lock()
        defer { lock.unlock() }
        return ranges[url.path]
    }

    public static func signalRange(of description: CMFormatDescription) -> VideoSignalRange {
        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]
        let full = extensions?[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool
            ?? (extensions?[kCMFormatDescriptionExtension_FullRangeVideo as String] as? NSNumber)?.boolValue
            ?? false
        return full ? .full : .video
    }

    // MARK: Histogram

    /// 64-bin red, green, blue and luma histograms of an image, each bin
    /// normalized to the tallest bin across the four.
    public static func histogram(of image: CGImage, bins: Int = 64) -> GradeHistogram {
        let width = min(image.width, 256)
        let height = max(1, Int(Double(image.height) * Double(width) / Double(max(image.width, 1))))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let drawSpace = space.model == .rgb ? space : CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: drawSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return GradeHistogram(bins: bins) }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return histogram(rgba8: pixels, bins: bins)
    }

    public static func histogram(rgba8 pixels: [UInt8], bins: Int = 64) -> GradeHistogram {
        var result = GradeHistogram(bins: bins)
        var r = [Double](repeating: 0, count: bins), g = r, b = r, y = r
        let scale = Double(bins) / 256
        var clippedHigh = 0, clippedLow = 0, total = 0
        for i in stride(from: 0, to: pixels.count - 3, by: 4) {
            let rv = Int(pixels[i]), gv = Int(pixels[i + 1]), bv = Int(pixels[i + 2])
            r[Int(Double(rv) * scale)] += 1
            g[Int(Double(gv) * scale)] += 1
            b[Int(Double(bv) * scale)] += 1
            let luma = min(255, Int(0.2126 * Double(rv) + 0.7152 * Double(gv) + 0.0722 * Double(bv)))
            y[Int(Double(luma) * scale)] += 1
            if max(rv, gv, bv) >= 254 { clippedHigh += 1 }
            if luma <= 2 { clippedLow += 1 }
            total += 1
        }
        // The tallest bin decides the scale, ignoring the end bins so a
        // clipped sky does not flatten everything else.
        let peak = max(1, [r, g, b, y].flatMap { $0.dropFirst().dropLast() }.max() ?? 1)
        result.red = r.map { min(1, $0 / peak) }
        result.green = g.map { min(1, $0 / peak) }
        result.blue = b.map { min(1, $0 / peak) }
        result.luma = y.map { min(1, $0 / peak) }
        result.highlightClipFraction = total == 0 ? 0 : Double(clippedHigh) / Double(total)
        result.shadowClipFraction = total == 0 ? 0 : Double(clippedLow) / Double(total)
        return result
    }
}

public struct GradeHistogram: Equatable, Sendable {
    public var red: [Double]
    public var green: [Double]
    public var blue: [Double]
    public var luma: [Double]
    public var highlightClipFraction: Double = 0
    public var shadowClipFraction: Double = 0

    public init(bins: Int) {
        red = Array(repeating: 0, count: bins)
        green = red
        blue = red
        luma = red
    }
}

/// What live playback draws, changed from the main actor while frames
/// render on AVFoundation's queue.
public final class GradeLiveState: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var recipe: GradeRecipe?
        /// Show the original only.
        public var bypass: Bool
        /// 0…1: left of this fraction of the width shows the original
        /// (before), right of it the grade (after). Nil: no split.
        public var wipe: Double?
    }

    private let lock = NSLock()
    private var state = Snapshot(recipe: nil, bypass: false, wipe: nil)

    public init(recipe: GradeRecipe? = nil) {
        state.recipe = recipe
    }

    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func update(_ change: (inout Snapshot) -> Void) {
        lock.lock()
        change(&state)
        lock.unlock()
    }
}

extension GradeRenderer {
    /// A composition that grades every frame from `live`. Output is tagged
    /// Rec.709. Used by the preview player and by the renderer.
    public func videoComposition(for asset: AVAsset, live: GradeLiveState, cubeSize: Int = GradeRenderer.previewCubeSize) async throws -> AVVideoComposition {
        let context = self.context
        // AVFoundation hands the handler frames already converted into the
        // composition's Rec.709. For a track tagged BT.2020 that conversion
        // moved the log code values; undo it before the grade reads them
        // (the original side of a split keeps AVFoundation's picture).
        let undo = try await Self.sourceGamutUndo(for: asset)
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { [weak self] request in
            let source = request.sourceImage
            guard let self else {
                request.finish(with: source, context: context)
                return
            }
            let state = live.snapshot
            guard let recipe = state.recipe, !state.bypass, !recipe.isIdentity else {
                request.finish(with: source, context: context)
                return
            }
            var codeValues = source
            if let undo, let filter = Self.colorCube(undo, size: Self.previewCubeSize) {
                filter.setValue(source, forKey: kCIInputImageKey)
                codeValues = filter.outputImage ?? source
            }
            let graded = self.apply(recipe, to: codeValues, cubeSize: cubeSize)
            if let wipe = state.wipe {
                let extent = source.extent
                let split = extent.minX + extent.width * min(max(wipe, 0), 1)
                let before = source.cropped(to: CGRect(x: extent.minX, y: extent.minY, width: split - extent.minX, height: extent.height))
                let after = graded.cropped(to: CGRect(x: split, y: extent.minY, width: extent.maxX - split, height: extent.height))
                request.finish(with: after.composited(over: before), context: context)
            } else {
                request.finish(with: graded, context: context)
            }
        }
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return composition
    }

    /// The cube that takes AVFoundation's Rec.709 rendition of a BT.2020
    /// tagged track back to the track's own code values, or nil when the
    /// track is Rec.709 (or untagged) and nothing moved.
    static func sourceGamutUndo(for asset: AVAsset) async throws -> Data? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let description = try await track.load(.formatDescriptions).first else { return nil }
        return sourceGamutUndo(primaries: CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String)
    }

    static func sourceGamutUndo(primaries: String?) -> Data? {
        guard primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) else { return nil }
        let toSource = RGBPrimaries.rec709.conversion(to: .rec2020)
        let size = previewCubeSize
        let scale = 1 / Double(size - 1)
        var floats = [Float](repeating: 1, count: size * size * size * 4)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let shown = SIMD3(Double(r) * scale, Double(g) * scale, Double(b) * scale)
                    let linear = toSource.apply(SIMD3(Rec709Transfer.decode(shown.x), Rec709Transfer.decode(shown.y), Rec709Transfer.decode(shown.z)))
                    let index = ((b * size + g) * size + r) * 4
                    floats[index] = Float(min(max(Rec709Transfer.encode(linear.x), 0), 1))
                    floats[index + 1] = Float(min(max(Rec709Transfer.encode(linear.y), 0), 1))
                    floats[index + 2] = Float(min(max(Rec709Transfer.encode(linear.z), 0), 1))
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
