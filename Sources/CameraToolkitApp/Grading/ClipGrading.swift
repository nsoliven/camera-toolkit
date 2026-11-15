import AppKit
import CameraToolkitCore
import Foundation
import Observation

/// What a tile shows about a clip's colour.
enum TileGradeMark: Equatable, Sendable {
    /// The tile draws this graded picture.
    case graded(GradeRecipe)
    /// Log footage with no look yet: drawn flat, with a quiet marker.
    case flatLog(LogProfile)

    var recipe: GradeRecipe? {
        if case .graded(let recipe) = self { return recipe }
        return nil
    }
}

/// The app side of colour grading: per-clip grades (non-destructive data
/// in the catalog), log detection from camera sidecars, per-profile
/// default looks, imported LUTs, the grade clipboard, Undo, and the render
/// job. Tiles ask it by file key (`facts`), so a grade change redraws only
/// the clips it touched.
@MainActor
@Observable
final class ClipGrading {
    @ObservationIgnored unowned let workspace: EventsWorkspace
    /// Keyed by `DisplayRotation.fileKey`.
    @ObservationIgnored let facts = KeyedObservation<String>()
    @ObservationIgnored let library: LUTLibrary
    @ObservationIgnored let renderer: GradeRenderer

    /// Imported LUTs, for the look strip and Settings.
    private(set) var luts: [ImportedLUT] = []
    /// Copy Grade / Paste Grade.
    var clipboard: ClipGrade?

    /// Detected profile by file key: present once the sidecar was read
    /// (nil value = read, not log).
    @ObservationIgnored private var detected: [String: LogProfile?] = [:]
    @ObservationIgnored private var detectionQueue: [String: (clip: URL, companions: [URL])] = [:]
    @ObservationIgnored private var detectionTask: Task<Void, Never>?
    /// Signal range per file key, for log clips.
    @ObservationIgnored private var ranges: [String: VideoSignalRange] = [:]

    init(workspace: EventsWorkspace, library: LUTLibrary? = nil, renderer: GradeRenderer = .shared) {
        self.workspace = workspace
        self.library = library ?? GradingStorage.library
        self.renderer = renderer
        let lutLibrary = self.library
        renderer.lutProvider = { lutLibrary.lut(id: $0) }
        luts = lutLibrary.list()
        workspace.model.onColorGradesChanged = { [weak self] old, new, defaultsChanged in
            self?.gradesChanged(from: old, to: new, defaultsChanged: defaultsChanged)
        }
        lutObserver = NotificationCenter.default.addObserver(forName: .cameraToolkitLUTsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLUTs(notify: false) }
        }
    }

    @ObservationIgnored private var lutObserver: NSObjectProtocol?
    /// Asks before a before-sync render (first run, or a big one). Tests
    /// answer it themselves.
    @ObservationIgnored var confirmRenderBeforeSync: @MainActor (RenderBeforeSyncSummary) -> RenderBeforeSyncChoice = ClipGrading.askRenderBeforeSync

    static func askRenderBeforeSync(_ summary: RenderBeforeSyncSummary) -> RenderBeforeSyncChoice {
        let formatter = ByteCountFormatter()
        let alert = NSAlert()
        alert.messageText = "Render \(summary.count) graded cop\(summary.count == 1 ? "y" : "ies") before syncing?"
        var lines = [
            "About \(formatter.string(fromByteCount: summary.estimatedBytes)) of Rec.709 copies go into each event's Edited/\(GradedRenderNaming.folderName)"
                + (summary.freeBytes.map { " (\(formatter.string(fromByteCount: $0)) free there)." } ?? "."),
            "Sync to NAS then carries them to the NAS, where Immich picks them up. The sync waits in the queue behind the render; Stop in the Jobs window ends the render and the sync still runs.",
        ]
        if summary.alreadyThere > 0 { lines.append("\(summary.alreadyThere) cop\(summary.alreadyThere == 1 ? "y is" : "ies are") already there and will not be made again.") }
        if summary.isFirstRun { lines.append("This is asked the first time, and again whenever more than \(renderBeforeSyncAskAbove) copies are due. Turn it off in Settings › Color.") }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Render and Sync")
        alert.addButton(withTitle: "Sync Without Rendering")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .renderThenSync
        case .alertSecondButtonReturn: return .syncOnly
        default: return .cancel
        }
    }

    var model: DashboardModel { workspace.model }

    // MARK: Questions (no file access)

    static func fileKey(_ file: OrganizeFile) -> String { DisplayRotation.fileKey(for: file) }

    /// Plain videos the app can decode and re-encode. 360° originals and
    /// copies this app rendered are left alone.
    static func isGradable(_ item: OrganizeItem) -> Bool {
        guard item.kind == .video else { return false }
        let ext = item.primary.fileExtension
        guard ["mp4", "mov", "m4v", "mxf"].contains(ext) else { return false }
        return !GradedRenderNaming.isGradedCopy(item.primary.url)
    }

    func explicitGrade(for item: OrganizeItem) -> ClipGrade? {
        let key = Self.fileKey(item.primary)
        facts.track(key)
        return model.colorGradesSnapshot[key]
    }

    /// The profile in effect (the user's mark over what was detected).
    /// Unknown until the sidecar has been read; asking schedules the read.
    func profile(for item: OrganizeItem) -> LogProfile? {
        guard Self.isGradable(item) else { return nil }
        let key = Self.fileKey(item.primary)
        facts.track(key)
        let mark = model.colorGradesSnapshot[key]?.profileMark ?? .detected
        if case .detected = mark, detected[key] == nil {
            scheduleDetection(for: item)
        }
        return mark.resolve(detected: detected[key] ?? nil)
    }

    /// True once the clip's sidecar has been read (or a mark makes it moot).
    func isProfileKnown(for item: OrganizeItem) -> Bool {
        let key = Self.fileKey(item.primary)
        if let mark = model.colorGradesSnapshot[key]?.profileMark, mark != .detected { return true }
        return detected[key] != nil || !Self.isGradable(item)
    }

    func detectedProfile(for item: OrganizeItem) -> LogProfile? {
        detected[Self.fileKey(item.primary)] ?? nil
    }

    /// The clip's own grade, else the default look for its profile.
    func effectiveGrade(for item: OrganizeItem) -> ClipGrade? {
        if let grade = explicitGrade(for: item) {
            // A grade that only labels the profile still gets the default.
            if grade.look == .none, grade.hasNeutralControls, let profile = profile(for: item),
               let look = model.gradeDefaultsSnapshot.look(for: profile) {
                var withDefault = grade
                withDefault.look = look
                return withDefault
            }
            return grade
        }
        guard let profile = profile(for: item), let look = model.gradeDefaultsSnapshot.look(for: profile) else { return nil }
        return ClipGrade(look: look)
    }

    func signalRange(for item: OrganizeItem, profile: LogProfile?) -> VideoSignalRange {
        if let known = ranges[Self.fileKey(item.primary)] { return known }
        if let known = renderer.knownSignalRange(of: item.primary.url) { return known }
        // Sony's log recordings are full range; most other video is not.
        switch profile {
        case .sLog3SGamut3Cine?, .sLog3SGamut3?: return .full
        default: return .video
        }
    }

    func recipe(for item: OrganizeItem, grade: ClipGrade? = nil) -> GradeRecipe? {
        guard Self.isGradable(item), let grade = grade ?? effectiveGrade(for: item) else { return nil }
        let profile = grade.profileMark.resolve(detected: detectedProfile(for: item))
        let recipe = GradeRecipe(grade: grade, profile: profile, range: signalRange(for: item, profile: profile))
        return recipe.grade.isIdentity ? nil : recipe
    }

    func tileMark(for stack: OrganizeStack) -> TileGradeMark? {
        let item = stack.coverItem
        guard Self.isGradable(item) else { return nil }
        if let recipe = recipe(for: item), isLookAvailable(recipe) {
            return .graded(recipe)
        }
        if let profile = profile(for: item) { return .flatLog(profile) }
        return nil
    }

    /// Without reading a LUT file: a tile asks this while it draws.
    func isLookAvailable(_ recipe: GradeRecipe) -> Bool {
        switch recipe.grade.look {
        case .none: true
        case .rec709: recipe.profile?.hasBuiltInConversion == true
        case .lut(let id): luts.contains { $0.id == id }
        }
    }

    // MARK: Detection

    private func scheduleDetection(for item: OrganizeItem) {
        let key = Self.fileKey(item.primary)
        guard detectionQueue[key] == nil else { return }
        detectionQueue[key] = (item.primary.url, item.companions.map(\.url))
        guard detectionTask == nil else { return }
        // Coalesce a screenful of tiles into one background pass.
        detectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            await self?.runDetection()
        }
    }

    private func runDetection() async {
        while !detectionQueue.isEmpty {
            let batch = detectionQueue
            detectionQueue.removeAll()
            let renderer = self.renderer
            let results: [(String, LogProfile?, VideoSignalRange?)] = await Task.detached(priority: .utility) {
                var out: [(String, LogProfile?, VideoSignalRange?)] = []
                for (key, entry) in batch {
                    let profile = LogProfileDetector.profile(clip: entry.clip, companions: entry.companions)
                    var range: VideoSignalRange?
                    if profile != nil { range = await renderer.signalRange(of: entry.clip) }
                    out.append((key, profile, range))
                }
                return out
            }.value
            for (key, profile, range) in results {
                detected[key] = .some(profile)
                if let range { ranges[key] = range }
                facts.touch(key)
            }
        }
        detectionTask = nil
    }

    /// Reads every clip's sidecar that has not been read yet, and returns
    /// once all are known — the blanket sheet waits on this to count.
    func ensureDetected(_ items: [OrganizeItem]) async {
        let unknown = items.filter { Self.isGradable($0) && detected[Self.fileKey($0.primary)] == nil }
        guard !unknown.isEmpty else { return }
        for item in unknown {
            detectionQueue[Self.fileKey(item.primary)] = (item.primary.url, item.companions.map(\.url))
        }
        if let running = detectionTask {
            await running.value
        }
        if !detectionQueue.isEmpty {
            detectionTask = Task { @MainActor [weak self] in await self?.runDetection() }
            await detectionTask?.value
        }
    }

    // MARK: Changes

    private func gradesChanged(from old: [String: ClipGrade], to new: [String: ClipGrade], defaultsChanged: Bool) {
        if defaultsChanged {
            facts.touchAll()
            return
        }
        for key in Set(old.keys).union(new.keys) where old[key] != new[key] {
            facts.touch(key)
        }
    }

    /// Sets (or with nil removes) the grade of every item, as one Undo step.
    func setGrade(_ grade: ClipGrade?, for items: [OrganizeItem], undoTitle: String, detail: String? = nil) {
        setGrades(items.filter(Self.isGradable).map { ($0, grade) }, undoTitle: undoTitle, detail: detail)
    }

    func setGrades(_ pairs: [(OrganizeItem, ClipGrade?)], undoTitle: String, detail: String? = nil) {
        let before = model.colorGradesSnapshot
        var changes: [UndoGradeChange] = []
        var seen: Set<String> = []
        for (item, grade) in pairs {
            let key = Self.fileKey(item.primary)
            guard seen.insert(key).inserted, before[key] != grade else { continue }
            changes.append(UndoGradeChange(key: key, before: before[key], after: grade))
        }
        guard !changes.isEmpty else { return }
        apply(changes, undo: false)
        workspace.recordUndo(undoTitle, detail: detail, .config(.colorGrades(changes)))
    }

    /// Replays an Undo or Redo step.
    func apply(_ changes: [UndoGradeChange], undo: Bool) {
        model.updateConfiguration { configuration in
            for change in changes {
                configuration.colorGrades[change.key] = undo ? change.before : change.after
            }
        }
    }

    /// Applies `look` at `intensity` to every log clip among `items`,
    /// keeping each clip's own basic controls. One Undo step.
    @discardableResult
    func applyLook(_ look: GradeLook, intensity: Double = 1, toLogClipsIn items: [OrganizeItem]) -> Int {
        let targets = items.filter { Self.isGradable($0) && profile(for: $0) != nil }
        let pairs: [(OrganizeItem, ClipGrade?)] = targets.map { item in
            var grade = explicitGrade(for: item) ?? ClipGrade()
            grade.look = look
            grade.intensity = intensity
            return (item, grade)
        }
        setGrades(pairs, undoTitle: "Apply \(lookName(look))", detail: "\(targets.count) log clip\(targets.count == 1 ? "" : "s")")
        return targets.count
    }

    func copyGrade(from item: OrganizeItem) {
        clipboard = effectiveGrade(for: item) ?? ClipGrade()
        model.statusMessage = "Copied the grade of \(item.primary.name)."
    }

    func pasteGrade(to items: [OrganizeItem]) {
        guard let clipboard else { return }
        let targets = items.filter(Self.isGradable)
        let pairs = targets.map { item in
            (item, Optional(clipboard.withProfileMark(explicitGrade(for: item)?.profileMark ?? .detected)))
        }
        setGrades(pairs, undoTitle: "Paste Grade", detail: targets.count == 1 ? nil : "\(targets.count) clips")
    }

    func removeGrade(from items: [OrganizeItem]) {
        let pairs: [(OrganizeItem, ClipGrade?)] = items.filter(Self.isGradable).map { item in
            // Keep a profile label the user set; drop the look and controls.
            guard let mark = explicitGrade(for: item)?.profileMark, mark != .detected else { return (item, nil) }
            return (item, ClipGrade(profileMark: mark))
        }
        setGrades(pairs, undoTitle: "Remove Grade", detail: pairs.count == 1 ? nil : "\(pairs.count) clips")
    }

    func markProfile(_ mark: ClipProfileMark, for items: [OrganizeItem]) {
        let pairs: [(OrganizeItem, ClipGrade?)] = items.filter(Self.isGradable).map { item in
            var grade = explicitGrade(for: item) ?? ClipGrade()
            grade.profileMark = mark
            return (item, grade.isIdentity && mark == .detected ? nil : grade)
        }
        let title: String = switch mark {
        case .detected: "Use Detected Profile"
        case .marked(let profile): "Mark as \(profile.shortName)"
        case .notLog: "Mark as Not Log"
        }
        setGrades(pairs, undoTitle: title)
    }

    // MARK: Defaults and LUTs (Settings — outside Undo)

    func setDefaultLook(_ look: GradeLook?, for profile: LogProfile) {
        model.updateConfiguration { $0.gradeDefaults.setLook(look, for: profile) }
    }

    func defaultLook(for profile: LogProfile) -> GradeLook? {
        _ = model.colorGradesRevision
        return model.gradeDefaultsSnapshot.look(for: profile)
    }

    @discardableResult
    func importLUTs(_ urls: [URL]) -> [String] {
        var problems: [String] = []
        for url in urls {
            do {
                try library.importLUT(from: url)
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        refreshLUTs()
        return problems
    }

    func removeLUT(_ id: String) {
        try? library.remove(id: id)
        refreshLUTs()
    }

    func renameLUT(_ id: String, to name: String) {
        try? library.rename(id: id, to: name)
        refreshLUTs()
    }

    private func refreshLUTs(notify: Bool = true) {
        luts = library.list()
        renderer.forgetCubes()
        facts.touchAll()
        if notify { NotificationCenter.default.post(name: .cameraToolkitLUTsChanged, object: self) }
    }

    func lookName(_ look: GradeLook) -> String {
        switch look {
        case .none: "Original"
        case .rec709: "Rec.709"
        case .lut(let id): luts.first { $0.id == id }?.name ?? "Missing LUT"
        }
    }

    /// Looks to offer for a clip: Rec.709 when the profile has a built-in
    /// conversion, then every imported LUT.
    func availableLooks(for profile: LogProfile?) -> [GradeLook] {
        var looks: [GradeLook] = [.none]
        if profile?.hasBuiltInConversion == true { looks.append(.rec709) }
        looks.append(contentsOf: luts.map { .lut($0.id) })
        return looks
    }
}
