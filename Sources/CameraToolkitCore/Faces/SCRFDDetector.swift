import AVFoundation
import CoreML
import CoreGraphics
import Foundation

/// Anything that finds faces in a decoded image. LOW runs the Vision
/// detector; MED and above run the SCRFD CoreML detector from the same
/// model pack as the embedder. Both return `DetectedFace` so the rest of
/// the pipeline — align, embed, match, group — is identical per mode.
public protocol FaceDetecting: Sendable {
    /// Detects faces in `image` (a bounded decode of the `imagePixelSize`
    /// native image), dropping faces under `options.minimumFacePixels`
    /// measured on the *native* image.
    func detect(
        in image: CGImage,
        imagePixelSize: CGSize,
        options: FaceScanOptions
    ) -> [DetectedFace]
}

/// LOW mode: Apple Vision rectangles + landmarks on the Neural Engine.
public struct VisionDetector: FaceDetecting {
    public init() {}

    public func detect(
        in image: CGImage,
        imagePixelSize: CGSize,
        options: FaceScanOptions
    ) -> [DetectedFace] {
        VisionFaceDetector.detect(
            in: image,
            imagePixelSize: imagePixelSize,
            minimumFacePixels: options.minimumFacePixels
        )
    }
}

/// The SCRFD-10G detector converted to CoreML by `scripts/convert-scrfd.sh`.
/// Each converted package is a fixed square input (the ONNX trace bakes
/// per-shape constants), so the detector holds one model per input size —
/// 640 always, 960 and 1024 when installed for HIGH's and XHIGH's extra
/// scales. Every pass letterboxes the image into the requested canvas,
/// resamples to the tensor side when no native model exists, runs one
/// prediction, and decodes the three FPN strides (8/16/32, 2 anchors per
/// cell). Boxes and five-point landmarks come back in image pixels.
///
/// `heavyModelURLs` loads the optional SCRFD-34G siblings
/// (`det_34g*.mlpackage`) — XHIGH's per-scan opt-in for group-shot faces
/// the 10G pass still misses. When `FaceScanOptions.usesLargeDetector` is
/// on and a heavy package exists, every canvas runs the large family;
/// otherwise the standard models run.
///
/// One detector instance is shared across scan workers — `MLModel`
/// predictions are safe to run concurrently.
public final class SCRFDDetector: FaceDetecting, @unchecked Sendable {
    /// Feature-map strides SCRFD emits, largest receptive field last.
    static let strides = [8, 16, 32]
    /// Anchors per feature-map cell.
    static let anchorsPerCell = 2
    /// Cross-scale non-max suppression IoU.
    static let nmsIoU: Float = 0.4

    /// Tensor side → loaded model + its input name.
    private let models: [Int: (model: MLModel, inputName: String)]
    /// Tensor side → loaded 34G model + its input name. Empty unless the
    /// optional `det_34g*` siblings were installed and loaded.
    private let heavyModels: [Int: (model: MLModel, inputName: String)]
    /// Input sizes with a native model installed, ascending.
    public let nativeInputSizes: [Int]
    /// Input sizes with a native 34G package installed, ascending.
    public let heavyInputSizes: [Int]

    public init(modelURLs: [Int: URL], heavyModelURLs: [Int: URL] = [:]) async throws {
        let models = try await Self.compile(modelURLs)
        guard !models.isEmpty else {
            throw ToolkitError.commandFailed("The face detector has no usable model packages.")
        }
        self.models = models
        self.nativeInputSizes = models.keys.sorted()
        // The large family is optional — a bad sibling must not take down
        // the installed 10G detector, so a failed compile just drops it.
        self.heavyModels = (try? await Self.compile(heavyModelURLs)) ?? [:]
        self.heavyInputSizes = heavyModels.keys.sorted()
    }

    /// Compiles and loads each package, returning tensor side → model.
    private static func compile(
        _ modelURLs: [Int: URL]
    ) async throws -> [Int: (model: MLModel, inputName: String)] {
        var models: [Int: (model: MLModel, inputName: String)] = [:]
        for (size, url) in modelURLs {
            // A .mlpackage must be compiled before CoreML loads it; the
            // compiled product is cached while the package is unchanged.
            let compiledURL = try await MLModel.compileModel(at: url)
            let model = try MLModel(contentsOf: compiledURL)
            guard let inputName = model.modelDescription.inputDescriptionsByName.keys.sorted().first else {
                throw ToolkitError.commandFailed("The face detector has no tensor input.")
            }
            models[size] = (model, inputName)
        }
        return models
    }

    /// The model and tensor side for a requested canvas: the native model
    /// when one exists for that size, else the largest installed — the
    /// canvas render is resampled to fit.
    private func modelEntry(
        for canvasSize: Int,
        in table: [Int: (model: MLModel, inputName: String)]
    ) -> (model: MLModel, inputName: String, tensorSide: Int)? {
        if let exact = table[canvasSize] {
            return (exact.model, exact.inputName, canvasSize)
        }
        guard let side = table.keys.max(), let entry = table[side] else { return nil }
        return (entry.model, entry.inputName, side)
    }

    /// The package family and canvas scales a pass with these options
    /// runs — for the Jobs log, the one place package names may appear.
    public func packageSummary(for options: FaceScanOptions) -> String {
        let family = (options.usesLargeDetector && !heavyModels.isEmpty) ? "det_34g" : "det_10g"
        let scales = options.detectorScales.sorted().map(String.init).joined(separator: "/")
        return "\(family) \(scales)"
    }

    public func detect(
        in image: CGImage,
        imagePixelSize: CGSize,
        options: FaceScanOptions
    ) -> [DetectedFace] {
        let imageWidth = image.width
        let imageHeight = image.height
        guard imageWidth > 0, imageHeight > 0 else { return [] }

        // XHIGH's optional 34G family: engaged only when the pass asks for
        // it *and* a sibling package is installed — never a silent upgrade.
        let family = (options.usesLargeDetector && !heavyModels.isEmpty) ? heavyModels : models
        var candidates: [Candidate] = []
        for canvasSize in options.detectorScales.sorted() {
            guard let entry = modelEntry(for: canvasSize, in: family) else { continue }
            guard let tensor = try? Self.letterboxTensor(
                image,
                canvasSize: canvasSize,
                tensorSide: entry.tensorSide
            ) else { continue }
            guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
                entry.inputName: MLFeatureValue(multiArray: tensor),
            ]), let output = try? entry.model.prediction(from: provider) else { continue }

            let decoded = Self.decode(
                outputs: output,
                tensorSide: entry.tensorSide,
                scoreThreshold: options.detScoreThreshold
            )
            // Tensor pixels → image pixels: the canvas placed the image at
            // canvas/max(w,h), then the tensor resampled canvas→tensorSide.
            let toImagePixels = Double(max(imageWidth, imageHeight)) / Double(entry.tensorSide)
            candidates.append(contentsOf: decoded.map { $0.scaled(by: toImagePixels) })
        }

        let kept = Self.nonMaxSuppressed(candidates, iouThreshold: Self.nmsIoU)
        let width = Double(imageWidth)
        let height = Double(imageHeight)
        return kept.compactMap { candidate in
            let box = candidate.box
            guard box.width > 0, box.height > 0 else { return nil }
            // Measured on the native image so the size floor means the same
            // thing at every decode bound.
            let nativeMinSide = min(
                box.width / width * imagePixelSize.width,
                box.height / height * imagePixelSize.height
            )
            guard nativeMinSide >= options.minimumFacePixels else { return nil }
            // Normalized box, bottom-left origin — the Vision convention the
            // rest of the pipeline expects.
            let normalized = CGRect(
                x: box.origin.x / width,
                y: 1 - (box.origin.y + box.height) / height,
                width: box.width / width,
                height: box.height / height
            )
            return DetectedFace(
                boundingBox: normalized,
                confidence: candidate.score,
                landmarks: candidate.landmarks.count == 5
                    ? FaceLandmarkSet(
                        eyeA: candidate.landmarks[0],
                        eyeB: candidate.landmarks[1],
                        nose: candidate.landmarks[2],
                        mouthA: candidate.landmarks[3],
                        mouthB: candidate.landmarks[4]
                    )
                    : nil
            )
        }
    }

    // MARK: - Letterbox and tensor

    /// Draws `image` scaled to fit a `canvasSize`² canvas (aspect preserved,
    /// top-left anchored, black padding), resampled to `tensorSide`², as a
    /// (1,3,S,S) float32 tensor in RGB order normalized to [-1, 1] —
    /// matching InsightFace's `blobFromImage` preprocessing.
    static func letterboxTensor(
        _ image: CGImage,
        canvasSize: Int,
        tensorSide: Int
    ) throws -> MLMultiArray {
        guard let canvas = FaceAligner.RGBContext(width: canvasSize, height: canvasSize) else {
            throw ToolkitError.commandFailed("Could not create the detector canvas.")
        }
        let scale = Double(canvasSize) / Double(max(image.width, image.height))
        let drawWidth = (Double(image.width) * scale).rounded()
        let drawHeight = (Double(image.height) * scale).rounded()
        // CGContext space is bottom-left; anchoring the draw at the top of
        // the pixel buffer puts padding at the bottom/right.
        canvas.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
        canvas.interpolationQuality = .high
        canvas.draw(image, in: CGRect(
            x: 0,
            y: Double(canvasSize) - drawHeight,
            width: drawWidth,
            height: drawHeight
        ))

        let source: CGContext
        if tensorSide != canvasSize {
            guard let down = FaceAligner.RGBContext(width: tensorSide, height: tensorSide),
                  let rendered = canvas.makeImage() else {
                throw ToolkitError.commandFailed("Could not resample the detector canvas.")
            }
            down.interpolationQuality = .high
            down.draw(rendered, in: CGRect(x: 0, y: 0, width: tensorSide, height: tensorSide))
            source = down
        } else {
            source = canvas
        }
        guard let data = source.data else {
            throw ToolkitError.commandFailed("Could not rasterize the detector input.")
        }

        let array = try MLMultiArray(
            shape: [1, 3, NSNumber(value: tensorSide), NSNumber(value: tensorSide)],
            dataType: .float32
        )
        let plane = tensorSide * tensorSide
        let bytes = data.bindMemory(to: UInt8.self, capacity: plane * 4)
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: plane * 3)
        // premultipliedLast RGBA; the detector takes R,G,B planes.
        for index in 0..<plane {
            let byte = index * 4
            pointer[index] = (Float(bytes[byte]) - 127.5) / 127.5
            pointer[plane + index] = (Float(bytes[byte + 1]) - 127.5) / 127.5
            pointer[plane * 2 + index] = (Float(bytes[byte + 2]) - 127.5) / 127.5
        }
        return array
    }

    // MARK: - Output decoding

    /// One decoded detection in tensor pixel space (top-left origin).
    struct Candidate: Sendable {
        var score: Float
        var box: CGRect
        var landmarks: [CGPoint]

        func scaled(by factor: Double) -> Candidate {
            Candidate(
                score: score,
                box: CGRect(
                    x: box.origin.x * factor,
                    y: box.origin.y * factor,
                    width: box.width * factor,
                    height: box.height * factor
                ),
                landmarks: landmarks.map { CGPoint(x: $0.x * factor, y: $0.y * factor) }
            )
        }
    }

    /// Decodes one prediction's outputs into candidates in tensor pixels.
    /// Outputs are classified by channel count — 1 = scores, 4 = box
    /// distances, 10 = landmark offsets — then ordered by anchor count so
    /// index 0 is stride 8. This survives whatever names the converter
    /// gives the tensors.
    static func decode(
        outputs: MLFeatureProvider,
        tensorSide: Int,
        scoreThreshold: Float
    ) -> [Candidate] {
        var scoreArrays: [[Float]] = []
        var boxArrays: [[Float]] = []
        var kpsArrays: [[Float]] = []
        for name in outputs.featureNames {
            guard let array = outputs.featureValue(for: name)?.multiArrayValue,
                  array.shape.count >= 2 else { continue }
            let channels = array.shape.last!.intValue
            let values = flatten(array)
            switch channels {
            case 1: scoreArrays.append(values)
            case 4: boxArrays.append(values)
            case 10: kpsArrays.append(values)
            default: continue
            }
        }
        return decodeArrays(
            scores: scoreArrays,
            boxes: boxArrays,
            kpss: kpsArrays,
            tensorSide: tensorSide,
            scoreThreshold: scoreThreshold
        )
    }

    /// The pure decode step over already-flattened output groups — kept
    /// separate so tests can exercise anchor math without CoreML.
    static func decodeArrays(
        scores scoreArrays: [[Float]],
        boxes boxArrays: [[Float]],
        kpss kpsArrays: [[Float]],
        tensorSide: Int,
        scoreThreshold: Float,
        strides: [Int] = SCRFDDetector.strides,
        anchorsPerCell: Int = SCRFDDetector.anchorsPerCell
    ) -> [Candidate] {
        let hasKps = kpsArrays.count == strides.count
        guard scoreArrays.count == strides.count, boxArrays.count == strides.count else {
            return []
        }
        // Most anchors = smallest stride. Each group must match its
        // expected anchor count or the layout assumption is wrong.
        let order = strideOrder(
            counts: scoreArrays.map(\.count),
            boxCounts: boxArrays.map(\.count),
            kpsCounts: hasKps ? kpsArrays.map(\.count) : nil,
            tensorSide: tensorSide,
            strides: strides,
            anchorsPerCell: anchorsPerCell
        )
        guard let order else { return [] }

        // The shipped graph emits probabilities, but a raw-logit export
        // would land outside [0, 1] — sigmoid only when needed.
        let needsSigmoid = order.scores.contains { index in
            let values = scoreArrays[index]
            return values.contains { $0 < -0.05 || $0 > 1.05 }
        }

        var candidates: [Candidate] = []
        for position in 0..<strides.count {
            let stride = Double(strides[position])
            let mapSide = Int((Double(tensorSide) / stride).rounded())
            let anchorCount = mapSide * mapSide * anchorsPerCell
            let scores = scoreArrays[order.scores[position]]
            let boxes = boxArrays[order.boxes[position]]
            let kpss = hasKps ? kpsArrays[order.kps![position]] : nil
            guard scores.count == anchorCount,
                  boxes.count == anchorCount * 4,
                  kpss == nil || kpss!.count == anchorCount * 10 else { continue }

            for anchor in 0..<anchorCount {
                var score = scores[anchor]
                if needsSigmoid { score = 1 / (1 + exp(-score)) }
                guard score >= scoreThreshold else { continue }

                // Anchor index = (row * mapSide + col) * anchorsPerCell + k.
                let cell = anchor / anchorsPerCell
                let cx = (Double(cell % mapSide) + 0.5) * stride
                let cy = (Double(cell / mapSide) + 0.5) * stride

                let base = anchor * 4
                let left = boxes[base] * Float(stride)
                let top = boxes[base + 1] * Float(stride)
                let right = boxes[base + 2] * Float(stride)
                let bottom = boxes[base + 3] * Float(stride)
                let box = CGRect(
                    x: cx - Double(left),
                    y: cy - Double(top),
                    width: Double(left + right),
                    height: Double(top + bottom)
                )

                var landmarks: [CGPoint] = []
                if let kpss {
                    landmarks.reserveCapacity(5)
                    let kpsBase = anchor * 10
                    for point in 0..<5 {
                        landmarks.append(CGPoint(
                            x: cx + Double(kpss[kpsBase + point * 2]) * stride,
                            y: cy + Double(kpss[kpsBase + point * 2 + 1]) * stride
                        ))
                    }
                }
                candidates.append(Candidate(score: score, box: box, landmarks: landmarks))
            }
        }
        return candidates
    }

    /// Maps each output group onto stride order by anchor count, or nil if
    /// the shapes do not line up with the expected FPN layout.
    private static func strideOrder(
        counts: [Int],
        boxCounts: [Int],
        kpsCounts: [Int]?,
        tensorSide: Int,
        strides: [Int],
        anchorsPerCell: Int
    ) -> (scores: [Int], boxes: [Int], kps: [Int]?)? {
        func order(_ counts: [Int], channels: Int) -> [Int]? {
            var result: [Int] = []
            var used = Set<Int>()
            for stride in strides {
                let mapSide = Int((Double(tensorSide) / Double(stride)).rounded())
                let expected = mapSide * mapSide * anchorsPerCell * channels
                guard let index = counts.indices.first(where: { !used.contains($0) && counts[$0] == expected }) else {
                    return nil
                }
                used.insert(index)
                result.append(index)
            }
            return result
        }
        guard let scores = order(counts, channels: 1),
              let boxes = order(boxCounts, channels: 4) else { return nil }
        let kps = kpsCounts.flatMap { order($0, channels: 10) }
        if kpsCounts != nil && kps == nil { return nil }
        return (scores, boxes, kps)
    }

    /// Greedy NMS: highest score wins, IoU over the threshold suppresses.
    static func nonMaxSuppressed(_ candidates: [Candidate], iouThreshold: Float) -> [Candidate] {
        var kept: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            var suppressed = false
            for other in kept {
                let intersection = candidate.box.intersection(other.box)
                guard !intersection.isNull else { continue }
                let overlap = intersection.width * intersection.height
                let union = candidate.box.width * candidate.box.height
                    + other.box.width * other.box.height - overlap
                if union > 0, Float(overlap / union) > iouThreshold {
                    suppressed = true
                    break
                }
            }
            if !suppressed { kept.append(candidate) }
        }
        return kept
    }

    /// Flattens a multi-array to float32, using the raw buffer when the
    /// layout is contiguous (the common case for model outputs).
    static func flatten(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        // Contiguity check: strides must be the row-major product.
        var contiguous = true
        var expected = 1
        for index in stride(from: array.shape.count - 1, through: 0, by: -1) {
            if array.strides[index].intValue != expected {
                contiguous = false
                break
            }
            expected *= array.shape[index].intValue
        }
        if contiguous {
            switch array.dataType {
            case .float32:
                let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count)
                return Array(UnsafeBufferPointer(start: pointer, count: count))
            case .float16:
                let pointer = array.dataPointer.bindMemory(to: UInt16.self, capacity: count)
                return (0..<count).map { Float(Float16(bitPattern: pointer[$0])) }
            default:
                break
            }
        }
        return (0..<count).map { Float(array[$0].doubleValue) }
    }
}

/// Reads sampled frames out of a video file for MED/HIGH passes. Each clip
/// gets its own sampler inside a scan worker; frames are decoded serially
/// with `AVAssetImageGenerator` — no GPU pinning, media stays read-only.
public final class FaceVideoSampler {
    private let generator: AVAssetImageGenerator
    /// Native clip dimensions with the track transform applied — the frame
    /// space boxes and the min-face floor are measured in.
    public let pixelSize: CGSize
    public let duration: TimeInterval

    public init?(url: URL, maximumPixelSize: Int) {
        let asset = AVURLAsset(url: url)
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(
            width: maximumPixelSize,
            height: maximumPixelSize
        )
        var pixelSize = CGSize(width: 0, height: 0)
        if let track = asset.tracks(withMediaType: .video).first {
            let natural = track.naturalSize.applying(track.preferredTransform)
            pixelSize = CGSize(width: abs(natural.width), height: abs(natural.height))
        }
        self.generator = generator
        self.duration = duration
        self.pixelSize = pixelSize
    }

    /// Evenly spaced sample times: first frame at half a stride, then every
    /// `stride` seconds, capped at `maxFrames`. A clip shorter than one
    /// stride contributes a single mid-clip frame.
    public static func sampleTimes(
        duration: TimeInterval,
        stride: TimeInterval,
        maxFrames: Int
    ) -> [TimeInterval] {
        guard duration > 0, stride > 0, maxFrames > 0 else { return [] }
        var times: [TimeInterval] = []
        var time = min(stride / 2, duration / 2)
        while time < duration && times.count < maxFrames {
            times.append(time)
            time += stride
        }
        return times
    }

    /// The frame nearest `time`, or nil when the decoder cannot produce it.
    public func frame(at time: TimeInterval) -> CGImage? {
        try? generator.copyCGImage(
            at: CMTime(seconds: time, preferredTimescale: 600),
            actualTime: nil
        )
    }
}
