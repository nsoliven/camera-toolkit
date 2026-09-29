import CameraToolkitCore
import Foundation

/// The History chart's visible stretch of the job: zoom about a point, pan,
/// zoom into a dragged range or a file's span, fit the whole job. Always
/// inside the job and never narrower than `minimumSpan`.
struct JobHistoryZoom: Equatable, Sendable {
    /// Narrowest zoom, in seconds — a few samples still show.
    static let minimumSpan: Double = 5

    private(set) var full: ClosedRange<Double>
    private(set) var visible: ClosedRange<Double>

    init(full: ClosedRange<Double>) {
        self.full = full
        visible = full
    }

    var span: Double { visible.upperBound - visible.lowerBound }
    var fullSpan: Double { full.upperBound - full.lowerBound }
    var isFit: Bool { visible == full }

    /// The job grew (it is still running). A fitted view follows it; a
    /// zoomed one stays where the owner put it.
    mutating func setFull(_ newFull: ClosedRange<Double>) {
        let wasFit = isFit
        full = newFull
        visible = wasFit ? newFull : Self.clamp(visible.lowerBound, visible.upperBound, in: newFull)
    }

    /// `factor` above 1 zooms in, below 1 out, keeping `anchor` where it is
    /// on screen.
    mutating func zoom(by factor: Double, around anchor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        let anchor = min(max(anchor, visible.lowerBound), visible.upperBound)
        let newSpan = span / factor
        let fraction = span > 0 ? (anchor - visible.lowerBound) / span : 0.5
        let lower = anchor - fraction * newSpan
        visible = Self.clamp(lower, lower + newSpan, in: full)
    }

    mutating func pan(by seconds: Double) {
        guard seconds.isFinite else { return }
        visible = Self.clamp(visible.lowerBound + seconds, visible.upperBound + seconds, in: full)
    }

    /// Shows `range`, widened by `padding` of its span on each side.
    mutating func show(_ range: ClosedRange<Double>, padding: Double = 0) {
        let margin = (range.upperBound - range.lowerBound) * padding
        visible = Self.clamp(range.lowerBound - margin, range.upperBound + margin, in: full)
    }

    /// Keeps the zoom, moves the view so `t` is in the middle.
    mutating func center(on t: Double) {
        pan(by: t - (visible.lowerBound + visible.upperBound) / 2)
    }

    mutating func fit() {
        visible = full
    }

    /// `lower...upper` moved (not squeezed) inside `full`, at least
    /// `minimumSpan` wide — or all of `full` when it is shorter.
    static func clamp(_ lower: Double, _ upper: Double, in full: ClosedRange<Double>) -> ClosedRange<Double> {
        let fullSpan = full.upperBound - full.lowerBound
        let span = min(max(upper - lower, min(minimumSpan, fullSpan)), fullSpan)
        var start = lower
        if upper - lower < span { start -= (span - (upper - lower)) / 2 }
        start = min(max(start, full.lowerBound), full.upperBound - span)
        return start...(start + span)
    }
}

/// A recorded job's samples, split into the chart's series once, so
/// zooming only re-reduces them (`JobHistoryAnalysis.downsample`).
struct JobHistoryChartData: Sendable {
    var unit: ThroughputUnit
    /// Series in legend order, by the live chart's names.
    var series: [String]
    /// Each series' points over the whole job.
    var points: [String: [JobHistoryAnalysis.Point]]
    /// A y-axis top that fits the whole job, so zooming does not rescale.
    var yUpper: Double
    /// Seconds the job ran — at least its last sample.
    var duration: Double

    init(samples: [JobHistorySample], duration: Double? = nil) {
        let phaseSeries = ["Copy (write)", "Verify (re-read)", "Verify (on NAS)", "Hash (drive read)"]
        let hasPhases = samples.contains { $0.copy != nil || $0.verify != nil || $0.hash != nil || $0.remoteVerify != nil }
        let movedBytes = samples.contains { ($0.combined ?? 0) > 0 }
        var names: [String]
        if hasPhases {
            names = ["Overall"] + phaseSeries.filter { name in samples.contains { $0.value(ofSeries: name) != nil } }
            unit = .megabytesPerSecond
        } else if movedBytes || !samples.contains(where: { ($0.filesPerSecond ?? 0) > 0 }) {
            names = ["Throughput"]
            unit = .megabytesPerSecond
        } else {
            names = ["Files"]
            unit = .filesPerSecond
        }
        series = names
        points = Dictionary(uniqueKeysWithValues: names.map { ($0, JobHistoryAnalysis.points(samples, series: $0)) })
        let peak = points.values.flatMap { $0 }.map(\.value).max() ?? 0
        yUpper = StableScale.nice(max(peak * 1.1, 1))
        self.duration = max(duration ?? 0, samples.last?.t ?? 0, 1)
    }

    /// Each series reduced for `range` at `buckets` columns.
    func visiblePoints(in range: ClosedRange<Double>, buckets: Int) -> [(series: String, points: [JobHistoryAnalysis.Point])] {
        series.map { name in (name, JobHistoryAnalysis.downsample(points[name] ?? [], in: range, buckets: buckets)) }
    }
}

enum JobHistoryChartMath {
    /// Axis tick spacing for `span` seconds: a round step giving about six
    /// ticks, from a second to a day.
    static func timeStride(_ span: Double) -> Double {
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200, 10_800, 21_600, 43_200, 86_400]
        let target = max(span, 1) / 6
        return steps.first { $0 >= target } ?? 86_400
    }
}

extension JobThroughputReadout {
    /// The live readout redrawn over the whole run so far from the job's
    /// recorded samples: the same readouts and ceiling, every second of
    /// the job along x (reduced to `buckets` columns).
    func wholeJob(samples: [JobHistorySample], elapsed: Double, buckets: Int = 320) -> JobThroughputReadout {
        var readout = self
        let data = JobHistoryChartData(samples: samples, duration: elapsed)
        let domain = 0...max(data.duration, 60)
        // Keep the live chart's series names and order; add any the
        // recording has that the live window has not seen yet.
        let known = series.isEmpty ? data.series : series
        let names = known.filter { data.series.contains($0) } + data.series.filter { !known.contains($0) }
        readout.series = names
        readout.points = names.flatMap { name -> [ThroughputPoint] in
            let source = data.points[name] ?? JobHistoryAnalysis.points(samples, series: name)
            return JobHistoryAnalysis.downsample(source, in: domain, buckets: buckets).map {
                ThroughputPoint(elapsed: $0.t, series: name, value: $0.value)
            }
        }
        let peak = readout.points.map(\.value).max() ?? 0
        readout.yUpper = StableScale.nice(max(peak * 1.15, (ceiling?.megabytesPerSecond ?? 0) * 1.1, 1))
        readout.xDomain = domain
        // The FILES readout follows the range too: the whole-job average
        // (files done over the job's wall time), the same way "average"
        // already averages bytes. The smoothed live rate reads wrong here —
        // a resumed sync settling thousands of already-verified files in
        // its first seconds holds a huge rate that says nothing about the
        // run the chart shows.
        let filesDone = samples.map(\.doneFiles).max() ?? 0
        readout.filesPerSecond = elapsed >= 1 && filesDone > 0 ? Double(filesDone) / elapsed : nil
        readout.wholeJobRate = true
        return readout
    }
}
