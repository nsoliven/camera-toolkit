import CameraToolkitCore
import SwiftUI

/// The blanket apply, shown before it happens: every affected clip's frame
/// before and after, a count, then Apply. One Undo step.
@MainActor
@Observable
final class BlanketGradeModel {
    struct Row: Identifiable {
        let id: String
        let name: String
        let profile: LogProfile
        /// Stage (b) for this clip (the looks go on top of it).
        let conversion: ResolvedConversion
        let range: VideoSignalRange
        let existing: ClipGrade?
        var before: CGImage?
        var after: CGImage?
    }

    let scopeTitle: String
    private(set) var isLoading = true
    private(set) var rows: [Row] = []
    private(set) var notLogCount = 0
    private(set) var looks: [GradeLook] = [.none]
    private(set) var lookThumbnails: [GradeLook: CGImage] = [:]
    var look: GradeLook = .builtIn(.softFilm) {
        didSet {
            guard look != oldValue else { return }
            intensity = look.defaultIntensity
            refreshAfters()
        }
    }
    var intensity: Double = 1 {
        didSet { if intensity != oldValue { refreshAfters() } }
    }
    var alsoMakeDefault = false
    let lookName: (GradeLook) -> String
    @ObservationIgnored private let renderer: GradeRenderer
    @ObservationIgnored private var afterTask: Task<Void, Never>?

    init(scopeTitle: String, lookName: @escaping (GradeLook) -> String, renderer: GradeRenderer = .shared) {
        self.scopeTitle = scopeTitle
        self.lookName = lookName
        self.renderer = renderer
    }

    var alreadyGradedCount: Int { rows.count { $0.existing.map { !$0.isDefault } ?? false } }
    /// "Sony S-Log3 → Rec.709 · Built-in (Sony math)" — what every row is
    /// converted with first; set by whoever fills the model.
    var conversionTitle = ""
    /// Profiles among the rows; the default toggle needs exactly one.
    var profiles: Set<LogProfile> { Set(rows.map(\.profile)) }

    func load(rows: [Row], notLogCount: Int, looks: [GradeLook]) {
        self.rows = rows
        self.notLogCount = notLogCount
        self.looks = looks
        if !looks.contains(look) { look = looks.first { $0 != .none } ?? .none }
        intensity = look.defaultIntensity
        isLoading = false
        refreshAfters()
    }

    func setBefore(_ image: CGImage?, for id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].before = image
        refreshAfters()
    }

    private func grade(for row: Row, look: GradeLook) -> GradeRecipe {
        var grade = row.existing ?? ClipGrade()
        grade.look = look
        grade.intensity = look == .none ? 1 : intensity
        return GradeRecipe(grade: grade, profile: row.profile, conversion: row.conversion, range: row.range)
    }

    private func refreshAfters() {
        afterTask?.cancel()
        let jobs = rows.map { row in (row.id, row.before, grade(for: row, look: look)) }
        let thumbSource = rows.first { $0.before != nil }
        let thumbJobs = thumbSource.map { source in looks.map { ($0, source.before!, grade(for: source, look: $0)) } } ?? []
        let renderer = self.renderer
        afterTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            let (afters, thumbs) = await Task.detached(priority: .userInitiated) { () -> ([String: CGImage], [GradeLook: CGImage]) in
                var afters: [String: CGImage] = [:]
                for (id, before, recipe) in jobs {
                    guard let before else { continue }
                    afters[id] = renderer.grade(before, recipe: recipe) ?? before
                }
                var thumbs: [GradeLook: CGImage] = [:]
                for (look, before, recipe) in thumbJobs {
                    thumbs[look] = recipe.isIdentity ? before : renderer.grade(before, recipe: recipe)
                }
                return (afters, thumbs)
            }.value
            guard let self, !Task.isCancelled else { return }
            for index in rows.indices {
                rows[index].after = afters[rows[index].id]
            }
            lookThumbnails = thumbs
        }
    }
}

struct BlanketGradeSheet: View {
    @Bindable var model: BlanketGradeModel
    var onCancel: () -> Void
    var onApply: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 196, maximum: 260), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apply a Look to Log Clips")
                    .font(.title3.weight(.semibold))
                Text(model.scopeTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !model.conversionTitle.isEmpty {
                    Label("Converted with \(model.conversionTitle), then the look below on top.", systemImage: "arrow.right.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            GradeLookStrip(
                looks: model.looks,
                selected: model.look,
                thumbnails: model.lookThumbnails,
                name: model.lookName,
                onChoose: { model.look = $0 },
                thumbnailWidth: 120,
                onDarkBackdrop: false
            )
            .padding(.horizontal, 10)

            HStack(spacing: 10) {
                Text("Intensity")
                Slider(value: $model.intensity, in: 0...1)
                    .frame(maxWidth: 220)
                    .disabled(model.look == .none)
                Text("\(Int((model.intensity * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            Divider()

            Group {
                if model.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Reading the clips' camera metadata…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.rows.isEmpty {
                    ContentUnavailableView(
                        "No Log Clips Here",
                        systemImage: "camera.filters",
                        description: Text("None of these clips was shot in S-Log3, and none is marked as D-Log M. Mark DJI clips with Color › Footage Is › D-Log M.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(model.rows) { row in
                                BlanketGradeCell(row: row)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .frame(minHeight: 280)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(countLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let profile = model.profiles.count == 1 ? model.profiles.first : nil, model.look != .none {
                    Toggle("Also use \(model.lookName(model.look)) for new \(profile.shortName) clips", isOn: $model.alsoMakeDefault)
                        .help("Clips with no grade of their own are then shown, played and rendered with this look. Change it in Settings › Color.")
                }
                HStack {
                    Text("Originals are never changed — the look is saved as data and can be undone.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button(model.rows.isEmpty ? "Apply" : "Apply to \(model.rows.count) Clip\(model.rows.count == 1 ? "" : "s")", action: onApply)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.rows.isEmpty || model.isLoading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 760, height: 640)
    }

    private var countLine: String {
        guard !model.isLoading else { return "Counting…" }
        var parts: [String] = []
        let n = model.rows.count
        parts.append(model.look == .none
            ? "\(n) log clip\(n == 1 ? "" : "s") will show the conversion only"
            : "\(n) log clip\(n == 1 ? "" : "s") will get \(model.lookName(model.look)) on top of the conversion")
        if model.alreadyGradedCount > 0 {
            parts.append("\(model.alreadyGradedCount) already graded keep their own sliders")
        }
        if model.notLogCount > 0 {
            parts.append("\(model.notLogCount) clip\(model.notLogCount == 1 ? " isn't" : "s aren't") log and stay\(model.notLogCount == 1 ? "s" : "") as \(model.notLogCount == 1 ? "it is" : "they are")")
        }
        return parts.joined(separator: " · ") + "."
    }
}

/// One clip: the frame split down the middle, original left, look right.
struct BlanketGradeCell: View {
    let row: BlanketGradeModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.25)
                    if let before = row.before {
                        Image(decorative: before, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: width, height: geometry.size.height)
                            .clipped()
                    }
                    if let after = row.after {
                        Image(decorative: after, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: width, height: geometry.size.height)
                            .clipped()
                            .mask(alignment: .trailing) {
                                Rectangle().frame(width: width / 2)
                            }
                    } else if row.before == nil {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    }
                    Rectangle()
                        .fill(.white.opacity(0.9))
                        .frame(width: 1.5)
                        .offset(x: width / 2 - 0.75)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Text("Log").cellLabel().padding(5)
            }
            .overlay(alignment: .bottomTrailing) {
                Text("Converted + look").cellLabel().padding(5)
            }
            HStack(spacing: 6) {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(row.profile.shortName)
                    .foregroundStyle(.secondary)
                if row.existing.map({ !$0.isDefault }) ?? false {
                    Image(systemName: "camera.filters")
                        .foregroundStyle(.secondary)
                        .help("Already graded — its own sliders are kept, only the look changes.")
                }
            }
            .font(.caption)
        }
    }
}

private extension Text {
    func cellLabel() -> some View {
        font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - Presenting from a board

extension ClipGrading {
    /// Builds the sheet's model and fills it in the background: reads the
    /// clips' sidecars, then their poster frames.
    func blanketModel(for request: BlanketGradeRequest) -> BlanketGradeModel {
        let model = BlanketGradeModel(scopeTitle: request.scopeTitle, lookName: { [weak self] in self?.lookName($0) ?? "" })
        Task { @MainActor [weak self] in
            guard let self else { return }
            await ensureDetected(request.items)
            var rows: [BlanketGradeModel.Row] = []
            var notLog = 0
            for item in request.items {
                guard let profile = profile(for: item) else {
                    notLog += 1
                    continue
                }
                let existing = explicitGrade(for: item)
                rows.append(.init(
                    id: item.id,
                    name: item.primary.name,
                    profile: profile,
                    conversion: resolver.conversion(for: existing ?? ClipGrade(), profile: profile),
                    range: signalRange(for: item, profile: profile),
                    existing: existing
                ))
            }
            // Clips with no conversion (D-Log M without its LUT) cannot take
            // a look: they are left out rather than stacked on log.
            let convertible = rows.filter { $0.conversion.converts }
            model.conversionTitle = convertible.first.map { conversionTitle($0.conversion, profile: $0.profile) } ?? ""
            model.load(rows: convertible, notLogCount: notLog + rows.count - convertible.count, looks: availableLooks(for: convertible.first?.profile))
            // Posters: tiles have usually decoded them already.
            for item in request.items where rows.contains(where: { $0.id == item.id }) {
                let image = await TileImageLoader.shared.image(
                    for: item.primary.url,
                    maximumPixelSize: 384,
                    orientation: workspace.savedTurns(for: item.primary),
                    priority: .high,
                    fileIdentity: ThumbnailDiskCache.fileIdentity(item.primary)
                )
                model.setBefore(image, for: item.id)
            }
        }
        return model
    }

    func applyBlanket(_ model: BlanketGradeModel, items: [OrganizeItem]) {
        let ids = Set(model.rows.map(\.id))
        let targets = items.filter { ids.contains($0.id) }
        let count = applyLook(model.look, intensity: model.intensity, toLogClipsIn: targets)
        if model.alsoMakeDefault, model.profiles.count == 1, let profile = model.profiles.first {
            setDefaultLook(model.look, for: profile)
        }
        self.model.statusMessage = "\(lookName(model.look)) on \(count) log clip\(count == 1 ? "" : "s"). Originals untouched — ⌘Z undoes it."
    }
}

/// Presents the blanket sheet for a board.
struct BlanketGradeSheetHost: ViewModifier {
    let workspace: EventsWorkspace
    @Binding var request: BlanketGradeRequest?
    @State private var model: BlanketGradeModel?

    func body(content: Content) -> some View {
        content
            .onChange(of: request?.id) { _, _ in
                model = request.map { workspace.grading.blanketModel(for: $0) }
            }
            .sheet(isPresented: Binding(get: { request != nil && model != nil }, set: { if !$0 { request = nil } })) {
                if let model, let request {
                    BlanketGradeSheet(
                        model: model,
                        onCancel: { self.request = nil },
                        onApply: {
                            workspace.grading.applyBlanket(model, items: request.items)
                            self.request = nil
                        }
                    )
                }
            }
    }
}

extension View {
    func blanketGradeSheet(workspace: EventsWorkspace, request: Binding<BlanketGradeRequest?>) -> some View {
        modifier(BlanketGradeSheetHost(workspace: workspace, request: request))
    }
}
