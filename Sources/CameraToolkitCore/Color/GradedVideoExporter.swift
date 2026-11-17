import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

/// One graded copy to render.
public struct GradedRenderRequest: Sendable {
    public var source: URL
    public var recipe: GradeRecipe
    /// The original's identity (`DisplayRotation.fileKey`), written into
    /// the copy so a later render can tell it made this exact file.
    public var sourceKey: String
    /// The original's modification time; the copy gets the same one so it
    /// sorts beside it.
    public var sourceModifiedAt: Date
    /// `<event>/Edited/Rec709`.
    public var outputFolder: URL
    public var make: String?
    public var model: String?
    /// The NAS mirror of `outputFolder` when the copy is written on the
    /// drive: a copy Sync already carried there counts as rendered, and its
    /// name is never reused for a different render (Sync would conflict).
    public var mirrorFolder: URL?
    /// A second render step after the grade (post stabilization). Nil — the
    /// default — renders the grade alone, as before; this exporter does not
    /// read it yet.
    public var stabilization: RenderStabilization?

    public init(source: URL, recipe: GradeRecipe, sourceKey: String, sourceModifiedAt: Date, outputFolder: URL, make: String? = nil, model: String? = nil, mirrorFolder: URL? = nil, stabilization: RenderStabilization? = nil) {
        self.mirrorFolder = mirrorFolder
        self.stabilization = stabilization
        self.source = source
        self.recipe = recipe
        self.sourceKey = sourceKey
        self.sourceModifiedAt = sourceModifiedAt
        self.outputFolder = outputFolder
        self.make = make
        self.model = model
    }
}

/// The settings of an optional post-stabilization step in a render. A
/// placeholder the stabilizer fills in: requests carry it, nothing reads it
/// yet.
public struct RenderStabilization: Codable, Hashable, Sendable {
    /// The stabilizer's preset or profile name.
    public var preset: String

    public init(preset: String = "default") {
        self.preset = preset
    }
}

public enum GradedRenderOutcome: Equatable, Sendable {
    /// `beside`: older copies of the same original (another grade) that
    /// took the earlier names. They are kept, never replaced.
    case rendered(URL, beside: [URL])
    /// A copy with the same original and the same grade is already there
    /// (on the drive, or on the NAS mirror).
    case alreadyRendered(URL)

    public var url: URL {
        switch self {
        case .rendered(let url, _), .alreadyRendered(let url): url
        }
    }
}

/// What a taken name holds, as far as its tags say.
public enum GradedRenderIdentity: Equatable, Sendable {
    /// This original with this grade.
    case same
    /// This original with another grade.
    case olderGrade
    /// Something else (another file, no tags).
    case other
    /// The tags could not be read in time: not known, so nothing is
    /// rendered beside it (a duplicate would be the likely result).
    case unknown
}

/// Where graded copies go and what they are called. A copy never replaces
/// a file: an existing name that is not this exact render moves the new
/// copy on to `… (2)`, `… (3)`.
public enum GradedRenderNaming {
    /// The edit tag folder under an event's `Edited/`.
    public static let folderName = "Rec709"
    public static let suffix = "_709"
    public static let fileExtension = "mov"
    /// Partial renders live here until they are verified and renamed in.
    /// Sync, the edit-tag scan and `DefaultExcludes` all skip it, and the
    /// partial's name carries Sync's own temporary marker as well.
    public static let temporaryFolderName = NASSyncPlanner.temporaryItemsFolder
    /// `<UUID>.ctsync-render.partial.mov`.
    public static let partialSuffix = NASSyncPlanner.temporaryMarker + "render.partial.mov"

    public static func partialName() -> String { UUID().uuidString + partialSuffix }

    /// True only for a name this exporter gives a partial — or the scratch
    /// copy AVAssetWriter's fast-start pass makes beside it
    /// (`<partial>.sb-<random>`).
    public static func isPartialName(_ name: String) -> Bool {
        var base = name
        if let scratch = name.range(of: partialSuffix + ".sb-") {
            base = String(name[..<scratch.lowerBound]) + partialSuffix
        }
        guard base.hasSuffix(partialSuffix) else { return false }
        return UUID(uuidString: String(base.dropLast(partialSuffix.count))) != nil
    }

    /// Deletes partials a crashed or stopped render left in `outputFolder`'s
    /// temporary folder — only files with this exporter's exact partial
    /// name — then removes the folder if that left it empty. Returns how
    /// many were removed. Renders run one at a time under the job gate, so
    /// any partial found at the start of a render is stale.
    @discardableResult
    public static func removeStalePartials(in outputFolder: URL) -> Int {
        let folder = outputFolder.appendingPathComponent(temporaryFolderName, isDirectory: true).path
        guard LayoutMigrationDisk.lstatEntry(folder)?.kind == .directory,
              let entries = try? DirectoryListing.list(folder) else { return 0 }
        var removed = 0
        for entry in entries where entry.kind == .file && isPartialName(entry.name) {
            if unlink((folder as NSString).appendingPathComponent(entry.name)) == 0 { removed += 1 }
        }
        _ = rmdir(folder) // Only when empty; anything else stays.
        return removed
    }

    public static func outputFolder(editedRoot: URL) -> URL {
        editedRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    /// `C0001.MP4` → `C0001_709.mov`, then `C0001_709 (2).mov`, …
    public static func candidateName(forSource source: URL, attempt: Int) -> String {
        let stem = source.deletingPathExtension().lastPathComponent
        return attempt <= 1
            ? "\(stem)\(suffix).\(fileExtension)"
            : "\(stem)\(suffix) (\(attempt)).\(fileExtension)"
    }

    public enum Resolution: Equatable, Sendable {
        /// Render to `url`; `beside` are older copies of the same original.
        case free(URL, beside: [URL])
        /// This exact render is already at `url`.
        case alreadyRendered(URL)
        /// A taken name's tags could not be read: nothing is decided.
        case undecided(URL)
        case exhausted
    }

    /// The first name free in `folder` and in `mirror` (the NAS copy of the
    /// folder, when there is one), or where this exact render already is.
    /// `exists` answers whether a path is taken; `identity` what it holds.
    public static func resolve(
        source: URL,
        folder: URL,
        mirror: URL? = nil,
        exists: (URL) -> Bool,
        identity: (URL) -> GradedRenderIdentity,
        maximumAttempts: Int = 999
    ) -> Resolution {
        var beside: [URL] = []
        for attempt in 1...maximumAttempts {
            let name = candidateName(forSource: source, attempt: attempt)
            let local = folder.appendingPathComponent(name, isDirectory: false)
            let remote = mirror?.appendingPathComponent(name, isDirectory: false)
            let taken = [local, remote].compactMap { $0 }.filter(exists)
            guard !taken.isEmpty else { return .free(local, beside: beside) }
            var older = false
            for url in taken {
                switch identity(url) {
                case .same: return .alreadyRendered(url)
                case .unknown: return .undecided(url)
                case .olderGrade: older = true
                case .other: break
                }
            }
            if older { beside.append(taken[0]) }
        }
        return .exhausted
    }

    /// True for a file this app rendered (so it is never treated as a log
    /// original, even when someone copies a sidecar next to it).
    public static func isGradedCopy(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.hasSuffix(suffix) || stem.range(of: #"_709 \(\d+\)$"#, options: .regularExpression) != nil
    }
}

/// Renders graded copies: hardware HEVC (VideoToolbox) Main 10, Rec.709
/// tagged, same size and frame rate, audio passed through untouched,
/// capture date and camera kept. Writes a partial file, checks it plays,
/// then renames it into place without replacing anything.
public final class GradedVideoExporter: @unchecked Sendable {
    public static let metadataGradeKey = "org.cameratoolkit.grade"
    public static let metadataSourceKey = "org.cameratoolkit.source"

    public let renderer: GradeRenderer
    /// Test seam: lets a test run on machines without a hardware encoder.
    public var requireHardwareEncoder = true

    public init(renderer: GradeRenderer = .shared) {
        self.renderer = renderer
    }

    public struct Progress: Sendable {
        public var fraction: Double
        public var framesWritten: Int
    }

    public func render(
        _ request: GradedRenderRequest,
        progress: @escaping @Sendable (Progress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> GradedRenderOutcome {
        let fileManager = FileManager.default
        let folder = request.outputFolder
        GradedRenderNaming.removeStalePartials(in: folder)
        let target: URL
        let beside: [URL]
        switch GradedRenderNaming.resolve(
            source: request.source,
            folder: folder,
            mirror: request.mirrorFolder,
            exists: { DriveMoveService.exists($0.path) },
            identity: { Self.identity(at: $0, of: request) }
        ) {
        case .free(let url, let older):
            target = url
            beside = older
        case .alreadyRendered(let url):
            return .alreadyRendered(url)
        case .undecided(let url):
            throw ToolkitError.commandFailed("Could not read \(url.lastPathComponent) in time to tell whether it is this render, so no second copy was made. Try again once the drive or NAS answers.")
        case .exhausted:
            throw ToolkitError.commandFailed("Every name for a graded copy of \(request.source.lastPathComponent) is taken.")
        }

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporaryFolder = folder.appendingPathComponent(GradedRenderNaming.temporaryFolderName, isDirectory: true)
        try fileManager.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
        let partial = temporaryFolder.appendingPathComponent(GradedRenderNaming.partialName(), isDirectory: false)
        defer {
            // Only the partial this call made, by its exact path; the
            // folder only when that leaves it empty.
            if DriveMoveService.exists(partial.path) { _ = unlink(partial.path) }
            // AVAssetWriter's fast-start pass leaves its scratch copy
            // (`<partial>.sb-…`) until the writer goes away; it is ours, by
            // name, so it goes too. Then the folder, only if empty.
            if let entries = try? DirectoryListing.list(temporaryFolder.path) {
                for entry in entries where entry.kind == .file && entry.name.hasPrefix(partial.lastPathComponent + ".sb-") {
                    _ = unlink(temporaryFolder.appendingPathComponent(entry.name).path)
                }
            }
            _ = rmdir(temporaryFolder.path)
        }

        try write(request, to: partial, progress: progress, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        try verify(partial, against: request.source)
        try? fileManager.setAttributes(
            [.modificationDate: request.sourceModifiedAt, .creationDate: request.sourceModifiedAt],
            ofItemAtPath: partial.path
        )
        // The claimed-name rename never replaces a file, on smbfs and exFAT
        // too, where a plain rename would.
        try NASFileIO.renameExclusive(from: partial.path, to: target.path)
        return .rendered(target, beside: beside)
    }

    // MARK: Identity

    /// What the file at `url` is, compared with this request.
    public static func identity(at url: URL, of request: GradedRenderRequest, timeout: TimeInterval = 20) -> GradedRenderIdentity {
        guard let tags = readTags(url, timeout: timeout) else { return .unknown }
        guard tags.source == request.sourceKey else { return .other }
        guard let fingerprint = renderFingerprint(of: request, timeout: timeout) else { return .unknown }
        return tags.grade == fingerprint ? .same : .olderGrade
    }

    /// The grade tag a copy of `request` carries
    /// (`GradeRecipe.renderFingerprint`), or nil when the original's colour
    /// tags could not be read within `timeout`.
    public static func renderFingerprint(of request: GradedRenderRequest, timeout: TimeInterval = 20) -> String? {
        guard let colour = sourceColourTags(request.source, timeout: timeout) else { return nil }
        return request.recipe.renderFingerprint(sourcePrimaries: colour.primaries, sourceTransfer: colour.transfer)
    }

    /// The original's video colour primaries and transfer tags (nil inside
    /// when untagged or unreadable); nil when nothing answered in time.
    static func sourceColourTags(_ url: URL, timeout: TimeInterval) -> (primaries: String?, transfer: String?)? {
        let asset = CameraVideoAsset.asset(for: url)
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var primaries: String?; var transfer: String? }
        let box = Box()
        Task.detached {
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let description = try? await track.load(.formatDescriptions).first {
                box.primaries = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
                box.transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return (box.primaries, box.transfer)
    }

    /// The copy's grade and source tags; nil when they could not be read
    /// within `timeout` (a sleeping NAS, say). A file without tags reads
    /// as two nils, which is an answer: not ours.
    public static func readTags(_ url: URL, timeout: TimeInterval = 20) -> (grade: String?, source: String?)? {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var grade: String?; var source: String? }
        let box = Box()
        Task.detached {
            if let items = try? await asset.loadMetadata(for: .quickTimeMetadata) {
                for item in items {
                    guard let key = item.key as? String else { continue }
                    let value = try? await item.load(.stringValue)
                    if key == metadataGradeKey { box.grade = value }
                    if key == metadataSourceKey { box.source = value }
                }
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return (box.grade, box.source)
    }

    /// Whether this exact render already exists (drive or NAS mirror),
    /// without rendering — what the before-sync count uses.
    public static func existingRender(of request: GradedRenderRequest) -> URL? {
        if case .found(let url) = existingRenderCheck(of: request) { return url }
        return nil
    }

    public enum ExistingRenderCheck: Equatable, Sendable {
        case found(URL)
        case none
        /// A taken name's tags did not answer within the timeout.
        case unknown
    }

    public static func existingRenderCheck(of request: GradedRenderRequest, timeout: TimeInterval = 20) -> ExistingRenderCheck {
        switch GradedRenderNaming.resolve(
            source: request.source, folder: request.outputFolder, mirror: request.mirrorFolder,
            exists: { DriveMoveService.exists($0.path) }, identity: { identity(at: $0, of: request, timeout: timeout) }
        ) {
        case .alreadyRendered(let url): .found(url)
        case .undecided: .unknown
        case .free, .exhausted: .none
        }
    }

    /// Free bytes on the volume `url` is on (or would be, walking up to the
    /// nearest folder that exists); nil when the volume does not say.
    public static func availableBytes(near url: URL) -> Int64? {
        var folder = url
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder.deleteLastPathComponent()
        }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// About how many bytes the copy will take: the target video bit rate
    /// plus the original's audio, over the clip's length.
    public static func estimatedBytes(of source: URL) -> Int64? {
        let estimate: Int64?? = try? blocking {
            let asset = CameraVideoAsset.asset(for: source)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { return nil }
            var audioRate: Float = 0
            for track in try await asset.loadTracks(withMediaType: .audio) { audioRate += try await track.load(.estimatedDataRate) }
            let videoRate = try await asset.loadTracks(withMediaType: .video).first?.load(.estimatedDataRate) ?? 0
            let bits = (Double(bitRate(sourceDataRate: Double(videoRate))) + Double(audioRate)) * duration
            return Int64(bits / 8 * 1.03)
        }
        return estimate ?? nil
    }

    // MARK: Writing

    private struct Sendables: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let videoOutput: AVAssetReaderVideoCompositionOutput
        let videoInput: AVAssetWriterInput
        let audio: [(AVAssetReaderTrackOutput, AVAssetWriterInput)]
    }

    private func write(
        _ request: GradedRenderRequest,
        to url: URL,
        progress: @escaping @Sendable (Progress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        let asset = CameraVideoAsset.asset(for: request.source)
        let loaded = try Self.blocking {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let video = videoTracks.first else { throw ToolkitError.commandFailed("\(request.source.lastPathComponent) has no video track.") }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            let rate = try await video.load(.estimatedDataRate)
            let fps = try await video.load(.nominalFrameRate)
            var audioHints: [CMFormatDescription?] = []
            for track in audioTracks { audioHints.append(try await track.load(.formatDescriptions).first) }
            let live = GradeLiveState(recipe: request.recipe)
            let composition = try await self.renderer.videoComposition(for: asset, live: live, cubeSize: GradeRenderer.renderCubeSize)
            return LoadedSource(video: video, audio: audioTracks, audioHints: audioHints, duration: duration, dataRate: rate, fps: fps, composition: composition)
        }

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [loaded.video],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
        )
        videoOutput.videoComposition = loaded.composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ToolkitError.commandFailed("Could not read the video of \(request.source.lastPathComponent).") }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = metadata(for: request)
        let size = loaded.composition.renderSize
        let bitRate = Self.bitRate(sourceDataRate: Double(loaded.dataRate))
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                AVVideoExpectedSourceFrameRateKey: max(1, Int(loaded.fps.rounded())),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ] as [String: Any],
        ]
        if requireHardwareEncoder {
            videoSettings[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
            ]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = .identity
        guard writer.canAdd(videoInput) else { throw ToolkitError.commandFailed("The HEVC encoder refused the settings for \(request.source.lastPathComponent).") }
        writer.add(videoInput)

        var audio: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for (track, hint) in zip(loaded.audio, loaded.audioHints) {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { continue }
            reader.add(output)
            writer.add(input)
            audio.append((output, input))
        }

        guard reader.startReading() else {
            throw ToolkitError.commandFailed("Could not start reading \(request.source.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error").")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ToolkitError.commandFailed("Could not start the HEVC encoder: \(writer.error?.localizedDescription ?? "unknown error").")
        }
        writer.startSession(atSourceTime: .zero)

        let parts = Sendables(reader: reader, writer: writer, videoOutput: videoOutput, videoInput: videoInput, audio: audio)
        let group = DispatchGroup()
        let durationSeconds = max(loaded.duration.seconds, 0.001)
        final class Counter: @unchecked Sendable { var frames = 0; var cancelled = false }
        let counter = Counter()

        group.enter()
        let videoQueue = DispatchQueue(label: "CameraToolkit.GradedRender.video")
        parts.videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while parts.videoInput.isReadyForMoreMediaData {
                if counter.cancelled || isCancelled() {
                    counter.cancelled = true
                    parts.videoInput.markAsFinished()
                    group.leave()
                    return
                }
                guard let sample = parts.videoOutput.copyNextSampleBuffer() else {
                    parts.videoInput.markAsFinished()
                    group.leave()
                    return
                }
                if !parts.videoInput.append(sample) {
                    parts.videoInput.markAsFinished()
                    group.leave()
                    return
                }
                counter.frames += 1
                if counter.frames % 15 == 0 {
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    progress(Progress(fraction: min(1, max(0, time / durationSeconds)), framesWritten: counter.frames))
                }
            }
        }
        for (index, pair) in parts.audio.enumerated() {
            group.enter()
            let queue = DispatchQueue(label: "CameraToolkit.GradedRender.audio\(index)")
            pair.1.requestMediaDataWhenReady(on: queue) {
                while pair.1.isReadyForMoreMediaData {
                    guard !counter.cancelled, let sample = pair.0.copyNextSampleBuffer(), pair.1.append(sample) else {
                        pair.1.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        group.wait()

        if counter.cancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw ToolkitError.commandFailed("Reading \(request.source.lastPathComponent) failed: \(reader.error?.localizedDescription ?? "unknown error").")
        }
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw ToolkitError.commandFailed("Writing the graded copy failed: \(writer.error?.localizedDescription ?? "unknown error").")
        }
        progress(Progress(fraction: 1, framesWritten: counter.frames))
    }

    private struct LoadedSource: @unchecked Sendable {
        let video: AVAssetTrack
        let audio: [AVAssetTrack]
        let audioHints: [CMFormatDescription?]
        let duration: CMTime
        let dataRate: Float
        let fps: Float
        let composition: AVVideoComposition
    }

    /// 75% of the original's video data rate (4:2:0 carries less than the
    /// camera's 4:2:2), between 8 and 150 Mb/s.
    public static func bitRate(sourceDataRate: Double) -> Int {
        let target = sourceDataRate > 0 ? sourceDataRate * 0.75 : 40_000_000
        return Int(min(max(target, 8_000_000), 150_000_000))
    }

    private func metadata(for request: GradedRenderRequest) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: String) {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            items.append(item)
        }
        func addCustom(_ key: String, _ value: String) {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = key as NSString
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            items.append(item)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let created = Self.blockingCreationDate(of: request.source) ?? request.sourceModifiedAt
        add(.quickTimeMetadataCreationDate, formatter.string(from: created))
        // `©day` too: some readers look only at the user-data atom. The
        // movie header's own time is the render time; AVAssetWriter has no
        // way to set it, so these tags and the file's date carry the
        // capture time.
        add(.quickTimeUserDataCreationDate, formatter.string(from: created))
        if let make = request.make { add(.quickTimeMetadataMake, make) }
        if let model = request.model { add(.quickTimeMetadataModel, model) }
        add(.quickTimeMetadataSoftware, "Camera Toolkit")
        addCustom(Self.metadataGradeKey, Self.renderFingerprint(of: request) ?? request.recipe.fingerprint)
        addCustom(Self.metadataSourceKey, request.sourceKey)
        return items
    }

    static func blockingCreationDate(of url: URL) -> Date? {
        try? blocking {
            let asset = CameraVideoAsset.asset(for: url)
            return try await asset.load(.creationDate)?.load(.dateValue)
        }
    }

    // MARK: Verification

    /// The partial must open, have one video track, last as long as the
    /// original (within a frame or two), and decode a frame.
    public func verify(_ url: URL, against source: URL) throws {
        let ok: Bool = try Self.blocking {
            let copy = AVURLAsset(url: url)
            let original = CameraVideoAsset.asset(for: source)
            let tracks = try await copy.loadTracks(withMediaType: .video)
            guard tracks.count == 1, try await copy.load(.isPlayable) else { return false }
            let copyDuration = try await copy.load(.duration).seconds
            let originalDuration = try await original.load(.duration).seconds
            guard abs(copyDuration - originalDuration) <= 0.1 else { return false }
            let generator = AVAssetImageGenerator(asset: copy)
            generator.maximumSize = CGSize(width: 320, height: 320)
            let time = CMTime(seconds: min(0.5, copyDuration / 2), preferredTimescale: 600)
            _ = try await generator.image(at: time)
            return true
        }
        guard ok else {
            throw ToolkitError.commandFailed("The graded copy of \(source.lastPathComponent) did not check out (length or tracks differ). It was not kept.")
        }
    }

    // MARK: Blocking bridge

    private final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

    static func blocking<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }
}
