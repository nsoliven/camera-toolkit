import Foundation

/// Moves that happened before the NAS followed them — or while it could not
/// — leave the NAS with a copy at the old path and none at the new one, so
/// Sync to NAS would copy the file again. This finds those copies by what
/// Sync to NAS itself recorded and renames them instead of copying; and it
/// finds the duplicates an earlier re-copy already left behind.
///
/// Both answers come from the catalog's verified records (path, size,
/// SHA-256) and the drive, with no listing of the NAS:
///
/// - **Catch-up.** A file to copy has no verified record at its path, but
///   a verified record at another path has its size and drive modification
///   time; no assignment and no drive file owns that other path any more;
///   and the drive file's own SHA-256 equals that record's. The NAS copy
///   is renamed to the new path.
/// - **Reconcile.** A verified record at a path nothing owns has the same
///   SHA-256 and size as a verified record at a path that is owned. The
///   stale copy is set aside on the NAS (`_Stale Copies`); the copy at the
///   right path stays.
///
/// Nothing owned is ever touched: a path counts as owned when an
/// assignment maps to it, a drive file sits at it, or this sync plans it.
public enum NASCatchUp {
    /// A file to copy and the NAS copies that may already be its own.
    public struct Candidate: Equatable, Sendable {
        public var item: NASSyncItem
        /// Verified records at unowned paths with the item's size and drive
        /// modification time — not yet proven to be its content.
        public var orphans: [NASSyncRecord]
    }

    /// An unowned copy and the owned copy that makes it redundant.
    public struct StaleDuplicate: Equatable, Sendable {
        public var stale: NASSyncRecord
        public var keeper: NASSyncRecord
    }

    public struct Analysis: Equatable, Sendable {
        public var candidates: [Candidate] = []
        public var staleDuplicates: [StaleDuplicate] = []

        public init() {}

        public var isEmpty: Bool { candidates.isEmpty && staleDuplicates.isEmpty }
        /// Bytes a catch-up would not have to copy (an upper bound until
        /// the files are hashed).
        public var savedBytes: Int64 { candidates.reduce(0) { $0 + $1.item.byteCount } }
    }

    /// Whether the Buffer or the private staging folder is there. Nothing
    /// can be proven stale without it (the drive is what says which NAS
    /// paths are owned), so the reconcile switch is off and greyed out
    /// while it is away.
    public static func driveIsMounted(_ locations: EventStorageLocations) -> Bool {
        [locations.bufferRoot, locations.privateStagingRoot].contains { DriveMoveService.exists($0.path) }
    }

    /// The mirror paths (`NASSyncStore.pathKey`) every assignment maps to.
    public static func ownedKeys(assignments: [PhotoEventAssignment], locations: EventStorageLocations) -> Set<String> {
        let events = Dictionary(locations.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var keys = Set<String>()
        for assignment in assignments {
            guard let event = events[assignment.eventID],
                  let relative = try? locations.layout(for: event, deviceID: assignment.deviceID).mirrorRelativePath(for: assignment.relativePath)
            else { continue }
            keys.insert(NASSyncStore.pathKey(relative))
        }
        return keys
    }

    /// From `plan` (what Sync to NAS would copy or check), the sync
    /// `records` of the NAS root, and the paths assignments own. Reads only
    /// the drive's directory entries (one `lstat` per unowned record).
    public static func analyze(
        plan: NASSyncPlan,
        records: [String: NASSyncRecord],
        ownedKeys: Set<String>,
        locations: EventStorageLocations
    ) -> Analysis {
        var analysis = Analysis()
        let planKeys = Set(plan.items.map { NASSyncStore.pathKey($0.relativePath) })
        func onDrive(_ relative: String) -> Bool {
            [locations.bufferRoot, locations.privateStagingRoot].contains { root in
                DriveMoveService.exists(root.path + "/" + relative)
            }
        }
        // Ownership is only provable with the drive present: with it away
        // (the usual case — the Buffer is temporary) nothing is an orphan.
        let driveMounted = driveIsMounted(locations)
        var orphans: [NASSyncRecord] = []
        var keepers: [String: NASSyncRecord] = [:]
        for record in records.values.sorted(by: { $0.pathKey < $1.pathKey }) {
            guard record.state == .verified, record.sha256 != nil, NASMoveFollower.isEventPath(record.relativePath) else { continue }
            if ownedKeys.contains(record.pathKey) || planKeys.contains(record.pathKey) || onDrive(record.relativePath) {
                if keepers[identity(record)] == nil { keepers[identity(record)] = record }
            } else if driveMounted, isOriginalsPath(record.relativePath) {
                // Only originals are owned through assignments. Edited
                // files, sidecar folders and anything else have no
                // assignment by design and are never leftovers.
                orphans.append(record)
            }
        }

        // Reconcile: an orphan whose content is already at an owned path.
        for orphan in orphans {
            if let keeper = keepers[identity(orphan)] {
                analysis.staleDuplicates.append(StaleDuplicate(stale: orphan, keeper: keeper))
            }
        }

        // Catch-up: a file to copy whose content is an orphan's.
        var bySizeAndTime: [String: [NASSyncRecord]] = [:]
        for orphan in orphans {
            guard let modified = orphan.sourceModifiedAt else { continue }
            bySizeAndTime[timeKey(orphan.byteCount, modified), default: []].append(orphan)
        }
        guard !bySizeAndTime.isEmpty else { return analysis }
        for item in plan.items {
            if let known = records[NASSyncStore.pathKey(item.relativePath)], known.state == .verified,
               known.byteCount == item.byteCount, known.sourceModifiedAt.map({ abs($0 - item.modifiedAt) < 0.001 }) == true {
                continue
            }
            var matches: [NASSyncRecord] = []
            let base = Int((item.modifiedAt * 1000).rounded())
            for neighbour in [base - 1, base, base + 1] {
                matches += (bySizeAndTime["\(item.byteCount)-\(neighbour)"] ?? []).filter {
                    $0.sourceModifiedAt.map { abs($0 - item.modifiedAt) < 0.001 } == true
                }
            }
            if !matches.isEmpty { analysis.candidates.append(Candidate(item: item, orphans: matches)) }
        }
        return analysis
    }

    /// The renames catch-up owes: each candidate's drive file is hashed
    /// (a local read at drive speed, cheaper than the copy it replaces)
    /// and paired with an orphan of the same SHA-256, each orphan once,
    /// where the new path is still free on the NAS.
    public static func renames(
        for candidates: [Candidate],
        nasRoot: URL,
        hasher: (String) throws -> String = { try FileScanner.sha256(URL(fileURLWithPath: $0)) },
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> [NASRename] {
        let root = nasRoot.standardizedFileURL.path
        var used = Set<String>()
        var renames: [NASRename] = []
        for candidate in candidates {
            if isCancelled() { break }
            let item = candidate.item
            guard !DriveMoveService.exists(root + "/" + item.relativePath),
                  candidate.orphans.contains(where: { !used.contains($0.pathKey) }),
                  let hash = try? hasher(item.sourcePath),
                  let orphan = candidate.orphans.first(where: { !used.contains($0.pathKey) && $0.sha256 == hash }) else { continue }
            used.insert(orphan.pathKey)
            renames.append(NASRename(
                from: orphan.relativePath,
                to: item.relativePath,
                byteCount: item.byteCount,
                eventID: item.eventID,
                previousEventID: orphan.eventID
            ))
        }
        return renames
    }

    /// The renames reconcile owes: the stale copy against the keeper's
    /// path. The follower's rule sets the stale copy aside because the
    /// identical file is there (two verified records, one hash).
    public static func renames(for duplicates: [StaleDuplicate]) -> [NASRename] {
        duplicates.map {
            NASRename(from: $0.stale.relativePath, to: $0.keeper.relativePath, byteCount: $0.stale.byteCount, eventID: $0.keeper.eventID)
        }
    }

    /// `<year>/<event>/[<subevent>/]Originals/<camera>/…` — the only files
    /// an assignment owns, so the only ones that can be left behind by a
    /// move. `Edited/` and other folders are never orphans.
    static func isOriginalsPath(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").dropLast().contains { $0 == EventStorageLocations.originalsFolderName }
    }

    private static func identity(_ record: NASSyncRecord) -> String {
        "\(record.byteCount)-\(record.sha256 ?? "")"
    }

    private static func timeKey(_ size: Int64, _ modified: Double) -> String {
        "\(size)-\(Int((modified * 1000).rounded()))"
    }
}

extension NASMoveFollower {
    /// Renames NAS copies to the paths a sync is about to copy them to.
    /// `plan` is the sync's plan; the batch is written down like any other.
    public func catchUp(
        plan: NASSyncPlan,
        ownedKeys: Set<String>,
        locations: EventStorageLocations,
        nasRoot: URL,
        assignments: [PhotoEventAssignment] = [],
        hasher: (String) throws -> String = { try FileScanner.sha256(URL(fileURLWithPath: $0)) },
        progress: Progress? = nil
    ) throws -> NASFollowResult {
        let root = nasRoot.standardizedFileURL.path
        let records = try storeRecords(nasRoot: root)
        let analysis = NASCatchUp.analyze(plan: plan, records: records, ownedKeys: ownedKeys, locations: locations)
        var renames = NASCatchUp.renames(for: analysis.candidates, nasRoot: nasRoot, hasher: hasher, isCancelled: cancellationCheck)
        // Photos only the NAS has, whose copy is not where the catalog
        // looks: found from the records and one listing per folder, and
        // renamed into place when exactly one NAS copy fits.
        if !assignments.isEmpty, !cancellationCheck() {
            let taken = Set(renames.map { NASSyncStore.pathKey($0.from) })
            let repairs = NASCatchUp.repairs(
                assignments: assignments, plan: plan, records: records, ownedKeys: ownedKeys,
                locations: locations, nasRoot: root, isCancelled: cancellationCheck
            ).repairs.filter { !taken.contains($0.orphan.pathKey) }
            renames += NASCatchUp.renames(for: repairs)
        }
        guard !renames.isEmpty else { return NASFollowResult() }
        var batch = NASRenameBatch(
            title: "Catch up NAS copies with moved files",
            origin: .catchUp,
            nasRoot: root,
            ops: renames
        )
        return try apply(&batch, nasRoot: nasRoot, progress: progress)
    }

    /// Sets aside NAS duplicates of files that are already at their right
    /// path. Run after a sync so the copies it just verified count.
    public func reconcile(
        plan: NASSyncPlan,
        ownedKeys: Set<String>,
        locations: EventStorageLocations,
        nasRoot: URL,
        progress: Progress? = nil
    ) throws -> NASFollowResult {
        let root = nasRoot.standardizedFileURL.path
        let records = try storeRecords(nasRoot: root)
        let analysis = NASCatchUp.analyze(plan: plan, records: records, ownedKeys: ownedKeys, locations: locations)
        guard !analysis.staleDuplicates.isEmpty else { return NASFollowResult() }
        var batch = NASRenameBatch(
            title: "Set aside stale NAS duplicates",
            origin: .reconcile,
            nasRoot: root,
            ops: NASCatchUp.renames(for: analysis.staleDuplicates)
        )
        return try apply(&batch, nasRoot: nasRoot, progress: progress)
    }
}

/// What a sync learned about earlier moves before it copies anything.
public struct NASSyncPreparation: Sendable {
    public var plan: NASSyncPlan
    public var follow: NASFollowResult
}

extension NASMoveFollower {
    /// The first half of a sync: queued renames are applied so a moved file
    /// is never copied a second time, the drive is planned, and — with
    /// `catchUp` — NAS copies of files moved before the NAS followed them
    /// are renamed to the paths the plan copies to.
    public func prepareSync(
        events: [SavedCameraEvent],
        locations: EventStorageLocations,
        nasRoot: URL,
        ownedKeys: Set<String>,
        catchUp: Bool,
        assignments: [PhotoEventAssignment] = [],
        progress: Progress? = nil
    ) throws -> NASSyncPreparation {
        var follow = try applyPending(nasRoot: nasRoot, progress: progress)
        let plan = NASSyncPlanner.plan(events: events, locations: locations)
        if catchUp, follow.stoppedReason == nil {
            follow.add(try self.catchUp(plan: plan, ownedKeys: ownedKeys, locations: locations, nasRoot: nasRoot, assignments: assignments, progress: progress))
        }
        return NASSyncPreparation(plan: plan, follow: follow)
    }
}
