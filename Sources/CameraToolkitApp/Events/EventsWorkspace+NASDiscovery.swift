import CameraToolkitCore
import Foundation

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
        let work = Task.detached(priority: .utility) { () -> NASEventDiscoveryResult? in
            guard VolumeInfo.isAvailable(nasRoot) else { return NASEventDiscoveryResult() }
            guard gate.waitIfPaused(for: nasRoot, shouldStop: { Task.isCancelled }) else { return nil }
            let result = NASEventDiscovery.discover(configuration: configuration, isCancelled: { Task.isCancelled })
            return Task.isCancelled ? nil : result
        }
        nasDiscoveryTask = Task { @MainActor [weak self] in
            let found = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard let self, let found, !Task.isCancelled else { return }
            discoveredNASEvents = found.events
            nasDiscoveryProblems = found.problems
            LaunchTrace.mark("discovery.nas", detail: "events=\(found.events.count) problems=\(found.problems.count)")
        }
    }

    /// Add to Events for every folder the sidebar shows. A job (it holds the
    /// job gate, so no move or sync runs beside it): the folders are listed
    /// again, the photo list is backed up, and only then are the files
    /// added — each to the event at its folder, as a NAS-only file. Nothing
    /// on the NAS or a drive is opened, moved or written.
    func adoptDiscoveredNASEvents() {
        let shown = discoveredNASEvents
        guard !shown.isEmpty else { return }
        model.flushConfigurationSave()
        let configuration = model.configuration
        let backup = model.catalogBackupService(for: configuration)
        let queue = nasRenameQueue
        let nasRoot = locations.nasRoot.path
        let folderIDs = Set(shown.map(\.id))
        let fileCount = shown.reduce(0) { $0 + $1.fileCount }
        model.runBackgroundJob(
            action: .organize,
            runningNote: "Adding \(fileCount.formatted()) NAS file\(fileCount == 1 ? "" : "s") to Events",
            logTitle: "Added NAS folders to Events",
            logDetail: "Listed the NAS folders again, backed up the photo list, then added every file no event covered to the event at its folder as a NAS-only file. No file on the NAS or a drive was opened, moved, copied or changed.",
            destinationPath: nasRoot,
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
                discoveredNASEvents = []
                // Both lists are read again against the new assignments.
                discoverDriveEvents()
                for eventID in summary.touchedEventIDs {
                    Task { await self.refreshEvent(eventID) }
                }
                return Self.nasAdoptionSummaryLine(summary, backedUp: plan.backup != nil)
            }
        )
    }

    nonisolated static func nasAdoptionSummaryLine(_ summary: NASAdoptionSummary, backedUp: Bool) -> String {
        guard summary.addedAssignments > 0 else {
            return "Nothing was added: those NAS files are already in events, or could not be matched to one."
                + (summary.problems.isEmpty ? "" : " \(summary.problems.count) folder(s) or file(s) were skipped.")
        }
        var parts = [
            "Added \(summary.addedAssignments.formatted()) NAS-only file\(summary.addedAssignments == 1 ? "" : "s")"
                + (summary.createdEvents > 0 ? " and \(summary.createdEvents) new event\(summary.createdEvents == 1 ? "" : "s")" : "")
                + ". Nothing on the NAS moved.",
        ]
        if backedUp { parts.append("The photo list was backed up first.") }
        if summary.alreadyCovered > 0 { parts.append("\(summary.alreadyCovered.formatted()) were already in an event.") }
        if !summary.problems.isEmpty { parts.append("\(summary.problems.count) folder(s) or file(s) were skipped.") }
        return parts.joined(separator: " ")
    }
}
