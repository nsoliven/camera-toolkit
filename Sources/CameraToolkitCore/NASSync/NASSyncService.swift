import Darwin
import Foundation

public struct NASSyncReport: Codable, Equatable, Sendable {
    /// Copied to the NAS and verified by re-reading the NAS copy.
    public var copied: [String] = []
    /// Already on the NAS at the same path with the same SHA-256; now
    /// recorded as verified.
    public var matchedExisting: [String] = []
    /// Verified by an earlier sync at the same size and drive modification
    /// time, and still on the NAS at that size; not re-read.
    public var alreadyVerified: [String] = []
    /// A different file sits at the NAS path. Never overwritten.
    public var conflicts: [NASSyncIssue] = []
    /// Could not be read, written, or verified; reported and skipped.
    public var failed: [NASSyncIssue] = []
    /// Not attempted because the NAS went away or the job was stopped.
    public var notAttempted: Int = 0
    public var stoppedReason: String?
    public var bytesCopied: Int64 = 0
    public var foldersCreated: Int = 0
    /// NAS copies whose SHA-256 did not match the drive copy's. Each is
    /// also in `failed`; listed apart because on a pool that has shown
    /// corruption this must never be read past.
    public var hashMismatches: [NASSyncIssue] = []
    /// Files whose first copy hit a transient SMB failure (a descriptor the
    /// share invalidated, a reset connection) and were copied again from a
    /// fresh open after a short delay. A file that then verified is in
    /// `copied`; one that failed again is also in `failed`.
    public var retried: [NASSyncIssue] = []
    /// How the run was configured and where its time went.
    public var timings = NASSyncTimings()

    public var verifiedCount: Int { copied.count + matchedExisting.count + alreadyVerified.count }
    public var succeeded: Bool { conflicts.isEmpty && failed.isEmpty && notAttempted == 0 && stoppedReason == nil }
}

extension NASSyncReport {
    /// Reports written before `retried` existed still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        copied = try container.decodeIfPresent([String].self, forKey: .copied) ?? []
        matchedExisting = try container.decodeIfPresent([String].self, forKey: .matchedExisting) ?? []
        alreadyVerified = try container.decodeIfPresent([String].self, forKey: .alreadyVerified) ?? []
        conflicts = try container.decodeIfPresent([NASSyncIssue].self, forKey: .conflicts) ?? []
        failed = try container.decodeIfPresent([NASSyncIssue].self, forKey: .failed) ?? []
        notAttempted = try container.decodeIfPresent(Int.self, forKey: .notAttempted) ?? 0
        stoppedReason = try container.decodeIfPresent(String.self, forKey: .stoppedReason)
        bytesCopied = try container.decodeIfPresent(Int64.self, forKey: .bytesCopied) ?? 0
        foldersCreated = try container.decodeIfPresent(Int.self, forKey: .foldersCreated) ?? 0
        hashMismatches = try container.decodeIfPresent([NASSyncIssue].self, forKey: .hashMismatches) ?? []
        retried = try container.decodeIfPresent([NASSyncIssue].self, forKey: .retried) ?? []
        timings = try container.decodeIfPresent(NASSyncTimings.self, forKey: .timings) ?? NASSyncTimings()
    }
}

/// Where a sync's time went. Phase seconds are summed over the parallel
/// transfers (busy time), so with 4 transfers they can add up to more than
/// `wallSeconds`.
public struct NASSyncTimings: Codable, Equatable, Hashable, Sendable {
    public var parallelTransfers: Int = 1
    /// "SMB re-read" or "NAS SHA-256 (<label>)".
    public var verification: String = ""
    public var flushEachFile: Bool = false
    public var wallSeconds: Double = 0
    /// Listing the NAS folders, creating missing ones, clearing stale temporaries.
    public var checkSeconds: Double = 0
    public var copySeconds: Double = 0
    public var flushSeconds: Double = 0
    public var verifySeconds: Double = 0
    public var renameSeconds: Double = 0
    /// Bytes written to the NAS.
    public var copyBytes: Int64 = 0
    /// Bytes verified by re-reading over SMB.
    public var smbVerifyBytes: Int64 = 0
    /// Bytes verified by hashing on the NAS.
    public var remoteVerifyBytes: Int64 = 0
    public var remoteBatches: Int = 0
    /// Files the NAS-side hash could not answer for, verified over SMB instead.
    public var remoteFallbacks: Int = 0
    /// Why NAS-side hashing fell back, the first time it did.
    public var remoteFallbackReason: String?
    /// Files copied a second time after a transient SMB failure (nil: none;
    /// optional so history rows written before it existed still decode).
    public var transientRetries: Int?

    public init() {}

    /// "Copy 12.3 s · Verify 1.0 s · Rename 0.2 s" — for the Jobs window.
    public var phaseSummary: String {
        var parts = [String(format: "Copy %.1f s", copySeconds)]
        if flushEachFile { parts.append(String(format: "Flush %.1f s", flushSeconds)) }
        parts.append(String(format: "Verify %.1f s", verifySeconds))
        parts.append(String(format: "Rename %.1f s", renameSeconds))
        return parts.joined(separator: " · ")
    }
}

/// How Sync to NAS copies and verifies.
public struct NASSyncOptions: Sendable {
    public static let parallelRange = 1...8
    public static let defaultParallelTransfers = 4

    /// Files copied at once. Each transfer holds one `NASFileIO.chunkSize`
    /// buffer, so memory stays at `chunkSize × parallelTransfers`.
    public var parallelTransfers: Int {
        didSet { parallelTransfers = Self.clamp(parallelTransfers) }
    }
    public var copy: NASFileIO.CopyOptions
    /// Hash on the NAS over SSH instead of re-reading over SMB.
    public var remoteVerifier: NASRemoteVerifier?
    /// A NAS-side batch is verified once it holds this many files …
    public var remoteBatchFiles: Int
    /// … or this many bytes, whichever comes first.
    public var remoteBatchBytes: Int64
    /// How long a file waits before its one retry after a transient SMB
    /// failure (see `NASFileIO.TransientIOError`).
    public var retryDelay: TimeInterval

    public init(
        parallelTransfers: Int = NASSyncOptions.defaultParallelTransfers,
        copy: NASFileIO.CopyOptions = .fast,
        remoteVerifier: NASRemoteVerifier? = nil,
        remoteBatchFiles: Int = 32,
        remoteBatchBytes: Int64 = 512 * 1024 * 1024,
        retryDelay: TimeInterval = 3
    ) {
        self.retryDelay = max(0, retryDelay)
        self.parallelTransfers = Self.clamp(parallelTransfers)
        self.copy = copy
        self.remoteVerifier = remoteVerifier
        self.remoteBatchFiles = max(1, remoteBatchFiles)
        self.remoteBatchBytes = max(1, remoteBatchBytes)
    }

    /// The engine before parallel transfers: one file at a time, uncached
    /// writes, a flush per file, SMB re-read. For benchmarks.
    public static let legacy = NASSyncOptions(parallelTransfers: 1, copy: .legacy)

    public static func clamp(_ value: Int) -> Int {
        min(max(value, parallelRange.lowerBound), parallelRange.upperBound)
    }

    /// The options the app's settings describe. NAS-side verification needs
    /// an SSH host and the server path of the share the NAS root is on; the
    /// local side of that mapping is the mount point of `nasRoot`'s volume.
    public static func from(configuration: AppConfiguration, nasRoot: URL) -> NASSyncOptions {
        var options = NASSyncOptions(parallelTransfers: configuration.nasSyncParallelTransfers)
        let host = configuration.nasSyncSSHHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverPrefix = configuration.nasSyncSSHServerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuration.nasSyncVerifyViaSSH, !host.isEmpty, serverPrefix.hasPrefix("/"),
           let mount = (try? nasRoot.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path, mount != "/" {
            options.remoteVerifier = .ssh(host: host, localPrefix: mount, serverPrefix: serverPrefix)
        }
        return options
    }

    var verificationLabel: String {
        remoteVerifier.map { "NAS SHA-256 (\($0.label))" } ?? "SMB re-read"
    }
}

/// One-way Buffer → NAS copy of the files a `NASSyncPlan` lists, each to the
/// same relative path under the NAS mirror root.
///
/// First, one pass over the plan (NAS folder listings only):
/// - verified before at the same size and drive mtime, and the NAS copy
///   still that size → skipped (a resumed sync does not re-read it);
/// - something that is not a file, or a file of another size, at the NAS
///   path → a conflict, never overwritten;
/// - missing folders are created and this sync's own stale temporaries
///   cleared.
///
/// Then up to `parallelTransfers` files at a time:
/// - a same-size file already at the NAS path → both hashed (the NAS copy
///   with `F_NOCACHE`); equal is recorded verified, different is a conflict;
/// - otherwise streamed into a temporary `.<name>.ctsync-<id>` in the
///   destination folder (created exclusively), hashed as it is read from
///   the drive. It is then verified — on the NAS over SSH, a batch at a
///   time, or by re-reading it over SMB — and only an exact SHA-256 match
///   is renamed into place, exclusively, never over a file. A temporary
///   that fails verification is removed (it is this sync's own partial
///   file, never presented as complete) and the file is retried next run.
///
/// No file is flushed on its own (see `NASFileIO.copyNew` for why that is
/// safe): nothing is recorded verified before its hash check.
///
/// A file that fails is recorded and skipped; the job goes on. It stops
/// early only when the NAS itself disappears or the job is stopped, and
/// says how many files were not attempted.
///
/// A `JobHistoryRecorder`, when given, is fed the same progress the Jobs
/// window gets and one row per file as it settles. It only listens: what
/// is copied, verified and reported is the same with or without one.
public struct NASSyncService {
    public typealias Progress = @Sendable (FileOperationProgress) -> Void

    private let store: NASSyncStore?
    private let options: NASSyncOptions
    private let recorder: JobHistoryRecorder?
    private let now: @Sendable () -> Date
    private let clock: @Sendable () -> TimeInterval
    private let isCancelled: () -> Bool

    public init(
        store: NASSyncStore?,
        options: NASSyncOptions = NASSyncOptions(),
        recorder: JobHistoryRecorder? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) {
        self.store = store
        self.options = options
        self.recorder = recorder
        self.now = now
        self.clock = clock
        self.isCancelled = isCancelled
    }

    public func sync(_ plan: NASSyncPlan, nasRoot: URL, progress: Progress? = nil) throws -> NASSyncReport {
        let started = clock()
        let root = nasRoot.standardizedFileURL.path
        guard LayoutMigrationDisk.lstatEntry(root)?.kind == .directory else {
            throw ToolkitError.commandFailed("The NAS folder \(root) is not connected. Nothing was copied.")
        }
        let known = try store?.records(nasRoot: root) ?? [:]
        let recorder = self.recorder
        recorder?.setTotals(files: plan.items.count, bytes: plan.totalBytes)
        // The recorder hears every emission the caller does.
        var reported = progress
        if let recorder {
            reported = { @Sendable update in
                recorder.observe(update)
                progress?(update)
            }
        }
        let run = NASSyncRun(root: root, plan: plan, options: options, now: now, clock: clock, progress: reported, recorder: recorder)
        run.time("Check", lane: NASSyncRun.checkLane)
        let store = self.store
        func flushRecords(force: Bool = false) {
            let batch = run.takePendingRecords(minimum: force ? 1 : 64)
            guard !batch.isEmpty else { return }
            do {
                try store?.upsert(batch)
            } catch {
                // The files themselves are proven on the NAS; a later sync
                // re-derives any state that did not land.
                run.noteCatalogProblem("Could not record sync state in the catalog: \(error.localizedDescription)")
            }
        }
        let tick = {
            flushRecords()
            run.emit("Syncing", force: false)
        }

        // 1. Classify every item from folder listings; create folders.
        var jobs: [NASSyncRun.Job] = []
        var folderListings: [String: [String: DirectoryListingEntry]] = [:]
        var createdFolders = Set<String>()
        func listing(of folder: String) -> [String: DirectoryListingEntry]? {
            if let cached = folderListings[folder] { return cached }
            guard let entries = try? DirectoryListing.list(folder) else { return nil }
            let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            folderListings[folder] = byName
            return byName
        }
        for (index, item) in plan.items.enumerated() {
            // Relative paths come from the planner, but a stale plan must
            // never escape the root.
            guard EventStorageLocations.isLexicallyClean(item.relativePath),
                  (try? PathSafety.validateRelativePath(item.relativePath)) != nil else {
                run.finish(item, failure: "Unsafe relative path.", work: 2 * item.byteCount, record: false)
                continue
            }
            let destination = root + "/" + item.relativePath
            let folder = (destination as NSString).deletingLastPathComponent
            let name = (destination as NSString).lastPathComponent
            run.emit("Checking NAS", path: item.relativePath, force: false)
            // One listing per destination folder answers "is it there, at
            // what size" for every file in it.
            let existing = listing(of: folder)?[name]

            // Resume: verified earlier at this size and drive mtime.
            if let previous = known[NASSyncStore.pathKey(item.relativePath)],
               previous.state == .verified,
               previous.byteCount == item.byteCount,
               previous.sourceModifiedAt.map({ abs($0 - item.modifiedAt) < 0.001 }) == true,
               let existing, existing.kind == .file, existing.size == item.byteCount {
                run.finishAlreadyVerified(item)
                continue
            }
            if let existing {
                guard existing.kind == .file else {
                    run.finishConflict(item, reason: "Something that is not a file is at the NAS path.", detail: "not a file on the NAS")
                    continue
                }
                guard existing.size == item.byteCount else {
                    let reason = "A different file (\(existing.size) bytes, the drive copy is \(item.byteCount)) is already on the NAS. It was not overwritten."
                    run.finishConflict(item, reason: reason, detail: reason)
                    continue
                }
                jobs.append(.init(index: index, item: item, destination: destination, kind: .compareExisting))
                continue
            }
            do {
                for made in try NASFileIO.makeDirectories(folder) where createdFolders.insert(made).inserted {
                    run.noteFolderCreated()
                    folderListings[made] = [:]
                }
            } catch {
                run.finish(item, failure: error.localizedDescription, work: 2 * item.byteCount, record: true)
                if nasIsGone(root) {
                    run.noteStop(Self.disconnected)
                    run.noteNotAttempted(plan.items.count - index - 1)
                    break
                }
                continue
            }
            removeStaleTemporaries(for: name, in: folder, listing: listing(of: folder))
            let temporary = (folder as NSString).appendingPathComponent(".\(name)\(NASSyncPlanner.temporaryMarker)\(UUID().uuidString.prefix(8))")
            jobs.append(.init(index: index, item: item, destination: destination, kind: .copy(temporary: temporary)))
        }
        run.endTime(lane: NASSyncRun.checkLane)
        run.addTiming { $0.checkSeconds = clock() - started }
        flushRecords()

        // 2. Transfers, at most `parallelTransfers` at once.
        let pool = NASTransferPool(width: options.parallelTransfers)
        for (position, job) in jobs.enumerated() {
            if run.isStopped {
                run.noteNotAttempted(jobs.count - position)
                break
            }
            pool.acquire(tick: tick)
            if isCancelled() {
                pool.release()
                run.noteNotAttempted(jobs.count - position)
                run.noteStop("Stopped before \(job.item.relativePath).")
                break
            }
            if run.isStopped {
                pool.release()
                run.noteNotAttempted(jobs.count - position)
                break
            }
            pool.submitAcquired { run.perform(job) }
        }
        pool.waitForAll(tick: tick)
        run.clearTransferRows()
        // The last partial NAS-side batch.
        run.verifyRemainingBatch()
        run.waitForVerification(tick: tick)
        flushRecords(force: true)
        run.addTiming { $0.wallSeconds = clock() - started }
        run.emit("Done", force: true)
        let report = run.finalReport()
        recorder?.noteSyncReport(
            report,
            phases: run.phaseTotals(),
            transferBytes: run.transferredBytes,
            configuration: run.configuration,
            verifyMethod: options.remoteVerifier == nil ? "smb" : "ssh"
        )
        return report
    }

    static let disconnected = "The NAS disconnected. Sync again once it is back; verified files are skipped."

    /// A crashed or quit sync can leave its own `.<name>.ctsync-<id>`
    /// temporary behind. Only exactly that pattern, for exactly this file
    /// name, is removed — never anything else.
    private func removeStaleTemporaries(for name: String, in folder: String, listing: [String: DirectoryListingEntry]?) {
        let prefix = ".\(name)\(NASSyncPlanner.temporaryMarker)"
        for entry in (listing ?? [:]).values where entry.kind == .file && entry.name.hasPrefix(prefix)
            && entry.name.count == prefix.count + 8 {
            unlink((folder as NSString).appendingPathComponent(entry.name))
        }
    }
}

func nasIsGone(_ root: String) -> Bool {
    LayoutMigrationDisk.lstatEntry(root)?.kind != .directory || !VolumeInfo.isAvailable(URL(fileURLWithPath: root))
}

/// A fixed number of concurrent slots on a global queue. The caller takes a
/// slot (`acquire`) before it submits; the slot is given back when the work
/// ends, so no more than `width` pieces of work ever run at once.
final class NASTransferPool: @unchecked Sendable {
    let width: Int
    private let slots: DispatchSemaphore
    private let group = DispatchGroup()
    private let queue = DispatchQueue(label: "CameraToolkit.NASSync.transfers", qos: .utility, attributes: .concurrent)

    init(width: Int) {
        self.width = max(1, width)
        slots = DispatchSemaphore(value: self.width)
    }

    /// Waits for a free slot, calling `tick` on this thread while it waits.
    func acquire(tick: () -> Void) {
        while slots.wait(timeout: .now() + 0.2) == .timedOut { tick() }
    }

    func release() { slots.signal() }

    func submitAcquired(_ work: @escaping @Sendable () -> Void) {
        group.enter()
        queue.async {
            work()
            self.slots.signal()
            self.group.leave()
        }
    }

    func waitForAll(tick: () -> Void) {
        while group.wait(timeout: .now() + 0.2) == .timedOut { tick() }
    }
}

/// The shared state of one sync run. Transfers run on pool threads; every
/// mutation goes through `lock`.
final class NASSyncRun: @unchecked Sendable {
    struct Job: Sendable {
        enum Kind: Sendable {
            case compareExisting
            case copy(temporary: String)
        }
        var index: Int
        var item: NASSyncItem
        var destination: String
        var kind: Kind
    }

    /// A temporary written and hashed, waiting for verification.
    struct Written: Sendable {
        var job: Job
        var temporary: String
        var sourceHash: String
    }

    let root: String
    let totalFiles: Int
    let options: NASSyncOptions
    let now: @Sendable () -> Date
    let clock: @Sendable () -> TimeInterval
    let progress: NASSyncService.Progress?
    let recorder: JobHistoryRecorder?

    private let lock = NSLock()
    private var report = NASSyncReport()
    private var pending: [NASSyncRecord] = []
    private var doneWork: Int64 = 0
    private var totalWork: Int64
    private var finishedFiles = 0
    /// One row per parallel transfer (`0..<parallelTransfers`), plus the
    /// NAS-side verification thread's row at `verifyLane`. A finished
    /// transfer's row stays, showing how it ended, until the next file
    /// takes it — so rows never blink out between files.
    private var rows: [Row?]
    /// Where the time goes, per phase, summed over the lanes (the
    /// transfer rows, the verification thread and the check pass).
    private var phases = JobPhaseLedger(order: NASSyncRun.phaseOrder)
    /// Bytes moved over the link: copies and SMB re-reads.
    private var transferBytes: Int64 = 0
    private let startedAt: TimeInterval
    private var stopReason: String?
    private var nasGone = false
    private var batch: [Written] = []
    private var batchBytes: Int64 = 0
    /// About 4 progress emissions a second, whatever the chunk rate.
    private var limiter = FileOperationProgressLimiter(minimumInterval: 0.25)
    private let verifyQueue = DispatchQueue(label: "CameraToolkit.NASSync.remoteVerify", qos: .utility)
    private let verifyGroup = DispatchGroup()
    /// Per-file timing for the recorder's file rows, by relative path.
    /// Only kept when there is a recorder.
    private var traces: [String: FileTrace] = [:]

    /// When a file took a transfer, which one, and how long its copy and
    /// verification took.
    struct FileTrace: Sendable {
        var start: Double
        var slot: Int
        var copySeconds: Double?
        var verifySeconds: Double?
        var verifyMethod: String?
    }

    init(root: String, plan: NASSyncPlan, options: NASSyncOptions, now: @escaping @Sendable () -> Date, clock: @escaping @Sendable () -> TimeInterval, progress: NASSyncService.Progress?, recorder: JobHistoryRecorder? = nil) {
        self.root = root
        self.totalFiles = plan.items.count
        self.options = options
        self.now = now
        self.clock = clock
        self.progress = progress
        self.recorder = recorder
        // Work in bytes: a copy reads the drive copy, then the NAS copy is
        // read once more (over SMB, or by the NAS itself); a match hashes
        // both. Skips take their bytes off the total.
        totalWork = plan.items.reduce(Int64(0)) { $0 + 2 * $1.byteCount }
        report.timings.parallelTransfers = options.parallelTransfers
        report.timings.verification = options.verificationLabel
        report.timings.flushEachFile = options.copy.flushEachFile
        rows = Array(repeating: nil, count: options.parallelTransfers + 1)
        startedAt = clock()
    }

    // MARK: Phases and rows

    /// Phase labels, in display order. "Flush" is only ever timed by the
    /// legacy engine; "Remote verify (NAS)" only with SSH verification.
    static let phaseOrder = ["Check", "Copy", "Flush", "Verify", remoteVerifyPhase, "Hash", "Rename"]
    static let remoteVerifyPhase = "Remote verify (NAS)"
    /// Phases whose bytes cross the link — the combined transfer speed.
    static let linkPhases: Set<String> = ["Copy", "Verify"]
    /// The planning pass's lane in the phase ledger.
    static let checkLane = -1
    /// The NAS-side verification thread's row and lane.
    var verifyLane: Int { options.parallelTransfers }

    /// What a transfer row shows.
    struct Row: Sendable {
        var name: String
        var path: String
        var step: String
        var phase: String
        var bytesDone: Int64
        var bytesTotal: Int64
        var busy: Bool
        /// Everything this row has moved, for its rate meter.
        var moved: Int64 = 0
        var meter = TransferRateMeter()
    }

    /// One-line configuration for the Jobs window.
    var configuration: String {
        let count = options.parallelTransfers
        var parts = ["\(count) transfer\(count == 1 ? "" : "s") in parallel", options.remoteVerifier == nil ? "SMB verify" : "SSH verify"]
        if options.copy.flushEachFile { parts.append("flush per file") }
        return parts.joined(separator: " · ")
    }

    func time(_ label: String, lane: Int) {
        let t = clock()
        lock.withLock { phases.begin(label, lane: lane, at: t) }
    }

    func endTime(lane: Int) {
        let t = clock()
        lock.withLock { phases.end(lane: lane, at: t) }
    }

    /// The lowest transfer row no file is using. The pool never runs more
    /// than `parallelTransfers` jobs, so one is always free.
    private func takeSlot(for job: Job) -> Int {
        let start = recorder?.elapsed()
        return lock.withLock {
            let slot = (0..<options.parallelTransfers).first { rows[$0]?.busy != true } ?? 0
            // Claimed in the same lock, so two transfers never share a row.
            // The row's meter and byte history carry over to the next file.
            var row = rows[slot] ?? Row(name: "", path: "", step: "", phase: "", bytesDone: 0, bytesTotal: 0, busy: true)
            row.name = (job.item.relativePath as NSString).lastPathComponent
            row.path = job.item.relativePath
            row.step = "Starting"
            row.phase = "Starting"
            row.bytesDone = 0
            row.bytesTotal = job.item.byteCount
            row.busy = true
            rows[slot] = row
            if let start { traces[job.item.relativePath] = FileTrace(start: start, slot: slot) }
            return slot
        }
    }

    /// Puts `name` on `slot`'s row in a new phase, and times that phase.
    private func show(_ slot: Int, name: String, path: String, step: String, phase: String, total: Int64, done: Int64 = 0, timing: String?) {
        let t = clock()
        lock.withLock {
            var row = rows[slot] ?? Row(name: name, path: path, step: step, phase: phase, bytesDone: 0, bytesTotal: total, busy: true)
            row.name = name
            row.path = path
            row.step = step
            row.phase = phase
            row.bytesDone = done
            row.bytesTotal = total
            row.busy = true
            rows[slot] = row
            if let timing { phases.begin(timing, lane: slot, at: t) }
        }
        emit(step, path: path, force: false)
    }

    private func show(_ slot: Int, _ job: Job, step: String, phase: String, done: Int64 = 0, timing: String?) {
        show(slot, name: (job.item.relativePath as NSString).lastPathComponent, path: job.item.relativePath, step: step, phase: phase, total: job.item.byteCount, done: done, timing: timing)
    }

    /// The row's file is done with this lane. A transfer row keeps showing
    /// `outcome` until the next file takes it; the verification row goes.
    private func release(_ slot: Int, outcome: String) {
        let t = clock()
        lock.withLock {
            phases.end(lane: slot, at: t)
            if slot < options.parallelTransfers {
                rows[slot]?.busy = false
                rows[slot]?.step = outcome
                rows[slot]?.phase = outcome
            } else {
                rows[slot] = nil
            }
        }
        emit("Syncing", force: false)
    }

    /// All transfers are done; only NAS-side verification may remain.
    func clearTransferRows() {
        lock.withLock {
            for slot in 0..<options.parallelTransfers { rows[slot] = nil }
        }
    }

    // MARK: State

    var isStopped: Bool { lock.withLock { nasGone || stopReason != nil } }

    func finalReport() -> NASSyncReport {
        lock.withLock {
            var final = report
            final.stoppedReason = stopReason ?? final.stoppedReason
            return final
        }
    }

    /// Busy time and bytes per phase so far, for the recorder's summary.
    func phaseTotals() -> [JobPhaseTotal] {
        let t = clock()
        return lock.withLock { phases.snapshot(at: t) }
    }

    var transferredBytes: Int64 { lock.withLock { transferBytes } }

    /// Adds to the file's trace; nothing without a recorder.
    private func trace(_ item: NASSyncItem, _ change: (inout FileTrace) -> Void) {
        guard recorder != nil else { return }
        lock.withLock {
            guard var trace = traces[item.relativePath] else { return }
            change(&trace)
            traces[item.relativePath] = trace
        }
    }

    /// Hands the recorder the settled file's row. Called after the lock
    /// that settled it is released; nothing without a recorder.
    private func settle(_ item: NASSyncItem, _ outcome: JobHistoryItemOutcome, error: String? = nil) {
        guard let recorder else { return }
        let end = recorder.elapsed()
        let trace = lock.withLock { traces.removeValue(forKey: item.relativePath) }
        recorder.fileSettled(JobHistoryItem(
            relativePath: item.relativePath,
            byteCount: item.byteCount,
            start: trace?.start,
            end: end,
            slot: trace?.slot,
            outcome: outcome,
            verifyMethod: trace?.verifyMethod,
            copySeconds: trace?.copySeconds,
            verifySeconds: trace?.verifySeconds,
            error: error
        ))
    }

    func takePendingRecords(minimum: Int) -> [NASSyncRecord] {
        lock.withLock {
            guard pending.count >= minimum else { return [] }
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
    }

    func noteStop(_ reason: String) {
        lock.withLock { if stopReason == nil { stopReason = reason } }
    }

    /// Recorded in the report without stopping: the files are proven on
    /// the NAS either way, and a later sync re-derives the state.
    func noteCatalogProblem(_ reason: String) {
        lock.withLock { if report.stoppedReason == nil { report.stoppedReason = reason } }
    }

    func noteNotAttempted(_ count: Int) {
        lock.withLock { report.notAttempted += count }
    }

    func noteFolderCreated() {
        lock.withLock { report.foldersCreated += 1 }
    }

    func addTiming(_ change: (inout NASSyncTimings) -> Void) {
        lock.withLock { change(&report.timings) }
    }

    /// Credits bytes to the job, to `phase` and to `slot`'s row.
    private func addWork(_ bytes: Int, _ phase: String, slot: Int?) {
        let count = Int64(bytes)
        lock.withLock {
            doneWork += count
            phases.addBytes(count, to: phase)
            if Self.linkPhases.contains(phase) { transferBytes += count }
            if let slot {
                rows[slot]?.bytesDone += count
                rows[slot]?.moved += count
            }
        }
    }

    private func appendRecord(_ item: NASSyncItem, _ state: NASSyncRecord.State, sha: String?, nasSHA: String?, detail: String?, verified: Bool) {
        let timestamp = now()
        pending.append(NASSyncRecord(
            nasRoot: root,
            relativePath: item.relativePath,
            eventID: item.eventID,
            byteCount: item.byteCount,
            sourceModifiedAt: item.modifiedAt,
            sha256: sha,
            nasSHA256: nasSHA,
            state: state,
            detail: detail,
            checkedAt: timestamp,
            verifiedAt: verified ? timestamp : nil
        ))
    }

    /// Settles a file that failed; `work` is the part of its planned work
    /// that will now never be done.
    func finish(_ item: NASSyncItem, failure: String, work: Int64, record: Bool, mismatch: Bool = false) {
        lock.withLock {
            report.failed.append(NASSyncIssue(path: item.relativePath, reason: failure))
            if mismatch { report.hashMismatches.append(NASSyncIssue(path: item.relativePath, reason: failure)) }
            if record { appendRecord(item, .failed, sha: nil, nasSHA: nil, detail: failure, verified: false) }
            totalWork -= work
            finishedFiles += 1
        }
        settle(item, .failed, error: failure)
    }

    func finishAlreadyVerified(_ item: NASSyncItem) {
        lock.withLock {
            report.alreadyVerified.append(item.relativePath)
            totalWork -= 2 * item.byteCount
            finishedFiles += 1
        }
        settle(item, .alreadyVerified)
        emit("Already verified", path: item.relativePath, force: false)
    }

    func finishConflict(_ item: NASSyncItem, reason: String, detail: String, sha: String? = nil, nasSHA: String? = nil, unfinishedWork: Int64? = nil) {
        lock.withLock {
            report.conflicts.append(NASSyncIssue(path: item.relativePath, reason: reason))
            appendRecord(item, .conflict, sha: sha, nasSHA: nasSHA, detail: detail, verified: false)
            totalWork -= unfinishedWork ?? 2 * item.byteCount
            finishedFiles += 1
        }
        settle(item, .conflict, error: reason)
    }

    private func finishMatched(_ item: NASSyncItem, sha: String) {
        lock.withLock {
            report.matchedExisting.append(item.relativePath)
            appendRecord(item, .verified, sha: sha, nasSHA: nil, detail: nil, verified: true)
            finishedFiles += 1
        }
        settle(item, .matched)
    }

    private func finishCopied(_ item: NASSyncItem, sha: String) {
        lock.withLock {
            report.copied.append(item.relativePath)
            report.bytesCopied += item.byteCount
            appendRecord(item, .verified, sha: sha, nasSHA: nil, detail: nil, verified: true)
            finishedFiles += 1
        }
        settle(item, .copied)
    }

    // MARK: Progress

    func emit(_ phase: String, path: String? = nil, force: Bool) {
        guard let progress else { return }
        let t = clock()
        let snapshot: FileOperationProgress? = lock.withLock {
            guard limiter.shouldEmit(force: force) else { return nil }
            var items: [JobActiveItem] = []
            for slot in rows.indices {
                guard var row = rows[slot] else { continue }
                row.meter.record(row.moved, at: t)
                rows[slot] = row
                items.append(JobActiveItem(
                    name: row.name,
                    path: row.path,
                    step: row.step,
                    slot: slot,
                    phase: row.phase,
                    bytesDone: row.bytesDone,
                    bytesTotal: row.bytesTotal,
                    bytesPerSecond: row.meter.bytesPerSecond
                ))
            }
            let shown = path ?? items.first { rows[$0.slot ?? 0]?.busy == true }?.path ?? ""
            // Time left at the job's average speed, once past a 15 s warm-up.
            let elapsed = t - startedAt
            let remaining = Double(max(totalWork - doneWork, 0))
            let secondsRemaining: Double? = elapsed < 15 ? nil
                : remaining == 0 ? 0
                : doneWork > 0 ? remaining / (Double(doneWork) / elapsed) : nil
            let counters = [
                JobCounter(label: "Copied", value: report.copied.count),
                JobCounter(label: "Already on NAS", value: report.matchedExisting.count + report.alreadyVerified.count),
                JobCounter(label: "Conflicts", value: report.conflicts.count),
                JobCounter(label: "Failed", value: report.failed.count),
            ]
            var facts = ["\(options.parallelTransfers) parallel", "Verify: \(options.verificationLabel)"]
            if options.copy.flushEachFile { facts.append("Flush per file") }
            facts.append(report.timings.phaseSummary)
            return FileOperationProgress(
                phase: phase,
                currentPath: (shown as NSString).lastPathComponent,
                processedFiles: finishedFiles,
                totalFiles: totalFiles,
                processedBytes: doneWork,
                totalBytes: totalWork,
                bytesPerSecond: elapsed > 0 ? Double(transferBytes) / elapsed : 0,
                telemetry: JobTelemetry(
                    step: phase,
                    activeItems: items,
                    counters: counters,
                    facts: facts,
                    work: JobWorkEstimate(
                        unitsDone: Int(doneWork),
                        unitsTotal: Int(totalWork),
                        secondsRemaining: secondsRemaining
                    ),
                    phases: phases.snapshot(at: t),
                    configuration: configuration,
                    transferBytes: transferBytes
                )
            )
        }
        if let snapshot { progress(snapshot) }
    }

    // MARK: Work (pool threads)

    func perform(_ job: Job) {
        let slot = takeSlot(for: job)
        switch job.kind {
        case .compareExisting: compareExisting(job, slot: slot)
        case .copy(let temporary): copy(job, temporary: temporary, slot: slot)
        }
    }

    /// How a finished file's row reads until the next file takes it.
    private func outcome(of item: NASSyncItem) -> String {
        lock.withLock {
            // Only the files settled since this one can be after it.
            let recent = options.parallelTransfers + 1
            if report.failed.suffix(recent).contains(where: { $0.path == item.relativePath }) { return "Failed" }
            if report.conflicts.suffix(recent).contains(where: { $0.path == item.relativePath }) { return "Conflict" }
            return "Verified"
        }
    }

    private func failed(_ job: Job, _ error: Error, work: Int64, mismatch: Bool = false) {
        finish(job.item, failure: error.localizedDescription, work: work, record: true, mismatch: mismatch)
        if nasIsGone(root) {
            lock.withLock {
                nasGone = true
                if stopReason == nil { stopReason = NASSyncService.disconnected }
            }
        }
    }

    private func compareExisting(_ job: Job, slot: Int) {
        let item = job.item
        var done: Int64 = 0
        do {
            // With SSH verification the NAS hashes its copy on its own disk
            // while this Mac hashes the drive copy, so nothing crosses the
            // link; a file the NAS cannot answer for is re-read over SMB.
            let remote = options.remoteVerifier.map { verifier in
                RemoteHash(verifier: verifier, path: job.destination)
            }
            show(slot, job, step: remote == nil ? "Hashing drive copy" : "Hashing drive copy and NAS copy", phase: "Hashing", timing: "Hash")
            let start = clock()
            let sourceHash = try NASFileIO.sha256(item.sourcePath, uncached: false, expectedByteCount: item.byteCount) { self.addWork($0, "Hash", slot: slot); done += Int64($0); self.emit("Hashing drive copy", force: false) }
            let nasHash: String
            if let remote, let hash = remote.wait() {
                addWork(Int(item.byteCount), Self.remoteVerifyPhase, slot: slot)
                done += item.byteCount
                let seconds = clock() - start
                addTiming {
                    $0.verifySeconds += seconds
                    $0.remoteVerifyBytes += item.byteCount
                }
                trace(item) { $0.verifySeconds = seconds; $0.verifyMethod = "ssh" }
                nasHash = hash
            } else {
                if let remote {
                    addTiming {
                        $0.remoteFallbacks += 1
                        if $0.remoteFallbackReason == nil { $0.remoteFallbackReason = remote.failure }
                    }
                }
                show(slot, job, step: "Re-reading NAS copy", phase: "Verifying", timing: "Verify")
                nasHash = try NASFileIO.sha256(job.destination, uncached: true, expectedByteCount: item.byteCount) { self.addWork($0, "Verify", slot: slot); done += Int64($0); self.emit("Re-reading NAS copy", force: false) }
                let seconds = clock() - start
                addTiming { $0.verifySeconds += seconds; $0.smbVerifyBytes += item.byteCount }
                trace(item) { $0.verifySeconds = seconds; $0.verifyMethod = "smb" }
            }
            if sourceHash == nasHash {
                finishMatched(item, sha: sourceHash)
            } else {
                let reason = "A different file with the same size is already on the NAS. It was not overwritten."
                finishConflict(item, reason: reason, detail: reason, sha: sourceHash, nasSHA: nasHash, unfinishedWork: 0)
            }
        } catch {
            failed(job, error, work: 2 * item.byteCount - done)
        }
        release(slot, outcome: outcome(of: item))
    }

    private func copy(_ job: Job, temporary firstTemporary: String, slot: Int) {
        let item = job.item
        var done: Int64 = 0
        do {
            show(slot, job, step: "Copying to NAS", phase: "Copying", timing: "Copy")
            var temporary = firstTemporary
            var retried = false
            var copied: NASFileIO.CopyResult?
            while copied == nil {
                do {
                    copied = try NASFileIO.copyNew(
                        from: item.sourcePath,
                        to: temporary,
                        expectedByteCount: item.byteCount,
                        options: options.copy,
                        clock: clock,
                        progress: {
                            self.addWork($0, "Copy", slot: slot)
                            done += Int64($0)
                            self.emit("Copying to NAS", force: false)
                        },
                        // Only the legacy engine flushes; the fast one never calls this.
                        willFlush: {
                            self.show(slot, job, step: "Flushing to NAS", phase: "Flushing", done: item.byteCount, timing: "Flush")
                        }
                    )
                } catch {
                    // By path, never through a descriptor: this sync's own
                    // partial file is never presented as complete.
                    unlink(temporary)
                    guard !retried, let transient = error as? NASFileIO.TransientIOError, canRetryCopy() else {
                        if retried {
                            throw ToolkitError.commandFailed("\(error.localizedDescription) The copy had already been retried once.")
                        }
                        throw error
                    }
                    retried = true
                    noteRetry(item, transient, redoing: done)
                    done = 0
                    Thread.sleep(forTimeInterval: options.retryDelay)
                    temporary = Self.freshTemporary(replacing: temporary)
                    show(slot, job, step: "Copying to NAS again", phase: "Copying", timing: "Copy")
                }
            }
            guard let result = copied else { throw ToolkitError.commandFailed("The copy did not finish.") }
            addTiming {
                $0.copySeconds += result.copySeconds
                $0.flushSeconds += result.flushSeconds
                $0.copyBytes += item.byteCount
            }
            trace(item) { $0.copySeconds = result.copySeconds + result.flushSeconds }
            // The drive copy must be the file the plan saw.
            if let current = LayoutMigrationDisk.lstatEntry(item.sourcePath),
               current.size != item.byteCount || abs(current.modifiedAt - item.modifiedAt) >= 0.001 {
                unlink(temporary)
                throw ToolkitError.commandFailed("The drive copy changed while it was copied.")
            }
            _ = setModificationTime(temporary, item.modifiedAt)
            let written = Written(job: job, temporary: temporary, sourceHash: result.sha256)
            if options.remoteVerifier != nil {
                release(slot, outcome: "Queued for NAS verify")
                enqueueForRemoteVerification(written)
                return
            }
            verifyOverSMBAndPlace(written, slot: slot)
            release(slot, outcome: outcome(of: item))
        } catch {
            failed(job, error, work: 2 * item.byteCount - done)
            release(slot, outcome: "Failed")
        }
    }

    /// A retry only makes sense while the share is still mounted and the
    /// job has not been stopped; otherwise the failure stands.
    private func canRetryCopy() -> Bool {
        !isStopped && !nasIsGone(root)
    }

    /// Records a retry in the report and the timings. The bytes the failed
    /// attempt already counted are added to the total work, so progress
    /// never runs past 100 % while they are copied again.
    private func noteRetry(_ item: NASSyncItem, _ error: NASFileIO.TransientIOError, redoing bytes: Int64) {
        lock.withLock {
            report.retried.append(NASSyncIssue(
                path: item.relativePath,
                reason: "\(error.localizedDescription) The temporary was removed and the file was copied again from a fresh open after \(Int(options.retryDelay.rounded())) s."
            ))
            report.timings.transientRetries = (report.timings.transientRetries ?? 0) + 1
            totalWork += bytes
        }
    }

    /// A new `.<name>.ctsync-<id>` next to the one that failed, so the retry
    /// never meets a leftover of the first attempt.
    static func freshTemporary(replacing temporary: String) -> String {
        String(temporary.dropLast(8)) + UUID().uuidString.prefix(8)
    }

    /// Re-reads the temporary over SMB (uncached) and renames it in on a match.
    /// The caller releases `slot`.
    private func verifyOverSMBAndPlace(_ written: Written, slot: Int) {
        let job = written.job
        let item = job.item
        var done: Int64 = 0
        do {
            show(slot, job, step: "Re-reading NAS copy", phase: "Verifying", timing: "Verify")
            let start = clock()
            let nasHash = try NASFileIO.sha256(written.temporary, uncached: true, expectedByteCount: item.byteCount) {
                self.addWork($0, "Verify", slot: slot)
                done += Int64($0)
                self.emit("Re-reading NAS copy", force: false)
            }
            let seconds = clock() - start
            addTiming { $0.verifySeconds += seconds; $0.smbVerifyBytes += item.byteCount }
            trace(item) { $0.verifySeconds = ($0.verifySeconds ?? 0) + seconds; $0.verifyMethod = "smb" }
            try check(written, nasHash: nasHash, how: "when re-read from the NAS")
            try place(written, slot: slot)
        } catch let error as MismatchError {
            failed(job, error, work: item.byteCount - done, mismatch: true)
        } catch {
            unlink(written.temporary)
            failed(job, error, work: item.byteCount - done)
        }
    }

    private struct MismatchError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private func check(_ written: Written, nasHash: String, how: String) throws {
        guard nasHash == written.sourceHash else {
            unlink(written.temporary)
            throw MismatchError(message: "SHA-256 MISMATCH: the NAS copy did not verify — its SHA-256 (\(nasHash)) differs from the drive copy's (\(written.sourceHash)) \(how). The NAS copy was removed; the drive copy is untouched and the next sync copies it again.")
        }
    }

    /// Renames a verified temporary into place, never over a file.
    private func place(_ written: Written, slot: Int) throws {
        let job = written.job
        let item = job.item
        show(slot, job, step: "Renaming into place", phase: "Renaming", done: item.byteCount, timing: "Rename")
        let start = clock()
        defer { addTiming { $0.renameSeconds += self.clock() - start } }
        do {
            try NASFileIO.renameExclusive(from: written.temporary, to: job.destination)
        } catch {
            // Someone else put a file there meanwhile: compare, never replace.
            guard LayoutMigrationDisk.lstatEntry(job.destination) != nil else { throw error }
            time("Verify", lane: slot)
            let other = try NASFileIO.sha256(job.destination, uncached: true)
            unlink(written.temporary)
            if other == written.sourceHash {
                finishMatched(item, sha: written.sourceHash)
            } else {
                let reason = "A different file appeared at the NAS path during the copy. It was not overwritten."
                finishConflict(item, reason: reason, detail: reason, sha: written.sourceHash, nasSHA: other, unfinishedWork: 0)
            }
            return
        }
        guard LayoutMigrationDisk.lstatEntry(job.destination).map({ $0.kind == .file && $0.size == item.byteCount }) == true else {
            throw ToolkitError.commandFailed("The NAS copy is not at its final path after the rename.")
        }
        finishCopied(item, sha: written.sourceHash)
    }

    // MARK: NAS-side verification

    private func enqueueForRemoteVerification(_ written: Written) {
        let full: [Written]? = lock.withLock {
            batch.append(written)
            batchBytes += written.job.item.byteCount
            guard batch.count >= options.remoteBatchFiles || batchBytes >= options.remoteBatchBytes else { return nil }
            defer { batch = []; batchBytes = 0 }
            return batch
        }
        if let full { submitRemote(full) }
    }

    func verifyRemainingBatch() {
        let rest: [Written] = lock.withLock {
            defer { batch = []; batchBytes = 0 }
            return batch
        }
        if !rest.isEmpty { submitRemote(rest) }
    }

    func waitForVerification(tick: () -> Void) {
        while verifyGroup.wait(timeout: .now() + 0.2) == .timedOut { tick() }
    }

    private func submitRemote(_ written: [Written]) {
        verifyGroup.enter()
        verifyQueue.async {
            self.verifyRemote(written)
            self.verifyGroup.leave()
        }
    }

    /// One `sync` + `sha256sum` on the NAS for the whole batch. A file the
    /// NAS could not answer for (SSH down, path not mapped) is re-read over
    /// SMB instead; only a hash that differs fails a file.
    private func verifyRemote(_ written: [Written]) {
        guard let verifier = options.remoteVerifier, let first = written.first else { return }
        let lane = verifyLane
        let batchBytes = written.reduce(Int64(0)) { $0 + $1.job.item.byteCount }
        show(
            lane,
            name: written.count == 1 ? (first.job.item.relativePath as NSString).lastPathComponent : "\(written.count) files",
            path: first.job.item.relativePath,
            step: "Hashing on NAS",
            phase: "Verifying on NAS",
            total: batchBytes,
            timing: Self.remoteVerifyPhase
        )
        let start = clock()
        var hashes: [String: String] = [:]
        var failure: String?
        do {
            hashes = try verifier.hashes(localPaths: written.map(\.temporary))
        } catch {
            failure = error.localizedDescription
        }
        let elapsed = clock() - start
        addTiming {
            $0.verifySeconds += elapsed
            $0.remoteBatches += 1
        }
        for entry in written {
            let item = entry.job.item
            guard let nasHash = hashes[entry.temporary] else {
                addTiming {
                    $0.remoteFallbacks += 1
                    if $0.remoteFallbackReason == nil {
                        $0.remoteFallbackReason = failure ?? "The NAS could not hash \((entry.temporary as NSString).lastPathComponent) at its mapped server path."
                    }
                }
                verifyOverSMBAndPlace(entry, slot: lane)
                continue
            }
            addWork(Int(item.byteCount), Self.remoteVerifyPhase, slot: lane)
            addTiming { $0.remoteVerifyBytes += item.byteCount }
            // One NAS call answers the whole batch; each file is charged
            // its share of it by size.
            let share = batchBytes > 0 ? elapsed * Double(item.byteCount) / Double(batchBytes) : elapsed / Double(written.count)
            trace(item) { $0.verifySeconds = share; $0.verifyMethod = "ssh" }
            do {
                try check(entry, nasHash: nasHash, how: "when hashed on the NAS")
                try place(entry, slot: lane)
            } catch let error as MismatchError {
                failed(entry.job, error, work: 0, mismatch: true)
            } catch {
                unlink(entry.temporary)
                failed(entry.job, error, work: 0)
            }
        }
        release(lane, outcome: "Verified")
    }
}

/// One NAS-side hash running in the background while the drive copy is
/// hashed here. `wait()` is nil when the NAS could not answer.
private final class RemoteHash: @unchecked Sendable {
    private let group = DispatchGroup()
    private var hash: String?
    private(set) var failure: String?

    init(verifier: NASRemoteVerifier, path: String) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            do {
                self.hash = try verifier.hashes(localPaths: [path])[path]
                if self.hash == nil {
                    self.failure = "The NAS could not hash \((path as NSString).lastPathComponent) at its mapped server path."
                }
            } catch {
                self.failure = error.localizedDescription
            }
            self.group.leave()
        }
    }

    func wait() -> String? {
        group.wait()
        return hash
    }
}

private func setModificationTime(_ path: String, _ modifiedAt: Double) -> Bool {
    let date = Date(timeIntervalSinceReferenceDate: modifiedAt)
    return (try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)) != nil
}
