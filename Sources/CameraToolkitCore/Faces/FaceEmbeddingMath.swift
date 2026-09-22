import Foundation

/// Vector helpers shared by matching, clustering, and tests. Embeddings
/// arrive L2-normalized from the sidecar, so cosine is a dot product.
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
