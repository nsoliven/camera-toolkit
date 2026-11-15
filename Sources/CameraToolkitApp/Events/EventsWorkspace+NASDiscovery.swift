import CameraToolkitCore
import Foundation

/// A "Found on the NAS" folder Add to Events could not add anything from:
/// the listing it had then, and why.
struct NASAdoptRefusal: Equatable, Sendable {
    /// `NASAdoptRefusal.fingerprint(of:)` of the folder when it was refused.
    var fingerprint: String
    var reason: String

    /// The folder's uncovered files, by path, size and time: a folder whose
    /// listing changed is offered again.
    static func fingerprint(of folder: DiscoveredNASEvent) -> String {
        folder.cameras
            .flatMap { camera in camera.files.map { "\(camera.folderName)/\($0.path)|\($0.size)|\($0.modifiedAt.timeIntervalSinceReferenceDate)" } }
            .sorted()
            .joined(separator: "\n")
    }
}

/// "Found on the NAS": event folders in the NAS mirror whose files no
/// assignment covers — media that never sat on a drive the app knows —
/// and Add to Events, which lists them on their events as NAS-only files.
extension EventsWorkspace {
    /// Lists the NAS mirror off the main actor (`NASEventDiscovery`, one
    /// bulk listing per folder) and replaces the sidebar's list. A newer
    /// call cancels an older one. While NAS renames are queued the list is
    /// empty: an event's old NAS folder still looks unowned until they land.
    func discoverNASEvents() {
        nasDiscoveryTask?.cancel()
        guard pendingNASRenameCount == 0 else {
            discoveredNASEvents = []
            nasDiscoveryProblems = []
            return
        }
        let configuration = model.configuration
        let nasRoot = locations.nasRoot
        let gate = driveActivityGate
        let work = { Task.detached(priority: .utility) { () -> NASEventDiscoveryResult? in
            guard VolumeInfo.isAvailable(nasRoot) else { return NASEventDiscoveryResult() }
            guard gate.waitIfPaused(for: nasRoot, shouldStop: { Task.isCancelled }) else { return nil }
            let result = NASEventDiscovery.discover(configuration: configuration, isCancelled: { Task.isCancelled })
            return Task.isCancelled ? nil : result
        } }
        nasDiscoveryTask = Task { @MainActor [weak self] in
            // This walks the NAS: not while the board is painting.
            await self?.waitForBoardIdle()
            guard !Task.isCancelled else { return }
            let running = work()
            let found = await withTaskCancellationHandler {
                await running.value
            } onCancel: {
                running.cancel()
            }
            guard let self, let found, !Task.isCancelled else { return }
            applyNASDiscovery(found)
            LaunchTrace.mark("discovery.nas", detail: "events=\(found.events.count) problems=\(found.problems.count)")
        }
    }

    /// Publishes a discovery result. A folder Add to Events already could
    /// not add anything from, unchanged since, is not offered again: it is
    /// listed with the left-out items, with the reason it was refused.
    func applyNASDiscovery(_ found: NASEventDiscoveryResult) {
        let split = Self.splitRefused(found, refused: nasAdoptRefusedFolders)
        discoveredNASEvents = split.offered
        nasDiscoveryProblems = split.problems
        // A refusal whose folder changed or went away is forgotten.
        let stillRefused = Set(found.events.map(\.id)).subtracting(split.offered.map(\.id))
        nasAdoptRefusedFolders = nasAdoptRefusedFolders.filter { stillRefused.contains($0.key) }
    }

    nonisolated static func splitRefused(
        _ found: NASEventDiscoveryResult,
        refused: [String: NASAdoptRefusal]
    ) -> (offered: [DiscoveredNASEvent], problems: [NASDiscoveryProblem]) {
        var offered: [DiscoveredNASEvent] = []
        var problems = found.problems
        for folder in found.events {
            if let refusal = refused[folder.id], refusal.fingerprint == NASAdoptRefusal.fingerprint(of: folder) {
                problems.append(NASDiscoveryProblem(path: folder.relativeFolderPath, reason: refusal.reason))
            } else {
                offered.append(folder)
            }
        }
        return (offered, problems)
    }

    /// Add to Events for every folder the sidebar shows. Every click ends
    /// in something visible: a job in Jobs (queued behind a running job
    /// rather than refused), or — when there is nothing to add — a line
    /// under the button and in the status bar saying why.
    ///
    /// The job holds the job gate, so no move or sync runs beside it: the
    /// folders are listed again, the photo list is backed up, and only then
    /// are the files added — each to the event at its folder, as a NAS-only
    /// file. Nothing on the NAS or a drive is opened, moved or written.
    func adoptDiscoveredNASEvents() {
        let shown = discoveredNASEvents
        guard !shown.isEmpty else {
            reportNASAdopt("Nothing was added: no NAS folder is waiting to be added any more. The NAS is listed again now.")
            discoverNASEvents()
            return
        }
        let fileCount = shown.reduce(0) { $0 + $1.fileCount }
        let files = "\(fileCount.formatted()) NAS file\(fileCount == 1 ? "" : "s")"
        nasAdoptNote = nil
        model.enqueueFileJob(
            action: .organize,
            queuedNote: "Add \(files) to Events.",
            detail: "Waits for the running job. Then lists the NAS folders again, backs up the photo list, and adds every file no event covers to the event at its folder as a NAS-only file. Nothing on the NAS or a drive is opened, moved or changed.",
            skippedNote: "Did not start: there was nothing left to add. Nothing changed."
        ) { [weak self] jobID in
            self?.runNASAdoption(shown, jobID: jobID)
        }
    }

    private func runNASAdoption(_ shown: [DiscoveredNASEvent], jobID: UUID) {
        model.flushConfigurationSave()
        let configuration = model.configuration
        let backup = model.catalogBackupService(for: configuration)
        let queue = nasRenameQueue
        let nasRoot = locations.nasRoot.path
        let folderIDs = Set(shown.map(\.id))
        let fileCount = shown.reduce(0) { $0 + $1.fileCount }
        let started = model.runBackgroundJob(
            action: .organize,
            runningNote: "Adding \(fileCount.formatted()) NAS file\(fileCount == 1 ? "" : "s") to Events",
            logTitle: "Added NAS folders to Events",
            logDetail: "Listed the NAS folders again, backed up the photo list, then added every file no event covered to the event at its folder as a NAS-only file. No file on the NAS or a drive was opened, moved, copied or changed.",
            destinationPath: nasRoot,
            onSettled: { [weak self] in
                // Failed or cancelled jobs say why under the button too.
                guard let self, let job = model.jobs.first(where: { $0.id == jobID }), job.state != .done else { return }
                nasAdoptNote = job.note
            },
            jobID: jobID,
            operation: { _ in
                try NASEventDiscovery.prepareAdoption(
                    folderIDs: folderIDs,
                    configuration: configuration,
                    pendingNASRenames: queue.pendingRenameCount(nasRoot: nasRoot),
                    backup: { try backup.backupNow(reason: .manual, mirrorToRemote: false) }
                )
            },
            completion: { [weak self] plan in
                guard let self else { return "" }
                var summary = NASAdoptionSummary()
                if !plan.events.isEmpty {
                    model.updateConfiguration { configuration in
                        summary = NASEventDiscovery.adopt(plan.events, into: &configuration)
                    }
                }
                if let manifest = plan.backup { model.lastCatalogBackupAt = manifest.createdAt }
                model.refreshCatalogBackupSummary()
                noteRefusedNASFolders(plan: plan, summary: summary)
                let line = Self.nasAdoptionSummaryLine(summary, backedUp: plan.backup != nil, requested: folderIDs.count, found: plan.events.count)
                nasAdoptNote = line
                discoveredNASEvents = []
                // Both lists are read again against the new assignments.
                discoverDriveEvents()
                for eventID in summary.touchedEventIDs {
                    Task { await self.refreshEvent(eventID) }
                }
                return line
            }
        )
        if started == nil {
            reportNASAdopt("Nothing was added: another file job is running. Press Add to Events again once it has finished.")
        }
    }

    /// Folders the job was asked to add that ended with nothing added and
    /// would come back unchanged: remembered with the reason, so the next
    /// listing shows them as left out rather than as addable.
    private func noteRefusedNASFolders(plan: NASAdoptionPlan, summary: NASAdoptionSummary) {
        for folder in plan.events where (summary.addedByFolder[folder.id] ?? 0) == 0 {
            let reasons = summary.problems.filter {
                $0.path == folder.relativeFolderPath || $0.path.hasPrefix(folder.relativeFolderPath + "/")
            }
            let reason = reasons.first.map { NASDiscoveryWording.plainReason($0.reason) }
                ?? "nothing in it could be added to an event"
            nasAdoptRefusedFolders[folder.id] = NASAdoptRefusal(fingerprint: NASAdoptRefusal.fingerprint(of: folder), reason: reason)
        }
    }

    /// A click that started no job: said under the button and in the
    /// status bar.
    private func reportNASAdopt(_ line: String) {
        nasAdoptNote = line
        model.statusMessage = line
    }

    nonisolated static func nasAdoptionSummaryLine(_ summary: NASAdoptionSummary, backedUp: Bool, requested: Int = 0, found: Int = 0) -> String {
        guard summary.addedAssignments > 0 else {
            if requested > 0, found == 0 {
                return "Nothing was added: the NAS no longer has files outside your events in \(requested == 1 ? "that folder" : "those folders")."
            }
            return "Nothing was added: those NAS files are already in events, or could not be matched to one."
                + (summary.problems.isEmpty ? "" : " \(summary.problems.count) folder(s) or file(s) were left out — the sidebar says why.")
        }
        var parts = [
            "Added \(summary.addedAssignments.formatted()) NAS-only file\(summary.addedAssignments == 1 ? "" : "s")"
                + (summary.createdEvents > 0 ? " and \(summary.createdEvents) new event\(summary.createdEvents == 1 ? "" : "s")" : "")
                + ". Nothing on the NAS moved.",
        ]
        if backedUp { parts.append("The photo list was backed up first.") }
        if summary.alreadyCovered > 0 { parts.append("\(summary.alreadyCovered.formatted()) were already in an event.") }
        if !summary.problems.isEmpty { parts.append("\(summary.problems.count) folder(s) or file(s) were left out — the sidebar says why.") }
        return parts.joined(separator: " ")
    }
}

/// Plain words for what "Found on the NAS" left out.
enum NASDiscoveryWording {
    /// The sidebar's line about left-out items: the one item and why, or a
    /// count with the details on hover.
    static func leftOutLine(_ problems: [NASDiscoveryProblem]) -> String? {
        guard let first = problems.first else { return nil }
        if problems.count == 1 {
            return "Left out: \(shortPath(first.path)) — \(plainReason(first.reason))."
        }
        return "\(problems.count) folders or files were left out and can’t be added as they are. Hover to see which and why."
    }

    /// Every left-out item with its reason, for the hover text.
    static func leftOutDetails(_ problems: [NASDiscoveryProblem], limit: Int = 8) -> String {
        var lines = problems.prefix(limit).map { "\(shortPath($0.path)): \(plainReason($0.reason))" }
        if problems.count > limit { lines.append("and \(problems.count - limit) more") }
        return lines.joined(separator: "\n")
    }

    /// "Beach Day ▸ Osmo 360 (Alex)" from
    /// "2026/2026-01-01 Beach Day/Originals/Osmo 360 (Alex)": the year,
    /// dates and `Originals` dropped.
    static func shortPath(_ path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        if let year = parts.first, year.count == 4, year.allSatisfy(\.isNumber) { parts.removeFirst() }
        parts.removeAll { $0 == EventStorageLocations.originalsFolderName }
        let named = parts.map { DriveEventDiscovery.parseEventFolder($0)?.name ?? $0 }
        return named.isEmpty ? path : named.joined(separator: " ▸ ")
    }

    /// Discovery's terse reasons, said plainly.
    static func plainReason(_ reason: String) -> String {
        let cameraPrefix = "the app names this camera’s folder "
        if reason.hasPrefix(cameraPrefix) {
            let name = reason.dropFirst(cameraPrefix.count)
            return "the app would name this camera’s folder \(name), so it can’t match these files to an event. Renaming the folder on the NAS to \(name) lets them be added"
        }
        switch reason {
        case "this user cannot read it": return "this Mac isn’t allowed to read it on the NAS"
        case "its name cannot be stored as is": return "its name has characters the app can’t store"
        case "its path does not resolve back to itself": return "its name would change if the app stored it"
        default: break
        }
        let listPrefix = "could not be listed"
        if reason.hasPrefix(listPrefix) {
            let detail = reason.dropFirst(listPrefix.count).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return detail.isEmpty ? "the NAS could not list it" : "the NAS could not list it (\(detail))"
        }
        return reason
    }
}
