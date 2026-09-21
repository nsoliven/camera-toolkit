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
    /// "Apple Vision", "det_10g.mlpackage", "w600k_r50.mlpackage".
    public var models: [String]
    /// Short facts about how the job is configured — "MED · FAST ·
    /// 10 workers".
    public var facts: [String]

    public init(
        step: String? = nil,
        activeItems: [JobActiveItem] = [],
        counters: [JobCounter] = [],
        models: [String] = [],
        facts: [String] = []
    ) {
        self.step = step
        self.activeItems = activeItems
        self.counters = counters
        self.models = models
        self.facts = facts
    }

    public func counter(_ label: String) -> Int? {
        counters.first { $0.label == label }?.value
    }
}
