import Foundation

/// Which sorted files still at their source (a card, an unsorted folder) are
/// already in their event — the files an Apply plan counts as "already
/// there" and would not copy or move again.
///
/// The rule is the Apply plan's own (`buildApplyPlan`, `.present` drive
/// case): the event's drive copy — its Buffer or private staging folder, in
/// the current or legacy layout, as `EventPresenceScanner` resolves it — is a
/// regular file of the recorded size, the source is still there and is not
/// itself that copy, and the source sits on a different volume than the
/// event's drive root (a card: Apply copied and left the original). On the
/// same volume a same-size file is only a candidate until Apply's checksum
/// check proves it identical; those come from the plan
/// (`applyDuplicateSourceKeys`), not from here.
///
/// Read-only: it stats the source and drive paths and never touches the NAS
/// (the archive place is reported as unavailable instead of probed).
public enum AppliedSourceCheck {
    public typealias SameVolume = @Sendable (_ source: URL, _ driveRoot: URL, _ mounted: Set<String>) -> Bool

    /// Source path key (`EventStorageLocations.pathKey`) → the event whose
    /// drive folder already holds that file.
    public static func appliedSources(
        assignments: [PhotoEventAssignment],
        events: [UUID: SavedCameraEvent],
        locations: EventStorageLocations,
        mountedVolumes: Set<String>? = nil,
        pauseGate: DriveActivityGate? = nil,
        sameVolume: SameVolume? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [String: UUID] {
        appliedAssets(
            assignments: assignments,
            events: events,
            locations: locations,
            mountedVolumes: mountedVolumes,
            pauseGate: pauseGate,
            sameVolume: sameVolume,
            isCancelled: isCancelled
        ).mapValues(\.assignment.eventID)
    }

    /// The same answer with the presence each one was decided on — source
    /// path key → that file's `EventAssetPresence` (drive copy path and root,
    /// NAS mirror path). The NAS place in it was not probed.
    public static func appliedAssets(
        assignments: [PhotoEventAssignment],
        events: [UUID: SavedCameraEvent],
        locations: EventStorageLocations,
        mountedVolumes: Set<String>? = nil,
        pauseGate: DriveActivityGate? = nil,
        sameVolume: SameVolume? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [String: EventAssetPresence] {
        guard !assignments.isEmpty else { return [:] }
        let mounted = mountedVolumes ?? VolumeInfo.mountedVolumePaths()
        let sameVolume = sameVolume ?? { source, root, mounted in
            VolumeInfo.isSameVolume(source.deletingLastPathComponent(), root, mountedVolumes: mounted)
        }
        let skippedRoots = [locations.nasRoot, locations.libraryRoot]
            .map { $0.standardizedFileURL.path }
            .filter { $0.count > 1 }
            .map { $0 + "/" }
        // The NAS is never asked: only the source and the drive copies decide.
        let probe: EventPresenceScanner.PresenceProbe = { url, size, mounted in
            guard let url else { return .missing }
            let path = url.standardizedFileURL.path
            if skippedRoots.contains(where: { path.hasPrefix($0) }) { return .unavailable }
            return EventPresenceScanner.state(url, size: size, mounted: mounted)
        }

        var applied: [String: EventAssetPresence] = [:]
        for (eventID, rows) in Dictionary(grouping: assignments, by: \.eventID) {
            guard !isCancelled(), let event = events[eventID] else { continue }
            let driveRoot = locations.driveRoot(for: locations.resolvedPolicy(for: event))
            guard let summary = EventPresenceScanner.scan(
                event: event,
                assignments: rows,
                locations: locations,
                mountedVolumes: mounted,
                probe: probe,
                pauseGate: pauseGate
            ) else { continue }
            for asset in summary.assets {
                guard asset.drive == .present, asset.source == .present, !asset.sourceIsDriveCopy,
                      let source = asset.sourcePath, asset.drivePath != nil else { continue }
                let sourceURL = URL(fileURLWithPath: source)
                guard !sameVolume(sourceURL, driveRoot, mounted) else { continue }
                applied[EventStorageLocations.pathKey(source)] = asset
            }
        }
        return applied
    }
}
