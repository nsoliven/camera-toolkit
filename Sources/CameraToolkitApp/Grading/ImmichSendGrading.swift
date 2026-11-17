import CameraToolkitCore
import CoreGraphics
import Foundation
import Observation

/// The question Send to Immich asks, every time, when log clips of the
/// chosen events would reach Immich without a Rec.709 copy.
@MainActor
@Observable
final class ImmichSendGradeAsk: Identifiable {
    enum Stage: Equatable {
        /// Reading the events' clips (sidecars, copies already made).
        case checking(String)
        case asking
        /// The blanket look sheet for the pending clips.
        case choosingLooks
    }

    enum Answer: Equatable {
        /// Render with every option that is on, then send.
        case renderAndSend
        case chooseLooksFirst
        case sendAsTheyAre
        case cancel
    }

    /// One step a render before sending can do, shown as a checkbox. Grade
    /// is always first; a later step (post stabilization) adds its own kind
    /// and fills its setting into each request (`GradedRenderRequest
    /// .stabilization`) in `ClipGrading.applyRenderOptions`.
    struct RenderOption: Identifiable, Equatable {
        enum Kind: String, Equatable {
            case grade
            /// Stabilize first (`ClipStabilizing.stabilizeOption`).
            case stabilize
        }

        var id: Kind
        var title: String
        var detail: String
        var isOn: Bool
        var isAvailable = true
    }

    var options: [RenderOption] = [
        RenderOption(id: .grade, title: "Grade", detail: "Convert log to Rec.709 with each clip's grade (or the default conversion and look).", isOn: true),
    ]

    /// True when at least one step would render something.
    var rendersAnything: Bool { options.contains { $0.isOn && $0.isAvailable } }

    func isOn(_ kind: RenderOption.Kind) -> Bool {
        options.contains { $0.id == kind && $0.isOn && $0.isAvailable }
    }

    func setOption(_ kind: RenderOption.Kind, on: Bool) {
        guard let index = options.firstIndex(where: { $0.id == kind }) else { return }
        options[index].isOn = on
    }

    let id = UUID()
    let eventIDs: Set<UUID>
    var stage: Stage
    /// The clips that need a copy, with their recipes and where each copy goes.
    var pending: [GradedSyncPlanner.PlacedRequest] = []
    /// Names of the events those clips are in.
    var eventNames: [String] = []
    var estimatedBytes: Int64 = 0
    /// Copies already there that the check could not read in time: their
    /// render looks again first and never makes a second copy.
    var unchecked = 0
    /// NAS copies whose drive (and its `Edited/Rec709`) is not connected,
    /// so a copy made there and not synced yet cannot be checked.
    var driveAwayCount = 0
    /// Before/after frames of the first few clips.
    var previews: [BlanketGradeModel.Row] = []
    var blanket: BlanketGradeModel?

    init(eventIDs: Set<UUID>, stage: Stage) {
        self.eventIDs = eventIDs
        self.stage = stage
    }

    var count: Int { pending.count }
    var onNASCount: Int { pending.count { $0.placement == .nas } }
    var onDriveCount: Int { pending.count { $0.placement == .drive } }

    /// "Beach Day", "Beach Day and Trip 2026", "3 events".
    var eventsText: String {
        switch eventNames.count {
        case 0: "these events"
        case 1: eventNames[0]
        case 2: "\(eventNames[0]) and \(eventNames[1])"
        default: "\(eventNames.count) events"
        }
    }

    /// "3 log clips in Beach Day have no Rec.709 copy. Immich will show them flat."
    var headline: String {
        "\(count) log clip\(count == 1 ? "" : "s") in \(eventsText) \(count == 1 ? "has" : "have") no Rec.709 copy. Immich will show \(count == 1 ? "it" : "them") flat."
    }
}

/// Send to Immich with grading: before anything is sent, the chosen events'
/// log clips are checked (the before-sync planner's rules: explicit marks,
/// Not Log left out, Sony sidecars), and when any would reach Immich flat the
/// send asks first. A copy is rendered where its clip is — on the drive
/// (Sync carries it), or straight into the NAS event's `Edited/Rec709` when
/// the clip is only on the NAS — then the send scans, and each check puts the
/// copy in its original's place in the album (`ImmichGradedAlbumSwap`).
extension ClipGrading {
    nonisolated static let immichSendPreviewCount = 6

    /// The Send button. Always checks; asks whenever there is something to
    /// grade.
    func beginImmichSend(_ eventIDs: Set<UUID>) {
        guard !eventIDs.isEmpty, workspace.immichSend?.isFinished ?? true else { return }
        let ask = ImmichSendGradeAsk(eventIDs: eventIDs, stage: .checking("Looking for log clips without a Rec.709 copy…"))
        immichSendAsk = ask
        let inputs = sendPlanInputs(eventIDs)
        let readsNAS = NASDirectApply.isNASUsable(workspace.locations)
        let renderer = self.renderer
        let locations = workspace.locations
        let catalogURL = model.catalogURLForImmich
        let stabilizing = self.stabilizing
        Task { @MainActor [weak self] in
            // Which clips are stabilized depends on Gyroflow: wait for the search.
            await stabilizing.ensureAvailability()
            let stabilization = stabilizing.renderStabilizationMap()
            let found = await Task.detached(priority: .userInitiated) {
                Self.planImmichSend(inputs, readsNAS: readsNAS, renderer: renderer, stabilization: stabilization, progress: { done, total in
                    Task { @MainActor in
                        if case .checking = ask.stage, total > 0 {
                            ask.stage = .checking("Checking which clips already have a Rec.709 copy: \(done) of \(total)…")
                        }
                    }
                }, record: { placed, copies in
                    _ = Self.recordGradedCopies(placed, copies: copies, newlyRendered: [], locations: locations, catalogURL: catalogURL)
                })
            }.value
            guard let self, immichSendAsk === ask else { return }
            settlePlan(found, for: ask)
        }
    }

    /// What the send found: copies to make, and the survey's numbers.
    struct ImmichSendPlan: Sendable {
        var pending: [GradedSyncPlanner.PlacedRequest] = []
        var estimatedBytes: Int64 = 0
        var unchecked = 0
        var driveAwayCount = 0
    }

    func sendPlanInputs(_ eventIDs: Set<UUID>) -> GradedSyncPlanner.Inputs {
        let events = model.configuration.savedEvents.filter { eventIDs.contains($0.id) }
        var policies: [UUID: EventStoragePolicy] = [:]
        for event in events { policies[event.id] = workspace.resolvedPolicy(for: event) }
        let resolved = policies
        return GradedSyncPlanner.Inputs(
            events: events,
            assignments: model.configuration.photoEventAssignments.filter { eventIDs.contains($0.eventID) },
            locations: workspace.locations,
            policy: { resolved[$0.id] ?? .buffer },
            grades: model.colorGradesSnapshot,
            resolver: resolver
        )
    }

    /// The planner (drive and NAS), then the survey of copies already made.
    /// `record` is handed the clips whose copy is already there.
    nonisolated static func planImmichSend(
        _ inputs: GradedSyncPlanner.Inputs,
        readsNAS: Bool,
        renderer: GradeRenderer,
        stabilization: [String: RenderStabilization] = [:],
        check: (@Sendable (GradedRenderRequest, TimeInterval) -> GradedVideoExporter.ExistingRenderCheck)? = nil,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
        record: ([GradedSyncPlanner.PlacedRequest], [String: URL]) -> Void = { _, _ in },
        driveIsAvailable: (URL) -> Bool = { VolumeInfo.isAvailable($0) }
    ) -> ImmichSendPlan {
        let placed = GradedSyncPlanner.placedRequests(
            inputs,
            readsNAS: readsNAS,
            detect: { LogProfileDetector.profile(clipBesideSidecar: $0) },
            range: { _ in .full }
        ).map { item in
            // A clip set to Stabilize needs its stabilized copy.
            var item = item
            item.request.stabilization = stabilization[item.request.sourceKey]
            return item
        }
        guard !placed.isEmpty else { return ImmichSendPlan() }
        let survey = survey(placed.map(\.request), renderer: renderer, check: check, progress: progress)
        if !survey.existing.isEmpty { record(placed, survey.existing) }
        // The survey's requests carry each clip's probed signal range.
        let surveyed = Dictionary(survey.pending.map { ($0.sourceKey, $0) }) { first, _ in first }
        var plan = ImmichSendPlan(estimatedBytes: survey.estimatedBytes, unchecked: survey.unchecked)
        for var item in placed {
            guard let request = surveyed[item.request.sourceKey] else { continue }
            item.request = request
            plan.pending.append(item)
        }
        var available: [String: Bool] = [:]
        plan.driveAwayCount = plan.pending.count { item in
            guard item.placement == .nas, let drive = item.request.mirrorFolder else { return false }
            let root = driveRoot(of: drive, inputs.locations)
            if let known = available[root.path] { return !known }
            let isThere = driveIsAvailable(root)
            available[root.path] = isThere
            return !isThere
        }
        return plan
    }

    /// The Buffer or private staging root a drive path is under.
    nonisolated static func driveRoot(of url: URL, _ locations: EventStorageLocations) -> URL {
        let path = url.standardizedFileURL.path
        return [locations.bufferRoot, locations.privateStagingRoot]
            .sorted { $0.path.count > $1.path.count }
            .first { path.hasPrefix($0.path + "/") } ?? locations.bufferRoot
    }

    private func settlePlan(_ plan: ImmichSendPlan, for ask: ImmichSendGradeAsk) {
        guard !plan.pending.isEmpty else {
            immichSendAsk = nil
            startSend(ask.eventIDs)
            return
        }
        ask.pending = plan.pending
        ask.setStabilizeOption(stabilizing.stabilizeOption(for: plan.pending))
        ask.estimatedBytes = plan.estimatedBytes
        ask.unchecked = plan.unchecked
        ask.driveAwayCount = plan.driveAwayCount
        let pendingEvents = Set(plan.pending.map(\.eventID))
        ask.eventNames = model.configuration.savedEvents
            .filter { pendingEvents.contains($0.id) }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        ask.previews = previewRows(for: Array(plan.pending.prefix(Self.immichSendPreviewCount)))
        ask.stage = .asking
        loadPreviews(for: ask)
    }

    // MARK: Answers

    func answerImmichSendAsk(_ answer: ImmichSendGradeAsk.Answer) {
        guard let ask = immichSendAsk else { return }
        switch answer {
        case .cancel:
            immichSendAsk = nil
        case .sendAsTheyAre:
            immichSendAsk = nil
            startSend(ask.eventIDs)
        case .renderAndSend:
            guard ask.rendersAnything else {
                immichSendAsk = nil
                startSend(ask.eventIDs)
                return
            }
            gradeAndSend(ask)
        case .chooseLooksFirst:
            chooseLooks(for: ask)
        }
    }

    /// Back from the look sheet to the question, nothing changed.
    func cancelChoosingLooks() {
        guard let ask = immichSendAsk else { return }
        ask.blanket = nil
        ask.stage = .asking
    }

    /// The look sheet's Apply: the look on every pending clip (one Undo
    /// step), then render with it and send.
    func applyLooksAndSend() {
        guard let ask = immichSendAsk, let blanket = ask.blanket else { return }
        let keys = Set(blanket.rows.map(\.id))
        let before = model.colorGradesSnapshot
        var pairs: [(String, ClipGrade?)] = []
        for key in keys.sorted() {
            var grade = before[key] ?? ClipGrade()
            grade.look = blanket.look
            grade.intensity = blanket.look == .none ? 1 : blanket.intensity
            pairs.append((key, grade))
        }
        setGrades(byKey: pairs, undoTitle: "Apply \(lookName(blanket.look))", detail: "\(pairs.count) log clip\(pairs.count == 1 ? "" : "s") before Send to Immich")
        if blanket.alsoMakeDefault, blanket.profiles.count == 1, let profile = blanket.profiles.first {
            setDefaultLook(blanket.look, for: profile)
        }
        // The quick sheet's Stabilize choice, then each copy's stabilization
        // as it is now.
        stabilizing.applyBlanketChoice(blanket.stabilize, keys: keys.sorted())
        ask.pending = stabilizing.refreshStabilization(of: ask.pending)
        let option = stabilizing.stabilizeOption(for: ask.pending)
        ask.setStabilizeOption(option)
        // The copies are drawn with the grades as they are now.
        let resolver = self.resolver
        let grades = model.colorGradesSnapshot
        ask.pending = ask.pending.compactMap { item in
            var item = item
            let recipe = item.request.recipe
            guard let updated = resolver.recipe(explicit: grades[item.request.sourceKey], detected: recipe.profile, range: recipe.range),
                  updated.conversion.converts else { return item }
            item.request.recipe = updated
            return item
        }
        ask.blanket = nil
        gradeAndSend(ask)
    }

    /// Sets grades by file key, as one Undo step.
    func setGrades(byKey pairs: [(String, ClipGrade?)], undoTitle: String, detail: String? = nil) {
        let before = model.colorGradesSnapshot
        let changes = pairs.compactMap { key, grade in
            before[key] == grade ? nil : UndoGradeChange(key: key, before: before[key], after: grade)
        }
        guard !changes.isEmpty else { return }
        apply(changes, undo: false)
        workspace.recordUndo(undoTitle, detail: detail, .config(.colorGrades(changes)))
    }

    private func startSend(_ eventIDs: Set<UUID>) {
        if let startImmichSend {
            startImmichSend(eventIDs)
        } else {
            workspace.sendToImmich(eventIDs)
        }
    }

    // MARK: Choose looks first

    private func chooseLooks(for ask: ImmichSendGradeAsk) {
        let rows = ask.pending.compactMap { item -> BlanketGradeModel.Row? in
            guard let profile = item.request.recipe.profile else { return nil }
            let preview = ask.previews.first { $0.id == item.request.sourceKey }
            return BlanketGradeModel.Row(
                id: item.request.sourceKey,
                name: item.request.source.lastPathComponent,
                profile: profile,
                conversion: item.request.recipe.conversion,
                range: item.request.recipe.range,
                existing: model.colorGradesSnapshot[item.request.sourceKey],
                before: preview?.before
            )
        }
        let blanket = BlanketGradeModel(
            scopeTitle: "\(ask.count) log clip\(ask.count == 1 ? "" : "s") in \(ask.eventsText), before Send to Immich",
            lookName: { [weak self] in self?.lookName($0) ?? "" },
            renderer: renderer
        )
        blanket.conversionTitle = rows.first.map { conversionTitle($0.conversion, profile: $0.profile) } ?? ""
        blanket.load(rows: rows, notLogCount: 0, looks: availableLooks(for: rows.first?.profile))
        ask.blanket = blanket
        ask.stage = .choosingLooks
        let clips = ask.pending.map { (key: $0.request.sourceKey, url: $0.request.source) }
        Task { @MainActor [weak self] in await self?.stabilizing.fillBlanketChoice(blanket, clips: clips) }
        let missing = ask.pending.filter { item in !rows.contains { $0.id == item.request.sourceKey && $0.before != nil } }
        Task { @MainActor in
            for item in missing {
                let image = await TileImageLoader.shared.image(
                    for: item.request.source, maximumPixelSize: 384, priority: .high, fileIdentity: item.request.sourceKey
                )
                blanket.setBefore(image, for: item.request.sourceKey)
            }
        }
    }

    // MARK: Previews

    private func previewRows(for items: [GradedSyncPlanner.PlacedRequest]) -> [BlanketGradeModel.Row] {
        items.compactMap { item in
            guard let profile = item.request.recipe.profile else { return nil }
            return BlanketGradeModel.Row(
                id: item.request.sourceKey,
                name: item.request.source.lastPathComponent,
                profile: profile,
                conversion: item.request.recipe.conversion,
                range: item.request.recipe.range,
                existing: model.colorGradesSnapshot[item.request.sourceKey]
            )
        }
    }

    /// Each preview's poster frame (tiles have often decoded it already),
    /// then the same frame drawn with the clip's recipe.
    private func loadPreviews(for ask: ImmichSendGradeAsk) {
        let renderer = self.renderer
        let recipes = Dictionary(ask.pending.map { ($0.request.sourceKey, ($0.request.source, $0.request.recipe)) }) { first, _ in first }
        Task { @MainActor in
            for row in ask.previews {
                guard let (source, recipe) = recipes[row.id] else { continue }
                let before = await TileImageLoader.shared.image(for: source, maximumPixelSize: 384, priority: .high, fileIdentity: row.id)
                guard let before else { continue }
                let after = await Task.detached(priority: .userInitiated) { renderer.grade(before, recipe: recipe) }.value
                guard let index = ask.previews.firstIndex(where: { $0.id == row.id }) else { continue }
                ask.previews[index].before = before
                ask.previews[index].after = after ?? before
            }
        }
    }

    // MARK: Grade and send

    /// What the send's render job did.
    struct ImmichSendRenderResult: Sendable {
        var outcome: RenderOutcome
        var recordProblems: [String] = []
    }

    final class ImmichSendRenderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ImmichSendRenderResult?
        var result: ImmichSendRenderResult? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// The requests as the chosen options render them. Grade is the
    /// request's recipe itself; a later step sets its own field here (left
    /// nil, a request renders exactly as before).
    func applyRenderOptions(_ options: [ImmichSendGradeAsk.RenderOption], to items: [GradedSyncPlanner.PlacedRequest]) -> [GradedSyncPlanner.PlacedRequest] {
        guard options.contains(where: { $0.id == .grade && $0.isOn && $0.isAvailable }) else { return [] }
        let stabilizes = options.contains { $0.id == .stabilize && $0.isOn && $0.isAvailable }
        return stabilizes ? items : items.withoutStabilization()
    }

    private func gradeAndSend(_ ask: ImmichSendGradeAsk) {
        immichSendAsk = nil
        let items = applyRenderOptions(ask.options, to: ask.pending)
        guard !items.isEmpty else {
            startSend(ask.eventIDs)
            return
        }
        let count = items.count
        workspace.immichSend = ImmichSendState(phase: .rendering(count: count, detail: nil), eventCount: ask.eventIDs.count)
        let box = ImmichSendRenderBox()
        let jobID = enqueueSendRender(items, box: box)
        let eventIDs = ask.eventIDs
        workspace.immichSendTask = Task { @MainActor [weak self] in
            await self?.waitForSendRender(jobID: jobID, count: count, box: box, eventIDs: eventIDs)
        }
    }

    /// Follows the render job in the send's progress, then sends — or says
    /// why it did not. Stopping the send stops the render.
    private func waitForSendRender(jobID: UUID, count: Int, box: ImmichSendRenderBox, eventIDs: Set<UUID>) async {
        var settled: JobSnapshot?
        do {
            while true {
                guard let job = model.jobs.first(where: { $0.id == jobID }) else { break }
                if job.state != .queued, job.state != .running {
                    settled = job
                    break
                }
                let detail = job.state == .queued ? "Waiting for the running job to finish…" : job.note
                workspace.immichSend?.phase = .rendering(count: count, detail: detail)
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            // The send was stopped: so is its render (a partial copy is removed).
            if model.queuedFileJobs.contains(where: { $0.id == jobID }) {
                model.cancelQueuedFileJob(id: jobID)
            } else if model.stoppableJobIDs.contains(jobID) {
                model.stopJob(id: jobID)
            }
            return
        }
        guard !Task.isCancelled else { return }
        guard let result = box.result else {
            let why = settled.map { $0.state == .failed ? $0.note : "The render did not run (\($0.note))" } ?? "The render did not run"
            workspace.immichSend?.phase = .failed("\(why) Nothing was sent; send again to retry.")
            return
        }
        if let stopped = result.outcome.stoppedReason {
            workspace.immichSend?.phase = .failed("Rendering stopped: \(stopped) Nothing was sent; the copies already made are kept and are used next time.")
            return
        }
        let made = result.outcome.rendered.count
        let failed = result.outcome.failures.count
        workspace.immichSend = nil
        startSend(eventIDs)
        workspace.immichSend?.renderedCopies = made
        workspace.immichSend?.renderFailures = failed
    }

    /// Queues the render as a file job (it shows in Jobs with its progress
    /// and Stop), then writes down each copy and verifies the NAS ones.
    @discardableResult
    func enqueueSendRender(_ items: [GradedSyncPlanner.PlacedRequest], box: ImmichSendRenderBox) -> UUID {
        let requests = items.map(\.request)
        let count = items.count
        let onNAS = items.count { $0.placement == .nas }
        let title = "Render \(count) graded cop\(count == 1 ? "y" : "ies") for Immich"
        var where_: [String] = []
        if onNAS > 0 { where_.append("\(onNAS) into the NAS event folder") }
        if count - onNAS > 0 { where_.append("\(count - onNAS) on the drive (Sync to NAS carries them)") }
        let detail = "Before Send to Immich: Rec.709 copies of log clips into Edited/\(GradedRenderNaming.folderName), \(where_.joined(separator: ", ")). Originals are only read."
        let renderer = self.renderer
        let locations = workspace.locations
        let catalogURL = model.catalogURLForImmich
        let eventIDs = Set(items.map(\.eventID))
        let stabilizer = stabilizing.stabilizerForRender(requests)
        return model.enqueueFileJob(
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
                    let outcome = try Self.runRender(requests, renderer: renderer, stabilizer: stabilizer, isStopped: { stop.isStopped }, progress: progress)
                    var copies: [String: URL] = [:]
                    for (index, url) in outcome.copies { copies[requests[index].sourceKey] = url }
                    progress(BackgroundJobUpdate(progress: 0.99, note: "Checking the copies written to the NAS…", phase: "Verify"))
                    let problems = Self.recordGradedCopies(
                        items, copies: copies, newlyRendered: Set(outcome.rendered.map(\.standardizedFileURL.path)),
                        locations: locations, catalogURL: catalogURL
                    )
                    let result = ImmichSendRenderResult(outcome: outcome, recordProblems: problems)
                    box.result = result
                    return result
                },
                completion: { [weak self] (result: ImmichSendRenderResult) in
                    for eventID in eventIDs { self?.workspace.refreshEditTags(for: eventID) }
                    var summary = Self.summary(result.outcome, refusals: [])
                    if !result.recordProblems.isEmpty {
                        summary += " \(result.recordProblems.count) NAS cop\(result.recordProblems.count == 1 ? "y" : "ies") could not be checked (\(result.recordProblems[0]))."
                    }
                    return summary
                }
            )
        }
    }

    /// Writes down each clip's copy (`GradedCopyStore`) so Immich checks
    /// put it in the original's place, and records a copy on the NAS that
    /// Sync has no word on yet as verified there (`GradedNASRecorder`) —
    /// after re-reading it whole. A copy that fails that check is still a
    /// finished, verified render; it is reported and left as it is.
    @discardableResult
    nonisolated static func recordGradedCopies(
        _ items: [GradedSyncPlanner.PlacedRequest],
        copies: [String: URL],
        newlyRendered: Set<String>,
        locations: EventStorageLocations,
        catalogURL: URL,
        hasher: ((String, Int64) throws -> String)? = nil
    ) -> [String] {
        var problems: [String] = []
        var records: [GradedCopyRecord] = []
        let syncStore = try? NASSyncStore(catalogURL: catalogURL)
        var nasCopies: [(URL, UUID, String)] = []
        for item in items {
            guard let url = copies[item.request.sourceKey],
                  let original = item.originalRelativePath,
                  let graded = item.gradedRelativePath(forCopyAt: url, locations: locations) else { continue }
            records.append(GradedCopyRecord(eventID: item.eventID, originalRelativePath: original, gradedRelativePath: graded, sourceKey: item.request.sourceKey))
            if locations.nasRelativePath(url.path) != nil { nasCopies.append((url, item.eventID, graded)) }
        }
        // A NAS copy Sync (or an earlier render) already verified is not read again.
        let known = NASSyncStore.records(catalogURL: catalogURL, nasRoot: locations.nasRoot.path, pathKeys: nasCopies.map { NASSyncStore.pathKey($0.2) })
        for (url, eventID, graded) in nasCopies {
            let isNew = newlyRendered.contains(url.standardizedFileURL.path)
            if !isNew, known[NASSyncStore.pathKey(graded)]?.state == .verified { continue }
            do {
                if let hasher {
                    _ = try GradedNASRecorder.record(copyAt: url, eventID: eventID, locations: locations, store: syncStore, hasher: hasher)
                } else {
                    _ = try GradedNASRecorder.record(copyAt: url, eventID: eventID, locations: locations, store: syncStore)
                }
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        do {
            try GradedCopyStore(catalogURL: catalogURL).save(records)
        } catch {
            problems.append("graded copies not written down: \(error.localizedDescription)")
        }
        return problems
    }
}
