import Foundation

/// Records one job into `JobHistoryStore` while it runs: the job row at
/// once, a speed sample about once a second, one row per file as it
/// settles, and the outcome at the end.
///
/// Built to stay out of the job's way. The calls a job makes (`observe`,
/// `fileSettled`) take a lock for a few arithmetic steps and hand the rest
/// to the recorder's own utility queue, which writes batches — every
/// `flushInterval` seconds, one transaction each. A store that cannot be
/// opened or written is logged and skipped; the job never sees an error.
///
/// Samples are also kept in memory for the job's lifetime, so the Jobs
/// window can draw the whole run without reading the database back.
public final class JobHistoryRecorder: @unchecked Sendable {
    /// At most one sample per this many seconds.
    public static let sampleInterval: TimeInterval = 1
    /// Buffered samples and file rows are written this often …
    public static let flushInterval: TimeInterval = 5
    /// … or as soon as this many file rows are waiting (a resumed sync
    /// settles thousands of already-verified files in its first seconds).
    public static let flushItemCount = 500
    /// Rates are over this trailing window, like the live chart's.
    public static let trailingWindow: TimeInterval = 5
    /// NAS-side verification credits a batch at a time, so its rate is
    /// averaged over a longer window (the live chart's `batchedWindow`).
    public static let batchedWindow: TimeInterval = 15

    /// System load at a sample, read by the app (Core has no GPU probe).
    public struct Load: Sendable {
        public var cpu: Double?
        public var gpu: Double?

        public init(cpu: Double?, gpu: Double?) {
            self.cpu = cpu
            self.gpu = gpu
        }
    }

    /// What a job reports, in the shape both `FileOperationProgress` and
    /// the app's job updates have.
    public struct Observation: Sendable {
        public var processedFiles: Int
        public var totalFiles: Int
        public var processedBytes: Int64
        public var totalBytes: Int64
        public var telemetry: JobTelemetry?

        public init(processedFiles: Int, totalFiles: Int, processedBytes: Int64, totalBytes: Int64, telemetry: JobTelemetry? = nil) {
            self.processedFiles = processedFiles
            self.totalFiles = totalFiles
            self.processedBytes = processedBytes
            self.totalBytes = totalBytes
            self.telemetry = telemetry
        }

        public init(_ progress: FileOperationProgress) {
            self.init(
                processedFiles: progress.processedFiles,
                totalFiles: progress.totalFiles,
                processedBytes: progress.processedBytes,
                totalBytes: progress.totalBytes,
                telemetry: progress.telemetry
            )
        }
    }

    /// One observation's cumulative counters, for the trailing-window rates.
    private struct Cumulative {
        var t: Double
        var transfer: Double
        var files: Double
        /// Phase label → (bytes, seconds the phase was running).
        var phases: [String: (bytes: Double, running: Double)]
    }

    /// Transfer rows in these phases are working; the rest show how their
    /// last file ended.
    static let busyPhases: Set<String> = ["Starting", "Copying", "Flushing", "Verifying", "Verifying on NAS", "Hashing", "Renaming"]

    public let jobID: UUID
    private let clock: @Sendable () -> TimeInterval
    private let startClock: TimeInterval
    private let loadProbe: (@Sendable () -> Load)?
    private let storeProvider: @Sendable () -> JobHistoryStore?
    private let queue = DispatchQueue(label: "CameraToolkit.JobHistory.recorder", qos: .utility)

    private let lock = NSLock()
    private var job: JobHistoryJob
    private var totalsPinned = false
    /// A sync's report has set the final counters; progress no longer does.
    private var reportNoted = false
    private var recordedSamples: [JobHistorySample] = []
    private var pendingSamples: [JobHistorySample] = []
    private var pendingItems: [JobHistoryItem] = []
    private var jobChanged = true
    private var lastSample: TimeInterval = -.infinity
    private var lastObservation: Observation?
    private var window: [Cumulative] = []
    private var finished = false

    // Confined to `queue`.
    private var resolvedStore: JobHistoryStore?
    private var storeResolved = false
    private var lastFlush: TimeInterval
    private var loggedWriteFailure = false

    /// `store` nil still records samples in memory; nothing is written.
    public convenience init(
        store: JobHistoryStore?,
        id: UUID = UUID(),
        kind: String,
        title: String,
        configuration: String? = nil,
        startedAt: Date = Date(),
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        loadProbe: (@Sendable () -> Load)? = nil
    ) {
        self.init(storeProvider: { store }, id: id, kind: kind, title: title, configuration: configuration, startedAt: startedAt, clock: clock, loadProbe: loadProbe)
    }

    /// Opens the shared store at `storeURL` on the recorder's queue, never
    /// on the caller's thread.
    public convenience init(
        storeURL: URL,
        id: UUID = UUID(),
        kind: String,
        title: String,
        configuration: String? = nil,
        startedAt: Date = Date(),
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        loadProbe: (@Sendable () -> Load)? = nil
    ) {
        self.init(storeProvider: { JobHistoryStore.shared(at: storeURL) }, id: id, kind: kind, title: title, configuration: configuration, startedAt: startedAt, clock: clock, loadProbe: loadProbe)
    }

    private init(
        storeProvider: @escaping @Sendable () -> JobHistoryStore?,
        id: UUID,
        kind: String,
        title: String,
        configuration: String?,
        startedAt: Date,
        clock: @escaping @Sendable () -> TimeInterval,
        loadProbe: (@Sendable () -> Load)?
    ) {
        jobID = id
        self.clock = clock
        self.loadProbe = loadProbe
        self.storeProvider = storeProvider
        startClock = clock()
        lastFlush = startClock
        job = JobHistoryJob(id: id, kind: kind, title: title, startedAt: startedAt, configuration: configuration)
    }

    /// The job has really started: its running row is written now, so a
    /// crash or quit still leaves a trace. A recorder that is never started
    /// writes nothing until the job reports something.
    public func start() {
        queue.async { self.flushOnQueue() }
    }

    /// Seconds since the job started, on the recorder's clock — the time
    /// base of samples and file rows alike.
    public func elapsed() -> TimeInterval {
        max(clock() - startClock, 0)
    }

    // MARK: Recording

    public func observe(_ progress: FileOperationProgress) {
        observe(Observation(progress))
    }

    /// A progress report. Becomes a sample when `sampleInterval` has passed
    /// since the last one (or `force`).
    public func observe(_ observation: Observation, force: Bool = false) {
        let t = elapsed()
        let sample: JobHistorySample? = lock.withLock {
            guard !finished else { return nil }
            lastObservation = observation
            let phases = observation.telemetry?.phases ?? []
            if !reportNoted {
                if !totalsPinned {
                    job.totalFiles = observation.totalFiles
                    job.totalBytes = observation.totalBytes
                }
                // A sync's bytes written to the NAS so far; other jobs' own counter.
                job.bytesDone = phases.first { $0.label == "Copy" }?.bytes ?? observation.processedBytes
                job.transferBytes = observation.telemetry?.transferBytes ?? job.transferBytes
                job.configuration = observation.telemetry?.configuration ?? job.configuration
                jobChanged = true
            }

            window.append(Cumulative(
                t: t,
                transfer: Double(max(observation.telemetry?.transferBytes ?? observation.processedBytes, 0)),
                files: Double(max(observation.processedFiles, 0)),
                phases: Dictionary(phases.map { ($0.label, (Double($0.bytes), $0.runningSeconds)) }, uniquingKeysWith: { a, _ in a })
            ))
            if let keep = window.lastIndex(where: { $0.t <= t - Self.batchedWindow - 2 }), keep > 0 {
                window.removeFirst(keep)
            }
            guard force || t - lastSample >= Self.sampleInterval else { return nil }
            lastSample = t
            return makeSample(at: t, observation)
        }
        guard let sample else { return }
        queue.async {
            var sample = sample
            if let load = self.loadProbe?() {
                sample.cpu = load.cpu
                sample.gpu = load.gpu
            }
            self.lock.withLock {
                self.recordedSamples.append(sample)
                self.pendingSamples.append(sample)
            }
            self.flushIfDue()
        }
    }

    /// Rates at `t` from the trailing window. Called under `lock`.
    private func makeSample(at t: Double, _ observation: Observation) -> JobHistorySample {
        guard let newest = window.last else { return JobHistorySample(t: t) }
        func reference(_ span: TimeInterval) -> Cumulative? {
            guard let reference = window.last(where: { $0.t <= t - span }) ?? window.first,
                  t - reference.t >= 1 else { return nil }
            return reference
        }
        let wall = reference(Self.trailingWindow)
        let combined = wall.map { max(newest.transfer - $0.transfer, 0) / (t - $0.t) / 1_000_000 }
        let files = wall.map { max(newest.files - $0.files, 0) / (t - $0.t) }
        func phaseRate(_ label: String, span: TimeInterval) -> Double? {
            guard let now = newest.phases[label], let reference = reference(span) else { return nil }
            let before = reference.phases[label] ?? (0, 0)
            let moved = now.bytes - before.bytes
            let running = now.running - before.running
            // A phase that did not run in the window has no rate.
            guard running >= 0.2, moved > 0 else { return nil }
            return moved / running / 1_000_000
        }
        let active = (observation.telemetry?.activeItems ?? []).count { Self.busyPhases.contains($0.phase ?? "") }
        return JobHistorySample(
            t: t,
            combined: combined,
            copy: phaseRate("Copy", span: Self.trailingWindow),
            verify: phaseRate("Verify", span: Self.trailingWindow),
            hash: phaseRate("Hash", span: Self.trailingWindow),
            remoteVerify: phaseRate(NASSyncRun.remoteVerifyPhase, span: Self.batchedWindow),
            filesPerSecond: files,
            activeTransfers: active,
            transferBytes: observation.telemetry?.transferBytes,
            doneBytes: observation.processedBytes,
            doneFiles: observation.processedFiles,
            secondsRemaining: observation.telemetry?.work?.secondsRemaining
        )
    }

    /// A file settled. Its counts go on the job row as they come, so an
    /// interrupted job still says what it did.
    public func fileSettled(_ item: JobHistoryItem) {
        let due: Bool = lock.withLock {
            guard !finished else { return false }
            pendingItems.append(item)
            switch item.outcome {
            case .copied: job.copied += 1
            case .matched: job.matchedExisting += 1
            case .alreadyVerified: job.alreadyVerified += 1
            case .conflict: job.conflicts += 1
            case .failed: job.failed += 1
            }
            jobChanged = true
            return true
        }
        if due { queue.async { self.flushIfDue() } }
    }

    /// The job's real size, when the job knows it better than its progress
    /// counters do (a sync's work counter is twice its bytes).
    public func setTotals(files: Int, bytes: Int64) {
        lock.withLock {
            totalsPinned = true
            job.totalFiles = files
            job.totalBytes = bytes
            jobChanged = true
        }
    }

    /// A finished sync's report: the authoritative counts and where the
    /// time went. Takes one last sample, so the chart reaches the end.
    public func noteSyncReport(_ report: NASSyncReport, phases: [JobPhaseTotal], transferBytes: Int64, configuration: String, verifyMethod: String) {
        lock.withLock {
            reportNoted = true
            job.copied = report.copied.count
            job.matchedExisting = report.matchedExisting.count
            job.alreadyVerified = report.alreadyVerified.count
            job.conflicts = report.conflicts.count
            job.failed = report.failed.count
            job.bytesDone = report.bytesCopied
            job.transferBytes = transferBytes
            job.configuration = configuration
            var summary = job.summary ?? JobHistorySummary()
            summary.phases = phases
            summary.timings = report.timings
            summary.verifyMethod = verifyMethod
            summary.stoppedReason = report.stoppedReason
            summary.notAttempted = report.notAttempted
            summary.hashMismatches = report.hashMismatches.count
            summary.foldersCreated = report.foldersCreated
            job.summary = summary
            jobChanged = true
        }
        if let last = lock.withLock({ lastObservation }) {
            observe(last, force: true)
        }
    }

    /// The job ended. `totals` are the job's final counters for jobs that
    /// did not pin their own. Everything buffered is written.
    public func finish(outcome: JobHistoryOutcome, note: String?, totals: Observation? = nil, endedAt: Date = Date()) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            if let totals, !totalsPinned {
                job.totalFiles = totals.totalFiles
                job.totalBytes = totals.totalBytes
                if !reportNoted {
                    job.bytesDone = totals.processedBytes
                }
            }
            job.outcome = outcome
            job.endedAt = endedAt
            var summary = job.summary ?? JobHistorySummary()
            summary.note = note
            job.summary = summary
            jobChanged = true
        }
        queue.async { self.flushOnQueue() }
    }

    // MARK: Reading back

    /// Every sample so far, in time order.
    public func samples() -> [JobHistorySample] {
        lock.withLock { recordedSamples }
    }

    /// The job row as it stands.
    public func currentJob() -> JobHistoryJob {
        lock.withLock { job }
    }

    /// Writes everything buffered and waits for it — at quit, and in tests.
    public func flush() {
        queue.sync { flushOnQueue() }
    }

    /// Waits for queued work without forcing a write — tests use it to see
    /// what the batching alone has written.
    func drain() {
        queue.sync {}
    }

    // MARK: Writing (queue)

    private func flushIfDue() {
        let waitingItems = lock.withLock { pendingItems.count }
        guard clock() - lastFlush >= Self.flushInterval || waitingItems >= Self.flushItemCount else { return }
        flushOnQueue()
    }

    private func flushOnQueue() {
        lastFlush = clock()
        if !storeResolved {
            storeResolved = true
            resolvedStore = storeProvider()
        }
        let batch: (job: JobHistoryJob?, samples: [JobHistorySample], items: [JobHistoryItem]) = lock.withLock {
            defer {
                pendingSamples.removeAll(keepingCapacity: true)
                pendingItems.removeAll(keepingCapacity: true)
                jobChanged = false
            }
            return (jobChanged ? job : nil, pendingSamples, pendingItems)
        }
        guard let store = resolvedStore else { return }
        do {
            try store.write(job: batch.job, samples: batch.samples, items: batch.items, jobID: jobID)
        } catch {
            // History is best effort: the batch is dropped, the job goes on.
            guard !loggedWriteFailure else { return }
            loggedWriteFailure = true
            DebugLog.shared.log("history.write", subsystem: .history, level: .error, outcome: .error, error: error.localizedDescription, detail: lock.withLock { job.kind })
        }
    }
}
