import CoreGraphics
import Foundation
import XCTest
@testable import CameraToolkitCore

/// Parity with the reference implementation. The sidecar *is* `insightface`,
/// so what these tests guard is everything around it: the bytes we hand it
/// (channel order, orientation, lossless fixtures), the box conversion, and
/// the install contract. The golden vector was produced by running the
/// original `w600k_r50.onnx` through onnxruntime on the same synthetic
/// pattern with InsightFace's own preprocessing (RGB, (x − 127.5) / 127.5).
final class FaceSidecarParityTests: XCTestCase {
    /// Cosine of the sidecar's embedding of `FaceSidecarFixture.pattern`
    /// against the ONNX reference. FP16 CoreML execution costs a little.
    private static let minimumParityCosine: Float = 0.98

    private func installedPool() throws -> FaceSidecarPool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let installation = FaceSidecarInstallation(applicationSupport: support)
        guard installation.isInstalled else {
            throw XCTSkip("Face sidecar not installed — run \(FaceSidecarInstallation.setupCommand) once")
        }
        return try FaceSidecarPool(installation: installation, processes: 1)
    }

    // MARK: - Reference parity (needs the sidecar installed)

    func testSidecarEmbeddingMatchesONNXReference() throws {
        let pool = try installedPool()
        defer { pool.shutdown() }
        let image = try XCTUnwrap(FaceSidecarFixture.pattern())
        let result = try pool.embedCrop(image)
        XCTAssertEqual(result.embedding.count, 512)
        var norm: Float = 0
        for value in result.embedding { norm += value * value }
        XCTAssertEqual(norm, 1, accuracy: 0.01)
        XCTAssertGreaterThan(result.quality, 0)
        let cosine = FaceEmbeddingMath.cosine(result.embedding, FaceSidecarFixture.referenceEmbedding)
        XCTAssertGreaterThan(
            cosine, Self.minimumParityCosine,
            "sidecar diverged from the ONNX reference (cosine \(cosine)) — channel order or preprocessing drifted"
        )
        // The same pattern with red and blue swapped must land measurably
        // elsewhere: the check has teeth.
        let swapped = try XCTUnwrap(FaceSidecarFixture.pattern(swapRedBlue: true))
        let swappedCosine = FaceEmbeddingMath.cosine(try pool.embedCrop(swapped).embedding, FaceSidecarFixture.referenceEmbedding)
        XCTAssertLessThan(swappedCosine, cosine)
    }

    func testSidecarAnalyzeOnFaceFreeImageReturnsNoFaces() throws {
        let pool = try installedPool()
        defer { pool.shutdown() }
        let image = try XCTUnwrap(FaceSidecarFixture.pattern(side: 640))
        let faces = try pool.analyze(image, options: FaceScanOptions(mode: .med))
        XCTAssertTrue(faces.isEmpty, "a flat synthetic gradient must not detect as a face")
        XCTAssertTrue(pool.displayName.contains("insightface"))
    }

    func testSidecarPoolServesConcurrentCallers() throws {
        let pool = try installedPool()
        defer { pool.shutdown() }
        let image = try XCTUnwrap(FaceSidecarFixture.pattern(side: 320))
        let group = DispatchGroup()
        let lock = NSLock()
        var failures: [String] = []
        for _ in 0..<6 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    _ = try pool.analyze(image, options: FaceScanOptions(mode: .low))
                } catch {
                    lock.lock()
                    failures.append(String(describing: error))
                    lock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success)
        XCTAssertEqual(failures, [])
    }

    // MARK: - Pure conversions (always run)

    func testFacesFromResponseConvertsBoxesToBottomLeftNormalized() {
        let response: [String: Any] = [
            "width": 2000.0,
            "height": 1000.0,
            "faces": [[
                "box": [200.0, 100.0, 600.0, 700.0],
                "det_score": 0.91,
                "embedding": [Double](repeating: 1.0 / 512.0.squareRoot(), count: 512),
                "norm": 18.5,
            ] as [String: Any]],
        ]
        let faces = FaceSidecarPool.faces(from: response)
        XCTAssertEqual(faces.count, 1)
        let face = try! XCTUnwrap(faces.first)
        XCTAssertEqual(face.box.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(face.box.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(face.box.height, 0.6, accuracy: 1e-9)
        // y2 = 700 of 1000 → bottom-left origin y = 1 − 0.7
        XCTAssertEqual(face.box.y, 0.3, accuracy: 1e-9)
        XCTAssertEqual(face.detScore, 0.91)
        XCTAssertEqual(face.quality, 18.5)
        XCTAssertEqual(face.facePixels, 400)
        XCTAssertEqual(face.embedding.count, 512)
    }

    func testFacesFromResponseClampsAndDropsDegenerateBoxes() {
        let response: [String: Any] = [
            "width": 100.0,
            "height": 100.0,
            "faces": [
                ["box": [-20.0, -10.0, 50.0, 40.0], "det_score": 0.8, "embedding": [1.0], "norm": 1.0] as [String: Any],
                ["box": [30.0, 30.0, 30.0, 60.0], "det_score": 0.8, "embedding": [1.0], "norm": 1.0] as [String: Any],
                ["box": [30.0, 30.0, 60.0, 60.0], "det_score": 0.8, "embedding": [], "norm": 1.0] as [String: Any],
            ],
        ]
        let faces = FaceSidecarPool.faces(from: response)
        XCTAssertEqual(faces.count, 1)
        XCTAssertEqual(faces[0].box.x, 0)
        XCTAssertEqual(faces[0].box.width, 0.5)
        XCTAssertEqual(faces[0].box.y, 0.6, accuracy: 1e-9)
    }

    func testInstallationReportsMissingEnvironment() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let installation = FaceSidecarInstallation(applicationSupport: empty)
        XCTAssertFalse(installation.isInstalled)
        XCTAssertEqual(installation.root.lastPathComponent, "face-sidecar")
        XCTAssertNotNil(FaceSidecarInstallation.scriptURL, "the sidecar script must ship in the Core resource bundle")
    }

    func testEngineIdentifierIsStampedOnNewRecords() {
        let face = FaceRecord(photoID: "p", box: NormalizedFaceBox(x: 0, y: 0, width: 0.1, height: 0.1), detScore: 0.9)
        XCTAssertEqual(face.model, FaceEngine.identifier)
        let photo = FacePhotoRecord(pathKey: "p", path: "/p", fileName: "p", byteCount: 1, modifiedAt: Date(), scanGrade: .med, engine: FaceEngine.identifier)
        XCTAssertTrue(photo.covers(.med))
        XCTAssertTrue(photo.covers(.low))
        XCTAssertFalse(photo.covers(.high))
        let stale = FacePhotoRecord(pathKey: "p", path: "/p", fileName: "p", byteCount: 1, modifiedAt: Date(), scanGrade: .xhigh, engine: "")
        XCTAssertFalse(stale.covers(.low), "rows from another engine never satisfy the skip rule")
    }
}

/// A deterministic 112×112 RGB pattern — red ramps left→right, green
/// top→bottom, blue along the diagonal — and its reference embedding.
enum FaceSidecarFixture {
    /// Top-left origin, RGBA8, no premultiplication ambiguity (alpha 255).
    static func pattern(side: Int = 112, swapRedBlue: Bool = false) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                let r = UInt8(x * 255 / (side - 1))
                let g = UInt8(y * 255 / (side - 1))
                let b = UInt8((x + y) * 255 / (2 * (side - 1)))
                bytes[offset] = swapRedBlue ? b : r
                bytes[offset + 1] = g
                bytes[offset + 2] = swapRedBlue ? r : b
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// `w600k_r50.onnx` on `pattern()` via onnxruntime, InsightFace preprocessing.
    static let referenceEmbedding: [Float] = [
        -0.035946, -0.077247, -0.020260, -0.028440, 0.025716, -0.023233, 0.040251, -0.083669,
        -0.039145, 0.031309, -0.014254, 0.011167, -0.002071, -0.058298, 0.056355, -0.056321,
        0.013159, -0.055302, -0.068333, 0.010925, 0.012936, 0.033163, 0.022319, -0.023614,
        -0.026716, -0.071396, 0.129772, -0.022476, -0.069014, 0.020269, 0.049526, -0.037092,
        0.019869, 0.070634, 0.032048, 0.036226, 0.014770, 0.021056, 0.055847, 0.037360,
        0.041774, -0.009640, -0.034530, -0.092819, -0.036090, 0.077322, -0.043997, -0.025313,
        0.009454, -0.049845, -0.024533, -0.031192, 0.070836, -0.018981, 0.062149, -0.068433,
        -0.045138, -0.060981, 0.019647, -0.053834, -0.026772, -0.035284, -0.044100, 0.043444,
        -0.034521, 0.024054, -0.000874, 0.002816, 0.039304, -0.096486, 0.009344, -0.022321,
        0.033046, -0.039481, 0.069915, -0.026976, 0.077253, 0.040334, -0.056752, -0.032577,
        -0.021310, -0.041935, 0.014241, 0.075473, 0.026059, -0.015822, 0.041274, -0.018725,
        0.048633, -0.085095, -0.012185, -0.066098, 0.081557, -0.026700, 0.008419, -0.102694,
        0.021200, 0.048318, -0.007712, 0.014435, 0.048478, -0.021948, 0.006573, -0.115750,
        -0.073763, -0.010965, 0.076746, -0.084971, 0.052110, 0.043638, -0.019317, -0.021299,
        -0.074823, -0.023212, -0.028472, -0.047444, 0.008828, 0.074284, 0.081843, 0.013267,
        0.000942, -0.018322, 0.002795, 0.001375, 0.017512, 0.007053, 0.027068, -0.061651,
        -0.019384, 0.041991, -0.002326, -0.019740, 0.021947, 0.018186, 0.049618, -0.027140,
        0.078666, -0.056428, 0.021205, 0.066137, 0.024523, 0.024727, -0.028273, 0.032298,
        -0.073006, -0.048554, 0.027349, 0.017363, -0.014735, 0.068524, 0.008453, 0.033108,
        -0.008577, 0.029061, 0.120107, 0.088815, -0.005957, -0.007131, 0.006245, -0.001586,
        0.050015, -0.093340, 0.000553, -0.007814, -0.026132, 0.051443, -0.008826, 0.062796,
        -0.017879, -0.086769, 0.009306, 0.026097, 0.042148, -0.068419, -0.007975, -0.066780,
        0.053296, 0.011305, 0.022604, 0.015160, 0.020343, -0.055877, 0.006948, -0.012379,
        -0.087517, 0.032902, 0.056635, -0.077280, -0.015539, 0.029756, 0.057852, 0.027653,
        -0.001850, -0.022503, 0.005526, -0.008123, 0.015598, -0.014396, 0.054450, -0.053027,
        0.060310, 0.002858, 0.026456, 0.044529, 0.011460, -0.020855, 0.028749, -0.118651,
        -0.021242, 0.065305, -0.020352, 0.037610, 0.040816, -0.009899, -0.005778, 0.028214,
        -0.061348, -0.064533, 0.004113, 0.041994, 0.044725, 0.020793, -0.035010, -0.079444,
        0.002091, -0.017396, 0.068644, -0.008273, -0.063734, 0.079551, -0.042198, -0.011681,
        -0.026347, -0.036170, -0.016070, -0.002149, 0.008829, 0.070047, 0.062779, -0.010214,
        0.013401, -0.035450, -0.032047, 0.007007, -0.053287, -0.014403, 0.010793, -0.011745,
        -0.014692, -0.018386, 0.017421, 0.028789, 0.003585, 0.045848, 0.091525, 0.061109,
        0.062420, -0.000903, 0.029196, 0.007691, 0.011500, 0.021751, 0.005748, -0.038868,
        0.059965, -0.005835, 0.002075, -0.049234, 0.067573, 0.011958, 0.019613, 0.018259,
        0.039352, -0.015380, -0.017915, -0.031873, -0.038666, 0.001639, 0.091872, 0.062715,
        -0.042641, -0.044906, 0.016967, 0.070087, -0.018740, -0.022173, -0.034663, 0.007096,
        0.035850, 0.037678, -0.013083, -0.011586, 0.006076, 0.044816, 0.007709, -0.019012,
        0.005018, -0.025391, 0.080608, 0.059936, 0.070137, 0.028726, 0.028528, -0.034610,
        0.038949, -0.027706, 0.033347, -0.053901, 0.013615, -0.049036, 0.014907, 0.022795,
        -0.002894, 0.008572, 0.057233, 0.013164, 0.012085, -0.038242, 0.058570, 0.087465,
        0.063242, -0.063169, -0.039998, 0.058085, 0.008494, 0.013785, 0.053432, -0.067364,
        0.019478, -0.017478, 0.024454, -0.034404, 0.052351, -0.026861, -0.056424, 0.032580,
        -0.029945, -0.077480, 0.037611, -0.053488, 0.086638, -0.011092, -0.008861, 0.018557,
        -0.061805, 0.016412, 0.107798, -0.070907, -0.021733, -0.034633, 0.011757, -0.084100,
        0.036329, -0.026247, 0.030259, 0.013159, 0.011940, -0.085189, -0.030811, -0.041874,
        -0.044326, 0.007693, -0.044718, -0.033825, -0.057400, 0.008716, 0.026038, -0.029936,
        -0.028048, 0.072193, 0.041382, -0.053885, 0.010006, 0.007464, 0.067207, -0.066320,
        -0.033409, -0.002828, 0.041716, 0.061695, 0.051262, 0.037265, -0.035230, 0.021494,
        0.001727, 0.041556, -0.029934, -0.009033, -0.032134, -0.038310, 0.010458, -0.005485,
        0.064094, 0.059803, -0.021444, -0.022280, -0.015848, -0.054987, -0.037992, -0.016296,
        -0.075676, -0.047301, 0.003567, -0.016157, 0.074703, -0.063148, 0.054805, -0.022775,
        0.022306, 0.103876, -0.062374, 0.062045, -0.056955, 0.009254, -0.069121, -0.021147,
        -0.014605, 0.077207, 0.040464, 0.011890, 0.077672, 0.009354, 0.012551, 0.023560,
        -0.022339, -0.060302, 0.055355, 0.042306, -0.010607, -0.033379, -0.014938, 0.041342,
        0.060351, 0.090601, -0.017345, 0.063068, -0.018831, 0.029680, -0.050854, 0.051281,
        0.018565, 0.013471, 0.041450, -0.032412, -0.062977, -0.007294, 0.027497, -0.017724,
        -0.064628, 0.044298, -0.011322, 0.041445, 0.024938, -0.006247, 0.039223, -0.015068,
        0.009096, -0.012294, -0.071838, 0.034798, -0.067773, -0.030629, -0.014853, -0.006337,
        0.042695, -0.035035, 0.019667, -0.003585, 0.009129, -0.012631, -0.047300, -0.062159,
        -0.000567, 0.023563, -0.042070, -0.015765, 0.000874, 0.024375, 0.012743, -0.033814,
        -0.117256, -0.044847, -0.045509, 0.012366, -0.083129, 0.011012, 0.065620, 0.027642,
        -0.025028, 0.007644, -0.039948, 0.012524, 0.023258, 0.044088, -0.005315, -0.007663,
        0.002355, 0.048340, -0.017963, -0.129713, 0.009194, -0.069887, -0.007135, -0.018939,
        -0.031856, -0.036939, 0.023608, -0.101608, 0.042540, -0.023689, -0.060466, -0.012942,
    ]
}
