import CameraToolkitCore
import Foundation

/// The speed graph's visible stretch of the job: zoom about a point, pan,
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

enum JobHistoryChartMath {
    /// Axis tick spacing for `span` seconds: a round step giving about six
    /// ticks, from a second to a day.
    static func timeStride(_ span: Double) -> Double {
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200, 10_800, 21_600, 43_200, 86_400]
        let target = max(span, 1) / 6
        return steps.first { $0 >= target } ?? 86_400
    }
}
