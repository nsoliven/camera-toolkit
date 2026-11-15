import Foundation

/// One sorted file Apply sends straight from its source (a card, an unsorted
/// folder) to its event's folder on the NAS, because the event's drive is not
/// connected. `relativePath` is the NAS mirror path the file would have had
/// if it had gone to the drive first and then through Sync to NAS:
/// `<year>/<event…>/Originals/<Camera>/<subpath>`, rewritten by
/// `PortablePath` exactly as Sync does.
public struct NASDirectCopyFile: Codable, Hashable, Sendable {
    /// The source file, absolute. Only ever read.
    public var sourcePath: String
    /// Under the NAS root.
    public var relativePath: String
    public var byteCount: Int64
    public var eventID: UUID

    public init(sourcePath: String, relativePath: String, byteCount: Int64, eventID: UUID) {
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.eventID = eventID
    }
}

/// What a straight-to-NAS Apply did.
public struct NASDirectApplyOutcome: Sendable {
    /// The Sync to NAS engine's own report: copied, matched, conflicts left
    /// untouched, failures.
    public var report: NASSyncReport
    /// The items handed to the engine.
    public var plan: NASSyncPlan
    /// Queued NAS renames applied first (as Sync to NAS does).
    public var follow: NASFollowResult
    /// Files left out before the copy: gone, changed size, not a regular
    /// file, or a NAS path another file of the same run already takes.
    public var skipped: [NASSyncIssue]

    public var succeeded: Bool { report.succeeded && skipped.isEmpty }
}

/// Apply straight to the NAS: when an event's drive (the Buffer, or private
/// staging) is not connected but the NAS is, sorted files are copied from
/// their source into the event's NAS folder by the Sync to NAS engine
/// (`NASSyncService`) — the same exclusive temporary-then-rename copy, the
/// same SHA-256 verification (re-read over SMB, or hashed on the NAS over
/// SSH), the same conflict rule (an existing NAS file is never overwritten;
/// a different one is reported and left alone) and the same
/// `nas_sync_files` records. The layout and the records are exactly those a
/// Sync to NAS of the drive copy would have produced; a record's
/// `sourceModifiedAt` is the source file's modification time, which is also
/// the drive copy's when Apply copies to the drive.
///
/// The source is only read: nothing on the card or the unsorted folder is
/// moved, renamed, re-timed or deleted. Clear from Card frees it later.
public enum NASDirectApply {
    /// A NAS root that is mounted, is a folder, and is not a drive root.
    public static func isNASUsable(_ locations: EventStorageLocations) -> Bool {
        NASEventDiscovery.nasRootIsUsable(locations)
    }

    /// The NAS mirror path of an assignment in its event — where Sync to NAS
    /// puts the event's drive copy.
    public static func mirrorPath(for assignment: PhotoEventAssignment, event: SavedCameraEvent, locations: EventStorageLocations) -> String? {
        try? locations.layout(for: event, deviceID: assignment.deviceID).mirrorRelativePath(for: assignment.relativePath)
    }

    /// True when `record` is Sync to NAS's verified word about this very
    /// source file: verified and dated, with a SHA-256, the same byte count,
    /// and made when the source had its current modification time. A
    /// different file at the same NAS path, or a source replaced since, is
    /// not vouched for.
    public static func vouches(_ record: NASSyncRecord?, sourcePath: String, byteCount: Int64) -> Bool {
        guard let record, record.state == .verified, record.verifiedAt != nil,
              let sha = record.sha256, !sha.isEmpty, record.byteCount == byteCount,
              let recorded = record.sourceModifiedAt,
              let entry = LayoutMigrationDisk.lstatEntry(sourcePath), entry.kind == .file, entry.size == byteCount else { return false }
        return abs(recorded - entry.modifiedAt) < 0.001
    }

    /// One catalog read: the source path keys (`EventStorageLocations.pathKey`)
    /// of the candidates whose NAS copy a verified record vouches for.
    public static func vouchedSources(
        _ candidates: [(sourcePath: String, mirrorPath: String, byteCount: Int64)],
        records: [String: NASSyncRecord]
    ) -> Set<String> {
        var vouched: Set<String> = []
        for candidate in candidates
        where vouches(records[NASSyncStore.pathKey(candidate.mirrorPath)], sourcePath: candidate.sourcePath, byteCount: candidate.byteCount) {
            vouched.insert(EventStorageLocations.pathKey(candidate.sourcePath))
        }
        return vouched
    }

    /// The catalog's records for these mirror paths (keyed by
    /// `NASSyncStore.pathKey`). Empty when the catalog cannot be read.
    public static func records(catalogURL: URL?, nasRoot: String, mirrorPaths: [String]) -> [String: NASSyncRecord] {
        guard let catalogURL, !mirrorPaths.isEmpty else { return [:] }
        return NASSyncStore.records(catalogURL: catalogURL, nasRoot: nasRoot, pathKeys: Array(Set(mirrorPaths.map(NASSyncStore.pathKey))))
    }

    /// The engine's plan, from the files as they are on disk now: each
    /// source must be a regular file of its planned size, outside the NAS,
    /// and its current modification time is what the engine checks again
    /// after copying and records. A path is never planned twice.
    public static func plan(
        _ files: [NASDirectCopyFile],
        events: [SavedCameraEvent],
        locations: EventStorageLocations
    ) -> (plan: NASSyncPlan, skipped: [NASSyncIssue]) {
        let nasPrefix = locations.nasRoot.standardizedFileURL.path + "/"
        var items: [NASSyncItem] = []
        var skipped: [NASSyncIssue] = []
        var seen: Set<String> = []
        for file in files {
            guard EventStorageLocations.isLexicallyClean(file.relativePath),
                  (try? PathSafety.validateRelativePath(file.relativePath)) != nil else {
                skipped.append(NASSyncIssue(path: file.sourcePath, reason: "Its NAS path cannot be used safely."))
                continue
            }
            let source = URL(fileURLWithPath: file.sourcePath).standardizedFileURL.path
            guard !source.hasPrefix(nasPrefix) else {
                skipped.append(NASSyncIssue(path: file.sourcePath, reason: "It is already on the NAS."))
                continue
            }
            guard let entry = LayoutMigrationDisk.lstatEntry(source) else {
                skipped.append(NASSyncIssue(path: file.sourcePath, reason: "It is no longer at its source."))
                continue
            }
            guard entry.kind == .file else {
                skipped.append(NASSyncIssue(path: file.sourcePath, reason: "Not a regular file; never followed or copied."))
                continue
            }
            guard entry.size == file.byteCount else {
                skipped.append(NASSyncIssue(path: file.sourcePath, reason: "Its size changed since it was sorted (\(entry.size) bytes, sorted as \(file.byteCount))."))
                continue
            }
            guard seen.insert(NASSyncStore.pathKey(file.relativePath)).inserted else {
                skipped.append(NASSyncIssue(path: file.sourcePath, reason: "Another file of this Apply goes to the same NAS path (\(file.relativePath))."))
                continue
            }
            items.append(NASSyncItem(
                sourcePath: source,
                relativePath: file.relativePath,
                byteCount: entry.size,
                modifiedAt: entry.modifiedAt,
                eventID: file.eventID
            ))
        }
        items.sort { $0.relativePath < $1.relativePath }
        let wanted = Set(files.map(\.eventID))
        let folders = Set(events.filter { wanted.contains($0.id) }.map {
            PortablePath.sanitize(relativePath: locations.layout(for: $0, deviceID: nil).mirrorEventFolderPath)
        })
        return (NASSyncPlan(items: items, eventFolders: folders.sorted()), skipped)
    }

    /// Copies the files through the Sync to NAS engine. Like Sync to NAS,
    /// queued NAS renames are applied first; while any is still waiting
    /// nothing is copied (an event's NAS folder may be about to move).
    public static func run(
        _ files: [NASDirectCopyFile],
        events: [SavedCameraEvent],
        locations: EventStorageLocations,
        store: NASSyncStore?,
        options: NASSyncOptions,
        recorder: JobHistoryRecorder? = nil,
        renameQueue: NASRenameQueue? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        progress: NASSyncService.Progress? = nil
    ) throws -> NASDirectApplyOutcome {
        guard isNASUsable(locations) else {
            throw ToolkitError.commandFailed("The NAS is not connected. Nothing was copied; the originals stay where they are.")
        }
        let nasRoot = locations.nasRoot
        let follower = NASMoveFollower(store: store, remoteVerifier: options.remoteVerifier, queue: renameQueue, isCancelled: isCancelled)
        let follow = try follower.applyPending(nasRoot: nasRoot)
        let waiting = renameQueue?.pendingRenameCount(nasRoot: nasRoot.standardizedFileURL.path) ?? 0
        guard waiting == 0, follow.stoppedReason == nil else {
            throw ToolkitError.commandFailed(
                (follow.stoppedReason.map { $0 + " " } ?? "")
                    + "\(waiting) NAS rename\(waiting == 1 ? " is" : "s are") still waiting, so nothing was copied. Try again once Sync to NAS has run them; the originals stay where they are."
            )
        }
        let prepared = plan(files, events: events, locations: locations)
        let report = try NASSyncService(store: store, options: options, recorder: recorder, isCancelled: isCancelled)
            .sync(prepared.plan, nasRoot: nasRoot, progress: progress)
        return NASDirectApplyOutcome(report: report, plan: prepared.plan, follow: follow, skipped: prepared.skipped)
    }
}
