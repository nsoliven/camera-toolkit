import CameraToolkitCore
import Foundation

/// Rendering graded copies into the event's `Edited/Rec709` folder.
extension ClipGrading {
    struct RenderPlan {
        var requests: [GradedRenderRequest] = []
        var eventIDs: Set<UUID> = []
        /// Why some clips were left out, one line each.
        var refusals: [String] = []
        /// Said with the job (clips set to Stabilize rendered graded only).
        var notes: [String] = []
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
                    // Stabilized without a grade: a stabilized-only copy.
                    if stabilizing.settings(for: item) != nil { continue }
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
                // On the NAS, the drive's folder is checked the same way: a
                // drive copy not synced yet keeps its name.
                let onNAS = output.path.hasPrefix(workspace.locations.nasRoot.standardizedFileURL.path + "/")
                let policy = workspace.resolvedPolicy(for: event)
                if let note = stabilizing.unavailableNote(forKeys: [Self.fileKey(item.primary)]), plan.notes.isEmpty {
                    plan.notes.append(note)
                }
                plan.requests.append(GradedRenderRequest(
                    source: item.primary.url,
                    recipe: recipe,
                    sourceKey: Self.fileKey(item.primary),
                    sourceModifiedAt: item.primary.modifiedAt,
                    outputFolder: output,
                    mirrorFolder: onNAS
                        ? GradedRenderNaming.outputFolder(editedRoot: workspace.locations.editedRoot(for: event, policy: policy))
                        : workspace.locations.nasMirrorURL(forDrivePath: output.path),
                    stabilization: stabilizing.renderStabilization(forKey: Self.fileKey(item.primary))
                ))
            }
        }
        return plan
    }

    /// Queues one job that renders every graded clip among `stacks`.
    func renderGradedCopies(of stacks: [OrganizeStack], boardEventID: UUID?, includeStabilizeOnly: Bool = true) {
        // Which clips are stabilized depends on Gyroflow: wait for the search
        // (only when a clip here is set to Stabilize, and not forever).
        let keys = stacks.flatMap(\.items).map { Self.fileKey($0.primary) }
        if stabilizing.needsAvailabilityWait(forKeys: keys) {
            Task { @MainActor [weak self] in
                await self?.stabilizing.ensureAvailability(forKeys: keys)
                self?.renderGradedCopiesNow(of: stacks, boardEventID: boardEventID, includeStabilizeOnly: includeStabilizeOnly)
            }
            return
        }
        renderGradedCopiesNow(of: stacks, boardEventID: boardEventID, includeStabilizeOnly: includeStabilizeOnly)
    }

    private func renderGradedCopiesNow(of stacks: [OrganizeStack], boardEventID: UUID?, includeStabilizeOnly: Bool) {
        let plan = renderPlan(for: stacks, boardEventID: boardEventID)
        // Stabilized clips without a grade get their stabilized-only copy.
        let stabilizeOnly = includeStabilizeOnly ? stabilizing.stabilizeOnlyItems(in: stacks) : []
        if !stabilizeOnly.isEmpty {
            stabilizing.renderStabilizedCopies(of: stabilizeOnly, in: stacks, boardEventID: boardEventID)
            if plan.requests.isEmpty { return }
        }
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
        /// Copies whose existing file could not be checked in time (a
        /// sleeping NAS); the render checks them again and never makes a
        /// duplicate.
        var unchecked: Int = 0
        /// Copies that are stabilized first (clips set to Stabilize).
        var stabilized: Int = 0
    }

    enum RenderBeforeSyncChoice: Equatable {
        case renderThenSync
        /// Render, but grade only: the Stabilize box was unticked.
        case renderThenSyncWithoutStabilizing
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
        let model = self.model
        let stabilizing = self.stabilizing
        model.statusMessage = "Looking for graded log clips to render before the sync…"
        let plannedKeys = Self.plannedKeys(inputs)
        Task { @MainActor [weak self] in
            // Which clips are stabilized depends on Gyroflow: wait for the
            // search, only when a clip here is set to Stabilize, at most
            // `availabilityWaitLimit` (then those render graded only).
            await stabilizing.ensureAvailability(forKeys: plannedKeys)
            let stabilization = stabilizing.renderStabilizationMap()
            let survey = await Task.detached(priority: .userInitiated) {
                Self.surveyBeforeSync(inputs, renderer: renderer, stabilization: stabilization, progress: { done, total in
                    Task { @MainActor in
                        model.statusMessage = "Checking which graded copies are already made: \(done) of \(total)…"
                    }
                })
            }.value
            guard let self else { return }
            guard !survey.pending.isEmpty else {
                syncNow()
                return
            }
            let firstRun = !UserDefaults.standard.bool(forKey: Self.renderBeforeSyncConfirmedKey)
            let summary = RenderBeforeSyncSummary(
                count: survey.pending.count, alreadyThere: survey.alreadyThere,
                estimatedBytes: survey.estimatedBytes, freeBytes: survey.freeBytes, isFirstRun: firstRun,
                unchecked: survey.unchecked,
                stabilized: survey.pending.count { $0.stabilization != nil }
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
            case .renderThenSync, .renderThenSyncWithoutStabilizing:
                UserDefaults.standard.set(true, forKey: Self.renderBeforeSyncConfirmedKey)
                var plan = RenderPlan()
                plan.requests = choice == .renderThenSync ? survey.pending : survey.pending.map { request in
                    var request = request
                    request.stabilization = nil
                    return request
                }
                plan.eventIDs = Set(events.map(\.id))
                if let note = stabilizing.unavailableNote(forKeys: survey.pending.map(\.sourceKey)) { plan.notes.append(note) }
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

    /// The file keys of every clip a before-sync or send plan could take,
    /// from the catalog alone (no file or Gyroflow access).
    static func plannedKeys(_ inputs: GradedSyncPlanner.Inputs) -> Set<String> {
        let events = Set(inputs.events.map(\.id))
        return Set(inputs.assignments.filter { events.contains($0.eventID) }.map { assignment in
            FaceIndexStore.fileKey(fileName: (assignment.relativePath as NSString).lastPathComponent, byteCount: assignment.fileSize, modifiedAt: assignment.modifiedAt)
        })
    }

    struct BeforeSyncSurvey: Sendable {
        var pending: [GradedRenderRequest] = []
        var alreadyThere = 0
        var unchecked = 0
        var estimatedBytes: Int64 = 0
        var freeBytes: Int64?
        /// Where each copy already made is, by its original (`sourceKey`).
        var existing: [String: URL] = [:]
    }

    /// How many clips are checked at once, and how long the whole check
    /// may take: on a sleeping NAS each tag read can wait, and the user is
    /// waiting for the sync to start.
    nonisolated static let surveyWidth = 8
    nonisolated static let surveyBudget: TimeInterval = 30

    /// The planner's requests with each clip's probed signal range (the
    /// same source a manual render uses), minus copies already made.
    /// Clips are checked `surveyWidth` at a time within `budget`; a clip
    /// whose existing copy did not answer in time stays in the plan as
    /// unchecked (its render looks again and refuses to duplicate).
    nonisolated static func surveyBeforeSync(
        _ inputs: GradedSyncPlanner.Inputs,
        renderer: GradeRenderer,
        stabilization: [String: RenderStabilization] = [:],
        budget: TimeInterval = surveyBudget,
        check: (@Sendable (GradedRenderRequest, TimeInterval) -> GradedVideoExporter.ExistingRenderCheck)? = nil,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) -> BeforeSyncSurvey {
        let found = GradedSyncPlanner.requests(
            inputs,
            detect: { LogProfileDetector.profile(clipBesideSidecar: $0) },
            range: { _ in .full }
        ).map { request in
            // A clip set to Stabilize needs its stabilized copy, so a plain
            // graded copy already there does not count as made.
            var request = request
            request.stabilization = stabilization[request.sourceKey]
            return request
        }
        return survey(found, renderer: renderer, budget: budget, check: check, progress: progress)
    }

    nonisolated static func survey(
        _ found: [GradedRenderRequest],
        renderer: GradeRenderer,
        budget: TimeInterval = surveyBudget,
        check: (@Sendable (GradedRenderRequest, TimeInterval) -> GradedVideoExporter.ExistingRenderCheck)? = nil,
        estimate: @escaping @Sendable (URL) -> Int64? = { GradedVideoExporter.estimatedBytes(of: $0) },
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) -> BeforeSyncSurvey {
        enum Answer: Sendable { case pending(GradedRenderRequest, Int64), already(String, URL), unchecked(GradedRenderRequest) }
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var answers: [Int: Answer] = [:]
            var done = 0
        }
        let results = Results()
        let deadline = Date().addingTimeInterval(budget)
        let check = check ?? { request, timeout in GradedVideoExporter.existingRenderCheck(of: request, timeout: timeout) }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = surveyWidth
        queue.qualityOfService = .userInitiated
        let total = found.count
        for (index, base) in found.enumerated() {
            queue.addOperation {
                var request = base
                let remaining = deadline.timeIntervalSinceNow
                let answer: Answer
                if remaining <= 0 {
                    answer = .unchecked(request)
                } else {
                    request.recipe.range = probedRange(request.source, renderer: renderer, timeout: min(remaining, 20)) ?? request.recipe.range
                    switch check(request, max(0.5, min(deadline.timeIntervalSinceNow, 20))) {
                    case .found(let url): answer = .already(request.sourceKey, url)
                    case .unknown: answer = .unchecked(request)
                    case .none: answer = .pending(request, estimate(request.source) ?? 0)
                    }
                }
                let done = results.lock.withLock { () -> Int in
                    results.answers[index] = answer
                    results.done += 1
                    return results.done
                }
                progress(done, total)
            }
        }
        // Wait for the checks, but never past the budget (plus a moment for
        // reads already given a shorter timeout to come back).
        let waited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            queue.waitUntilAllOperationsAreFinished()
            waited.signal()
        }
        if waited.wait(timeout: .now() + budget + 2) == .timedOut { queue.cancelAllOperations() }
        var survey = BeforeSyncSurvey()
        let answers = results.lock.withLock { results.answers }
        for index in found.indices {
            switch answers[index] {
            case .already(let key, let url)?:
                survey.alreadyThere += 1
                survey.existing[key] = url
            case .pending(let request, let bytes)?:
                survey.pending.append(request)
                survey.estimatedBytes += bytes
            case .unchecked(let request)?:
                survey.unchecked += 1
                survey.pending.append(request)
            case nil:
                survey.unchecked += 1
                survey.pending.append(found[index])
            }
        }
        survey.freeBytes = survey.pending.first.flatMap { GradedVideoExporter.availableBytes(near: $0.outputFolder) }
        return survey
    }

    nonisolated static func probedRange(_ url: URL, renderer: GradeRenderer, timeout: TimeInterval = 20) -> VideoSignalRange? {
        final class Box: @unchecked Sendable { var range: VideoSignalRange? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.range = await renderer.signalRange(of: url)
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        return box.range
    }

    // MARK: Render job

    func enqueueRender(_ plan: RenderPlan, reason: String?) {
        let requests = plan.requests
        let count = requests.count
        let refusals = plan.refusals
        let eventIDs = plan.eventIDs
        let title = "Render \(count) graded cop\(count == 1 ? "y" : "ies")"
        let stabilized = requests.count { $0.stabilization != nil }
        let detail = (reason ?? "Rec.709 HEVC copies into Edited/\(GradedRenderNaming.folderName). Originals are only read.")
            + (stabilized > 0 ? " \(stabilized) stabilized first with Gyroflow." : "")
            + plan.notes.map { " " + $0 }.joined()
        let renderer = self.renderer
        let stabilizer = stabilizing.stabilizerForRender(requests)
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
                    try Self.runRender(requests, renderer: renderer, stabilizer: stabilizer, isStopped: { stop.isStopped }, progress: progress)
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
        /// Where each request's copy is (made now or already there), by its
        /// index in the requests.
        var copies: [Int: URL] = [:]
    }

    /// Room kept free on the volume a copy is written to.
    nonisolated static let freeSpaceMargin: Int64 = 5 * 1_024 * 1_024 * 1_024

    nonisolated static func runRender(
        _ requests: [GradedRenderRequest],
        renderer: GradeRenderer = .shared,
        exporter: GradedVideoExporter? = nil,
        stabilizer: Stabilizer? = nil,
        isStopped: @escaping @Sendable () -> Bool = { false },
        availableBytes: (URL) -> Int64? = { GradedVideoExporter.availableBytes(near: $0) },
        estimatedBytes: (URL) -> Int64? = { GradedVideoExporter.estimatedBytes(of: $0) },
        stabilizedBytes: (URL) -> Int64? = { Stabilizer.estimatedBytes(of: $0) },
        frameRate: (URL) -> Double? = { GradedVideoExporter.nominalFrameRate(of: $0) },
        progress: @escaping @Sendable (BackgroundJobUpdate) -> Void
    ) throws -> RenderOutcome {
        let exporter = exporter ?? GradedVideoExporter(renderer: renderer)
        var outcome = RenderOutcome()
        let total = requests.count
        let tally = RenderFrameTally()
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
            let steps = request.stabilization == nil ? [RenderFrameTally.grade] : [RenderFrameTally.stabilize, RenderFrameTally.grade]
            let clip = index + 1
            progress(BackgroundJobUpdate(
                progress: Double(index) / Double(total),
                note: "Rendering \(index + 1) of \(total) · \(name)",
                phase: "Render",
                sourcePath: request.source.path,
                destinationPath: request.outputFolder.path,
                currentPath: request.source.path,
                processedFiles: index,
                totalFiles: total,
                telemetry: tally.telemetry(step: steps[0], steps: steps, frame: 0, totalFrames: nil, videoFrameRate: nil, clip: clip, of: total)
            ))
            if let existing = GradedVideoExporter.existingRender(of: request) {
                outcome.alreadyThere.append(existing)
                outcome.copies[index] = existing
                continue
            }
            // A stabilized render also holds its ProRes intermediate (several
            // GB a minute at UHD) beside the copy until the copy is made.
            let intermediate = request.stabilization == nil ? nil : stabilizedBytes(request.source)
            let copy = estimatedBytes(request.source)
            if copy != nil || intermediate != nil, let free = availableBytes(request.outputFolder) {
                let need = (copy ?? 0) + (intermediate ?? 0)
                if free < need + freeSpaceMargin {
                    let formatter = ByteCountFormatter()
                    let what = intermediate.map { "about \(formatter.string(fromByteCount: need)) (\(formatter.string(fromByteCount: $0)) of it the stabilized intermediate, deleted after)" }
                        ?? "about \(formatter.string(fromByteCount: need))"
                    outcome.stoppedReason = "Stopped before \(name): \(formatter.string(fromByteCount: max(free, 0))) free where the copy goes; it needs \(what) plus \(formatter.string(fromByteCount: freeSpaceMargin)) kept free."
                    break
                }
            }
            // Stabilize first (the first half of this clip's progress), then
            // grade from the stabilized intermediate, which is deleted after.
            var chain: StabilizedGradeChain.Prepared?
            defer { StabilizedGradeChain.cleanUp(chain) }
            let share = request.stabilization == nil ? 0.0 : 0.5
            do {
                var graded = request
                var stabilizedFrames: Int?
                if request.stabilization != nil {
                    let clipRate = frameRate(request.source)
                    tally.beginStep()
                    defer { stabilizedFrames = tally.endStep() }
                    chain = try StabilizedGradeChain.prepare(
                        request, stabilizer: stabilizer,
                        rangeOf: { probedRange($0, renderer: renderer) },
                        progress: { step in
                            progress(BackgroundJobUpdate(
                                progress: (Double(index) + step.fraction * share) / Double(total),
                                note: "Stabilizing \(index + 1) of \(total) · \(name) · \(StabilizeWording.phase(step))",
                                phase: "Stabilize",
                                currentPath: request.source.path,
                                processedFiles: index,
                                totalFiles: total,
                                telemetry: tally.telemetry(
                                    step: RenderFrameTally.stabilize, steps: steps, frame: step.frame,
                                    totalFrames: step.totalFrames > 0 ? step.totalFrames : nil,
                                    videoFrameRate: clipRate, clip: clip, of: total
                                )
                            ))
                        },
                        isCancelled: isStopped
                    )
                    graded = chain!.request
                }
                tally.beginStep()
                defer { _ = tally.endStep() }
                // The stabilized intermediate has exactly the frames Gyroflow
                // counted; a plain clip's are length × frame rate.
                let gradeFrames = stabilizedFrames.flatMap { $0 > 0 ? $0 : nil }
                let result = try exporter.render(graded, progress: { step in
                    progress(BackgroundJobUpdate(
                        progress: (Double(index) + share + step.fraction * (1 - share)) / Double(total),
                        note: "Rendering \(index + 1) of \(total) · \(name) · \(Int(step.fraction * 100))%",
                        phase: "Render",
                        currentPath: request.source.path,
                        processedFiles: index,
                        totalFiles: total,
                        telemetry: tally.telemetry(
                            step: RenderFrameTally.grade, steps: steps, frame: step.framesWritten,
                            totalFrames: gradeFrames ?? step.totalFrames, videoFrameRate: step.frameRate,
                            clip: clip, of: total
                        )
                    ))
                }, isCancelled: isStopped)
                switch result {
                case .rendered(let url, let beside):
                    outcome.rendered.append(url)
                    if !beside.isEmpty { outcome.besideOlder.append(url) }
                case .alreadyRendered(let url):
                    outcome.alreadyThere.append(url)
                }
                outcome.copies[index] = result.url
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

/// Counts a render job's frames across its steps and clips, so the Jobs
/// window measures the job's speed from one counter that only goes up.
/// Its reports arrive from Gyroflow's reader and the encoder's queue.
final class RenderFrameTally: @unchecked Sendable {
    static let stabilize = "Stabilize"
    static let grade = "Grade"

    private let lock = NSLock()
    /// Frames of steps already over.
    private var finished = 0
    /// Frames the running step has made, of the total it last reported.
    private var current = 0
    private var currentTotal: Int?

    /// A step starts counting from zero.
    func beginStep() {
        lock.withLock {
            finished += current
            current = 0
            currentTotal = nil
        }
    }

    /// The step is over (made, failed or stopped); returns the frames it
    /// said it would make, or those it made when it never said.
    @discardableResult
    func endStep() -> Int {
        lock.withLock {
            let made = currentTotal ?? current
            finished += current
            current = 0
            currentTotal = nil
            return made
        }
    }

    /// The running step reached `frame`; the telemetry the update carries.
    func telemetry(
        step: String,
        steps: [String],
        frame: Int,
        totalFrames: Int?,
        videoFrameRate: Double?,
        clip: Int,
        of clipCount: Int
    ) -> JobTelemetry {
        let done: Int = lock.withLock {
            current = max(current, frame)
            if let totalFrames { currentTotal = totalFrames }
            return finished + current
        }
        return JobTelemetry(frames: JobFrameProgress(
            step: step,
            steps: steps,
            frame: max(frame, 0),
            totalFrames: totalFrames,
            framesDone: done,
            videoFrameRate: videoFrameRate,
            clipIndex: clip,
            clipCount: clipCount
        ))
    }
}

/// Set by Stop in the Jobs window; the render checks it between frames.
final class RenderStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }
}
