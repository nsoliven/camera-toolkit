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

    public init(name: String, path: String, step: String) {
        self.name = name
        self.path = path
        self.step = step
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

    public init(
        step: String? = nil,
        activeItems: [JobActiveItem] = [],
        counters: [JobCounter] = [],
        models: [String] = [],
        facts: [String] = [],
        work: JobWorkEstimate? = nil
    ) {
        self.step = step
        self.activeItems = activeItems
        self.counters = counters
        self.models = models
        self.facts = facts
        self.work = work
    }

    public func counter(_ label: String) -> Int? {
        counters.first { $0.label == label }?.value
    }
}
