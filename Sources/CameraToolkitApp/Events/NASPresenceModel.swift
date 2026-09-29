import CameraToolkitCore
import Foundation
import Observation

/// What asks for a NAS presence check.
enum NASPresenceTrigger: String, Sendable {
    /// App start: counts from Sync to NAS's records right away, then a
    /// listing once the NAS is mounted.
    case launch
    /// A volume mounted or unmounted.
    case mounted
    /// An event board was opened.
    case boardOpened
    /// A file job other than Sync to NAS finished — drive files may have
    /// changed, so the counts are redone; the NAS itself was not written.
    case jobFinished
    /// Sync to NAS finished: its folders are listed again, unthrottled.
    case syncFinished
    /// Check Again.
    case manual

    /// Throttled: at most one listing per `NASPresenceSchedule.automaticInterval`.
    var isAutomatic: Bool { self != .manual && self != .syncFinished }

    /// Whether the counts are worth redoing even when the NAS is not listed.
    var recountsWithoutListing: Bool { self == .launch || self == .jobFinished }
}

/// When a NAS presence check may list the NAS. Pure, so the throttle can
/// be tested without a NAS.
enum NASPresenceSchedule {
    /// Automatic listings run at most this often.
    static let automaticInterval: TimeInterval = 5 * 60
    /// The board answers the NAS place from a folder's listing only while
    /// it is younger than this; older, it stats files as before.
    static let boardTrust: TimeInterval = 15 * 60

    enum Decision: Equatable {
        /// List the NAS now.
        case list
        /// A NAS job or another check is running: ask again when it ends.
        case wait
        /// No listing this time, and why.
        case skip(String)
    }

    static func decide(
        trigger: NASPresenceTrigger,
        now: Date,
        lastListingAttempt: Date?,
        nasAvailable: Bool,
        nasJobRunning: Bool,
        isChecking: Bool
    ) -> Decision {
        // A listing would compete with the job's transfers for the link
        // and the NAS disks.
        if nasJobRunning || isChecking { return .wait }
        guard nasAvailable else { return .skip("The NAS is not connected.") }
        guard trigger.isAutomatic, let lastListingAttempt else { return .list }
        let age = now.timeIntervalSince(lastListingAttempt)
        guard age < automaticInterval else { return .list }
        return .skip("Checked \(max(Int(age / 60), 0)) min ago.")
    }
}

/// What a check needs from the workspace, read on the main actor when the
/// check starts.
struct NASPresenceContext: Sendable {
    var events: [SavedCameraEvent]
    var locations: EventStorageLocations
    var catalogURL: URL
    /// Settings: the SSH lister is built from them inside the check, off
    /// the main actor — finding the share's mount point asks the volume.
    var configuration: AppConfiguration
    var nasAvailable: Bool
    var nasJobRunning: Bool
}

/// Keeps "which event files are not on the NAS yet" current in the
/// background: counts from Sync to NAS's records at once, a listing of the
/// NAS (one SSH `find`, or bulk SMB folder reads) once it is mounted and
/// idle, a re-list of just the synced folders after each sync. Everything
/// runs off the main actor at utility priority; views read `report` only.
@MainActor
@Observable
final class NASPresenceModel {
    private(set) var report: NASPresenceReport?
    private(set) var isChecking = false
    /// NAS files listed so far by the running check.
    private(set) var listedFiles = 0
    /// Why the last check was slower than it could be, or did not list.
    private(set) var note: String?

    /// The NAS listing the counts and the board use.
    @ObservationIgnored private(set) var listing: NASTreeListing?
    @ObservationIgnored private var lastListingAttempt: Date?
    @ObservationIgnored private var waiting: Request?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Off until the app starts the NAS connection, so tests and previews
    /// never list anything.
    @ObservationIgnored var isEnabled = false
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }
    @ObservationIgnored var context: (@MainActor () -> NASPresenceContext?)?
    /// Called on the main actor after a check publishes, with the previous
    /// report.
    @ObservationIgnored var onReportChanged: (@MainActor (_ old: NASPresenceReport?, _ new: NASPresenceReport) -> Void)?

    /// A queued check: the union of what waiting triggers asked for.
    struct Request: Equatable {
        var trigger: NASPresenceTrigger
        /// Events whose folders to list; nil lists every event.
        var scope: [SavedCameraEvent]?

        /// Two requests as one: the broader scope and the stronger trigger.
        func merged(with other: Request) -> Request {
            let scope: [SavedCameraEvent]? = if let mine = self.scope, let theirs = other.scope {
                mine + theirs.filter { event in !mine.contains { $0.id == event.id } }
            } else {
                nil
            }
            let trigger = Self.rank(other.trigger) > Self.rank(self.trigger) ? other.trigger : self.trigger
            return Request(trigger: trigger, scope: scope)
        }

        private static func rank(_ trigger: NASPresenceTrigger) -> Int {
            switch trigger {
            case .boardOpened: 0
            case .mounted: 1
            case .jobFinished: 2
            case .launch: 3
            case .syncFinished: 4
            case .manual: 5
            }
        }
    }

    /// Starts a check if the schedule allows one. Cheap to call often.
    func refresh(_ trigger: NASPresenceTrigger, scope: [SavedCameraEvent]? = nil) {
        guard isEnabled else { return }
        var request = Request(trigger: trigger, scope: scope)
        if let waiting {
            request = waiting.merged(with: request)
        }
        guard let context = context?() else { return }
        let decision = NASPresenceSchedule.decide(
            trigger: request.trigger,
            now: now(),
            lastListingAttempt: lastListingAttempt,
            nasAvailable: context.nasAvailable,
            nasJobRunning: context.nasJobRunning,
            isChecking: isChecking
        )
        switch decision {
        case .wait:
            waiting = request
        case .list:
            waiting = nil
            lastListingAttempt = now()
            start(request, context: context, list: true)
        case .skip(let reason):
            waiting = nil
            guard request.trigger.recountsWithoutListing || report == nil else { return }
            if !context.nasAvailable { note = reason }
            start(request, context: context, list: false)
        }
    }

    /// A NAS job is starting: a running check stops (it would compete) and
    /// asks again once the job ends.
    func pauseForJob() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        isChecking = false
        generation += 1
        let again = Request(trigger: .jobFinished, scope: nil)
        waiting = waiting.map { $0.merged(with: again) } ?? again
    }

    /// A job finished. Sync to NAS asks for its own scoped check instead.
    func jobFinished(_ action: JobAction) {
        guard action != .syncBuffer else { return }
        refresh(.jobFinished)
    }

    /// Sync to NAS just proved these files on the NAS: the listing learns
    /// them now and the counts are redone from it — local work only, the
    /// sync is done with the NAS — so they drop before the synced folders
    /// are listed again (which queues behind this recount).
    func noteSynced(_ items: [NASSyncItem]) {
        guard isEnabled, !items.isEmpty, listing != nil else { return }
        listing?.recordSynced(items)
        guard !isChecking, let context = context?() else { return }
        start(Request(trigger: .syncFinished, scope: nil), context: context, list: false)
    }

    /// The listing the board may answer the NAS from: only folders listed
    /// within `NASPresenceSchedule.boardTrust`. Nil when there is none.
    func boardListing() -> NASTreeListing? {
        guard let listing else { return nil }
        let trusted = listing.trusting(listedSince: now().addingTimeInterval(-NASPresenceSchedule.boardTrust))
        return trusted.coverage.isEmpty ? nil : trusted
    }

    private func start(_ request: Request, context: NASPresenceContext, list: Bool) {
        task?.cancel()
        generation += 1
        let generation = self.generation
        isChecking = true
        listedFiles = 0
        let base = listing
        let now = self.now
        let progress = ListingProgress { [weak self] count in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.listedFiles = count
            }
        }
        task = Task.detached(priority: .utility) { [weak self] in
            let outcome = Self.check(request: request, context: context, base: base, list: list, now: now, progress: progress)
            await self?.finish(outcome, generation: generation)
        }
    }

    struct Outcome: Sendable {
        var report: NASPresenceReport?
        var listing: NASTreeListing?
        var note: String?
        var cancelled = false
    }

    /// The check itself, off the main actor: the drive plan (local folder
    /// listings), Sync to NAS's records (one catalog read), and — when
    /// `list` — one listing of the NAS folders the request covers.
    nonisolated static func check(
        request: Request,
        context: NASPresenceContext,
        base: NASTreeListing?,
        list: Bool,
        now: @Sendable () -> Date,
        progress: ListingProgress? = nil
    ) -> Outcome {
        let locations = context.locations
        let nasRoot = locations.nasRoot
        // The legacy-layout check stats one folder per event on the NAS;
        // skipped while it is not mounted, where it could only say "no".
        let plan = NASSyncPlanner.plan(events: context.events, locations: locations, checkLegacyLayout: context.nasAvailable)
        if Task.isCancelled { return Outcome(cancelled: true) }
        let records = NASSyncStore.existingRecords(catalogURL: context.catalogURL, nasRoot: nasRoot.path)
        var listing = base?.root == nasRoot.standardizedFileURL.path ? base : nil
        var note: String?
        if list {
            let remote = NASRemoteLister.from(configuration: context.configuration, nasRoot: nasRoot)
            // Over SSH every event folder costs nothing extra; over SMB only
            // the folders that hold drive files are read.
            let withFiles = Set(plan.items.compactMap(\.eventID))
            let events = request.scope ?? (remote != nil ? context.events : context.events.filter { withFiles.contains($0.id) })
            let folders = NASPresenceIndex.folders(for: events, locations: locations)
            do {
                let result = try NASPresenceIndex.list(
                    nasRoot: nasRoot,
                    folders: folders,
                    remote: remote,
                    now: now(),
                    isCancelled: { Task.isCancelled },
                    progress: { progress?.report($0) }
                )
                if var merged = listing {
                    merged.merge(result.listing)
                    listing = merged
                } else {
                    listing = result.listing
                }
                if let reason = result.sshFallbackReason {
                    note = "Listed over SMB — SSH did not answer: \(reason)"
                }
            } catch is CancellationError {
                return Outcome(cancelled: true)
            } catch {
                note = "Could not list the NAS: \(error.localizedDescription)"
            }
        }
        if Task.isCancelled { return Outcome(cancelled: true) }
        return Outcome(
            report: NASPresenceIndex.report(plan: plan, records: records, listing: listing, checkedAt: now()),
            listing: listing,
            note: note
        )
    }

    private func finish(_ outcome: Outcome, generation: Int) {
        guard generation == self.generation else { return }
        task = nil
        isChecking = false
        if !outcome.cancelled, let report = outcome.report {
            let old = self.report
            listing = outcome.listing
            self.report = report
            note = outcome.note
            onReportChanged?(old, report)
        }
        if let waiting {
            self.waiting = nil
            refresh(waiting.trigger, scope: waiting.scope)
        }
    }

    /// Hands listing progress to the main actor at most a few times a second.
    final class ListingProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date.distantPast
        private let emit: @Sendable (Int) -> Void

        init(emit: @escaping @Sendable (Int) -> Void) {
            self.emit = emit
        }

        func report(_ count: Int) {
            let due: Bool = lock.withLock {
                let now = Date()
                guard now.timeIntervalSince(last) >= 0.25 else { return false }
                last = now
                return true
            }
            if due { emit(count) }
        }
    }
}

/// The words and numbers the Sync All button, the sidebar badges, and the
/// confirmation show. Pure, so they are tested without views.
enum NASPendingText {
    /// "312", "1.2k", "12k" — short enough for a sidebar badge.
    static func badge(_ count: Int) -> String {
        switch count {
        case ..<1_000: "\(count)"
        case ..<10_000: String(format: "%.1fk", Double(count) / 1_000).replacingOccurrences(of: ".0k", with: "k")
        default: "\(count / 1_000)k"
        }
    }

    static func files(_ count: Int) -> String {
        "\(count.formatted()) file\(count == 1 ? "" : "s")"
    }

    /// The line under "Sync All to NAS".
    static func syncAllDetail(report: NASPresenceReport?, isChecking: Bool, nasAvailable: Bool) -> String {
        guard let report else {
            return isChecking ? "Checking what is not on the NAS…" : (nasAvailable ? "Not checked yet" : "NAS not connected")
        }
        let total = report.total
        if total.pendingFiles > 0 {
            // Only Sync to NAS's records answered: "not verified" is all
            // that is known.
            let unverifiedOnly = total.unknownFiles == total.pendingFiles && report.listedAt == nil
            return "\(files(total.pendingFiles)) · \(total.pendingBytes.formattedBytes) \(unverifiedOnly ? "not verified on NAS" : "not on NAS")"
        }
        if total.differentFiles > 0 {
            return "\(files(total.differentFiles)) differ on the NAS"
        }
        if total.files == 0 { return "No event files on the drive" }
        return "Everything is on the NAS"
    }

    /// The help text of a sidebar event's badge.
    static func badgeHelp(_ totals: NASPresenceTotals) -> String {
        var parts = ["\(files(totals.pendingFiles)) · \(totals.pendingBytes.formattedBytes) not on the NAS yet"]
        if totals.differentFiles > 0 { parts.append("\(files(totals.differentFiles)) differ on the NAS (never overwritten)") }
        return parts.joined(separator: " · ")
    }

    /// "as of 5 min ago · SSH listing"
    static func freshness(_ report: NASPresenceReport, now: Date) -> String {
        guard let listedAt = report.listedAt else { return "from Sync to NAS's records — the NAS has not been listed yet" }
        let minutes = max(Int(now.timeIntervalSince(listedAt) / 60), 0)
        let age = minutes == 0 ? "just now" : "\(minutes) min ago"
        let method = report.method == .ssh ? "listed on the NAS over SSH" : "listed over SMB"
        return "\(method) \(age)"
    }
}

/// One event in the Sync All confirmation.
struct NASSyncAllRow: Identifiable, Equatable {
    var id: UUID
    var title: String
    var isPrivate: Bool
    var pendingFiles: Int
    var pendingBytes: Int64
    var differentFiles: Int

    /// Every event with something not on the NAS (or different there),
    /// most bytes first. Each event counts its own folder; subevents are
    /// their own rows.
    static func rows(report: NASPresenceReport, events: [SavedCameraEvent], title: (SavedCameraEvent) -> String, isPrivate: (SavedCameraEvent) -> Bool) -> [NASSyncAllRow] {
        events.compactMap { event -> NASSyncAllRow? in
            guard let totals = report.byEvent[event.id], totals.pendingFiles > 0 || totals.differentFiles > 0 else { return nil }
            return NASSyncAllRow(
                id: event.id,
                title: title(event),
                isPrivate: isPrivate(event),
                pendingFiles: totals.pendingFiles,
                pendingBytes: totals.pendingBytes,
                differentFiles: totals.differentFiles
            )
        }
        .sorted { ($0.pendingBytes, $0.pendingFiles, $1.title) > ($1.pendingBytes, $1.pendingFiles, $0.title) }
    }
}
