import CameraToolkitCore
import Foundation
import Observation

/// A "Keep in X only" waiting for the owner's confirmation.
struct PendingDuplicateResolution: Identifiable, Sendable {
    let id = UUID()
    var keep: DuplicateOwner
    var drop: DuplicateOwner
    var groups: [DuplicateGroup]

    /// The dropped side's copies.
    var copies: [DuplicateCopy] { groups.flatMap { $0.copies(of: drop) } }
    /// Copies that are one file shared with the kept side: only their
    /// listing goes, nothing moves to Trash.
    var listingOnlyCount: Int { groups.filter(\.isOneFile).reduce(0) { $0 + $1.copies(of: drop).count } }
    var trashCount: Int { copies.count - listingOnlyCount }
    var trashBytes: Int64 { groups.filter { !$0.isOneFile }.reduce(Int64(0)) { $0 + $1.byteCount * Int64($1.copies(of: drop).count) } }
}

/// What the Duplicates window shows on its right side.
enum DuplicateReviewSelection: Hashable, Sendable {
    case identical(DuplicateOwnerPair)
    case sameName(DuplicateOwnerPair)
}

/// The duplicate review: one scan of every event's local copies (and the
/// unsorted folders already on screen), the owner's Keep Both marks, and
/// the confirmation before anything moves. Scanning is read-only and runs
/// off the main actor; resolving goes through `EventsWorkspace`.
@MainActor
@Observable
final class DuplicateReviewModel {
    @ObservationIgnored private weak var workspace: EventsWorkspace?

    private(set) var report: DuplicateScanReport?
    private(set) var reviewedKeys: Set<String> = []
    private(set) var isScanning = false
    private(set) var progress: FileOperationProgress?
    var includeUnsorted = true
    var selection: DuplicateReviewSelection?
    /// Groups ticked in the detail list for a batch action.
    var checkedGroupIDs: Set<String> = []
    var pending: PendingDuplicateResolution?
    /// The window's own last-result line.
    var message: String?

    @ObservationIgnored private var scanWork: Task<(DuplicateScanReport, Set<String>), Never>?

    init(workspace: EventsWorkspace) {
        self.workspace = workspace
    }

    var storeURL: URL? {
        workspace.map { DuplicateReviewStore.defaultURL(supportFolder: $0.supportFolder) }
    }

    // MARK: Scan

    /// Hashes only files whose size another owner shares, reusing cached
    /// hashes for files that did not change. Never writes to a photo.
    func scan() {
        guard !isScanning, let workspace, let storeURL else { return }
        let configuration = workspace.model.configuration
        let locations = workspace.locations
        let folders: [(id: UUID, paths: [String])] = includeUnsorted
            ? workspace.sources.compactMap { id, state in
                state.result.map { (id: id, paths: $0.items.flatMap(\.files).map(\.path)) }
            }
            : []
        isScanning = true
        progress = nil
        message = nil
        let work = Task.detached(priority: .utility) { [weak self] () -> (DuplicateScanReport, Set<String>) in
            let store = try? DuplicateReviewStore(url: storeURL)
            let events = DuplicateScanner.eventCandidates(
                events: configuration.savedEvents,
                assignments: configuration.photoEventAssignments,
                locations: locations
            )
            let unsorted = DuplicateScanner.unsortedCandidates(
                folders: folders,
                excluding: events,
                assignments: configuration.photoEventAssignments
            )
            let report = DuplicateScanner(store: store).scan(events + unsorted) { update in
                Task { @MainActor in self?.progress = update }
            }
            return (report, (try? store?.reviewedGroupKeys()) ?? [])
        }
        scanWork = work
        Task { @MainActor [weak self] in
            let (report, reviewed) = await work.value
            guard let self else { return }
            isScanning = false
            progress = nil
            scanWork = nil
            reviewedKeys = reviewed
            self.report = report
            checkedGroupIDs = []
            if case .identical(let pair)? = selection, !pairs.contains(where: { $0.pair == pair }) {
                selection = nil
            }
            if selection == nil {
                selection = pairs.first.map { .identical($0.pair) } ?? collisionPairs.first.map { .sameName($0.pair) }
            }
            message = DuplicateReviewWording.scanSummary(report, pairs: pairs.count)
        }
    }

    func stopScan() {
        scanWork?.cancel()
    }

    // MARK: Reading the result

    /// Owner pairs with unreviewed identical files, largest first.
    var pairs: [DuplicatePairSummary] {
        (report?.pairs(reviewed: reviewedKeys) ?? []).filter { $0.fileCount > 0 }
    }

    var reviewedCount: Int {
        guard let report else { return 0 }
        return report.groups.count { reviewedKeys.contains($0.id) }
    }

    var collisionPairs: [DuplicateCollisionPairSummary] { report?.collisionPairs() ?? [] }

    func summary(for pair: DuplicateOwnerPair) -> DuplicatePairSummary? {
        pairs.first { $0.pair == pair }
    }

    func collisions(for pair: DuplicateOwnerPair) -> [DuplicateNameCollision] {
        collisionPairs.first { $0.pair == pair }?.collisions ?? []
    }

    /// Unreviewed groups an event shares with anyone — the board notice.
    func sharedGroups(forEvent eventID: UUID) -> [DuplicateGroup] {
        report?.groups(sharedBy: .event(eventID), reviewed: reviewedKeys) ?? []
    }

    /// The other owners an event shares identical files with, most first.
    func partners(ofEvent eventID: UUID) -> [DuplicateOwner] {
        pairs.filter { $0.pair.contains(.event(eventID)) }.map { $0.pair.other(than: .event(eventID)) }
    }

    /// Focuses the window on the event's largest pair.
    func focus(onEvent eventID: UUID) {
        if let pair = pairs.first(where: { $0.pair.contains(.event(eventID)) }) {
            selection = .identical(pair.pair)
            checkedGroupIDs = []
        }
    }

    // MARK: Owners, as the window names them

    func title(_ owner: DuplicateOwner) -> String {
        switch owner {
        case .event(let id):
            workspace?.event(id).map { workspace?.eventTitle($0) ?? $0.name } ?? "Deleted event"
        case .folder(let id):
            workspace?.location(id).map(\.name) ?? "Unsorted folder"
        }
    }

    func isPrivate(_ owner: DuplicateOwner) -> Bool {
        guard case .event(let id) = owner, let workspace, let event = workspace.event(id) else { return false }
        return workspace.resolvedPolicy(for: event) == .archiveOnly
    }

    /// Which half of the drive a copy sits in, then its folder under that
    /// root: "Private staging · 2026/2026-08-26 Hotel/Originals/Sony A7V".
    /// A head-truncated path would hide exactly the part that differs.
    func place(of copy: DuplicateCopy) -> String {
        guard let workspace else { return copy.folderPath }
        let locations = workspace.locations
        let folder = copy.folderPath
        let roots: [(String, String)] = [
            (locations.privateStagingRoot.path, "Private staging"),
            (locations.bufferRoot.path, "Buffer"),
        ] + workspace.unsortedLocations.map { (DashboardModel.expandedPath($0.path), $0.name) }
        for (root, name) in roots where folder.lowercased().hasPrefix(root.lowercased() + "/") || folder.lowercased() == root.lowercased() {
            let rest = String(folder.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rest.isEmpty ? name : "\(name) · \(rest)"
        }
        return folder
    }

    func symbol(_ owner: DuplicateOwner) -> String {
        switch owner {
        case .event: isPrivate(owner) ? "lock.fill" : "folder.fill"
        case .folder: "tray.full"
        }
    }

    // MARK: Choices

    /// Opens the confirmation for "Keep in `keep` only" on `groups`.
    func requestKeep(_ keep: DuplicateOwner, in pair: DuplicateOwnerPair, groups: [DuplicateGroup]) {
        guard !groups.isEmpty else { return }
        pending = PendingDuplicateResolution(keep: keep, drop: pair.other(than: keep), groups: groups)
    }

    func confirm(_ request: PendingDuplicateResolution) {
        pending = nil
        guard let workspace else { return }
        let resolutions = request.groups.map { DuplicateResolution(group: $0, keep: request.keep, drop: [request.drop]) }
        let started = workspace.resolveDuplicates(resolutions) { [weak self] outcome in
            self?.didResolve(outcome)
        }
        if !started {
            message = "Another file job is running. Try again when it finishes — nothing was moved."
        }
    }

    /// Keep Both: the groups stop being flagged, now and in later scans.
    func keepBoth(_ groups: [DuplicateGroup]) {
        guard !groups.isEmpty, let storeURL else { return }
        let keys = groups.map(\.id)
        reviewedKeys.formUnion(keys)
        checkedGroupIDs.subtract(keys)
        message = "Kept both copies of \(ApplyPlanOverview.plural(groups.count, "photo")). They won’t be flagged again unless another copy turns up."
        Task.detached(priority: .utility) {
            try? DuplicateReviewStore(url: storeURL).markReviewed(groups)
        }
    }

    /// Flags every Keep Both group again.
    func resetReviewed() {
        guard let storeURL, !reviewedKeys.isEmpty else { return }
        let keys = Array(reviewedKeys)
        reviewedKeys = []
        Task.detached(priority: .utility) {
            try? DuplicateReviewStore(url: storeURL).clearReviewed(keys)
        }
    }

    /// Drops every copy that left its owner from the result, so the list
    /// matches the drive without a rescan.
    func didResolve(_ outcome: DuplicateResolutionOutcome) {
        let gone = outcome.resolvedCopyIDs
        message = DuplicateReviewWording.resolutionSummary(outcome)
        guard var report else { return }
        report.groups = report.groups.compactMap { group in
            let kept = group.copies.filter { !gone.contains($0.id) }
            guard Set(kept.map(\.owner)).count >= 2 else { return nil }
            return DuplicateGroup(sha256: group.sha256, byteCount: group.byteCount, copies: kept)
        }
        self.report = report
        checkedGroupIDs = checkedGroupIDs.intersection(Set(report.groups.map(\.id)))
        if case .identical(let pair)? = selection, summary(for: pair) == nil {
            selection = pairs.first.map { .identical($0.pair) }
        }
    }
}

/// The Duplicates window's sentences. Pure string work.
enum DuplicateReviewWording {
    static func copies(_ count: Int) -> String {
        count == 1 ? "1 copy" : "\(count.formatted()) copies"
    }

    /// "71 identical photos · 1.7 GB"
    static func pairLine(_ summary: DuplicatePairSummary) -> String {
        let noun = summary.groups.allSatisfy { EventMoveWording.isPhoto($0.fileName) } ? "photo" : "file"
        return "\(ApplyPlanOverview.plural(summary.fileCount, "identical \(noun)")) · \(summary.byteCount.formattedBytes)"
    }

    /// The confirmation's message: exactly what moves, what stays, and how
    /// to get it back.
    static func confirmation(_ request: PendingDuplicateResolution, keepName: String, dropName: String) -> String {
        var parts: [String] = []
        if request.trashCount > 0 {
            parts.append("\(copies(request.trashCount)) (\(request.trashBytes.formattedBytes)) in \(dropName) will move to the drive’s Trash. The copies in \(keepName) stay.")
        }
        if request.listingOnlyCount > 0 {
            let verb = request.listingOnlyCount == 1 ? "is" : "are"
            parts.append("\(request.listingOnlyCount) \(verb) one file listed in both events — only \(dropName)’s listing goes; the file stays.")
        }
        parts.append("Each copy is re-checked byte for byte first, and anything that changed is left alone.")
        if request.trashCount > 0 {
            parts.append("You can restore them from the Trash window.")
        }
        return parts.joined(separator: " ")
    }

    static func confirmButton(_ request: PendingDuplicateResolution) -> String {
        request.trashCount > 0
            ? "Move \(copies(request.trashCount)) to Trash"
            : "Remove \(request.listingOnlyCount == 1 ? "Listing" : "Listings")"
    }

    static func scanSummary(_ report: DuplicateScanReport, pairs: Int) -> String {
        if report.cancelled { return "Scan stopped. Results so far are shown." }
        var text = report.groups.isEmpty
            ? "No photo is in two places. Checked \(ApplyPlanOverview.plural(report.scannedFiles, "file"))."
            : "Found \(ApplyPlanOverview.plural(report.groups.count, "photo")) held in more than one place (\(pairs) \(pairs == 1 ? "pair" : "pairs"))."
        if !report.unreadable.isEmpty {
            text += " \(report.unreadable.count) could not be read."
        }
        return text
    }

    /// The status line after "Keep in X only".
    static func resolutionSummary(_ outcome: DuplicateResolutionOutcome) -> String {
        var parts: [String] = []
        if !outcome.trashed.isEmpty {
            parts.append("Moved \(copies(outcome.trashed.count)) (\(outcome.trashedBytes.formattedBytes)) to Trash — restorable from the Trash window.")
        }
        if !outcome.unassigned.isEmpty {
            parts.append("Removed \(outcome.unassigned.count == 1 ? "1 extra listing" : "\(outcome.unassigned.count) extra listings"); the file stayed.")
        }
        if let first = outcome.refused.first {
            parts.append("\(copies(outcome.refused.count)) left untouched: \(first.reason)")
        }
        return parts.isEmpty ? "Nothing changed." : parts.joined(separator: " ")
    }

    /// The event board's notice.
    static func boardNotice(count: Int, partners: [String]) -> String {
        let what = count == 1 ? "1 photo here is an identical copy" : "\(count.formatted()) photos here are identical copies"
        let place: String
        switch partners.count {
        case 0: place = "another event"
        case 1: place = partners[0]
        case 2: place = "\(partners[0]) and \(partners[1])"
        default: place = "\(partners[0]) and \(partners.count - 1) other places"
        }
        return "\(what) of \(count == 1 ? "one" : "ones") in \(place)."
    }
}
