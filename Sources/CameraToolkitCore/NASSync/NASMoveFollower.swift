import Darwin
import Foundation

/// What a run of NAS renames did.
public struct NASFollowResult: Equatable, Sendable {
    /// Files renamed at the NAS to follow the drive.
    public var renamed = 0
    /// Whole event folders renamed (each is one rename on the server).
    public var foldersRenamed = 0
    /// Stale copies moved to the NAS's `_Stale Copies` folder because the
    /// identical file already sat at the new path.
    public var merged = 0
    /// Nothing on the NAS at the old path: nothing to rename.
    public var absent = 0
    /// A different file sits at the new path; both left untouched.
    public var differs: [NASSyncIssue] = []
    /// Same size at the new path and the two copies could not both be read
    /// to compare them; both left exactly as they are.
    public var unproven: [NASSyncIssue] = []
    public var failed: [NASSyncIssue] = []
    /// Renames the share refused with a transient error (a dropped session,
    /// `EIO`, a stale handle): tried again within the run, and left queued
    /// for the next one. The copy has not moved.
    public var deferred: [NASSyncIssue] = []
    /// Left queued because the NAS went away or the job was stopped.
    public var notAttempted = 0
    public var stoppedReason: String?
    /// Sync records that could not be updated (the copies are fine; the
    /// next sync re-derives them).
    public var catalogProblem: String?
    /// Emptied NAS folders removed.
    public var prunedFolders = 0
    public var batches = 0
    public var bytesRenamed: Int64 = 0
    /// Every file rename and every trashed stale copy, in order — what a
    /// listing is patched with.
    public var applied: [NASRename] = []

    public init() {}

    /// Renames, merges, and folder renames: what changed on the NAS.
    public var changed: Int { renamed + merged + foldersRenamed }
    public var isEmpty: Bool {
        changed == 0 && absent == 0 && differs.isEmpty && unproven.isEmpty && failed.isEmpty && deferred.isEmpty && notAttempted == 0
    }
    public var succeeded: Bool { failed.isEmpty && differs.isEmpty && unproven.isEmpty && deferred.isEmpty && notAttempted == 0 && stoppedReason == nil }

    public mutating func add(_ other: NASFollowResult) {
        renamed += other.renamed
        foldersRenamed += other.foldersRenamed
        merged += other.merged
        absent += other.absent
        differs += other.differs
        unproven += other.unproven
        failed += other.failed
        deferred += other.deferred
        notAttempted += other.notAttempted
        stoppedReason = stoppedReason ?? other.stoppedReason
        catalogProblem = catalogProblem ?? other.catalogProblem
        prunedFolders += other.prunedFolders
        batches += other.batches
        bytesRenamed += other.bytesRenamed
        applied += other.applied
    }

    /// The listing follows what moved, so counts stay right without
    /// listing the NAS again.
    public func patch(_ listing: inout NASTreeListing) {
        for op in applied {
            switch (op.kind, op.state) {
            case (.folder, _): listing.recordFolderRenamed(from: op.from, to: op.to)
            case (.file, .renamed): listing.recordRenamed(from: op.from, to: op.to)
            case (.file, .merged): listing.recordRemoved(op.from)
            default: break
            }
        }
    }

    /// What happened, as lower-case clauses; empty when nothing did.
    public var clauses: [String] {
        var parts: [String] = []
        if renamed > 0 { parts.append("renamed \(renamed) cop\(renamed == 1 ? "y" : "ies") on the NAS") }
        if foldersRenamed > 0 { parts.append("renamed \(foldersRenamed) event folder\(foldersRenamed == 1 ? "" : "s") on the NAS") }
        if merged > 0 { parts.append("set aside \(merged) stale duplicate\(merged == 1 ? "" : "s") on the NAS") }
        if !differs.isEmpty { parts.append("\(differs.count) left untouched (a different file is already at the new name)") }
        if !unproven.isEmpty { parts.append("\(unproven.count) left untouched (the two copies could not both be read to compare them)") }
        if !failed.isEmpty { parts.append("\(failed.count) could not be renamed") }
        if !deferred.isEmpty { parts.append("\(deferred.count) hit a network error and stay queued to be tried again") }
        if notAttempted > 0 { parts.append("\(notAttempted) still queued") }
        return parts
    }

    /// One sentence for the status line and the Jobs list.
    public var summary: String {
        let parts = clauses.isEmpty ? [absent > 0 ? "nothing to rename on the NAS" : "nothing to do"] : clauses
        var text = parts.joined(separator: ", ")
        text = text.prefix(1).uppercased() + text.dropFirst() + "."
        if let stoppedReason { text += " " + stoppedReason }
        return text
    }
}

/// What Undo did on the NAS side of a move.
public struct NASUndoResult: Equatable, Sendable {
    public var follow = NASFollowResult()
    /// Renames of the move that had not run yet and were dropped.
    public var cancelled = 0
    /// Reverse renames left queued because the NAS is not there.
    public var queued = 0

    public init() {}
}

/// Makes the NAS mirror follow the drive when files move: the copy of a
/// moved file is renamed *on the NAS* to the new path, so Sync to NAS finds
/// it there instead of copying it again next to the old one.
///
/// One server-side rename per file — a metadata call, instant on ZFS, no
/// bytes cross the wire — and never a read of file contents. Exclusive,
/// like every rename here: nothing is ever replaced.
///
/// - The old path is checked with one `lstat`; a NAS copy of another size
///   is a different file and is left alone.
/// - A new path that is free is created (folders as needed) and the file
///   renamed into it; its sync record moves with it (same hash, size and
///   time), so it stays "verified on the NAS".
/// - A new path that already holds the identical file — proven by two
///   verified records with one hash, or by hashing both *on the NAS* when
///   SSH verification is set up — keeps that file, and the stale copy goes
///   to `.Camera Toolkit/_Stale Copies/<stamp>/<old path>` on the NAS. A
///   different file, or a same-size file nothing can prove identical, is
///   left exactly as it is and reported.
/// - Every batch is written down before the first rename and its progress
///   saved as it goes, so a crash resumes (already-renamed files are
///   recognised) and Undo can reverse it.
/// - Folders emptied by the renames are removed up to the NAS root, by the
///   same rule the drive move uses (only Finder metadata may remain).
public struct NASMoveFollower {
    public typealias Progress = @Sendable (FileOperationProgress) -> Void

    /// Where stale duplicates are set aside on the NAS, under the root.
    /// Deliberately not a `_Trash` folder: Empty Trash covers those, and
    /// nothing here is ever emptied by the app.
    public static let staleFolderPath = "\(EventStorageLocations.toolkitFolderName)/_Stale Copies"

    /// Tries a rename gets in one run when the share answers with a
    /// transient error, and over all runs before it is given up as failed.
    public static let attemptsPerRun = 2
    public static let maxAttempts = 6

    private let store: NASSyncStore?
    private let remoteVerifier: NASRemoteVerifier?
    private let queue: NASRenameQueue?
    private let now: @Sendable () -> Date
    private let isCancelled: @Sendable () -> Bool
    private let retryDelay: TimeInterval

    /// `retryDelay`: how long a rename waits before its second try in one
    /// run after a transient share error.
    public init(
        store: NASSyncStore?,
        remoteVerifier: NASRemoteVerifier? = nil,
        queue: NASRenameQueue? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        retryDelay: TimeInterval = 1,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) {
        self.store = store
        self.remoteVerifier = remoteVerifier
        self.queue = queue
        self.now = now
        self.retryDelay = max(0, retryDelay)
        self.isCancelled = isCancelled
    }

    func storeRecords(nasRoot: String) throws -> [String: NASSyncRecord] {
        try store?.records(nasRoot: nasRoot) ?? [:]
    }

    func cancellationCheck() -> Bool { isCancelled() }

    // MARK: Planning

    /// A path under the NAS root that belongs to an event:
    /// `<year>/…/Originals|Edited/…`. A rename is only followed between
    /// two such paths — never into or out of a folder that is not an event.
    public static func isEventPath(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0].count == 4, parts[0].allSatisfy(\.isNumber) else { return false }
        return parts.dropFirst().dropLast().contains { EventStorageLocations.reservedEventFolderNames.contains(String($0)) }
    }

    /// The NAS renames a drive move owes: each move whose two ends both
    /// have a mirror path (under the Buffer or Private root, in an event
    /// folder) and where that path changed. A move between the Buffer and
    /// Private keeps its mirror path, so it owes nothing.
    public static func renames(
        forMoves moves: [DriveMove],
        locations: EventStorageLocations,
        eventIDsByDestination: [String: UUID] = [:],
        previousEventIDs: [String: UUID] = [:]
    ) -> [NASRename] {
        var seen = Set<String>()
        var renames: [NASRename] = []
        for move in moves {
            guard let old = locations.mirrorRelativePath(forDrivePath: move.sourcePath),
                  let new = locations.mirrorRelativePath(forDrivePath: move.destinationPath),
                  NASSyncStore.pathKey(old) != NASSyncStore.pathKey(new),
                  isEventPath(old), isEventPath(new),
                  seen.insert(NASSyncStore.pathKey(old)).inserted else { continue }
            renames.append(NASRename(
                from: old,
                to: new,
                byteCount: move.byteCount,
                eventID: eventIDsByDestination[EventStorageLocations.pathKey(move.destinationPath)],
                previousEventID: previousEventIDs[EventStorageLocations.pathKey(move.destinationPath)]
            ))
        }
        return renames
    }

    /// What one Move to Event owes the NAS: the renames that follow its
    /// drive moves (Undo of the move's journal reverses these), and the
    /// stale NAS copies of extra drive copies that went to Trash because
    /// the target already had the identical file (its NAS copy stays).
    public static func renames(
        forEventMove outcome: EventMoveOutcome,
        locations: EventStorageLocations
    ) -> (moves: [NASRename], merges: [NASRename]) {
        var eventIDs: [String: UUID] = [:]
        var previousIDs: [String: UUID] = [:]
        for item in outcome.moved + outcome.keptBoth.map(\.item) {
            guard let destination = item.move?.destinationPath else { continue }
            let key = EventStorageLocations.pathKey(destination)
            eventIDs[key] = item.added.eventID
            previousIDs[key] = item.removed.eventID
        }
        var moves = renames(
            forMoves: outcome.report.moved,
            locations: locations,
            eventIDsByDestination: eventIDs,
            previousEventIDs: previousIDs
        )
        // A file only the NAS has moved in the catalog alone; its NAS copy
        // has no drive move to follow, so it owes its own rename.
        var seen = Set(moves.map { NASSyncStore.pathKey($0.from) })
        for item in outcome.moved {
            guard item.move == nil, let copy = item.nasCopy,
                  NASSyncStore.pathKey(copy.from) != NASSyncStore.pathKey(copy.to),
                  isEventPath(copy.from), isEventPath(copy.to),
                  seen.insert(NASSyncStore.pathKey(copy.from)).inserted else { continue }
            moves.append(NASRename(
                from: copy.from,
                to: copy.to,
                byteCount: item.removed.fileSize,
                eventID: item.added.eventID,
                previousEventID: item.removed.eventID
            ))
        }
        let trashed = Set((outcome.trashBatch?.entries ?? []).map { EventStorageLocations.pathKey($0.originalAbsolutePath) })
        var mergeMoves: [DriveMove] = []
        var mergeEvents: [String: UUID] = [:]
        for item in outcome.merged {
            guard let extra = item.currentPath, trashed.contains(EventStorageLocations.pathKey(extra)),
                  let kept = item.takenBy.first(where: { locations.mirrorRelativePath(forDrivePath: $0) != nil }) else { continue }
            mergeMoves.append(DriveMove(sourcePath: extra, destinationPath: kept, byteCount: item.removed.fileSize))
            mergeEvents[EventStorageLocations.pathKey(kept)] = item.added.eventID
        }
        return (moves, renames(forMoves: mergeMoves, locations: locations, eventIDsByDestination: mergeEvents))
    }

    /// The stale NAS copies of duplicate drive copies "Keep in X only"
    /// sent to Trash: each is set against a kept copy's NAS path, where
    /// the identical file already is.
    public static func renames(
        forDuplicates resolutions: [DuplicateResolution],
        outcome: DuplicateResolutionOutcome,
        locations: EventStorageLocations
    ) -> [NASRename] {
        let trashed = Set(outcome.trashed.map(\.pathKey))
        var moves: [DriveMove] = []
        for resolution in resolutions {
            guard let kept = resolution.group.copies(of: resolution.keep)
                .first(where: { locations.mirrorRelativePath(forDrivePath: $0.path) != nil }) else { continue }
            for copy in resolution.group.copies where resolution.drop.contains(copy.owner) && trashed.contains(copy.pathKey) {
                moves.append(DriveMove(sourcePath: copy.path, destinationPath: kept.path, byteCount: copy.byteCount))
            }
        }
        return renames(forMoves: moves, locations: locations)
    }

    /// The event's folder under the NAS root.
    public static func mirrorEventFolder(of event: SavedCameraEvent, locations: EventStorageLocations) -> String {
        PortablePath.sanitize(relativePath: locations.layout(for: event, deviceID: nil).mirrorEventFolderPath)
    }

    /// The one folder rename an event rename (or date change, or new
    /// parent) owes, or nil when its NAS folder keeps its path. Its
    /// subevents' folders nest inside and move with it.
    public static func folderRename(
        from old: SavedCameraEvent,
        to renamed: SavedCameraEvent,
        locations: EventStorageLocations
    ) -> NASRename? {
        let from = mirrorEventFolder(of: old, locations: locations)
        let to = mirrorEventFolder(of: renamed, locations: locations)
        guard NASSyncStore.pathKey(from) != NASSyncStore.pathKey(to) else { return nil }
        return NASRename(kind: .folder, from: from, to: to, eventID: renamed.id, previousEventID: old.id)
    }

    /// The batch an event rename owes the NAS, to be saved to the queue
    /// right away: always, whether or not the NAS is connected and whether
    /// or not its folder is at the old name *yet*. A second rename before
    /// the first one ran finds no folder at its old name — that is the
    /// first rename's, still queued — and skipping it stranded the NAS
    /// folder at the first name for good. Queued in order, the two run in
    /// order; when the NAS never had the folder the op is recorded as
    /// `.absent`, which is harmless.
    public static func folderRenameBatch(
        from old: SavedCameraEvent,
        to renamed: SavedCameraEvent,
        locations: EventStorageLocations,
        title: String
    ) -> NASRenameBatch? {
        guard let owed = folderRename(from: old, to: renamed, locations: locations) else { return nil }
        return NASRenameBatch(title: title, origin: .folderRename, nasRoot: locations.nasRoot.path, ops: [owed])
    }

    // MARK: Undo

    /// The batch that reverses `batch`: every applied rename backwards,
    /// newest first; a merged stale copy comes back out of the stale
    /// folder. Nil when nothing was applied.
    public static func inverse(of batch: NASRenameBatch, now: Date = Date()) -> NASRenameBatch? {
        var ops: [NASRename] = []
        for op in batch.ops.reversed() {
            switch op.state {
            case .renamed:
                ops.append(NASRename(
                    kind: op.kind, from: op.to, to: op.from, byteCount: op.byteCount,
                    eventID: op.previousEventID, previousEventID: op.eventID
                ))
            case .merged:
                guard let stale = op.stalePath else { continue }
                ops.append(NASRename(kind: .file, from: stale, to: op.from, byteCount: op.byteCount))
            default:
                continue
            }
        }
        guard !ops.isEmpty else { return nil }
        return NASRenameBatch(
            title: "Undo: " + batch.title,
            origin: .undo,
            createdAt: now,
            nasRoot: batch.nasRoot,
            undoOf: batch.id,
            ops: ops
        )
    }

    /// Undo of a move on the NAS. Renames of the move that never ran are
    /// dropped; the ones that ran are reversed by a new batch, applied now
    /// when the NAS is there and queued when it is not.
    ///
    /// `reversedMirrorKeys`, when given, are `NASSyncStore.pathKey`s of the
    /// NAS paths (each rename's `to`) whose drive move really went back. A
    /// rename whose drive move stayed where it is keeps its NAS copy where it
    /// is too — the NAS follows the drive — and its batch stays open.
    public func undo(
        moveJournalID: UUID,
        nasRoot: URL,
        reversedMirrorKeys: Set<String>? = nil,
        progress: Progress? = nil
    ) throws -> NASUndoResult {
        guard let queue else { return NASUndoResult() }
        var undone = NASUndoResult()
        for var batch in queue.batches(forMoveJournal: moveJournalID) where batch.undoneAt == nil {
            let wanted: (NASRename) -> Bool = { op in
                reversedMirrorKeys.map { $0.contains(NASSyncStore.pathKey(op.to)) } ?? true
            }
            var reversedOps: [NASRename] = []
            var leftOpen = false
            for index in batch.ops.indices {
                switch batch.ops[index].state {
                case .pending, .renamed, .merged:
                    guard wanted(batch.ops[index]) else { leftOpen = true; continue }
                    if batch.ops[index].state == .pending {
                        batch.ops[index].state = .cancelled
                        undone.cancelled += 1
                    }
                    reversedOps.append(batch.ops[index])
                default:
                    continue
                }
            }
            if !leftOpen { batch.undoneAt = now() }
            var selected = batch
            selected.ops = reversedOps
            let reverse = Self.inverse(of: selected, now: now())
            try queue.save(batch)
            guard var reverse else { continue }
            let result = try apply(&reverse, nasRoot: nasRoot, progress: progress)
            undone.follow.add(result)
            undone.queued += reverse.pendingCount
        }
        return undone
    }

    // MARK: Applying

    /// Applies every queued batch for `nasRoot`, oldest first. Returns
    /// right away with nothing done when the NAS folder is not there.
    public func applyPending(nasRoot: URL, progress: Progress? = nil) throws -> NASFollowResult {
        var total = NASFollowResult()
        guard let queue else { return total }
        let root = nasRoot.standardizedFileURL.path
        for var batch in queue.pending(nasRoot: root) {
            let result = try apply(&batch, nasRoot: nasRoot, progress: progress)
            total.add(result)
            if result.stoppedReason != nil { break }
        }
        return total
    }

    /// Applies one batch: every pending rename, in order. The batch is
    /// updated in place (state per rename) and saved to the queue as it
    /// goes.
    @discardableResult
    public func apply(_ batch: inout NASRenameBatch, nasRoot: URL, progress: Progress? = nil) throws -> NASFollowResult {
        var result = NASFollowResult()
        let root = nasRoot.standardizedFileURL.path
        // Written before anything else — even with the NAS away — so the
        // renames are queued on disk and a crash leaves the journal.
        try queue?.save(batch)
        guard LayoutMigrationDisk.lstatEntry(root)?.kind == .directory, VolumeInfo.isAvailable(nasRoot) else {
            result.notAttempted = batch.pendingCount
            result.stoppedReason = "The NAS is not connected; \(batch.pendingCount) rename\(batch.pendingCount == 1 ? "" : "s") stay queued."
            return result
        }
        guard batch.nasRoot == NASSyncStore.standardizedRoot(root) else {
            result.notAttempted = batch.pendingCount
            result.stoppedReason = "This batch is for another NAS folder (\(batch.nasRoot))."
            return result
        }
        result.batches = 1

        var run = Run(
            root: root,
            staleFolder: "\(Self.staleFolderPath)/\(Self.stamp(now()))-\(batch.id.uuidString.prefix(4))",
            records: RecordCache(store: store, root: root)
        )
        run.records.preload(batch.ops.flatMap { [NASSyncStore.pathKey($0.from), NASSyncStore.pathKey($0.to)] })
        var limiter = FileOperationProgressLimiter()
        var sinceCheckpoint = 0
        var settled = 0
        var index = 0

        func checkpoint() {
            flush(&run, into: &result, nasRoot: root)
            try? queue?.save(batch)
            sinceCheckpoint = 0
        }

        while index < batch.ops.count {
            defer { index += 1 }
            guard batch.ops[index].state == .pending else { continue }
            if isCancelled() {
                result.stoppedReason = "Stopped; the remaining renames stay queued."
                break
            }
            var op = batch.ops[index]
            if limiter.shouldEmit(force: false) {
                progress?(FileOperationProgress(
                    phase: "Renaming on the NAS",
                    currentPath: (op.to as NSString).lastPathComponent,
                    processedFiles: settled,
                    totalFiles: batch.ops.filter { $0.kind == .file }.count
                ))
            }
            func perform() {
                switch op.kind {
                case .file:
                    performFile(&op, run: &run, result: &result)
                case .folder:
                    performFolder(&op, run: &run, result: &result)
                }
            }
            perform()
            // One transient error on a rename (a dropped session, `EIO`, a
            // stale handle) must not strand the copy: the op is still
            // pending, so it is tried once more from a fresh call — with
            // its destination folder made again — before the run moves on.
            // Whatever is still pending stays queued for the next run.
            var triesThisRun = 1
            while op.state == .pending, triesThisRun < Self.attemptsPerRun, !isCancelled(), !nasIsGone(root) {
                triesThisRun += 1
                if retryDelay > 0 { Thread.sleep(forTimeInterval: retryDelay) }
                perform()
            }
            // A dropped share fails renames with odd errors: the op stays
            // queued and the run stops, rather than losing the rename.
            if op.state == .failed || op.state == .pending || (op.state == .absent && LayoutMigrationDisk.lstatEntry(root)?.kind != .directory),
               nasIsGone(root) {
                result.stoppedReason = "The NAS disconnected; the remaining renames stay queued."
                break
            }
            batch.ops[index] = op
            if !run.children.isEmpty {
                batch.ops.insert(contentsOf: run.children, at: index + 1)
                run.children = []
            }
            record(op, into: &result)
            settled += op.kind == .file ? 1 : 0
            sinceCheckpoint += 1
            if sinceCheckpoint >= 100 { checkpoint() }
        }
        result.notAttempted = batch.pendingCount
        flush(&run, into: &result, nasRoot: root)
        result.prunedFolders = prune(run.sourceFolders, nasRoot: root)
        if batch.pendingCount == 0, batch.completedAt == nil { batch.completedAt = now() }
        try? queue?.save(batch)
        progress?(FileOperationProgress(phase: "Renaming on the NAS", processedFiles: settled, totalFiles: settled))
        return result
    }

    // MARK: One rename

    /// Facts one run accumulates.
    private struct Run {
        var root: String
        var staleFolder: String
        var records: RecordCache
        var recordMoves: [NASSyncStore.RecordMove] = []
        var sourceFolders: Set<String> = []
        /// Per-file renames a folder rename split into.
        var children: [NASRename] = []

        init(root: String, staleFolder: String, records: RecordCache) {
            self.root = root
            self.staleFolder = staleFolder
            self.records = records
        }
    }

    /// The sync records this run needs, read from the catalog on demand.
    private final class RecordCache {
        private let store: NASSyncStore?
        private let root: String
        private var known: [String: NASSyncRecord] = [:]
        private var absent = Set<String>()

        init(store: NASSyncStore?, root: String) {
            self.store = store
            self.root = root
        }

        func preload(_ keys: [String]) {
            guard let found = try? store?.records(nasRoot: root, pathKeys: keys) else { return }
            known.merge(found) { _, new in new }
            absent.formUnion(Set(keys).subtracting(found.keys))
        }

        func record(_ key: String) -> NASSyncRecord? {
            if let cached = known[key] { return cached }
            if absent.contains(key) { return nil }
            preload([key])
            return known[key]
        }

        /// The record is on its way to another path.
        func forget(_ key: String) {
            known[key] = nil
            absent.insert(key)
        }
    }

    private func record(_ op: NASRename, into result: inout NASFollowResult) {
        switch (op.kind, op.state) {
        case (.file, .renamed):
            result.renamed += 1
            result.bytesRenamed += op.byteCount
            result.applied.append(op)
        case (.file, .merged):
            result.merged += 1
            result.applied.append(op)
        case (.folder, .renamed):
            result.foldersRenamed += 1
            result.applied.append(op)
        case (_, .absent): result.absent += 1
        case (_, .differs): result.differs.append(NASSyncIssue(path: op.to, reason: op.detail ?? "A different file is at the new path."))
        case (_, .unproven): result.unproven.append(NASSyncIssue(path: op.to, reason: op.detail ?? "Identity could not be proven."))
        case (_, .failed): result.failed.append(NASSyncIssue(path: op.from, reason: op.detail ?? "Could not rename."))
        case (_, .pending) where op.attempts != nil:
            result.deferred.append(NASSyncIssue(path: op.from, reason: op.detail ?? "The share refused the rename; it stays queued."))
        default: break
        }
    }

    /// A rename or folder creation the share refused. A session hiccup
    /// (`EIO`, `ESTALE`, a dropped connection…) leaves the copy exactly
    /// where it was, so the op stays `.pending` and is counted; only after
    /// `maxAttempts` — or for any other error — is it `.failed`.
    private func fail(_ op: inout NASRename, _ error: Error) {
        guard NASFileIO.isTransient(error) else {
            op.state = .failed
            op.detail = error.localizedDescription
            return
        }
        let attempts = (op.attempts ?? 0) + 1
        op.attempts = attempts
        if attempts >= Self.maxAttempts {
            op.state = .failed
            op.detail = error.localizedDescription + " Tried \(attempts) times."
        } else {
            op.state = .pending
            op.detail = error.localizedDescription + " (attempt \(attempts); it stays queued.)"
        }
    }

    /// `mkdir -p` and the exclusive rename, with the destination folder made
    /// again once if the share lost it between the two.
    private func renameCreatingFolders(from fromPath: String, to toPath: String) throws {
        let folder = (toPath as NSString).deletingLastPathComponent
        try NASFileIO.makeDirectories(folder)
        do {
            try NASFileIO.renameExclusive(from: fromPath, to: toPath)
        } catch where NASFileIO.code(of: error) == ENOENT && LayoutMigrationDisk.lstatEntry(fromPath) != nil {
            try NASFileIO.makeDirectories(folder)
            try NASFileIO.renameExclusive(from: fromPath, to: toPath)
        }
    }

    private static func isClean(_ relativePath: String) -> Bool {
        EventStorageLocations.isLexicallyClean(relativePath) && (try? PathSafety.validateRelativePath(relativePath)) != nil
    }

    private func performFile(_ op: inout NASRename, run: inout Run, result: inout NASFollowResult) {
        let fromKey = NASSyncStore.pathKey(op.from)
        let toKey = NASSyncStore.pathKey(op.to)
        guard Self.isClean(op.from), Self.isClean(op.to) else {
            op.state = .failed
            op.detail = "Not a safe path."
            return
        }
        guard fromKey != toKey else {
            op.state = .absent
            op.detail = "The name only changes in letter case; the NAS is case-insensitive."
            return
        }
        let fromPath = run.root + "/" + op.from
        let toPath = run.root + "/" + op.to
        guard let old = LayoutMigrationDisk.lstatEntry(fromPath) else {
            // Nothing at the old path: never synced — or an interrupted
            // run already renamed it and only its bookkeeping is missing.
            if let new = LayoutMigrationDisk.lstatEntry(toPath), new.kind == .file, op.byteCount == 0 || new.size == op.byteCount,
               run.records.record(fromKey) != nil || run.records.record(toKey) != nil {
                if run.records.record(fromKey) != nil {
                    run.recordMoves.append(.init(from: op.from, to: op.to, eventID: op.eventID))
                    run.records.forget(fromKey)
                }
                op.state = .renamed
                op.detail = "Already at the new path."
            } else {
                op.state = .absent
            }
            return
        }
        guard old.kind == .file else {
            op.state = .failed
            op.detail = "Something that is not a file is at the old NAS path."
            return
        }
        if op.byteCount > 0, old.size != op.byteCount {
            op.state = .differs
            op.detail = "The NAS copy at the old path is \(old.size) bytes and the moved file is \(op.byteCount): a different file. Left untouched."
            return
        }
        if let new = LayoutMigrationDisk.lstatEntry(toPath) {
            guard new.kind == .file, new.size == old.size else {
                op.state = .differs
                op.detail = new.kind == .file
                    ? "A different file (\(new.size) bytes, not \(old.size)) is already at the new path. Both left untouched."
                    : "Something that is not a file is at the new path. Both left untouched."
                return
            }
            switch identical(op, size: old.size, fromPath: fromPath, toPath: toPath, records: run.records) {
            case true?:
                setAside(&op, run: &run, fromPath: fromPath)
            case false?:
                op.state = .differs
                op.detail = "A different file of the same size is already at the new path. Both left untouched."
            case nil:
                op.state = .unproven
                op.detail = "A file of the same size is already at the new path and the two copies could not both be read to compare them. Both left untouched."
            }
            return
        }
        do {
            try renameCreatingFolders(from: fromPath, to: toPath)
        } catch {
            fail(&op, error)
            return
        }
        op.state = .renamed
        run.recordMoves.append(.init(from: op.from, to: op.to, eventID: op.eventID))
        run.records.forget(fromKey)
        run.sourceFolders.insert((fromPath as NSString).deletingLastPathComponent)
    }

    /// The stale copy goes to the NAS's stale folder; the identical file at
    /// the new path stays. Never deleted.
    private func setAside(_ op: inout NASRename, run: inout Run, fromPath: String) {
        let stale = run.staleFolder + "/" + op.from
        do {
            try renameCreatingFolders(from: fromPath, to: run.root + "/" + stale)
        } catch {
            fail(&op, error)
            return
        }
        op.state = .merged
        op.stalePath = stale
        op.detail = "The identical file was already at the new path; the old copy was set aside."
        run.recordMoves.append(.init(from: op.from, to: op.to, eventID: op.eventID, replaceExisting: false))
        run.records.forget(NASSyncStore.pathKey(op.from))
        run.sourceFolders.insert((fromPath as NSString).deletingLastPathComponent)
    }

    /// True/false when the two copies' identity is known; nil when one of
    /// them could not be read.
    ///
    /// Bytes decide, never records. The NAS has shown rare corruption: a
    /// copy that was verified once can hold other bytes now, and a merge
    /// that trusted two matching records would keep the damaged file at the
    /// owned path and set the good one aside. So both copies are hashed
    /// *now* — on the NAS itself when SSH is set up (only the answer
    /// crosses the wire), else by re-reading them over SMB. A record can
    /// only rule a pair out: two verified records with different hashes
    /// mean "different", which leaves both files where they are.
    private func identical(_ op: NASRename, size: Int64, fromPath: String, toPath: String, records: RecordCache) -> Bool? {
        if let old = records.record(NASSyncStore.pathKey(op.from)), let new = records.record(NASSyncStore.pathKey(op.to)),
           old.state == .verified, new.state == .verified, old.byteCount == size, new.byteCount == size,
           let oldHash = old.sha256, let newHash = new.sha256, oldHash != newHash {
            return false
        }
        // Hashed on the NAS itself: only the answer crosses the wire.
        if let remoteVerifier, let hashes = try? remoteVerifier.hashes(localPaths: [fromPath, toPath]),
           let oldHash = hashes[fromPath], let newHash = hashes[toPath] {
            return oldHash == newHash
        }
        // No SSH (or it could not answer): read both over SMB, uncached.
        guard !isCancelled(),
              let oldHash = try? NASFileIO.sha256(fromPath, uncached: true, expectedByteCount: size),
              !isCancelled(),
              let newHash = try? NASFileIO.sha256(toPath, uncached: true, expectedByteCount: size) else { return nil }
        return oldHash == newHash
    }

    // MARK: Folders

    private func performFolder(_ op: inout NASRename, run: inout Run, result: inout NASFollowResult) {
        guard Self.isClean(op.from), Self.isClean(op.to) else {
            op.state = .failed
            op.detail = "Not a safe path."
            return
        }
        let fromKey = NASSyncStore.pathKey(op.from)
        let toKey = NASSyncStore.pathKey(op.to)
        guard fromKey != toKey, !toKey.hasPrefix(fromKey + "/"), !fromKey.hasPrefix(toKey + "/") else {
            op.state = .failed
            op.detail = "A folder cannot be renamed into itself."
            return
        }
        let fromPath = run.root + "/" + op.from
        let toPath = run.root + "/" + op.to
        guard let old = LayoutMigrationDisk.lstatEntry(fromPath) else {
            // Renamed before an interruption, records not moved yet?
            if LayoutMigrationDisk.lstatEntry(toPath)?.kind == .directory,
               let under = try? store?.records(nasRoot: run.root, prefixes: [op.from]), !under.isEmpty {
                _ = try? store?.relocateFolder(nasRoot: run.root, from: op.from, to: op.to)
                op.state = .renamed
                op.detail = "Already at the new path."
            } else {
                op.state = .absent
            }
            return
        }
        guard old.kind == .directory else {
            op.state = .failed
            op.detail = "Something that is not a folder is at the old NAS path."
            return
        }
        guard let new = LayoutMigrationDisk.lstatEntry(toPath) else {
            do {
                try renameCreatingFolders(from: fromPath, to: toPath)
            } catch {
                fail(&op, error)
                return
            }
            do {
                try store?.relocateFolder(nasRoot: run.root, from: op.from, to: op.to)
            } catch {
                result.catalogProblem = "Could not move sync records in the catalog: \(error.localizedDescription)"
            }
            op.state = .renamed
            run.sourceFolders.insert((fromPath as NSString).deletingLastPathComponent)
            return
        }
        guard new.kind == .directory else {
            op.state = .differs
            op.detail = "A file is already at the new folder path. Left untouched."
            return
        }
        // The new folder exists (an earlier sync copied there): rename the
        // old folder's files one by one into it instead.
        var folders: [String] = []
        run.children = Self.walk(relative: op.from, target: op.to, root: run.root, folders: &folders)
        run.sourceFolders.formUnion(folders)
        op.state = .expanded
        op.detail = "The new folder already exists; \(run.children.count) file\(run.children.count == 1 ? "" : "s") renamed one by one."
    }

    private static func walk(relative: String, target: String, root: String, folders: inout [String]) -> [NASRename] {
        let path = root + "/" + relative
        folders.append(path)
        guard let entries = try? DirectoryListing.list(path) else { return [] }
        var renames: [NASRename] = []
        for entry in entries where !NASSyncPlanner.isJunk(entry.name) {
            switch entry.kind {
            case .file:
                renames.append(NASRename(from: relative + "/" + entry.name, to: target + "/" + entry.name, byteCount: entry.size))
            case .directory:
                renames += walk(relative: relative + "/" + entry.name, target: target + "/" + entry.name, root: root, folders: &folders)
            case .symlink, .other:
                continue
            }
        }
        return renames
    }

    // MARK: Bookkeeping

    /// Writes the sync records that follow the renames done so far.
    private func flush(_ run: inout Run, into result: inout NASFollowResult, nasRoot: String) {
        guard !run.recordMoves.isEmpty else { return }
        do {
            try store?.relocate(nasRoot: nasRoot, run.recordMoves)
        } catch {
            // The copies are proven where they are; a later sync re-derives
            // any record that did not land.
            result.catalogProblem = "Could not move sync records in the catalog: \(error.localizedDescription)"
        }
        run.recordMoves = []
    }

    /// Removes NAS folders the renames emptied, walking up but never onto
    /// the NAS root — the drive move's rule: only Finder metadata may be
    /// in a folder that goes. Returns how many folders are gone.
    private func prune(_ folders: Set<String>, nasRoot: String) -> Int {
        guard !folders.isEmpty else { return 0 }
        DriveMoveService().pruneEmptyFolders(folders, boundaries: [URL(fileURLWithPath: nasRoot, isDirectory: true)])
        return folders.filter { !DriveMoveService.exists($0) }.count
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
