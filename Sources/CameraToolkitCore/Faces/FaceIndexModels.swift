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

    /// The word the scan sheet uses for this tier — Low, Medium, High,
    /// Extra High. `none` is not a scan grade (it marks a manually tagged
    /// file that was never scanned) and has no label.
    public var displayName: String? {
        switch self {
        case .none: nil
        case .low: "Low"
        case .med: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        }
    }
}

/// Live counts of what the face index holds — the Clear Face Scan sheet's
/// "what will be removed" list.
public struct FaceIndexCounts: Equatable, Sendable {
    /// `face_photos` rows — files a scan (or a manual tag) has covered.
    public var scannedPhotos: Int
    /// `faces` rows — stored detections.
    public var faces: Int
    /// Roster `people` rows — named people.
    public var namedPeople: Int
    /// Non-roster `people` rows — auto-formed clusters.
    public var unnamedGroups: Int

    public init(scannedPhotos: Int = 0, faces: Int = 0, namedPeople: Int = 0, unnamedGroups: Int = 0) {
        self.scannedPhotos = scannedPhotos
        self.faces = faces
        self.namedPeople = namedPeople
        self.unnamedGroups = unnamedGroups
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
    /// `FaceEngine.identifier` of the pass that scanned the file. A row from
    /// another engine never satisfies the skip rule, so an engine change
    /// re-reads the photo instead of mixing embedding spaces.
    public var engine: String

    public init(
        pathKey: String,
        path: String,
        fileName: String,
        byteCount: Int64,
        modifiedAt: Date,
        takenAt: Date? = nil,
        scanGrade: FaceScanGrade = .none,
        faceCount: Int = 0,
        engine: String = ""
    ) {
        self.pathKey = pathKey
        self.path = path
        self.fileName = fileName
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.takenAt = takenAt
        self.scanGrade = scanGrade
        self.faceCount = faceCount
        self.engine = engine
    }

    /// True when this row was produced by the current engine at a grade
    /// that covers `mode` — the whole skip rule besides file identity.
    public func covers(_ mode: FaceScanGrade) -> Bool {
        engine == FaceEngine.identifier && scanGrade.covers(mode)
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
    /// Detector confidence (0–1).
    public var detScore: Double
    /// Cosine score of the current assignment, when one exists.
    public var matchScore: Double?
    /// The embedding's pre-normalization norm — the engine's own quality
    /// signal; blurry, tiny, or occluded faces come out short. Nil on rows
    /// written before it was recorded and on manual tags.
    public var quality: Double?
    /// The face's shorter box side in pixels of the decoded image the
    /// engine saw. The grouping size floor reads this.
    public var facePixels: Double?
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
        quality: Double? = nil,
        facePixels: Double? = nil,
        embedding: [Float]? = nil,
        crop: Data? = nil,
        model: String = FaceEngine.identifier,
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
        self.quality = quality
        self.facePixels = facePixels
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

/// Persisted "not this person" / "not this group" verdicts, indexed for
/// the match and group passes. A rejected face can never be assigned back
/// to that person (`blocks`), and its embedding doubles as a negative
/// example: a candidate closer to a rejected face than to the person's
/// own templates or group centroid is vetoed (`vetoes`). Rejections die
/// only with the face or person row — Clear Face Scan wipes the table.
public struct FaceRejectionIndex: Sendable {
    /// face id → the persons it must never be assigned to.
    public var personIDsByFaceID: [UUID: Set<UUID>] = [:]
    /// person id → embeddings of faces rejected from it.
    public var embeddingsByPersonID: [UUID: [[Float]]] = [:]

    public init() {}

    /// True when this face may never be assigned to this person.
    public func blocks(faceID: UUID, personID: UUID) -> Bool {
        personIDsByFaceID[faceID]?.contains(personID) ?? false
    }

    /// True when `embedding` is closer to one of the person's rejected
    /// faces than `score` — the cheap negative check that keeps rejected
    /// looks from re-seeding a person or joining a group, no model needed.
    public func vetoes(_ embedding: [Float], personID: UUID, score: Float) -> Bool {
        guard let rejected = embeddingsByPersonID[personID] else { return false }
        return rejected.contains { FaceEmbeddingMath.cosine(embedding, $0) > score }
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
    /// Cosine floor for proposing a roster person (best template match).
    public var matchThreshold: Float
    /// Cosine floor for joining an automatic group — the mean similarity
    /// to the group's members (average linkage), never to one face.
    public var clusterThreshold: Float
    /// Longer edge of the bounded decode detection runs on.
    public var detectPixels: Int
    /// Most templates kept per person — when a group is named, and as the
    /// XHIGH gallery rebuild's cap.
    public var templateCap: Int
    /// Detector confidence floor: faces below it are not stored at all.
    public var detScoreThreshold: Float
    /// Detector confidence floor for grouping (Immich's default). Faces
    /// below it are stored — boxes and roster proposals still work — but
    /// never seed or join an automatic group.
    public var groupingMinDetScore: Float
    /// Smallest face (shorter box side, decoded pixels) that may be
    /// grouped. Below it the embedding is an upscaled smear that resembles
    /// every other smear — the raw material of junk piles.
    public var groupingMinFacePixels: Double
    /// Faces a cluster formed in one pass needs before it becomes a
    /// "Person N" row. Smaller clusters stay ungrouped rather than
    /// littering People with pairs and singletons.
    public var minimumGroupFaces: Int
    /// Detector input sizes the engine runs — LOW and MED 640, HIGH adds
    /// 960, XHIGH adds 1024 for smaller faces. Detections merge under one
    /// NMS.
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

    public init(
        mode: FaceScanGrade = .low,
        fast: Bool = true,
        minimumFacePixels: Double? = nil,
        matchThreshold: Float = 0.45,
        clusterThreshold: Float = 0.40,
        detectPixels: Int? = nil,
        templateCap: Int? = nil,
        detScoreThreshold: Float = 0.6,
        groupingMinDetScore: Float = 0.7,
        groupingMinFacePixels: Double = 48,
        minimumGroupFaces: Int = 3,
        detectorScales: [Int]? = nil,
        videoFrameStride: TimeInterval? = nil,
        maximumVideoFrames: Int? = nil,
        videoDuplicateCosine: Float = 0.92,
        flipTTA: Bool? = nil,
        rebuildTemplates: Bool? = nil
    ) {
        self.mode = mode
        self.fast = fast
        self.minimumFacePixels = minimumFacePixels ?? Self.defaultMinimumFacePixels(for: mode)
        self.matchThreshold = matchThreshold
        self.clusterThreshold = clusterThreshold
        self.detectPixels = detectPixels ?? Self.defaultDetectPixels(for: mode)
        self.templateCap = templateCap ?? Self.defaultTemplateCap(for: mode)
        self.detScoreThreshold = detScoreThreshold
        self.groupingMinDetScore = groupingMinDetScore
        self.groupingMinFacePixels = groupingMinFacePixels
        self.minimumGroupFaces = minimumGroupFaces
        self.detectorScales = detectorScales ?? Self.defaultDetectorScales(for: mode)
        self.videoFrameStride = videoFrameStride ?? Self.defaultVideoFrameStride(for: mode)
        self.maximumVideoFrames = maximumVideoFrames ?? Self.defaultMaximumVideoFrames(for: mode)
        self.videoDuplicateCosine = videoDuplicateCosine
        self.flipTTA = flipTTA ?? (mode == .xhigh)
        self.rebuildTemplates = rebuildTemplates ?? (mode == .xhigh)
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
    /// Faces whose assigned person changed in the match/group pass — the
    /// "did anything actually move" count the Re-match status line shows.
    public var facesMoved: Int = 0
    /// Auto "Person N" groups the rebundle dissolved outright — rows left
    /// with no faces after their members re-pooled.
    public var groupsDissolved: Int = 0
    /// The engine and detector scales that ran — for the Jobs log, which
    /// may name packages. Nil for a vectors-only re-match.
    public var detectorSummary: String?

    public init() {}
}

public enum FaceIndexError: Error, Equatable, LocalizedError {
    /// The sidecar environment or model pack is missing; the payload is
    /// the user-facing sentence naming the setup command.
    case engineNotInstalled(String)
    /// The sidecar failed to start, died, timed out, or rejected a request.
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .engineNotInstalled(let message), .engineFailed(let message):
            message
        }
    }
}
