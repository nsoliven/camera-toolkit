import CoreGraphics
import Foundation

/// The pet engine: dogs found by RT-DETRv2 and described by DINOv2, both
/// run by `transformers` inside the pet sidecar (`pet_sidecar.py`). It is a
/// separate engine with its own embedding space, so its rows live in the
/// pet index (`PetIndexDatabase`) and never meet a face row. See
/// docs/PET-PIPELINE.md.
public enum PetFaceEngine {
    /// Stamped on every pet row and every pet-scanned photo; must equal
    /// `ENGINE` in `pet_sidecar.py`. Changing a model, a revision, or the
    /// crop rule means changing it, so old vectors are re-read rather than
    /// mixed with new ones.
    public static let identifier = "pets/rtdetr_v2_r50vd+dinov2-large-boxpad"
    public static let displayName = "Pets: RT-DETRv2 R50 (dogs) + DINOv2 large"
}

/// Where the pet sidecar lives on this Mac and whether it is ready.
public struct PetSidecarInstallation: Equatable, Sendable {
    /// The one-time install command the UI names.
    public static let setupCommand = "scripts/setup-pet-sidecar.sh"

    /// `…/CameraToolkit/pet-sidecar`: the venv, the models, the ready line.
    public var root: URL

    public init(applicationSupport: URL) {
        root = applicationSupport.appendingPathComponent("CameraToolkit/pet-sidecar", isDirectory: true)
    }

    public init(root: URL) {
        self.root = root
    }

    public var pythonURL: URL { root.appendingPathComponent("venv/bin/python") }
    /// Written by the setup script only after the models downloaded and
    /// ran once, so a half-finished install never looks ready.
    public var readyMarkerURL: URL { root.appendingPathComponent("ready.json") }

    public var isInstalled: Bool {
        isInstalled(scriptURL: Self.scriptURL)
    }

    public func isInstalled(scriptURL: URL?) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path), scriptURL != nil,
              let size = (try? FileManager.default.attributesOfItem(atPath: readyMarkerURL.path))?[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    /// The bundled sidecar script (`Contents/Resources` of the packaged app).
    public static var scriptURL: URL? {
        CoreResources.petSidecarScript.url
    }

    public static let notInstalledMessage =
        "The pet engine is not installed yet. Run \(setupCommand) once on this Mac, then scan again."
}

/// The production pet analyzer: one sidecar process (both models sit on
/// the Metal device; a second process would only fight it for memory).
/// `analyze` is safe to call from many threads — calls take turns.
public final class PetSidecarPool: FaceAnalyzing, @unchecked Sendable {
    public let displayName: String
    private var process: FaceSidecarProcess?
    private let lock = NSLock()

    public init(installation: PetSidecarInstallation, startupTimeout: TimeInterval = 300) throws {
        guard let script = PetSidecarInstallation.scriptURL else {
            throw FaceIndexError.engineFailed("The pet sidecar script is missing from the app bundle.")
        }
        guard installation.isInstalled(scriptURL: script) else {
            throw FaceIndexError.engineNotInstalled(PetSidecarInstallation.notInstalledMessage)
        }
        let process = try FaceSidecarProcess(
            pythonURL: installation.pythonURL,
            scriptURL: script,
            root: installation.root,
            name: "pet sidecar",
            startupTimeout: startupTimeout
        )
        let engine = process.readyObject["engine"] as? String ?? ""
        guard engine == PetFaceEngine.identifier else {
            process.terminate()
            throw FaceIndexError.engineFailed(
                "The pet sidecar reports engine “\(engine)”, but this app expects “\(PetFaceEngine.identifier)”. Run \(PetSidecarInstallation.setupCommand) again."
            )
        }
        self.process = process
        let device = (process.readyObject["device"] as? String ?? "cpu").uppercased()
        let torch = process.readyObject["torch"] as? String ?? "?"
        displayName = "\(PetFaceEngine.displayName) · torch \(torch) \(device)"
    }

    public static func open(applicationSupport: URL) throws -> PetSidecarPool {
        try PetSidecarPool(installation: PetSidecarInstallation(applicationSupport: applicationSupport))
    }

    public func shutdown() {
        lock.lock()
        let running = process
        process = nil
        lock.unlock()
        running?.terminate()
    }

    deinit {
        shutdown()
    }

    public func analyze(_ image: CGImage, options: FaceScanOptions) throws -> [AnalyzedFace] {
        guard let jpeg = FaceImageEncoding.jpegData(image, quality: 0.95) else {
            throw FaceIndexError.engineFailed("Could not encode an image for the pet sidecar.")
        }
        let response = try request([
            "op": "analyze",
            "image_b64": jpeg.base64EncodedString(),
            "det_thresh": options.detScoreThreshold,
            "flip_tta": options.flipTTA,
        ])
        // Same box conversion as faces: the one geometry Swift does.
        return FaceSidecarPool.faces(from: response)
    }

    /// Embeds an already-cut crop — the parity test's path.
    public func embedCrop(_ image: CGImage) throws -> (embedding: [Float], quality: Double) {
        guard let png = FaceImageEncoding.pngData(image) else {
            throw FaceIndexError.engineFailed("Could not encode a crop for the pet sidecar.")
        }
        let response = try request(["op": "embed_crop", "image_b64": png.base64EncodedString()])
        return (FaceSidecarPool.floats(response["embedding"]), response["norm"] as? Double ?? 0)
    }

    private func request(_ body: [String: Any]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard let process else {
            throw FaceIndexError.engineFailed("The pet sidecar was shut down.")
        }
        return try process.request(body)
    }
}

extension FaceScanOptions {
    /// A pet pass at `mode`: the face pass's burst sampling, video
    /// sampling, and decode bound, with pet floors and thresholds. The
    /// thresholds are for DINOv2-large cosine on the padded dog box and
    /// were measured on a hand-labelled library plus public look-alike
    /// breeds — see docs/PET-PIPELINE.md. Mirror averaging stays off on
    /// every grade: it measured no better for dogs.
    public static func pets(mode: FaceScanGrade = .med, fast: Bool = true) -> FaceScanOptions {
        FaceScanOptions(
            mode: mode,
            fast: fast,
            minimumFacePixels: PetScanDefaults.minimumDogPixels(for: mode),
            matchThreshold: PetScanDefaults.matchThreshold,
            clusterThreshold: PetScanDefaults.clusterThreshold,
            detScoreThreshold: PetScanDefaults.detScoreThreshold,
            groupingMinDetScore: PetScanDefaults.groupingMinDetScore,
            groupingMinFacePixels: PetScanDefaults.groupingMinDogPixels,
            minimumGroupFaces: 3,
            videoDuplicateCosine: PetScanDefaults.videoDuplicateCosine,
            flipTTA: false,
            uprightRawDetection: true
        )
    }
}

/// Pet scan defaults in one place so the doc and the tests can name them.
public enum PetScanDefaults {
    /// Detector score floor: dogs below it are not stored.
    public static let detScoreThreshold: Float = 0.5
    /// Below this a dog is stored but never seeds or joins a group.
    public static let groupingMinDetScore: Float = 0.7
    /// Mean cosine to a group's members to join it (average linkage).
    public static let clusterThreshold: Float = 0.50
    /// Best template cosine to file a dog on a named pet's "looks like" row.
    public static let matchThreshold: Float = 0.60
    /// Two video-frame detections this alike are one appearance.
    public static let videoDuplicateCosine: Float = 0.95
    /// Smallest dog (shorter box side, decoded pixels) that may be grouped.
    public static let groupingMinDogPixels: Double = 96

    /// Smallest dog stored at all, in the photo's native pixels.
    public static func minimumDogPixels(for mode: FaceScanGrade) -> Double {
        switch mode {
        case .none, .low: 128
        case .med: 96
        case .high, .xhigh: 64
        }
    }
}
