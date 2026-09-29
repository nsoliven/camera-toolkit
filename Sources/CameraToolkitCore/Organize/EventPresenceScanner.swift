import Foundation

public struct EventAssetPresence: Identifiable, Hashable, Sendable {
    public var id: String
    public var assignment: PhotoEventAssignment
    public var sourcePath: String?
    /// The copy on the drive root the event's policy points at.
    public var drivePath: String?
    /// The copy on the other drive root, such as a Buffer copy of a private event.
    public var otherDrivePath: String?
    public var archivePath: String?
    public var source: CatalogPresenceState
    public var drive: CatalogPresenceState
    public var otherDrive: CatalogPresenceState
    public var archive: CatalogPresenceState
    /// True when the assignment was adopted from a folder already on the drive.
    public var sourceIsDriveCopy: Bool
    /// True when `drivePath` / `otherDrivePath` is the legacy
    /// `<device>/Card Copy` copy: the drive has not been migrated to
    /// `Originals/<Camera>` yet and the file was found only there.
    public var driveIsLegacyLayout: Bool = false
    public var otherDriveIsLegacyLayout: Bool = false
    /// True when `archivePath` is the legacy archive copy
    /// (`Originals/<year>/<event>/<device>/RAW|JPEG|…`): the event was
    /// archived before the mirror layout and not migrated yet.
    public var archiveIsLegacyLayout: Bool = false
    /// When Sync to NAS last proved the mirror copy byte-identical by
    /// re-reading it from the NAS. Nil when no sync verified it — a legacy
    /// copy, or a file that only happens to have the right size.
    public var archiveVerifiedAt: Date?

    /// A NAS copy Take Off Drive may rely on: one Sync to NAS verified by
    /// re-reading it. A legacy-layout copy is not — migrate the event, then
    /// Sync to NAS verifies it in place. Take Off Drive re-hashes it anyway.
    public var archiveIsTrusted: Bool {
        archive == .present && archiveVerifiedAt != nil && !archiveIsLegacyLayout
    }

    /// The folder `drivePath` sits in minus the assignment's relative path —
    /// the root to pair with `assignment.relativePath` when the copy is
    /// read or moved. Nil when the path does not end in the relative path.
    public var driveRootPath: String? { Self.root(of: drivePath, relativePath: assignment.relativePath) }
    public var otherDriveRootPath: String? { Self.root(of: otherDrivePath, relativePath: assignment.relativePath) }

    static func root(of path: String?, relativePath: String) -> String? {
        guard let path, path.hasSuffix("/" + relativePath) else { return nil }
        return String(path.dropLast(relativePath.count + 1))
    }

    public var bestLocalPath: String? {
        if drive == .present { return drivePath }
        if otherDrive == .present { return otherDrivePath }
        if source == .present { return sourcePath }
        if archive == .present { return archivePath }
        return nil
    }

    public var isOnSeparateSource: Bool { !sourceIsDriveCopy && source == .present }
}

public struct EventPresenceSummary: Sendable {
    public var eventID: UUID
    public var policy: EventStoragePolicy
    public var assets: [EventAssetPresence]
    public var checkedAt: Date

    public init(eventID: UUID, policy: EventStoragePolicy, assets: [EventAssetPresence], checkedAt: Date) {
        self.eventID = eventID
        self.policy = policy
        self.assets = assets
        self.checkedAt = checkedAt
    }

    public var total: Int { assets.count }
    public var totalBytes: Int64 { assets.reduce(Int64(0)) { $0 + $1.assignment.fileSize } }
    public var onSource: Int { assets.count { $0.isOnSeparateSource } }
    public var sourceOffline: Int { assets.count { !$0.sourceIsDriveCopy && $0.source == .unavailable } }
    public var onDrive: Int { assets.count { $0.drive == .present } }
    public var onOtherDrive: Int { assets.count { $0.otherDrive == .present } }
    public var onArchive: Int { assets.count { $0.archive == .present } }
    public var archiveOffline: Bool { assets.contains { $0.archive == .unavailable } }
    public var driveOffline: Bool { assets.contains { $0.drive == .unavailable } }
    /// Files found only in the legacy `Card Copy` layout.
    public var onLegacyLayout: Int { assets.count { ($0.drive == .present && $0.driveIsLegacyLayout) || ($0.otherDrive == .present && $0.otherDriveIsLegacyLayout) } }
    public var missingEverywhere: Int { assets.count { $0.bestLocalPath == nil } }
    /// NAS copies found only in the legacy archive layout.
    public var onLegacyArchiveLayout: Int { assets.count { $0.archive == .present && $0.archiveIsLegacyLayout } }
    /// NAS mirror copies Sync to NAS verified by re-reading them.
    public var verifiedOnArchive: Int { assets.count { $0.archive == .present && $0.archiveVerifiedAt != nil } }
    /// The oldest verification among them — "verified <date>" is only as
    /// fresh as the least recently checked file.
    public var oldestArchiveVerification: Date? { assets.compactMap { $0.archive == .present ? $0.archiveVerifiedAt : nil }.min() }
}

public enum EventPresenceScanner {
    /// One file-stat probe: mounted-volume check, then a regular-file and
    /// size read. Injectable so the sweep can be observed — or stalled the
    /// way a NAS share stalls — without a real filesystem.
    public typealias PresenceProbe = @Sendable (URL?, Int64, Set<String>) -> CatalogPresenceState

    /// The truthful four-place answer for one event. Probes each file's
    /// source, policy drive, other drive, and NAS archive path in
    /// assignment order — sequential, never fanned out, so a slow share is
    /// poked once at a time rather than stampeded. Returns nil when the
    /// surrounding task is cancelled mid-sweep so a stale pass can be
    /// dropped instead of published. When `pauseGate` is set the sweep waits
    /// at it before touching a volume that a speed test is measuring.
    ///
    /// `archiveListing`, when it covers a file's NAS mirror folder, answers
    /// the NAS place from memory instead of a stat over SMB — the same
    /// listing the NAS presence index counts from, so the board and the
    /// sidebar agree. A file it does not cover is probed as before.
    public static func scan(
        event: SavedCameraEvent,
        assignments: [PhotoEventAssignment],
        locations: EventStorageLocations,
        mountedVolumes: Set<String>? = nil,
        probe: PresenceProbe? = nil,
        pauseGate: DriveActivityGate? = nil,
        nasVerified: [String: Date]? = nil,
        nasFacts: [String: NASSyncStore.VerifiedFact]? = nil,
        archiveListing: NASTreeListing? = nil
    ) -> EventPresenceSummary? {
        let mounted = mountedVolumes ?? VolumeInfo.mountedVolumePaths()
        let policy = locations.resolvedPolicy(for: event)
        let otherPolicy: EventStoragePolicy = policy == .buffer ? .archiveOnly : .buffer
        let probe = probe ?? { url, size, mounted in state(url, size: size, mounted: mounted) }

        // Every candidate path is (a root that depends only on the event,
        // the assignment's device, and the policy) joined with the file's
        // relative path. The sweep used to rebuild each root per file —
        // and each rebuild minted several DateFormatters — so they are
        // memoized here and per-file work is a string join plus the same
        // validation and standardization the public helpers apply.
        var driveRoots: [String: URL] = [:]
        var legacyRoots: [String: URL] = [:]
        var layouts: [String: OrganizedArchiveLayout] = [:]
        var validRelative: [String: Bool] = [:]
        // With a listing, the legacy archive is only probed per file when
        // the event has a legacy folder at all — one stat per event.
        var legacyArchiveEventExists: Bool?
        func hasLegacyArchiveFolder() -> Bool {
            if let known = legacyArchiveEventExists { return known }
            let exists = LayoutMigrationDisk.lstatEntry(locations.legacyArchiveEventFolder(for: event).path)?.kind == .directory
            legacyArchiveEventExists = exists
            return exists
        }

        func originalsRoot(_ policy: EventStoragePolicy, _ deviceID: String?) -> URL {
            let key = "\(policy.rawValue)\u{0}\(deviceID ?? "")"
            if let cached = driveRoots[key] { return cached }
            let root = locations.originalsRoot(for: event, deviceID: deviceID, policy: policy)
            driveRoots[key] = root
            return root
        }
        func legacyRoot(_ policy: EventStoragePolicy, _ deviceID: String?) -> URL {
            let key = "\(policy.rawValue)\u{0}\(deviceID ?? "")"
            if let cached = legacyRoots[key] { return cached }
            let root = locations.legacyCardCopyRoot(for: event, deviceID: deviceID, policy: policy)
            legacyRoots[key] = root
            return root
        }
        func layout(_ deviceID: String?) -> OrganizedArchiveLayout {
            let key = deviceID ?? ""
            if let cached = layouts[key] { return cached }
            let built = locations.layout(for: event, deviceID: deviceID)
            layouts[key] = built
            return built
        }
        // Mirrors `driveURL`/`archiveURL`/`sourceURL`: validate once per
        // relative path, then append + standardize exactly as they do.
        func isValidRelative(_ path: String) -> Bool {
            if let cached = validRelative[path] { return cached }
            let valid = (try? PathSafety.validateRelativePath(path)) != nil
            validRelative[path] = valid
            return valid
        }

        var assets: [EventAssetPresence] = []
        assets.reserveCapacity(assignments.count)
        for assignment in assignments {
            if Task<Never, Never>.isCancelled { return nil }
            var mirrorKey: String?
            var mirrorRelative: String?
            let (source, drive, other, archive, legacyDrive, legacyOther, legacyArchive) = autoreleasepool {
                () -> (URL?, URL?, URL?, URL?, URL?, URL?, URL?) in
                let valid = isValidRelative(assignment.relativePath)
                let source = locations.sourceURL(for: assignment)
                func join(_ root: URL) -> URL? {
                    valid ? root.appendingPathComponent(assignment.relativePath).standardizedFileURL : nil
                }
                let archiveLayout = layout(assignment.deviceID)
                let archive = try? archiveLayout.mirrorRelativePath(for: assignment.relativePath)
                let legacyArchive = try? archiveLayout.legacyArchiveRelativePath(for: assignment.relativePath)
                mirrorKey = archive.map(NASSyncStore.pathKey)
                mirrorRelative = archive
                return (
                    source,
                    join(originalsRoot(policy, assignment.deviceID)),
                    join(originalsRoot(otherPolicy, assignment.deviceID)),
                    archive.map { locations.nasRoot.appendingPathComponent($0).standardizedFileURL },
                    join(legacyRoot(policy, assignment.deviceID)),
                    join(legacyRoot(otherPolicy, assignment.deviceID)),
                    legacyArchive.map { locations.libraryRoot.appendingPathComponent($0).standardizedFileURL }
                )
            }
            if let pauseGate {
                for url in [source, drive, other, archive].compactMap({ $0 }) {
                    guard pauseGate.waitIfPaused(
                        for: url,
                        shouldStop: { Task<Never, Never>.isCancelled }
                    ) else { return nil }
                }
            }
            // Every candidate is already a `standardizedFileURL` path, so
            // `pathKey` on them reduces to a lowercase compare — no extra
            // standardize (or stat) per file.
            let sourceKey = source?.path.lowercased()
            let sourceIsDrive = sourceKey != nil && [drive, other, legacyDrive, legacyOther].contains {
                $0?.path.lowercased() == sourceKey
            }
            // The current layout first. A copy missing there is looked for
            // in the legacy `Card Copy` folder, so a drive that has not been
            // migrated yet still shows its files; an offline drive is not
            // probed twice.
            func resolve(_ current: URL?, _ legacy: URL?) -> (URL?, CatalogPresenceState, Bool) {
                let state = probe(current, assignment.fileSize, mounted)
                guard state == .missing, let legacy else { return (current, state, false) }
                let legacyState = probe(legacy, assignment.fileSize, mounted)
                return legacyState == .present ? (legacy, .present, true) : (current, state, false)
            }
            // Probe order stays source, drive, other drive, archive.
            let sourceState = probe(source, assignment.fileSize, mounted)
            let driveResolved = resolve(drive, legacyDrive)
            let otherResolved = resolve(other, legacyOther)
            // The NAS: the mirror layout first, then the legacy archive
            // layout an event archived before the mirror still sits in.
            func resolveArchive() -> (URL?, CatalogPresenceState, Bool) {
                guard let archiveListing, let archive, let mirrorRelative,
                      archiveListing.root == locations.nasRoot.path,
                      archiveListing.covers(mirrorRelative),
                      VolumeInfo.isAvailable(archive, mountedVolumes: mounted) else {
                    return resolve(archive, legacyArchive)
                }
                if let entry = archiveListing.entry(mirrorRelative), entry.size == assignment.fileSize {
                    return (archive, .present, false)
                }
                guard let legacyArchive, hasLegacyArchiveFolder() else { return (archive, .missing, false) }
                let legacyState = probe(legacyArchive, assignment.fileSize, mounted)
                return legacyState == .present ? (legacyArchive, .present, true) : (archive, .missing, false)
            }
            let archiveResolved = resolveArchive()
            // "Verified" is a record's word about a file, so it only counts
            // for the file in front of us: the record must be about a copy of
            // this size, and — when a drive copy is here — about that drive
            // copy's modification time. A different file that happens to sit
            // at the same path, or a drive file replaced since, must not
            // inherit a verification (Take Off Drive relies on it).
            var verifiedAt: Date?
            if archiveResolved.1 == .present, !archiveResolved.2, let mirrorKey {
                if let nasFacts {
                    if let fact = nasFacts[mirrorKey], fact.byteCount == assignment.fileSize {
                        let driveCopy = [driveResolved, otherResolved].first { $0.1 == .present && !$0.2 }?.0
                        if let driveCopy {
                            let modified = (try? driveCopy.resourceValues(forKeys: [.contentModificationDateKey]))?
                                .contentModificationDate?.timeIntervalSinceReferenceDate
                            if let recorded = fact.sourceModifiedAt, let modified, abs(recorded - modified) < 0.001 {
                                verifiedAt = fact.verifiedAt
                            }
                        } else {
                            verifiedAt = fact.verifiedAt
                        }
                    }
                } else {
                    verifiedAt = nasVerified?[mirrorKey]
                }
            }
            assets.append(EventAssetPresence(
                id: CatalogStore.eventAssetID(assignment),
                assignment: assignment,
                sourcePath: source?.path,
                drivePath: driveResolved.0?.path,
                otherDrivePath: otherResolved.0?.path,
                archivePath: archiveResolved.0?.path,
                source: sourceState,
                drive: driveResolved.1,
                otherDrive: otherResolved.1,
                archive: archiveResolved.1,
                sourceIsDriveCopy: sourceIsDrive,
                driveIsLegacyLayout: driveResolved.2,
                otherDriveIsLegacyLayout: otherResolved.2,
                archiveIsLegacyLayout: archiveResolved.2,
                archiveVerifiedAt: verifiedAt
            ))
        }
        return EventPresenceSummary(eventID: event.id, policy: policy, assets: assets, checkedAt: Date())
    }

    /// Present only when a regular file of the recorded size exists.
    public static func state(_ url: URL?, size: Int64, mounted: Set<String>) -> CatalogPresenceState {
        guard let url else { return .missing }
        guard VolumeInfo.isAvailable(url, mountedVolumes: mounted) else { return .unavailable }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return .missing }
        return Int64(values.fileSize ?? -1) == size ? .present : .missing
    }
}
