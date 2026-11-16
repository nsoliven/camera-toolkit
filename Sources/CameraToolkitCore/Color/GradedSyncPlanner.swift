import Foundation

/// Which graded copies to render before a Sync to NAS, when "Send graded
/// versions of log videos to Immich" is on. Works from the catalog — no
/// board needs to be open: every assigned clip of the synced events that is
/// on the drive and is log footage the app converts (with its look, if it
/// has one) gets a request for `Edited/Rec709` on the drive, so
/// Sync carries the copy to the NAS at its final name.
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

    /// `detect` reads a clip's profile from its sidecar (file access);
    /// `range` its signal range. Run off the main actor.
    public static func requests(
        _ inputs: Inputs,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        detect: (URL) -> LogProfile?,
        range: (URL) -> VideoSignalRange
    ) -> [GradedRenderRequest] {
        let events = Dictionary(inputs.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var requests: [GradedRenderRequest] = []
        var seen: Set<String> = []
        for assignment in inputs.assignments {
            guard let event = events[assignment.eventID] else { continue }
            let name = (assignment.relativePath as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            guard gradableExtensions.contains(ext) else { continue }
            let policy = inputs.policy(event)
            guard let url = inputs.locations.driveURL(for: assignment, event: event, policy: policy),
                  !GradedRenderNaming.isGradedCopy(url) else { continue }
            let key = FaceIndexStore.fileKey(fileName: name, byteCount: assignment.fileSize, modifiedAt: assignment.modifiedAt)
            guard seen.insert(key).inserted else { continue }
            let explicit = inputs.grades[key]
            let mark = explicit?.profileMark ?? .detected
            guard mark != .notLog, fileExists(url) else { continue }
            let detected: LogProfile? = if case .marked = mark { nil } else { detect(url) }
            // Log footage only: a converted (and maybe looked) copy is what
            // Immich should show.
            guard mark.resolve(detected: detected) != nil,
                  let recipe = inputs.resolver.recipe(explicit: explicit, detected: detected, range: range(url)),
                  recipe.conversion.converts else { continue }
            let edited = inputs.locations.editedRoot(for: event, policy: policy)
            let output = GradedRenderNaming.outputFolder(editedRoot: edited)
            requests.append(GradedRenderRequest(
                source: url,
                recipe: recipe,
                sourceKey: key,
                sourceModifiedAt: assignment.modifiedAt,
                outputFolder: output,
                mirrorFolder: inputs.locations.nasMirrorURL(forDrivePath: output.path)
            ))
        }
        return requests
    }
}
