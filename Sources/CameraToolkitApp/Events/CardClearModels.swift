import CameraToolkitCore
import Foundation

/// A planner pass's inputs, captured on the main actor and run anywhere.
struct CardClearJobInputs: Sendable {
    var inputs: [CardClearInput]
    var sourceRoot: String
    var events: [UUID: SavedCameraEvent]
    var locations: EventStorageLocations
    var catalogURL: URL
    var mountedVolumes: Set<String>?
    var pauseGate: DriveActivityGate?
    var sameVolume: AppliedSourceCheck.SameVolume?

    func plan(isCancelled: @Sendable () -> Bool) -> CardClearPlan {
        CardClearPlanner.plan(
            inputs: inputs,
            sourceRoot: sourceRoot,
            events: events,
            locations: locations,
            catalogURL: catalogURL,
            mountedVolumes: mountedVolumes,
            pauseGate: pauseGate,
            sameVolume: sameVolume,
            isCancelled: isCancelled
        )
    }
}

/// What the unsorted board's banner says about clearing the card.
struct CardClearSummary: Equatable, Sendable {
    var clearableFiles: Int
    var clearableBytes: Int64
    var waitingForNASFiles: Int
    var driveName: String?

    init(_ plan: CardClearPlan) {
        clearableFiles = plan.clearableFiles
        clearableBytes = plan.clearableBytes
        waitingForNASFiles = plan.waitingFiles
        driveName = plan.driveName
    }

    var isEmpty: Bool { clearableFiles == 0 && waitingForNASFiles == 0 }
}

/// The open Clear from Card confirmation: what the planner found when the
/// button was pressed. The job plans again and clears only these items.
struct CardClearRequest: Identifiable {
    struct EventLine: Equatable {
        var name: String
        var fileCount: Int
        var byteCount: Int64
    }

    let id = UUID()
    var locationID: UUID
    var locationName: String
    var itemIDs: Set<String>
    var fileCount: Int
    var byteCount: Int64
    var events: [EventLine]
    var waitingForNASFiles: Int
    var driveName: String?
    var nasReachable: Bool
}

struct CardClearOutcome: Sendable {
    var report: CardClearReport
    /// Items the sheet listed that no longer qualified when the job planned
    /// again; left alone.
    var noLongerEligible: Int
}

enum CardClearWording {
    static func drive(_ name: String?) -> String {
        name.map { "\($0)" } ?? "the drive"
    }

    /// The banner's line.
    static func bannerLine(_ summary: CardClearSummary) -> String {
        var parts: [String] = []
        if summary.clearableFiles > 0 {
            parts.append("\(summary.clearableFiles.formatted()) file\(summary.clearableFiles == 1 ? " here is" : "s here are") safe on \(drive(summary.driveName)) and the NAS")
        }
        if summary.waitingForNASFiles > 0 {
            parts.append(summary.clearableFiles > 0
                ? "\(summary.waitingForNASFiles.formatted()) waiting for Sync to NAS"
                : "\(summary.waitingForNASFiles.formatted()) file\(summary.waitingForNASFiles == 1 ? " is" : "s are") in \(summary.waitingForNASFiles == 1 ? "its event" : "their events") but waiting for Sync to NAS before they can be cleared")
        }
        return parts.joined(separator: " · ")
    }

    static func sheetExplanation(_ request: CardClearRequest) -> String {
        "Camera Toolkit checks every file again first: the copy on \(drive(request.driveName)) must still hash to exactly what Sync to NAS verified"
            + (request.nasReachable ? ", the NAS copy is read again and must match it," : ",")
            + " and the card file must hash the same as the drive copy. Only files that pass are permanently deleted from \(request.locationName). Anything that does not match stays on the card. The drive and NAS copies are not touched."
    }

    static func nasNote(_ request: CardClearRequest) -> String? {
        request.nasReachable
            ? nil
            : "The NAS is not reachable now, so the NAS side relies on the SHA-256 that Sync to NAS recorded when it verified each copy."
    }

    static func skippedNote(_ request: CardClearRequest) -> String? {
        guard request.waitingForNASFiles > 0 else { return nil }
        return "Stays on the card: \(request.waitingForNASFiles) file\(request.waitingForNASFiles == 1 ? "" : "s") not on the NAS yet — Sync to NAS first. Files not yet applied, or not sorted, are never cleared."
    }

    static func summary(_ outcome: CardClearOutcome, locationName: String) -> String {
        let report = outcome.report
        var line = "Cleared \(report.cleared.count) file\(report.cleared.count == 1 ? "" : "s") (\(report.clearedBytes.formattedBytes)) from \(locationName) after re-checking their copies."
        if !report.skipped.isEmpty {
            let reasons = Dictionary(grouping: report.skipped.values, by: { $0 })
                .sorted { $0.value.count > $1.value.count }
                .prefix(3)
                .map { "\($0.value.count) — \($0.key)" }
            line += " \(report.skipped.count) stayed on the card: " + reasons.joined(separator: "; ")
        }
        if outcome.noLongerEligible > 0 {
            line += " \(outcome.noLongerEligible) item\(outcome.noLongerEligible == 1 ? "" : "s") no longer qualified and stayed."
        }
        if report.usedRecordedNASHashes, !report.cleared.isEmpty {
            line += " The NAS was not reachable; its recorded verified hashes were used."
        }
        return line + " Drive and NAS copies were not touched."
    }
}
