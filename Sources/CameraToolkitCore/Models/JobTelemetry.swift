import Foundation

/// One file a parallel job is working on right now — a row in the Jobs
/// window's per-worker list.
public struct JobActiveItem: Codable, Equatable, Hashable, Sendable {
    /// Display name — the file's basename, not a library path.
    public var name: String
    /// Full path, for tooltips and disambiguation only.
    public var path: String
    /// The pipeline step this file is in, e.g. "Decode" or "Embed".
    public var step: String
    /// The worker row this file occupies, for jobs with a fixed number of
    /// parallel transfers (Sync to NAS). A finished transfer's row is
    /// reused by the next file, so rows keep their place. Nil for jobs
    /// without fixed rows.
    public var slot: Int?
    /// Short phase for the row — "Copying", "Verifying on NAS", "Renaming".
    public var phase: String?
    /// Bytes this file has moved in its current phase, of `bytesTotal`.
    public var bytesDone: Int64?
    public var bytesTotal: Int64?
    /// This row's own smoothed speed (`TransferRateMeter`).
    public var bytesPerSecond: Double?

    public init(
        name: String,
        path: String,
        step: String,
        slot: Int? = nil,
        phase: String? = nil,
        bytesDone: Int64? = nil,
        bytesTotal: Int64? = nil,
        bytesPerSecond: Double? = nil
    ) {
        self.name = name
        self.path = path
        self.step = step
        self.slot = slot
        self.phase = phase
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.bytesPerSecond = bytesPerSecond
    }

    /// Done over total for the row's bar; nil without byte counts.
    public var byteFraction: Double? {
        guard let bytesDone, let bytesTotal, bytesTotal > 0 else { return nil }
        return min(max(Double(bytesDone) / Double(bytesTotal), 0), 1)
    }
}

/// A smoothed speed for one transfer row, sampled at most every
/// `minimumInterval` (~4 Hz) from a cumulative byte counter — so a row's
/// MB/s is steady instead of jumping with every 4 MB chunk. It keeps its
/// value across files (a row reused by the next file does not drop to
/// zero); a real stall still pulls it down.
public struct TransferRateMeter: Equatable, Sendable {
    public var minimumInterval: TimeInterval
    public var timeConstant: TimeInterval
    /// Nil until one full interval has been measured.
    public private(set) var bytesPerSecond: Double?
    private var lastCount: Int64?
    private var lastTime: TimeInterval = 0

    public init(minimumInterval: TimeInterval = 0.25, timeConstant: TimeInterval = 2) {
        self.minimumInterval = minimumInterval
        self.timeConstant = timeConstant
    }

    /// `cumulative` is every byte the row has moved; it never goes down.
    public mutating func record(_ cumulative: Int64, at now: TimeInterval) {
        guard let lastCount else {
            self.lastCount = cumulative
            lastTime = now
            return
        }
        let span = now - lastTime
        guard span >= minimumInterval else { return }
        let instantaneous = Double(max(cumulative - lastCount, 0)) / span
        if let current = bytesPerSecond {
            let alpha = 1 - exp(-span / timeConstant)
            bytesPerSecond = current + alpha * (instantaneous - current)
        } else {
            bytesPerSecond = instantaneous
        }
        self.lastCount = cumulative
        lastTime = now
    }
}

/// One named live counter, in the order the job wants them shown —
/// ("Faces", 61), ("Failed", 2).
public struct JobCounter: Codable, Equatable, Hashable, Sendable {
    public var label: String
    public var value: Int

    public init(label: String, value: Int) {
        self.label = label
        self.value = value
    }
}

/// A job's own measure of its work — units done, the planned total, and
/// the time left at the recent rate. A face scan counts one unit per
/// still and one per planned video frame, so a long clip in flight moves
/// the bar instead of freezing it until the clip ends.
public struct JobWorkEstimate: Codable, Equatable, Hashable, Sendable {
    public var unitsDone: Int
    /// Planned units; nil while the total cannot be estimated yet.
    public var unitsTotal: Int?
    /// True while part of the total is extrapolated (clips not yet opened).
    public var totalIsEstimate: Bool
    /// What a unit is — "frames" on a video-only scan, "photos and
    /// frames" on a mixed one; nil when the file count already says it.
    public var unitLabel: String?
    /// Seconds left at the smoothed recent rate; nil while estimating.
    public var secondsRemaining: Double?

    public init(
        unitsDone: Int,
        unitsTotal: Int?,
        totalIsEstimate: Bool = false,
        unitLabel: String? = nil,
        secondsRemaining: Double? = nil
    ) {
        self.unitsDone = unitsDone
        self.unitsTotal = unitsTotal
        self.totalIsEstimate = totalIsEstimate
        self.unitLabel = unitLabel
        self.secondsRemaining = secondsRemaining
    }

    /// Done over total, 0 while the total is unknown.
    public var fraction: Double? {
        guard let unitsTotal, unitsTotal > 0 else { return nil }
        return min(max(Double(unitsDone) / Double(unitsTotal), 0), 1)
    }
}

/// Time and bytes a job has spent in one named phase so far — "Copy",
/// "Flush", "Verify", "Rename". Measured with a monotonic clock around
/// each phase; `bytes` is what moved while that phase was running.
///
/// `seconds` is busy time: with parallel workers it is summed over them
/// (as `NASSyncTimings` does), so shares of it say where the work went.
/// `activeSeconds` is the wall time during which at least one worker was
/// in the phase; nil for a job with one worker, where the two are equal.
public struct JobPhaseTotal: Codable, Equatable, Hashable, Sendable {
    public var label: String
    public var seconds: Double
    public var bytes: Int64
    public var activeSeconds: Double?

    public init(label: String, seconds: Double, bytes: Int64 = 0, activeSeconds: Double? = nil) {
        self.label = label
        self.seconds = seconds
        self.bytes = bytes
        self.activeSeconds = activeSeconds
    }

    /// Wall seconds the phase was running at all.
    public var runningSeconds: Double { activeSeconds ?? seconds }

    /// Bytes per second while this phase was running — over all workers
    /// in it at once; nil when it moved no bytes or took no measurable
    /// time.
    public var bytesPerSecond: Double? {
        guard bytes > 0, runningSeconds > 0 else { return nil }
        return Double(bytes) / runningSeconds
    }
}

/// One phase's share of a job's measured time, for the Jobs window's
/// "Copy 30% · Flush 40% · Verify 25% · Rename 5%" breakdown.
public struct JobPhaseShare: Equatable, Hashable, Sendable {
    public var label: String
    public var seconds: Double
    /// Exact share of the measured time, 0...1; the shares sum to 1.
    public var fraction: Double
    /// Whole percent, rounded so the shown percentages sum to exactly 100.
    public var percent: Int
    public var bytesPerSecond: Double?
}

/// Accumulates per-phase wall time with a monotonic clock, cheaply: one
/// clock read per phase change, O(1) byte credit per chunk. Beginning a
/// phase ends the one before, so a job just names what it is doing next.
public struct JobPhaseTimer: Sendable {
    public private(set) var totals: [JobPhaseTotal]
    private var currentIndex: Int?
    private var currentSince: TimeInterval = 0

    /// `order` fixes the display order; phases first seen later are
    /// appended.
    public init(order: [String] = []) {
        totals = order.map { JobPhaseTotal(label: $0, seconds: 0) }
    }

    /// The phase running now, if any.
    public var current: String? { currentIndex.map { totals[$0].label } }

    public mutating func begin(_ label: String, at now: TimeInterval) {
        if let currentIndex, totals[currentIndex].label == label { return }
        end(at: now)
        let index = totals.firstIndex { $0.label == label } ?? {
            totals.append(JobPhaseTotal(label: label, seconds: 0))
            return totals.count - 1
        }()
        currentIndex = index
        currentSince = now
    }

    public mutating func end(at now: TimeInterval) {
        guard let currentIndex else { return }
        totals[currentIndex].seconds += max(now - currentSince, 0)
        self.currentIndex = nil
    }

    /// Credits bytes to the running phase; ignored between phases.
    public mutating func addBytes(_ count: Int64) {
        guard let currentIndex else { return }
        totals[currentIndex].bytes += count
    }

    /// Totals including the running phase's time so far — what a progress
    /// emission reports. Phases with no time and no bytes are left out.
    public func snapshot(at now: TimeInterval) -> [JobPhaseTotal] {
        var result = totals
        if let currentIndex {
            result[currentIndex].seconds += max(now - currentSince, 0)
        }
        return result.filter { $0.seconds > 0 || $0.bytes > 0 }
    }
}

/// `JobPhaseTimer` for a job whose workers run concurrently: each worker
/// (a "lane") is in at most one phase at a time. Per phase it keeps busy
/// seconds summed over lanes, and the wall seconds during which at least
/// one lane was in it. A value type with no locking of its own — the
/// owner confines it or guards it with a lock.
public struct JobPhaseLedger: Sendable {
    private struct Running: Sendable {
        var index: Int
        var since: TimeInterval
    }

    private struct Occupancy: Sendable {
        var lanes = 0
        var since: TimeInterval = 0
    }

    private var totals: [JobPhaseTotal]
    private var running: [Int: Running] = [:]
    private var occupancy: [Occupancy]

    /// `order` fixes the display order; phases first seen later are
    /// appended.
    public init(order: [String] = []) {
        totals = order.map { JobPhaseTotal(label: $0, seconds: 0, activeSeconds: 0) }
        occupancy = Array(repeating: Occupancy(), count: totals.count)
    }

    /// The phase `lane` is in now, if any.
    public func current(lane: Int) -> String? {
        running[lane].map { totals[$0.index].label }
    }

    private mutating func index(of label: String) -> Int {
        if let index = totals.firstIndex(where: { $0.label == label }) { return index }
        totals.append(JobPhaseTotal(label: label, seconds: 0, activeSeconds: 0))
        occupancy.append(Occupancy())
        return totals.count - 1
    }

    /// `lane` moves into `label`, ending whatever phase it was in.
    public mutating func begin(_ label: String, lane: Int, at now: TimeInterval) {
        let target = index(of: label)
        if running[lane]?.index == target { return }
        end(lane: lane, at: now)
        running[lane] = Running(index: target, since: now)
        if occupancy[target].lanes == 0 { occupancy[target].since = now }
        occupancy[target].lanes += 1
    }

    /// `lane` stops working; ignored when it is in no phase.
    public mutating func end(lane: Int, at now: TimeInterval) {
        guard let current = running.removeValue(forKey: lane) else { return }
        totals[current.index].seconds += max(now - current.since, 0)
        occupancy[current.index].lanes -= 1
        if occupancy[current.index].lanes == 0 {
            totals[current.index].activeSeconds = (totals[current.index].activeSeconds ?? 0)
                + max(now - occupancy[current.index].since, 0)
        }
    }

    /// Credits bytes to a phase, whichever lane moved them.
    public mutating func addBytes(_ count: Int64, to label: String) {
        totals[index(of: label)].bytes += count
    }

    /// Totals including running lanes' time so far — what a progress
    /// emission reports. Phases with no time and no bytes are left out.
    public func snapshot(at now: TimeInterval) -> [JobPhaseTotal] {
        var result = totals
        for current in running.values {
            result[current.index].seconds += max(now - current.since, 0)
        }
        for (index, entry) in occupancy.enumerated() where entry.lanes > 0 {
            result[index].activeSeconds = (result[index].activeSeconds ?? 0) + max(now - entry.since, 0)
        }
        return result.filter { $0.seconds > 0 || $0.bytes > 0 }
    }
}

/// Best-effort live detail a job reports next to the coarse
/// `FileOperationProgress` counters — the payload the Jobs window's
/// activity pane renders. Everything in it is genuinely measured or
/// recorded by the job; jobs that never set it render as the plain row.
public struct JobTelemetry: Codable, Equatable, Hashable, Sendable {
    /// The pipeline step the job is spending time in — "Detect", "Embed",
    /// "Match" — when the job can say so.
    public var step: String?
    /// Files in flight this instant — one entry per busy worker on a
    /// parallel job, empty between items and on single-threaded passes.
    public var activeItems: [JobActiveItem]
    /// Ordered live counters ("Faces", "Skipped", "Video frames").
    public var counters: [JobCounter]
    /// Engine and package names actually in use — debug-accurate, e.g.
    /// "InsightFace buffalo_l (SCRFD-10G + ArcFace w600k_r50) · insightface 2.0 · onnxruntime 1.30.0 CoreML".
    public var models: [String]
    /// Short facts about how the job is configured — "MED · FAST ·
    /// 10 workers".
    public var facts: [String]
    /// Units of work and time left, for jobs that can measure them. Nil
    /// for jobs that cannot, and in snapshots from older builds.
    public var work: JobWorkEstimate?
    /// Where the job's time has gone, per phase, when the job measures it
    /// (Sync to NAS). Empty for jobs that do not, and in older snapshots.
    public var phases: [JobPhaseTotal]
    /// How the job runs, in one line above its worker rows — "4 transfers
    /// in parallel · SSH verify".
    public var configuration: String?
    /// Bytes all parallel transfers together have moved over the link (a
    /// sync's copies and SMB re-reads, not hashes the NAS does itself) —
    /// the combined speed's counter. Nil: the job's byte counter is it.
    public var transferBytes: Int64?

    public init(
        step: String? = nil,
        activeItems: [JobActiveItem] = [],
        counters: [JobCounter] = [],
        models: [String] = [],
        facts: [String] = [],
        work: JobWorkEstimate? = nil,
        phases: [JobPhaseTotal] = [],
        configuration: String? = nil,
        transferBytes: Int64? = nil
    ) {
        self.step = step
        self.activeItems = activeItems
        self.counters = counters
        self.models = models
        self.facts = facts
        self.work = work
        self.phases = phases
        self.configuration = configuration
        self.transferBytes = transferBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        step = try container.decodeIfPresent(String.self, forKey: .step)
        activeItems = try container.decodeIfPresent([JobActiveItem].self, forKey: .activeItems) ?? []
        counters = try container.decodeIfPresent([JobCounter].self, forKey: .counters) ?? []
        models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
        facts = try container.decodeIfPresent([String].self, forKey: .facts) ?? []
        work = try container.decodeIfPresent(JobWorkEstimate.self, forKey: .work)
        phases = try container.decodeIfPresent([JobPhaseTotal].self, forKey: .phases) ?? []
        configuration = try container.decodeIfPresent(String.self, forKey: .configuration)
        transferBytes = try container.decodeIfPresent(Int64.self, forKey: .transferBytes)
    }

    /// Each measured phase's share of the time, in the job's order. The
    /// fractions sum to 1 and the whole percentages to exactly 100
    /// (largest-remainder rounding). Empty when nothing was measured.
    public var phaseShares: [JobPhaseShare] {
        Self.shares(of: phases)
    }

    public static func shares(of phases: [JobPhaseTotal]) -> [JobPhaseShare] {
        let measured = phases.filter { $0.seconds > 0 }
        let total = measured.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return [] }
        let exact = measured.map { $0.seconds / total * 100 }
        var percents = exact.map { Int($0.rounded(.down)) }
        let leftover = 100 - percents.reduce(0, +)
        let byRemainder = exact.indices.sorted {
            let a = exact[$0] - Double(percents[$0])
            let b = exact[$1] - Double(percents[$1])
            return a != b ? a > b : $0 < $1
        }
        for index in byRemainder.prefix(max(leftover, 0)) {
            percents[index] += 1
        }
        return measured.enumerated().map { index, phase in
            JobPhaseShare(
                label: phase.label,
                seconds: phase.seconds,
                fraction: phase.seconds / total,
                percent: percents[index],
                bytesPerSecond: phase.bytesPerSecond
            )
        }
    }

    public func counter(_ label: String) -> Int? {
        counters.first { $0.label == label }?.value
    }
}
