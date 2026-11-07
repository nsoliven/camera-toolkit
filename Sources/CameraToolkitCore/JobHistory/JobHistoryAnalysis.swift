import Foundation

/// Pure helpers the Jobs window reads recorded samples with, kept here so
/// they are tested without a window.
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
