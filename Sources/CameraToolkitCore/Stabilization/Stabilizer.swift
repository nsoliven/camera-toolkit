import AVFoundation
import Foundation

/// Where stabilized copies go and what they are called. Like graded copies,
/// a stabilized copy never replaces a file: a taken name that is not this
/// exact render moves the new copy on to `… (2)`.
///
/// - A clip that is only stabilized gets `<event>/Edited/Stabilized/<name>_stab.mov`
///   (ProRes 422 HQ, still log when the clip was shot in log).
/// - A clip that is also graded gets one final file, `Edited/Rec709/<name>_709.mov`:
///   the stabilized ProRes is an intermediate in that folder's temporary
///   folder, graded from, then deleted (`StabilizedGradeChain`).
public enum StabilizedRenderNaming {
    public static let folderName = "Stabilized"
    public static let suffix = "_stab"
    public static let fileExtension = "mov"
    /// `<UUID>.ctsync-stab.partial.mov`: Sync, the edit-tag scan and the
    /// default excludes skip it, like a graded partial.
    public static let partialSuffix = NASSyncPlanner.temporaryMarker + "stab.partial.mov"
    /// What a stabilized copy's comment starts with; the rest names the
    /// original and the stabilization (`tag(sourceKey:settings:)`).
    public static let tagPrefix = "org.cameratoolkit.stab"

    public static func partialName() -> String { UUID().uuidString + partialSuffix }

    /// Gyroflow writes `<partial>.tmp` while it renders and renames it to
    /// the partial when done: both are this stabilizer's.
    public static let inProgressSuffix = ".tmp"

    public static func isPartialName(_ name: String) -> Bool {
        var base = name
        if base.hasSuffix(partialSuffix + inProgressSuffix) { base = String(base.dropLast(inProgressSuffix.count)) }
        guard base.hasSuffix(partialSuffix) else { return false }
        return UUID(uuidString: String(base.dropLast(partialSuffix.count))) != nil
    }

    public static func outputFolder(editedRoot: URL) -> URL {
        editedRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    public static func temporaryFolder(in folder: URL) -> URL {
        folder.appendingPathComponent(GradedRenderNaming.temporaryFolderName, isDirectory: true)
    }

    /// `C0001.MP4` → `C0001_stab.mov`, then `C0001_stab (2).mov`, …
    public static func candidateName(forSource source: URL, attempt: Int) -> String {
        let stem = source.deletingPathExtension().lastPathComponent
        return attempt <= 1 ? "\(stem)\(suffix).\(fileExtension)" : "\(stem)\(suffix) (\(attempt)).\(fileExtension)"
    }

    /// True for a file this app stabilized: never treated as an original.
    public static func isStabilizedCopy(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.hasSuffix(suffix) || stem.range(of: #"_stab \(\d+\)$"#, options: .regularExpression) != nil
    }

    public static func tag(sourceKey: String, settings: StabilizationSettings) -> String {
        "\(tagPrefix) source=\(sourceKey) stab=\(settings.fingerprint)"
    }

    /// Reads a tag back out of a comment (Gyroflow puts its own line first).
    public static func parseTag(_ comment: String) -> (source: String, stabilization: String)? {
        guard let start = comment.range(of: tagPrefix + " ") else { return nil }
        let line = comment[start.upperBound...].prefix { $0 != "\n" }
        var source: String?
        var stab: String?
        for part in line.split(separator: " ") {
            if part.hasPrefix("source=") { source = String(part.dropFirst("source=".count)) }
            if part.hasPrefix("stab=") { stab = String(part.dropFirst("stab=".count)) }
        }
        guard let source, let stab else { return nil }
        return (source, stab)
    }

    /// The first free name in `folder` (and `mirror`, the NAS copy of the
    /// folder), or where this exact stabilized copy already is.
    public static func resolve(
        source: URL,
        folder: URL,
        mirror: URL? = nil,
        exists: (URL) -> Bool,
        identity: (URL) -> GradedRenderIdentity,
        maximumAttempts: Int = 999
    ) -> GradedRenderNaming.Resolution {
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

    /// Deletes stabilizer partials (and its preset files) a crashed or
    /// stopped run left in `folder`'s temporary folder — only this
    /// stabilizer's exact names — then the folder if that emptied it.
    /// With `olderThan`, a partial written to since then is left alone (a
    /// run of this session may be writing it).
    @discardableResult
    public static func removeStalePartials(in folder: URL, olderThan: Date? = nil) -> Int {
        let temporary = temporaryFolder(in: folder).path
        guard LayoutMigrationDisk.lstatEntry(temporary)?.kind == .directory,
              let entries = try? DirectoryListing.list(temporary) else { return 0 }
        var removed = 0
        for entry in entries where entry.kind == .file && isPartialName(entry.name) {
            let path = (temporary as NSString).appendingPathComponent(entry.name)
            if let olderThan, let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               modified >= olderThan { continue }
            if unlink(path) == 0 { removed += 1 }
        }
        _ = rmdir(temporary)
        return removed
    }
}

/// One stabilized file to make.
public struct StabilizeRequest: Sendable {
    public var source: URL
    public var settings: StabilizationSettings
    /// The original's identity (`DisplayRotation.fileKey`), written into
    /// the copy's comment.
    public var sourceKey: String
    public var sourceModifiedAt: Date
    /// `<event>/Edited/Stabilized`.
    public var outputFolder: URL
    /// The NAS copy of `outputFolder` when the copy is written on the drive.
    public var mirrorFolder: URL?

    public init(source: URL, settings: StabilizationSettings, sourceKey: String, sourceModifiedAt: Date, outputFolder: URL, mirrorFolder: URL? = nil) {
        self.source = source
        self.settings = settings
        self.sourceKey = sourceKey
        self.sourceModifiedAt = sourceModifiedAt
        self.outputFolder = outputFolder
        self.mirrorFolder = mirrorFolder
    }
}

/// Stabilizes clips with an installed Gyroflow, headless: checks the clip
/// has motion data, writes a partial in the destination's temporary
/// folder, reports progress from Gyroflow's output, ends the run and
/// deletes the partial on Stop, checks the result plays and lasts as long
/// as it should, then renames it in without replacing anything.
public final class Stabilizer: @unchecked Sendable {
    public struct Progress: Equatable, Sendable {
        public enum Phase: String, Sendable { case starting, synchronizing, rendering }
        public var phase: Phase
        /// 0…1 over the whole run.
        public var fraction: Double
        public var frame: Int
        public var totalFrames: Int
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case unavailable(String)
        case noMotionData
        case gyroflow(String)
        case noOutput(String?)
        case verification(String)
        case nameTaken(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let line): line
            case .noMotionData: "No motion data in this file, so there is nothing to stabilize from."
            case .gyroflow(let message): GyroflowOutputLine.explain(message)
            case .noOutput(let message):
                message.map { "Gyroflow made no file: \(GyroflowOutputLine.explain($0))" } ?? "Gyroflow ended without making a file."
            case .verification(let line): line
            case .nameTaken(let line): line
            }
        }
    }

    public let installation: GyroflowInstallation
    public let runner: StabilizerProcessRunning
    /// After an `[ERROR]` line with no render under way, how long Gyroflow
    /// gets before the run is ended: its command line does not quit by
    /// itself after an error.
    public var errorGrace: TimeInterval
    /// After Gyroflow says the render completed, how long it gets to close
    /// its file and quit before it is ended.
    public var finishGrace: TimeInterval = 30
    /// Checks a finished partial (`verify(partial, expectedSeconds)`); a
    /// test seam. The default opens it with AVFoundation.
    public var verifier: @Sendable (URL, Double?) throws -> Void
    /// Answers "is there motion data"; a test seam.
    public var probe: @Sendable (URL) -> MotionDataAvailability
    /// Where the preset file for a run is written (local scratch).
    public var scratchFolder: URL

    public init(
        installation: GyroflowInstallation,
        runner: StabilizerProcessRunning = FoundationProcessRunner(),
        errorGrace: TimeInterval = 4,
        verifier: (@Sendable (URL, Double?) throws -> Void)? = nil,
        probe: @escaping @Sendable (URL) -> MotionDataAvailability = { MotionDataProbe.probe($0) },
        scratchFolder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("CameraToolkit-Stabilizer", isDirectory: true)
    ) {
        self.installation = installation
        self.runner = runner
        self.errorGrace = errorGrace
        self.verifier = verifier ?? { try Stabilizer.verifyPlayable($0, expectedSeconds: $1) }
        self.probe = probe
        self.scratchFolder = scratchFolder
    }

    // MARK: Whole-clip copies

    /// Makes `request`'s stabilized copy in `Edited/Stabilized`, or finds
    /// that this exact copy is already there.
    public func render(
        _ request: StabilizeRequest,
        progress: @escaping @Sendable (Progress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> GradedRenderOutcome {
        StabilizedRenderNaming.removeStalePartials(in: request.outputFolder)
        let target: URL
        let beside: [URL]
        switch StabilizedRenderNaming.resolve(
            source: request.source,
            folder: request.outputFolder,
            mirror: request.mirrorFolder,
            exists: { DriveMoveService.exists($0.path) },
            identity: { Self.identity(at: $0, sourceKey: request.sourceKey, settings: request.settings) }
        ) {
        case .free(let url, let older):
            target = url
            beside = older
        case .alreadyRendered(let url):
            return .alreadyRendered(url)
        case .undecided(let url):
            throw Failure.nameTaken("Could not read \(url.lastPathComponent) in time to tell whether it is this copy, so no second one was made.")
        case .exhausted:
            throw Failure.nameTaken("Every name for a stabilized copy of \(request.source.lastPathComponent) is taken.")
        }
        let partial = try stabilize(
            source: request.source,
            settings: request.settings,
            into: request.outputFolder,
            comment: StabilizedRenderNaming.tag(sourceKey: request.sourceKey, settings: request.settings),
            progress: progress,
            isCancelled: isCancelled
        )
        defer { Self.removePartial(partial) }
        try? FileManager.default.setAttributes(
            [.modificationDate: request.sourceModifiedAt, .creationDate: request.sourceModifiedAt],
            ofItemAtPath: partial.path
        )
        try NASFileIO.renameExclusive(from: partial.path, to: target.path)
        return .rendered(target, beside: beside)
    }

    /// Runs Gyroflow on `source` into a partial in `folder`'s temporary
    /// folder and returns it, checked. The caller renames or deletes it
    /// (`removePartial`). On Stop or failure nothing is left behind.
    public func stabilize(
        source: URL,
        settings: StabilizationSettings,
        into folder: URL,
        trim: ClosedRange<Double>? = nil,
        codec: StabilizedOutputCodec = .proResHQ,
        comment: String = "",
        progress: @escaping @Sendable (Progress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> URL {
        guard installation.canRunHeadless else {
            throw Failure.unavailable(StabilizerAvailability(installation).problem ?? "Gyroflow can’t run here.")
        }
        switch probe(source) {
        case .absent: throw Failure.noMotionData
        case .present, .unknown: break
        }
        if isCancelled() { throw CancellationError() }
        let fileManager = FileManager.default
        let temporary = StabilizedRenderNaming.temporaryFolder(in: folder)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        let partial = temporary.appendingPathComponent(StabilizedRenderNaming.partialName(), isDirectory: false)
        try fileManager.createDirectory(at: scratchFolder, withIntermediateDirectories: true)
        let presetFile = scratchFolder.appendingPathComponent(UUID().uuidString + ".gyroflow", isDirectory: false)
        let job = GyroflowJob(input: source, output: partial, settings: settings, trim: trim, codec: codec, comment: comment)
        try GyroflowCommand.presetData(for: job).write(to: presetFile, options: .atomic)
        var keep = false
        // Gyroflow should never write beside the source (the preset moves
        // the output); if it did, only the exact stray name a run made goes.
        let strays = GyroflowCommand.strayOutputs(beside: source)
        let strayBefore = Set(strays.filter { DriveMoveService.exists($0.path) }.map(\.path))
        defer {
            _ = unlink(presetFile.path)
            if !keep { Self.removePartial(partial) }
            for stray in strays where !strayBefore.contains(stray.path) && DriveMoveService.exists(stray.path) {
                _ = unlink(stray.path)
            }
        }

        final class RunState: @unchecked Sendable {
            let lock = NSLock()
            var lastError: String?
            var errorAt: Date?
            var rendering = false
            var completed = false
            var failed = false
            var doneAt: Date?
        }
        let state = RunState()
        let grace = errorGrace
        let finishGrace = self.finishGrace
        progress(Progress(phase: .starting, fraction: 0, frame: 0, totalFrames: 0))
        let outcome = try runner.run(
            executable: installation.executableURL,
            arguments: GyroflowCommand.arguments(input: source, presetFile: presetFile),
            onLine: { line in
                switch GyroflowOutputLine.parse(line) {
                case .synchronizing(let value):
                    progress(Progress(phase: .synchronizing, fraction: value * 0.1, frame: 0, totalFrames: 0))
                case .rendering(let frame, let total):
                    state.lock.withLock { state.rendering = true }
                    let fraction = total > 0 ? Double(frame) / Double(total) : 0
                    progress(Progress(phase: .rendering, fraction: 0.1 + 0.9 * min(1, fraction), frame: frame, totalFrames: total))
                case .completed:
                    state.lock.withLock { state.completed = true; state.doneAt = Date() }
                case .failed:
                    state.lock.withLock { state.failed = true; state.doneAt = Date() }
                case .error(let message):
                    state.lock.withLock {
                        if state.lastError == nil || !message.hasPrefix("file_exists") { state.lastError = message }
                        state.errorAt = Date()
                    }
                case .other:
                    break
                }
            },
            keepRunning: {
                if isCancelled() { return false }
                return state.lock.withLock {
                    // Gyroflow's CLI may sit in its event loop after a
                    // render (it is given time to close its file) or after
                    // an error with nothing rendering.
                    if let done = state.doneAt, Date().timeIntervalSince(done) > finishGrace { return false }
                    if let at = state.errorAt, !state.rendering, Date().timeIntervalSince(at) > grace { return false }
                    return true
                }
            }
        )
        if isCancelled() { throw CancellationError() }
        let (lastError, failed) = state.lock.withLock { (state.lastError, state.failed) }
        if failed { throw Failure.gyroflow(lastError ?? "Gyroflow reported the render failed.") }
        guard let size = (try? fileManager.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber, size.int64Value > 0 else {
            throw Failure.noOutput(lastError ?? (outcome.exitCode != 0 ? "exit code \(outcome.exitCode)" : nil))
        }
        let expected: Double? = trim.map { $0.upperBound - $0.lowerBound } ?? Self.duration(of: source)
        do {
            try verifier(partial, expected)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.verification("The stabilized copy of \(source.lastPathComponent) did not check out: \(error.localizedDescription)")
        }
        keep = true
        return partial
    }

    /// Deletes a partial this stabilizer made (by its exact name), then its
    /// temporary folder if that emptied it.
    public static func removePartial(_ partial: URL) {
        guard StabilizedRenderNaming.isPartialName(partial.lastPathComponent) else { return }
        if DriveMoveService.exists(partial.path) { _ = unlink(partial.path) }
        let inProgress = partial.path + StabilizedRenderNaming.inProgressSuffix
        if DriveMoveService.exists(inProgress) { _ = unlink(inProgress) }
        _ = rmdir(partial.deletingLastPathComponent().path)
    }

    // MARK: Identity

    /// What the file at `url` is, by the tag in its comment.
    public static func identity(at url: URL, sourceKey: String, settings: StabilizationSettings, timeout: TimeInterval = 20) -> GradedRenderIdentity {
        guard let comment = readComment(url, timeout: timeout) else { return .unknown }
        guard let tag = StabilizedRenderNaming.parseTag(comment), tag.source == sourceKey else { return .other }
        return tag.stabilization == settings.fingerprint ? .same : .olderGrade
    }

    /// The file's comment (empty when it has none); nil when it could not
    /// be read within `timeout`.
    public static func readComment(_ url: URL, timeout: TimeInterval = 20) -> String? {
        final class Box: @unchecked Sendable { var text = "" }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let asset = AVURLAsset(url: url)
            var texts: [String] = []
            for format in [AVMetadataFormat.quickTimeUserData, .quickTimeMetadata, .iTunesMetadata] {
                if let items = try? await asset.loadMetadata(for: format) {
                    for item in items {
                        if let value = try? await item.load(.stringValue) { texts.append(value) }
                    }
                }
            }
            box.text = texts.joined(separator: "\n")
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.text
    }

    // MARK: Checks

    /// About how many bytes Gyroflow writes for `source` in `codec`
    /// (Apple's ProRes target rates, scaled from 1080p30 by pixels and
    /// frame rate), plus PCM audio and a little container overhead.
    public static func estimatedBytes(of source: URL, codec: StabilizedOutputCodec = .proResHQ, trim: ClosedRange<Double>? = nil) -> Int64? {
        let facts: (CGSize, Float, Double)? = try? GradedVideoExporter.blocking {
            let asset = AVURLAsset(url: source)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            return (try await video.load(.naturalSize), try await video.load(.nominalFrameRate), try await asset.load(.duration).seconds)
        } ?? nil
        guard let (size, fps, duration) = facts else { return nil }
        let seconds = trim.map { $0.upperBound - $0.lowerBound } ?? duration
        return estimatedBytes(width: Double(size.width), height: Double(size.height), fps: Double(fps), seconds: seconds, codec: codec)
    }

    public static func estimatedBytes(width: Double, height: Double, fps: Double, seconds: Double, codec: StabilizedOutputCodec) -> Int64? {
        guard width > 0, height > 0, seconds.isFinite, seconds > 0 else { return nil }
        let rate = fps.isFinite && fps > 0 ? fps : 30
        let video = codec.megabitsAt1080p30 * 1_000_000 * (abs(width * height) / (1920 * 1080)) * (rate / 29.97)
        let audio = 1_536_000.0
        return Int64((video + audio) * seconds / 8 * 1.05)
    }

    public static func duration(of url: URL) -> Double? {
        try? GradedVideoExporter.blocking {
            let seconds = try await AVURLAsset(url: url).load(.duration).seconds
            return seconds.isFinite && seconds > 0 ? seconds : nil
        }
    }

    /// The file opens, has one video track, decodes a frame, and lasts
    /// `expectedSeconds` (within a few frames) when that is known.
    public static func verifyPlayable(_ url: URL, expectedSeconds: Double?) throws {
        let problem: String? = try GradedVideoExporter.blocking {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard tracks.count == 1 else { return "it has \(tracks.count) video tracks" }
            let duration = try await asset.load(.duration).seconds
            if let expectedSeconds, abs(duration - expectedSeconds) > 0.25 {
                return String(format: "it lasts %.2f s, not %.2f s", duration, expectedSeconds)
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 320, height: 320)
            _ = try await generator.image(at: CMTime(seconds: min(0.5, duration / 2), preferredTimescale: 600))
            return nil
        }
        if let problem { throw Failure.verification("The stabilized copy did not check out: \(problem). It was not kept.") }
    }
}
