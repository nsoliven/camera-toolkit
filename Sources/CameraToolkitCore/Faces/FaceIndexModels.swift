import Foundation

/// How thoroughly a photo has been searched for faces. Grades are ordered —
/// a photo scanned at a grade never needs reprocessing at a lower or equal
/// grade, and a higher grade may add new faces without disturbing confirmed
/// ones.
public enum FaceScanGrade: String, Codable, CaseIterable, Sendable, Comparable {
    case none
    case low
    case med
    case high
    case xhigh

    private var rank: Int {
        switch self {
        case .none: 0
        case .low: 1
        case .med: 2
        case .high: 3
        case .xhigh: 4
        }
    }

    public static func < (lhs: FaceScanGrade, rhs: FaceScanGrade) -> Bool {
        lhs.rank < rhs.rank
    }

    /// True when this grade already covers `other`, so scanning at `other`
    /// may skip the photo.
    public func covers(_ other: FaceScanGrade) -> Bool {
        rank >= other.rank
    }
}

/// What the index currently believes about one detected face.
public enum FaceState: String, Codable, CaseIterable, Sendable {
    /// Embedded and kept, but not matched or grouped yet — the vector is
    /// re-evaluated whenever the roster changes, without re-running ML.
    case cached
    /// Matched against a roster person's templates, awaiting review.
    case proposed
    /// The user said this is that person. Frozen: no scan or re-match may
    /// reclassify it.
    case confirmed
    /// Grouped with an unnamed cluster (a non-roster person row).
    case other
}

/// A face bounding box in normalized image coordinates (0–1, bottom-left
/// origin, matching Apple Vision's convention).
public struct NormalizedFaceBox: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Intersection-over-union with another normalized box — used to avoid
    /// inserting a fresh detection on top of a confirmed face.
    public func iou(with other: NormalizedFaceBox) -> Double {
        let intersection = rect.intersection(other.rect)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let overlap = intersection.width * intersection.height
        let union = width * height + other.width * other.height - overlap
        guard union > 0 else { return 0 }
        return overlap / union
    }
}

/// One scanned photo's face index row. The photo identity is its path plus
/// size and modification time — the same convention `CaptureDateCache` uses —
/// so the pipeline never hashes file bytes just to know it has seen a photo.
public struct FacePhotoRecord: Equatable, Sendable {
    /// `EventStorageLocations.pathKey` of the scanned file — the primary key.
    public var pathKey: String
    public var path: String
    public var fileName: String
    public var byteCount: Int64
    public var modifiedAt: Date
    public var takenAt: Date?
    public var scanGrade: FaceScanGrade
    public var faceCount: Int

    public init(
        pathKey: String,
        path: String,
        fileName: String,
        byteCount: Int64,
        modifiedAt: Date,
        takenAt: Date? = nil,
        scanGrade: FaceScanGrade = .none,
        faceCount: Int = 0
    ) {
        self.pathKey = pathKey
        self.path = path
        self.fileName = fileName
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.takenAt = takenAt
        self.scanGrade = scanGrade
        self.faceCount = faceCount
    }

    /// True when this row describes the same file bytes — same size and
    /// modification time within the same one-second tolerance the app uses
    /// for file identity elsewhere.
    public func describes(path: String, size: Int64, modifiedAt: Date) -> Bool {
        byteCount == size && abs(self.modifiedAt.timeIntervalSince(modifiedAt)) < 1
            && EventStorageLocations.pathKey(path) == pathKey
    }
}

/// One detected face: where it sits in its photo, its embedding, and its
/// current classification state.
public struct FaceRecord: Identifiable, Equatable, Sendable {
    public var id: UUID
    /// `FacePhotoRecord.pathKey` of the owning photo.
    public var photoID: String
    public var personID: UUID?
    public var box: NormalizedFaceBox
    /// Vision's detection confidence (0–1).
    public var detScore: Double
    /// Cosine score of the current assignment, when one exists.
    public var matchScore: Double?
    /// 512-d L2-normalized embedding. Nil only while a detection is being
    /// written before its embed step finished.
    public var embedding: [Float]?
    /// JPEG bytes of the aligned 112×112 crop for review UI.
    public var crop: Data?
    public var model: String
    public var state: FaceState
    public var scanGrade: FaceScanGrade
    /// Path of the photo when it was scanned — for display only; the join
    /// key is `photoID`.
    public var photoPath: String = ""

    public init(
        id: UUID = UUID(),
        photoID: String,
        personID: UUID? = nil,
        box: NormalizedFaceBox,
        detScore: Double,
        matchScore: Double? = nil,
        embedding: [Float]? = nil,
        crop: Data? = nil,
        model: String = FaceModelCatalog.modelName,
        state: FaceState = .cached,
        scanGrade: FaceScanGrade = .low,
        photoPath: String = ""
    ) {
        self.id = id
        self.photoID = photoID
        self.personID = personID
        self.box = box
        self.detScore = detScore
        self.matchScore = matchScore
        self.embedding = embedding
        self.crop = crop
        self.model = model
        self.state = state
        self.scanGrade = scanGrade
        self.photoPath = photoPath
    }

    /// The embedding serialized for SQLite — little-endian float32.
    public var embeddingData: Data? {
        embedding.map { values in
            var data = Data(capacity: values.count * MemoryLayout<Float>.size)
            for value in values {
                var little = value.bitPattern.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            return data
        }
    }

    public static func embedding(from data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: UInt32.self)
            return buffer.map { Float(bitPattern: UInt32(littleEndian: $0)) }
        }
    }
}

/// A named roster person or an unnamed "Other" group. `isRoster == false`
/// marks an auto-created cluster the user may name, merge, or junk.
public struct FacePerson: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isRoster: Bool
    public var faceCount: Int
    /// The face the user pinned as this person's cover thumbnail. Nil means
    /// the highest-confidence detection stands in.
    public var coverFaceID: UUID?

    public init(id: UUID = UUID(), name: String, isRoster: Bool, faceCount: Int = 0, coverFaceID: UUID? = nil) {
        self.id = id
        self.name = name
        self.isRoster = isRoster
        self.faceCount = faceCount
        self.coverFaceID = coverFaceID
    }
}

/// Which detector a scan runs. LOW uses Apple Vision on the Neural Engine;
/// MED and above use the SCRFD detector from the same model pack as the
/// embedder. The identity model never changes per mode.
public enum FaceDetectorKind: String, Codable, Sendable {
    case vision
    case scrfd
}

/// Options for one face scan pass. `mode` is the quality knob; `fast`
/// pins the Mac (max workers). Off keeps a quiet 2-wide pass. Same models.
public struct FaceScanOptions: Equatable, Sendable {
    public var mode: FaceScanGrade
    /// FAST: use as many workers as the machine has. Default ON.
    public var fast: Bool
    /// Minimum face size in the photo's own pixels. LOW keeps large, clear
    /// faces only; MED ~40px; HIGH and XHIGH ~30px — still a real face,
    /// not tourists.
    public var minimumFacePixels: Double
    /// Cosine threshold for proposing a roster person.
    public var matchThreshold: Float
    /// Cosine threshold for joining an existing Other group.
    public var clusterThreshold: Float
    /// Longer edge of the bounded decode detection runs on.
    public var detectPixels: Int
    /// Most templates kept per person — when a group is named, and as the
    /// XHIGH gallery rebuild's cap.
    public var templateCap: Int
    /// Detector score floor for the SCRFD path.
    public var detScoreThreshold: Float
    /// Detector letterbox sizes for the SCRFD path — MED runs 640 only,
    /// HIGH adds a 960 pass, XHIGH adds 1024 for smaller faces.
    public var detectorScales: [Int]
    /// Seconds between sampled video frames. Nil means video is skipped
    /// (LOW stills-only); MED samples sparsely, HIGH ~1 fps, XHIGH ~2 fps.
    public var videoFrameStride: TimeInterval?
    /// Cap on sampled frames per clip so MED stays light on long videos.
    public var maximumVideoFrames: Int
    /// Cosine floor for treating two video-frame detections as the same
    /// appearance — 1 fps would otherwise record one face per second.
    public var videoDuplicateCosine: Float
    /// XHIGH's horizontal-flip TTA: each face is embedded twice — the
    /// aligned crop and its mirror — and the averaged vector is stored.
    /// Same ArcFace model both times; the second view steadies the
    /// embedding. Off below XHIGH.
    public var flipTTA: Bool
    /// XHIGH's gallery rebuild: after matching, each roster person's
    /// templates are re-picked from their confirmed faces — a diverse
    /// spread across photos instead of whatever happened to be pinned.
    /// Off below XHIGH.
    public var rebuildTemplates: Bool
    /// The optional larger SCRFD sibling package — XHIGH's last resort
    /// when the standard detector still misses real group-shot faces.
    /// Default off; silently unused when no `det_34g*` package is
    /// installed alongside the 10G ones. Never a different recognizer.
    public var usesLargeDetector: Bool

    public init(
        mode: FaceScanGrade = .low,
        fast: Bool = true,
        minimumFacePixels: Double? = nil,
        matchThreshold: Float = 0.48,
        clusterThreshold: Float = 0.5,
        detectPixels: Int? = nil,
        templateCap: Int? = nil,
        detScoreThreshold: Float = 0.5,
        detectorScales: [Int]? = nil,
        videoFrameStride: TimeInterval? = nil,
        maximumVideoFrames: Int? = nil,
        videoDuplicateCosine: Float = 0.92,
        flipTTA: Bool? = nil,
        rebuildTemplates: Bool? = nil,
        usesLargeDetector: Bool = false
    ) {
        self.mode = mode
        self.fast = fast
        self.minimumFacePixels = minimumFacePixels ?? Self.defaultMinimumFacePixels(for: mode)
        self.matchThreshold = matchThreshold
        self.clusterThreshold = clusterThreshold
        self.detectPixels = detectPixels ?? Self.defaultDetectPixels(for: mode)
        self.templateCap = templateCap ?? Self.defaultTemplateCap(for: mode)
        self.detScoreThreshold = detScoreThreshold
        self.detectorScales = detectorScales ?? Self.defaultDetectorScales(for: mode)
        self.videoFrameStride = videoFrameStride ?? Self.defaultVideoFrameStride(for: mode)
        self.maximumVideoFrames = maximumVideoFrames ?? Self.defaultMaximumVideoFrames(for: mode)
        self.videoDuplicateCosine = videoDuplicateCosine
        self.flipTTA = flipTTA ?? (mode == .xhigh)
        self.rebuildTemplates = rebuildTemplates ?? (mode == .xhigh)
        self.usesLargeDetector = usesLargeDetector
    }

    /// The detector this mode runs.
    public var detectorKind: FaceDetectorKind {
        mode == .low || mode == .none ? .vision : .scrfd
    }

    /// The grade a scan actually achieves: every pipeline through XHIGH is
    /// implemented, so a requested mode stamps itself.
    public static let implementedGrade = FaceScanGrade.xhigh

    public static func defaultMinimumFacePixels(for mode: FaceScanGrade) -> Double {
        switch mode {
        case .none, .low: 64
        case .med: 40
        case .high, .xhigh: 30
        }
    }

    public static func defaultDetectPixels(for mode: FaceScanGrade) -> Int {
        switch mode {
        case .none, .low: 1_600
        case .med, .high, .xhigh: 2_560
        }
    }

    public static func defaultDetectorScales(for mode: FaceScanGrade) -> [Int] {
        switch mode {
        case .none, .low, .med: [640]
        case .high: [640, 960]
        case .xhigh: [640, 960, 1024]
        }
    }

    /// Most templates kept per roster person — 8 on the lower modes, 15
    /// once XHIGH's rebuild has a deeper confirmed pool to pick from.
    public static func defaultTemplateCap(for mode: FaceScanGrade) -> Int {
        switch mode {
        case .xhigh: 15
        default: 8
        }
    }

    public static func defaultVideoFrameStride(for mode: FaceScanGrade) -> TimeInterval? {
        switch mode {
        case .none, .low: nil
        case .med: 30
        case .high: 1
        case .xhigh: 0.5
        }
    }

    public static func defaultMaximumVideoFrames(for mode: FaceScanGrade) -> Int {
        switch mode {
        case .none, .low: 0
        case .med: 12
        case .high, .xhigh: .max
        }
    }

    /// Whether this pass reads video frames at all.
    public var scansVideo: Bool {
        videoFrameStride != nil && maximumVideoFrames > 0
    }

    /// Worker width for the decode/detect/embed stage.
    /// Fast = pin the machine. Off = two workers so the Mac stays cool.
    public var concurrency: Int {
        fast
            ? max(2, ProcessInfo.processInfo.activeProcessorCount)
            : 2
    }
}

public struct FaceScanReport: Equatable, Sendable {
    public var photosConsidered: Int = 0
    public var photosProcessed: Int = 0
    public var photosSkipped: Int = 0
    public var photosFailed: Int = 0
    public var facesDetected: Int = 0
    public var facesProposed: Int = 0
    public var facesGrouped: Int = 0
    public var groupsCreated: Int = 0
    /// Video frames sampled in MED/HIGH/XHIGH passes.
    public var videoFramesRead: Int = 0
    /// Burst members covered by a sibling's sample — stamped at the
    /// executed grade without being decoded.
    public var photosBurstCovered: Int = 0
    /// The detector packages that ran — e.g. "det_10g 640/960/1024" — for
    /// the Jobs log, which may name packages. Nil on the Vision path.
    public var detectorSummary: String?

    public init() {}
}

public enum FaceIndexError: Error, Equatable, LocalizedError {
    case modelNotInstalled(String)
    case detectorNotInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let path):
            "The face model is not installed. Run scripts/convert-arcface.sh once to build it at \(path)."
        case .detectorNotInstalled(let path):
            "The face detector is not installed. Run scripts/convert-scrfd.sh once to build it at \(path)."
        }
    }
}
