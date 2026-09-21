import Foundation

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

    init(minimumEmissionInterval: TimeInterval = 0.15, rateWindowSpan: TimeInterval = 6) {
        self.minimumEmissionInterval = minimumEmissionInterval
        self.rateWindowSpan = rateWindowSpan
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
        let now = ProcessInfo.processInfo.systemUptime
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
        videoFrames += videoFramesRead
        if failed { photosFailed += 1 }
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
        let now = ProcessInfo.processInfo.systemUptime
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
        lock.unlock()
        return JobTelemetry(
            step: step,
            activeItems: items,
            counters: counters,
            models: models,
            facts: facts
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
