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

    public init(source: URL, recipe: GradeRecipe, sourceKey: String, sourceModifiedAt: Date, outputFolder: URL, make: String? = nil, model: String? = nil) {
        self.source = source
        self.recipe = recipe
        self.sourceKey = sourceKey
        self.sourceModifiedAt = sourceModifiedAt
        self.outputFolder = outputFolder
        self.make = make
        self.model = model
    }
}

public enum GradedRenderOutcome: Equatable, Sendable {
    case rendered(URL)
    /// A copy with the same original and the same grade is already there.
    case alreadyRendered(URL)

    public var url: URL {
        switch self {
        case .rendered(let url), .alreadyRendered(let url): url
        }
    }
}

/// Where graded copies go and what they are called. A copy never replaces
/// a file: an existing name that is not this exact render moves the new
/// copy on to `… (2)`, `… (3)`.
public enum GradedRenderNaming {
    /// The edit tag folder under an event's `Edited/`.
    public static let folderName = "Rec709"
    public static let suffix = "_709"
    public static let fileExtension = "mov"
    /// Partial renders live here until they are verified and renamed in;
    /// `.TemporaryItems` is excluded from every scan and sync.
    public static let temporaryFolderName = ".TemporaryItems"

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

    /// The first name that is free, or the name of an identical render
    /// already there. `existing` answers whether a path is taken, and
    /// `isSameRender` whether a taken path is this exact render.
    public static func resolve(
        source: URL,
        folder: URL,
        exists: (URL) -> Bool,
        isSameRender: (URL) -> Bool,
        maximumAttempts: Int = 999
    ) -> (url: URL, alreadyRendered: Bool)? {
        for attempt in 1...maximumAttempts {
            let url = folder.appendingPathComponent(candidateName(forSource: source, attempt: attempt), isDirectory: false)
            guard exists(url) else { return (url, false) }
            if isSameRender(url) { return (url, true) }
        }
        return nil
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
        guard let target = GradedRenderNaming.resolve(
            source: request.source,
            folder: folder,
            exists: { DriveMoveService.exists($0.path) },
            isSameRender: { Self.isRender(at: $0, of: request) }
        ) else {
            throw ToolkitError.commandFailed("Every name for a graded copy of \(request.source.lastPathComponent) is taken.")
        }
        if target.alreadyRendered { return .alreadyRendered(target.url) }

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporaryFolder = folder.appendingPathComponent(GradedRenderNaming.temporaryFolderName, isDirectory: true)
        try fileManager.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
        let partial = temporaryFolder.appendingPathComponent("\(UUID().uuidString).partial.mov", isDirectory: false)
        defer {
            // Only the partial this call made; never anything else.
            if DriveMoveService.exists(partial.path) { try? fileManager.removeItem(at: partial) }
            try? fileManager.removeItem(at: temporaryFolder) // only succeeds when empty
        }

        try write(request, to: partial, progress: progress, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        try verify(partial, against: request.source)
        try? fileManager.setAttributes(
            [.modificationDate: request.sourceModifiedAt, .creationDate: request.sourceModifiedAt],
            ofItemAtPath: partial.path
        )
        try DriveMoveService.renameExclusive(from: partial.path, to: target.url.path)
        return .rendered(target.url)
    }

    // MARK: Identity

    /// Whether the file at `url` is a copy of this original with this grade.
    public static func isRender(at url: URL, of request: GradedRenderRequest) -> Bool {
        let tags = readTags(url)
        return tags.grade == request.recipe.fingerprint && tags.source == request.sourceKey
    }

    public static func readTags(_ url: URL) -> (grade: String?, source: String?) {
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
        _ = semaphore.wait(timeout: .now() + 20)
        return (box.grade, box.source)
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
        addCustom(Self.metadataGradeKey, request.recipe.fingerprint)
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
