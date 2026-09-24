import CameraToolkitCore
import Foundation

/// One event's files Apply could not move because the name is taken, as
/// the sheet and status line say it. Pure string work over the plan.
struct ApplyCollisionSummary: Identifiable, Equatable, Sendable {
    var id: UUID { eventID }
    var eventID: UUID
    var eventName: String
    /// Identical copies already in the event.
    var duplicateCount: Int
    var duplicateBytes: Int64
    var duplicateNames: [String]
    /// Different files whose name is taken (sidecars held with them are
    /// counted in `heldBackCount`, not here).
    var conflictCount: Int
    var conflictNames: [String]
    var heldBackCount: Int
    var allDuplicatesArePhotos: Bool

    /// "1 photo is already in Beach Day (identical copy)"
    var duplicateLine: String? {
        guard duplicateCount > 0 else { return nil }
        let noun = allDuplicatesArePhotos ? "photo" : "file"
        let verb = duplicateCount == 1 ? "is" : "are"
        let copy = duplicateCount == 1 ? "identical copy" : "identical copies"
        return "\(ApplyPlanOverview.plural(duplicateCount, noun)) \(verb) already in \(eventName) (\(copy))"
    }

    /// "1 file can't move: a different DSC0001.ARW is already in Beach Day"
    var conflictLine: String? {
        guard conflictCount > 0 else { return nil }
        let what = conflictCount == 1 && conflictNames.count == 1
            ? "a different \(conflictNames[0]) is"
            : "different files with the same names are"
        return "\(ApplyPlanOverview.plural(conflictCount, "file")) can’t move: \(what) already in \(eventName)"
    }

    /// Shown under the conflict line when sidecars wait with their file.
    var heldBackLine: String? {
        heldBackCount > 0
            ? "\(ApplyPlanOverview.plural(heldBackCount, "sidecar")) \(heldBackCount == 1 ? "waits" : "wait") with \(conflictCount == 1 ? "it" : "them"), so pairs stay together."
            : nil
    }

    /// Example of the Keep Both name, e.g. "DSC0001 (2).ARW".
    var keepBothExample: String? {
        conflictNames.first.map { KeepBothNaming.suffixed($0, 2) }
    }
}

enum ApplyStatusWording {
    static func summaries(for plan: OrganizeApplyPlan) -> [ApplyCollisionSummary] {
        plan.groups.compactMap { group in
            guard !group.duplicates.isEmpty || !group.conflicts.isEmpty else { return nil }
            let conflicts = group.conflicts.filter { $0.kind == .nameConflict }
            return ApplyCollisionSummary(
                eventID: group.event.id,
                eventName: group.event.name,
                duplicateCount: group.duplicates.count,
                duplicateBytes: group.duplicates.reduce(Int64(0)) { $0 + $1.move.byteCount },
                duplicateNames: group.duplicates.map(\.fileName).sorted(),
                conflictCount: conflicts.count,
                conflictNames: conflicts.map(\.fileName).sorted(),
                heldBackCount: group.conflicts.count - conflicts.count,
                allDuplicatesArePhotos: group.duplicates.allSatisfy { collision in
                    let kind = OrganizeFileClassifier.kind(forExtension: (collision.fileName as NSString).pathExtension)
                    return kind == .raw || kind == .photo
                }
            )
        }
    }

    /// Every blocked file in plain words, pointing at the fix — or nil when
    /// nothing was blocked. "1 photo is already in Beach Day (identical
    /// copy) — open Apply to resolve."
    static func collisionNote(for plan: OrganizeApplyPlan) -> String? {
        let lines = summaries(for: plan).flatMap { [$0.duplicateLine, $0.conflictLine].compactMap { $0 } }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: ". ") + " — open Apply to resolve."
    }

    /// The status line after an Apply job: what moved, then why anything
    /// stayed, in words that point at the action.
    static func afterApply(
        movedCount: Int,
        movedBytes: Int64,
        skipped: [DriveMoveIssue],
        plan: OrganizeApplyPlan
    ) -> String {
        var text = "Moved \(movedCount) file(s) (\(movedBytes.formattedBytes)) into their events."
        if let first = skipped.first {
            let taken = skipped.count { $0.reason.contains("already exists") }
            if taken == skipped.count {
                text += " \(skipped.count) left in place: a file with the same name is already in the event — open Apply to resolve."
            } else {
                text += " \(skipped.count) left in place: \(first.reason)"
            }
        }
        if let note = collisionNote(for: plan) {
            text += " " + note
        }
        return text
    }

    /// The unsorted board's bottom hint, or nil for the "how to sort" hint.
    /// `sortedFiles` excludes identical copies but includes conflicts.
    static func boardHint(sortedFiles: Int, sortedBytes: Int64, duplicates: Int, conflicts: Int) -> String? {
        guard duplicates > 0 || conflicts > 0 else {
            return sortedFiles > 0
                ? "\(sortedFiles) sorted file\(sortedFiles == 1 ? "" : "s") (\(sortedBytes.formattedBytes)) still here — nothing moves until you Apply"
                : nil
        }
        var parts: [String] = []
        let waiting = sortedFiles - conflicts
        if waiting > 0 {
            parts.append("\(waiting) sorted file\(waiting == 1 ? "" : "s") still here")
        }
        if duplicates > 0 {
            parts.append("\(duplicates) already in \(duplicates == 1 ? "its" : "their") event (identical copy)")
        }
        if conflicts > 0 {
            parts.append("\(conflicts) can’t move: the name is taken")
        }
        return parts.joined(separator: " · ") + " — open Apply to resolve"
    }
}
