import CoreGraphics
import Foundation

/// The LOW-mode face pass: Vision detection on bounded decodes, ArcFace
/// embeddings for every face that clears the size floor, cosine matching
/// against roster templates, and greedy grouping of the leftovers.
///
/// The service writes only to the catalog database — media files are never
/// touched. Skip rules come from `face_photos.scan_grade` plus the
/// size/mtime file identity, so replugging a drive never re-runs detection
/// on photos already scanned at this grade or higher. Confirmed faces are
/// frozen: they are excluded from matching, grouping, and photo-level face
/// replacement.
public struct FaceIndexService: Sendable {
    public var options: FaceScanOptions
    private let store: FaceIndexStore

    public init(catalogURL: URL, options: FaceScanOptions = FaceScanOptions()) {
        self.store = FaceIndexStore(url: catalogURL)
        self.options = options
    }

    init(store: FaceIndexStore, options: FaceScanOptions = FaceScanOptions()) {
        self.store = store
        self.options = options
    }

    // MARK: - Scan

    /// Scans a location's stills (the photo and RAW primaries of an
    /// `OrganizeScanner` result). Video is skipped entirely in LOW mode.
    public func scan(
        items: [OrganizeItem],
        embedder: FaceEmbeddingProviding?,
        progress: FileOperationProgressHandler? = nil
    ) throws -> FaceScanReport {
        guard let embedder else {
            throw FaceIndexError.modelNotInstalled(FaceModelCatalog.modelFileName)
        }

        var report = FaceScanReport()
        let stills = items.filter { $0.kind == .raw || $0.kind == .photo }
        report.photosConsidered = stills.count

        // New-files-only rule: a photo whose recorded grade covers this mode
        // — and whose size/mtime still match — is skipped without decoding.
        let existing = try store.photos(pathKeys: stills.map(\.primary.pathKey))
        var pending: [OrganizeItem] = []
        for item in stills {
            let file = item.primary
            if let known = existing[file.pathKey],
               known.scanGrade.covers(options.mode),
               known.describes(path: file.path, size: file.size, modifiedAt: file.modifiedAt) {
                report.photosSkipped += 1
            } else {
                pending.append(item)
            }
        }

        let total = pending.count
        progress?(FileOperationProgress(phase: "Detecting faces", processedFiles: 0, totalFiles: total))
        let options = self.options
        let store = self.store
        let items = pending
        let results = OrganizeScanner.parallelMap(
            count: total,
            width: options.concurrency,
            onCompleted: { completed in
                if completed == total || completed % 5 == 0 {
                    progress?(FileOperationProgress(
                        phase: "Detecting faces",
                        processedFiles: completed,
                        totalFiles: total
                    ))
                }
            },
            transform: { index in
                autoreleasepool {
                    Self.processPhoto(items[index], options: options, embedder: embedder, store: store)
                }
            }
        )

        for outcome in results {
            switch outcome {
            case .processed(let faces):
                report.photosProcessed += 1
                report.facesDetected += faces
            case .failed:
                report.photosFailed += 1
            case .skipped:
                report.photosSkipped += 1
            }
        }

        try matchAndGroup(report: &report, progress: progress)
        return report
    }

    /// Re-matches every stored, unconfirmed embedding against the current
    /// roster and re-groups the leftovers — the cheap pass that runs after
    /// the roster changes. Reads vectors only; nothing is re-decoded and no
    /// ML runs.
    public func rematchRoster(progress: FileOperationProgressHandler? = nil) throws {
        var report = FaceScanReport()
        try matchAndGroup(report: &report, progress: progress)
    }

    /// Sends faces back through the grouping pass — used when a face is
    /// rejected from a proposed match or pulled out of a group. Each face
    /// joins the nearest existing group or seeds a new one. Confirmed faces
    /// are never moved.
    public func regroup(_ faceIDs: [UUID]) throws {
        var pool: [FaceRecord] = []
        for id in faceIDs {
            guard let face = try store.face(id: id), face.state != .confirmed else { continue }
            try store.unassignFace(id)
            pool.append(face)
        }
        _ = try assignToGroups(pool, options: options)
        try store.refreshFaceCounts()
    }

    // MARK: - Per-photo pipeline

    private enum PhotoOutcome {
        case processed(faces: Int)
        case failed
        case skipped
    }

    /// The grade a scan actually achieves. Phase 1 implements only the
    /// Vision-detect LOW pipeline — a higher requested mode still runs that
    /// pipeline, so the photo is stamped with what ran and stays eligible
    /// for the real MED/HIGH passes when they land.
    private static let executedGrade = FaceScanGrade.low

    private static func processPhoto(
        _ item: OrganizeItem,
        options: FaceScanOptions,
        embedder: FaceEmbeddingProviding,
        store: FaceIndexStore
    ) -> PhotoOutcome {
        let file = item.primary
        let url = file.url
        guard let image = FaceImageDecoder.detectionImage(for: url, maximumPixelSize: options.detectPixels) else {
            return .failed
        }
        let fullSize = FaceImageDecoder.pixelSize(of: url)
            ?? CGSize(width: image.width, height: image.height)

        let detections = VisionFaceDetector.detect(
            in: image,
            imagePixelSize: fullSize,
            minimumFacePixels: options.minimumFacePixels
        )

        var faces: [FaceRecord] = []
        for detection in detections {
            let aligned: CGImage?
            if let landmarks = detection.landmarks {
                aligned = FaceAligner.alignedImage(image, landmarks: landmarks)
            } else {
                aligned = FaceAligner.boxCrop(image, box: detection.boundingBox)
            }
            guard let aligned,
                  let embedding = try? embedder.embed(aligned) else { continue }
            faces.append(FaceRecord(
                photoID: file.pathKey,
                box: NormalizedFaceBox(
                    x: Double(detection.boundingBox.origin.x),
                    y: Double(detection.boundingBox.origin.y),
                    width: Double(detection.boundingBox.width),
                    height: Double(detection.boundingBox.height)
                ),
                detScore: Double(detection.confidence),
                embedding: embedding,
                crop: FaceAligner.jpegData(aligned),
                state: .cached,
                scanGrade: executedGrade,
                photoPath: file.path
            ))
        }

        let photo = FacePhotoRecord(
            pathKey: file.pathKey,
            path: file.path,
            fileName: file.name,
            byteCount: file.size,
            modifiedAt: file.modifiedAt,
            takenAt: item.captureDate,
            scanGrade: min(options.mode, executedGrade),
            faceCount: faces.count
        )
        guard (try? store.replaceFaces(photo: photo, faces: faces)) != nil else {
            return .failed
        }
        return .processed(faces: faces.count)
    }

    // MARK: - Match and group

    private func matchAndGroup(
        report: inout FaceScanReport,
        progress: FileOperationProgressHandler?
    ) throws {
        let faces = try store.matchableFaces()
        progress?(FileOperationProgress(
            phase: "Matching people",
            processedFiles: 0,
            totalFiles: faces.count
        ))
        let templates = try store.rosterTemplates()
        var unmatched: [FaceRecord] = []
        for (index, face) in faces.enumerated() {
            guard let embedding = face.embedding else { continue }
            if let match = Self.bestMatch(embedding, templates: templates, threshold: options.matchThreshold) {
                try store.assignFace(face.id, to: match.personID, state: .proposed, score: Double(match.score))
                report.facesProposed += 1
            } else if let personID = face.personID,
                      let person = try store.person(personID), person.isRoster {
                // A proposal that no longer holds returns to the pool.
                try store.unassignFace(face.id)
                unmatched.append(face)
            } else if face.personID == nil {
                unmatched.append(face)
            }
            // Faces already in an Other group keep their grouping.
            if index % 200 == 0 {
                progress?(FileOperationProgress(
                    phase: "Matching people",
                    processedFiles: index,
                    totalFiles: faces.count
                ))
            }
        }

        progress?(FileOperationProgress(
            phase: "Grouping faces",
            processedFiles: 0,
            totalFiles: unmatched.count
        ))
        let grouped = try assignToGroups(unmatched, options: options)
        report.facesGrouped = grouped.assigned
        report.groupsCreated = grouped.created
        try store.refreshFaceCounts()
    }

    /// Best roster template for an embedding, or nil below the threshold.
    static func bestMatch(
        _ embedding: [Float],
        templates: [(personID: UUID, embedding: [Float])],
        threshold: Float
    ) -> (personID: UUID, score: Float)? {
        var best: (UUID, Float)?
        for template in templates {
            let score = FaceEmbeddingMath.cosine(embedding, template.embedding)
            if score >= threshold, score > (best?.1 ?? -.infinity) {
                best = (template.personID, score)
            }
        }
        return best
    }

    /// Greedy cosine grouping: faces in detection-confidence order join the
    /// nearest existing group at or above `clusterThreshold`, else seed a
    /// new "Person N" group whose centroid updates as members join.
    private func assignToGroups(
        _ faces: [FaceRecord],
        options: FaceScanOptions
    ) throws -> (assigned: Int, created: Int) {
        let store = self.store
        let groupEmbeddings = try store.groupEmbeddings()
        var centroids: [(personID: UUID, centroid: [Float], members: Int)] = []
        centroids.reserveCapacity(groupEmbeddings.count)
        for (personID, embeddings) in groupEmbeddings.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            if let centroid = FaceEmbeddingMath.centroid(embeddings) {
                centroids.append((personID, centroid, embeddings.count))
            }
        }

        var assigned = 0
        var created = 0
        // Deterministic order: most confident detections form groups first.
        for face in faces.sorted(by: { $0.detScore > $1.detScore }) {
            guard let embedding = face.embedding else { continue }
            var bestIndex: Int?
            var bestScore: Float = options.clusterThreshold
            for (index, entry) in centroids.enumerated() {
                let score = FaceEmbeddingMath.cosine(embedding, entry.centroid)
                if score >= bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }
            let personID: UUID
            if let bestIndex {
                personID = centroids[bestIndex].personID
                // Running-mean update keeps the centroid honest as the group
                // grows within this pass.
                var updated = centroids[bestIndex].centroid.map { $0 * Float(centroids[bestIndex].members) }
                for i in updated.indices { updated[i] += embedding[i] }
                centroids[bestIndex].members += 1
                centroids[bestIndex].centroid = FaceEmbeddingMath.l2Normalized(updated)
            } else {
                let group = try store.createPerson(name: store.nextGroupName(), isRoster: false)
                personID = group.id
                centroids.append((personID, embedding, 1))
                created += 1
            }
            try store.assignFace(face.id, to: personID, state: .other, score: bestIndex.map { _ in Double(bestScore) })
            assigned += 1
        }
        return (assigned, created)
    }
}
