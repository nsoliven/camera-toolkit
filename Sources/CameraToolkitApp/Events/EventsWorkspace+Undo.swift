import AppKit
import CameraToolkitCore
import Foundation

// One time-ordered history behind ⌘Z and ⌘⇧Z.
//
// Every action that can be taken back registers an `UndoEntry` when it
// finishes (a job registers from its completion, so the entry is in the
// history only once the files really moved). ⌘Z takes the newest entry and
// replays its inverse — as a job when it touches files, with the same
// refusals the actions have: a drive that is away, an event that was
// deleted or renamed, a name that is taken, another job running. Nothing is
// ever replaced or deleted; an inverse that cannot run says why and leaves
// the entry where it is. ⌘⇧Z replays the action again.
//
// Deliberately outside the history, and said so where they are confirmed:
// Remove from Source, Take Off Drive (its copies wait in Trash), Empty
// Trash, Sync to NAS, Immich upload, and Settings.

/// What is deliberately outside Undo (⌘Z), in the words the confirmations use.
enum UndoScopeWording {
    static let removeFromSource = "This is not part of Undo (⌘Z): once the originals are deleted, nothing brings them back. The drive copies stay."
    static let takeOffDrive = "This is not part of Undo (⌘Z). The drive copies wait in _Trash, so restore them from the Trash window."
    static let emptyTrash = "Empty Trash is not part of Undo (⌘Z) — deleted files cannot be brought back."
    static let syncToNAS = "Sync to NAS is not part of Undo (⌘Z): it only adds verified copies, and nothing on the NAS is overwritten or removed."
    static let immichUpload = "Uploading is not part of Undo (⌘Z). Remove the uploads in Immich if you change your mind."
    static let settings = "Changes here are not part of Undo (⌘Z)."
}

/// Undo and Redo of a change whose inverse lives in memory only.
struct UndoSessionHandlers {
    var undo: @MainActor () -> Void
    var redo: @MainActor () -> Void
}

/// Writes the history to disk off the main actor. Saves coalesce: while one
/// is running, only the newest history waits.
final class UndoPersistence: @unchecked Sendable {
    private let store: UndoHistoryStore
    private let queue = DispatchQueue(label: "CameraToolkit.undo-history", qos: .utility)
    private let lock = NSLock()
    private var pending: UndoHistory?
    private var scheduled = false

    init(store: UndoHistoryStore) {
        self.store = store
    }

    func enqueue(_ history: UndoHistory) {
        let start = lock.withLock { () -> Bool in
            pending = history
            if scheduled { return false }
            scheduled = true
            return true
        }
        guard start else { return }
        queue.async { [self] in drain() }
    }

    private func drain() {
        while true {
            let next = lock.withLock { () -> UndoHistory? in
                let history = pending
                pending = nil
                if history == nil { scheduled = false }
                return history
            }
            guard let next else { return }
            do {
                try store.save(next)
            } catch {
                DebugLog.shared.log("undo.save", subsystem: .apply, level: .error, outcome: .error, error: error.localizedDescription)
            }
        }
    }

    /// Waits for every save queued so far.
    func flush() {
        queue.sync {}
    }

    func load() -> UndoHistory {
        (try? store.load()) ?? UndoHistory()
    }

    func close() {
        flush()
        store.close()
    }
}

enum UndoDirection: Sendable {
    case undo
    case redo

    var verb: String { self == .undo ? "Undo" : "Redo" }
    var past: String { self == .undo ? "Undid" : "Redid" }
    var gerund: String { self == .undo ? "Undoing" : "Redoing" }
}

/// A step that acted on the NAS copies and the catalog alone.
struct UndoNASOnlyOutcome: Sendable {
    /// The journal renames whose NAS copy followed the move and went with it.
    var covered: [Int]
    /// How many renames the step considered.
    var total: Int
    /// The step finished what an earlier NAS-only step began.
    var wasLagging: Bool
    /// The NAS was not there either, so nothing was done.
    var nasAbsent = false
    /// Renames with no NAS copy to act on. When there are any, the step does
    /// nothing at all: a half-done step could not be undone or redone again.
    var uncovered = 0
}

extension EventsWorkspace.UndoJournalMode {
    var isSkip: Bool {
        if case .skip = self { return true }
        return false
    }

    var laggingIndices: [Int]? {
        if case .lagging(let indices) = self { return indices }
        return nil
    }
}

/// The spare copies in Trash could not be reached (their drive is unplugged
/// or was emptied): the step acted on the NAS copies that followed them.
struct UndoTrashNASOnlyOutcome: Sendable {
    /// The trashed files (by original path) whose NAS copy went back.
    var covered: Set<String>
    /// The NAS was not there either, so nothing was done.
    var nasAbsent = false
    /// Trashed files with no NAS copy that followed them: the step then does
    /// nothing at all.
    var uncovered = 0
}

/// What the file part of an Undo or Redo did, from the job.
struct UndoFilesOutcome: Sendable {
    var nasOnly: UndoNASOnlyOutcome?
    var trashNASOnly: UndoTrashNASOnlyOutcome?
    var trash: MediaTrashRestoreReport?
    var retrashed: MediaTrashBatch?
    var journalReport: DriveMoveReport?
    var journal: DriveMoveJournal?
    var nas = NASUndoResult()
    var remainingNASRenames = 0
}

extension EventsWorkspace {
    // MARK: - What the menus read

    var canUndo: Bool { undoHistory.canUndo }
    var canRedo: Bool { undoHistory.canRedo }

    /// "Undo Move to Lakeside (12 files)" — nil when there is nothing to undo.
    var undoMenuTitle: String? { undoHistory.nextUndo.map { "Undo \($0.displayName)" } }
    var redoMenuTitle: String? { undoHistory.nextRedo.map { "Redo \($0.displayName)" } }

    /// The title of the newest move that has a journal on disk.
    var latestMoveJournalTitle: String? {
        undoHistory.undoStack.last { $0.journalID != nil }?.title
    }

    /// Catalog-only changes waiting on the undo stack (sorts, unsorts, moves
    /// of files that are not on the drive).
    var undoableSortCount: Int {
        undoHistory.undoStack.count { entry in
            if case .files(let files) = entry.action { return files.isCatalogOnly && files.nasLinks.isEmpty }
            return false
        }
    }

    // MARK: - Recording

    /// Puts a finished action on the history, newest, and forgets any Redo.
    func recordUndo(_ title: String, detail: String? = nil, _ action: UndoAction) {
        undoHistory.record(UndoEntry(title: title, detail: detail, action: action))
        persistUndoHistory()
    }

    /// A catalog swap that has already been applied (a sort, an unsort, a
    /// move that only changed entries).
    func recordAssignmentUndo(_ change: AssignmentChange, nasLink: UUID? = nil, eventFolders: [String: String]? = nil) {
        guard !change.removed.isEmpty || !change.added.isEmpty else { return }
        var files = UndoFilesAction(removed: change.removed, added: change.added)
        if let nasLink {
            files.nasLinks = [nasLink]
            files.eventFolders = eventFolders
        }
        recordUndo(change.title, detail: UndoEntry.fileCount(max(change.removed.count, change.added.count)), .files(files))
    }

    /// A finished job that renamed files under a journal (Apply, Keep Both,
    /// Return to Unsorted): the journal owns the renames and the catalog
    /// entries that go with them.
    func recordJournalUndo(title: String, report: DriveMoveReport) {
        guard let path = report.journalPath, let id = report.journalID, !report.moved.isEmpty else { return }
        let files = UndoFilesAction(journalID: id, journalFile: (path as NSString).lastPathComponent)
        recordUndo(title, detail: UndoEntry.fileCount(report.moved.count), .files(files))
    }

    /// A finished Move to Event: its journal (renames and the entries that
    /// went with them), the entries of files that only moved in the catalog,
    /// the entries of copies that merged into one the event already had,
    /// the spare copies that went to Trash, and the NAS renames both owe.
    func recordMoveUndo(title: String, moveID: UUID, mergeLink: UUID, outcome: EventMoveOutcome, eventFolders: [String: String]) {
        var files = UndoFilesAction()
        // A journal whose renames all failed has nothing to take back; the
        // entries that moved in the catalog alone are then the swap.
        if let path = outcome.report.journalPath, let id = outcome.report.journalID, !outcome.report.moved.isEmpty {
            files.journalID = id
            files.journalFile = (path as NSString).lastPathComponent
        } else {
            files.removed += outcome.moved.map(\.removed)
            files.added += outcome.moved.map(\.added)
            if outcome.moved.contains(where: { $0.nasCopy != nil }) { files.nasLinks.append(outcome.report.journalID ?? moveID) }
        }
        // A merge keeps the target's own entry; the source's entry goes, and
        // a name taken on disk alone adopts one.
        files.removed += outcome.merged.map(\.removed)
        let placed = Set((outcome.moved + outcome.keptBoth.map(\.item)).map { CatalogStore.eventAssetID($0.added) })
        files.added += outcome.addedAssignments.filter { !placed.contains(CatalogStore.eventAssetID($0)) }
        if let batch = outcome.trashBatch { files.trashed = batch.undoTrashedFiles }
        if !outcome.merged.isEmpty { files.nasLinks.append(mergeLink) }
        guard files.journalID != nil || !files.removed.isEmpty || !files.added.isEmpty || !files.trashed.isEmpty else { return }
        files.eventFolders = eventFolders
        recordUndo(title, detail: UndoEntry.fileCount(max(outcome.removedAssignments.count, outcome.report.moved.count)), .files(files))
    }

    /// Files sent to a `_Trash` batch, and the entries that were dropped with them.
    func recordTrashUndo(title: String, batch: MediaTrashBatch, dropped: [PhotoEventAssignment], originRoot: String?, nasLink: UUID? = nil) {
        guard !batch.entries.isEmpty else { return }
        var files = UndoFilesAction(removed: dropped, trashed: batch.undoTrashedFiles, trashOriginRoot: originRoot)
        if let nasLink { files.nasLinks = [nasLink] }
        recordUndo(title, detail: UndoEntry.fileCount(batch.entries.count), .files(files))
    }

    // MARK: - Persistence

    func persistUndoHistory() {
        undoPersistence.enqueue(undoHistory.persistent)
    }

    /// Waits for the last save (quit, tests).
    func flushUndoHistory() {
        undoPersistence.flush()
    }

    /// Reads the history a previous run left. Entries whose move journal
    /// is gone or in the wrong state are dropped; the newest open journal
    /// that no entry knows (written by an earlier build) is offered too.
    /// Anything recorded before the read finished stays on top.
    func loadUndoHistory() async {
        guard !undoHistoryLoaded else { return }
        undoHistoryLoaded = true
        let persistence = undoPersistence
        let folder = journalFolder
        let (loaded, interrupted) = await Task.detached(priority: .utility) { () -> (UndoHistory, [(url: URL, journal: DriveMoveJournal)]) in
            (Self.reconciled(persistence.load(), journalFolder: folder), DriveMoveService.interruptedSteps(in: folder))
        }.value
        // Entries recorded while the file was being read are already on disk or
        // about to be: they are not added twice.
        let recorded = undoHistory.undoStack + undoHistory.redoStack
        let recordedIDs = Set(recorded.map(\.id))
        let recordedJournals = Set(recorded.compactMap(\.journalID))
        func fresh(_ entries: [UndoEntry]) -> [UndoEntry] {
            entries.filter { entry in
                !recordedIDs.contains(entry.id) && (entry.journalID.map { !recordedJournals.contains($0) } ?? true)
            }
        }
        var merged = UndoHistory(undoStack: fresh(loaded.undoStack), redoStack: fresh(loaded.redoStack))
        for entry in undoHistory.undoStack { merged.record(entry) }
        undoHistory = merged
        if !loaded.undoStack.isEmpty || !loaded.redoStack.isEmpty { persistUndoHistory() }
        recoverInterruptedSteps(interrupted)
    }

    /// An Undo or Redo that was running when the app stopped is finished now.
    /// Its journal was marked before the first rename and is cleared only once
    /// the catalog and the NAS copies followed the drive, so wherever it
    /// stopped the step is replayed from its journal: the drive's renames
    /// again (the ones already done are recognised), then the catalog, then the
    /// NAS copies. Nothing is replaced; every rename is exclusive.
    func recoverInterruptedSteps(_ interrupted: [(url: URL, journal: DriveMoveJournal)]) {
        for (url, journal) in interrupted {
            let direction: UndoDirection = journal.pendingStep == "redo" ? .redo : .undo
            guard journal.driveStepDone == true else {
                // Stopped among the drive's renames: the entry is still the one
                // to undo (or redo) — run it again, and it finishes the rest.
                let entryID = journal.id
                let top = direction == .undo ? undoHistory.nextUndo : undoHistory.nextRedo
                if top?.journalID == entryID, !hasPendingMoves, !model.isBusy {
                    model.statusMessage = "Finishing the \(direction.verb) of “\(journal.title)” that was interrupted."
                    performHistoryStep(direction)
                }
                continue
            }
            replayCatalogPhase(url: url, journal: journal, direction: direction)
        }
    }

    /// The drive's renames are done and the catalog and the NAS are not:
    /// bring them level with the drive, then close the step.
    private func replayCatalogPhase(url: URL, journal: DriveMoveJournal, direction: UndoDirection) {
        let locations = self.locations
        let nasRoot = locations.nasRoot
        let journalFolder = self.journalFolder
        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
        let current = Set(model.configuration.photoEventAssignments.map(CatalogStore.eventAssetID))
        // The moves whose NAS copy goes with the drive's, and the catalog-only
        // ones, worked out before the catalog changes.
        let moved = direction == .undo ? (journal.undoneIndices ?? []) : journal.completedIndices
        let driveKeys = Set(moved.filter { journal.moves.indices.contains($0) }.compactMap {
            locations.mirrorRelativePath(forDrivePath: journal.moves[$0].destinationPath).map(NASSyncStore.pathKey)
        })
        let catalogOnly = direction == .undo ? catalogOnlyMirrorKeys(of: journal) : []
        switch direction {
        case .undo:
            let restore = journal.assignmentsToRestore(
                reversed: moved, fullyUndone: journal.undoneAt != nil,
                isCurrent: { current.contains(CatalogStore.eventAssetID($0)) }
            )
            applyAssignmentChange(AssignmentChange(title: journal.title, removed: restore.added, added: reinstatable(restore.removed)), touching: nil)
        case .redo:
            let again = journal.assignmentsToReapply(
                redone: moved, fullyRedone: journal.undoneAt == nil,
                isCurrent: { current.contains(CatalogStore.eventAssetID($0)) }
            )
            applyAssignmentChange(AssignmentChange(title: journal.title, removed: again.removed, added: reinstatable(again.added)), touching: nil)
        }
        model.flushConfigurationSave()
        let started = model.runBackgroundJob(
            action: .organize,
            runningNote: "Finishing the \(direction.verb) of “\(journal.title)” that was interrupted",
            logTitle: "Finished an interrupted \(direction.verb)",
            logDetail: "Replayed an Undo or Redo the app was stopped in the middle of: the catalog follows the drive's files, and the NAS copies that followed the move are renamed to match. Nothing was replaced.",
            operation: { _ in
                let queue = NASRenameQueue(journalFolder: journalFolder)
                let follower = NASMoveFollower(store: try? NASSyncStore(catalogURL: catalogURL), queue: queue)
                var result = NASUndoResult()
                do {
                    switch direction {
                    case .undo: result = try follower.undo(moveJournalID: journal.id, nasRoot: nasRoot, reversedMirrorKeys: driveKeys.union(catalogOnly))
                    case .redo: result = try follower.redo(moveJournalID: journal.id, nasRoot: nasRoot)
                    }
                } catch {
                    DebugLog.shared.log("nas.rename.undo", subsystem: .apply, level: .error, outcome: .error, error: error.localizedDescription)
                }
                try? DriveMoveService.finishStep(journalURL: url)
                return (result, queue.pendingRenameCount(nasRoot: nasRoot.path))
            },
            completion: { [weak self] outcome in
                self?.nasRenamesApplied(outcome.0.follow, remaining: outcome.1)
                if let self {
                    for boardID in self.boardsShowing(Set((journal.addedAssignments + journal.removedAssignments).map(\.eventID))) {
                        Task { await self.refreshEvent(boardID) }
                    }
                }
                return "Finished the \(direction.verb) of “\(journal.title)” that was interrupted." + NASFollowWording.undone(outcome.0)
            }
        )
        if started == nil {
            // Another job holds the gate; the journal stays marked and the next
            // launch replays it (the catalog part above is idempotent).
            DebugLog.shared.log("undo.recover", subsystem: .apply, level: .info, detail: "deferred: another job is running")
        }
    }

    nonisolated static func reconciled(_ stored: UndoHistory, journalFolder: URL) -> UndoHistory {
        func journal(of entry: UndoEntry) -> DriveMoveJournal? {
            guard case .files(let files) = entry.action, let file = files.journalFile else { return nil }
            return try? DriveMoveService.read(journalFolder.appendingPathComponent(file))
        }
        var undo: [UndoEntry] = []
        var redo: [UndoEntry] = []
        for entry in stored.undoStack {
            if case .files(let files) = entry.action, files.journalID != nil {
                // The journal must still be open — or its Undo was interrupted
                // after the drive and is replayed now, so it is a Redo.
                guard let journal = journal(of: entry) else { continue }
                if journal.undoneAt != nil {
                    if journal.pendingStep == "undo" { redo.append(entry) }
                    continue
                }
            }
            undo.append(entry)
        }
        for entry in stored.redoStack {
            if case .files(let files) = entry.action, files.journalID != nil {
                guard let journal = journal(of: entry) else { continue }
                if journal.undoneAt == nil {
                    if journal.pendingStep == "redo" { undo.append(entry) }
                    continue
                }
            }
            redo.append(entry)
        }
        // A journal an earlier build wrote (or one whose entry never made it
        // to disk) is still an Undo: the newest open one, in time order.
        var history = UndoHistory(undoStack: undo, redoStack: redo)
        if let entry = unownedJournalEntry(in: journalFolder, history: history) {
            history.insertChronologically(entry)
        }
        return history
    }

    /// The newest open move journal no entry owns — written by an earlier
    /// build, or by a run that stopped before its entry was recorded — as an
    /// entry, so it is still an Undo.
    nonisolated static func unownedJournalEntry(in journalFolder: URL, history: UndoHistory) -> UndoEntry? {
        guard let latest = DriveMoveService.latestUndoableJournal(in: journalFolder),
              !(history.undoStack + history.redoStack).contains(where: { $0.journalID == latest.journal.id }) else { return nil }
        return UndoEntry(
            createdAt: latest.journal.createdAt,
            title: latest.journal.title,
            detail: UndoEntry.fileCount(latest.journal.completedIndices.count),
            action: .files(UndoFilesAction(journalID: latest.journal.id, journalFile: latest.url.lastPathComponent))
        )
    }

    /// Offers the newest open journal the history does not know.
    func discoverLatestJournal() {
        guard let entry = Self.unownedJournalEntry(in: journalFolder, history: undoHistory) else { return }
        undoHistory.insertChronologically(entry)
        persistUndoHistory()
    }

    // MARK: - Undo and Redo

    /// ⌘Z: takes back the newest action.
    func undo() {
        performHistoryStep(.undo)
    }

    /// ⌘⇧Z: does the action that was just taken back again.
    func redo() {
        performHistoryStep(.redo)
    }

    /// The Undo entry points older code and tests call: all one history now.
    func undoLastSort() { undo() }
    func undoLastMove() { undo() }

    private func performHistoryStep(_ direction: UndoDirection) {
        guard let entry = direction == .undo ? undoHistory.nextUndo : undoHistory.nextRedo else {
            model.statusMessage = direction == .undo ? "Nothing to undo." : "Nothing to redo."
            return
        }
        // A click that is still waiting or running is newer than every entry:
        // taking back an older one now would undo the wrong thing.
        guard !hasPendingMoves else {
            refuseUndo(entry, direction, "A move is still waiting or running. \(direction.verb) after it finishes — nothing was changed.")
            return
        }
        switch entry.action {
        case .files(let files): performFilesStep(entry, files, direction)
        case .eventEdit(let edit): performEventEditStep(entry, edit, direction)
        case .config(let change): performConfigStep(entry, change, direction)
        case .faces(let snapshot): performFacesStep(entry, snapshot, direction)
        case .session(let id): performSessionStep(entry, id, direction)
        }
    }

    private func refuseUndo(_ entry: UndoEntry, _ direction: UndoDirection, _ message: String) {
        refuseMove("\(direction.verb) “\(entry.title)”", message)
    }

    /// The entry can never run (an event it names is gone): it leaves the
    /// history so it stops standing in front of the older ones.
    private func dropEntry(_ entry: UndoEntry, _ direction: UndoDirection, _ message: String, closing journalURL: URL? = nil) {
        if direction == .undo, let journalURL { try? DriveMoveService.abandon(journalURL: journalURL) }
        undoHistory.remove(entry.id)
        persistUndoHistory()
        refuseUndo(entry, direction, message)
    }

    private func finish(_ entry: UndoEntry, _ direction: UndoDirection) {
        switch direction {
        case .undo: undoHistory.completeUndo(entry)
        case .redo: undoHistory.completeRedo(entry)
        }
        persistUndoHistory()
    }

    // MARK: - Files, journals, Trash and the NAS

    /// How the journal's drive renames take part in a step.
    enum UndoJournalMode: Sendable {
        /// Not at all: already in the state the step needs (retried after a
        /// partial step), or the entry has no journal.
        case skip
        /// Rename the drive files — unless none of them can be reached (the
        /// drive is unplugged, or was wiped), in which case the step acts on
        /// the NAS copies and the catalog alone.
        case drive
        /// The last step acted on the NAS and the catalog alone; the drive is
        /// still in the state before it. This step does the same for those
        /// renames and the drive needs nothing.
        case lagging([Int])
    }

    private func performFilesStep(_ entry: UndoEntry, _ files: UndoFilesAction, _ direction: UndoDirection) {
        let name = "\(direction.verb) “\(entry.title)”"
        let past = direction == .undo ? "undone" : "redone"
        let journalURL = files.journalFile.map { journalFolder.appendingPathComponent($0) }
        let journal = journalURL.flatMap { try? DriveMoveService.read($0) }
        if files.journalID != nil, journal == nil, files.trashed.isEmpty, files.removed.isEmpty, files.added.isEmpty {
            dropEntry(entry, direction, "“\(entry.title)” can't be \(past): its move journal is gone. Nothing was changed, and it was dropped from the history.")
            return
        }
        // The journal's rename runs only when it is in the state this step
        // starts from; a step retried after a partial one skips what is done.
        let journalMode: UndoJournalMode = {
            guard let journal else { return .skip }
            if let lagging = files.driveLagging { return .lagging(lagging) }
            return (direction == .undo ? journal.undoneAt == nil : journal.undoneAt != nil) ? .drive : .skip
        }()
        var runsDrive = false
        if case .drive = journalMode { runsDrive = true }

        // An event the action names was deleted since: entries put back into
        // it would belong to nothing.
        let known = Set(model.configuration.savedEvents.map(\.id))
        var named = files.removed + files.added
        if let journal { named += journal.removedAssignments + journal.addedAssignments }
        if named.contains(where: { !known.contains($0.eventID) }) {
            dropEntry(
                entry, direction,
                "“\(entry.title)” can't be \(past): one of its events was deleted since. Nothing was changed, and it was dropped from the history.",
                closing: runsDrive ? journalURL : nil
            )
            return
        }

        // An event it names moved folders (renamed, re-dated, re-parented):
        // its files and NAS copies are not where the action left them.
        // Undoing the rename comes first — it is newer, so it is the next ⌘Z
        // when it is in the history.
        let recordedFolders = (journalMode.isSkip ? nil : journal?.eventFolders) ?? (files.nasLinks.isEmpty ? nil : files.eventFolders)
        var moved = recordedFolders.flatMap { eventMoved(since: $0) }
        if moved == nil, direction == .undo, runsDrive, let journal { moved = eventRenamedSince(journal) }
        if let moved {
            refuseUndo(
                entry, direction,
                "“\(entry.title)” can't be \(past) yet: \(eventTitle(moved)) was renamed or moved since, so its files are not where the action left them. Undo the rename first (it is the next step in Edit ▸ Undo when it was made here), or rename it back. Nothing was changed."
            )
            return
        }

        // A volume that is not there cannot give its files back, and trying
        // would spend the journal on nothing: say which one and wait. The
        // exception is a journal whose drive files are all on volumes that
        // are not there while the NAS is: the step then acts on the NAS
        // copies and the catalog (`performFilesJob`), which needs the NAS.
        let mounted = VolumeInfo.mountedVolumePaths()
        func absentVolume(_ paths: [String]) -> String? {
            paths.first { !VolumeInfo.isAvailable(URL(fileURLWithPath: $0), mountedVolumes: mounted) }
        }
        func driveName(_ path: String) -> String {
            VolumeInfo.volumeRoot(for: URL(fileURLWithPath: path))?.lastPathComponent ?? path
        }
        var mustHave: [String] = files.trashed.map(\.entry.originalAbsolutePath)
        if direction == .undo { mustHave += files.trashed.map(\.batchFolder) }
        if let absent = absentVolume(mustHave), files.nasLinks.isEmpty || !nasIsConnected {
            refuseUndo(
                entry, direction,
                "“\(entry.title)” can't be \(past) while \(driveName(absent)) isn't connected — its files in Trash are on it\(files.nasLinks.isEmpty ? "" : ", and the NAS isn't connected either, so there is no NAS copy to act on"). Connect \(files.nasLinks.isEmpty ? "it" : "one of them") and try again — nothing was changed."
            )
            return
        }
        if runsDrive, let journal {
            let paths = journal.moves.flatMap { [$0.sourcePath, $0.destinationPath] }
            let absent = paths.filter { !VolumeInfo.isAvailable(URL(fileURLWithPath: $0), mountedVolumes: mounted) }
            if !absent.isEmpty {
                if absent.count < paths.count, let first = absent.first {
                    refuseUndo(
                        entry, direction,
                        "“\(entry.title)” can't be \(past) while \(driveName(first)) isn't connected, and some of its files are on another drive. Connect it and try again — nothing was changed."
                    )
                    return
                }
                guard nasIsConnected else {
                    refuseUndo(
                        entry, direction,
                        "“\(entry.title)” can't be \(past): \(driveName(absent[0])) isn't connected, and neither is the NAS, so there is no copy to act on. Connect one of them and try again — nothing was changed."
                    )
                    return
                }
            }
        }

        // Entries an undo would take out of the catalog: one whose file now
        // has a copy in its event's folder cannot just disappear — that
        // would leave the copy in the folder with nothing recording it.
        if direction == .undo, !files.added.isEmpty {
            let locations = self.locations
            let events = Set(files.added.map(\.eventID))
            let inCatalog = Set(model.configuration.photoEventAssignments.lazy
                .filter { events.contains($0.eventID) }
                .map(CatalogStore.eventAssetID))
            let kept = files.added.filter { inCatalog.contains(CatalogStore.eventAssetID($0)) && hasDriveCopy($0, locations: locations) }
            guard kept.isEmpty else {
                refuseMove(
                    name,
                    "\(ApplyPlanOverview.plural(kept.count, "file")) from “\(entry.title)” already have a copy in their event's folder, so it can't be undone here. Open the event and use Return to Unsorted.",
                    files: kept.map { ($0.relativePath as NSString).lastPathComponent }
                )
                return
            }
        }

        // Entries whose photo moved on since stay as they are, and a name taken
        // since is found before any file moves.
        let stale = staleEntryIDs(files, direction)
        let taken = nameClash(files, journal: journal, mode: journalMode, direction: direction, skipping: stale)
        if !taken.isEmpty {
            refuseMove(
                name,
                "\(ApplyPlanOverview.plural(taken.count, "file")) can't be put back under \(taken.count == 1 ? "its" : "their") name: another file has taken it since. Nothing was changed — undo or rename the newer file first.",
                files: taken
            )
            return
        }

        // A NAS copy follows a job: the step runs behind the job gate, like the
        // moves it takes back — never beside a NAS rename job that has the same
        // batch in hand.
        let needsJob = !journalMode.isSkip || !files.trashed.isEmpty || !files.nasLinks.isEmpty
        guard needsJob else {
            // Catalog entries only: no drive to rename, no NAS copy to follow.
            let leaving = direction == .undo ? files.added : files.removed
            let joining = direction == .undo ? files.removed : files.added
            let putBack = joining.filter { !stale.contains(CatalogStore.eventAssetID($0)) }
            if !joining.isEmpty, putBack.isEmpty {
                dropEntry(
                    entry, direction,
                    "“\(entry.title)” can't be \(past): \(ApplyPlanOverview.plural(joining.count, "file")) moved on since, so \(joining.count == 1 ? "its" : "their") entr\(joining.count == 1 ? "y is" : "ies are") not the ones the catalog has now. Nothing was changed, and it was dropped from the history."
                )
                return
            }
            applyAssignmentChange(AssignmentChange(title: entry.title, removed: leaving, added: reinstatable(putBack)), touching: nil)
            finish(entry, direction)
            model.statusMessage = "\(direction.past) “\(entry.title)”." + (stale.isEmpty ? "" : " \(ApplyPlanOverview.plural(stale.count, "file")) moved on since and \(stale.count == 1 ? "was" : "were") left where they are now.")
            return
        }
        runFilesStep(entry, files, direction, journalURL: journalURL, journal: journal, mode: journalMode, skipping: stale)
    }

    /// The entries a step would put back whose file moved on since: the entry
    /// it took out (or is about to take out) and the one it put in (or
    /// would) describe one photo — same name, size and modification time —
    /// and neither is in the catalog any more, because a later change moved
    /// the photo elsewhere. Putting the old entry back would give one photo
    /// two owners.
    private func staleEntryIDs(_ files: UndoFilesAction, _ direction: UndoDirection) -> Set<String> {
        let current = Set(model.configuration.photoEventAssignments.map(CatalogStore.eventAssetID))
        let leaving = direction == .undo ? files.added : files.removed
        let joining = direction == .undo ? files.removed : files.added
        guard !leaving.isEmpty, !joining.isEmpty else { return [] }
        let partners = Dictionary(grouping: leaving, by: { Self.fileKey($0) })
        var stale: Set<String> = []
        for entry in joining {
            guard let paired = partners[Self.fileKey(entry)] else { continue }
            let id = CatalogStore.eventAssetID(entry)
            if !current.contains(id), paired.allSatisfy({ !current.contains(CatalogStore.eventAssetID($0)) }) { stale.insert(id) }
        }
        return stale
    }

    /// A name the step would put an entry back under that another file of the
    /// event has taken since. Decided before any file moves: the drive would
    /// otherwise put the file back and leave it with no entry, or with a
    /// second entry of one name.
    private func nameClash(
        _ files: UndoFilesAction,
        journal: DriveMoveJournal?,
        mode: UndoJournalMode,
        direction: UndoDirection,
        skipping: Set<String>
    ) -> [String] {
        let current = Set(model.configuration.photoEventAssignments.map(CatalogStore.eventAssetID))
        var putBack = direction == .undo ? files.removed : files.added
        var takeOut = direction == .undo ? files.added : files.removed
        if let journal, !mode.isSkip {
            switch direction {
            case .undo:
                let restore = journal.assignmentsToRestore(
                    reversed: mode.laggingIndices ?? journal.completedIndices, fullyUndone: true,
                    isCurrent: { current.contains(CatalogStore.eventAssetID($0)) }
                )
                putBack += restore.removed
                takeOut += restore.added
            case .redo:
                let again = journal.assignmentsToReapply(
                    redone: mode.laggingIndices ?? (journal.undoneIndices ?? journal.completedIndices), fullyRedone: true,
                    isCurrent: { current.contains(CatalogStore.eventAssetID($0)) }
                )
                putBack += again.added
                takeOut += again.removed
            }
        }
        refreshIndexIfNeeded()
        let leaving = Set(takeOut.map(CatalogStore.eventAssetID))
        let known = Set(model.configuration.savedEvents.map(\.id))
        var names: [String] = []
        for entry in putBack where known.contains(entry.eventID) {
            let id = CatalogStore.eventAssetID(entry)
            guard !skipping.contains(id), !current.contains(id) else { continue }
            if let existing = assignmentsByName(inEvent: entry.eventID)[Self.nameKey(entry.relativePath)],
               CatalogStore.eventAssetID(existing) != id, !leaving.contains(CatalogStore.eventAssetID(existing)) {
                names.append("\((entry.relativePath as NSString).lastPathComponent) in \(event(entry.eventID).map(eventTitle) ?? "its event")")
            }
        }
        return names
    }

    /// The mirror keys of the entries a step takes out of the catalog that are
    /// still there: the NAS copies of a catalog-only move go back only for
    /// those. One a later change moved on keeps its NAS copy where that
    /// change put it.
    private func currentAddedMirrorKeys(_ files: UndoFilesAction) -> Set<String> {
        let current = Set(model.configuration.photoEventAssignments.map(CatalogStore.eventAssetID))
        let locations = self.locations
        var keys: Set<String> = []
        for added in files.added where current.contains(CatalogStore.eventAssetID(added)) {
            if let owner = event(added.eventID), let url = locations.archiveURL(for: added, event: owner),
               let relative = locations.nasRelativePath(url.path) {
                keys.insert(NASSyncStore.pathKey(relative))
            }
        }
        return keys
    }

    /// The entries that may be put back: not one the catalog already has,
    /// and not one whose name another file of the event has taken.
    private func reinstatable(_ assignments: [PhotoEventAssignment]) -> [PhotoEventAssignment] {
        guard !assignments.isEmpty else { return [] }
        refreshIndexIfNeeded()
        let known = Set(model.configuration.savedEvents.map(\.id))
        var claimed: [UUID: Set<String>] = [:]
        var result: [PhotoEventAssignment] = []
        for assignment in assignments where known.contains(assignment.eventID) {
            let id = CatalogStore.eventAssetID(assignment)
            let name = Self.nameKey(assignment.relativePath)
            if let existing = assignmentsByName(inEvent: assignment.eventID)[name],
               CatalogStore.eventAssetID(existing) != id { continue }
            guard claimed[assignment.eventID, default: []].insert(name).inserted else { continue }
            result.append(assignment)
        }
        return result
    }

    /// The mirror keys of files the journal's move only changed in the
    /// catalog (a photo only the NAS has): they have no drive rename to go
    /// back, but their NAS copy does. Only those still assigned where the
    /// move put them — one a later change moved on keeps its NAS copy where
    /// that change put it.
    private func catalogOnlyMirrorKeys(of journal: DriveMoveJournal) -> Set<String> {
        let locations = self.locations
        let currentIDs = Set(model.configuration.photoEventAssignments.map(CatalogStore.eventAssetID))
        var keys: Set<String> = []
        for (position, index) in (journal.assignmentMoveIndices ?? []).enumerated()
        where index == nil && position < journal.addedAssignments.count {
            let added = journal.addedAssignments[position]
            if currentIDs.contains(CatalogStore.eventAssetID(added)),
               let owner = event(added.eventID), let url = locations.archiveURL(for: added, event: owner),
               let relative = locations.nasRelativePath(url.path) {
                keys.insert(NASSyncStore.pathKey(relative))
            }
        }
        return keys
    }

    private func runFilesStep(
        _ entry: UndoEntry,
        _ files: UndoFilesAction,
        _ direction: UndoDirection,
        journalURL: URL?,
        journal: DriveMoveJournal?,
        mode: UndoJournalMode,
        skipping stale: Set<String>
    ) {
        let locations = self.locations
        let boundaries = [locations.bufferRoot, locations.privateStagingRoot]
        let nasRoot = locations.nasRoot
        let journalFolder = self.journalFolder
        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
        let fallbackTrashRoot = locations.removedFilesRoot
        let catalogOnly = journal.map { catalogOnlyMirrorKeys(of: $0) } ?? []
        let addedKeys = currentAddedMirrorKeys(files)
        let title = entry.title
        model.runBackgroundJob(
            action: .organize,
            runningNote: "\(direction.gerund) “\(title)”",
            logTitle: "\(direction.past) “\(title)”",
            logDetail: direction == .undo
                ? "Renamed files back to where they were and moved files out of Trash to the paths their manifest recorded. Nothing was replaced. NAS copies that were renamed to follow the move are renamed back; while the NAS is away that is queued. When the drive is not there, only the NAS copies and the catalog go back."
                : "Renamed files forward again and moved files back into Trash. Nothing was replaced. NAS copies follow; while the NAS is away that is queued. When the drive is not there, only the NAS copies and the catalog follow.",
            operation: { progress in
                try Self.performFilesJob(
                    direction: direction, files: files, journalURL: journalURL, journal: journal, mode: mode,
                    catalogOnlyMirrorKeys: catalogOnly, addedMirrorKeys: addedKeys, locations: locations, boundaries: boundaries,
                    nasRoot: nasRoot, journalFolder: journalFolder, catalogURL: catalogURL,
                    fallbackTrashRoot: fallbackTrashRoot, progress: progress
                )
            },
            completion: { [weak self] outcome in
                guard let self else { return "" }
                return finishFilesStep(entry, files, direction, outcome: outcome, skipping: stale)
            }
        )
    }

    /// The drive, Trash, and NAS part of an Undo or Redo — runs off the main actor.
    nonisolated private static func performFilesJob(
        direction: UndoDirection,
        files: UndoFilesAction,
        journalURL: URL?,
        journal: DriveMoveJournal?,
        mode: UndoJournalMode,
        catalogOnlyMirrorKeys: Set<String>,
        addedMirrorKeys: Set<String>,
        locations: EventStorageLocations,
        boundaries: [URL],
        nasRoot: URL,
        journalFolder: URL,
        catalogURL: URL,
        fallbackTrashRoot: URL,
        progress: @escaping @Sendable (BackgroundJobUpdate) -> Void
    ) throws -> UndoFilesOutcome {
        var outcome = UndoFilesOutcome()
        let queue = NASRenameQueue(journalFolder: journalFolder)
        let follower = NASMoveFollower(store: try? NASSyncStore(catalogURL: catalogURL), queue: queue)
        func merge(_ result: NASUndoResult) {
            outcome.nas.follow.add(result.follow)
            outcome.nas.cancelled += result.cancelled
            outcome.nas.queued += result.queued
        }
        func mirrorKey(_ path: String) -> String? {
            locations.mirrorRelativePath(forDrivePath: path).map(NASSyncStore.pathKey)
        }
        let trashService = MediaTrashService(removedFilesRoot: fallbackTrashRoot)
        let fileManager = FileManager.default
        let nasMounted = fileManager.fileExists(atPath: nasRoot.path) && VolumeInfo.isAvailable(nasRoot)

        /// The step on the NAS copies and the catalog alone, for the journal
        /// renames `indices` whose drive files are not touched. It is all or
        /// nothing: every rename needs a NAS copy that followed the move, or
        /// nothing is done — an entry with no NAS copy would be swapped into a
        /// place its file is not in, and a half-done step could not be undone
        /// or redone again. False when nothing was done.
        func nasOnly(_ journal: DriveMoveJournal, indices: [Int], lagging: Bool) throws -> Bool {
            var covered: [Int] = []
            let targets = direction == .undo
                ? follower.reversibleTargets(moveJournalID: journal.id)
                : follower.redoableTargets(moveJournalID: journal.id)
            for index in indices where journal.moves.indices.contains(index) {
                if let key = mirrorKey(journal.moves[index].destinationPath), targets.contains(key) { covered.append(index) }
            }
            outcome.journal = journal
            let uncovered = indices.count - covered.count
            guard uncovered == 0 else {
                outcome.nasOnly = UndoNASOnlyOutcome(covered: [], total: indices.count, wasLagging: lagging, uncovered: uncovered)
                return false
            }
            outcome.nasOnly = UndoNASOnlyOutcome(covered: covered, total: indices.count, wasLagging: lagging)
            let hasCatalogOnly = (journal.assignmentMoveIndices ?? []).contains { $0 == nil }
            guard !covered.isEmpty || hasCatalogOnly else { return true }
            do {
                switch direction {
                case .undo:
                    let keys = Set(covered.compactMap { mirrorKey(journal.moves[$0].destinationPath) })
                    merge(try follower.undo(moveJournalID: journal.id, nasRoot: nasRoot, reversedMirrorKeys: keys.union(catalogOnlyMirrorKeys)))
                case .redo:
                    merge(try follower.redo(moveJournalID: journal.id, nasRoot: nasRoot))
                }
            } catch {
                DebugLog.shared.log("nas.rename.undo", subsystem: .apply, level: .error, outcome: .error, error: error.localizedDescription)
            }
            return true
        }
        func finished() -> UndoFilesOutcome {
            outcome.remainingNASRenames = queue.pendingRenameCount(nasRoot: nasRoot.path)
            return outcome
        }

        switch direction {
        case .undo:
            if !files.trashed.isEmpty {
                // Each spare copy is in its batch (restore it), already back at
                // its place (the Trash window restored it: nothing to do), or
                // nowhere — its drive is unplugged or was emptied. The ones that
                // are nowhere can only be acted on through the NAS copy that
                // followed them, and only if every one of them has one: the step
                // is all or nothing.
                func inBatch(_ file: UndoTrashedFile) -> Bool {
                    fileManager.fileExists(atPath: URL(fileURLWithPath: file.batchFolder).appendingPathComponent(file.entry.trashedRelativePath).path)
                }
                let lost = files.trashed.filter { !inBatch($0) && !fileManager.fileExists(atPath: $0.entry.originalAbsolutePath) }
                if lost.isEmpty || files.nasLinks.isEmpty {
                    outcome.trash = trashService.restore(items: files.trashed.map(\.item)) { update in
                        progress(DashboardModel.jobUpdate(from: update, notePrefix: "Restoring", command: ""))
                    }
                } else if nasMounted {
                    // Only a trashed file with a NAS copy that followed it has
                    // an entry to put back: the entry would name a file that
                    // is nowhere else.
                    let origins = Set(files.nasLinks.flatMap { follower.reversibleRenames(moveJournalID: $0).map(\.from) })
                    let covered = lost.map(\.entry.originalAbsolutePath).filter { path in
                        mirrorKey(path).map { origins.contains($0) } ?? false
                    }
                    let uncovered = lost.count - covered.count
                    outcome.trashNASOnly = UndoTrashNASOnlyOutcome(covered: uncovered == 0 ? Set(covered) : [], uncovered: uncovered)
                    if uncovered > 0 { return finished() }
                    let restorable = files.trashed.filter(inBatch)
                    if !restorable.isEmpty {
                        outcome.trash = trashService.restore(items: restorable.map(\.item)) { update in
                            progress(DashboardModel.jobUpdate(from: update, notePrefix: "Restoring", command: ""))
                        }
                    }
                } else {
                    outcome.trashNASOnly = UndoTrashNASOnlyOutcome(covered: [], nasAbsent: true)
                    return finished()
                }
            }
            switch mode {
            case .skip:
                break
            case .lagging(let indices):
                if let journal, try !nasOnly(journal, indices: indices, lagging: true) { return finished() }
            case .drive:
                guard let journalURL, let journal else { break }
                // Can any of its drive files be reached? A drive that is
                // unplugged, or was wiped, cannot give them back.
                let completed = journal.completedIndices.filter { journal.moves.indices.contains($0) }
                let reachable = completed.contains { fileManager.fileExists(atPath: journal.moves[$0].destinationPath) }
                if !completed.isEmpty, !reachable {
                    if nasMounted {
                        if try !nasOnly(journal, indices: completed, lagging: false) { return finished() }
                    } else {
                        outcome.nasOnly = UndoNASOnlyOutcome(covered: [], total: completed.count, wasLagging: false, nasAbsent: true)
                        outcome.journal = journal
                        return finished()
                    }
                    break
                }
                let undone = try DriveMoveService().undo(journalURL: journalURL, pruneBoundaries: boundaries) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Undoing", command: ""))
                }
                outcome.journalReport = undone.report
                outcome.journal = undone.journal
                // The move's NAS renames are journaled under the same id. Only
                // the ones whose drive file really went back are reversed —
                // the NAS follows the drive, wherever the drive file is.
                let reversedMirrorKeys = Set(undone.report.moved.compactMap { mirrorKey($0.sourcePath) }).union(catalogOnlyMirrorKeys)
                do {
                    merge(try follower.undo(moveJournalID: undone.journal.id, nasRoot: nasRoot, reversedMirrorKeys: reversedMirrorKeys))
                } catch {
                    DebugLog.shared.log("nas.rename.undo", subsystem: .apply, level: .error, outcome: .error, error: error.localizedDescription)
                }
            }
            for link in files.nasLinks {
                // The renames a catalog-only move queued go back only for the
                // entries still where the move put them; a later change that
                // took a photo on keeps its NAS copy where it put it. Merges,
                // set-asides and folder renames go back whole.
                let isMove = queue.batches(forMoveJournal: link).contains { $0.origin == .move }
                do {
                    merge(try follower.undo(moveJournalID: link, nasRoot: nasRoot, reversedMirrorKeys: isMove ? addedMirrorKeys : nil))
                } catch {
                    DebugLog.shared.log("nas.rename.undo", subsystem: .apply, level: .error, outcome: .error, error: error.localizedDescription)
                }
            }
        case .redo:
            switch mode {
            case .skip:
                break
            case .lagging(let indices):
                if let journal, try !nasOnly(journal, indices: indices, lagging: true) { return finished() }
            case .drive:
                guard let journalURL, let journal else { break }
                let undoneIndices = (journal.undoneIndices ?? journal.completedIndices).filter { journal.moves.indices.contains($0) }
                let reachable = undoneIndices.contains { fileManager.fileExists(atPath: journal.moves[$0].sourcePath) }
                if !undoneIndices.isEmpty, !reachable {
                    if nasMounted {
                        if try !nasOnly(journal, indices: undoneIndices, lagging: false) { return finished() }
                    } else {
                        outcome.nasOnly = UndoNASOnlyOutcome(covered: [], total: undoneIndices.count, wasLagging: false, nasAbsent: true)
                        outcome.journal = journal
                        return finished()
                    }
                    break
                }
                let redone = try DriveMoveService().redo(journalURL: journalURL, pruneBoundaries: boundaries) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Redoing", command: ""))
                }
                outcome.journalReport = redone.report
                outcome.journal = redone.journal
                do {
                    merge(try follower.redo(moveJournalID: redone.journal.id, nasRoot: nasRoot))
                } catch {
                    DebugLog.shared.log("nas.rename.redo", subsystem: .apply, level: .error, outcome: .error, error: error.localizedDescription)
                }
            }
            for link in files.nasLinks {
                do {
                    merge(try follower.redo(moveJournalID: link, nasRoot: nasRoot))
                } catch {
                    DebugLog.shared.log("nas.rename.redo", subsystem: .apply, level: .error, outcome: .error, error: error.localizedDescription)
                }
            }
            if !files.trashed.isEmpty {
                let entries = files.trashed.map(\.entry)
                let organized = entries.map { OrganizeFile(path: $0.originalAbsolutePath, size: $0.size, modifiedAt: $0.capturedAt ?? Date()) }
                var context = TrashContext(locationName: entries.first?.originalLocationName, deviceID: entries.first?.deviceID)
                for entry in entries {
                    let key = EventStorageLocations.pathKey(entry.originalAbsolutePath)
                    if let id = entry.eventID {
                        context.eventIDsByPathKey[key] = id
                        if let name = entry.eventName { context.eventNamesByID[id] = name }
                    }
                    if !entry.personNames.isEmpty { context.personNamesByPathKey[key] = entry.personNames }
                    if let date = entry.capturedAt { context.captureDatesByPathKey[key] = date }
                    if !entry.droppedAssignments.isEmpty { context.assignmentsByPathKey[key] = entry.droppedAssignments }
                }
                let origin = files.trashOriginRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? DuplicateResolver.commonFolder(of: entries.map(\.originalAbsolutePath))
                outcome.retrashed = try trashService.trash(files: organized, originRoot: origin, context: context) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Moving to Trash", command: ""))
                }
            }
        }
        outcome.remainingNASRenames = queue.pendingRenameCount(nasRoot: nasRoot.path)
        return outcome
    }

    /// Back on the main actor: the catalog follows the files, the boards
    /// re-read, the history moves the entry.
    private func finishFilesStep(
        _ entry: UndoEntry,
        _ files: UndoFilesAction,
        _ direction: UndoDirection,
        outcome: UndoFilesOutcome,
        skipping stale: Set<String> = []
    ) -> String {
        nasRenamesApplied(outcome.nas.follow, remaining: outcome.remainingNASRenames)
        var takeOut = direction == .undo ? files.added : files.removed
        var putBack = direction == .undo ? files.removed : files.added
        var pieces: [String] = []
        var complete = true
        var madeProgress = false
        var journalClosedEmpty = false
        var trashGone = false
        var refused = false
        var updatedFiles = files

        if let report = outcome.journalReport, let journal = outcome.journal {
            retargetMovedPaths(report.moved)
            let current = Set(model.configuration.photoEventAssignments.map(CatalogStore.eventAssetID))
            switch direction {
            case .undo:
                // Only the catalog entries whose file went back swap back: an
                // entry left pointing at the event it left, with its file
                // still in the event it joined, would be a file the app
                // cannot find.
                let restore = journal.assignmentsToRestore(
                    reversed: report.reversedIndices,
                    fullyUndone: report.skipped.isEmpty,
                    isCurrent: { current.contains(CatalogStore.eventAssetID($0)) }
                )
                takeOut += restore.added
                putBack += restore.removed
                pieces.append("Moved \(report.moved.count) file(s) back.")
            case .redo:
                let again = journal.assignmentsToReapply(
                    redone: report.reversedIndices,
                    fullyRedone: report.skipped.isEmpty,
                    isCurrent: { current.contains(CatalogStore.eventAssetID($0)) }
                )
                takeOut += again.removed
                putBack += again.added
                pieces.append("Moved \(report.moved.count) file(s) forward again.")
            }
            if !report.reversedIndices.isEmpty { madeProgress = true }
            if let first = report.skipped.first {
                let count = report.skipped.count
                let names = report.skipped.map { "\(($0.move.sourcePath as NSString).lastPathComponent) — \($0.reason)" }
                let again = direction == .undo && journal.undoneAt == nil ? " Undo tries them again." : ""
                pieces.append("\(count) could not move \(direction == .undo ? "back" : "forward") and stayed where they are (\(first.reason.trimmingCharacters(in: CharacterSet(charactersIn: ".")))).\(again)")
                model.recordActivity(
                    action: .organize,
                    state: .failed,
                    title: "\(direction.verb) “\(entry.title)” — \(ApplyPlanOverview.plural(count, "file")) stayed",
                    summary: pieces.joined(separator: " "),
                    detail: Self.fileNameList(names)
                )
                if direction == .undo { complete = false }
                if direction == .undo, report.reversedIndices.isEmpty, journal.undoneAt != nil { journalClosedEmpty = true }
            }
        } else if let nasOnly = outcome.nasOnly, let journal = outcome.journal {
            // The drive's files were not touched — it is unplugged, or empty.
            // The NAS copies that followed the move went back with the
            // catalog entries that name them, all or nothing.
            let current = Set(model.configuration.photoEventAssignments.map(CatalogStore.eventAssetID))
            if nasOnly.nasAbsent {
                pieces.append("Its files are not on the drive any more or the drive isn't connected, and the NAS isn't connected either, so there is no copy to act on. Connect one of them and \(direction == .undo ? "undo" : "redo") again — nothing was changed.")
                complete = false
                refused = true
            } else if nasOnly.uncovered > 0 {
                let rest = nasOnly.uncovered
                pieces.append("\(ApplyPlanOverview.plural(rest, "file")) \(rest == 1 ? "has" : "have") no NAS copy that followed the move, and the drive's files can't be reached, so \(direction.verb.lowercased()) would leave \(rest == 1 ? "it" : "them") behind — nothing was changed. Connect the drive and \(direction.verb.lowercased()) again.")
                complete = false
                refused = true
            } else {
                switch direction {
                case .undo:
                    let restore = journal.assignmentsToRestore(
                        reversed: nasOnly.covered, fullyUndone: false,
                        isCurrent: { current.contains(CatalogStore.eventAssetID($0)) }
                    )
                    takeOut += restore.added
                    putBack += restore.removed
                case .redo:
                    let again = journal.assignmentsToReapply(
                        redone: nasOnly.covered, fullyRedone: false,
                        isCurrent: { current.contains(CatalogStore.eventAssetID($0)) }
                    )
                    takeOut += again.removed
                    putBack += again.added
                }
                if nasOnly.wasLagging {
                    pieces.append("Brought the NAS copies and the catalog in step with the drive's files, which had been left where they were.")
                    updatedFiles.driveLagging = nil
                } else {
                    pieces.append("The drive isn't connected (or its files are not there), so \(direction.verb.lowercased()) went \(direction == .undo ? "back" : "forward") on the NAS and in the catalog only: \(ApplyPlanOverview.plural(nasOnly.covered.count, "file")) — the drive's copies stay where they are.")
                    // The drive is now one step behind; the next step brings the
                    // entry and the drive level again.
                    updatedFiles.driveLagging = nasOnly.covered
                }
                madeProgress = true
            }
        }

        if direction == .undo, outcome.trash != nil || outcome.trashNASOnly != nil {
            let only = outcome.trashNASOnly
            if only?.nasAbsent == true {
                pieces.append("Its files in Trash are on a drive that isn't connected or was emptied, and the NAS isn't connected either, so there is no copy to act on. Connect one of them and undo again — nothing was changed.")
                complete = false
                refused = true
            } else if let only, only.uncovered > 0 {
                pieces.append("\(ApplyPlanOverview.plural(only.uncovered, "file")) in Trash \(only.uncovered == 1 ? "has" : "have") no NAS copy that followed, and the Trash is on a drive that isn't connected or was emptied, so \(only.uncovered == 1 ? "it" : "they") could not be brought back — nothing was changed. Connect the drive and undo again.")
                complete = false
                refused = true
            } else {
                // A trashed file is back when it went back now, or is at its
                // place for another reason (the Trash window restored it
                // earlier), or its NAS copy went back for it. One that stayed
                // in Trash (a name taken, an error) keeps its catalog entry
                // out; so does one that is nowhere any more (the drive was
                // emptied) — it would be an entry for a file the app cannot
                // find.
                let fileManager = FileManager.default
                let trash = outcome.trash
                let restored = Set(trash?.restored ?? [])
                let conflicted = Set(trash?.conflicts ?? [])
                let nasBack = only?.covered ?? []
                func inPlace(_ file: UndoTrashedFile) -> Bool {
                    let path = file.entry.originalAbsolutePath
                    return restored.contains(path) || (!conflicted.contains(path) && fileManager.fileExists(atPath: path))
                }
                func inBatch(_ file: UndoTrashedFile) -> Bool {
                    fileManager.fileExists(atPath: URL(fileURLWithPath: file.batchFolder).appendingPathComponent(file.entry.trashedRelativePath).path)
                }
                let stillTrashed = files.trashed.filter { !inPlace($0) && !nasBack.contains($0.entry.originalAbsolutePath) }
                let gone = stillTrashed.filter { !inBatch($0) && !conflicted.contains($0.entry.originalAbsolutePath) }
                // A file back at a path its event no longer implies (the event
                // moved since) stays out of the catalog: it would be a file the
                // app cannot find.
                let misplaced = files.trashed.filter { file in
                    inPlace(file) && !file.entry.droppedAssignments.isEmpty
                        && !file.entry.droppedAssignments.contains { impliedPathKeys(for: $0).contains(EventStorageLocations.pathKey(file.entry.originalAbsolutePath)) }
                }
                if !misplaced.isEmpty {
                    pieces.append("\(ApplyPlanOverview.plural(misplaced.count, "file")) went back to a folder its event no longer uses, so \(misplaced.count == 1 ? "its entry was" : "their entries were") not put back.")
                }
                let excluded = Set((stillTrashed + misplaced).flatMap(\.entry.droppedAssignments).map(CatalogStore.eventAssetID))
                putBack.removeAll { excluded.contains(CatalogStore.eventAssetID($0)) }
                if !restored.isEmpty || !nasBack.isEmpty { madeProgress = true }
                if !stillTrashed.isEmpty { complete = false }
                if let trash { pieces.append("Restored \(trash.restored.count) file(s) from Trash.") }
                if !nasBack.isEmpty {
                    pieces.append("The spare copies' drive isn't connected (or is empty), so \(ApplyPlanOverview.plural(nasBack.count, "file")) went back on the NAS and in the catalog only; the copies stay where they are.")
                }
                if !conflicted.isEmpty {
                    pieces.append("\(conflicted.count) stayed in Trash because a file already exists at the original path.")
                }
                if !gone.isEmpty {
                    pieces.append("\(gone.count) file(s) are not in Trash any more, so their entries were not put back.")
                    if gone.count == files.trashed.count, restored.isEmpty, nasBack.isEmpty { trashGone = true }
                } else if let trash, !trash.failed.isEmpty {
                    pieces.append("\(trash.failed.count) could not move back: \(trash.failed.values.first ?? "")")
                }
            }
        }

        if direction == .redo, let batch = outcome.retrashed {
            let went = Set(batch.entries.map { EventStorageLocations.pathKey($0.originalAbsolutePath) })
            // A file that is already gone from its place counts as sent.
            let gone = Set(batch.skipped.filter { $0.reason.hasPrefix("The file is no longer at its original location") }
                .map { EventStorageLocations.pathKey($0.path) })
            let stayed = files.trashed.filter {
                let key = EventStorageLocations.pathKey($0.entry.originalAbsolutePath)
                return !went.contains(key) && !gone.contains(key)
            }
            let excluded = Set(stayed.flatMap(\.entry.droppedAssignments).map(CatalogStore.eventAssetID))
            takeOut.removeAll { excluded.contains(CatalogStore.eventAssetID($0)) }
            if !batch.entries.isEmpty { madeProgress = true }
            pieces.append("Moved \(batch.entries.count) file(s) to Trash again.")
            if !stayed.isEmpty {
                pieces.append("\(stayed.count) stayed in place: \(batch.skipped.first?.reason ?? "it could not be moved").")
            }
            // The next Undo restores from the new batch — and, for a file that
            // was already gone from its place (in Trash under the old batch),
            // from the old one.
            updatedFiles.trashed = batch.undoTrashedFiles + files.trashed.filter {
                gone.contains(EventStorageLocations.pathKey($0.entry.originalAbsolutePath))
            }
            if batch.entries.isEmpty, !stayed.isEmpty { complete = false }
        }

        // A step that could not act (nothing to act on, no volume) changed
        // nothing on disk, so it changes nothing in the catalog either.
        if refused {
            return pieces.joined(separator: " ")
        }

        var updated = entry
        updated.action = .files(updatedFiles)

        // An entry whose photo moved on since stays out.
        let skipped = putBack.filter { stale.contains(CatalogStore.eventAssetID($0)) }
        if !skipped.isEmpty {
            putBack.removeAll { stale.contains(CatalogStore.eventAssetID($0)) }
            pieces.append("\(ApplyPlanOverview.plural(skipped.count, "file")) moved on since, so \(skipped.count == 1 ? "its" : "their") old entr\(skipped.count == 1 ? "y was" : "ies were") not put back.")
        }
        let inCatalog = !takeOut.isEmpty || !putBack.isEmpty
        if inCatalog {
            applyAssignmentChange(
                AssignmentChange(title: entry.title, removed: takeOut, added: reinstatable(putBack)),
                touching: nil
            )
            madeProgress = true
        }
        // The catalog now agrees with the drive and the NAS: the journal's step
        // is finished. Until this is written a crash is replayed at launch.
        if outcome.journalReport != nil, let file = files.journalFile {
            model.flushConfigurationSave()
            try? DriveMoveService.finishStep(journalURL: journalFolder.appendingPathComponent(file))
        }

        // Boards and folders re-read: files come back under their old names
        // (a Keep Both "(2)" name goes back to the plain one), which a board
        // patch cannot match to its tiles.
        var events = Set((files.removed + files.added).map(\.eventID))
        if let journal = outcome.journal { events.formUnion((journal.addedAssignments + journal.removedAssignments).map(\.eventID)) }
        for location in unsortedLocations where sources[location.id]?.result != nil {
            scan(location, force: true)
        }
        for boardID in boardsShowing(events) {
            Task { await self.refreshEvent(boardID) }
        }
        if case .event(let eventID) = selection {
            Task { await self.refreshEvent(eventID) }
        }
        if outcome.trash != nil || outcome.retrashed != nil {
            Self.postTrashChanged(rescanUnsorted: false)
        }

        if direction == .redo, !refused { complete = true }
        let acted = !refused && (madeProgress || (outcome.journalReport == nil && outcome.nasOnly == nil))
        if complete, acted {
            finish(updated, direction)
        } else if (journalClosedEmpty || trashGone) && !madeProgress {
            // The attempt got nowhere and can never get anywhere (the journal
            // is closed, the trashed files are gone): the entry stops
            // standing in front of the older changes.
            undoHistory.remove(entry.id)
            persistUndoHistory()
        } else {
            undoHistory.replace(updated)
            persistUndoHistory()
        }
        let summary = pieces.isEmpty ? "\(direction.past) “\(entry.title)”." : pieces.joined(separator: " ")
        return summary + NASFollowWording.undone(outcome.nas)
    }

    // MARK: - Events: rename, re-date, re-parent

    /// The fields an edit changes.
    private func sameEventFields(_ lhs: SavedCameraEvent, _ rhs: SavedCameraEvent) -> Bool {
        lhs.name == rhs.name
            && lhs.eventDate == rhs.eventDate
            && lhs.parentEventID == rhs.parentEventID
            && lhs.storagePolicy == rhs.storagePolicy
    }

    func recordEventEditUndo(
        before: SavedCameraEvent,
        after: SavedCameraEvent,
        folderMoves: [UndoFolderMove],
        touchedEventIDs: Set<UUID>,
        nasLink: UUID?
    ) {
        guard !sameEventFields(before, after) else { return }
        let verb: String
        if before.name != after.name {
            verb = "Rename"
        } else if before.parentEventID != after.parentEventID {
            verb = "Move"
        } else if before.eventDate != after.eventDate {
            verb = "Change Date of"
        } else {
            verb = "Change Storage of"
        }
        recordUndo(
            "\(verb) \(eventTitle(before))",
            detail: nil,
            .eventEdit(UndoEventEdit(
                eventID: before.id, before: before, after: after, folderMoves: folderMoves,
                touchedEventIDs: touchedEventIDs.sorted { $0.uuidString < $1.uuidString }, nasLink: nasLink
            ))
        )
    }

    private func performEventEditStep(_ entry: UndoEntry, _ edit: UndoEventEdit, _ direction: UndoDirection) {
        guard let current = event(edit.eventID) else {
            dropEntry(entry, direction, "“\(entry.title)” can't be \(direction == .undo ? "undone" : "redone"): the event was deleted since. Nothing was changed, and it was dropped from the history.")
            return
        }
        let expected = direction == .undo ? edit.after : edit.before
        let target = direction == .undo ? edit.before : edit.after
        guard sameEventFields(current, expected) else {
            refuseUndo(entry, direction, "\(eventTitle(current)) was changed since (its name, date, parent or storage setting), so “\(entry.title)” can't be \(direction == .undo ? "undone" : "redone") over it. Nothing was changed.")
            return
        }
        guard !model.isBusy, !model.isStorageBenchmarkRunning else {
            model.statusMessage = "Another file job is already running. Wait for it to finish, then \(direction.verb.lowercased()) again."
            return
        }
        var stepList = direction == .undo
            ? edit.folderMoves.reversed().map { UndoFolderMove(old: $0.new, new: $0.old, caseOnly: $0.caseOnly) }
            : edit.folderMoves
        // The drive's folders. When none of them can be reached (the drive is
        // unplugged, or was emptied) and the NAS has the event's folder, the
        // step renames the event and the NAS folder alone and leaves the
        // drive one step behind (`driveLagging`); the step after it leaves the
        // drive alone too. Some reachable and some not: nothing is done.
        let wasLagging = edit.driveLagging == true
        var nasOnly = wasLagging
        if wasLagging {
            stepList = []
        } else if !stepList.isEmpty {
            let mounted = VolumeInfo.mountedVolumePaths()
            let reachable = stepList.filter {
                VolumeInfo.isAvailable(URL(fileURLWithPath: $0.old), mountedVolumes: mounted) && FileManager.default.fileExists(atPath: $0.old)
            }
            if reachable.count < stepList.count {
                let first = stepList.first { step in !reachable.contains { $0.old == step.old } }?.old ?? ""
                let drive = VolumeInfo.volumeRoot(for: URL(fileURLWithPath: first))?.lastPathComponent ?? (first as NSString).lastPathComponent
                if !reachable.isEmpty {
                    refuseUndo(entry, direction, "Some of the event's folders are on \(drive), which isn't connected or is missing them, and some are not. Connect it and try again — nothing was changed.")
                    return
                }
                // A rename always queues its NAS folder rename, so a link says
                // only that one was queued: what an Undo (or Redo) can act on
                // is a rename that ran, is still waiting, or was closed by
                // Undo — not one recorded as absent because the NAS had no
                // folder to rename.
                let nasFollowed: Bool = {
                    guard let link = edit.nasLink else { return false }
                    let follower = NASMoveFollower(store: nil, queue: NASRenameQueue(journalFolder: self.journalFolder))
                    return direction == .undo
                        ? !follower.reversibleTargets(moveJournalID: link).isEmpty
                        : !follower.redoableTargets(moveJournalID: link).isEmpty
                }()
                guard nasFollowed else {
                    refuseUndo(entry, direction, "The event's folders on \(drive) aren't there — the drive isn't connected or was emptied — and no NAS folder was renamed with them, so there is nothing to act on. Connect the drive and try again — nothing was changed.")
                    return
                }
                guard nasIsConnected else {
                    refuseUndo(entry, direction, "The event's folders on \(drive) aren't there and the NAS isn't connected either, so there is no folder to rename. Connect one of them and try again — nothing was changed.")
                    return
                }
                nasOnly = true
                stepList = []
            }
        }
        let steps = stepList
        let touched = Set(edit.touchedEventIDs).union([edit.eventID])
        let boardsBefore = Set(eventStacks.keys.filter { !scopeIDs($0).isDisjoint(with: touched) })
        // Renaming the event and its NAS folder without the drive's folders
        // leaves every file that has no NAS copy behind: its only copy is in
        // a folder under the name the event no longer has. So the step needs
        // every file of the event (and its subevents) on the NAS — checked
        // in the job, before anything changes.
        let coverageNeeded = nasOnly && !wasLagging
        var familyArchivePaths: [String] = []
        if coverageNeeded {
            let locations = self.locations
            for assignment in model.configuration.photoEventAssignments where touched.contains(assignment.eventID) {
                familyArchivePaths.append(event(assignment.eventID).flatMap { locations.archiveURL(for: assignment, event: $0)?.path } ?? "")
            }
        }
        let archivePaths = familyArchivePaths

        func applyFields() {
            model.updateConfiguration { configuration in
                guard let index = configuration.savedEvents.firstIndex(where: { $0.id == edit.eventID }) else { return }
                configuration.savedEvents[index].name = target.name
                configuration.savedEvents[index].eventDate = target.eventDate
                configuration.savedEvents[index].parentEventID = target.parentEventID
                configuration.savedEvents[index].storagePolicy = target.storagePolicy
                // Adopted entries point straight at the folders.
                for step in steps {
                    let from = URL(fileURLWithPath: step.old).standardizedFileURL.path + "/"
                    let to = URL(fileURLWithPath: step.new).standardizedFileURL.path
                    for assignmentIndex in configuration.photoEventAssignments.indices
                    where touched.contains(configuration.photoEventAssignments[assignmentIndex].eventID) {
                        let root = configuration.photoEventAssignments[assignmentIndex].sourceRootPath
                        if root.hasPrefix(from) {
                            configuration.photoEventAssignments[assignmentIndex].sourceRootPath = to + "/" + root.dropFirst(from.count)
                        }
                    }
                }
            }
        }
        func refreshBoards() {
            let boardsAfter = Set(eventStacks.keys.filter { !scopeIDs($0).isDisjoint(with: touched) })
            for boardID in touched.union(boardsBefore).union(boardsAfter) {
                Task { await refreshEvent(boardID) }
            }
        }

        var updatedEntry = entry
        if wasLagging || nasOnly {
            var next = edit
            // The drive is one step behind after a step that skipped it, and
            // level again after the step that follows.
            next.driveLagging = wasLagging ? nil : true
            updatedEntry.action = .eventEdit(next)
        }
        guard !steps.isEmpty || edit.nasLink != nil else {
            applyFields()
            finish(updatedEntry, direction)
            refreshBoards()
            model.statusMessage = "\(direction.past) “\(entry.title)”."
            return
        }
        let locations = self.locations
        let journalFolder = self.journalFolder
        let nasRoot = locations.nasRoot
        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
        let link = edit.nasLink
        model.runBackgroundJob(
            action: .organize,
            runningNote: "\(direction.gerund) “\(entry.title)”",
            logTitle: "\(direction.past) “\(entry.title)”",
            logDetail: "Renamed the event's folders back with the name, on the drive and — through a journaled NAS rename — on the NAS. Nothing was replaced.",
            operation: { _ in
                if coverageNeeded {
                    let missing = archivePaths.filter { $0.isEmpty || !FileManager.default.fileExists(atPath: $0) }.count
                    guard missing == 0 else {
                        throw ToolkitError.commandFailed("The event's folders on the drive aren't there, and \(missing) of its files have no copy on the NAS, so renaming the event and its NAS folder alone would leave \(missing == 1 ? "it" : "them") behind. Connect the drive and try again — nothing was changed.")
                    }
                }
                var done: [UndoFolderMove] = []
                for step in steps {
                    do {
                        if step.caseOnly {
                            try DriveMoveService().renameFolderChangingCase(from: URL(fileURLWithPath: step.old), to: URL(fileURLWithPath: step.new))
                        } else {
                            try DriveMoveService().moveFolder(from: URL(fileURLWithPath: step.old), to: URL(fileURLWithPath: step.new))
                        }
                        done.append(step)
                    } catch {
                        for back in done.reversed() {
                            if back.caseOnly {
                                try? DriveMoveService().renameFolderChangingCase(from: URL(fileURLWithPath: back.new), to: URL(fileURLWithPath: back.old))
                            } else {
                                try? DriveMoveService().moveFolder(from: URL(fileURLWithPath: back.new), to: URL(fileURLWithPath: back.old))
                            }
                        }
                        throw error
                    }
                }
                var nas = NASUndoResult()
                let queue = NASRenameQueue(journalFolder: journalFolder)
                if let link {
                    let follower = NASMoveFollower(store: try? NASSyncStore(catalogURL: catalogURL), queue: queue)
                    do {
                        nas = direction == .undo
                            ? try follower.undo(moveJournalID: link, nasRoot: nasRoot)
                            : try follower.redo(moveJournalID: link, nasRoot: nasRoot)
                    } catch {
                        DebugLog.shared.log("nas.rename.undo", subsystem: .apply, level: .error, outcome: .error, error: error.localizedDescription)
                    }
                }
                return (nas, queue.pendingRenameCount(nasRoot: nasRoot.path))
            },
            completion: { [weak self] result in
                guard let self else { return "" }
                let (nas, remaining) = result
                nasRenamesApplied(nas.follow, remaining: remaining)
                applyFields()
                finish(updatedEntry, direction)
                refreshBoards()
                let driveNote = nasOnly && !wasLagging
                    ? " The drive's folders aren't there, so the event and its NAS folder were renamed alone; the drive's folders stay as they are."
                    : ""
                return "\(direction.past) “\(entry.title)” — the event is “\(target.name)” again." + driveNote + NASFollowWording.undone(nas)
            }
        )
    }

    // MARK: - Configuration: events, burst splits, rotations

    private func performConfigStep(_ entry: UndoEntry, _ change: UndoConfigChange, _ direction: UndoDirection) {
        switch change {
        case .burstSplit(let split):
            model.updateConfiguration { configuration in
                switch direction {
                case .undo: configuration.burstSplits.removeAll { $0.id == split.id }
                case .redo:
                    if !configuration.burstSplits.contains(where: { $0.id == split.id }) { configuration.burstSplits.append(split) }
                }
            }
            restackBoardsForSplits()
        case .orientations(let changes):
            model.updateConfiguration { configuration in
                for change in changes {
                    let value = direction == .undo ? change.before : change.after
                    if let value { configuration.displayOrientations[change.key] = value } else { configuration.displayOrientations[change.key] = nil }
                }
            }
            invalidateTiles(forOrientationKeys: Set(changes.map(\.key)))
        case .events(let events):
            if let refusal = applyEventsChange(events, direction) {
                refuseUndo(entry, direction, refusal)
                return
            }
        }
        finish(entry, direction)
        model.statusMessage = "\(direction.past) “\(entry.title)”."
    }

    /// Nil when it worked, else why not.
    private func applyEventsChange(_ change: UndoEventsChange, _ direction: UndoDirection) -> String? {
        let creating = direction == .undo ? change.deleted : change.created
        let removing = direction == .undo ? change.created : change.deleted
        for event in removing {
            let owned = model.configuration.photoEventAssignments.count { $0.eventID == event.id }
            guard owned == 0 else {
                return "\(eventTitle(event)) has \(ApplyPlanOverview.plural(owned, "file")) in it now, so it can't be removed. Nothing was changed."
            }
            guard EventHierarchy.descendants(of: event.id, in: model.configuration.savedEvents).isEmpty else {
                return "\(eventTitle(event)) has subevents now, so it can't be removed. Nothing was changed."
            }
        }
        model.updateConfiguration { configuration in
            for event in removing { configuration.savedEvents.removeAll { $0.id == event.id } }
            for event in creating where !configuration.savedEvents.contains(where: { $0.id == event.id }) {
                configuration.savedEvents.append(event)
            }
            for pair in change.edited {
                guard let index = configuration.savedEvents.firstIndex(where: { $0.id == pair.before.id }) else { continue }
                let target = direction == .undo ? pair.before : pair.after
                configuration.savedEvents[index].storagePolicy = target.storagePolicy
                configuration.savedEvents[index].name = target.name
                configuration.savedEvents[index].eventDate = target.eventDate
                configuration.savedEvents[index].parentEventID = target.parentEventID
            }
        }
        if case .event(let id) = selection, removing.contains(where: { $0.id == id }) { selection = nil }
        for pair in change.edited { Task { await refreshEvent(pair.before.id) } }
        return nil
    }

    /// Boards and scanned folders cut their stacks again after the burst
    /// splits changed.
    private func restackBoardsForSplits() {
        let splits = model.configuration.burstSplits
        for id in Array(sources.keys) {
            if let result = sources[id]?.result {
                sources[id]?.result = result.restacked(withSplits: splits)
            }
        }
        for id in Array(eventStacks.keys) {
            if let stacks = eventStacks[id] {
                eventStacks[id] = OrganizeStacker.stacks(for: stacks.flatMap(\.items), splits: splits)
                    .carryingIDs(from: stacks)
            }
        }
        let liveIDs = Set(sources.values.compactMap(\.result).flatMap { $0.stacks.map(\.id) })
            .union(eventStacks.values.flatMap { $0.map(\.id) })
        selectedStackIDs.formIntersection(liveIDs)
        if let focusedStackID, !liveIDs.contains(focusedStackID) { self.focusedStackID = nil }
    }

    /// Tiles whose rotation changed decode again.
    private func invalidateTiles(forOrientationKeys keys: Set<String>) {
        let stacks = sources.values.compactMap(\.result).flatMap(\.stacks) + eventStacks.values.flatMap { $0 }
        for file in stacks.flatMap(\.files) where keys.contains(DisplayRotation.fileKey(for: file)) {
            TileImageLoader.shared.invalidate(url: file.url)
        }
    }

    // MARK: - Faces

    /// The rows a face action may change, captured before it runs.
    func beginFaceUndo(expandingPeople: Set<UUID> = [], people: Set<UUID> = [], faces: Set<UUID> = []) -> FaceSnapshot? {
        try? faceStore.captureSnapshot(expandingPeople: expandingPeople, people: people, faces: faces)
    }

    /// Registers a face action that worked.
    func recordFaceUndo(_ before: FaceSnapshot?, _ title: String, detail: String? = nil) {
        guard let before else { return }
        recordUndo(title, detail: detail, .faces(before))
    }

    private func performFacesStep(_ entry: UndoEntry, _ snapshot: FaceSnapshot, _ direction: UndoDirection) {
        guard model.activeJob?.action != .faceScan else {
            model.statusMessage = "A face scan is running. \(direction.verb) “\(entry.title)” after it finishes — nothing was changed."
            return
        }
        do {
            let replaced = try faceStore.swapSnapshot(snapshot)
            var updated = entry
            updated.action = .faces(replaced)
            facesRevision &+= 1
            finish(updated, direction)
            model.statusMessage = "\(direction.past) “\(entry.title)”. Face rows only — no photo was touched."
        } catch {
            refuseUndo(entry, direction, "The face rows could not be restored: \(error.localizedDescription). Nothing was changed.")
        }
    }

    // MARK: - Changes that live in memory

    /// Registers a change whose undo and redo are closures (regrouped bursts).
    func recordSessionUndo(_ title: String, detail: String? = nil, undo: @escaping @MainActor () -> Void, redo: @escaping @MainActor () -> Void) {
        let token = UUID()
        undoSessionHandlers[token] = UndoSessionHandlers(undo: undo, redo: redo)
        recordUndo(title, detail: detail, .session(token))
    }

    private func performSessionStep(_ entry: UndoEntry, _ token: UUID, _ direction: UndoDirection) {
        guard let handlers = undoSessionHandlers[token] else {
            undoHistory.remove(entry.id)
            persistUndoHistory()
            model.statusMessage = "“\(entry.title)” can't be \(direction == .undo ? "undone" : "redone") any more."
            return
        }
        switch direction {
        case .undo: handlers.undo()
        case .redo: handlers.redo()
        }
        finish(entry, direction)
        model.statusMessage = "\(direction.past) “\(entry.title)”."
    }

    /// A duplicate resolution: the copies that went to Trash, the entries
    /// that were dropped (also those whose file stayed), and the NAS copies
    /// that were set aside.
    func recordDuplicatesUndo(outcome: DuplicateResolutionOutcome, nasLink: UUID, eventFolders: [String: String]) {
        let trashed = outcome.trashBatch?.undoTrashedFiles ?? []
        guard !outcome.removedAssignments.isEmpty || !trashed.isEmpty else { return }
        var files = UndoFilesAction(removed: outcome.removedAssignments, trashed: trashed)
        if !trashed.isEmpty {
            files.nasLinks = [nasLink]
            files.eventFolders = eventFolders
        }
        let count = max(outcome.removedAssignments.count, trashed.count)
        recordUndo("Remove Duplicate Copies", detail: "\(count) cop\(count == 1 ? "y" : "ies")", .files(files))
    }

    /// The places an entry's file is expected on this Mac: its event's folders
    /// on either drive, and the folder it was sorted from.
    func impliedPathKeys(for assignment: PhotoEventAssignment) -> Set<String> {
        guard let owner = event(assignment.eventID) else { return [] }
        let locations = self.locations
        var keys: Set<String> = []
        for policy in EventStoragePolicy.allCases {
            if let url = locations.driveURL(for: assignment, event: owner, policy: policy) {
                keys.insert(EventStorageLocations.pathKey(url.path))
            }
        }
        if let source = locations.sourceURL(for: assignment) { keys.insert(EventStorageLocations.pathKey(source.path)) }
        return keys
    }

    // MARK: - Trash restore

    /// Puts back the catalog entries a restored Trash file recorded, when
    /// its event still exists and the event has not taken the name since.
    /// Called after a restore from the Trash window; Undo goes through the
    /// same rule. Returns how many entries came back.
    @discardableResult
    func reinstateTrashedAssignments(_ report: MediaTrashRestoreReport) -> Int {
        // A file goes back to the path it left. When its event was renamed or
        // moved since, that is a folder the event no longer uses: an entry put
        // back would name a file the app cannot find, so it stays out.
        var placed: [PhotoEventAssignment] = []
        for entry in report.restoredEntries {
            let key = EventStorageLocations.pathKey(entry.originalAbsolutePath)
            placed += entry.droppedAssignments.filter { impliedPathKeys(for: $0).contains(key) }
        }
        let candidates = reinstatable(placed)
        let present = Set(model.configuration.photoEventAssignments.map(CatalogStore.eventAssetID))
        let fresh = candidates.filter { !present.contains(CatalogStore.eventAssetID($0)) }
        guard !fresh.isEmpty else { return 0 }
        applyAssignmentChange(AssignmentChange(title: "Restore from Trash", removed: [], added: fresh), touching: nil)
        return fresh.count
    }
}
