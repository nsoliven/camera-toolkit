import CoreGraphics
import Foundation

/// The face pass for every quality mode: detection on bounded decodes
/// (Vision for LOW, SCRFD for MED+), ArcFace embeddings for every face
/// that clears the mode's size floor, cosine matching against roster
/// templates, and greedy grouping of the leftovers. MED/HIGH/XHIGH
/// additionally sample video frames — stills plus a light frame pass at
/// MED, ~1 fps at HIGH, ~2 fps at XHIGH — and XHIGH adds a third detector
/// scale, flip-TTA embeddings, and a roster-template rebuild.
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

    /// Camera files below this size cannot hold a decodable preview at all —
    /// the cheapest possible "don't waste a sample slot on a corrupt frame"
    /// check, done on the stat the scan already recorded.
    public static let minimumSampleBytes: Int64 = 65_536

    /// The items a scan decodes. Singles contribute their one still or the
    /// video itself; a burst contributes its first, middle, and last stills
    /// — the same scene and the same people most of the time, so decoding
    /// all eighty frames is waste — plus each video in the stack (its poster
    /// can show faces the stills miss). At HIGH and above every still is a
    /// target. Faces land on the sampled files only; the burst's other
    /// frames keep no `face_photos` row, so a later regroup that splits the
    /// burst can scan them on their own.
    public static func scanTargets(for stacks: [OrganizeStack], mode: FaceScanGrade) -> [OrganizeItem] {
        let scannable: Set<OrganizeMediaKind> = [.raw, .photo, .video]
        var targets: [OrganizeItem] = []
        for stack in stacks {
            if stack.isBurst, mode < .high {
                targets.append(contentsOf: burstSample(stack))
            } else {
                targets.append(contentsOf: stack.items.filter { scannable.contains($0.kind) })
            }
        }
        return targets
    }

    /// First/middle/last stills of a burst — chosen from frames large
    /// enough to hold a decodable preview, so a corrupt/tiny candidate is
    /// replaced by the next healthy frame rather than wasting a sample —
    /// plus every video in the stack (its poster can show faces the stills
    /// miss). A burst of all-tiny files still keeps its first still so
    /// something represents it. Blur gets no special check — no cheap
    /// signal beats the first/mid/last spread.
    private static func burstSample(_ stack: OrganizeStack) -> [OrganizeItem] {
        let stills = stack.items.filter { $0.kind == .raw || $0.kind == .photo }
        var picked: [OrganizeItem] = []
        if !stills.isEmpty {
            let healthy = stills.filter { $0.primary.size >= minimumSampleBytes }
            if healthy.isEmpty {
                picked = [stills[0]]
            } else {
                var seen = Set<Int>()
                picked = [0, healthy.count / 2, healthy.count - 1]
                    .filter { seen.insert($0).inserted }
                    .map { healthy[$0] }
            }
        }
        picked.append(contentsOf: stack.items.filter { $0.kind == .video })
        return picked
    }

    /// Scans a location's burst stacks — the `OrganizeScanner` grouping a
    /// board already produced. This is the grouping gate: the scan runs
    /// against the current burst structure, sampling each burst per
    /// `scanTargets` (first/middle/last stills at LOW and MED, every still
    /// at HIGH and above). `detector` is the engine for the mode: nil
    /// resolves to Vision for LOW and throws for MED+, where the SCRFD
    /// package must be installed. Modes that do not read video frames
    /// skip video targets entirely.
    public func scan(
        stacks: [OrganizeStack],
        embedder: FaceEmbeddingProviding?,
        detector: FaceDetecting? = nil,
        progress: FileOperationProgressHandler? = nil
    ) throws -> FaceScanReport {
        guard let embedder else {
            throw FaceIndexError.modelNotInstalled(FaceModelCatalog.modelFileName)
        }
        let engine = try resolveEngine(detector)

        var report = FaceScanReport()
        var targets = Self.scanTargets(for: stacks, mode: options.mode)
        if !options.scansVideo {
            targets = targets.filter { $0.kind != .video }
        }
        report.photosConsidered = targets.count

        // New-files-only rule: a photo whose recorded grade covers this mode
        // — and whose size/mtime still match — is skipped without decoding.
        let existing = try store.photos(pathKeys: targets.map(\.primary.pathKey))
        var pending: [OrganizeItem] = []
        for item in targets {
            let file = item.primary
            if let known = existing[file.pathKey],
               known.scanGrade.covers(options.mode),
               known.describes(path: file.path, size: file.size, modifiedAt: file.modifiedAt) {
                report.photosSkipped += 1
            } else {
                pending.append(item)
            }
        }

        try executeScan(
            pending: pending,
            covered: [],
            embedder: embedder,
            engine: engine,
            report: &report,
            progress: progress
        )
        return report
    }

    /// Scans a location's media (the photo, RAW, and — at MED and above —
    /// video primaries of an `OrganizeScanner` result). `detector` is the
    /// engine for the mode: nil resolves to Vision for LOW and throws for
    /// MED+, where the SCRFD package must be installed.
    ///
    /// `stacks` is the scanner's burst grouping. When present, a burst of
    /// stills is sampled — at most three spread frames are decoded and the
    /// rest are stamped covered by the sibling sample — because near-
    /// identical frames repeat the same faces. Without it (no scan result)
    /// every still is scanned, and at HIGH and above every still is a
    /// target regardless of grouping.
    public func scan(
        items: [OrganizeItem],
        embedder: FaceEmbeddingProviding?,
        detector: FaceDetecting? = nil,
        stacks: [OrganizeStack]? = nil,
        progress: FileOperationProgressHandler? = nil
    ) throws -> FaceScanReport {
        guard let embedder else {
            throw FaceIndexError.modelNotInstalled(FaceModelCatalog.modelFileName)
        }
        let engine = try resolveEngine(detector)

        var report = FaceScanReport()
        let eligible = items.filter {
            $0.kind == .raw || $0.kind == .photo || (options.scansVideo && $0.kind == .video)
        }
        report.photosConsidered = eligible.count

        // Burst-aware selection: which items are sampled frames and which
        // are burst members covered by a sibling sample. Video never
        // stacks, and at HIGH and above every still is a target — the same
        // gate `scanTargets` applies to the stacks-driven scan.
        var sampledIDs: Set<String> = []
        var burstMemberIDs: Set<String> = []
        if let stacks, options.mode < .high {
            let eligibleIDs = Set(eligible.map(\.id))
            for stack in stacks where stack.isBurst {
                // The stacker never stacks video; keep that invariant here
                // so a clip always runs its own frame sampling.
                let members = stack.items.filter { eligibleIDs.contains($0.id) && $0.kind != .video }
                guard members.count > 1 else { continue }
                for item in members { burstMemberIDs.insert(item.id) }
                for item in Self.burstSample(members) { sampledIDs.insert(item.id) }
            }
        }

        // New-files-only rule: a photo whose recorded grade covers this mode
        // — and whose size/mtime still match — is skipped without decoding.
        let existing = try store.photos(pathKeys: eligible.map(\.primary.pathKey))
        var pending: [OrganizeItem] = []
        var covered: [OrganizeItem] = []
        for item in eligible {
            let file = item.primary
            if let known = existing[file.pathKey],
               known.scanGrade.covers(options.mode),
               known.describes(path: file.path, size: file.size, modifiedAt: file.modifiedAt) {
                report.photosSkipped += 1
            } else if burstMemberIDs.contains(item.id), !sampledIDs.contains(item.id) {
                covered.append(item)
            } else {
                pending.append(item)
            }
        }

        try executeScan(
            pending: pending,
            covered: covered,
            embedder: embedder,
            engine: engine,
            report: &report,
            progress: progress
        )
        return report
    }

    /// The detector for this pass: an explicit engine if the caller built
    /// one (a stub in tests, SCRFD for MED+), else Vision for LOW and an
    /// install error for MED+.
    private func resolveEngine(_ detector: FaceDetecting?) throws -> FaceDetecting {
        if let detector { return detector }
        if options.detectorKind == .vision { return VisionDetector() }
        throw FaceIndexError.detectorNotInstalled(FaceModelCatalog.detectorFileName)
    }

    /// Runs the decode/detect/embed pass over `pending`, stamps covered
    /// burst members with the executed grade, then re-matches and re-groups
    /// the stored faces.
    private func executeScan(
        pending: [OrganizeItem],
        covered: [OrganizeItem],
        embedder: FaceEmbeddingProviding,
        engine: FaceDetecting,
        report: inout FaceScanReport,
        progress: FileOperationProgressHandler?
    ) throws {
        let options = self.options
        let total = pending.count
        progress?(FileOperationProgress(phase: "Detecting faces", processedFiles: 0, totalFiles: total))
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
                    Self.processItem(
                        items[index],
                        options: options,
                        detector: engine,
                        embedder: embedder,
                        store: store
                    )
                }
            }
        )

        for outcome in results {
            switch outcome {
            case .processed(let faces, let videoFrames):
                report.photosProcessed += 1
                report.facesDetected += faces
                report.videoFramesRead += videoFrames
            case .failed:
                report.photosFailed += 1
            case .skipped:
                report.photosSkipped += 1
            }
        }

        // Un-sampled burst members are covered by their siblings' pass:
        // stamp the same executed grade so they stay out of later scans.
        // Faces a lower grade already found on them are kept.
        let grade = Self.executedGrade(for: options.mode)
        for item in covered {
            let file = item.primary
            try? store.markCovered(photo: FacePhotoRecord(
                pathKey: file.pathKey,
                path: file.path,
                fileName: file.name,
                byteCount: file.size,
                modifiedAt: file.modifiedAt,
                takenAt: item.captureDate,
                scanGrade: grade
            ))
            report.photosBurstCovered += 1
        }

        report.detectorSummary = (engine as? SCRFDDetector)?.packageSummary(for: options)

        // XHIGH rebuilds the gallery first so the match below runs against
        // the sharpened templates; the rebuild reads confirmed faces only.
        if options.rebuildTemplates {
            try rebuildRosterTemplates()
        }
        try matchAndGroup(report: &report, progress: progress)
    }

    /// The frames a burst actually scans: every frame of a small burst,
    /// else first, middle, and last — near-identical frames repeat the
    /// same faces, so the middle and edges cover the whole stack.
    static func burstSample(_ members: [OrganizeItem]) -> [OrganizeItem] {
        guard members.count > 3 else { return members }
        return [members[0], members[members.count / 2], members[members.count - 1]]
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
        case processed(faces: Int, videoFrames: Int)
        case failed
        case skipped
    }

    /// The grade stamped on a photo: what actually ran, never higher than
    /// the implemented pipeline. Every grade through XHIGH is implemented,
    /// so a request stamps itself and a repeat pass skips the photo.
    private static func executedGrade(for mode: FaceScanGrade) -> FaceScanGrade {
        min(mode, FaceScanOptions.implementedGrade)
    }

    private static func processItem(
        _ item: OrganizeItem,
        options: FaceScanOptions,
        detector: FaceDetecting,
        embedder: FaceEmbeddingProviding,
        store: FaceIndexStore
    ) -> PhotoOutcome {
        if item.kind == .video {
            return processVideo(item, options: options, detector: detector, embedder: embedder, store: store)
        }
        return processPhoto(item, options: options, detector: detector, embedder: embedder, store: store)
    }

    /// Detect → align → embed for every face on one image. Shared by still
    /// decodes and sampled video frames; `pixelSize` is the native image
    /// size the min-face floor is measured against.
    private static func facesOnImage(
        _ image: CGImage,
        pixelSize: CGSize,
        file: OrganizeFile,
        options: FaceScanOptions,
        detector: FaceDetecting,
        embedder: FaceEmbeddingProviding
    ) -> [FaceRecord] {
        let detections = detector.detect(
            in: image,
            imagePixelSize: pixelSize,
            options: options
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
                  var embedding = try? embedder.embed(aligned) else { continue }
            // XHIGH hflip TTA: embed the mirrored crop too and store the
            // L2-normalized mean — the standard ArcFace second view.
            if options.flipTTA,
               let flipped = FaceAligner.flippedHorizontally(aligned),
               let flippedEmbedding = try? embedder.embed(flipped),
               let averaged = FaceEmbeddingMath.centroid([embedding, flippedEmbedding]) {
                embedding = averaged
            }
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
                scanGrade: executedGrade(for: options.mode),
                photoPath: file.path
            ))
        }
        return faces
    }

    private static func processPhoto(
        _ item: OrganizeItem,
        options: FaceScanOptions,
        detector: FaceDetecting,
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

        let faces = facesOnImage(
            image,
            pixelSize: fullSize,
            file: file,
            options: options,
            detector: detector,
            embedder: embedder
        )

        let photo = FacePhotoRecord(
            pathKey: file.pathKey,
            path: file.path,
            fileName: file.name,
            byteCount: file.size,
            modifiedAt: file.modifiedAt,
            takenAt: item.captureDate,
            scanGrade: executedGrade(for: options.mode),
            faceCount: faces.count
        )
        guard (try? store.replaceFaces(photo: photo, faces: faces)) != nil else {
            return .failed
        }
        return .processed(faces: faces.count, videoFrames: 0)
    }

    /// MED/HIGH video pass: sampled frames through the same
    /// detect-align-embed path. Per-clip embedding dedup keeps one row per
    /// distinct appearance instead of one per second — event people care
    /// about who was there, not how long they were on screen.
    private static func processVideo(
        _ item: OrganizeItem,
        options: FaceScanOptions,
        detector: FaceDetecting,
        embedder: FaceEmbeddingProviding,
        store: FaceIndexStore
    ) -> PhotoOutcome {
        let file = item.primary
        guard let stride = options.videoFrameStride,
              let sampler = FaceVideoSampler(url: file.url, maximumPixelSize: options.detectPixels) else {
            return .failed
        }
        let times = FaceVideoSampler.sampleTimes(
            duration: sampler.duration,
            stride: stride,
            maxFrames: options.maximumVideoFrames
        )
        guard !times.isEmpty else { return .failed }

        let nativeSize = sampler.pixelSize.width > 0 ? sampler.pixelSize : nil
        var faces: [FaceRecord] = []
        var keptEmbeddings: [[Float]] = []
        var framesRead = 0
        for time in times {
            guard let frame = sampler.frame(at: time) else { continue }
            framesRead += 1
            let size = nativeSize ?? CGSize(width: frame.width, height: frame.height)
            for face in facesOnImage(
                frame,
                pixelSize: size,
                file: file,
                options: options,
                detector: detector,
                embedder: embedder
            ) {
                if let embedding = face.embedding,
                   keptEmbeddings.contains(where: {
                       FaceEmbeddingMath.cosine($0, embedding) >= options.videoDuplicateCosine
                   }) {
                    continue
                }
                if let embedding = face.embedding { keptEmbeddings.append(embedding) }
                faces.append(face)
            }
        }

        let photo = FacePhotoRecord(
            pathKey: file.pathKey,
            path: file.path,
            fileName: file.name,
            byteCount: file.size,
            modifiedAt: file.modifiedAt,
            takenAt: item.captureDate,
            scanGrade: executedGrade(for: options.mode),
            faceCount: faces.count
        )
        guard (try? store.replaceFaces(photo: photo, faces: faces)) != nil else {
            return .failed
        }
        return .processed(faces: faces.count, videoFrames: framesRead)
    }

    // MARK: - Match and group

    /// XHIGH's gallery rebuild: every roster person's template set is
    /// re-picked from its confirmed faces — one face per photo, then a
    /// farthest-first spread so the kept set covers different views
    /// (front, side, glasses, years) rather than the top-N by score.
    /// Confirmed faces are the only trusted pool; proposals and grouped
    /// faces never seed templates.
    private func rebuildRosterTemplates() throws {
        for person in try store.rosterPeople() {
            let confirmed = try store.faces(personID: person.id)
                .filter { $0.state == .confirmed && $0.embedding != nil }
            var perPhoto: [String: FaceRecord] = [:]
            for face in confirmed {
                // `faces(personID:)` arrives detScore-sorted, so the first
                // sighting of a photo is its best face.
                if perPhoto[face.photoID] == nil { perPhoto[face.photoID] = face }
            }
            let picks = Self.diverseTemplatePick(
                perPhoto.values.sorted {
                    $0.detScore != $1.detScore
                        ? $0.detScore > $1.detScore
                        : $0.id.uuidString < $1.id.uuidString
                },
                cap: options.templateCap
            )
            try store.clearTemplates(personID: person.id)
            for pick in picks {
                try store.addTemplate(personID: person.id, faceID: pick.id)
            }
        }
    }

    /// Farthest-first selection: seed with the most confident face, then
    /// keep adding the candidate least similar to anything already picked.
    /// The kept set spans the person's appearance range instead of
    /// clustering around their clearest frontal shot.
    static func diverseTemplatePick(_ candidates: [FaceRecord], cap: Int) -> [FaceRecord] {
        guard cap > 0, !candidates.isEmpty else { return [] }
        var picked: [FaceRecord] = [candidates[0]]
        var remaining = Array(candidates.dropFirst())
        while picked.count < cap, !remaining.isEmpty {
            var bestIndex: Int?
            var bestDistance = -Float.infinity
            for (index, candidate) in remaining.enumerated() {
                guard let embedding = candidate.embedding else { continue }
                // Distance to the nearest already-picked template — the
                // new template should add a view, not repeat one.
                let nearest = picked.compactMap(\.embedding)
                    .map { FaceEmbeddingMath.cosine(embedding, $0) }
                    .max() ?? -1
                let distance = 1 - nearest
                if distance > bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            guard let bestIndex else { break }
            picked.append(remaining.remove(at: bestIndex))
        }
        return picked
    }

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
