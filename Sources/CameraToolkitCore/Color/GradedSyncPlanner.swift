import Foundation

/// Which graded copies to render before a Sync to NAS, when "Send graded
/// versions of log videos to Immich" is on. Works from the catalog — no
/// board needs to be open: every assigned clip of the synced events that is
/// on the drive, is log footage, and has a grade (its own, or its
/// profile's default) gets a request for `Edited/Rec709` on the drive, so
/// Sync carries the copy to the NAS at its final name.
public enum GradedSyncPlanner {
    public static let gradableExtensions: Set<String> = ["mp4", "mov", "m4v", "mxf"]

    public struct Inputs: Sendable {
        public var events: [SavedCameraEvent]
        public var assignments: [PhotoEventAssignment]
        public var locations: EventStorageLocations
        public var policy: @Sendable (SavedCameraEvent) -> EventStoragePolicy
        public var grades: [String: ClipGrade]
        public var defaults: GradeDefaults
        public var availableLUTs: Set<String>

        public init(
            events: [SavedCameraEvent],
            assignments: [PhotoEventAssignment],
            locations: EventStorageLocations,
            policy: @escaping @Sendable (SavedCameraEvent) -> EventStoragePolicy,
            grades: [String: ClipGrade],
            defaults: GradeDefaults,
            availableLUTs: Set<String>
        ) {
            self.events = events
            self.assignments = assignments
            self.locations = locations
            self.policy = policy
            self.grades = grades
            self.defaults = defaults
            self.availableLUTs = availableLUTs
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
            guard let profile = mark.resolve(detected: detected) else { continue }
            var grade: ClipGrade
            if let explicit, !(explicit.look == .none && explicit.hasNeutralControls) {
                grade = explicit
            } else if let look = inputs.defaults.look(for: profile) {
                grade = explicit ?? ClipGrade()
                grade.look = look
            } else {
                continue
            }
            let recipe = GradeRecipe(grade: grade, profile: profile, range: range(url))
            guard !recipe.grade.isIdentity else { continue }
            switch grade.look {
            case .rec709: guard profile.hasBuiltInConversion else { continue }
            case .lut(let id): guard inputs.availableLUTs.contains(id) else { continue }
            case .none: break
            }
            let edited = inputs.locations.editedRoot(for: event, policy: policy)
            requests.append(GradedRenderRequest(
                source: url,
                recipe: recipe,
                sourceKey: key,
                sourceModifiedAt: assignment.modifiedAt,
                outputFolder: GradedRenderNaming.outputFolder(editedRoot: edited)
            ))
        }
        return requests
    }
}
