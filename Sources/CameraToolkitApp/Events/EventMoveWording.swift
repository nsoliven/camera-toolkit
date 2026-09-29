import CameraToolkitCore
import Foundation

/// The status line after Move to Event, in plain words decided by what the
/// files turned out to be — never "file(s)". Pure string work.
enum EventMoveWording {
    /// "Moved 40 photos to Beach Day (4 were already there, so their extra
    /// copies went to Trash). 2 had the same name as different photos and
    /// were kept with a new name. 1 stayed in Hotel Night: …"
    /// `titles` names each file's own event: a move clicked on a family board
    /// leaves files behind in whichever subevent held them, and the line
    /// says that one, not the board's.
    static func summary(_ outcome: EventMoveOutcome, from: String, to: String, titles: [UUID: String] = [:]) -> String {
        let all = outcome.moved + outcome.keptBoth.map(\.item) + outcome.merged + outcome.stayed.map(\.item)
        let noun = all.allSatisfy { isPhoto($0.fileName) } ? "photo" : "file"
        let merged = outcome.merged.count
        let arrived = outcome.moved.count + outcome.keptBoth.count
        var sentences: [String] = []

        if arrived > 0 {
            var head = "Moved \(ApplyPlanOverview.plural(arrived + merged, noun)) to \(to)"
            if merged > 0 {
                head += " (\(mergedClause(merged, trashed: outcome.mergedToTrash)))"
            }
            sentences.append(head + ".")
        } else if merged > 0 {
            let verb = merged == 1 ? "was" : "were"
            var line = "\(ApplyPlanOverview.plural(merged, noun)) \(verb) already in \(to)"
            if outcome.mergedToTrash > 0 {
                line += outcome.mergedToTrash == merged
                    ? ", so \(merged == 1 ? "its extra copy" : "their extra copies") went to Trash"
                    : "; \(copies(outcome.mergedToTrash)) went to Trash"
            }
            sentences.append(line + ".")
        } else {
            sentences.append("Nothing moved to \(to).")
        }

        if let first = outcome.keptBoth.first {
            let count = outcome.keptBoth.count
            sentences.append(count == 1
                ? "1 had the same name as a different \(noun) and was kept as \(first.newName)."
                : "\(count) had the same name as different \(noun)s and were kept with a new name.")
        }

        if let first = outcome.stayed.first {
            let count = outcome.stayed.count
            let reasons = Set(outcome.stayed.map(\.reason))
            let owners = Set(outcome.stayed.map(\.item.removed.eventID))
            let home = owners.count == 1 ? titles[owners.first!] ?? from : from
            let lead = count == 1 ? "1 stayed in \(home)" : "\(count) stayed in \(home)"
            let reason = trimmed(first.reason)
            sentences.append(reasons.count == 1 || count == 1
                ? "\(lead): \(reason)."
                : "\(lead), for example: \(reason).")
        }
        return sentences.joined(separator: " ")
    }

    /// "4 were already there, so their extra copies went to Trash"
    private static func mergedClause(_ merged: Int, trashed: Int) -> String {
        let verb = merged == 1 ? "was" : "were"
        if trashed == 0 { return "\(merged) \(verb) already there" }
        if trashed == merged {
            return "\(merged) \(verb) already there, so \(merged == 1 ? "its extra copy" : "their extra copies") went to Trash"
        }
        return "\(merged) \(verb) already there; \(copies(trashed)) went to Trash"
    }

    private static func copies(_ count: Int) -> String {
        count == 1 ? "1 extra copy" : "\(count.formatted()) extra copies"
    }

    private static func trimmed(_ reason: String) -> String {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func isPhoto(_ fileName: String) -> Bool {
        let kind = OrganizeFileClassifier.kind(forExtension: (fileName as NSString).pathExtension)
        return kind == .raw || kind == .photo || kind == .video
    }
}
