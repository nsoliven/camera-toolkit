import Foundation

/// How a recorded job ended. `running` is only ever seen on a job that is
/// still going — or, after a crash or quit, until the next launch marks it
/// `interrupted`.
public enum JobHistoryOutcome: String, Codable, CaseIterable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
    case interrupted
}

/// One recorded job — a row of the `jobs` table.
public struct JobHistoryJob: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    /// The job's kind — `JobAction.rawValue` ("syncBuffer", "faceScan").
    public var kind: String
    public var title: String
    public var startedAt: Date
    /// Nil while the job runs.
    public var endedAt: Date?
    public var outcome: JobHistoryOutcome
    public var totalFiles: Int
    public var totalBytes: Int64
    /// The job's own byte counter at the end — for Sync to NAS, the bytes
    /// copied to the NAS.
    public var bytesDone: Int64
    /// Bytes every parallel transfer together moved over the link (a
    /// sync's copies and SMB re-reads); nil for jobs without that counter.
    public var transferBytes: Int64?
    public var copied: Int
    public var matchedExisting: Int
    public var alreadyVerified: Int
    public var conflicts: Int
    public var failed: Int
    /// "4 transfers in parallel · SSH verify".
    public var configuration: String?
    public var summary: JobHistorySummary?

    public init(
        id: UUID = UUID(),
        kind: String,
        title: String,
        startedAt: Date,
        endedAt: Date? = nil,
        outcome: JobHistoryOutcome = .running,
        totalFiles: Int = 0,
        totalBytes: Int64 = 0,
        bytesDone: Int64 = 0,
        transferBytes: Int64? = nil,
        copied: Int = 0,
        matchedExisting: Int = 0,
        alreadyVerified: Int = 0,
        conflicts: Int = 0,
        failed: Int = 0,
        configuration: String? = nil,
        summary: JobHistorySummary? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
        self.bytesDone = bytesDone
        self.transferBytes = transferBytes
        self.copied = copied
        self.matchedExisting = matchedExisting
        self.alreadyVerified = alreadyVerified
        self.conflicts = conflicts
        self.failed = failed
        self.configuration = configuration
        self.summary = summary
    }

    /// Wall seconds from start to end (or to `now` while running).
    public func duration(now: Date = Date()) -> TimeInterval {
        max((endedAt ?? now).timeIntervalSince(startedAt), 0)
    }

    /// Bytes per second over the whole job: the combined link counter when
    /// the job has one (what the live pane's "average · combined" shows),
    /// else the job's own byte counter. Nil before a second has passed or
    /// when nothing moved.
    public func averageBytesPerSecond(now: Date = Date()) -> Double? {
        let seconds = summary?.timings?.wallSeconds ?? duration(now: now)
        let moved = transferBytes ?? bytesDone
        guard seconds >= 1, moved > 0 else { return nil }
        return Double(moved) / seconds
    }
}

/// The detail a job's row keeps as JSON: where the time went, how it
/// verified, why it stopped. Everything optional, so older rows and jobs
/// that measure less still decode.
public struct JobHistorySummary: Codable, Equatable, Hashable, Sendable {
    /// Busy time and bytes per phase at the end (Sync to NAS).
    public var phases: [JobPhaseTotal]
    /// Sync to NAS's own timings and verification counters.
    public var timings: NASSyncTimings?
    /// "ssh" or "smb" for Sync to NAS.
    public var verifyMethod: String?
    public var stoppedReason: String?
    public var notAttempted: Int?
    public var hashMismatches: Int?
    public var foldersCreated: Int?
    /// The job's closing note — its summary line, or the error it failed on.
    public var note: String?

    public init(
        phases: [JobPhaseTotal] = [],
        timings: NASSyncTimings? = nil,
        verifyMethod: String? = nil,
        stoppedReason: String? = nil,
        notAttempted: Int? = nil,
        hashMismatches: Int? = nil,
        foldersCreated: Int? = nil,
        note: String? = nil
    ) {
        self.phases = phases
        self.timings = timings
        self.verifyMethod = verifyMethod
        self.stoppedReason = stoppedReason
        self.notAttempted = notAttempted
        self.hashMismatches = hashMismatches
        self.foldersCreated = foldersCreated
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phases = try container.decodeIfPresent([JobPhaseTotal].self, forKey: .phases) ?? []
        timings = try container.decodeIfPresent(NASSyncTimings.self, forKey: .timings)
        verifyMethod = try container.decodeIfPresent(String.self, forKey: .verifyMethod)
        stoppedReason = try container.decodeIfPresent(String.self, forKey: .stoppedReason)
        notAttempted = try container.decodeIfPresent(Int.self, forKey: .notAttempted)
        hashMismatches = try container.decodeIfPresent(Int.self, forKey: .hashMismatches)
        foldersCreated = try container.decodeIfPresent(Int.self, forKey: .foldersCreated)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

/// One second of a job — a row of `job_samples`. Rates are decimal MB/s
/// (as the live pane shows them), each measured the way the live chart
/// measures it: the combined rate over the last `JobHistoryRecorder.
/// trailingWindow` seconds of wall time, a phase's rate over the time that
/// phase was actually running in that window. A phase that did not run in
/// the window has no rate (nil), never a fake zero.
public struct JobHistorySample: Codable, Equatable, Hashable, Sendable {
    /// Seconds since the job started.
    public var t: Double
    /// Everything together over the link — "now · combined".
    public var combined: Double?
    /// Copy to the NAS (write).
    public var copy: Double?
    /// SMB re-read of the NAS copy.
    public var verify: Double?
    /// Hashing the drive copy of a file already on the NAS.
    public var hash: Double?
    /// NAS-side SHA-256 over SSH.
    public var remoteVerify: Double?
    /// Finished files per second, for jobs that count files, not bytes.
    public var filesPerSecond: Double?
    /// Transfer rows busy this second (parallel transfers and the NAS-side
    /// verification row).
    public var activeTransfers: Int
    /// System-wide CPU and GPU load, 0...1, when the app could read them.
    public var cpu: Double?
    public var gpu: Double?
    /// The cumulative counters behind the rates, so any other window can
    /// be computed from the table later.
    public var transferBytes: Int64?
    public var doneBytes: Int64
    public var doneFiles: Int
    /// What the Jobs window said was left at this second ("~10 m left"),
    /// so a finished job shows how far off each estimate was.
    public var secondsRemaining: Double?

    public init(
        t: Double,
        combined: Double? = nil,
        copy: Double? = nil,
        verify: Double? = nil,
        hash: Double? = nil,
        remoteVerify: Double? = nil,
        filesPerSecond: Double? = nil,
        activeTransfers: Int = 0,
        cpu: Double? = nil,
        gpu: Double? = nil,
        transferBytes: Int64? = nil,
        doneBytes: Int64 = 0,
        doneFiles: Int = 0,
        secondsRemaining: Double? = nil
    ) {
        self.t = t
        self.combined = combined
        self.copy = copy
        self.verify = verify
        self.hash = hash
        self.remoteVerify = remoteVerify
        self.filesPerSecond = filesPerSecond
        self.activeTransfers = activeTransfers
        self.cpu = cpu
        self.gpu = gpu
        self.transferBytes = transferBytes
        self.doneBytes = doneBytes
        self.doneFiles = doneFiles
        self.secondsRemaining = secondsRemaining
    }

    /// When this second's estimate said the job would end, minus when it
    /// really ended: positive means it finished sooner than estimated.
    public func estimateError(actualDuration: Double) -> Double? {
        secondsRemaining.map { t + $0 - actualDuration }
    }

    /// The chart series this sample carries, by the live chart's names.
    public static let seriesNames = ["Overall", "Copy (write)", "Verify (re-read)", "Verify (on NAS)", "Hash (drive read)"]

    public func value(ofSeries name: String) -> Double? {
        switch name {
        case "Overall", "Throughput": combined
        case "Copy (write)": copy
        case "Verify (re-read)": verify
        case "Verify (on NAS)": remoteVerify
        case "Hash (drive read)": hash
        case "Files": filesPerSecond
        default: nil
        }
    }
}

/// How one file of a recorded job settled.
public enum JobHistoryItemOutcome: String, Codable, CaseIterable, Sendable {
    case copied
    case matched
    case alreadyVerified
    case conflict
    case failed
}

/// One file of a recorded job — a row of `job_items`, written when the
/// file settles.
public struct JobHistoryItem: Codable, Equatable, Hashable, Sendable {
    public var relativePath: String
    public var fileName: String
    public var byteCount: Int64
    /// Seconds since the job started when a transfer took the file; nil for
    /// a file settled without one (already verified, refused path).
    public var start: Double?
    /// Seconds since the job started when the file settled.
    public var end: Double
    /// The transfer row that carried it.
    public var slot: Int?
    public var outcome: JobHistoryItemOutcome
    /// "ssh" or "smb" — how the NAS copy was checked.
    public var verifyMethod: String?
    public var copySeconds: Double?
    public var verifySeconds: Double?
    /// Decimal MB/s over the file's whole time in flight; nil without one.
    public var averageMegabytesPerSecond: Double?
    public var error: String?

    public init(
        relativePath: String,
        fileName: String? = nil,
        byteCount: Int64,
        start: Double?,
        end: Double,
        slot: Int? = nil,
        outcome: JobHistoryItemOutcome,
        verifyMethod: String? = nil,
        copySeconds: Double? = nil,
        verifySeconds: Double? = nil,
        averageMegabytesPerSecond: Double? = nil,
        error: String? = nil
    ) {
        self.relativePath = relativePath
        self.fileName = fileName ?? (relativePath as NSString).lastPathComponent
        self.byteCount = byteCount
        self.start = start
        self.end = end
        self.slot = slot
        self.outcome = outcome
        self.verifyMethod = verifyMethod
        self.copySeconds = copySeconds
        self.verifySeconds = verifySeconds
        self.averageMegabytesPerSecond = averageMegabytesPerSecond ?? start.flatMap { start in
            let span = end - start
            return span > 0 && byteCount > 0 ? Double(byteCount) / span / 1_000_000 : nil
        }
        self.error = error
    }

    /// Seconds in flight; nil without a start.
    public var duration: Double? { start.map { max(end - $0, 0) } }
}
