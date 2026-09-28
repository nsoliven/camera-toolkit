import Foundation

/// Who holds a copy: an event (through its catalog assignment) or an
/// unsorted folder (a file nobody sorted yet).
public enum DuplicateOwner: Hashable, Comparable, Codable, Sendable {
    case event(UUID)
    case folder(UUID)

    public var eventID: UUID? {
        if case .event(let id) = self { return id }
        return nil
    }

    /// Stable text form — part of a reviewed group's key.
    public var key: String {
        switch self {
        case .event(let id): "event:\(id.uuidString)"
        case .folder(let id): "folder:\(id.uuidString)"
        }
    }

    public static func < (lhs: DuplicateOwner, rhs: DuplicateOwner) -> Bool { lhs.key < rhs.key }
}

/// One file the scan should consider, and who holds it.
public struct DuplicateCandidate: Hashable, Sendable {
    public var owner: DuplicateOwner
    /// Absolute path of the local copy.
    public var path: String
    /// The event assignment behind the copy; nil for unsorted files.
    public var assignment: PhotoEventAssignment?

    public init(owner: DuplicateOwner, path: String, assignment: PhotoEventAssignment? = nil) {
        self.owner = owner
        self.path = path
        self.assignment = assignment
    }
}

/// One copy in a scan result.
public struct DuplicateCopy: Identifiable, Hashable, Sendable {
    public var id: String { owner.key + "\n" + pathKey }
    public var owner: DuplicateOwner
    public var path: String
    public var pathKey: String
    public var byteCount: Int64
    public var modifiedAt: Date
    /// EXIF capture time, read for copies that end up in a result.
    public var captureDate: Date?
    public var assignment: PhotoEventAssignment?
    /// `device:inode` at scan time: two copies with the same identity are
    /// one file on disk reached twice, not two copies.
    public var fileIdentity: String

    public var fileName: String { (path as NSString).lastPathComponent }
    public var folderPath: String { (path as NSString).deletingLastPathComponent }
}

/// The same bytes held by more than one owner.
public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public var sha256: String
    public var byteCount: Int64
    public var copies: [DuplicateCopy]
    /// Distinct owners, sorted.
    public var owners: [DuplicateOwner]

    public init(sha256: String, byteCount: Int64, copies: [DuplicateCopy]) {
        self.sha256 = sha256
        self.byteCount = byteCount
        self.copies = copies.sorted { ($0.owner, $0.pathKey) < ($1.owner, $1.pathKey) }
        self.owners = Array(Set(copies.map(\.owner))).sorted()
    }

    /// Content plus the owners holding it: a Keep Both mark covers exactly
    /// this set, so the same photo turning up in another event is new.
    public var id: String { Self.key(sha256: sha256, owners: owners) }

    public static func key(sha256: String, owners: [DuplicateOwner]) -> String {
        ([sha256] + owners.sorted().map(\.key)).joined(separator: "|")
    }

    public func copies(of owner: DuplicateOwner) -> [DuplicateCopy] {
        copies.filter { $0.owner == owner }
    }

    /// Every copy is the same file on disk: one photo assigned to several
    /// events, with no spare bytes anywhere.
    public var isOneFile: Bool { Set(copies.map(\.fileIdentity)).count == 1 }

    /// The display name — the first copy's file name.
    public var fileName: String { copies.first?.fileName ?? "" }
}

/// Files with the same name held by different owners whose contents
/// differ — Sony reuses frame numbers, so these are different photos, not
/// duplicates. Informational only.
public struct DuplicateNameCollision: Identifiable, Hashable, Sendable {
    /// Lower-cased file name.
    public var id: String
    public var fileName: String
    public var copies: [DuplicateCopy]
    public var owners: [DuplicateOwner]
}

/// Two owners, in order.
public struct DuplicateOwnerPair: Hashable, Sendable {
    public var first: DuplicateOwner
    public var second: DuplicateOwner

    public init(_ a: DuplicateOwner, _ b: DuplicateOwner) {
        first = min(a, b)
        second = max(a, b)
    }

    public func contains(_ owner: DuplicateOwner) -> Bool { first == owner || second == owner }

    public func other(than owner: DuplicateOwner) -> DuplicateOwner { first == owner ? second : first }
}

/// Everything two owners hold in common.
public struct DuplicatePairSummary: Identifiable, Hashable, Sendable {
    public var id: DuplicateOwnerPair { pair }
    public var pair: DuplicateOwnerPair
    public var groups: [DuplicateGroup]
    /// Groups hidden because the owner already chose Keep Both.
    public var reviewedCount: Int

    public var fileCount: Int { groups.count }
    /// Bytes one side would give back: one copy per group.
    public var byteCount: Int64 { groups.reduce(Int64(0)) { $0 + $1.byteCount } }
}

public struct DuplicateCollisionPairSummary: Identifiable, Hashable, Sendable {
    public var id: DuplicateOwnerPair { pair }
    public var pair: DuplicateOwnerPair
    public var collisions: [DuplicateNameCollision]
}

public struct DuplicateUnreadable: Hashable, Sendable {
    public var path: String
    public var reason: String
}

public struct DuplicateScanReport: Sendable {
    public var groups: [DuplicateGroup] = []
    public var nameCollisions: [DuplicateNameCollision] = []
    /// Candidates the scan could not hash.
    public var unreadable: [DuplicateUnreadable] = []
    /// Candidates that exist on disk.
    public var scannedFiles = 0
    /// Files read this run, and files answered from the cache.
    public var hashedFiles = 0
    public var cachedFiles = 0
    public var cancelled = false
    public var scannedAt = Date()

    public init() {}

    /// One summary per owner pair that shares identical files, largest
    /// first. A group held by three owners appears under each of its pairs.
    /// `reviewed` groups (Keep Both) are counted but left out.
    public func pairs(reviewed: Set<String> = []) -> [DuplicatePairSummary] {
        var byPair: [DuplicateOwnerPair: (groups: [DuplicateGroup], reviewed: Int)] = [:]
        for group in groups {
            let isReviewed = reviewed.contains(group.id)
            for (index, first) in group.owners.enumerated() {
                for second in group.owners.dropFirst(index + 1) {
                    let pair = DuplicateOwnerPair(first, second)
                    var entry = byPair[pair] ?? ([], 0)
                    if isReviewed {
                        entry.reviewed += 1
                    } else {
                        entry.groups.append(group)
                    }
                    byPair[pair] = entry
                }
            }
        }
        return byPair
            .map { DuplicatePairSummary(pair: $0.key, groups: $0.value.groups, reviewedCount: $0.value.reviewed) }
            .sorted { ($0.fileCount, $1.pair.first.key) > ($1.fileCount, $0.pair.first.key) }
    }

    public func collisionPairs() -> [DuplicateCollisionPairSummary] {
        var byPair: [DuplicateOwnerPair: [DuplicateNameCollision]] = [:]
        for collision in nameCollisions {
            for (index, first) in collision.owners.enumerated() {
                for second in collision.owners.dropFirst(index + 1) {
                    byPair[DuplicateOwnerPair(first, second), default: []].append(collision)
                }
            }
        }
        return byPair
            .map { DuplicateCollisionPairSummary(pair: $0.key, collisions: $0.value) }
            .sorted { ($0.collisions.count, $1.pair.first.key) > ($1.collisions.count, $0.pair.first.key) }
    }

    /// Unreviewed groups `owner` shares with anyone else.
    public func groups(sharedBy owner: DuplicateOwner, reviewed: Set<String> = []) -> [DuplicateGroup] {
        groups.filter { $0.owners.contains(owner) && !reviewed.contains($0.id) }
    }
}

/// Finds files whose bytes are held by more than one owner.
///
/// Candidates are bucketed by byte size first, and only a size two owners
/// share is read at all; those files are hashed with a streamed SHA-256
/// (`FileScanner.sha256`, one bounded buffer), one at a time, with
/// progress. A hash is cached in `DuplicateReviewStore` by path, size and
/// modification time, so a re-run reads only files that changed. Nothing
/// here writes to a photo. Run it off the main actor.
public struct DuplicateScanner: Sendable {
    public typealias Hasher = @Sendable (URL, (Int) -> Void) throws -> String

    private let store: DuplicateReviewStore?
    private let hasher: Hasher
    private let readsCaptureDates: Bool

    public init(
        store: DuplicateReviewStore?,
        readsCaptureDates: Bool = true,
        hasher: @escaping Hasher = { url, progress in
            try withoutActuallyEscaping(progress) { try FileScanner.sha256(url, progress: $0) }
        }
    ) {
        self.store = store
        self.readsCaptureDates = readsCaptureDates
        self.hasher = hasher
    }

    public func scan(_ candidates: [DuplicateCandidate], progress: FileOperationProgressHandler? = nil) -> DuplicateScanReport {
        var report = DuplicateScanReport()

        // One copy per (owner, path); a file that is gone is not a candidate.
        var seen: Set<String> = []
        var copies: [DuplicateCopy] = []
        var stamps: [String: DuplicateFileStamp] = [:]
        for candidate in candidates {
            let key = EventStorageLocations.pathKey(candidate.path)
            guard seen.insert(candidate.owner.key + "\n" + key).inserted,
                  let facts = DuplicateFileFacts.read(candidate.path),
                  facts.byteCount > 0 else { continue }
            copies.append(DuplicateCopy(
                owner: candidate.owner,
                path: candidate.path,
                pathKey: key,
                byteCount: facts.byteCount,
                modifiedAt: facts.modifiedAt,
                captureDate: nil,
                assignment: candidate.assignment,
                fileIdentity: facts.identity
            ))
            stamps[key] = DuplicateFileStamp(pathKey: key, byteCount: facts.byteCount, modifiedNanoseconds: facts.modifiedNanoseconds)
        }
        report.scannedFiles = copies.count

        // Only a size held by two owners can be a cross-owner duplicate.
        let bySize = Dictionary(grouping: copies, by: \.byteCount)
        var toHash: [DuplicateCopy] = []
        var hashedIdentities: Set<String> = []
        for (_, sized) in bySize where Set(sized.map(\.owner)).count >= 2 {
            for copy in sized where hashedIdentities.insert(copy.fileIdentity).inserted {
                toHash.append(copy)
            }
        }
        toHash.sort { $0.path < $1.path }

        var hashByIdentity: [String: String] = [:]
        let cached = (try? store?.cachedHashes(for: toHash.compactMap { stamps[$0.pathKey] })) ?? [:]
        var pending: [DuplicateCopy] = []
        for copy in toHash {
            if let hash = cached[copy.pathKey] {
                hashByIdentity[copy.fileIdentity] = hash
                report.cachedFiles += 1
            } else {
                pending.append(copy)
            }
        }

        let totalBytes = pending.reduce(Int64(0)) { $0 + $1.byteCount }
        var processedBytes: Int64 = 0
        var limiter = FileOperationProgressLimiter()
        var fresh: [(stamp: DuplicateFileStamp, sha256: String)] = []
        let startedAt = Date()
        for (index, copy) in pending.enumerated() {
            if Task<Never, Never>.isCancelled {
                report.cancelled = true
                break
            }
            do {
                let hash = try hasher(URL(fileURLWithPath: copy.path)) { chunk in
                    processedBytes += Int64(chunk)
                    if limiter.shouldEmit() {
                        progress?(Self.progress(copy, index, pending.count, processedBytes, totalBytes, startedAt))
                    }
                }
                hashByIdentity[copy.fileIdentity] = hash
                report.hashedFiles += 1
                if let stamp = stamps[copy.pathKey] {
                    fresh.append((stamp, hash))
                }
            } catch {
                report.unreadable.append(DuplicateUnreadable(path: copy.path, reason: error.localizedDescription))
            }
            if fresh.count >= 200 {
                try? store?.storeHashes(fresh)
                fresh.removeAll()
            }
            if limiter.shouldEmit(force: index + 1 == pending.count) {
                progress?(Self.progress(copy, index + 1, pending.count, processedBytes, totalBytes, startedAt))
            }
        }
        try? store?.storeHashes(fresh)

        func content(_ copy: DuplicateCopy) -> String? {
            if let hash = hashByIdentity[copy.fileIdentity] { return hash }
            // A size no other owner has cannot match anything — it was
            // never read, and it differs from every other size.
            return Set((bySize[copy.byteCount] ?? []).map(\.owner)).count >= 2 ? nil : "size:\(copy.byteCount)"
        }

        var captureDates: [String: Date] = [:]
        func dated(_ copy: DuplicateCopy) -> DuplicateCopy {
            guard readsCaptureDates else { return copy }
            var copy = copy
            if let known = captureDates[copy.pathKey] {
                copy.captureDate = known
            } else if let date = CaptureDateReader.captureDate(of: URL(fileURLWithPath: copy.path)) {
                captureDates[copy.pathKey] = date
                copy.captureDate = date
            }
            return copy
        }

        var byHash: [String: [DuplicateCopy]] = [:]
        for copy in copies {
            if let hash = hashByIdentity[copy.fileIdentity] {
                byHash[hash, default: []].append(copy)
            }
        }
        report.groups = byHash.compactMap { hash, members in
            guard Set(members.map(\.owner)).count >= 2 else { return nil }
            return DuplicateGroup(sha256: hash, byteCount: members[0].byteCount, copies: members.map(dated))
        }
        .sorted { ($0.fileName.lowercased(), $0.sha256) < ($1.fileName.lowercased(), $1.sha256) }

        // Same name, different bytes, different owners.
        let byName = Dictionary(grouping: copies, by: { $0.fileName.lowercased() })
        for (name, members) in byName where Set(members.map(\.owner)).count >= 2 {
            let known = members.compactMap { copy in content(copy).map { (copy, $0) } }
            let differs = known.contains { first in
                known.contains { second in first.0.owner != second.0.owner && first.1 != second.1 }
            }
            guard differs else { continue }
            report.nameCollisions.append(DuplicateNameCollision(
                id: name,
                fileName: members[0].fileName,
                copies: members.map(dated).sorted { ($0.owner, $0.pathKey) < ($1.owner, $1.pathKey) },
                owners: Array(Set(members.map(\.owner))).sorted()
            ))
        }
        report.nameCollisions.sort { $0.id < $1.id }
        report.unreadable.sort { $0.path < $1.path }
        return report
    }

    private static func progress(
        _ copy: DuplicateCopy,
        _ processed: Int,
        _ total: Int,
        _ bytes: Int64,
        _ totalBytes: Int64,
        _ startedAt: Date
    ) -> FileOperationProgress {
        let elapsed = Date().timeIntervalSince(startedAt)
        return FileOperationProgress(
            phase: "Comparing",
            currentPath: copy.fileName,
            processedFiles: processed,
            totalFiles: total,
            processedBytes: bytes,
            totalBytes: totalBytes,
            bytesPerSecond: elapsed > 0 ? Double(bytes) / elapsed : 0
        )
    }
}

extension DuplicateScanner {
    /// One candidate per assignment: its first local copy that exists — the
    /// event's own drive folder, then the other drive root (a private
    /// event's copy still in the shared Buffer), then the legacy
    /// `Card Copy` layout, then the folder it was sorted from. The NAS is
    /// never read. Paths on unmounted volumes are skipped without a stat.
    public static func eventCandidates(
        events: [SavedCameraEvent],
        assignments: [PhotoEventAssignment],
        locations: EventStorageLocations,
        mountedVolumes: Set<String>? = nil
    ) -> [DuplicateCandidate] {
        let mounted = mountedVolumes ?? VolumeInfo.mountedVolumePaths()
        let byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Building a root spends a date formatter and an ancestor walk, so
        // each (event, device, policy, layout) root is built once.
        var roots: [String: URL] = [:]
        func root(_ event: SavedCameraEvent, _ deviceID: String?, _ policy: EventStoragePolicy, legacy: Bool) -> URL {
            let key = "\(event.id.uuidString)|\(deviceID ?? "")|\(policy.rawValue)|\(legacy)"
            if let cached = roots[key] { return cached }
            let built = legacy
                ? locations.legacyCardCopyRoot(for: event, deviceID: deviceID, policy: policy)
                : locations.originalsRoot(for: event, deviceID: deviceID, policy: policy)
            roots[key] = built
            return built
        }
        // A source that lives on the NAS library is its archive, not a
        // local copy — never read over the network.
        // A root that holds the drive folders themselves (or no root at
        // all) excludes nothing.
        let driveKeys = [locations.bufferRoot.path, locations.privateStagingRoot.path].map { $0.lowercased() + "/" }
        let nasPrefixes = [locations.nasRoot.path, locations.libraryRoot.path]
            .map { $0.lowercased() + "/" }
            .filter { prefix in prefix.count > 1 && !driveKeys.contains { $0.hasPrefix(prefix) } }
        func isOnNAS(_ path: String) -> Bool {
            let key = path.lowercased()
            return nasPrefixes.contains { key.hasPrefix($0) }
        }
        var policies: [UUID: EventStoragePolicy] = [:]
        var result: [DuplicateCandidate] = []
        for assignment in assignments {
            guard let event = byID[assignment.eventID],
                  (try? PathSafety.validateRelativePath(assignment.relativePath)) != nil else { continue }
            let policy = policies[event.id] ?? locations.resolvedPolicy(for: event)
            policies[event.id] = policy
            let other: EventStoragePolicy = policy == .buffer ? .archiveOnly : .buffer
            var places: [URL] = []
            for (placePolicy, legacy) in [(policy, false), (other, false), (policy, true), (other, true)] {
                places.append(root(event, assignment.deviceID, placePolicy, legacy: legacy)
                    .appendingPathComponent(assignment.relativePath))
            }
            if let source = locations.sourceURL(for: assignment) {
                places.append(source)
            }
            for place in places where VolumeInfo.isAvailable(place, mountedVolumes: mounted) && !isOnNAS(place.path) {
                if DriveMoveService.isRegularFile(place.path) {
                    result.append(DuplicateCandidate(owner: .event(event.id), path: place.path, assignment: assignment))
                    break
                }
            }
        }
        return result
    }

    /// Files of unsorted folders nobody sorted yet. A file an event already
    /// claims — as its local copy or as the source it was sorted from — is
    /// that event's, never a second copy of itself.
    public static func unsortedCandidates(
        folders: [(id: UUID, paths: [String])],
        excluding events: [DuplicateCandidate],
        assignments: [PhotoEventAssignment]
    ) -> [DuplicateCandidate] {
        var claimed = Set(events.map { EventStorageLocations.pathKey($0.path) })
        for assignment in assignments {
            let root = NSString(string: assignment.sourceRootPath).expandingTildeInPath
            claimed.insert(EventStorageLocations.pathKey((root as NSString).appendingPathComponent(assignment.relativePath)))
        }
        return folders.flatMap { folder in
            folder.paths
                .filter { !claimed.contains(EventStorageLocations.pathKey($0)) }
                .map { DuplicateCandidate(owner: .folder(folder.id), path: $0) }
        }
    }
}
