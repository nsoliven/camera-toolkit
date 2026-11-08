import CameraToolkitCore
import Foundation

/// The order thumbnails are made in: the open event, its family, then every
/// other event newest first. Pure work on a catalog snapshot — nothing here
/// touches a file.
enum ThumbnailWarmPlan {
    struct Input: Sendable {
        var configuration: AppConfiguration
        var selectedEventID: UUID?
        var orientations: [String: Int]
        /// The decode bucket a board's tiles ask for.
        var bucket: Int
    }

    /// The open event, then its subevents, then the rest of its family, then
    /// every other event newest first. "Most recent, then the rest" is that
    /// one date order.
    static func eventOrder(events: [SavedCameraEvent], selectedEventID: UUID?) -> [SavedCameraEvent] {
        var ordered: [SavedCameraEvent] = []
        var seen: Set<UUID> = []
        func add(_ event: SavedCameraEvent) {
            if seen.insert(event.id).inserted { ordered.append(event) }
        }
        if let selected = events.first(where: { $0.id == selectedEventID }) {
            add(selected)
            EventHierarchy.descendants(of: selected.id, in: events).sorted(by: EventHierarchy.datePrecedes).forEach(add)
            let root = EventHierarchy.ancestors(of: selected, in: events).last ?? selected
            add(root)
            EventHierarchy.descendants(of: root.id, in: events).sorted(by: EventHierarchy.datePrecedes).forEach(add)
        }
        events.sorted(by: EventHierarchy.datePrecedes).forEach(add)
        return ordered
    }

    /// One item per tile the library draws. A RAW+JPEG pair is one tile, so
    /// the pairing rules pick the same file a board shows, and the key is the
    /// one that tile will look up. Sources are the Buffer copy, then the NAS.
    static func items(for input: Input) -> [ThumbnailWarmer.Item] {
        guard input.bucket <= ThumbnailDiskCache.largestBucket else { return [] }
        let events = input.configuration.savedEvents
        guard let fallback = events.first else { return [] }
        let locations = EventStorageLocations(configuration: input.configuration)
        let implied = ImpliedPaths(
            locations: locations,
            members: EventHierarchy.index(events),
            fallbackOwner: fallback,
            custom: nil
        )
        let byEvent = Dictionary(grouping: input.configuration.photoEventAssignments, by: \.eventID)

        var items: [ThumbnailWarmer.Item] = []
        items.reserveCapacity(input.configuration.photoEventAssignments.count)
        for event in eventOrder(events: events, selectedEventID: input.selectedEventID) {
            guard !Task.isCancelled else { return [] }
            guard let assignments = byEvent[event.id] else { continue }
            var sources: [String: [String]] = [:]
            var files: [OrganizeFile] = []
            files.reserveCapacity(assignments.count)
            for assignment in assignments {
                let paths = [true, false].compactMap { implied.path(for: assignment, driveUp: $0) }
                guard let first = paths.first else { continue }
                sources[first] = paths
                files.append(OrganizeFile(literalPath: first, size: assignment.fileSize, modifiedAt: assignment.modifiedAt))
            }
            for pairing in OrganizeFileClassifier.pair(files) where pairing.kind != .other {
                guard let paths = sources[pairing.primary.path] else { continue }
                let orientation = DisplayRotation.savedTurns(for: pairing.primary, in: input.orientations)
                items.append(ThumbnailWarmer.Item(
                    key: ThumbnailDiskCache.key(
                        fileIdentity: ThumbnailDiskCache.fileIdentity(pairing.primary),
                        bucket: input.bucket,
                        orientation: orientation
                    ),
                    sources: paths,
                    bucket: input.bucket,
                    orientation: orientation
                ))
            }
        }
        return items
    }
}
