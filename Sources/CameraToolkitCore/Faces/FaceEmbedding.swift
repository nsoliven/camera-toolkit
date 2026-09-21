import CoreML
import CoreGraphics
import Foundation

/// Where the converted ArcFace model lives on this Mac. The model is a
/// generated artifact produced once per machine by
/// `scripts/convert-arcface.sh`; it is never committed to the repository and
/// never written anywhere but the app's own support folder.
public enum FaceModelCatalog {
    /// The single identity model. The embedding space dies if the model is
    /// swapped, so the name is fixed.
    public static let modelName = "w600k_r50"
    public static let modelFileName = "w600k_r50.mlpackage"

    public static func modelsDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("CameraToolkit/Models", isDirectory: true)
    }

    public static func modelURL(applicationSupport: URL) -> URL {
        modelsDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent(modelFileName)
    }

    public static func isModelInstalled(applicationSupport: URL) -> Bool {
        FileManager.default.fileExists(atPath: modelURL(applicationSupport: applicationSupport).path)
    }

    /// The embedder, or nil with a clear next step when the model package is
    /// absent. The package is compiled once per process into a temporary
    /// `.mlmodelc` — CoreML does not load mlpackages directly.
    public static func loadEmbedder(applicationSupport: URL) async throws -> ArcFaceEmbedder? {
        let url = modelURL(applicationSupport: applicationSupport)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try await ArcFaceEmbedder(modelURL: url)
    }
}

/// Turns an aligned 112×112 face image into one 512-d embedding.
public protocol FaceEmbeddingProviding: Sendable {
    func embed(_ image: CGImage) throws -> [Float]
}

/// The frozen InsightFace ArcFace R50 (`w600k_r50`) as a converted CoreML
/// package. Input is a (1,3,112,112) float32 tensor in BGR order normalized
/// to [-1, 1] — exactly what the ONNX graph expects.
public final class ArcFaceEmbedder: FaceEmbeddingProviding, @unchecked Sendable {
    private let model: MLModel
    private let inputName: String
    private let outputName: String

    public init(modelURL: URL) async throws {
        // A .mlpackage must be compiled before CoreML loads it. The compiled
        // model lands in a CoreML-managed location and is reused while the
        // package is unchanged.
        let compiledURL = try await MLModel.compileModel(at: modelURL)
        let model = try MLModel(contentsOf: compiledURL)
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        guard let inputName = inputs.keys.sorted().first,
              let outputName = outputs.keys.sorted().first else {
            throw ToolkitError.commandFailed("The face model has no tensor input or output.")
        }
        self.model = model
        self.inputName = inputName
        self.outputName = outputName
    }

    public var embeddingSize: Int { 512 }

    public func embed(_ image: CGImage) throws -> [Float] {
        let input = try Self.inputTensor(for: image)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(multiArray: input),
        ])
        let output = try model.prediction(from: provider)
        guard let multiArray = output.featureValue(for: outputName)?.multiArrayValue else {
            throw ToolkitError.commandFailed("The face model produced no embedding output.")
        }
        let count = multiArray.count
        var embedding = [Float](repeating: 0, count: count)
        let pointer = multiArray.dataPointer.bindMemory(to: Float.self, capacity: count)
        // Float16 outputs are read through the MLMultiArray double accessor.
        switch multiArray.dataType {
        case .float32:
            for index in 0..<count { embedding[index] = pointer[index] }
        default:
            for index in 0..<count { embedding[index] = Float(multiArray[index].doubleValue) }
        }
        return FaceEmbeddingMath.l2Normalized(embedding)
    }

    /// BGR tensor normalized to [-1, 1], matching InsightFace's cv2 pipeline.
    static func inputTensor(for image: CGImage) throws -> MLMultiArray {
        let size = FaceAligner.outputSize
        guard let context = FaceAligner.RGBContext(width: size, height: size) else {
            throw ToolkitError.commandFailed("Could not create a pixel buffer for a face crop.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data else {
            throw ToolkitError.commandFailed("Could not rasterize a face crop.")
        }

        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        let plane = size * size
        let bytes = data.bindMemory(to: UInt8.self, capacity: plane * 4)
        // premultipliedLast RGBA bytes; the model wants B,G,R channels.
        for index in 0..<plane {
            let byte = index * 4
            let b = Float(bytes[byte + 2])
            let g = Float(bytes[byte + 1])
            let r = Float(bytes[byte])
            array[index] = NSNumber(value: (b - 127.5) / 127.5)
            array[plane + index] = NSNumber(value: (g - 127.5) / 127.5)
            array[plane * 2 + index] = NSNumber(value: (r - 127.5) / 127.5)
        }
        return array
    }
}

/// Vector helpers shared by matching, clustering, and tests.
public enum FaceEmbeddingMath {
    public static func l2Normalized(_ vector: [Float]) -> [Float] {
        var sum: Float = 0
        for value in vector { sum += value * value }
        guard sum > 0 else { return vector }
        let norm = sum.squareRoot()
        return vector.map { $0 / norm }
    }

    /// Cosine similarity; for L2-normalized inputs this is the dot product.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return -1 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Component-wise mean of the vectors, L2-normalized — a cluster or
    /// template centroid.
    public static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        var mean = [Float](repeating: 0, count: first.count)
        var used = 0
        for vector in vectors where vector.count == first.count {
            for index in vector.indices { mean[index] += vector[index] }
            used += 1
        }
        guard used > 0 else { return nil }
        return l2Normalized(mean.map { $0 / Float(used) })
    }
}
