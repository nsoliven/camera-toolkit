import CameraToolkitCore
import Foundation

/// Rendering graded copies into the event's `Edited/Rec709` folder.
extension ClipGrading {
    struct RenderPlan {
        var requests: [GradedRenderRequest] = []
        var eventIDs: Set<UUID> = []
        /// Why some clips were left out, one line each.
        var refusals: [String] = []
    }

    /// Which `Edited` folder a clip's copy goes to: the drive's when the
    /// clip is in the event's folder on the drive, the NAS's when it is in
    /// the NAS folder (so the copy is written there at its final name), the
    /// drive's for a clip still on a card. Nil when that place is away.
    func editedRoot(for item: OrganizeItem, event: SavedCameraEvent) -> URL? {
        let locations = workspace.locations
        let policy = workspace.resolvedPolicy(for: event)
        let path = item.primary.pathKey
        let driveEvent = EventStorageLocations.pathKey(locations.eventFolder(for: event, policy: policy).path)
        let nasEvent = EventStorageLocations.pathKey(locations.nasEventFolder(for: event).path)
        if path.hasPrefix(driveEvent + "/") { return locations.editedRoot(for: event, policy: policy) }
        if path.hasPrefix(nasEvent + "/") { return locations.nasEditedRoot(for: event) }
        let driveRoot = locations.driveRoot(for: policy)
        guard VolumeInfo.isAvailable(driveRoot) else { return nil }
        return locations.editedRoot(for: event, policy: policy)
    }

    func renderPlan(for stacks: [OrganizeStack], boardEventID: UUID?) -> RenderPlan {
        var plan = RenderPlan()
        let boardEvent = boardEventID.flatMap { workspace.event($0) }
        for stack in stacks {
            let event = workspace.assignedEvent(for: stack).event ?? boardEvent
            for item in stack.items where Self.isGradable(item) {
                guard let recipe = recipe(for: item) else {
                    plan.refusals.append("\(item.primary.name) has no grade.")
                    continue
                }
                guard isAvailable(recipe) else {
                    plan.refusals.append("\(item.primary.name): its look is not available (\(lookName(recipe.grade.look))).")
                    continue
                }
                guard let event else {
                    plan.refusals.append("\(item.primary.name) is not in an event yet — sort it first, so its copy has an Edited folder to go to.")
                    continue
                }
                guard let edited = editedRoot(for: item, event: event) else {
                    plan.refusals.append("\(item.primary.name): the drive for \(event.name) isn't connected.")
                    continue
                }
                plan.eventIDs.insert(event.id)
                let output = GradedRenderNaming.outputFolder(editedRoot: edited)
                // On the drive, the NAS copy of the folder is checked too:
                // a copy Sync already carried counts, and its name is never
                // reused for another render.
                let onNAS = output.path.hasPrefix(workspace.locations.nasRoot.standardizedFileURL.path + "/")
                plan.requests.append(GradedRenderRequest(
                    source: item.primary.url,
                    recipe: recipe,
                    sourceKey: Self.fileKey(item.primary),
                    sourceModifiedAt: item.primary.modifiedAt,
                    outputFolder: output,
                    mirrorFolder: onNAS ? nil : workspace.locations.nasMirrorURL(forDrivePath: output.path)
                ))
            }
        }
        return plan
    }

    /// Queues one job that renders every graded clip among `stacks`.
    func renderGradedCopies(of stacks: [OrganizeStack], boardEventID: UUID?) {
        let plan = renderPlan(for: stacks, boardEventID: boardEventID)
        guard !plan.requests.isEmpty else {
            model.statusMessage = plan.refusals.first ?? "Nothing to render — none of these clips has a grade."
            return
        }
        enqueueRender(plan, reason: nil)
    }

    // MARK: Render before Sync

    /// What a before-sync render would do, shown before it starts.
    struct RenderBeforeSyncSummary: Equatable {
        var count: Int
        var alreadyThere: Int
        var estimatedBytes: Int64
        var freeBytes: Int64?
        var isFirstRun: Bool
    }

    enum RenderBeforeSyncChoice: Equatable {
        case renderThenSync
        case syncOnly
        case cancel
    }

    /// More copies than this in one run always ask first.
    static let renderBeforeSyncAskAbove = 5
    static let renderBeforeSyncConfirmedKey = "CameraToolkit.renderBeforeSyncConfirmed"

    /// With "Send graded versions of log videos to Immich" on, works out
    /// which graded copies the synced events still need. With none, the
    /// sync starts as it always did (`syncNow`). Otherwise — after asking
    /// on the first run and whenever there are more than a handful — it
    /// queues the render job and then the Sync itself as a queued file job
    /// right behind it (`queueSync`, handed the queued job's id), so the
    /// Sync keeps its place whatever the render does: done, failed, stopped
    /// or taken off the queue.
    func renderBeforeSyncIfWanted(
        events: [SavedCameraEvent],
        syncTitle: String,
        syncNow: @escaping @MainActor () -> Void,
        queueSync: @escaping @MainActor (UUID) -> Void
    ) {
        guard model.configuration.renderGradedCopiesBeforeSync else {
            syncNow()
            return
        }
        var policies: [UUID: EventStoragePolicy] = [:]
        for event in events { policies[event.id] = workspace.resolvedPolicy(for: event) }
        let resolved = policies
        let inputs = GradedSyncPlanner.Inputs(
            events: events,
            assignments: model.configuration.photoEventAssignments,
            locations: workspace.locations,
            policy: { resolved[$0.id] ?? .buffer },
            grades: model.colorGradesSnapshot,
            resolver: resolver
        )
        let renderer = self.renderer
        model.statusMessage = "Looking for graded log clips to render before the sync…"
        Task { @MainActor [weak self] in
            let survey = await Task.detached(priority: .userInitiated) {
                Self.surveyBeforeSync(inputs, renderer: renderer)
            }.value
            guard let self else { return }
            guard !survey.pending.isEmpty else {
                syncNow()
                return
            }
            let firstRun = !UserDefaults.standard.bool(forKey: Self.renderBeforeSyncConfirmedKey)
            let summary = RenderBeforeSyncSummary(
                count: survey.pending.count, alreadyThere: survey.alreadyThere,
                estimatedBytes: survey.estimatedBytes, freeBytes: survey.freeBytes, isFirstRun: firstRun
            )
            var choice = RenderBeforeSyncChoice.renderThenSync
            if firstRun || summary.count > Self.renderBeforeSyncAskAbove {
                choice = confirmRenderBeforeSync(summary)
            }
            switch choice {
            case .cancel:
                model.statusMessage = "Nothing was rendered or synced."
            case .syncOnly:
                syncNow()
            case .renderThenSync:
                UserDefaults.standard.set(true, forKey: Self.renderBeforeSyncConfirmedKey)
                var plan = RenderPlan()
                plan.requests = survey.pending
                plan.eventIDs = Set(events.map(\.id))
                enqueueRender(plan, reason: "Before Sync to NAS: Rec.709 copies of graded log clips into Edited/\(GradedRenderNaming.folderName), so they reach the NAS and Immich.")
                model.enqueueFileJob(
                    action: .syncBuffer,
                    queuedNote: "Sync \(syncTitle) to the NAS.",
                    detail: "Starts after the graded copies, whether or not every copy was made. Copies only files missing on the NAS and verifies each one.",
                    skippedNote: "Did not start: the NAS was not connected when its turn came. Nothing changed.",
                    start: queueSync
                )
            }
        }
    }

    struct BeforeSyncSurvey: Sendable {
        var pending: [GradedRenderRequest] = []
        var alreadyThere = 0
        var estimatedBytes: Int64 = 0
        var freeBytes: Int64?
    }

    /// The planner's requests with each clip's probed signal range (the
    /// same source a manual render uses), minus copies already made.
    nonisolated static func surveyBeforeSync(_ inputs: GradedSyncPlanner.Inputs, renderer: GradeRenderer) -> BeforeSyncSurvey {
        let found = GradedSyncPlanner.requests(
            inputs,
            detect: { LogProfileDetector.profile(clipBesideSidecar: $0) },
            range: { _ in .full }
        )
        var survey = BeforeSyncSurvey()
        for var request in found {
            request.recipe.range = probedRange(request.source, renderer: renderer) ?? request.recipe.range
            if GradedVideoExporter.existingRender(of: request) != nil {
                survey.alreadyThere += 1
                continue
            }
            survey.estimatedBytes += GradedVideoExporter.estimatedBytes(of: request.source) ?? 0
            survey.pending.append(request)
        }
        survey.freeBytes = survey.pending.first.flatMap { GradedVideoExporter.availableBytes(near: $0.outputFolder) }
        return survey
    }

    nonisolated static func probedRange(_ url: URL, renderer: GradeRenderer) -> VideoSignalRange? {
        final class Box: @unchecked Sendable { var range: VideoSignalRange? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.range = await renderer.signalRange(of: url)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 20)
        return box.range
    }

    // MARK: Render job

    func enqueueRender(_ plan: RenderPlan, reason: String?) {
        let requests = plan.requests
        let count = requests.count
        let refusals = plan.refusals
        let eventIDs = plan.eventIDs
        let title = "Render \(count) graded cop\(count == 1 ? "y" : "ies")"
        let detail = reason ?? "Rec.709 HEVC copies into Edited/\(GradedRenderNaming.folderName). Originals are only read."
        let renderer = self.renderer
        model.enqueueFileJob(
            action: .gradeRender,
            queuedNote: "\(title).",
            detail: detail,
            skippedNote: "Did not start: nothing to render. Nothing changed."
        ) { [weak self] (jobID: UUID) in
            guard let self else { return }
            let stop = RenderStopFlag()
            model.registerStop(jobID: jobID) { stop.stop() }
            let model = self.model
            model.runBackgroundJob(
                action: .gradeRender,
                runningNote: "\(title)…",
                logTitle: title,
                logDetail: detail,
                onSettled: { @MainActor in model.unregisterStop(jobID: jobID) },
                jobID: jobID,
                operation: { progress in
                    try Self.runRender(requests, renderer: renderer, isStopped: { stop.isStopped }, progress: progress)
                },
                completion: { [weak self] (outcome: RenderOutcome) in
                    for eventID in eventIDs { self?.workspace.refreshEditTags(for: eventID) }
                    return Self.summary(outcome, refusals: refusals)
                }
            )
        }
    }

    struct RenderOutcome: Sendable {
        var rendered: [URL] = []
        var alreadyThere: [URL] = []
        /// New copies saved beside an older copy of the same clip.
        var besideOlder: [URL] = []
        var failures: [String] = []
        /// Why the job stopped before the end (Stop, or not enough space).
        var stoppedReason: String?
    }

    /// Room kept free on the volume a copy is written to.
    nonisolated static let freeSpaceMargin: Int64 = 5 * 1_024 * 1_024 * 1_024

    nonisolated static func runRender(
        _ requests: [GradedRenderRequest],
        renderer: GradeRenderer = .shared,
        exporter: GradedVideoExporter? = nil,
        isStopped: @escaping @Sendable () -> Bool = { false },
        availableBytes: (URL) -> Int64? = { GradedVideoExporter.availableBytes(near: $0) },
        estimatedBytes: (URL) -> Int64? = { GradedVideoExporter.estimatedBytes(of: $0) },
        progress: @escaping @Sendable (BackgroundJobUpdate) -> Void
    ) throws -> RenderOutcome {
        let exporter = exporter ?? GradedVideoExporter(renderer: renderer)
        var outcome = RenderOutcome()
        let total = requests.count
        // A crash or a Stop can leave partials: clear them first, in every
        // folder this job touches, whatever it goes on to render.
        for folder in Set(requests.map(\.outputFolder)) {
            GradedRenderNaming.removeStalePartials(in: folder)
        }
        for (index, base) in requests.enumerated() {
            if isStopped() {
                outcome.stoppedReason = "Stopped after \(index) of \(total)."
                break
            }
            var prepared = base
            // One range source for every render: the clip's own format.
            prepared.recipe.range = probedRange(prepared.source, renderer: renderer) ?? prepared.recipe.range
            let sidecar = LogProfileDetector.sonySidecarDevice(forClip: prepared.source)
            prepared.make = sidecar?.make
            prepared.model = sidecar?.model
            let request = prepared
            let name = request.source.lastPathComponent
            progress(BackgroundJobUpdate(
                progress: Double(index) / Double(total),
                note: "Rendering \(index + 1) of \(total) · \(name)",
                phase: "Render",
                sourcePath: request.source.path,
                destinationPath: request.outputFolder.path,
                currentPath: request.source.path,
                processedFiles: index,
                totalFiles: total
            ))
            if let existing = GradedVideoExporter.existingRender(of: request) {
                outcome.alreadyThere.append(existing)
                continue
            }
            if let need = estimatedBytes(request.source), let free = availableBytes(request.outputFolder),
               free < need + freeSpaceMargin {
                let formatter = ByteCountFormatter()
                outcome.stoppedReason = "Stopped before \(name): \(formatter.string(fromByteCount: max(free, 0))) free where the copy goes; it needs about \(formatter.string(fromByteCount: need)) plus \(formatter.string(fromByteCount: freeSpaceMargin)) kept free."
                break
            }
            do {
                let result = try exporter.render(request, progress: { step in
                    progress(BackgroundJobUpdate(
                        progress: (Double(index) + step.fraction) / Double(total),
                        note: "Rendering \(index + 1) of \(total) · \(name) · \(Int(step.fraction * 100))%",
                        phase: "Render",
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
            throw ToolkitError.commandFailed("No graded copy was made. \(first)")
        }
        return outcome
    }

    nonisolated static func summary(_ outcome: RenderOutcome, refusals: [String]) -> String {
        var parts: [String] = []
        if let stopped = outcome.stoppedReason { parts.append(stopped) }
        if !outcome.rendered.isEmpty {
            parts.append("Rendered \(outcome.rendered.count) graded cop\(outcome.rendered.count == 1 ? "y" : "ies") into Edited/\(GradedRenderNaming.folderName)")
        }
        if !outcome.besideOlder.isEmpty {
            parts.append("\(outcome.besideOlder.count) sit\(outcome.besideOlder.count == 1 ? "s" : "") beside an older copy of the same clip with its earlier grade — the older copy is kept; remove it in Edited/\(GradedRenderNaming.folderName) if you no longer want it")
        }
        if !outcome.alreadyThere.isEmpty {
            parts.append("\(outcome.alreadyThere.count) already there unchanged")
        }
        if !outcome.failures.isEmpty {
            parts.append("\(outcome.failures.count) failed (\(outcome.failures[0]))")
        }
        if !refusals.isEmpty {
            parts.append("\(refusals.count) skipped (\(refusals[0]))")
        }
        return parts.joined(separator: "; ") + ". Originals untouched; Sync to NAS carries the copies."
    }
}

/// Set by Stop in the Jobs window; the render checks it between frames.
final class RenderStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }
}
