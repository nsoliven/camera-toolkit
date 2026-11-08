import Foundation

extension JobSpeedGraph {
    /// One pass of a scan on the graph's time axis.
    public struct ScanPass: Equatable, Sendable {
        /// 1-based.
        public var index: Int
        /// "Faces", "Dogs", or "Pass 3" for a run the scan never produces.
        public var title: String
        public var start: Double
        public var end: Double
        public var photos: Int

        public init(index: Int, title: String, start: Double, end: Double, photos: Int) {
            self.index = index
            self.title = title
            self.start = start
            self.end = end
            self.photos = photos
        }

        /// "Pass 2 · Dogs".
        public var label: String { "Pass \(index) · \(title)" }
    }
}

/// Reads what a scan really did out of its recorded counters.
///
/// A scan's `doneFiles` is not one counter. Each pass counts its own files
/// from zero, and between passes the matching step reports *faces* in the
/// same field: tens of thousands "done" in a second, falling back when the
/// grouping step starts. Taken at face value that is a rate of thousands of
/// photos a second. Runs are therefore cut wherever a counter falls, and
/// only the runs that look like files being read count as work. Everything
/// comes from the samples, so jobs recorded before passes were reported
/// read the same way.
struct JobScanTimeline {
    struct Run {
        var samples: [JobHistorySample]
        var ratePoints: [JobSpeedGraph.Point]
        /// Photos finished in steps a scan can really take.
        var photos: Int
        /// The same, leaving out what had landed before the first sample:
        /// the photos `workSeconds` actually timed.
        var timedPhotos: Int
        /// Seconds from the run's first sample to its last real progress.
        var workSeconds: Double
        var start: Double
        var end: Double
    }

    /// Faster than this is never one machine reading photos.
    static let impossibleRate = 500.0
    /// A pass counts from zero, give or take the files that land before
    /// its first sample.
    static let highestPlausibleStart = 50
    /// A rate this many times the run's median is a jump, not speed.
    static let jumpRatio = 8.0
    /// Below this, a run's median is too small to judge a jump by.
    static let minimumJumpRate = 50.0

    private(set) var runs: [Run] = []
    private(set) var passes: [JobSpeedGraph.ScanPass] = []
    private(set) var finishing: [ClosedRange<Double>] = []

    init(_ samples: [JobHistorySample]) {
        let pieces = Self.split(samples)
        let hasBytes = samples.contains { $0.doneBytes > 0 }
        for (index, piece) in pieces.enumerated() {
            if Self.isWork(piece, index: index, hasBytes: hasBytes) {
                runs.append(Self.run(piece, trimsTail: index < pieces.count - 1))
            } else if let first = piece.first, let last = piece.last, Self.counted(piece) {
                finishing.append(first.t...max(last.t, first.t))
            }
        }
        guard runs.count > 1 else { return }
        passes = runs.enumerated().map { index, run in
            let title = switch index {
            case 0: "Faces"
            case 1: "Dogs"
            default: "Pass \(index + 1)"
            }
            return JobSpeedGraph.ScanPass(index: index + 1, title: title, start: run.start, end: run.end, photos: run.photos)
        }
    }

    /// `samples` cut wherever the file or byte counter falls.
    static func split(_ samples: [JobHistorySample]) -> [[JobHistorySample]] {
        var pieces: [[JobHistorySample]] = []
        var current: [JobHistorySample] = []
        for sample in samples {
            if let last = current.last, sample.doneFiles < last.doneFiles || sample.doneBytes < last.doneBytes {
                pieces.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func counted(_ piece: [JobHistorySample]) -> Bool {
        piece.contains { $0.doneFiles > 0 }
    }

    private static func isWork(_ piece: [JobHistorySample], index: Int, hasBytes: Bool) -> Bool {
        guard counted(piece), let first = piece.first else { return false }
        // The grouping step opens at its full face count.
        if index > 0, first.doneFiles > highestPlausibleStart { return false }
        // Matching moves no bytes; a job that read bytes anywhere read them
        // in every real pass.
        if hasBytes, !piece.contains(where: { $0.doneBytes > 0 }) { return false }
        // A real pass can jump once; matching does nothing but.
        var moved = 0
        var impossible = 0
        for (earlier, later) in zip(piece, piece.dropFirst()) where later.t > earlier.t && later.doneFiles > earlier.doneFiles {
            moved += 1
            if Double(later.doneFiles - earlier.doneFiles) / (later.t - earlier.t) > impossibleRate { impossible += 1 }
        }
        return moved == 0 || Double(impossible) / Double(moved) <= 0.5
    }

    /// The most a run's counter may rise per second and still be scanning:
    /// a burst of cached files or a counter jump lands above it.
    private static func jumpLimit(_ piece: [JobHistorySample]) -> Double {
        var rates: [Double] = []
        for (earlier, later) in zip(piece, piece.dropFirst()) where later.t > earlier.t {
            let step = Double(later.doneFiles - earlier.doneFiles) / (later.t - earlier.t)
            if step > 0 { rates.append(step) }
        }
        guard !rates.isEmpty else { return impossibleRate }
        let median = rates.sorted()[rates.count / 2]
        return min(impossibleRate, max(median * jumpRatio, minimumJumpRate))
    }

    private static func run(_ piece: [JobHistorySample], trimsTail: Bool) -> Run {
        let limit = jumpLimit(piece)
        let headStart = piece.first.map(\.doneFiles) ?? 0
        var timedPhotos = 0
        var jumpSeconds = 0.0
        var lastProgress = piece.first?.t ?? 0
        for (earlier, later) in zip(piece, piece.dropFirst()) where later.t > earlier.t {
            let step = later.doneFiles - earlier.doneFiles
            let span = later.t - earlier.t
            if Double(step) / span > limit {
                jumpSeconds += span
            } else {
                timedPhotos += step
            }
            if step > 0 { lastProgress = later.t }
        }
        let start = piece.first?.t ?? 0
        // A pass that held its count while matching ran has stopped
        // working where the count stopped.
        let kept = trimsTail ? piece.filter { $0.t <= lastProgress } : piece
        let points = kept.compactMap { sample -> JobSpeedGraph.Point? in
            guard let rate = sample.filesPerSecond, rate.isFinite, rate <= limit else { return nil }
            return JobSpeedGraph.Point(t: sample.t, value: max(rate, 0))
        }
        return Run(
            samples: piece,
            ratePoints: points,
            photos: headStart + timedPhotos,
            timedPhotos: timedPhotos,
            workSeconds: max(lastProgress - start - jumpSeconds, 0),
            start: start,
            end: kept.last?.t ?? start
        )
    }
}
