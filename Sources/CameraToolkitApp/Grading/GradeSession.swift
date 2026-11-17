import AVFoundation
import CoreImage
import CameraToolkitCore
import Foundation
import Observation

/// How the grade panel shows the clip.
enum GradeViewMode: String, CaseIterable, Identifiable {
    case after
    case split
    case before

    var id: String { rawValue }

    var title: String {
        switch self {
        case .after: "Graded"
        case .split: "Split"
        case .before: "Original"
        }
    }
}

/// One clip open in the grade panel: the draft grade, what live playback
/// draws, the current frame, its histogram and the look thumbnails. Views
/// read it; it never touches the catalog itself — `commit` does, debounced,
/// so a slider drag is one Undo step.
@MainActor
@Observable
final class GradeSession {
    let itemID: String
    let clipName: String
    let profile: LogProfile?
    let detectedProfile: LogProfile?
    let range: VideoSignalRange
    let looks: [GradeLook]
    let lookName: (GradeLook) -> String
    /// The conversions this clip can use (empty for non-log video).
    let conversionChoices: [GradeConversion]
    let conversionName: (GradeConversion) -> String
    /// "Sony S-Log3 → Rec.709 · Built-in (Sony math)".
    let conversionTitle: (GradeRecipe) -> String
    /// The draft as drawn: profile, resolved conversion, range.
    @ObservationIgnored let resolve: (ClipGrade) -> GradeRecipe

    var draft: ClipGrade {
        didSet {
            guard draft != oldValue else { return }
            pushLive()
            scheduleCommit()
            scheduleDerived()
        }
    }

    var viewMode: GradeViewMode = .after {
        didSet { pushLive() }
    }

    /// 0…1 across the picture; left of it is the original.
    var wipe: Double = 0.5 {
        didSet { if viewMode == .split { pushLive() } }
    }

    /// The current frame as decoded (no grade), small.
    private(set) var frame: CGImage?
    private(set) var gradedFrame: CGImage?
    private(set) var histogram: GradeHistogram?
    private(set) var lookThumbnails: [GradeLook: CGImage] = [:]
    /// The draft was saved (or nothing changed since opening).
    private(set) var isSaved = true

    @ObservationIgnored let live: GradeLiveState
    @ObservationIgnored let renderer: GradeRenderer
    /// Persists the draft (debounced). Nil in previews.
    @ObservationIgnored var commit: ((ClipGrade) -> Void)?
    /// Asks the paused player to draw the current frame again.
    @ObservationIgnored var refreshPlayer: (() -> Void)?
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var derivedTask: Task<Void, Never>?

    init(
        itemID: String,
        clipName: String,
        grade: ClipGrade,
        profile: LogProfile?,
        detectedProfile: LogProfile?,
        range: VideoSignalRange,
        looks: [GradeLook],
        lookName: @escaping (GradeLook) -> String,
        conversionChoices: [GradeConversion] = [],
        conversionName: @escaping (GradeConversion) -> String = { _ in "" },
        conversionTitle: @escaping (GradeRecipe) -> String = { _ in "" },
        resolve: ((ClipGrade) -> GradeRecipe)? = nil,
        live: GradeLiveState = GradeLiveState(),
        renderer: GradeRenderer = .shared
    ) {
        self.itemID = itemID
        self.clipName = clipName
        self.draft = grade
        self.profile = profile
        self.detectedProfile = detectedProfile
        self.range = range
        self.looks = looks
        self.lookName = lookName
        self.conversionChoices = conversionChoices
        self.conversionName = conversionName
        self.conversionTitle = conversionTitle
        self.resolve = resolve ?? { grade in
            GradeRecipe(grade: grade, profile: grade.profileMark.resolve(detected: detectedProfile), range: range)
        }
        self.live = live
        self.renderer = renderer
        pushLive()
    }

    func recipe(for grade: ClipGrade) -> GradeRecipe { resolve(grade) }

    var recipe: GradeRecipe { recipe(for: draft) }

    var isConversionAvailable: Bool { renderer.pipeline(for: recipe).isConversionAvailable }
    var isLookAvailable: Bool { renderer.pipeline(for: recipe).isLookAvailable }
    /// A look can only go on a Rec.709 picture: log footage needs its
    /// conversion first.
    var canTakeLook: Bool { recipe.profile == nil || recipe.conversion.converts }
    var isLog: Bool { recipe.profile != nil }

    /// The one-line order of operations the panel shows.
    var orderLine: String {
        let r = recipe
        guard let profile = r.profile else { return "Rec.709 video: your look and adjustments go straight on top." }
        guard r.conversion.converts else { return "Shown as recorded (\(profile.shortName)). Looks need the conversion first." }
        let source: String = switch r.conversion {
        case .builtIn: "the built-in Sony math"
        case .lut: "\(profile.vendorName)’s conversion"
        case .none: ""
        }
        return "Converted from \(profile.shortName) with \(source), then your look on top."
    }

    func setConversion(_ conversion: GradeConversion) {
        var next = draft
        next.conversion = conversion
        draft = next
    }

    private func pushLive() {
        let recipe = recipe
        let mode = viewMode
        let wipe = wipe
        live.update { state in
            state.recipe = recipe.isIdentity ? nil : recipe
            state.bypass = mode == .before
            state.wipe = mode == .split ? wipe : nil
        }
        refreshPlayer?()
    }

    private func scheduleCommit() {
        isSaved = false
        commitTask?.cancel()
        commitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Saves the draft now (closing the panel, switching clips).
    func flush() {
        commitTask?.cancel()
        commitTask = nil
        guard !isSaved else { return }
        commit?(draft)
        isSaved = true
    }

    /// The catalog's grade changed under the panel (Undo, Paste): show it.
    func adopt(_ grade: ClipGrade) {
        guard isSaved, grade != draft else { return }
        draft = grade
        commitTask?.cancel()
        isSaved = true
    }

    func choose(_ look: GradeLook) {
        guard canTakeLook || look == .none else { return }
        var next = draft
        if next.look != look { next.intensity = look.defaultIntensity }
        next.look = look
        draft = next
    }

    func resetControls() {
        var next = draft
        next.exposure = 0
        next.temperature = 0
        next.tint = 0
        next.contrast = 0
        next.saturation = 0
        next.intensity = next.look.defaultIntensity
        draft = next
    }

    // MARK: Frame, histogram, thumbnails

    /// A new frame from the player (scrub, pause, a tick during playback).
    func setFrame(_ image: CGImage) {
        frame = image
        scheduleDerived()
    }

    private func scheduleDerived() {
        guard let frame else { return }
        derivedTask?.cancel()
        let draft = self.draft
        let looks = self.looks
        let renderer = self.renderer
        let recipe = recipe(for: draft)
        let lookRecipes = looks.map { look -> (GradeLook, GradeRecipe) in
            var grade = draft
            if grade.look != look { grade.intensity = look.defaultIntensity }
            grade.look = look
            return (look, self.recipe(for: grade))
        }
        // Thumbnails follow the draft's controls, so each look is shown
        // the way choosing it would look.
        let wantsThumbnails = true
        derivedTask = Task { @MainActor [weak self] in
            // Settle slider bursts into one render.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (CGImage?, GradeHistogram?, [GradeLook: CGImage]) in
                let graded = recipe.isIdentity ? frame : renderer.grade(frame, recipe: recipe)
                let histogram = graded.map { GradeRenderer.histogram(of: $0) }
                var thumbs: [GradeLook: CGImage] = [:]
                if wantsThumbnails {
                    let small = Self.downscaled(frame, maxWidth: 360) ?? frame
                    for (look, lookRecipe) in lookRecipes {
                        thumbs[look] = lookRecipe.isIdentity ? small : renderer.grade(small, recipe: lookRecipe)
                    }
                }
                return (graded, histogram, thumbs)
            }.value
            guard let self, !Task.isCancelled else { return }
            gradedFrame = result.0
            histogram = result.1
            if wantsThumbnails { lookThumbnails = result.2 }
        }
    }

    nonisolated static func downscaled(_ image: CGImage, maxWidth: Int) -> CGImage? {
        guard image.width > maxWidth else { return image }
        let scale = Double(maxWidth) / Double(image.width)
        let ci = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return GradeRenderer.shared.context.createCGImage(ci, from: ci.extent.integral, format: .RGBA16, colorSpace: nil)?
            .copy(colorSpace: image.colorSpace ?? GradeRenderer.outputColorSpace)
    }
}

/// Grabs small frames from a clip for the grade panel, one at a time.
final class GradeFrameGrabber: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private let lock = NSLock()
    private var busy = false

    init(url: URL, maximumWidth: CGFloat = 960) {
        generator = AVAssetImageGenerator(asset: CameraVideoAsset.asset(for: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumWidth, height: maximumWidth)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
    }

    /// The frame at `time`, or nil when a grab is already running.
    func frame(at time: CMTime) async -> CGImage? {
        let start = lock.withLock { () -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard start else { return nil }
        defer { lock.withLock { busy = false } }
        // The grade reads code values: never let a BT.2020 tag colour-match them.
        return (try? await generator.image(at: time).image).map(GradeRenderer.codeValues(ofDecodedFrame:))
    }
}
