import Foundation

/// Smoothed units-per-second for a scan's time-left readout. Rates are
/// measured over real intervals of at least `bucket` seconds (units done ÷
/// time elapsed), never as per-tick deltas, so a stretch with no finished
/// file cannot decay the rate toward zero; the exponential weight has a
/// `timeConstant` of ~20 s, so the last 30–60 s dominate. Until `warmup`
/// seconds have passed it reports nothing — the first files are too few
/// and too uneven to extrapolate from.
struct ScanRateEstimator: Sendable {
    let warmup: TimeInterval
    let bucket: TimeInterval
    let timeConstant: TimeInterval

    private(set) var startedAt: TimeInterval?
    private var bucketStart: TimeInterval = 0
    private var bucketUnits: Double = 0
    private(set) var rate: Double = 0

    init(warmup: TimeInterval = 15, bucket: TimeInterval = 1, timeConstant: TimeInterval = 20) {
        self.warmup = warmup
        self.bucket = bucket
        self.timeConstant = timeConstant
    }

    mutating func start(at now: TimeInterval) {
        startedAt = now
        bucketStart = now
        bucketUnits = 0
        rate = 0
    }

    /// Cumulative units done as of `now`.
    mutating func record(units: Double, at now: TimeInterval) {
        guard let startedAt else {
            start(at: now)
            return
        }
        let span = now - bucketStart
        guard span >= bucket else { return }
        let elapsed = now - startedAt
        if elapsed <= warmup {
            // During the warm-up the job average is the best guess; it
            // seeds the smoothed rate so it does not start from zero.
            rate = elapsed > 0 ? units / elapsed : 0
        } else {
            let instantaneous = max(units - bucketUnits, 0) / span
            let alpha = 1 - exp(-span / timeConstant)
            rate += alpha * (instantaneous - rate)
        }
        bucketStart = now
        bucketUnits = units
    }

    /// Seconds to finish `remaining` units, or nil while warming up or
    /// before any rate exists.
    func secondsRemaining(_ remaining: Double, at now: TimeInterval) -> Double? {
        guard let startedAt, now - startedAt >= warmup else { return nil }
        guard remaining > 0 else { return 0 }
        guard rate > 0 else { return nil }
        return remaining / rate
    }
}

/// Live, lock-protected counters for a running face scan — the payload the
/// Jobs window's activity pane renders. Scan workers record which file they
/// hold and which pipeline step it is in; every mutation is O(1) under a
/// lock, so telemetry never gates the pipeline. Progress emissions snapshot
/// it into `JobTelemetry`.
final class FaceScanTelemetry: @unchecked Sendable {
    /// The pipeline steps one scanned file moves through, in order.
    enum Step: String, Sendable, CaseIterable {
        case decode
        case detect
        case align
        case embed
        case write

        var label: String {
            switch self {
            case .decode: "Decode"
            case .detect: "Detect"
            case .align: "Align"
            case .embed: "Embed"
            case .write: "Write"
            }
        }

        fileprivate var rank: Int {
            switch self {
            case .decode: 0
            case .detect: 1
            case .align: 2
            case .embed: 3
            case .write: 4
            }
        }
    }

    private struct InFlight {
        var name: String
        var path: String
        var step: Step
    }

    /// One clip's share of the work: its size until it opens, then its
    /// exact planned frame count, then — once finished — what it did.
    private struct VideoWork {
        var bytes: Int64
        var duration: TimeInterval?
        var plannedFrames: Int?
        var framesAttempted = 0
        var framesDecoded = 0
        var finished = false
    }

    /// The pass's work plan: one unit per still, one per planned frame.
    private struct WorkPlan {
        var photoTokens: Set<Int> = []
        var photosDone = 0
        var videos: [Int: VideoWork] = [:]
        var stride: TimeInterval = 1
        var maximumFrames = Int.max
    }

    private let lock = NSLock()
    /// Item index → what that worker is doing right now.
    private var inFlight: [Int: InFlight] = [:]
    /// Whole-job stage once the per-file pass ends ("Match", "Group").
    private var stage: String?
    private var facesDetected = 0
    private var photosFailed = 0
    private var videoFrames = 0
    private var matched = 0
    private var grouped = 0
    private var groupsCreated = 0
    private var bytesRead: Int64 = 0
    /// (systemUptime, cumulative bytesRead) — pruned to `rateWindowSpan`
    /// so the reported rate is the recent rate, not the job average.
    private var rateWindow: [(uptime: TimeInterval, bytes: Int64)] = []
    private var lastEmission = -TimeInterval.greatestFiniteMagnitude
    private let minimumEmissionInterval: TimeInterval
    private let rateWindowSpan: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private var plan: WorkPlan?
    private var filesFinished = 0
    private var unitRate: ScanRateEstimator
    /// Called (outside the lock) whenever a video frame lands, so a long
    /// clip in flight still reports progress between file completions.
    private var unitsChanged: (@Sendable () -> Void)?

    init(
        minimumEmissionInterval: TimeInterval = 0.15,
        rateWindowSpan: TimeInterval = 6,
        rateEstimator: ScanRateEstimator = ScanRateEstimator(),
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.minimumEmissionInterval = minimumEmissionInterval
        self.rateWindowSpan = rateWindowSpan
        self.unitRate = rateEstimator
        self.clock = clock
    }

    // MARK: - Work plan

    /// Declares the pass's work: `photos` still tokens and `videos` clip
    /// tokens with their byte sizes. Clip durations are learned as each
    /// clip opens; until then a clip's frames are extrapolated from the
    /// bytes-per-second of the clips already opened.
    func planWork(
        photos: [Int],
        videos: [(token: Int, bytes: Int64)],
        stride: TimeInterval?,
        maximumFrames: Int
    ) {
        lock.lock()
        var plan = WorkPlan()
        plan.photoTokens = Set(photos)
        for video in videos {
            plan.videos[video.token] = VideoWork(bytes: video.bytes)
        }
        plan.stride = max(stride ?? 1, 0.001)
        plan.maximumFrames = max(maximumFrames, 1)
        self.plan = plan
        unitRate.start(at: clock())
        lock.unlock()
    }

    /// Routes frame-level progress to the job's progress channel.
    func onUnitsChanged(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        unitsChanged = handler
        lock.unlock()
    }

    /// A clip opened: its exact frame plan replaces the size estimate.
    func openVideo(_ token: Int, duration: TimeInterval, plannedFrames: Int) {
        lock.lock()
        plan?.videos[token]?.duration = duration
        plan?.videos[token]?.plannedFrames = plannedFrames
        lock.unlock()
    }

    /// One sampled frame was attempted on `token` — decoded or not, it is
    /// a unit of the plan done.
    func noteFrame(_ token: Int, decoded: Bool) {
        lock.lock()
        plan?.videos[token]?.framesAttempted += 1
        if decoded {
            plan?.videos[token]?.framesDecoded += 1
            videoFrames += 1
        }
        recordUnitsLocked()
        let handler = unitsChanged
        lock.unlock()
        handler?()
    }

    var finishedFiles: Int {
        lock.lock()
        defer { lock.unlock() }
        return filesFinished
    }

    /// A worker picked up `file` — it is in the decode step until told
    /// otherwise.
    func begin(_ token: Int, file: OrganizeFile) {
        lock.lock()
        inFlight[token] = InFlight(name: file.name, path: file.path, step: .decode)
        lock.unlock()
    }

    func step(_ token: Int, _ step: Step) {
        lock.lock()
        inFlight[token]?.step = step
        lock.unlock()
    }

    /// Media bytes consumed — recorded when the decode that read them
    /// finishes, so the rate tracks real read work.
    func noteReadBytes(_ bytes: Int64) {
        guard bytes > 0 else { return }
        lock.lock()
        bytesRead += bytes
        let now = clock()
        rateWindow.append((now, bytesRead))
        while let first = rateWindow.first, now - first.uptime > rateWindowSpan {
            rateWindow.removeFirst()
        }
        lock.unlock()
    }

    /// The worker is done with `token` — fold its outcome into the counters.
    func finish(_ token: Int, faces: Int, videoFramesRead: Int, failed: Bool) {
        lock.lock()
        inFlight.removeValue(forKey: token)
        facesDetected += faces
        filesFinished += 1
        if failed { photosFailed += 1 }
        if var video = plan?.videos[token] {
            // Frames already counted live are not counted twice; a clip
            // that ended early (or failed) keeps only the frames it ran.
            videoFrames += max(videoFramesRead - video.framesDecoded, 0)
            video.finished = true
            plan?.videos[token] = video
        } else {
            videoFrames += videoFramesRead
            if plan?.photoTokens.contains(token) == true {
                plan?.photosDone += 1
            }
        }
        recordUnitsLocked()
        lock.unlock()
    }

    /// The per-file pass ended; the job is now in a named stage.
    func enterStage(_ name: String) {
        lock.lock()
        stage = name
        inFlight.removeAll()
        lock.unlock()
    }

    func noteMatch() {
        lock.lock()
        matched += 1
        lock.unlock()
    }

    func noteGrouped(assigned: Int, groupsCreated newGroups: Int) {
        lock.lock()
        grouped += assigned
        groupsCreated += newGroups
        lock.unlock()
    }

    /// Rate-limit progress emissions off the workers — each one posts to
    /// the main actor, so without this a fast burst floods the UI.
    func shouldEmit(force: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        guard force || now - lastEmission >= minimumEmissionInterval else { return false }
        lastEmission = now
        return true
    }

    var totalBytesRead: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return bytesRead
    }

    /// Recent media-read rate from the sliding window; 0 until two samples
    /// exist or when the scan stalls.
    var bytesPerSecond: Double {
        lock.lock()
        defer { lock.unlock() }
        guard let first = rateWindow.first, let last = rateWindow.last,
              last.uptime > first.uptime else { return 0 }
        return Double(last.bytes - first.bytes) / (last.uptime - first.uptime)
    }

    /// Work units done and planned right now, and whether the total leans
    /// on extrapolated clips. `total` is nil while unopened clips exist and
    /// no clip has opened yet to learn a bitrate from.
    private func unitsLocked() -> (done: Int, total: Int?, estimated: Bool)? {
        guard let plan else { return nil }
        var done = plan.photosDone
        var total = plan.photoTokens.count
        var openedBytes: Int64 = 0
        var openedSeconds: TimeInterval = 0
        var unopenedBytes: [Int64] = []
        for video in plan.videos.values {
            done += video.framesAttempted
            if video.finished {
                total += video.framesAttempted
            } else if let planned = video.plannedFrames {
                total += max(planned, video.framesAttempted)
            } else {
                unopenedBytes.append(video.bytes)
            }
            if let duration = video.duration, duration > 0 {
                openedBytes += video.bytes
                openedSeconds += duration
            }
        }
        guard !unopenedBytes.isEmpty else { return (done, total, false) }
        guard openedSeconds > 0, openedBytes > 0 else { return (done, nil, true) }
        let bytesPerSecond = Double(openedBytes) / openedSeconds
        for bytes in unopenedBytes {
            let seconds = Double(bytes) / bytesPerSecond
            let frames = Int((seconds / plan.stride).rounded()) + 1
            total += min(max(frames, 1), plan.maximumFrames)
        }
        return (done, total, true)
    }

    private func recordUnitsLocked() {
        guard let units = unitsLocked() else { return }
        unitRate.record(units: Double(units.done), at: clock())
    }

    private func workLocked() -> JobWorkEstimate? {
        guard stage == nil, let plan, let units = unitsLocked() else { return nil }
        let label: String?
        if plan.videos.isEmpty {
            label = nil
        } else {
            label = plan.photoTokens.isEmpty ? "frames" : "photos and frames"
        }
        let remaining = units.total.map { Double(max($0 - units.done, 0)) }
        return JobWorkEstimate(
            unitsDone: units.done,
            unitsTotal: units.total,
            totalIsEstimate: units.estimated,
            unitLabel: label,
            secondsRemaining: remaining.flatMap { unitRate.secondsRemaining($0, at: clock()) }
        )
    }

    /// What the Jobs pane should render right now. `skipped` lives on the
    /// scan report (it is decided before the pass), so it is passed in.
    func snapshot(skipped: Int, models: [String], facts: [String]) -> JobTelemetry {
        lock.lock()
        let items = inFlight
            .sorted { $0.key < $1.key }
            .map { JobActiveItem(name: $0.value.name, path: $0.value.path, step: $0.value.step.label) }
        let step: String?
        if let stage {
            step = stage
        } else {
            step = dominantStep().map(\.label)
        }
        var counters: [JobCounter] = [JobCounter(label: "Faces", value: facesDetected)]
        if matched > 0 { counters.append(JobCounter(label: "Matched", value: matched)) }
        if grouped > 0 { counters.append(JobCounter(label: "Grouped", value: grouped)) }
        if groupsCreated > 0 { counters.append(JobCounter(label: "New groups", value: groupsCreated)) }
        if skipped > 0 { counters.append(JobCounter(label: "Skipped", value: skipped)) }
        if photosFailed > 0 { counters.append(JobCounter(label: "Failed", value: photosFailed)) }
        if videoFrames > 0 { counters.append(JobCounter(label: "Video frames", value: videoFrames)) }
        let work = workLocked()
        lock.unlock()
        return JobTelemetry(
            step: step,
            activeItems: items,
            counters: counters,
            models: models,
            facts: facts,
            work: work
        )
    }

    /// The step most in-flight files are in; ties go to the later pipeline
    /// step, which is where the time is actually going.
    private func dominantStep() -> Step? {
        var counts: [Step: Int] = [:]
        for item in inFlight.values {
            counts[item.step, default: 0] += 1
        }
        return counts.max {
            $0.value != $1.value ? $0.value < $1.value : $0.key.rank < $1.key.rank
        }?.key
    }
}
