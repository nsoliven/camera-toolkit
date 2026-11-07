import Foundation

/// What the Jobs window's speed graph draws for one job, built from the
/// job's recorded samples (`job_samples`) — the same for a job that is
/// still running and one that ended long ago.
///
/// One rate is plotted, chosen by what the job did: MB/s for a job that
/// moved bytes, files/s for one that only counted files (a face scan, a
/// check). Seconds without a sample are gaps, never a line drawn across
/// them. The phases the samples record (Check, Hash, Copy, Verify) become
/// spans the graph marks under the line. A job too short to chart, or one
/// that moved nothing, carries a `summary` instead and draws no chart.
public struct JobSpeedGraph: Equatable, Sendable {
    public enum Metric: String, Equatable, Sendable {
        case megabytesPerSecond
        case filesPerSecond

        public var unit: String {
            switch self {
            case .megabytesPerSecond: "MB/s"
            case .filesPerSecond: "files/s"
            }
        }
    }

    /// What a job was doing in a stretch of time, read from which rates its
    /// samples carry. Ordered as the lanes are drawn.
    public enum Phase: String, CaseIterable, Equatable, Sendable {
        /// Listing and comparing files; nothing moved.
        case check
        /// Hashing the drive copy of a file already on the NAS.
        case hash
        case copy
        /// Re-reading the NAS copy, or hashing it on the NAS.
        case verify

        public var label: String {
            switch self {
            case .check: "Check"
            case .hash: "Hash"
            case .copy: "Copy"
            case .verify: "Verify"
            }
        }
    }

    public struct Point: Equatable, Sendable {
        public var t: Double
        public var value: Double

        public init(t: Double, value: Double) {
            self.t = t
            self.value = value
        }
    }

    /// One drawn column: the mean of the points in it, and their range.
    public struct Bucket: Equatable, Sendable {
        public var t: Double
        public var mean: Double
        public var low: Double
        public var high: Double

        public init(t: Double, mean: Double, low: Double, high: Double) {
            self.t = t
            self.mean = mean
            self.low = low
            self.high = high
        }
    }

    public struct PhaseSpan: Equatable, Sendable {
        public var phase: Phase
        public var start: Double
        public var end: Double

        public init(phase: Phase, start: Double, end: Double) {
            self.phase = phase
            self.start = start
            self.end = end
        }
    }

    /// Why the graph shows a sentence instead of a chart.
    public enum Summary: Equatable, Sendable {
        /// No sample carried a rate.
        case noSamples
        /// Over (or, while running, not yet past) `minimumChartSeconds`, or
        /// too few samples for a line to mean anything.
        case tooShort(duration: Double)
        /// A copy job that copied nothing — every file was already there.
        /// `files` is how many it checked; `filesPerSecond` how fast.
        case nothingMoved(files: Int, filesPerSecond: Double?)
    }

    /// Shorter than this, a job gets a summary instead of a chart.
    public static let minimumChartSeconds: Double = 10
    /// Fewer plotted samples than this, likewise.
    public static let minimumChartPoints = 4
    /// Kinds whose purpose is to copy bytes: when they copy none, their
    /// graph is a summary however long they checked.
    public static let copyKinds: Set<String> = ["syncBuffer", "ingestCard"]
    /// Kinds whose honest unit is files (photos) per second even when they
    /// read bytes along the way.
    public static let fileRateKinds: Set<String> = ["faceScan"]

    /// Nil when nothing was measured.
    public var metric: Metric?
    /// Seconds the job ran — the x-axis is `0...duration`.
    public var duration: Double
    /// Continuous runs of the plotted rate, in time order; the space
    /// between two runs is a gap in the recording.
    public var segments: [[Point]]
    public var phases: [PhaseSpan]
    /// The job's average in `metric`: everything it moved (or finished) over
    /// its whole time.
    public var average: Double?
    /// The highest plotted sample.
    public var peak: Point?
    /// Files the job finished, from the samples' counters.
    public var filesDone: Int
    /// `filesDone` over the job's whole time; nil when none finished.
    public var averageFilesPerSecond: Double?
    /// A round axis top above the peak and the average — or, when the
    /// peak is a lone burst far above everything else, above the rest of
    /// the line, with the peak marked off the scale.
    public var yUpper: Double
    /// True when the peak is above `yUpper`.
    public var peakIsOffScale: Bool {
        (peak?.value ?? 0) > yUpper
    }
    /// Samples further apart than this are a gap.
    public var gapThreshold: Double
    public var summary: Summary?

    /// True when the graph marks more than one kind of phase — a single
    /// phase over the whole job tells nothing a lane could add.
    public var showsPhases: Bool {
        Set(phases.map(\.phase)).count > 1
    }

    public var pointCount: Int { segments.reduce(0) { $0 + $1.count } }

    /// Builds the graph for a job of `kind` (`JobAction.rawValue`) that ran
    /// `duration` seconds. `movedBytes` is the job's own total when its row
    /// has one (`transferBytes ?? bytesDone`); otherwise the samples'
    /// counters are summed.
    public static func build(
        samples raw: [JobHistorySample],
        kind: String,
        duration: Double,
        movedBytes: Int64? = nil
    ) -> JobSpeedGraph {
        let samples = deduplicated(raw)
        let duration = max(duration, samples.last?.t ?? 0, 0)
        let gap = gapThreshold(samples)

        let bytesMoved = movedBytes ?? positiveDeltaSum(samples.map { $0.transferBytes ?? $0.doneBytes })
        let filesDone = positiveDeltaSum(samples.map { Int64($0.doneFiles) })
        let hasByteRates = samples.contains { ($0.combined ?? 0) > 0 }
        let hasFileRates = samples.contains { ($0.filesPerSecond ?? 0) > 0 }

        let metric: Metric?
        if fileRateKinds.contains(kind), hasFileRates {
            metric = .filesPerSecond
        } else if hasByteRates, bytesMoved > 0 {
            metric = .megabytesPerSecond
        } else if hasFileRates {
            metric = .filesPerSecond
        } else if hasByteRates {
            metric = .megabytesPerSecond
        } else {
            metric = nil
        }

        let points: [Point] = metric.map { metric in
            samples.compactMap { sample in
                value(of: sample, metric: metric).map { Point(t: sample.t, value: max($0, 0)) }
            }
        } ?? []
        let segments = split(points, gap: gap)

        let filesRate: Double? = duration >= 1 && filesDone > 0 ? Double(filesDone) / duration : nil
        let average: Double? = metric.flatMap { metric in
            switch metric {
            case .megabytesPerSecond: return duration >= 1 && bytesMoved > 0 ? Double(bytesMoved) / duration / 1_000_000 : nil
            case .filesPerSecond: return filesRate
            }
        }
        let peak = points.max { $0.value < $1.value }.flatMap { $0.value > 0 ? $0 : nil }
        let yUpper = axisUpper(points.map(\.value), average: average)

        let summary: Summary?
        if copyKinds.contains(kind), bytesMoved == 0 {
            summary = .nothingMoved(files: Int(filesDone), filesPerSecond: filesRate)
        } else if points.isEmpty, duration >= minimumChartSeconds {
            summary = .noSamples
        } else if duration < minimumChartSeconds || points.count < minimumChartPoints {
            summary = .tooShort(duration: duration)
        } else {
            summary = nil
        }

        return JobSpeedGraph(
            metric: metric,
            duration: duration,
            segments: segments,
            phases: phaseSpans(samples, gap: gap),
            average: average,
            peak: peak,
            filesDone: Int(filesDone),
            averageFilesPerSecond: filesRate,
            yUpper: yUpper,
            gapThreshold: gap,
            summary: summary
        )
    }

    // MARK: - Drawing

    /// The segments over `range`, reduced to about `buckets` columns across
    /// it: each column is the mean of its points (the drawn line) and
    /// their low and high (a faint band, so a spike or a stall still
    /// shows). Each segment keeps its nearest point just outside the range
    /// so its line runs to the edge. A segment with no more points than
    /// columns comes back point for point.
    ///
    /// Where columns were merged, the line is also smoothed over
    /// `smoothing` columns each side: a five-second rate from parallel
    /// transfers swings every few seconds, and over an hour that reads as
    /// noise, not speed.
    public func visibleBuckets(in range: ClosedRange<Double>, buckets: Int, smoothing: Int = 2) -> [[Bucket]] {
        segments.compactMap { segment in
            let slice = Self.clip(segment, to: range)
            guard !slice.isEmpty else { return nil }
            let columns = Self.aggregate(slice, in: range, buckets: buckets)
            return slice.count > buckets ? Self.smoothed(columns, radius: smoothing) : columns
        }
    }

    /// The phases running at `t`, in lane order.
    public func phases(at t: Double) -> [Phase] {
        let running = Set(phases.filter { $0.start <= t && t <= $0.end }.map(\.phase))
        return Phase.allCases.filter(running.contains)
    }

    /// The sample whose time is nearest `t`, unless the nearest one is
    /// further than a gap away — then `t` is in a gap and there is none.
    public static func sample(near t: Double, in samples: [JobHistorySample], within gap: Double) -> JobHistorySample? {
        guard let nearest = JobHistoryAnalysis.nearestSample(samples, to: t) else { return nil }
        return abs(nearest.t - t) <= gap / 2 + 0.5 ? nearest : nil
    }

    /// `points` reduced to about `buckets` columns over `range`, by a fixed
    /// time grid so every segment shares the same columns.
    public static func aggregate(_ points: [Point], in range: ClosedRange<Double>, buckets: Int) -> [Bucket] {
        guard !points.isEmpty else { return [] }
        guard buckets > 0, points.count > buckets else {
            return points.map { Bucket(t: $0.t, mean: $0.value, low: $0.value, high: $0.value) }
        }
        let width = max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude) / Double(buckets)
        func column(_ t: Double) -> Int { Int(((t - range.lowerBound) / width).rounded(.down)) }
        var result: [Bucket] = []
        var index = 0
        while index < points.count {
            let key = column(points[index].t)
            var sum = 0.0
            var sumT = 0.0
            var low = Double.infinity
            var high = -Double.infinity
            var count = 0
            while index < points.count, column(points[index].t) == key {
                let point = points[index]
                sum += point.value
                sumT += point.t
                low = min(low, point.value)
                high = max(high, point.value)
                count += 1
                index += 1
            }
            result.append(Bucket(t: sumT / Double(count), mean: sum / Double(count), low: low, high: high))
        }
        return result
    }

    // MARK: - Building blocks

    /// How far above the bulk of the line a peak may sit before the axis
    /// stops following it: a burst of thousands of files settling in one
    /// second at the end of a scan that ran at 30 a second otherwise
    /// flattens the whole run to the floor.
    static let outlierRatio = 2.5

    /// The y-axis top: 12 % over the peak, or — when the peak is more than
    /// `outlierRatio` times the 98th percentile — 25 % over that
    /// percentile. Never under the average.
    static func axisUpper(_ values: [Double], average: Double?) -> Double {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard let peak = sorted.last, peak > 0 else { return niceUpper((average ?? 0) * 1.12) }
        let typical = sorted[min(Int((Double(sorted.count - 1) * 0.98).rounded()), sorted.count - 1)]
        let top = typical > 0 && peak > typical * outlierRatio ? typical * 1.25 : peak * 1.12
        return niceUpper(max(top, (average ?? 0) * 1.12))
    }

    /// Bucket means smoothed by a centred moving average `radius` columns
    /// wide on each side; each column's low and high stay as they were, so
    /// the band still shows every spike the line no longer follows.
    public static func smoothed(_ buckets: [Bucket], radius: Int) -> [Bucket] {
        guard radius > 0, buckets.count > 2 else { return buckets }
        var prefix = [0.0]
        prefix.reserveCapacity(buckets.count + 1)
        for bucket in buckets { prefix.append(prefix[prefix.count - 1] + bucket.mean) }
        return buckets.indices.map { index in
            let lower = max(index - radius, 0)
            let upper = min(index + radius, buckets.count - 1)
            var bucket = buckets[index]
            bucket.mean = (prefix[upper + 1] - prefix[lower]) / Double(upper - lower + 1)
            return bucket
        }
    }

    /// Samples in time order with one per instant (the last written wins —
    /// a job's closing sample repeats the final second).
    static func deduplicated(_ samples: [JobHistorySample]) -> [JobHistorySample] {
        let sorted = samples.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        var result: [JobHistorySample] = []
        for sample in sorted {
            if let last = result.last, abs(last.t - sample.t) < 0.001 {
                result[result.count - 1] = sample
            } else {
                result.append(sample)
            }
        }
        return result
    }

    /// How far apart two samples may be before the space between them is a
    /// gap: three typical intervals, and never under five seconds (the
    /// recorder's rates already span five).
    static func gapThreshold(_ samples: [JobHistorySample]) -> Double {
        let intervals = zip(samples, samples.dropFirst()).map { $1.t - $0.t }.filter { $0 > 0 }.sorted()
        guard !intervals.isEmpty else { return 5 }
        let median = intervals[intervals.count / 2]
        return max(5, median * 3)
    }

    /// `points` cut wherever two neighbours are more than `gap` apart.
    static func split(_ points: [Point], gap: Double) -> [[Point]] {
        var segments: [[Point]] = []
        var current: [Point] = []
        for point in points {
            if let last = current.last, point.t - last.t > gap {
                segments.append(current)
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// A counter's total growth, summing only its rises — a counter that
    /// restarts between passes (a copy, then a verify) still adds up.
    public static func positiveDeltaSum(_ values: [Int64]) -> Int64 {
        var total: Int64 = 0
        var previous: Int64 = 0
        for value in values {
            if value > previous { total += value - previous }
            previous = value
        }
        return total
    }

    static func value(of sample: JobHistorySample, metric: Metric) -> Double? {
        switch metric {
        case .megabytesPerSecond: sample.combined
        case .filesPerSecond: sample.filesPerSecond
        }
    }

    /// The phases a sample says ran in the seconds it covers: a phase rate
    /// is recorded only while that phase ran. A sample with files finishing
    /// and no bytes moving is a check.
    static func phases(of sample: JobHistorySample) -> Set<Phase> {
        var phases: Set<Phase> = []
        if sample.copy != nil { phases.insert(.copy) }
        if sample.verify != nil || sample.remoteVerify != nil { phases.insert(.verify) }
        if sample.hash != nil { phases.insert(.hash) }
        if phases.isEmpty, (sample.combined ?? 0) == 0, (sample.filesPerSecond ?? 0) > 0 {
            phases.insert(.check)
        }
        return phases
    }

    /// Each sample stands for the time since the one before it (its rates
    /// are trailing); runs of samples in the same phase join into one span,
    /// broken by a gap in the recording.
    static func phaseSpans(_ samples: [JobHistorySample], gap: Double) -> [PhaseSpan] {
        var spans: [PhaseSpan] = []
        var open: [Phase: PhaseSpan] = [:]
        var previousT: Double?
        for sample in samples {
            let start = previousT.map { sample.t - $0 <= gap ? $0 : sample.t } ?? sample.t
            let running = phases(of: sample)
            for phase in Phase.allCases {
                if running.contains(phase) {
                    if var span = open[phase], start <= span.end + 0.001 {
                        span.end = sample.t
                        open[phase] = span
                    } else {
                        if let finished = open[phase] { spans.append(finished) }
                        open[phase] = PhaseSpan(phase: phase, start: start, end: sample.t)
                    }
                } else if let finished = open.removeValue(forKey: phase) {
                    spans.append(finished)
                }
            }
            previousT = sample.t
        }
        spans.append(contentsOf: open.values)
        return spans
            .filter { $0.end > $0.start }
            .sorted { ($0.start, Phase.allCases.firstIndex(of: $0.phase) ?? 0) < ($1.start, Phase.allCases.firstIndex(of: $1.phase) ?? 0) }
    }

    /// `segment`'s points inside `range`, plus the nearest one outside each
    /// end.
    static func clip(_ segment: [Point], to range: ClosedRange<Double>) -> [Point] {
        guard let head = segment.first, let tail = segment.last,
              tail.t >= range.lowerBound, head.t <= range.upperBound else { return [] }
        let firstInside = segment.firstIndex { $0.t >= range.lowerBound } ?? segment.count
        let firstAfter = segment.firstIndex { $0.t > range.upperBound } ?? segment.count
        let lower = max(firstInside - 1, 0)
        let upper = min(firstAfter, segment.count - 1)
        return Array(segment[lower...upper])
    }

    /// The next round axis bound at or above `value`: 1, 2, 2.5, 5 × 10ⁿ.
    public static func niceUpper(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let normalized = value / magnitude
        let step: Double = switch normalized {
        case ...1.0001: 1
        case ...2.0001: 2
        case ...2.5001: 2.5
        case ...5.0001: 5
        default: 10
        }
        return step * magnitude
    }
}
