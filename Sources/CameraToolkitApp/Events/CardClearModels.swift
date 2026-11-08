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

    /// One copy the sheet shows being checked, in the order the job checks
    /// them.
    struct CheckLine: Equatable {
        var systemImage: String
        var title: String
        var detail: String
        /// True when the check is weaker than a fresh read (NAS unreachable).
        var isWarning = false
    }

    /// The sheet's three checks: the drive copy, the NAS copy, the card file.
    static func sheetChecks(_ request: CardClearRequest) -> [CheckLine] {
        [
            CheckLine(
                systemImage: "externaldrive",
                title: request.driveName ?? "Drive",
                detail: "Re-read, must match the verified hash"
            ),
            request.nasReachable
                ? CheckLine(systemImage: "server.rack", title: "NAS", detail: "Re-read, must match the drive copy")
                : CheckLine(systemImage: "server.rack", title: "NAS", detail: "Using the hash recorded at sync — NAS not reachable", isWarning: true),
            CheckLine(
                systemImage: "sdcard",
                title: request.locationName,
                detail: "Must match the drive copy before it's deleted"
            ),
        ]
    }

    /// The rule above the checks, in one line.
    static func sheetRule(_ request: CardClearRequest) -> String {
        "Each file is deleted only when it is safe on both \(drive(request.driveName)) and the NAS."
    }

    /// Below the checks: what happens to anything that fails.
    static let sheetFootnote = "Anything that does not match stays on the card. The drive and NAS copies are only read."

    /// "Checking NAS copy · checked 40/165 on Buffer and the NAS ·
    /// 38 cleared" — the running job's note, from the service's own step and
    /// counters.
    static func runningNote(_ update: FileOperationProgress, driveName: String?, nasReachable: Bool) -> String {
        let telemetry = update.telemetry
        let step = telemetry?.step ?? update.phase
        let checked = telemetry?.counter(CardClearService.checkedCounter) ?? 0
        let cleared = telemetry?.counter("Cleared") ?? 0
        let skipped = telemetry?.counter("Skipped") ?? 0
        let copies = nasReachable
            ? "on \(drive(driveName)) and the NAS"
            : "on \(drive(driveName)) and the recorded NAS hashes"
        var parts = [step, "checked \(checked.formatted())/\(update.totalFiles.formatted()) \(copies)"]
        if cleared > 0 || step == CardClearService.deletingStep {
            parts.append("\(cleared.formatted()) cleared")
        }
        if skipped > 0 {
            parts.append("\(skipped.formatted()) skipped")
        }
        return "Clear from Card: " + parts.joined(separator: " · ")
    }

    /// One copy's result: "165 matched on Buffer ✓", or "163/165 …"
    /// when some did not.
    private static func matched(_ count: Int, of checked: Int, on place: String) -> String {
        count == checked
            ? "\(count.formatted()) matched on \(place) ✓"
            : "\(count.formatted())/\(checked.formatted()) matched on \(place)"
    }

    /// "165 matched on Buffer ✓ · 165 matched on the NAS ✓ · 165
    /// cleared"; nil when nothing was checked.
    static func checksLine(_ checks: CardClearChecks) -> String? {
        guard checks.checked > 0 else { return nil }
        var parts = [matched(checks.driveMatched, of: checks.checked, on: drive(checks.driveName))]
        if checks.nasReread {
            parts.append(matched(checks.nasMatched, of: checks.checked, on: "the NAS"))
        } else {
            parts.append("NAS not reachable — recorded hashes used")
        }
        parts.append("\(checks.cleared.formatted()) cleared")
        return parts.joined(separator: " · ")
    }

    /// The finished job's per-copy results, one per copy, for its detail.
    static func finishedChecks(_ checks: CardClearChecks) -> [CheckLine] {
        guard checks.checked > 0 else { return [] }
        func count(_ matched: Int) -> String {
            matched == checks.checked ? "\(matched.formatted()) matched ✓" : "\(matched.formatted()) of \(checks.checked.formatted()) matched"
        }
        return [
            CheckLine(systemImage: "externaldrive", title: checks.driveName ?? "Drive", detail: count(checks.driveMatched), isWarning: checks.driveMatched < checks.checked),
            checks.nasReread
                ? CheckLine(systemImage: "server.rack", title: "NAS", detail: count(checks.nasMatched), isWarning: checks.nasMatched < checks.checked)
                : CheckLine(systemImage: "server.rack", title: "NAS", detail: "Not reachable — recorded hashes used", isWarning: true),
            CheckLine(systemImage: "sdcard", title: "Card", detail: "\(checks.cleared.formatted()) cleared" + (checks.skipped > 0 ? " · \(checks.skipped.formatted()) stayed" : ""), isWarning: checks.skipped > 0),
        ]
    }

    static func skippedNote(_ request: CardClearRequest) -> String? {
        guard request.waitingForNASFiles > 0 else { return nil }
        return "Stays on the card: \(request.waitingForNASFiles) file\(request.waitingForNASFiles == 1 ? "" : "s") not on the NAS yet — Sync to NAS first. Files not yet applied, or not sorted, are never cleared."
    }

    static func summary(_ outcome: CardClearOutcome, locationName: String) -> String {
        let report = outcome.report
        var line = "Cleared \(report.cleared.count) file\(report.cleared.count == 1 ? "" : "s") (\(report.clearedBytes.formattedBytes)) from \(locationName) after re-checking their copies."
        if let checks = checksLine(report.checks) {
            line += " \(checks)."
        }
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
        if report.usedRecordedNASHashes, report.checks.checked > 0 || !report.cleared.isEmpty {
            line += " The NAS was not reachable, so the hashes Sync to NAS recorded were used instead of reading it again."
        }
        return line + " Drive and NAS copies were not touched."
    }
}
