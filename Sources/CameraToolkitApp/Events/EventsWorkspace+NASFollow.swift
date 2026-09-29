import CameraToolkitCore
import Foundation

/// Counts the NAS renames a background job queued, for its completion line.
final class NASQueuedRenames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var count: Int { lock.withLock { stored } }
    func add(_ count: Int) { lock.withLock { stored += count } }
}

/// What the NAS follow-up says next to a move, a rename, or an Undo.
enum NASFollowWording {
    /// "12 NAS copies will be renamed when the NAS is connected."
    static func queued(_ count: Int, connected: Bool) -> String {
        guard count > 0 else { return "" }
        let noun = count == 1 ? "1 NAS copy" : "\(count.formatted()) NAS copies"
        return connected
            ? " \(noun) will be renamed to match next."
            : " \(noun) will be renamed when the NAS is connected."
    }

    static func undone(_ undo: NASUndoResult) -> String {
        var parts: [String] = []
        let changed = undo.follow.renamed + undo.follow.foldersRenamed
        if changed > 0 { parts.append("Renamed \(changed.formatted()) NAS cop\(changed == 1 ? "y" : "ies") back.") }
        if undo.cancelled > 0 { parts.append("\(undo.cancelled.formatted()) queued NAS rename\(undo.cancelled == 1 ? " was" : "s were") dropped.") }
        if undo.queued > 0 { parts.append("\(undo.queued.formatted()) NAS cop\(undo.queued == 1 ? "y" : "ies") will be renamed back when the NAS is connected.") }
        let stuck = undo.follow.differs.count + undo.follow.unproven.count + undo.follow.failed.count
        if stuck > 0 { parts.append("\(stuck) NAS cop\(stuck == 1 ? "y" : "ies") could not be renamed back and \(stuck == 1 ? "was" : "were") left untouched.") }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }
}

/// The Sync All confirmation's counts for "Reconcile NAS after moves":
/// answered from the catalog's records and the drive, without the NAS.
struct NASReconcilePreview: Equatable, Sendable {
    /// Files to copy whose NAS copy already sits at an old path.
    var renames = 0
    var renameBytes: Int64 = 0
    /// NAS copies that duplicate a file already at its right path.
    var staleDuplicates = 0
    var staleBytes: Int64 = 0
    /// Renames queued by earlier moves, applied first.
    var queuedRenames = 0

    var isEmpty: Bool { renames == 0 && staleDuplicates == 0 && queuedRenames == 0 }
}

extension EventsWorkspace {
    /// The journal of NAS renames the drive moves owe, beside the move journals.
    var nasRenameQueue: NASRenameQueue { NASRenameQueue(journalFolder: journalFolder) }

    /// Writes a batch of NAS renames to the journal — from a job, off the
    /// main actor — and returns how many it queued. A journal that cannot
    /// be written queues nothing: the catch-up in Sync to NAS finds those
    /// files later.
    nonisolated static func queueNASRenames(
        _ ops: [NASRename],
        title: String,
        origin: NASRenameBatch.Origin,
        moveJournalID: UUID? = nil,
        nasRoot: URL,
        journalFolder: URL
    ) -> Int {
        guard !ops.isEmpty else { return 0 }
        do {
            try NASRenameQueue(journalFolder: journalFolder).save(NASRenameBatch(
                title: title,
                origin: origin,
                nasRoot: nasRoot.path,
                moveJournalID: moveJournalID,
                ops: ops
            ))
            return ops.count
        } catch {
            DebugLog.shared.log("nas.rename.queue", subsystem: .apply, level: .error, outcome: .error, error: error.localizedDescription)
            return 0
        }
    }

    /// A job queued renames: the count is kept in memory so a finished job
    /// need not read the journal folder to know whether the NAS owes any.
    func noteNASRenamesQueued(_ count: Int) {
        pendingNASRenameCount += count
    }

    /// Recounts the queue from the journal folder, off the main actor, and
    /// applies it when the NAS is there. At launch, and after a mount.
    func refreshNASRenameBacklog() {
        let queue = nasRenameQueue
        let root = locations.nasRoot.path
        Task { @MainActor [weak self] in
            let count = await Task.detached(priority: .utility) { queue.pendingRenameCount(nasRoot: root) }.value
            self?.pendingNASRenameCount = count
            self?.drainNASRenames()
        }
    }

    /// Applies the queued NAS renames as a job of their own — only when
    /// the NAS is mounted and no other file job holds the gate; a job that
    /// finishes, or a mount, tries again. Sync to NAS applies the queue
    /// itself before it plans, so a sync never waits on this.
    func drainNASRenames() {
        guard pendingNASRenameCount > 0, nasIsConnected, !model.isBusy, !model.isStorageBenchmarkRunning else { return }
        let queue = nasRenameQueue
        let nasRoot = locations.nasRoot
        let configuration = model.configuration
        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(configuration.catalogDatabasePath))
        let count = pendingNASRenameCount
        model.runBackgroundJob(
            action: .nasRename,
            runningNote: "Renaming \(count.formatted()) NAS cop\(count == 1 ? "y" : "ies") to match the drive",
            logTitle: "Renamed NAS copies to match moved files",
            logDetail: "Renamed each moved file's copy on the NAS with an exclusive server-side rename — no file was read, copied, or replaced — and moved its Sync to NAS record with it. A new path that already held the identical file kept it, and the stale copy was set aside under .Camera Toolkit/_Stale Copies on the NAS; a different file was left untouched. Every rename is journaled, so Undo of the move reverses it.",
            destinationPath: nasRoot.path,
            operation: { progress in
                let store = try? NASSyncStore(catalogURL: catalogURL)
                let remote = NASSyncOptions.from(configuration: configuration, nasRoot: nasRoot).remoteVerifier
                let result = try NASMoveFollower(store: store, remoteVerifier: remote, queue: queue)
                    .applyPending(nasRoot: nasRoot) { update in
                        progress(DashboardModel.jobUpdate(from: update, notePrefix: "Renaming on the NAS", command: ""))
                    }
                return (result, queue.pendingRenameCount(nasRoot: nasRoot.path))
            },
            completion: { [weak self] outcome in
                let (result, remaining) = outcome
                self?.nasRenamesApplied(result, remaining: remaining)
                guard result.failed.isEmpty else { throw ToolkitError.commandFailed(result.summary) }
                return result.summary
            }
        )
    }

    /// NAS renames ran (from the queue, a sync, or an Undo): the counts and
    /// the NAS listing follow, without listing the NAS again.
    func nasRenamesApplied(_ result: NASFollowResult, remaining: Int) {
        pendingNASRenameCount = remaining
        nasPresence.noteRenamed(result)
        // The open board's NAS place was read before the copies moved.
        if result.changed > 0, case .event(let eventID) = selection, presence[eventID] != nil {
            Task { await refreshEvent(eventID) }
        }
    }

    /// The Sync All confirmation's counts, read from the presence answer's
    /// pending files and the catalog's records — no NAS access.
    func refreshReconcilePreview() {
        guard let report = nasPresence.report else {
            reconcilePreview = nil
            return
        }
        let locations = self.locations
        let assignments = model.configuration.photoEventAssignments
        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
        let pending = report.pending
        let queue = nasRenameQueue
        let nasRoot = locations.nasRoot.path
        Task { @MainActor [weak self] in
            let preview = await Task.detached(priority: .utility) { () -> NASReconcilePreview in
                let records = NASSyncStore.existingRecords(catalogURL: catalogURL, nasRoot: nasRoot)
                let analysis = NASCatchUp.analyze(
                    plan: NASSyncPlan(items: pending),
                    records: records,
                    ownedKeys: NASCatchUp.ownedKeys(assignments: assignments, locations: locations),
                    locations: locations
                )
                var preview = NASReconcilePreview()
                preview.renames = analysis.candidates.count
                preview.renameBytes = analysis.savedBytes
                preview.staleDuplicates = analysis.staleDuplicates.count
                preview.staleBytes = analysis.staleDuplicates.reduce(0) { $0 + $1.stale.byteCount }
                preview.queuedRenames = queue.pendingRenameCount(nasRoot: nasRoot)
                return preview
            }.value
            self?.reconcilePreview = preview
        }
    }
}
