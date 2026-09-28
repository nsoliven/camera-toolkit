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
        var text = "Moved \(ApplyPlanOverview.plural(movedCount, "file")) (\(movedBytes.formattedBytes)) into their events."
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

// MARK: - Decisions (what the owner chooses per taken name)

/// What happens to one file whose name is already taken in its event.
enum ApplyCollisionChoice: String, CaseIterable, Hashable, Sendable {
    /// Move it in under a free "(N)" name, next to the other file.
    case keepBoth
    /// Leave it where it is; the rest of the plan still applies.
    case leave
    /// Identical copies only: the spare goes to the recoverable Trash,
    /// through the organizer Trash confirmation.
    case trash

    var title: String {
        switch self {
        case .keepBoth: "Keep Both"
        case .leave: "Leave Here"
        case .trash: "Trash Duplicate"
        }
    }
}

/// One taken name as the sheet shows it: the file here, the file already
/// in the event, and the sidecars that travel with it.
struct ApplyCollisionItem: Identifiable, Sendable {
    var id: String { collision.move.sourcePath }
    /// `.identicalCopy` or `.nameConflict` — never a companion.
    var collision: ApplyCollision
    /// `.travelsWithConflict` sidecars that share the file's base name.
    var companions: [ApplyCollision]
    var eventID: UUID
    var eventName: String

    var fileName: String { collision.fileName }
    var isIdentical: Bool { collision.kind == .identicalCopy }
    var isPhoto: Bool {
        let kind = OrganizeFileClassifier.kind(forExtension: (fileName as NSString).pathExtension)
        return kind == .raw || kind == .photo
    }

    var sourcePath: String { collision.move.sourcePath }
    var existingPath: String { collision.move.destinationPath }
    /// Files this item moves with Keep Both: the file and its sidecars.
    var fileCount: Int { 1 + companions.count }

    /// The choices the row offers, recommended first.
    var choices: [ApplyCollisionChoice] { isIdentical ? [.trash, .leave] : [.keepBoth, .leave] }
    var recommendedChoice: ApplyCollisionChoice { choices[0] }
}

/// The files each choice acts on, ready for the workspace.
struct ApplyCollisionDecisions: Sendable {
    /// Name conflicts plus their companions, for the journaled Keep Both.
    var keepBoth: [ApplyCollision] = []
    /// Identical copies bound for the Trash confirmation.
    var trash: [ApplyCollision] = []
    /// Name conflicts (not companions) kept both — the count the button says.
    var keepBothConflictCount = 0

    var isEmpty: Bool { keepBoth.isEmpty && trash.isEmpty }
}

/// Pure decision logic for the Apply sheet's taken-name box: which rows to
/// show, the recommended choice per row, what each choice acts on, and the
/// words that say it. No disk access.
enum ApplyCollisionResolution {
    /// One item per identical copy and per name conflict, in plan order;
    /// held-back sidecars attach to the conflict that shares their base name.
    static func items(for plan: OrganizeApplyPlan) -> [ApplyCollisionItem] {
        plan.groups.flatMap { group -> [ApplyCollisionItem] in
            let companions = Dictionary(
                grouping: group.conflicts.filter { $0.kind == .travelsWithConflict },
                by: { ApplyCollisionCheck.groupKey($0.move.sourcePath) }
            )
            let primaries = group.conflicts.filter { $0.kind == .nameConflict } + group.duplicates
            return primaries
                .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
                .map { collision in
                    ApplyCollisionItem(
                        collision: collision,
                        companions: collision.kind == .nameConflict
                            ? companions[ApplyCollisionCheck.groupKey(collision.move.sourcePath)] ?? []
                            : [],
                        eventID: group.event.id,
                        eventName: group.event.name
                    )
                }
        }
    }

    /// Every row starts on its recommended choice.
    static func defaultChoices(for items: [ApplyCollisionItem]) -> [String: ApplyCollisionChoice] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.recommendedChoice) })
    }

    /// A row's choice, falling back to the recommendation, and never one
    /// the row does not offer (Trash is only for identical copies).
    static func choice(for item: ApplyCollisionItem, in choices: [String: ApplyCollisionChoice]) -> ApplyCollisionChoice {
        guard let chosen = choices[item.id], item.choices.contains(chosen) else { return item.recommendedChoice }
        return chosen
    }

    /// "Keep Both for all different photos": every name conflict switches
    /// to Keep Both; identical copies keep their own choice.
    static func keepBothForAllDifferent(_ items: [ApplyCollisionItem], _ choices: [String: ApplyCollisionChoice]) -> [String: ApplyCollisionChoice] {
        var result = choices
        for item in items where !item.isIdentical {
            result[item.id] = .keepBoth
        }
        return result
    }

    /// Every row left where it is ("Skip These").
    static func leaveAll(_ items: [ApplyCollisionItem]) -> [String: ApplyCollisionChoice] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, ApplyCollisionChoice.leave) })
    }

    static func decisions(for items: [ApplyCollisionItem], choices: [String: ApplyCollisionChoice]) -> ApplyCollisionDecisions {
        var decisions = ApplyCollisionDecisions()
        for item in items {
            switch choice(for: item, in: choices) {
            case .keepBoth:
                decisions.keepBoth.append(item.collision)
                decisions.keepBoth += item.companions
                decisions.keepBothConflictCount += 1
            case .trash:
                decisions.trash.append(item.collision)
            case .leave:
                break
            }
        }
        return decisions
    }

    // MARK: Wording

    /// The line between the two photos. "Identical copy", or "Different
    /// photos with the same name (taken Aug 19 vs Aug 29)" — the evidence is
    /// the capture day, else the time, else the size, when those are known.
    static func verdict(
        isIdentical: Bool,
        isPhoto: Bool,
        source: ApplyCollisionFileFacts?,
        existing: ApplyCollisionFileFacts?,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if isIdentical { return "Identical copy" }
        let noun = isPhoto ? "photos" : "files"
        let base = "Different \(noun) with the same name"
        if let mine = source?.captureDate, let theirs = existing?.captureDate {
            if !calendar.isDate(mine, inSameDayAs: theirs) {
                let sameYear = calendar.component(.year, from: mine) == calendar.component(.year, from: theirs)
                let style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                    .month(.abbreviated).day()
                let format = sameYear ? style : style.year()
                return "\(base) (taken \(mine.formatted(format)) vs \(theirs.formatted(format)))"
            }
            if abs(mine.timeIntervalSince(theirs)) >= 60 {
                let format = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                return "\(base) (taken \(mine.formatted(format)) vs \(theirs.formatted(format)))"
            }
        }
        if let mine = source?.byteCount, let theirs = existing?.byteCount, mine != theirs {
            return "\(base) (\(mine.formattedBytes) vs \(theirs.formattedBytes))"
        }
        return base
    }

    /// The plain-words recommendation under the pair.
    static func recommendation(for item: ApplyCollisionItem, keepBothName: String?) -> String {
        if item.isIdentical {
            return "This exact \(item.isPhoto ? "photo" : "file") is already there. You don’t need this copy."
        }
        let newName = keepBothName ?? KeepBothNaming.suffixed(item.fileName, 2)
        let sidecars = item.companions.isEmpty
            ? ""
            : " \(item.companions.count == 1 ? "Its sidecar moves" : "Its \(item.companions.count) sidecars move") with it under the same number."
        return "These are different \(item.isPhoto ? "photos" : "files"). Keep both. Yours will be saved as \(newName).\(sidecars)"
    }

    /// What the chosen action does, for the row under the recommendation.
    static func outcome(for item: ApplyCollisionItem, choice: ApplyCollisionChoice, keepBothName: String?) -> String {
        switch choice {
        case .keepBoth:
            "Moves in as \(keepBothName ?? KeepBothNaming.suffixed(item.fileName, 2)). Nothing is replaced, and Undo moves it back."
        case .leave:
            "Stays in this folder. The rest of the plan still applies."
        case .trash:
            "Goes to the drive’s _Trash after you confirm. The copy in \(item.eventName) stays."
        }
    }

    /// The sheet's subtitle when only taken names are left to decide.
    static func decisionSentence(for items: [ApplyCollisionItem]) -> String {
        guard let first = items.first else { return "" }
        if items.count == 1 {
            return first.isIdentical
                ? "\(first.fileName) is already in \(first.eventName) as an identical copy."
                : "A different \(first.fileName) is already in \(first.eventName). Choose what to do with yours."
        }
        let events = Set(items.map(\.eventID))
        let place = events.count == 1 ? first.eventName : "\(events.count) events"
        return "\(ApplyPlanOverview.plural(items.count, "file")) need a decision: the same names are already in \(place)."
    }
}
