import CameraToolkitCore
import Foundation
import Observation

/// The app side of stabilization: per-clip settings (data in the catalog,
/// beside the grades), the cheap motion-data probe, the Gyroflow engine,
/// the render jobs and the 3-second preview. The original is never
/// changed: stabilizing writes a copy (`Edited/Stabilized`) or feeds the
/// graded copy (`Edited/Rec709`).
@MainActor
@Observable
final class ClipStabilizing {
    @ObservationIgnored unowned let grading: ClipGrading
    @ObservationIgnored private let store: StabilizationStore?

    /// Stabilization by file key; a key that is absent is off.
    private(set) var settingsByKey: [String: StabilizationSettings] = [:]
    /// Probe answers by file key.
    private(set) var motion: [String: MotionDataAvailability] = [:]
    private(set) var availability: StabilizerAvailability
    /// The "Stabilize all clips" sheet a board shows.
    var allRequest: StabilizeAllRequest?
    /// The before/after preview being made or shown.
    var preview: StabilizePreviewModel?
    /// The last smoothing chosen, offered next time.
    var lastSmoothing: StabilizationSmoothing = .medium

    @ObservationIgnored private var probing: Set<String> = []
    /// Builds the engine; tests hand in one with a fake runner.
    @ObservationIgnored var makeStabilizer: @MainActor () -> Stabilizer?
    /// Finds Gyroflow (reads code signatures; run off the main actor).
    @ObservationIgnored private let locator: @Sendable () -> GyroflowInstallation?
    /// The search under way, for planners to wait on (`ensureAvailability`).
    @ObservationIgnored private var search: Task<Void, Never>?

    init(
        grading: ClipGrading,
        store: StabilizationStore? = nil,
        installation: GyroflowInstallation?? = nil,
        locator: (@Sendable () -> GyroflowInstallation?)? = nil
    ) {
        self.locator = locator ?? { GyroflowInstallation.locate() }
        self.grading = grading
        let catalog = URL(fileURLWithPath: DashboardModel.expandedPath(grading.model.configuration.catalogDatabasePath))
        let store = store ?? (grading.model.configuration.catalogDatabasePath.isEmpty ? nil : StabilizationStore(catalogURL: catalog))
        self.store = store
        settingsByKey = (try? store?.load()) ?? [:]
        if let installation {
            availability = StabilizerAvailability(installation)
            makeStabilizer = { StabilizerAvailability(installation).installation.map { Stabilizer(installation: $0) } }
        } else {
            // The search checks code signatures: off the main actor. Made
            // at launch (`StabilizeLifecycle`), so it is done long before a
            // render asks; a planner that does ask while it runs waits.
            availability = .checking
            makeStabilizer = { nil }
            refreshAvailability()
        }
    }

    /// How long a planner waits for the Gyroflow search before rendering
    /// the clips set to Stabilize graded only (with a note).
    @ObservationIgnored var availabilityWaitLimit: TimeInterval = 15

    /// Planners call this before deciding which clips are stabilized. It
    /// returns at once when none of `keys` is set to Stabilize (a Sync of
    /// clips nobody stabilizes never waits on Gyroflow) or the search is
    /// done; otherwise it waits for the search — `.checking` is a wait, not
    /// "unavailable", which would make plain duplicates of stabilized
    /// copies — but at most `availabilityWaitLimit`. Returns false when it
    /// gave up waiting; those clips are then rendered graded only.
    @discardableResult
    func ensureAvailability<Keys: Sequence>(forKeys keys: Keys) async -> Bool where Keys.Element == String {
        guard availability == .checking, search != nil else { return true }
        guard keys.contains(where: { settingsByKey[$0] != nil }) else { return true }
        let deadline = ContinuousClock.now + .seconds(availabilityWaitLimit)
        while availability == .checking, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return availability != .checking
    }

    /// True when a planner for `keys` would have to wait for the search.
    func needsAvailabilityWait<Keys: Sequence>(forKeys keys: Keys) -> Bool where Keys.Element == String {
        availability == .checking && search != nil && keys.contains { settingsByKey[$0] != nil }
    }

    var workspace: EventsWorkspace { grading.workspace }
    var model: DashboardModel { grading.model }

    /// Looks for Gyroflow again (after the person installed it).
    func refreshAvailability() {
        availability = .checking
        let locate = locator
        search = Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) { locate() }.value
            guard let self else { return }
            availability = StabilizerAvailability(found)
            makeStabilizer = { StabilizerAvailability(found).installation.map { Stabilizer(installation: $0) } }
        }
    }

    // MARK: Questions

    static func fileKey(_ item: OrganizeItem) -> String { ClipGrading.fileKey(item.primary) }

    /// Plain MP4/MOV videos Gyroflow can read; never a copy this app made.
    static func isStabilizable(_ item: OrganizeItem) -> Bool {
        guard item.kind == .video, ["mp4", "mov"].contains(item.primary.fileExtension) else { return false }
        let url = item.primary.url
        return !GradedRenderNaming.isGradedCopy(url) && !StabilizedRenderNaming.isStabilizedCopy(url)
    }

    func settings(for item: OrganizeItem) -> StabilizationSettings? {
        settingsByKey[Self.fileKey(item)]
    }

    func settings(forKey key: String) -> StabilizationSettings? { settingsByKey[key] }

    /// The probe's answer; nil until it has run (asking starts it).
    func motionData(for item: OrganizeItem) -> MotionDataAvailability? {
        let key = Self.fileKey(item)
        if let known = motion[key] { return known }
        guard Self.isStabilizable(item) else { return .absent }
        scheduleProbe([item])
        return nil
    }

    private func scheduleProbe(_ items: [OrganizeItem]) {
        let todo = items.filter { motion[Self.fileKey($0)] == nil && !probing.contains(Self.fileKey($0)) }
        guard !todo.isEmpty else { return }
        for item in todo { probing.insert(Self.fileKey(item)) }
        let pairs = todo.map { (Self.fileKey($0), $0.primary.url) }
        Task { @MainActor [weak self] in
            let answers = await Task.detached(priority: .utility) {
                pairs.map { ($0.0, MotionDataProbe.probe($0.1)) }
            }.value
            guard let self else { return }
            for (key, answer) in answers {
                motion[key] = answer
                probing.remove(key)
            }
        }
    }

    /// Probes every clip not probed yet and returns once all are known.
    func ensureProbed(_ items: [OrganizeItem]) async {
        let todo = items.filter { Self.isStabilizable($0) && motion[Self.fileKey($0)] == nil }
        guard !todo.isEmpty else { return }
        let pairs = todo.map { (Self.fileKey($0), $0.primary.url) }
        let answers = await Task.detached(priority: .userInitiated) {
            pairs.map { ($0.0, MotionDataProbe.probe($0.1)) }
        }.value
        for (key, answer) in answers { motion[key] = answer }
    }

    /// Records a probe answer (tests, and the blanket sheet's count).
    func setMotion(_ answer: MotionDataAvailability, forKey key: String) {
        motion[key] = answer
    }

    // MARK: Changes (one Undo step each)

    func setStabilization(_ settings: StabilizationSettings?, for items: [OrganizeItem], undoTitle: String? = nil) {
        let pairs = items.filter(Self.isStabilizable).map { (Self.fileKey($0), settings) }
        let title = undoTitle ?? (settings == nil ? "Turn Off Stabilization" : "Stabilize")
        setStabilization(byKey: pairs, undoTitle: title, detail: pairs.count == 1 ? nil : "\(pairs.count) clips")
    }

    func setStabilization(byKey pairs: [(String, StabilizationSettings?)], undoTitle: String, detail: String? = nil) {
        let before = settingsByKey
        var changes: [String: (before: StabilizationSettings?, after: StabilizationSettings?)] = [:]
        for (key, settings) in pairs where changes[key] == nil && before[key] != settings {
            changes[key] = (before[key], settings)
        }
        guard !changes.isEmpty else { return }
        if let smoothing = pairs.compactMap({ $0.1?.smoothing }).first { lastSmoothing = smoothing }
        write(changes.mapValues(\.after))
        workspace.recordSessionUndo(
            undoTitle,
            detail: detail,
            undo: { [weak self] in self?.write(changes.mapValues(\.before)) },
            redo: { [weak self] in self?.write(changes.mapValues(\.after)) }
        )
    }

    private func write(_ values: [String: StabilizationSettings?]) {
        for (key, value) in values { settingsByKey[key] = value }
        do {
            try store?.save(values)
        } catch {
            model.statusMessage = "Stabilization was set for this session but could not be saved to the catalog: \(error.localizedDescription)"
        }
    }

    // MARK: Graded renders

    /// The stabilization a graded copy of `key` gets: the clip's own, when
    /// it is on and the clip has motion data (or has not been probed).
    func renderStabilization(forKey key: String) -> RenderStabilization? {
        // Without a Gyroflow that can render, the clip is graded alone
        // (with a note), never left without its graded copy.
        guard availability.isReady, let settings = settingsByKey[key] else { return nil }
        if motion[key] == .absent { return nil }
        return RenderStabilization(settings: settings)
    }

    /// Fills in each request's stabilization from the clips' settings.
    func attachStabilization(to requests: [GradedRenderRequest]) -> [GradedRenderRequest] {
        requests.map { request in
            var request = request
            request.stabilization = renderStabilization(forKey: request.sourceKey)
            return request
        }
    }

    /// Said when clips set to Stabilize are rendered without it because
    /// Gyroflow can't run here; nil otherwise.
    func unavailableNote(forKeys keys: [String]) -> String? {
        guard !availability.isReady else { return nil }
        let count = keys.count { settingsByKey[$0] != nil }
        guard count > 0 else { return nil }
        if availability == .checking {
            return "\(count) clip\(count == 1 ? " is" : "s are") set to Stabilize: the Gyroflow check didn't finish, so rendered graded only."
        }
        return "\(count) clip\(count == 1 ? " is" : "s are") set to Stabilize but rendered graded only: \(availability.problem ?? "Gyroflow can’t run here.")"
    }

    /// True when some of `requests` would be stabilized.
    func anyStabilized(_ keys: [String]) -> Bool {
        keys.contains { renderStabilization(forKey: $0) != nil }
    }

    // MARK: Stabilized-only copies

    struct StabilizePlan {
        var requests: [StabilizeRequest] = []
        var eventIDs: Set<UUID> = []
        var refusals: [String] = []
    }

    /// Clips among `stacks` that are stabilized but have no grade: their
    /// render is a stabilized-only copy into `Edited/Stabilized`.
    func stabilizeOnlyItems(in stacks: [OrganizeStack]) -> [OrganizeItem] {
        stacks.flatMap(\.items).filter { item in
            Self.isStabilizable(item) && settings(for: item) != nil && (grading.recipe(for: item)?.isIdentity ?? true)
        }
    }

    func stabilizePlan(for items: [OrganizeItem], in stacks: [OrganizeStack], boardEventID: UUID?) -> StabilizePlan {
        var plan = StabilizePlan()
        let boardEvent = boardEventID.flatMap { workspace.event($0) }
        for item in items {
            guard let settings = settings(for: item) else { continue }
            if motion[Self.fileKey(item)] == .absent {
                plan.refusals.append("\(item.primary.name): no motion data in this file.")
                continue
            }
            let stack = stacks.first { $0.items.contains { $0.id == item.id } } ?? OrganizeStack(items: [item])
            guard let event = workspace.assignedEvent(for: stack).event ?? boardEvent else {
                plan.refusals.append("\(item.primary.name) is not in an event yet — sort it first, so its copy has an Edited folder to go to.")
                continue
            }
            guard let edited = grading.editedRoot(for: item, event: event) else {
                plan.refusals.append("\(item.primary.name): the drive for \(event.name) isn't connected.")
                continue
            }
            let output = StabilizedRenderNaming.outputFolder(editedRoot: edited)
            let onNAS = output.path.hasPrefix(workspace.locations.nasRoot.standardizedFileURL.path + "/")
            let policy = workspace.resolvedPolicy(for: event)
            plan.eventIDs.insert(event.id)
            plan.requests.append(StabilizeRequest(
                source: item.primary.url,
                settings: settings,
                sourceKey: Self.fileKey(item),
                sourceModifiedAt: item.primary.modifiedAt,
                outputFolder: output,
                // The other copy of the folder (NAS for a drive copy, drive
                // for a NAS copy): a copy there keeps its name.
                mirrorFolder: onNAS
                    ? StabilizedRenderNaming.outputFolder(editedRoot: workspace.locations.editedRoot(for: event, policy: policy))
                    : workspace.locations.nasMirrorURL(forDrivePath: output.path)
            ))
        }
        return plan
    }

    /// Queues one job that makes the stabilized-only copies of `items`.
    func renderStabilizedCopies(of items: [OrganizeItem], in stacks: [OrganizeStack], boardEventID: UUID?) {
        if needsAvailabilityWait(forKeys: items.map(Self.fileKey)) {
            Task { @MainActor [weak self] in
                await self?.ensureAvailability(forKeys: items.map(Self.fileKey))
                self?.renderStabilizedCopiesNow(of: items, in: stacks, boardEventID: boardEventID)
            }
            return
        }
        renderStabilizedCopiesNow(of: items, in: stacks, boardEventID: boardEventID)
    }

    private func renderStabilizedCopiesNow(of items: [OrganizeItem], in stacks: [OrganizeStack], boardEventID: UUID?) {
        guard let stabilizer = makeStabilizer() else {
            model.statusMessage = availability.problem ?? "Gyroflow is needed to stabilize."
            return
        }
        let plan = stabilizePlan(for: items, in: stacks, boardEventID: boardEventID)
        guard !plan.requests.isEmpty else {
            model.statusMessage = plan.refusals.first ?? "Nothing to stabilize — turn Stabilize on for a clip first."
            return
        }
        enqueue(plan, stabilizer: stabilizer)
    }

    func enqueue(_ plan: StabilizePlan, stabilizer: Stabilizer) {
        let requests = plan.requests
        let count = requests.count
        let refusals = plan.refusals
        let eventIDs = plan.eventIDs
        let title = "Stabilize \(count) clip\(count == 1 ? "" : "s")"
        let detail = "Stabilized ProRes copies into Edited/\(StabilizedRenderNaming.folderName), made with Gyroflow from each clip's motion data. Originals are only read."
        model.enqueueFileJob(
            action: .stabilize,
            queuedNote: "\(title).",
            detail: detail,
            skippedNote: "Did not start: nothing to stabilize. Nothing changed."
        ) { [weak self] (jobID: UUID) in
            guard let self else { return }
            let stop = RenderStopFlag()
            model.registerStop(jobID: jobID) { stop.stop() }
            let model = self.model
            model.runBackgroundJob(
                action: .stabilize,
                runningNote: "\(title)…",
                logTitle: title,
                logDetail: detail,
                onSettled: { @MainActor in model.unregisterStop(jobID: jobID) },
                jobID: jobID,
                operation: { progress in
                    try Self.runStabilize(requests, stabilizer: stabilizer, isStopped: { stop.isStopped }, progress: progress)
                },
                completion: { [weak self] (outcome: ClipGrading.RenderOutcome) in
                    for eventID in eventIDs { self?.workspace.refreshEditTags(for: eventID) }
                    return Self.summary(outcome, refusals: refusals)
                }
            )
        }
    }

    nonisolated static func runStabilize(
        _ requests: [StabilizeRequest],
        stabilizer: Stabilizer,
        isStopped: @escaping @Sendable () -> Bool = { false },
        availableBytes: (URL) -> Int64? = { GradedVideoExporter.availableBytes(near: $0) },
        estimatedBytes: (URL) -> Int64? = { Stabilizer.estimatedBytes(of: $0) },
        progress: @escaping @Sendable (BackgroundJobUpdate) -> Void
    ) throws -> ClipGrading.RenderOutcome {
        var outcome = ClipGrading.RenderOutcome()
        let total = requests.count
        for (index, request) in requests.enumerated() {
            if isStopped() {
                outcome.stoppedReason = "Stopped after \(index) of \(total)."
                break
            }
            let name = request.source.lastPathComponent
            progress(BackgroundJobUpdate(
                progress: Double(index) / Double(total),
                note: "Stabilizing \(index + 1) of \(total) · \(name)",
                phase: "Stabilize",
                sourcePath: request.source.path,
                destinationPath: request.outputFolder.path,
                currentPath: request.source.path,
                processedFiles: index,
                totalFiles: total
            ))
            if let need = estimatedBytes(request.source), let free = availableBytes(request.outputFolder),
               free < need + ClipGrading.freeSpaceMargin {
                let formatter = ByteCountFormatter()
                outcome.stoppedReason = "Stopped before \(name): \(formatter.string(fromByteCount: max(free, 0))) free where the copy goes; its ProRes copy needs about \(formatter.string(fromByteCount: need)) plus \(formatter.string(fromByteCount: ClipGrading.freeSpaceMargin)) kept free."
                break
            }
            do {
                let result = try stabilizer.render(request, progress: { step in
                    progress(BackgroundJobUpdate(
                        progress: (Double(index) + step.fraction) / Double(total),
                        note: "Stabilizing \(index + 1) of \(total) · \(name) · \(StabilizeWording.phase(step))",
                        phase: "Stabilize",
                        currentPath: request.source.path,
                        processedFiles: index,
                        totalFiles: total
                    ))
                }, isCancelled: isStopped)
                switch result {
                case .rendered(let url, let beside):
                    outcome.rendered.append(url)
                    if !beside.isEmpty { outcome.besideOlder.append(url) }
                case .alreadyRendered(let url):
                    outcome.alreadyThere.append(url)
                }
            } catch is CancellationError {
                outcome.stoppedReason = "Stopped during \(name); its partial copy was removed."
                break
            } catch {
                outcome.failures.append("\(name): \(error.localizedDescription)")
            }
        }
        if outcome.rendered.isEmpty, outcome.alreadyThere.isEmpty, outcome.stoppedReason == nil, let first = outcome.failures.first {
            throw ToolkitError.commandFailed("No stabilized copy was made. \(first)")
        }
        return outcome
    }

    nonisolated static func summary(_ outcome: ClipGrading.RenderOutcome, refusals: [String]) -> String {
        var parts: [String] = []
        if let stopped = outcome.stoppedReason { parts.append(stopped) }
        if !outcome.rendered.isEmpty {
            parts.append("Stabilized \(outcome.rendered.count) clip\(outcome.rendered.count == 1 ? "" : "s") into Edited/\(StabilizedRenderNaming.folderName)")
        }
        if !outcome.besideOlder.isEmpty {
            parts.append("\(outcome.besideOlder.count) sit\(outcome.besideOlder.count == 1 ? "s" : "") beside an older copy made with other settings — the older copy is kept")
        }
        if !outcome.alreadyThere.isEmpty { parts.append("\(outcome.alreadyThere.count) already there unchanged") }
        if !outcome.failures.isEmpty { parts.append("\(outcome.failures.count) failed (\(outcome.failures[0]))") }
        if !refusals.isEmpty { parts.append("\(refusals.count) skipped (\(refusals[0]))") }
        return parts.joined(separator: "; ") + ". Originals untouched."
    }

    // MARK: Graded render step

    /// The engine for a graded render job, made on the main actor before
    /// the job leaves it. Nil when no request needs it.
    func stabilizerForRender(_ requests: [GradedRenderRequest]) -> Stabilizer? {
        requests.contains { $0.stabilization != nil } ? makeStabilizer() : nil
    }
}

/// Words for progress and the panel.
enum StabilizeWording {
    nonisolated static func phase(_ step: Stabilizer.Progress) -> String {
        switch step.phase {
        case .starting: "starting Gyroflow"
        case .synchronizing: "matching gyro to video \(Int((step.fraction / 0.1 * 100).rounded()))%"
        case .rendering:
            step.totalFrames > 0 ? "frame \(step.frame) of \(step.totalFrames)" : "\(Int((step.fraction * 100).rounded()))%"
        }
    }

    static func motionLine(_ answer: MotionDataAvailability?) -> String {
        switch answer {
        case nil: "Looking for motion data…"
        case .present(let source)?: "\(source.displayName) motion data found — stabilized from the camera's gyro."
        case .absent?: "No motion data in this file"
        case .unknown(let reason)?: reason
        }
    }
}

extension ClipGrading {
    /// The stabilization side of grading (made on first use).
    var stabilizing: ClipStabilizing {
        if let existing = stabilizingStorage { return existing }
        let made = ClipStabilizing(grading: self)
        stabilizingStorage = made
        return made
    }
}
