import Foundation

/// Pure helpers the History view draws with, kept here so they are tested
/// without a window.
public enum JobHistoryAnalysis {
    /// One plotted value.
    public struct Point: Equatable, Sendable {
        public var t: Double
        public var value: Double

        public init(t: Double, value: Double) {
            self.t = t
            self.value = value
        }
    }

    /// `points` (in time order) reduced for drawing `range` at `buckets`
    /// columns: each column keeps its lowest and highest point, in time
    /// order, so a spike or a stall survives however far the view is
    /// zoomed out, and a 10-hour job draws a few hundred points instead of
    /// 36,000. The nearest point just outside each end is kept too, so the
    /// line runs to the edge instead of stopping short, and so are the
    /// range's own first and last points. Under two points a
    /// column there is nothing to drop and the slice comes back as is.
    public static func downsample(_ points: [Point], in range: ClosedRange<Double>, buckets: Int) -> [Point] {
        guard !points.isEmpty, buckets > 0 else { return [] }
        let lower = lowerBound(points, range.lowerBound)
        let upper = lowerBound(points, nextUp(range.upperBound))
        // One neighbour beyond each edge.
        let first = max(lower - 1, 0)
        let last = min(upper, points.count - 1)
        guard first <= last else { return [] }
        let slice = points[first...last]
        guard slice.count > 2 * buckets + 2 else { return Array(slice) }

        var result: [Point] = []
        result.reserveCapacity(2 * buckets + 2)
        if first < lower { result.append(points[first]) }
        let span = max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)
        var index = lower
        while index < upper {
            let bucket = min(Int((points[index].t - range.lowerBound) / span * Double(buckets)), buckets - 1)
            var low = points[index]
            var high = points[index]
            index += 1
            while index < upper, min(Int((points[index].t - range.lowerBound) / span * Double(buckets)), buckets - 1) == bucket {
                if points[index].value < low.value { low = points[index] }
                if points[index].value > high.value { high = points[index] }
                index += 1
            }
            if low == high {
                result.append(low)
            } else if low.t < high.t {
                result.append(low)
                result.append(high)
            } else {
                result.append(high)
                result.append(low)
            }
        }
        // The range's own first and last points always stay, so the line
        // spans it end to end.
        if let firstDrawn = result.firstIndex(where: { $0.t >= points[lower].t }), result[firstDrawn] != points[lower] {
            result.insert(points[lower], at: firstDrawn)
        }
        if result.last != points[upper - 1] { result.append(points[upper - 1]) }
        if last >= upper, upper < points.count { result.append(points[upper]) }
        return result
    }

    /// First index whose `t` is at least `t`.
    private static func lowerBound(_ points: [Point], _ t: Double) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].t < t { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func nextUp(_ value: Double) -> Double { value.nextUp }

    /// One series of `samples` as points, leaving out seconds the series
    /// had no value.
    public static func points(_ samples: [JobHistorySample], series: String) -> [Point] {
        samples.compactMap { sample in sample.value(ofSeries: series).map { Point(t: sample.t, value: $0) } }
    }

    /// The sample nearest `t`, by binary search over `samples` in time order.
    public static func nearestSample(_ samples: [JobHistorySample], to t: Double) -> JobHistorySample? {
        guard !samples.isEmpty else { return nil }
        var low = 0
        var high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].t < t { low = middle + 1 } else { high = middle }
        }
        if low == 0 { return samples[0] }
        if low == samples.count { return samples[samples.count - 1] }
        return t - samples[low - 1].t <= samples[low].t - t ? samples[low - 1] : samples[low]
    }
}

/// Which files were in flight at an instant, answered fast for a job of
/// tens of thousands of files: spans sorted by start, and the longest span,
/// bound the search to the files that started at most that long before.
public struct JobHistoryFlightIndex: Sendable {
    /// Indexes into the items the index was built from, by start time.
    private let order: [Int]
    private let starts: [Double]
    private let ends: [Double]
    private let longest: Double

    /// Files without a start (settled without a transfer) never fly.
    public init(_ items: [JobHistoryItem]) {
        let flown = items.indices.filter { items[$0].start != nil }
            .sorted { (items[$0].start ?? 0, $0) < (items[$1].start ?? 0, $1) }
        order = flown
        starts = flown.map { items[$0].start ?? 0 }
        ends = flown.map { items[$0].end }
        longest = zip(starts, ends).map { $1 - $0 }.max() ?? 0
    }

    /// Indexes of the items whose span contains `t`, by start time.
    public func inFlight(at t: Double) -> [Int] {
        inFlight(during: t...t)
    }

    /// Indexes of the items whose span overlaps `range`, by start time.
    public func inFlight(during range: ClosedRange<Double>) -> [Int] {
        // Only a file that started at most `longest` before the range can
        // still be running in it.
        var low = 0
        var high = starts.count
        let earliest = range.lowerBound - longest
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] < earliest { low = middle + 1 } else { high = middle }
        }
        var result: [Int] = []
        var position = low
        while position < starts.count, starts[position] <= range.upperBound {
            if ends[position] >= range.lowerBound { result.append(order[position]) }
            position += 1
        }
        return result
    }
}
