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
                guard renderer.pipeline(for: recipe).isLookAvailable else {
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
                plan.requests.append(GradedRenderRequest(
                    source: item.primary.url,
                    recipe: recipe,
                    sourceKey: Self.fileKey(item.primary),
                    sourceModifiedAt: item.primary.modifiedAt,
                    outputFolder: GradedRenderNaming.outputFolder(editedRoot: edited)
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

    /// With "Send graded versions of log videos to Immich" on, renders the
    /// graded copies of the synced events' log clips first, then runs
    /// `sync` once that job has settled (whether or not every copy worked).
    /// Off, or with nothing to render, `sync` runs at once.
    func renderBeforeSyncIfWanted(events: [SavedCameraEvent], sync: @escaping @MainActor () -> Void) {
        guard model.configuration.renderGradedCopiesBeforeSync else {
            sync()
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
            defaults: model.gradeDefaultsSnapshot,
            availableLUTs: Set(luts.map(\.id))
        )
        let renderer = self.renderer
        model.statusMessage = "Looking for graded log clips to render before the sync…"
        Task { @MainActor [weak self] in
            let requests = await Task.detached(priority: .userInitiated) { () -> [GradedRenderRequest] in
                var ranges: [String: VideoSignalRange] = [:]
                let found = GradedSyncPlanner.requests(
                    inputs,
                    detect: { LogProfileDetector.profile(clipBesideSidecar: $0) },
                    range: { url in ranges[url.path] ?? .full }
                )
                for request in found { ranges[request.source.path] = await renderer.signalRange(of: request.source) ?? request.recipe.range }
                return found.map { request in
                    var request = request
                    request.recipe.range = ranges[request.source.path] ?? request.recipe.range
                    return request
                }
            }.value
            guard let self else { return }
            guard !requests.isEmpty else {
                sync()
                return
            }
            var plan = RenderPlan()
            plan.requests = requests
            plan.eventIDs = Set(events.map(\.id))
            enqueueRender(plan, reason: "Before Sync to NAS: Rec.709 copies of graded log clips into Edited/\(GradedRenderNaming.folderName), so they reach the NAS and Immich.", afterSettled: sync)
        }
    }

    func enqueueRender(_ plan: RenderPlan, reason: String?, then: (@MainActor () -> Void)? = nil, afterSettled: (@MainActor () -> Void)? = nil) {
        let requests = plan.requests
        let count = requests.count
        let refusals = plan.refusals
        let eventIDs = plan.eventIDs
        let title = "Render \(count) graded cop\(count == 1 ? "y" : "ies")"
        let detail = reason ?? "Rec.709 HEVC copies into Edited/\(GradedRenderNaming.folderName). Originals are only read."
        model.enqueueFileJob(
            action: .gradeRender,
            queuedNote: "\(title).",
            detail: detail,
            skippedNote: "Did not start: nothing to render. Nothing changed."
        ) { [weak self] (jobID: UUID) in
            guard let self else { return }
            model.runBackgroundJob(
                action: .gradeRender,
                runningNote: "\(title)…",
                logTitle: title,
                logDetail: detail,
                onSettled: afterSettled.map { follow in { @MainActor @Sendable in Task { @MainActor in follow() } } },
                jobID: jobID,
                operation: { progress in
                    try Self.runRender(requests, progress: progress)
                },
                completion: { [weak self] (outcome: RenderOutcome) in
                    for eventID in eventIDs { self?.workspace.refreshEditTags(for: eventID) }
                    then?()
                    return Self.summary(outcome, refusals: refusals)
                }
            )
        }
    }

    struct RenderOutcome: Sendable {
        var rendered: [URL] = []
        var alreadyThere: [URL] = []
        var failures: [String] = []
    }

    nonisolated static func runRender(
        _ requests: [GradedRenderRequest],
        progress: @escaping @Sendable (BackgroundJobUpdate) -> Void
    ) throws -> RenderOutcome {
        let exporter = GradedVideoExporter()
        var outcome = RenderOutcome()
        let total = requests.count
        for (index, base) in requests.enumerated() {
            var prepared = base
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
                })
                switch result {
                case .rendered(let url): outcome.rendered.append(url)
                case .alreadyRendered(let url): outcome.alreadyThere.append(url)
                }
            } catch {
                outcome.failures.append("\(name): \(error.localizedDescription)")
            }
        }
        if outcome.rendered.isEmpty, outcome.alreadyThere.isEmpty, let first = outcome.failures.first {
            throw ToolkitError.commandFailed("No graded copy was made. \(first)")
        }
        return outcome
    }

    nonisolated static func summary(_ outcome: RenderOutcome, refusals: [String]) -> String {
        var parts: [String] = []
        if !outcome.rendered.isEmpty {
            parts.append("Rendered \(outcome.rendered.count) graded cop\(outcome.rendered.count == 1 ? "y" : "ies") into Edited/\(GradedRenderNaming.folderName)")
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
