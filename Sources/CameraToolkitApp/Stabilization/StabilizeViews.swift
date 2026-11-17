import AVFoundation
import AVKit
import AppKit
import CameraToolkitCore
import CryptoKit
import SwiftUI

// MARK: - Viewer panel

/// The Stabilize section of the full-size viewer's grade panel: a toggle,
/// Low / Medium / High, the motion-data line, Preview 3 s, and (for a clip
/// with no grade) Render Stabilized Copy. With a grade, Render Graded Copy
/// stabilizes too.
struct StabilizePanel: View {
    let stabilizing: ClipStabilizing
    let item: OrganizeItem
    let stack: OrganizeStack
    let boardEventID: UUID?
    /// The playhead, for the preview.
    let currentTime: () -> Double
    /// True when the clip also has a grade to render.
    let isGraded: Bool

    var body: some View {
        let settings = stabilizing.settings(for: item)
        let motion = stabilizing.motionData(for: item)
        let available = stabilizing.availability
        let canStabilize = motion?.isPresent ?? false || (motion.map { if case .unknown = $0 { return true } else { return false } } ?? false)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "gyroscope").foregroundStyle(.secondary)
                Text("Stabilize").font(.headline)
                Spacer()
                Toggle("Stabilize", isOn: Binding(
                    get: { settings != nil },
                    set: { on in
                        stabilizing.setStabilization(on ? StabilizationSettings(smoothing: stabilizing.lastSmoothing) : nil, for: [item])
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled((!canStabilize || !available.isReady) && settings == nil)
                .help(canStabilize ? "Stabilize this clip from its motion data when it is rendered" : (motion?.problem ?? "Looking for motion data…"))
            }
            Picker("Smoothing", selection: Binding(
                get: { settings?.smoothing ?? stabilizing.lastSmoothing },
                set: { smoothing in
                    var next = settings ?? StabilizationSettings()
                    next.smoothing = smoothing
                    stabilizing.setStabilization(next, for: [item], undoTitle: "Stabilize: \(smoothing.displayName)")
                }
            )) {
                ForEach(StabilizationSmoothing.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(settings == nil)

            Label(StabilizeWording.motionLine(motion), systemImage: motion?.isPresent ?? false ? "checkmark.circle" : "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem = available.problem {
                VStack(alignment: .leading, spacing: 4) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Link("Get Gyroflow (free)", destination: GyroflowInstallation.downloadPage)
                        Button("Check Again") { stabilizing.refreshAvailability() }
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                }
            }

            HStack(spacing: 8) {
                Button("Preview 3 s", systemImage: "play.square.stack") {
                    stabilizing.startPreview(for: item, at: currentTime())
                }
                .help("Stabilizes 3 seconds around the playhead and plays it beside the original")
                .disabled(settings == nil || !available.isReady)
                if !isGraded {
                    Button("Render Stabilized Copy", systemImage: "square.and.arrow.down.on.square") {
                        stabilizing.renderStabilizedCopies(of: [item], in: [stack], boardEventID: boardEventID)
                    }
                    .disabled(settings == nil || !available.isReady)
                    .help("Writes \(StabilizedRenderNaming.candidateName(forSource: item.primary.url, attempt: 1)) into the event’s Edited/\(StabilizedRenderNaming.folderName). The original is never changed.")
                }
            }
            .controlSize(.small)
            if settings != nil, isGraded {
                Text("Render Graded Copy stabilizes first (on the log footage), then grades — one file in Edited/\(GradedRenderNaming.folderName).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .sheet(isPresented: Binding(
            get: { stabilizing.preview?.itemID == item.id },
            set: { if !$0 { stabilizing.closePreview() } }
        )) {
            if let preview = stabilizing.preview {
                StabilizePreviewSheet(model: preview, onClose: { stabilizing.closePreview() })
            }
        }
    }
}

// MARK: - Preview 3 s

/// A short stabilized segment around the playhead, shown beside the
/// original. Rendered small (ProRes Proxy) into Caches; the last few are
/// kept, older ones deleted.
@MainActor
@Observable
final class StabilizePreviewModel: Identifiable {
    enum Stage: Equatable {
        case rendering(String)
        case ready(stabilized: URL)
        case failed(String)
    }

    let id = UUID()
    let itemID: String
    let source: URL
    let name: String
    let range: ClosedRange<Double>
    let recipe: GradeRecipe?
    var stage: Stage = .rendering("Starting Gyroflow…")
    var sideBySide = true
    @ObservationIgnored let stop = RenderStopFlag()

    init(itemID: String, source: URL, name: String, range: ClosedRange<Double>, recipe: GradeRecipe?) {
        self.itemID = itemID
        self.source = source
        self.name = name
        self.range = range
        self.recipe = recipe
    }
}

extension ClipStabilizing {
    nonisolated static let previewSeconds = 3.0
    nonisolated static let previewsKept = 6

    /// A 3-second window around `time`, inside the clip.
    nonisolated static func previewRange(around time: Double, duration: Double?) -> ClosedRange<Double> {
        let length = previewSeconds
        guard let duration, duration > 0 else { return max(0, time - 1)...(max(0, time - 1) + length) }
        if duration <= length { return 0...duration }
        let start = min(max(0, time - length / 2), duration - length)
        return start...(start + length)
    }

    static var previewFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("CameraToolkit/StabilizePreviews", isDirectory: true)
    }

    func startPreview(for item: OrganizeItem, at time: Double) {
        guard let settings = settings(for: item), let stabilizer = makeStabilizer() else {
            model.statusMessage = availability.problem ?? "Turn Stabilize on first."
            return
        }
        preview?.stop.stop()
        let source = item.primary.url
        let duration = Stabilizer.duration(of: source)
        let range = Self.previewRange(around: time, duration: duration)
        let recipe = grading.recipe(for: item)
        let preview = StabilizePreviewModel(itemID: item.id, source: source, name: item.primary.name, range: range, recipe: recipe.flatMap { $0.isIdentity ? nil : $0 })
        self.preview = preview
        let key = Self.fileKey(item)
        let folder = Self.previewFolder
        let digest = SHA256.hash(data: Data((key + settings.fingerprint).utf8)).map { String(format: "%02x", $0) }.joined()
        let name = "\(digest.prefix(12))-\(Int(range.lowerBound * 1000)).mov"
        let target = folder.appendingPathComponent(name, isDirectory: false)
        if FileManager.default.fileExists(atPath: target.path) {
            preview.stage = .ready(stabilized: target)
            return
        }
        let stop = preview.stop
        Task { @MainActor in
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let partial = try stabilizer.stabilize(
                        source: source, settings: settings, into: folder, trim: range, codec: .proResProxy,
                        progress: { step in
                            Task { @MainActor in preview.stage = .rendering("Stabilizing 3 seconds · \(StabilizeWording.phase(step))") }
                        },
                        isCancelled: { stop.isStopped }
                    )
                    defer { Stabilizer.removePartial(partial) }
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: partial, to: target)
                    Self.prunePreviews(in: folder, keeping: Self.previewsKept)
                    return target
                }
            }.value
            switch result {
            case .success(let url): preview.stage = .ready(stabilized: url)
            case .failure(let error):
                preview.stage = error is CancellationError ? .failed("Stopped.") : .failed(error.localizedDescription)
            }
        }
    }

    func closePreview() {
        preview?.stop.stop()
        preview = nil
    }

    /// Keeps the newest `keeping` previews; deletes the rest (cache only).
    nonisolated static func prunePreviews(in folder: URL, keeping: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let movies = files.filter { $0.pathExtension == "mov" }.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b
        }
        for old in movies.dropFirst(keeping) { try? FileManager.default.removeItem(at: old) }
    }
}

struct StabilizePreviewSheet: View {
    @Bindable var model: StabilizePreviewModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Stabilize Preview").font(.title3.weight(.semibold))
                Text(model.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if case .ready = model.stage {
                    Picker("Show", selection: $model.sideBySide) {
                        Text("Side by Side").tag(true)
                        Text("Stabilized Only").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            switch model.stage {
            case .rendering(let line):
                VStack(spacing: 10) {
                    ProgressView()
                    Text(line).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            case .failed(let line):
                ContentUnavailableView("No Preview", systemImage: "exclamationmark.triangle", description: Text(line))
                    .frame(maxWidth: .infinity, minHeight: 300)
            case .ready(let stabilized):
                StabilizeComparePlayers(original: model.source, stabilized: stabilized, range: model.range, recipe: model.recipe, sideBySide: model.sideBySide)
                    .frame(minHeight: 300)
            }
            HStack {
                Text(String(format: "%.1f–%.1f s of the clip. The original is never changed; this preview is a cache file.", model.range.lowerBound, model.range.upperBound))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 900, height: 520)
    }
}

/// Two looping players kept in step: the original's window and the
/// stabilized segment, each drawn with the clip's grade when it has one.
struct StabilizeComparePlayers: View {
    let original: URL
    let stabilized: URL
    let range: ClosedRange<Double>
    let recipe: GradeRecipe?
    let sideBySide: Bool
    @State private var players: (AVPlayer, AVPlayer)?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        Group {
            if let players {
                HStack(spacing: 10) {
                    if sideBySide {
                        labelled("Original", VideoPlayer(player: players.0))
                    }
                    labelled("Stabilized", VideoPlayer(player: players.1))
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: stabilized) { await load() }
        .onDisappear {
            players?.0.pause()
            players?.1.pause()
            if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
            loopObserver = nil
        }
    }

    private func labelled(_ title: String, _ player: some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            player.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func load() async {
        let start = CMTime(seconds: range.lowerBound, preferredTimescale: 600)
        let end = CMTime(seconds: range.upperBound, preferredTimescale: 600)
        let left = AVPlayerItem(asset: CameraVideoAsset.asset(for: original))
        left.forwardPlaybackEndTime = end
        let right = AVPlayerItem(asset: AVURLAsset(url: stabilized))
        if let recipe {
            left.videoComposition = try? await GradeRenderer.shared.videoComposition(for: left.asset, live: GradeLiveState(recipe: recipe))
            // Gyroflow writes video range, whatever the original's range:
            // the stabilized side is drawn with its own.
            var stabilizedRecipe = recipe
            stabilizedRecipe.range = await GradeRenderer.shared.signalRange(of: stabilized) ?? .video
            right.videoComposition = try? await GradeRenderer.shared.videoComposition(for: right.asset, live: GradeLiveState(recipe: stabilizedRecipe))
        }
        let a = AVPlayer(playerItem: left)
        let b = AVPlayer(playerItem: right)
        a.isMuted = true
        await a.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        players = (a, b)
        a.play()
        b.play()
        // Loop both from the top whenever the stabilized one ends.
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: right, queue: .main) { _ in
            Task { @MainActor in
                await a.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
                await b.seek(to: .zero)
                a.play()
                b.play()
            }
        }
    }
}

// MARK: - Stabilize all clips

/// What the "Stabilize all clips" sheet applies to.
struct StabilizeAllRequest: Identifiable {
    let id = UUID()
    let scopeTitle: String
    let items: [OrganizeItem]
    let stacks: [OrganizeStack]
    let boardEventID: UUID?
}

/// Counts what a blanket stabilize would do — how many clips have motion
/// data, how many are skipped and why — then turns it on (one Undo step)
/// and, if asked, renders.
struct StabilizeAllSheet: View {
    let stabilizing: ClipStabilizing
    let request: StabilizeAllRequest
    var onDone: () -> Void
    @State private var smoothing: StabilizationSmoothing = .medium
    @State private var counted = false

    private var stabilizable: [OrganizeItem] { request.items.filter(ClipStabilizing.isStabilizable) }
    private var withMotion: [OrganizeItem] {
        stabilizable.filter { stabilizing.motion[ClipStabilizing.fileKey($0)]?.isPresent ?? false }
    }
    private var skipped: [(String, Int)] {
        var reasons: [String: Int] = [:]
        let notVideo = request.items.count - stabilizable.count
        if notVideo > 0 { reasons["not an MP4/MOV video (photos, 360° originals, copies)"] = notVideo }
        for item in stabilizable {
            switch stabilizing.motion[ClipStabilizing.fileKey(item)] {
            case .absent?: reasons["no motion data in the file", default: 0] += 1
            case .unknown(let why)?: reasons[why.lowercased(), default: 0] += 1
            case .present?, nil: break
            }
        }
        return reasons.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Stabilize Clips", systemImage: "gyroscope").font(.title3.weight(.semibold))
            Text(request.scopeTitle).font(.callout).foregroundStyle(.secondary)
            Picker("Smoothing", selection: $smoothing) {
                ForEach(StabilizationSmoothing.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            if !counted {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for motion data in \(stabilizable.count) clip\(stabilizable.count == 1 ? "" : "s")…").foregroundStyle(.secondary)
                }
            } else {
                Text("\(withMotion.count) clip\(withMotion.count == 1 ? "" : "s") with motion data will be stabilized when rendered.")
                    .font(.callout)
                if !skipped.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(skipped, id: \.0) { reason, count in
                            Text("\(count) skipped: \(reason)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let problem = stabilizing.availability.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Get Gyroflow (free)", destination: GyroflowInstallation.downloadPage).font(.caption)
            }
            Text("Saved per clip like a grade; ⌘Z undoes it. Graded clips are stabilized, then graded, into Edited/\(GradedRenderNaming.folderName); the others get Edited/\(StabilizedRenderNaming.folderName) copies. Originals are only read.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onDone).keyboardShortcut(.cancelAction)
                Button("Turn On") { apply(render: false) }
                    .disabled(!counted || withMotion.isEmpty || !stabilizing.availability.isReady)
                Button("Turn On and Render") { apply(render: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!counted || withMotion.isEmpty || !stabilizing.availability.isReady)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            smoothing = stabilizing.lastSmoothing
            await stabilizing.ensureProbed(stabilizable)
            counted = true
        }
    }

    private func apply(render: Bool) {
        let targets = withMotion
        stabilizing.setStabilization(
            StabilizationSettings(smoothing: smoothing), for: targets,
            undoTitle: "Stabilize \(targets.count) Clip\(targets.count == 1 ? "" : "s")"
        )
        stabilizing.model.statusMessage = "Stabilize (\(smoothing.displayName)) on for \(targets.count) clip\(targets.count == 1 ? "" : "s")\(skipped.isEmpty ? "" : "; \(skipped.reduce(0) { $0 + $1.1 }) skipped"). ⌘Z undoes it."
        if render { stabilizing.renderAll(targets, in: request.stacks, boardEventID: request.boardEventID) }
        onDone()
    }
}

extension ClipStabilizing {
    /// Renders every clip among `items`: graded ones through the graded
    /// render (stabilized first), the rest as stabilized-only copies.
    func renderAll(_ items: [OrganizeItem], in stacks: [OrganizeStack], boardEventID: UUID?) {
        let ids = Set(items.map(\.id))
        let only = stabilizeOnlyItems(in: stacks).filter { ids.contains($0.id) }
        let onlyIDs = Set(only.map(\.id))
        let graded = items.filter { !onlyIDs.contains($0.id) }
        if !graded.isEmpty {
            grading.renderGradedCopies(of: graded.map { OrganizeStack(items: [$0]) }, boardEventID: boardEventID, includeStabilizeOnly: false)
        }
        if !only.isEmpty { renderStabilizedCopies(of: only, in: stacks, boardEventID: boardEventID) }
    }
}

/// Presents the "Stabilize all clips" sheet for a board.
struct StabilizeAllSheetHost: ViewModifier {
    let workspace: EventsWorkspace

    func body(content: Content) -> some View {
        let stabilizing = workspace.grading.stabilizing
        content.sheet(item: Binding(get: { stabilizing.allRequest }, set: { stabilizing.allRequest = $0 })) { request in
            StabilizeAllSheet(stabilizing: stabilizing, request: request, onDone: { stabilizing.allRequest = nil })
        }
    }
}

// MARK: - Board menu

/// The Color menu's stabilize items.
struct StabilizeMenuItems: View {
    let workspace: EventsWorkspace
    let targets: [OrganizeStack]
    let boardStacks: () -> [OrganizeStack]
    let boardTitle: String
    let boardEventID: UUID?

    var body: some View {
        let stabilizing = workspace.grading.stabilizing
        let items = targets.flatMap(\.items).filter(ClipStabilizing.isStabilizable)
        Divider()
        Button("Stabilize Selected Clips…") {
            stabilizing.allRequest = StabilizeAllRequest(
                scopeTitle: items.count == 1 ? items[0].primary.name : "\(items.count) selected clips",
                items: items, stacks: targets, boardEventID: boardEventID
            )
        }
        .disabled(items.isEmpty)
        Button("Stabilize All Clips in \(boardTitle)…") {
            let stacks = boardStacks()
            stabilizing.allRequest = StabilizeAllRequest(
                scopeTitle: boardTitle, items: stacks.flatMap(\.items), stacks: stacks, boardEventID: boardEventID
            )
        }
        Button("Turn Off Stabilization") { stabilizing.setStabilization(nil, for: items) }
            .disabled(!items.contains { stabilizing.settings(for: $0) != nil })
    }
}
