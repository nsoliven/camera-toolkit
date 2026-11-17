import Foundation

/// Which graded copies to render before a Sync to NAS, when "Send graded
/// versions of log videos to Immich" is on, and before Send to Immich.
/// Works from the catalog — no board needs to be open: every assigned clip
/// of the chosen events that is log footage the app converts (with its
/// look, if it has one) gets a request. A clip on the drive gets one for
/// `Edited/Rec709` on the drive, so Sync carries the copy to the NAS at its
/// final name; with `readsNAS`, a clip only on the NAS is read there and
/// its copy is written into the NAS event's `Edited/Rec709`.
public enum GradedSyncPlanner {
    public static let gradableExtensions: Set<String> = ["mp4", "mov", "m4v", "mxf"]

    public struct Inputs: Sendable {
        public var events: [SavedCameraEvent]
        public var assignments: [PhotoEventAssignment]
        public var locations: EventStorageLocations
        public var policy: @Sendable (SavedCameraEvent) -> EventStoragePolicy
        public var grades: [String: ClipGrade]
        public var resolver: GradeResolver

        public init(
            events: [SavedCameraEvent],
            assignments: [PhotoEventAssignment],
            locations: EventStorageLocations,
            policy: @escaping @Sendable (SavedCameraEvent) -> EventStoragePolicy,
            grades: [String: ClipGrade],
            resolver: GradeResolver
        ) {
            self.events = events
            self.assignments = assignments
            self.locations = locations
            self.policy = policy
            self.grades = grades
            self.resolver = resolver
        }
    }

    /// Where a planned copy is written.
    public enum Placement: String, Sendable, Equatable {
        /// The clip is on the drive: the copy goes into the drive's
        /// `Edited/Rec709` and Sync to NAS carries it.
        case drive
        /// The clip is only on the NAS (applied straight there, or the
        /// drive is away): it is read from the NAS and the copy is written
        /// into the NAS event's `Edited/Rec709` at its final name.
        case nas
    }

    /// One planned copy with what the rest of a send needs to know about it.
    public struct PlacedRequest: Sendable {
        public var request: GradedRenderRequest
        public var placement: Placement
        public var eventID: UUID
        /// The catalog row of the original (`CatalogStore.eventAssetID`).
        public var eventAssetID: String
        /// The original's path under the NAS root, as Immich sees it.
        public var originalRelativePath: String?

        public init(request: GradedRenderRequest, placement: Placement, eventID: UUID, eventAssetID: String, originalRelativePath: String?) {
            self.request = request
            self.placement = placement
            self.eventID = eventID
            self.eventAssetID = eventAssetID
            self.originalRelativePath = originalRelativePath
        }

        /// The copy's path under the NAS root once it is there: the NAS
        /// path itself (a NAS render, or a drive render Sync already
        /// carried), or the drive path's NAS mirror (where Sync puts it).
        public func gradedRelativePath(forCopyAt url: URL, locations: EventStorageLocations) -> String? {
            locations.nasRelativePath(url.path) ?? locations.mirrorRelativePath(forDrivePath: url.path)
        }
    }

    /// `detect` reads a clip's profile from its sidecar (file access);
    /// `range` its signal range. Run off the main actor.
    public static func requests(
        _ inputs: Inputs,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        detect: (URL) -> LogProfile?,
        range: (URL) -> VideoSignalRange
    ) -> [GradedRenderRequest] {
        placedRequests(inputs, readsNAS: false, fileExists: fileExists, detect: detect, range: range).map(\.request)
    }

    /// The planner's requests, each with where it is read and written.
    /// With `readsNAS`, a clip that is not on the drive but is in its NAS
    /// event folder is read there and its copy goes into the NAS event's
    /// `Edited/Rec709`; a clip on the drive keeps the drive plan. A clip on
    /// neither is left out.
    public static func placedRequests(
        _ inputs: Inputs,
        readsNAS: Bool,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        detect: (URL) -> LogProfile?,
        range: (URL) -> VideoSignalRange
    ) -> [PlacedRequest] {
        let events = Dictionary(inputs.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var placed: [PlacedRequest] = []
        var seen: Set<String> = []
        for assignment in inputs.assignments {
            guard let event = events[assignment.eventID] else { continue }
            let name = (assignment.relativePath as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            guard gradableExtensions.contains(ext) else { continue }
            let policy = inputs.policy(event)
            guard let driveURL = inputs.locations.driveURL(for: assignment, event: event, policy: policy),
                  !GradedRenderNaming.isGradedCopy(driveURL) else { continue }
            let key = FaceIndexStore.fileKey(fileName: name, byteCount: assignment.fileSize, modifiedAt: assignment.modifiedAt)
            guard seen.insert(key).inserted else { continue }
            let explicit = inputs.grades[key]
            let mark = explicit?.profileMark ?? .detected
            guard mark != .notLog else { continue }
            let url: URL
            let placement: Placement
            if fileExists(driveURL) {
                url = driveURL
                placement = .drive
            } else if readsNAS, let nasURL = inputs.locations.archiveURL(for: assignment, event: event), fileExists(nasURL) {
                url = nasURL
                placement = .nas
            } else {
                continue
            }
            let detected: LogProfile? = if case .marked = mark { nil } else { detect(url) }
            // Log footage only: a converted (and maybe looked) copy is what
            // Immich should show.
            guard mark.resolve(detected: detected) != nil,
                  let recipe = inputs.resolver.recipe(explicit: explicit, detected: detected, range: range(url)),
                  recipe.conversion.converts else { continue }
            let request: GradedRenderRequest
            switch placement {
            case .drive:
                let output = GradedRenderNaming.outputFolder(editedRoot: inputs.locations.editedRoot(for: event, policy: policy))
                request = GradedRenderRequest(
                    source: url,
                    recipe: recipe,
                    sourceKey: key,
                    sourceModifiedAt: assignment.modifiedAt,
                    outputFolder: output,
                    mirrorFolder: inputs.locations.nasMirrorURL(forDrivePath: output.path)
                )
            case .nas:
                // Written on the NAS at its final name: there is no other
                // copy of the folder to check.
                request = GradedRenderRequest(
                    source: url,
                    recipe: recipe,
                    sourceKey: key,
                    sourceModifiedAt: assignment.modifiedAt,
                    outputFolder: GradedRenderNaming.outputFolder(editedRoot: inputs.locations.nasEditedRoot(for: event))
                )
            }
            placed.append(PlacedRequest(
                request: request,
                placement: placement,
                eventID: event.id,
                eventAssetID: CatalogStore.eventAssetID(assignment),
                originalRelativePath: inputs.locations.archiveRelativePath(for: assignment, event: event)
            ))
        }
        return placed
    }
}
