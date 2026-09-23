import Darwin
import Foundation

// MARK: - Request, update, workload seam

/// Everything a stability run needs, resolved by the app layer.
public struct StabilityTestRequest: Sendable {
    /// The mounted volume under test — probed for USB counters and watched
    /// for disappearance.
    public var volumeRoot: URL
    /// The Buffer or library folder writes are allowed in. Nil means the
    /// drive is read-only and only read/burst phases run.
    public var writeDirectory: URL?
    /// Existing media to sample for read phases. Read phases always
    /// prefer this media over the test's own temp file — reads of
    /// just-written data can come back from cache instead of the device.
    public var searchRoots: [URL]
    public var profile: StabilityProfile
    /// The detected link's typical MB/s range — feeds the
    /// "under about half of typical" warning and, when the negotiated
    /// link rate is unknown, the above-ceiling sample exclusion.
    public var typicalRangeMBps: ClosedRange<Double>?
    /// Distinguishes units that share a placeholder serial.
    public var volumeUUID: String?
    public var cableLabel: String
    public var portLabel: String

    public init(
        volumeRoot: URL,
        writeDirectory: URL? = nil,
        searchRoots: [URL] = [],
        profile: StabilityProfile = .standard,
        typicalRangeMBps: ClosedRange<Double>? = nil,
        volumeUUID: String? = nil,
        cableLabel: String = "",
        portLabel: String = ""
    ) {
        self.volumeRoot = volumeRoot
        self.writeDirectory = writeDirectory
        self.searchRoots = searchRoots
        self.profile = profile
        self.typicalRangeMBps = typicalRangeMBps
        self.volumeUUID = volumeUUID
        self.cableLabel = cableLabel
        self.portLabel = portLabel
    }
}

/// One ~1 Hz tick of live state during a run.
public struct StabilityTestUpdate: Equatable, Sendable {
    /// Nil while the run is still preparing (preflight, first probe read).
    public var phase: StabilityPhaseKind?
    public var phaseIndex: Int
    public var phaseCount: Int
    public var phaseRemaining: TimeInterval
    public var runRemaining: TimeInterval
    /// Throughput over the recent rolling window (about
    /// `throughputWindowSeconds`), for the live graph.
    public var bytesPerSecond: Double
    public var mounted: Bool
    /// False → the UI says "USB counters not available on this connection".
    public var usbCountersAvailable: Bool
    /// Counters since the run's baseline — always deltas, never raw
    /// cumulative-since-boot values.
    public var counterDelta: [String: Int64]
    public var linkBitsPerSecond: Int64?
    /// Port derived from the registry location, e.g. "USB-C port 2".
    public var detectedPortLabel: String?
    public var device: USBDeviceIdentity?

    public init(
        phase: StabilityPhaseKind? = nil,
        phaseIndex: Int = 0,
        phaseCount: Int = 0,
        phaseRemaining: TimeInterval = 0,
        runRemaining: TimeInterval = 0,
        bytesPerSecond: Double = 0,
        mounted: Bool = true,
        usbCountersAvailable: Bool = false,
        counterDelta: [String: Int64] = [:],
        linkBitsPerSecond: Int64? = nil,
        detectedPortLabel: String? = nil,
        device: USBDeviceIdentity? = nil
    ) {
        self.phase = phase
        self.phaseIndex = phaseIndex
        self.phaseCount = phaseCount
        self.phaseRemaining = phaseRemaining
        self.runRemaining = runRemaining
        self.bytesPerSecond = bytesPerSecond
        self.mounted = mounted
        self.usbCountersAvailable = usbCountersAvailable
        self.counterDelta = counterDelta
        self.linkBitsPerSecond = linkBitsPerSecond
        self.detectedPortLabel = detectedPortLabel
        self.device = device
    }
}

/// What actually moves bytes in each phase. The production workload writes
/// and reads a bounded cycling temp area; tests substitute a fake to drive
/// the clock, simulate drops, and prove read-only drives are never written.
public protocol StabilityWorkload: AnyObject, Sendable {
    /// Set up for a phase — open descriptors, start burst workers.
    func begin(phase: StabilityPhaseKind) throws
    /// One bounded unit of work; returns the bytes it moved (0 allowed —
    /// idle watch moves none by design). Must return reasonably promptly so
    /// the supervisor's liveness heartbeat keeps working; a step parked in
    /// a dead mount's syscall is what the watchdog bounds.
    func step(phase: StabilityPhaseKind, shouldStop: @Sendable () -> Bool) throws -> Int64
    /// Phase finished — release what `begin` took. Never throws.
    func end(phase: StabilityPhaseKind)
    /// Remove the temp area and release whatever is left. Called on every
    /// exit path — success, failure, cancel, drop.
    func cleanup()
    /// True when the running phase reads the test's own temp file because
    /// the drive offered no readable media — those bytes can come back
    /// from cache, so the report labels the phase "may include cache".
    var readsMayIncludeCache: Bool { get }
}

extension StabilityWorkload {
    public var readsMayIncludeCache: Bool { false }
}

// MARK: - Service

/// Runs a fixed-profile cable/enclosure stability test against one mounted
/// volume. I/O happens through a `StabilityWorkload` on a supervised worker
/// so a parked syscall fails the run instead of hanging it, and USB port
/// counters are sampled about once a second as deltas from the run's start.
public struct StabilityTestService: @unchecked Sendable {
    /// Hidden temp files a run creates inside the writable directory.
    public static let temporaryFilePrefix = ".CameraToolkit-Stability-"
    /// The temp area cycles instead of growing — a run never owns more
    /// than this on disk at once.
    public static let maximumTempAreaBytes: Int64 = 8 * 1024 * 1024 * 1024
    /// Below this the area is too small to mean anything.
    public static let minimumTempAreaBytes: Int64 = 256 * 1024 * 1024
    /// Headroom kept free beyond the temp area.
    public static let freeSpaceReserve: Int64 = 1024 * 1024 * 1024
    public static let writeChunkByteCount: Int64 = 8 * 1024 * 1024
    public static let readChunkByteCount = 4 * 1024 * 1024
    /// A stretch with no progress this long earns a stall warning.
    public static let stallWarningSeconds: TimeInterval = 2
    /// Abort a run whose worker has not completed a unit of work for this
    /// long — the dead-mount bound.
    public static let defaultStallTimeout: TimeInterval = 15
    /// Port counters and mount state are re-read about this often.
    public static let defaultSampleInterval: TimeInterval = 1
    /// Reported throughput is measured over a rolling window this long —
    /// per-second deltas alias bursty completions into fake peaks and
    /// dips, so min/typical/max quote windowed rates instead.
    public static let throughputWindowSeconds: TimeInterval = 3
    /// Cap on enumeration while looking for media to read — discovery
    /// must stay bounded.
    static let mediaSampleFileLimit = 512
    /// Media files at least this big are preferred for read phases —
    /// sequential reads off tiny files measure seeking more than the
    /// link. Smaller files are used only when nothing bigger exists.
    static let mediaReadMinimumBytes: Int64 = 8 * 1024 * 1024

    private let fileManager: FileManager
    private let probe: any USBPortHealthProbing
    private let workloadFactory: @Sendable (StabilityTestRequest, Int64) throws -> any StabilityWorkload
    private let uptime: @Sendable () -> TimeInterval
    private let isMounted: @Sendable (URL) -> Bool
    private let stallTimeout: TimeInterval
    private let sampleInterval: TimeInterval
    private let supervisor: RunSupervisor

    /// `probe`, `workloadFactory`, `uptime`, `isMounted`, `sampleInterval`
    /// are test seams — production callers use the defaults, which walk
    /// the real IORegistry, write real files, and read the real clock.
    public init(
        fileManager: FileManager = .default,
        probe: (any USBPortHealthProbing)? = nil,
        workloadFactory: (@Sendable (StabilityTestRequest, Int64) throws -> any StabilityWorkload)? = nil,
        uptime: (@Sendable () -> TimeInterval)? = nil,
        isMounted: (@Sendable (URL) -> Bool)? = nil,
        stallTimeout: TimeInterval = StabilityTestService.defaultStallTimeout,
        sampleInterval: TimeInterval = StabilityTestService.defaultSampleInterval
    ) {
        self.fileManager = fileManager
        self.probe = probe ?? USBPortHealthProbe()
        let uptime = uptime ?? { ProcessInfo.processInfo.systemUptime }
        self.uptime = uptime
        self.isMounted = isMounted ?? Self.mountPresent
        self.stallTimeout = stallTimeout
        self.sampleInterval = sampleInterval
        self.workloadFactory = workloadFactory ?? { request, areaBytes in
            FileStabilityWorkload(request: request, areaBytes: areaBytes)
        }
        self.supervisor = RunSupervisor(
            stallTimeout: stallTimeout,
            uptime: uptime,
            queueLabel: "CameraToolkit.StabilityTest.io",
            stalledError: {
                ToolkitError.commandFailed(
                    "The drive stopped responding — no data moved for a while, so the stability test was abandoned. This can mean an overheating or underpowered enclosure or cable, or a drive that dropped off the bus."
                )
            },
            missingResultError: {
                ToolkitError.commandFailed("The stability test did not produce a result.")
            }
        )
    }

    /// The temp area size for a writable run: capped at 8 GB, shrunk when
    /// free space is short, nil when there is not enough to bother.
    public static func boundedAreaBytes(freeBytes: Int64) -> Int64? {
        let usable = freeBytes - freeSpaceReserve
        guard usable >= minimumTempAreaBytes else { return nil }
        return min(maximumTempAreaBytes, usable)
    }

    static func mountPresent(_ url: URL) -> Bool {
        var info = Darwin.statfs()
        return url.withUnsafeFileSystemRepresentation { path in
            path.map { statfs($0, &info) == 0 } ?? false
        }
    }

    /// Runs the profile and returns the graded record — including on
    /// failure, so history keeps the drops as well as the passes. Throws
    /// `CancellationError` when stopped and a `ToolkitError` when the run
    /// cannot even be set up.
    @discardableResult
    public func run(
        _ request: StabilityTestRequest,
        updates: @escaping @Sendable (StabilityTestUpdate) -> Void = { _ in }
    ) throws -> StabilityTestRecord {
        let box = RunStateBox()
        var thrownError: Error?
        do {
            try supervisor.run { monitor in
                try self.execute(request: request, monitor: monitor, box: box, updates: updates)
            }
        } catch is CancellationError {
            _ = boundedCleanup(box.workload)
            throw CancellationError()
        } catch {
            thrownError = error
        }

        if let cleanupError = boundedCleanup(box.workload) {
            box.noteCleanupIssue(cleanupError)
        }

        var summary = box.summary
        if summary.failureMessage == nil, let thrownError {
            summary.failureMessage = thrownError.localizedDescription
        }
        let verdict = StabilityVerdict.evaluate(
            summary: summary,
            typicalRangeMBps: request.typicalRangeMBps
        )
        return StabilityTestRecord(
            finishedAt: Date(),
            profile: request.profile.rawValue,
            cableLabel: request.cableLabel,
            portLabel: request.portLabel,
            grade: verdict.grade,
            headline: verdict.headline,
            reasons: verdict.reasons,
            advice: verdict.advice,
            phases: summary.phases.map(StabilityPhaseRecord.init(metrics:)),
            counterDeltas: summary.counterDelta,
            linkBitsPerSecond: box.linkBitsPerSecond,
            powerSinkAllocation: box.device?.powerSinkAllocation,
            enclosure: box.device,
            volumeUUID: box.volumeUUID ?? request.volumeUUID,
            durationSeconds: box.elapsed,
            completed: summary.finishedAllPhases
        )
    }

    /// The worker side of the run — preflight, baseline probe, then every
    /// phase to its deadline or the first hard failure.
    private func execute(
        request: StabilityTestRequest,
        monitor: RunLivenessMonitor<Void>,
        box: RunStateBox,
        updates: @Sendable (StabilityTestUpdate) -> Void
    ) throws {
        let canWrite = request.writeDirectory != nil
        let phases = request.profile.phases(canWrite: canWrite)
        guard !phases.isEmpty else {
            throw ToolkitError.commandFailed(
                "This drive is read-only and has no readable media to test."
            )
        }

        var areaBytes: Int64 = 0
        if let directory = request.writeDirectory {
            // Preflight runs inside supervision too — on a dead mount even a
            // stat can block, and Stop must never hang.
            try FileScanner(fileManager: fileManager).assertDirectory(directory)
            let free = try freeBytes(at: directory)
            guard let area = Self.boundedAreaBytes(freeBytes: free) else {
                throw ToolkitError.commandFailed(
                    "Not enough free space for the test's bounded temporary area. Keep at least \(Self.minimumTempAreaBytes + Self.freeSpaceReserve) bytes available."
                )
            }
            areaBytes = area
        }
        let workload = try workloadFactory(request, areaBytes)
        box.workload = workload
        box.volumeUUID = request.volumeUUID ?? volumeUUIDString(of: request.volumeRoot)

        let baseline = probe.sample(volumeRoot: request.volumeRoot)
        box.noteBaseline(baseline)
        let totalSeconds = phases.reduce(0) { $0 + $1.seconds }
        let runStart = uptime()
        box.startedAt = runStart
        var portEntryID = baseline?.portEntryID

        updates(box.makeUpdate(
            phase: nil, phaseIndex: 0, phaseCount: phases.count,
            phaseRemaining: 0, runRemaining: totalSeconds,
            bytesPerSecond: 0, mounted: isMounted(request.volumeRoot)
        ))

        for (index, phase) in phases.enumerated() {
            if monitor.shouldStop { throw CancellationError() }
            let phaseStart = uptime()
            let phaseEnd = phaseStart + phase.seconds
            var phaseBytes: Int64 = 0
            var phaseSamples: [Double] = []
            var cacheAffectedSamples = 0
            var window = ThroughputWindow(span: Self.throughputWindowSeconds)
            var phaseReadsMayIncludeCache = false
            var intervalBytes: Int64 = 0
            var lastProgressAt = phaseStart
            var lastSampleAt = phaseStart
            var nextSampleAt = phaseStart
            var completed = true
            var openStall: (phase: StabilityPhaseKind, since: TimeInterval)?

            do {
                try workload.begin(phase: phase.kind)
                phaseReadsMayIncludeCache = workload.readsMayIncludeCache
            } catch {
                box.noteFailure(error.localizedDescription)
                completed = false
            }

            phaseLoop: while completed && uptime() < phaseEnd {
                if monitor.shouldStop {
                    workload.end(phase: phase.kind)
                    throw CancellationError()
                }
                let now = uptime()
                do {
                    let moved = try workload.step(
                        phase: phase.kind,
                        shouldStop: { monitor.shouldStop }
                    )
                    monitor.markChunkCompleted(at: uptime())
                    if moved > 0 {
                        phaseBytes += moved
                        intervalBytes += moved
                        if let stall = openStall {
                            box.noteStall(
                                StabilityStall(phase: stall.phase, seconds: now - stall.since)
                            )
                            openStall = nil
                        }
                        lastProgressAt = now
                    } else if phase.kind.movesBytes,
                              openStall == nil,
                              now - lastProgressAt >= Self.stallWarningSeconds {
                        openStall = (phase.kind, lastProgressAt)
                    }
                } catch {
                    box.noteFailure(error.localizedDescription)
                    completed = false
                    break phaseLoop
                }
                if !isMounted(request.volumeRoot) {
                    box.noteMountLost()
                    completed = false
                    break phaseLoop
                }
                if now >= nextSampleAt {
                    let interval = max(now - lastSampleAt, 0.001)
                    let moved = intervalBytes
                    intervalBytes = 0
                    lastSampleAt = now
                    nextSampleAt = now + sampleInterval
                    var rate = Double(moved) / interval
                    if phase.kind.movesBytes {
                        window.append(bytes: moved, seconds: interval)
                        rate = window.rate
                        // Only a full window feeds min/typical/max — a
                        // lone fast tick is not a sustained figure. A
                        // window faster than the link can physically
                        // carry came from cache or a buffer, so it is
                        // counted and left out.
                        if window.isFull {
                            if let ceiling = Self.linkCeilingBytesPerSecond(
                                linkBitsPerSecond: box.currentLinkBitsPerSecond,
                                typicalRangeMBps: request.typicalRangeMBps
                            ), window.rate > ceiling {
                                cacheAffectedSamples += 1
                            } else {
                                phaseSamples.append(window.rate)
                            }
                        }
                    }
                    let sample = samplePort(entryID: portEntryID, volumeRoot: request.volumeRoot)
                    if let newID = sample?.portEntryID { portEntryID = newID }
                    box.noteSample(sample)
                    updates(box.makeUpdate(
                        phase: phase.kind, phaseIndex: index, phaseCount: phases.count,
                        phaseRemaining: max(phaseEnd - now, 0),
                        runRemaining: max(phaseEnd - now, 0) + phases[(index + 1)...].reduce(0) { $0 + $1.seconds },
                        bytesPerSecond: rate, mounted: true
                    ))
                }
            }
            if let stall = openStall {
                box.noteStall(
                    StabilityStall(phase: stall.phase, seconds: uptime() - stall.since)
                )
                openStall = nil
            }
            workload.end(phase: phase.kind)
            box.notePhase(StabilityPhaseMetrics(
                kind: phase.kind,
                seconds: uptime() - phaseStart,
                bytesMoved: phaseBytes,
                samplesBytesPerSecond: phaseSamples,
                completed: completed && uptime() >= phaseEnd - 0.001,
                cacheAffectedSamples: cacheAffectedSamples,
                readsMayIncludeCache: phaseReadsMayIncludeCache
            ))
            if !completed || box.hasFailure { break }
        }
        box.finished(at: uptime())
    }

    /// Above this rate a window cannot be device truth — the bytes came
    /// from a cache or a buffer. USB 3.x goodput tops out near 88% of the
    /// negotiated wire rate; slower links use the wire rate itself (their
    /// real ceiling sits under it anyway). When the negotiated rate is
    /// unknown, the caller's typical range supplies a softer ceiling.
    private static func linkCeilingBytesPerSecond(
        linkBitsPerSecond: Int64?,
        typicalRangeMBps: ClosedRange<Double>?
    ) -> Double? {
        if let bits = linkBitsPerSecond, bits > 0 {
            let wire = Double(bits) / 8
            return bits >= 5_000_000_000 ? wire * 0.88 : wire
        }
        if let upper = typicalRangeMBps?.upperBound, upper > 0 {
            return upper * 1_000_000 * 1.2
        }
        return nil
    }

    /// Re-read the port by entry id first — it survives the device dropping
    /// off the bus — falling back to the full walk when the port entry is
    /// gone or was never resolved.
    private func samplePort(entryID: UInt64?, volumeRoot: URL) -> USBPortHealthSample? {
        if let entryID, let sample = probe.samplePort(entryID: entryID) {
            return sample
        }
        return probe.sample(volumeRoot: volumeRoot)
    }

    private func freeBytes(at directory: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfFileSystem(forPath: directory.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    private func volumeUUIDString(of volumeRoot: URL) -> String? {
        try? volumeRoot.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    /// Cleanup with the same bound as the benchmark's temp removal: on a
    /// dead mount even unlink can park, and an aborted run must report
    /// instead of hanging. Whatever survives is swept by prefix on the
    /// next launch.
    private func boundedCleanup(_ workload: (any StabilityWorkload)?) -> Error? {
        guard let workload else { return nil }
        let monitor = RunLivenessMonitor<Void>(startedAt: uptime())
        DispatchQueue(label: "CameraToolkit.StabilityTest.cleanup", qos: .userInitiated).async {
            monitor.finish(Result(catching: { workload.cleanup() }))
        }
        guard monitor.waitFinished(timeout: stallTimeout), let outcome = monitor.result() else {
            return ToolkitError.commandFailed(
                "The drive stopped responding while its temporary test file was being removed. Any leftover will be removed on the next launch."
            )
        }
        if case let .failure(error) = outcome {
            return error
        }
        return nil
    }
}

/// A rolling ~3 s view of bytes moved. Per-interval deltas alias bursty
/// completions into fake peaks and dips (an 8 MB write landing in one tick
/// looks like 8 GB/s), so min/typical/max quote windowed rates. The sample
/// that tips the window past the span stays in, so a window always covers
/// at least `span` seconds before it is quoted.
private struct ThroughputWindow {
    let span: TimeInterval
    private var entries: [(bytes: Int64, seconds: TimeInterval)] = []
    private(set) var totalBytes: Int64 = 0
    private(set) var totalSeconds: TimeInterval = 0

    init(span: TimeInterval) {
        self.span = span
    }

    mutating func append(bytes: Int64, seconds: TimeInterval) {
        entries.append((bytes: bytes, seconds: seconds))
        totalBytes += bytes
        totalSeconds += seconds
        while entries.count > 1, totalSeconds - entries[0].seconds >= span {
            totalBytes -= entries[0].bytes
            totalSeconds -= entries[0].seconds
            entries.removeFirst()
        }
    }

    var rate: Double {
        totalSeconds > 0 ? Double(totalBytes) / totalSeconds : 0
    }

    /// Only a full-span window is a sustained figure worth recording.
    var isFull: Bool { totalSeconds >= span }
}

// MARK: - Run state shared between worker and caller

/// Locked accumulation the supervised worker writes and `run` reads back —
/// so a watchdog abort still returns the partial counters and phases the
/// run managed before it stopped.
final class RunStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state = StabilityRunSummary()
    private var baselineCounters: [String: Int64] = [:]
    private var sawUSBCounters = false
    private var detectedPort: String?
    private var cleanupIssue: String?
    private var endedAt: TimeInterval = 0

    var workload: (any StabilityWorkload)?
    var volumeUUID: String?
    var linkBitsPerSecond: Int64?
    var device: USBDeviceIdentity?
    var startedAt: TimeInterval = 0

    var summary: StabilityRunSummary {
        lock.withLock { state }
    }

    /// Locked read of the negotiated link rate for the worker's
    /// per-window ceiling checks — `noteSample` can refresh it mid-run.
    var currentLinkBitsPerSecond: Int64? {
        lock.withLock { linkBitsPerSecond }
    }

    var counterDelta: [String: Int64] {
        lock.withLock { state.counterDelta }
    }

    var hasFailure: Bool {
        lock.withLock { state.mountLost || state.failureMessage != nil }
    }

    var elapsed: TimeInterval {
        lock.withLock { max(endedAt - startedAt, 0) }
    }

    func noteBaseline(_ sample: USBPortHealthSample?) {
        lock.lock()
        defer { lock.unlock() }
        baselineCounters = sample?.counters ?? [:]
        sawUSBCounters = !(sample?.counters.isEmpty ?? true)
        device = sample?.device ?? device
        linkBitsPerSecond = sample?.device?.linkBitsPerSecond ?? linkBitsPerSecond
        detectedPort = USBPortHealthParser.portLabel(forLocation: sample?.deviceLocation)
    }

    func noteSample(_ sample: USBPortHealthSample?) {
        lock.lock()
        if let sample {
            sawUSBCounters = sawUSBCounters || !sample.counters.isEmpty
            device = sample.device ?? device
            linkBitsPerSecond = sample.device?.linkBitsPerSecond ?? linkBitsPerSecond
            if detectedPort == nil {
                detectedPort = USBPortHealthParser.portLabel(forLocation: sample.deviceLocation)
            }
            state.counterDelta = USBPortHealthParser.delta(
                from: baselineCounters, to: sample.counters
            )
        }
        lock.unlock()
    }

    func noteStall(_ stall: StabilityStall) {
        guard stall.seconds > 0 else { return }
        lock.lock()
        state.stalls.append(stall)
        lock.unlock()
    }

    func noteFailure(_ message: String) {
        lock.lock()
        if state.failureMessage == nil {
            state.failureMessage = message
        }
        lock.unlock()
    }

    func noteMountLost() {
        lock.lock()
        state.mountLost = true
        if state.failureMessage == nil {
            state.failureMessage = "the volume unmounted mid-run"
        }
        lock.unlock()
    }

    func notePhase(_ metrics: StabilityPhaseMetrics) {
        lock.lock()
        state.phases.append(metrics)
        lock.unlock()
    }

    func noteCleanupIssue(_ error: Error) {
        lock.lock()
        cleanupIssue = error.localizedDescription
        lock.unlock()
    }

    func finished(at uptime: TimeInterval) {
        lock.lock()
        endedAt = max(startedAt, uptime)
        state.finishedAllPhases = !state.phases.isEmpty
            && state.phases.allSatisfy(\.completed)
            && state.failureMessage == nil
            && !state.mountLost
        lock.unlock()
    }

    func makeUpdate(
        phase: StabilityPhaseKind?,
        phaseIndex: Int,
        phaseCount: Int,
        phaseRemaining: TimeInterval,
        runRemaining: TimeInterval,
        bytesPerSecond: Double,
        mounted: Bool
    ) -> StabilityTestUpdate {
        lock.lock()
        defer { lock.unlock() }
        return StabilityTestUpdate(
            phase: phase,
            phaseIndex: phaseIndex,
            phaseCount: phaseCount,
            phaseRemaining: phaseRemaining,
            runRemaining: runRemaining,
            bytesPerSecond: bytesPerSecond,
            mounted: mounted,
            usbCountersAvailable: sawUSBCounters,
            counterDelta: state.counterDelta,
            linkBitsPerSecond: linkBitsPerSecond,
            detectedPortLabel: detectedPort,
            device: device
        )
    }
}
