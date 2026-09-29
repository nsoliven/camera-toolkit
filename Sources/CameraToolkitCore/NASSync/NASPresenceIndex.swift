import Foundation

/// Where one drive file stands against the NAS mirror.
public enum NASFilePresence: Equatable, Hashable, Sendable {
    /// Sync to NAS verified it by hash at this size and drive modification
    /// time, and (when a listing covers it) it is still there at that size.
    case verified(Date?)
    /// A file of the same size is at the NAS path, not verified by a sync
    /// yet — Sync to NAS hashes both and records it. `timeMatches` when the
    /// modification times agree within `NASPresenceIndex.mtimeTolerance`.
    case onNAS(timeMatches: Bool)
    /// A listing covered the folder and found nothing at the path.
    case missing
    /// A different file (another size, or a recorded hash conflict) is at
    /// the NAS path. Never overwritten — the owner decides.
    case differs(nasSize: Int64?)
    /// No listing covers it and no sync verified it: as far as anything
    /// local knows, it is not on the NAS yet.
    case unknown

    /// What Sync to NAS still has to copy.
    public var isPending: Bool {
        switch self {
        case .missing, .unknown: true
        case .verified, .onNAS, .differs: false
        }
    }
}

/// Counts for one event (or the whole library) against the NAS.
public struct NASPresenceTotals: Equatable, Hashable, Sendable {
    public var files = 0
    public var bytes: Int64 = 0
    /// Not on the NAS yet (`missing` or `unknown`): what Sync to NAS copies.
    public var pendingFiles = 0
    public var pendingBytes: Int64 = 0
    /// A different file at the NAS path — reported, never overwritten.
    public var differentFiles = 0
    public var verifiedFiles = 0
    /// Same size on the NAS, not verified yet.
    public var unverifiedFiles = 0
    /// Pending only because nothing listed their folder yet.
    public var unknownFiles = 0

    public init() {}

    public var onNASFiles: Int { verifiedFiles + unverifiedFiles }
    public var isSynced: Bool { pendingFiles == 0 && differentFiles == 0 }

    public mutating func add(_ item: NASSyncItem, _ state: NASFilePresence) {
        files += 1
        bytes += item.byteCount
        switch state {
        case .verified: verifiedFiles += 1
        case .onNAS: unverifiedFiles += 1
        case .differs: differentFiles += 1
        case .missing, .unknown:
            pendingFiles += 1
            pendingBytes += item.byteCount
            if state == .unknown { unknownFiles += 1 }
        }
    }

    public mutating func add(_ other: NASPresenceTotals) {
        files += other.files
        bytes += other.bytes
        pendingFiles += other.pendingFiles
        pendingBytes += other.pendingBytes
        differentFiles += other.differentFiles
        verifiedFiles += other.verifiedFiles
        unverifiedFiles += other.unverifiedFiles
        unknownFiles += other.unknownFiles
    }
}

/// The answer to "which event files are not on the NAS yet, or differ",
/// per event, as of `listedAt`.
public struct NASPresenceReport: Equatable, Sendable {
    /// Per event id, for that event's own folder (subevents are their own
    /// rows; sum a subtree with `totals(for:)`).
    public var byEvent: [UUID: NASPresenceTotals]
    public var total: NASPresenceTotals
    /// The pending files themselves, in plan order, for the confirmation.
    public var pending: [NASSyncItem]
    /// The oldest folder listing the report used; nil when it rests on
    /// Sync to NAS's records alone.
    public var listedAt: Date?
    public var method: NASTreeListing.Method?
    /// Drive files the planner left out because they are already on the
    /// NAS in the legacy archive layout.
    public var inLegacyLayout: Int
    /// Drive folders the planner could not list: their files are in no count.
    public var unreadableFolders: Int
    public var checkedAt: Date

    public init(
        byEvent: [UUID: NASPresenceTotals] = [:],
        total: NASPresenceTotals = NASPresenceTotals(),
        pending: [NASSyncItem] = [],
        listedAt: Date? = nil,
        method: NASTreeListing.Method? = nil,
        inLegacyLayout: Int = 0,
        unreadableFolders: Int = 0,
        checkedAt: Date = Date()
    ) {
        self.byEvent = byEvent
        self.total = total
        self.pending = pending
        self.listedAt = listedAt
        self.method = method
        self.inLegacyLayout = inLegacyLayout
        self.unreadableFolders = unreadableFolders
        self.checkedAt = checkedAt
    }

    /// The summed totals of `eventIDs` (an event and its subevents).
    public func totals(for eventIDs: some Sequence<UUID>) -> NASPresenceTotals {
        var sum = NASPresenceTotals()
        for id in eventIDs {
            if let totals = byEvent[id] { sum.add(totals) }
        }
        return sum
    }
}

/// Which event files are on the NAS, with as little network as possible:
///
/// 1. Sync to NAS's own records (catalog, zero network): a drive file whose
///    path, size, and modification time match a verified record is on the
///    NAS as of that verification.
/// 2. One listing of the NAS mirror (`NASTreeListing`: an SSH `find`, or
///    bulk SMB folder reads) — never a stat per file, never a read.
/// 3. The comparison: present at the same size is on the NAS; absent is
///    not on the NAS yet; another size is a conflict, which Sync to NAS
///    reports and never overwrites.
///
/// A listing, when it covers a path, wins over a record: a file removed
/// from the NAS after it was verified is missing again.
public enum NASPresenceIndex {
    /// SMB reports times in 100 ns units and a server may round to whole
    /// seconds; two seconds also absorbs FAT-style 2 s precision.
    public static let mtimeTolerance: Double = 2

    public static func state(for item: NASSyncItem, record: NASSyncRecord?, listing: NASTreeListing?) -> NASFilePresence {
        let recordMatches = record.map { record in
            record.byteCount == item.byteCount
                && record.sourceModifiedAt.map({ abs($0 - item.modifiedAt) < 0.001 }) == true
        } ?? false
        if let listing, listing.covers(item.relativePath) {
            guard let entry = listing.entry(item.relativePath) else { return .missing }
            guard entry.size == item.byteCount else { return .differs(nasSize: entry.size) }
            if recordMatches, let record {
                switch record.state {
                case .verified: return .verified(record.verifiedAt)
                // The same NAS file a sync already found different by hash.
                case .conflict where record.nasSHA256 != nil: return .differs(nasSize: entry.size)
                case .conflict, .failed: break
                }
            }
            return .onNAS(timeMatches: abs(entry.modifiedAt - item.modifiedAt) <= mtimeTolerance)
        }
        if recordMatches, let record {
            switch record.state {
            case .verified: return .verified(record.verifiedAt)
            case .conflict: return .differs(nasSize: nil)
            case .failed: break
            }
        }
        return .unknown
    }

    /// Classifies every item of `plan`. `records` is `NASSyncStore.records`
    /// for the NAS root (keyed by `pathKey`).
    public static func report(
        plan: NASSyncPlan,
        records: [String: NASSyncRecord],
        listing: NASTreeListing?,
        checkedAt: Date = Date()
    ) -> NASPresenceReport {
        var report = NASPresenceReport(
            listedAt: listing?.oldestListing,
            method: listing?.method,
            inLegacyLayout: plan.inLegacyLayout.count,
            unreadableFolders: plan.unreadable.count,
            checkedAt: checkedAt
        )
        var usedListing = false
        for item in plan.items {
            let state = state(for: item, record: records[NASSyncStore.pathKey(item.relativePath)], listing: listing)
            if listing?.covers(item.relativePath) == true { usedListing = true }
            report.total.add(item, state)
            if let eventID = item.eventID { report.byEvent[eventID, default: NASPresenceTotals()].add(item, state) }
            if state.isPending { report.pending.append(item) }
        }
        if !usedListing {
            report.listedAt = nil
            report.method = nil
        }
        return report
    }

    /// The NAS mirror folders to list for `events`: each top-level event's
    /// folder once (a subevent's folder nests inside its parent's).
    public static func folders(for events: [SavedCameraEvent], locations: EventStorageLocations) -> [String] {
        let ids = Set(events.map(\.id))
        var folders = Set<String>()
        for event in events {
            // The highest ancestor in the set covers this event.
            let top = locations.ancestors(of: event).first { ids.contains($0.id) } ?? event
            folders.insert(PortablePath.sanitize(relativePath: locations.layout(for: top, deviceID: nil).mirrorEventFolderPath))
        }
        return folders.sorted()
    }

    /// Lists `folders` of the NAS mirror: over SSH when `remote` is given,
    /// falling back to bulk SMB listings when SSH fails (the reason comes
    /// back so the app can say why it was slower).
    public static func list(
        nasRoot: URL,
        folders: [String],
        remote: NASRemoteLister?,
        smbConcurrency: Int = 2,
        now: Date = Date(),
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        progress: (@Sendable (Int) -> Void)? = nil
    ) throws -> (listing: NASTreeListing, sshFallbackReason: String?) {
        var fallbackReason: String?
        if let remote {
            do {
                return (try remote.list(root: nasRoot, folders: folders, now: now, isCancelled: isCancelled, progress: progress), nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                fallbackReason = error.localizedDescription
            }
        }
        let listing = try NASSMBLister.list(
            root: nasRoot,
            folders: folders,
            concurrency: smbConcurrency,
            now: now,
            isCancelled: isCancelled,
            progress: progress
        )
        return (listing, fallbackReason)
    }
}
