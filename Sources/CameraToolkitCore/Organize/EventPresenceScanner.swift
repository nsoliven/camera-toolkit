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

    public var total: Int { assets.count }
    public var totalBytes: Int64 { assets.reduce(Int64(0)) { $0 + $1.assignment.fileSize } }
    public var onSource: Int { assets.count { $0.isOnSeparateSource } }
    public var sourceOffline: Int { assets.count { !$0.sourceIsDriveCopy && $0.source == .unavailable } }
    public var onDrive: Int { assets.count { $0.drive == .present } }
    public var onOtherDrive: Int { assets.count { $0.otherDrive == .present } }
    public var onArchive: Int { assets.count { $0.archive == .present } }
    public var archiveOffline: Bool { assets.contains { $0.archive == .unavailable } }
    public var driveOffline: Bool { assets.contains { $0.drive == .unavailable } }
    public var missingEverywhere: Int { assets.count { $0.bestLocalPath == nil } }
}

public enum EventPresenceScanner {
    public static func scan(
        event: SavedCameraEvent,
        assignments: [PhotoEventAssignment],
        locations: EventStorageLocations,
        mountedVolumes: Set<String>? = nil
    ) -> EventPresenceSummary {
        let mounted = mountedVolumes ?? VolumeInfo.mountedVolumePaths()
        let policy = locations.resolvedPolicy(for: event)
        let otherPolicy: EventStoragePolicy = policy == .buffer ? .archiveOnly : .buffer

        let assets = assignments.map { assignment -> EventAssetPresence in
            let source = locations.sourceURL(for: assignment)
            let drive = locations.driveURL(for: assignment, event: event, policy: policy)
            let other = locations.driveURL(for: assignment, event: event, policy: otherPolicy)
            let archive = locations.archiveURL(for: assignment, event: event)
            let sourceIsDrive = [drive, other].contains { candidate in
                guard let candidate, let source else { return false }
                return EventStorageLocations.pathKey(candidate.path) == EventStorageLocations.pathKey(source.path)
            }
            return EventAssetPresence(
                id: CatalogStore.eventAssetID(assignment),
                assignment: assignment,
                sourcePath: source?.path,
                drivePath: drive?.path,
                otherDrivePath: other?.path,
                archivePath: archive?.path,
                source: state(source, size: assignment.fileSize, mounted: mounted),
                drive: state(drive, size: assignment.fileSize, mounted: mounted),
                otherDrive: state(other, size: assignment.fileSize, mounted: mounted),
                archive: state(archive, size: assignment.fileSize, mounted: mounted),
                sourceIsDriveCopy: sourceIsDrive
            )
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
