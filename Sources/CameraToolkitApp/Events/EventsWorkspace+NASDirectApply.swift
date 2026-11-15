import CameraToolkitCore
import Foundation

struct NASDirectJobResult: Sendable {
    var outcome: NASDirectApplyOutcome
    var reportPath: String?
}

/// Apply straight to the NAS: the plan's files whose event drive is not
/// connected go from their source into the event's NAS folder through the
/// Sync to NAS engine (`NASDirectApply`). A file job like Sync to NAS — in
/// Jobs with the same progress, queued behind whatever holds the job gate —
/// and outside Undo like Sync to NAS: nothing on the source changes, and
/// nothing on the NAS is ever replaced.
extension EventsWorkspace {
    func startNASDirectApply(_ plan: OrganizeApplyPlan) {
        let targets = plan.groups.flatMap { $0.nasCopies.flatMap(\.targets) }
        guard !targets.isEmpty else { return }
        let events = plan.groups.filter { !$0.nasCopies.isEmpty }.map(\.event)
        let bytes = targets.reduce(Int64(0)) { $0 + $1.byteCount }
        let files = "\(targets.count.formatted()) file\(targets.count == 1 ? "" : "s")"
        let title = plan.title
        nasConnection.prepareForNASJob { [weak self] in
            guard let self else { return }
            model.enqueueFileJob(
                action: .syncBuffer,
                queuedNote: "Copy \(files) (\(bytes.formattedBytes)) straight to the NAS.",
                detail: "Waits for the running job. Then copies each file from its source into its event's NAS folder, checked with SHA-256 file by file, as Sync to NAS does. Nothing on the NAS is replaced; nothing at the source changes.",
                skippedNote: "Did not start: the NAS is not connected. Nothing was copied; the originals stay where they are."
            ) { [weak self] jobID in
                self?.runNASDirectApply(targets, events: events, title: title, jobID: jobID)
            }
        }
    }

    private func runNASDirectApply(_ targets: [NASDirectCopyFile], events: [SavedCameraEvent], title: String, jobID: UUID) {
        let locations = self.locations
        guard NASDirectApply.isNASUsable(locations) else {
            model.statusMessage = "The NAS is not connected, so nothing was copied. The originals stay where they are; Apply again once the NAS or the event's drive is back."
            return
        }
        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
        let reportsFolder = catalogURL.deletingLastPathComponent().appendingPathComponent("NAS Sync", isDirectory: true)
        let options = NASSyncOptions.from(configuration: model.configuration, nasRoot: locations.nasRoot)
        let logTitle = "Copied straight to the NAS: \(title)"
        let recorder = model.makeHistoryRecorder(action: .syncBuffer, title: logTitle, id: jobID)
        let renameQueue = nasRenameQueue
        let nasPresence = self.nasPresence
        // Each event's board, and the board of the family it belongs to.
        let refresh = Set(events.flatMap { event in [event.id] + locations.ancestors(of: event).map(\.id) })
        model.runBackgroundJob(
            action: .syncBuffer,
            runningNote: "Copying \(targets.count.formatted()) file(s) straight to the NAS",
            logTitle: logTitle,
            logDetail: "The event's drive was not connected, so each file was copied from its source into the event's NAS folder — the path Sync to NAS gives the drive copy — \(options.parallelTransfers) at a time, and every copy's SHA-256 was checked (\(options.remoteVerifier == nil ? "re-read from the NAS" : "hashed on the NAS over SSH")) before it was named. Existing NAS files were never overwritten; the source was only read.",
            destinationPath: locations.nasRoot.path,
            history: recorder,
            onSettled: { nasPresence.refresh(.syncFinished, scope: events) },
            jobID: jobID,
            operation: { progress in
                progress(BackgroundJobUpdate(progress: 0.02, note: "Straight to NAS: running queued NAS renames first"))
                let store = try? NASSyncStore(catalogURL: catalogURL)
                let outcome = try NASDirectApply.run(
                    targets,
                    events: events,
                    locations: locations,
                    store: store,
                    options: options,
                    recorder: recorder,
                    renameQueue: renameQueue,
                    progress: { update in
                        progress(DashboardModel.jobUpdate(from: update, lowerBound: 0.03, upperBound: 0.99, notePrefix: "Straight to NAS", command: ""))
                    }
                )
                let reportPath = Self.writeNASDirectReport(outcome, title: title, to: reportsFolder)
                return NASDirectJobResult(outcome: outcome, reportPath: reportPath)
            },
            completion: { [weak self] (result: NASDirectJobResult) in
                let outcome = result.outcome
                let reportPath = result.reportPath
                let proven = Set(outcome.report.copied + outcome.report.matchedExisting + outcome.report.alreadyVerified)
                self?.nasPresence.noteSynced(outcome.plan.items.filter { proven.contains($0.relativePath) })
                // The same post-copy hook as Sync to NAS: Immich scans the
                // NAS event tree and checks the albums of what just landed.
                if !outcome.report.copied.isEmpty { self?.followNASChangeInImmich() }
                self?.nasRenamesApplied(outcome.follow, remaining: renameQueue.pendingRenameCount(nasRoot: locations.nasRoot.path))
                for eventID in refresh {
                    Task { await self?.refreshEvent(eventID) }
                }
                for location in self?.unsortedLocations ?? [] {
                    Task { await self?.refreshAppliedSources(for: location.id) }
                }
                let summary = ApplyPlanOverview.nasDirectSummary(outcome, reportPath: reportPath)
                guard outcome.succeeded else { throw ToolkitError.commandFailed(summary) }
                return summary
            }
        )
    }

    /// Every issue of a straight-to-NAS copy, per file, as JSON beside the
    /// catalog (the same folder Sync to NAS writes its reports to).
    nonisolated static func writeNASDirectReport(_ outcome: NASDirectApplyOutcome, title: String, to folder: URL) -> String? {
        struct Document: Encodable {
            var title: String
            var finishedAt: Date
            var route: String
            var report: NASSyncReport
            var skippedBeforeCopy: [NASSyncIssue]
        }
        guard !outcome.succeeded else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = folder.appendingPathComponent("straight-to-nas-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(Document(
                title: title,
                finishedAt: Date(),
                route: "source → NAS (event drive not connected)",
                report: outcome.report,
                skippedBeforeCopy: outcome.skipped
            )).write(to: url, options: .withoutOverwriting)
            return url.path
        } catch {
            return nil
        }
    }
}
