import CameraToolkitCore
import Darwin
import Foundation
import IOKit
import Observation

/// Cheap, synchronous hardware reads for the Jobs window — the same public
/// counters Activity Monitor uses, sampled about once a second while the
/// pane is visible. Every field can be nil: when macOS does not expose a
/// counter the UI says so instead of drawing a fake number.
enum SystemLoadProbe {
    /// Cumulative scheduler ticks since boot, split by state.
    struct CPUTicks: Equatable, Sendable {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64

        var busy: UInt64 { user + system + nice }
        var total: UInt64 { busy + idle }
    }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    /// Fraction of scheduler ticks that were busy between two samples —
    /// system-wide, all cores, matching Activity Monitor's CPU graph.
    static func cpuFraction(between earlier: CPUTicks, and later: CPUTicks) -> Double? {
        let busy = later.busy &- earlier.busy
        let total = later.total &- earlier.total
        guard later.total > earlier.total, total > 0 else { return nil }
        return min(max(Double(busy) / Double(total), 0), 1)
    }

    /// GPU "Device Utilization %" from the IOGPU registry entry — the
    /// counter Activity Monitor's GPU History reads. Nil on machines whose
    /// driver exposes no statistics, so the UI can say "not reported"
    /// rather than inventing a load.
    static func gpuFraction() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOGPU"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            var properties: Unmanaged<CFMutableDictionary>?
            let result = IORegistryEntryCreateCFProperties(
                entry, &properties, kCFAllocatorDefault, 0
            )
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS,
                  let stats = (properties?.takeRetainedValue() as? [String: Any])?["PerformanceStatistics"] as? [String: Any],
                  let utilization = stats["Device Utilization %"] as? NSNumber else {
                continue
            }
            let fraction = min(max(utilization.doubleValue / 100, 0), 1)
            best = max(best ?? 0, fraction)
        }
        return best
    }
}

/// Everything the Jobs window's throughput card shows for one job.
struct JobThroughputReadout: Equatable {
    var unit: ThroughputUnit
    /// Smoothed current rate (~5 s EWMA between counter changes), in MB/s
    /// or files/s per `unit`. Held — never blanked — while the counter
    /// does not move; nil only before the job has moved anything.
    var current: Double?
    /// The job's average so far, in the same unit.
    var average: Double?
    /// Seconds the current value has been held without new progress, once
    /// that is long enough to say so (the view fades the number).
    var heldFor: TimeInterval?
    var filesPerSecond: Double?
    /// Video frames per second, for face scans that decode clips.
    var framesPerSecond: Double?
    var points: [ThroughputPoint] = []
    /// Series in legend order — "Copy (write)", "Verify (re-read)".
    var series: [String] = []
    var yUpper: Double = 1
    var xDomain: ClosedRange<Double> = 0...JobThroughputTrack.chartWindow
    var ceiling: JobLinkCeiling?

    var isHeld: Bool { heldFor != nil }
}

/// One job's rolling throughput state. Keyed by job in the monitor, so two
/// expanded rows never reset each other's history.
struct JobThroughputTrack {
    /// The chart shows the last three minutes.
    static let chartWindow: TimeInterval = 180
    /// Chart points are trailing-window rates over this span — smooth,
    /// robust to chunky counters, and honest about real stalls.
    static let trailingWindow: TimeInterval = 5
    /// A held value fades after this long without progress.
    static let staleAfter: TimeInterval = 2.5

    private struct Sample {
        var time: TimeInterval
        /// Cumulative units per series.
        var counts: [String: Double]
        /// Cumulative seconds per phase series; absent for wall-clock series.
        var seconds: [String: Double]
    }

    /// One chart series' cumulative state at a tick.
    struct SeriesCount: Equatable {
        var name: String
        var count: Double
        /// Time the phase has run, for per-phase series: its rate is units
        /// per second *while running*. Nil for the overall series, whose
        /// rate is per wall-clock second.
        var activeSeconds: Double?
    }

    let unit: ThroughputUnit
    private let firstSeen: TimeInterval
    private let ageAtFirstSeen: TimeInterval
    private(set) var lastTick: TimeInterval
    private(set) var primary = HeldRate()
    private(set) var files = HeldRate()
    private(set) var frames = HeldRate()
    private var hasFrames = false
    private var lastPrimaryCount: Double
    /// Baseline at first sight plus every positive delta since — survives
    /// a counter that restarts between passes.
    private var movedTotal: Double
    private var samples: [Sample] = []
    private(set) var points: [ThroughputPoint] = []
    private(set) var series: [String] = []
    private(set) var scale = StableScale()

    init(unit: ThroughputUnit, job: JobSnapshot, now: TimeInterval, wallNow: Date) {
        self.unit = unit
        firstSeen = now
        lastTick = now
        ageAtFirstSeen = max(wallNow.timeIntervalSince(job.createdAt), 0)
        let count = Self.primaryCount(job, unit: unit)
        lastPrimaryCount = count
        movedTotal = count
    }

    func elapsed(at now: TimeInterval) -> TimeInterval {
        now - firstSeen + ageAtFirstSeen
    }

    static func primaryCount(_ job: JobSnapshot, unit: ThroughputUnit) -> Double {
        switch unit {
        case .megabytesPerSecond: Double(max(job.processedBytes, 0))
        case .filesPerSecond: Double(max(job.processedFiles, 0))
        }
    }

    /// Chart series for this job: the overall rate, plus — for a job that
    /// times its phases (Sync to NAS) — each byte-moving phase's speed while
    /// it runs, so copy and verify can each be read against the link
    /// ceiling however short a file's copy → flush → verify cycle is.
    static func seriesCounts(_ job: JobSnapshot, unit: ThroughputUnit) -> [SeriesCount] {
        let overall = SeriesCount(
            name: unit == .megabytesPerSecond ? "Throughput" : "Files",
            count: primaryCount(job, unit: unit)
        )
        guard unit == .megabytesPerSecond, let phases = job.telemetry?.phases, !phases.isEmpty else {
            return [overall]
        }
        // Only phases that move bytes are lines; the rest (flush, rename)
        // show in the time breakdown.
        let moving = phases.filter { $0.bytes > 0 }.map {
            SeriesCount(name: seriesName($0.label), count: Double($0.bytes), activeSeconds: $0.seconds)
        }
        return [SeriesCount(name: "Overall", count: overall.count)] + moving
    }

    static func seriesName(_ phase: String) -> String {
        switch phase {
        case "Copy": "Copy (write)"
        case "Verify": "Verify (re-read)"
        case "Hash": "Hash (drive read)"
        default: phase
        }
    }

    mutating func record(_ job: JobSnapshot, at now: TimeInterval, ceiling: JobLinkCeiling?) {
        lastTick = now
        let count = Self.primaryCount(job, unit: unit)
        if count >= lastPrimaryCount {
            movedTotal += count - lastPrimaryCount
        }
        lastPrimaryCount = count
        primary.observe(count, at: now)
        files.observe(Double(job.processedFiles), at: now)
        if let frameCount = job.telemetry?.counter("Video frames") {
            hasFrames = true
            frames.observe(Double(frameCount), at: now)
        }

        let counts = Self.seriesCounts(job, unit: unit)
        for entry in counts where !series.contains(entry.name) {
            series.append(entry.name)
        }
        samples.append(Sample(
            time: now,
            counts: Dictionary(counts.map { ($0.name, $0.count) }, uniquingKeysWith: { a, _ in a }),
            seconds: Dictionary(counts.compactMap { entry in entry.activeSeconds.map { (entry.name, $0) } }, uniquingKeysWith: { a, _ in a })
        ))
        let horizon = now - Self.trailingWindow - 2
        if let keep = samples.lastIndex(where: { $0.time <= horizon }), keep > 0 {
            samples.removeFirst(keep)
        }

        // Trailing-window rate per series, from the newest sample at least
        // `trailingWindow` old (or the oldest there is). A phase series is
        // plotted only when the phase actually ran in the window.
        let reference = samples.last { $0.time <= now - Self.trailingWindow } ?? samples.first
        if let reference, now - reference.time >= 1 {
            let divisor = unit == .megabytesPerSecond ? 1_000_000.0 : 1
            let at = elapsed(at: now)
            for entry in counts {
                let moved = max(entry.count - (reference.counts[entry.name] ?? 0), 0)
                let span: Double
                if let active = entry.activeSeconds {
                    span = active - (reference.seconds[entry.name] ?? 0)
                    guard span >= 0.2, moved > 0 else { continue }
                } else {
                    span = now - reference.time
                }
                points.append(ThroughputPoint(elapsed: at, series: entry.name, value: moved / span / divisor))
            }
        }
        let start = xDomain(at: now).lowerBound
        points.removeAll { $0.elapsed < start - 1 }

        let visibleMax = points.map(\.value).max() ?? 0
        scale.update(visibleMax: visibleMax, floor: (ceiling?.megabytesPerSecond ?? 0) * 1.1)
    }

    func xDomain(at now: TimeInterval) -> ClosedRange<Double> {
        let end = max(elapsed(at: now), 60)
        return max(end - Self.chartWindow, 0)...end
    }

    func readout(for job: JobSnapshot, at now: TimeInterval, ceiling: JobLinkCeiling?) -> JobThroughputReadout {
        let live = job.state == .running || job.state == .queued
        let at = live ? now : lastTick
        let divisor = unit == .megabytesPerSecond ? 1_000_000.0 : 1
        let seconds = elapsed(at: at)
        let held = primary.secondsSinceChange(at: at).flatMap { $0 >= Self.staleAfter ? $0 : nil }
        return JobThroughputReadout(
            unit: unit,
            current: live ? primary.value.map { $0 / divisor } : nil,
            average: seconds >= 1 && movedTotal > 0 ? movedTotal / seconds / divisor : nil,
            heldFor: live && primary.value != nil ? held : nil,
            filesPerSecond: unit == .filesPerSecond ? nil : (live ? files.value : nil),
            framesPerSecond: hasFrames && live ? frames.value : nil,
            points: points,
            series: series,
            yUpper: scale.upper,
            xDomain: xDomain(at: at),
            ceiling: unit == .megabytesPerSecond ? ceiling : nil
        )
    }
}

/// Rolling samples for the Jobs window's activity pane: the job's own
/// throughput (from its byte and file counters, never a synthetic gauge),
/// system CPU and GPU load, thermal state. Owned by the window view and
/// ticked at ~1 Hz by a TimelineView — sampling never runs inside the
/// job's worker threads. Throughput state is kept per job, so several
/// expanded rows tick the same monitor without wiping each other.
@MainActor
@Observable
final class JobActivityMonitor {
    struct HardwareSample: Equatable, Sendable {
        var cpuFraction: Double?
        var gpuFraction: Double?
        var thermalState: ProcessInfo.ThermalState = .nominal
        var lowPowerMode = false
    }

    /// ~4 minutes of 1 Hz hardware samples.
    static let historyLimit = 240
    /// Finished jobs' charts are kept for the most recent few.
    static let trackLimit = 6

    private(set) var hardware = HardwareSample(
        thermalState: ProcessInfo.processInfo.thermalState,
        lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
    )
    private(set) var cpuHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    private(set) var tracks: [UUID: JobThroughputTrack] = [:]
    private(set) var ceilings: [UUID: JobLinkCeiling] = [:]

    private let ceilingResolver: (@Sendable (String) async -> JobLinkCeiling?)?
    private var ceilingRequested: Set<UUID> = []
    private var previousCPUTicks: SystemLoadProbe.CPUTicks?
    private var lastHardwareSample: TimeInterval?

    /// `ceilingResolver` detects the link behind a job's destination; nil
    /// turns detection off (tests, snapshots).
    init(ceilingResolver: (@Sendable (String) async -> JobLinkCeiling?)? = { await JobLinkCeiling.resolve(path: $0) }) {
        self.ceilingResolver = ceilingResolver
    }

    /// One sample. Called on every TimelineView tick of every expanded
    /// row — hardware is read at most about once a second however many
    /// rows tick, and each job's counters feed only that job's track.
    func tick(
        job: JobSnapshot?,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        wallNow: Date = Date()
    ) {
        sampleHardware(now: now)
        guard let job, job.state == .running || job.state == .queued else { return }

        let unit: ThroughputUnit? = job.totalBytes > 0 || job.processedBytes > 0
            ? .megabytesPerSecond
            : (job.totalFiles > 0 || job.processedFiles > 0 ? .filesPerSecond : nil)
        guard let unit else { return }
        if tracks[job.id]?.unit != unit {
            tracks[job.id] = JobThroughputTrack(unit: unit, job: job, now: now, wallNow: wallNow)
            pruneTracks()
        }
        if let lastTick = tracks[job.id]?.lastTick, now - lastTick < 0.5, tracks[job.id]?.points.isEmpty == false {
            return
        }
        tracks[job.id]?.record(job, at: now, ceiling: ceilings[job.id])
        requestCeiling(for: job, unit: unit)
    }

    /// The throughput card's numbers and chart for `job`; a job the monitor
    /// never saw running still gets its average from its own counters.
    func readout(for job: JobSnapshot, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> JobThroughputReadout {
        if let track = tracks[job.id] {
            return track.readout(for: job, at: now, ceiling: ceilings[job.id])
        }
        let bytes = job.totalBytes > 0 || job.processedBytes > 0
        let end = job.finishedAt ?? Date()
        let seconds = end.timeIntervalSince(job.createdAt)
        let moved = bytes ? Double(job.processedBytes) / 1_000_000 : Double(job.processedFiles)
        return JobThroughputReadout(
            unit: bytes ? .megabytesPerSecond : .filesPerSecond,
            average: seconds >= 1 && moved > 0 ? moved / seconds : nil,
            ceiling: ceilings[job.id]
        )
    }

    /// Test and snapshot seam: a known ceiling without probing the system.
    func setCeiling(_ ceiling: JobLinkCeiling?, for id: UUID) {
        ceilingRequested.insert(id)
        ceilings[id] = ceiling
    }

    /// What the header's "left" readout says.
    enum RemainingEstimate: Equatable {
        /// Too early (or too little measured) to extrapolate.
        case estimating
        case seconds(TimeInterval)
    }

    /// Time left for a running job. A job that measures its own work (the
    /// face scan's photos + planned video frames, Sync's bytes at a
    /// smoothed recent rate) is trusted over the monitor's byte rate.
    /// Other jobs fall back to the byte-rate estimate.
    func remainingEstimate(for job: JobSnapshot) -> RemainingEstimate? {
        guard job.state == .running else { return nil }
        if let work = job.telemetry?.work {
            return work.secondsRemaining.map { .seconds($0) } ?? .estimating
        }
        return estimatedRemaining(for: job).map { .seconds($0) }
    }

    /// Byte-rate ETA when the job reports byte counters; nil when there is
    /// no honest way to estimate.
    func estimatedRemaining(for job: JobSnapshot) -> TimeInterval? {
        guard job.state == .running, job.totalBytes > 0,
              let track = tracks[job.id], track.unit == .megabytesPerSecond,
              let rate = track.primary.value, rate > 1 else {
            return nil
        }
        let remaining = max(job.totalBytes - job.processedBytes, 0)
        return remaining > 0 ? Double(remaining) / rate : 0
    }

    private func sampleHardware(now: TimeInterval) {
        if let lastHardwareSample, now - lastHardwareSample < 0.9, now >= lastHardwareSample { return }
        lastHardwareSample = now
        let ticks = SystemLoadProbe.cpuTicks()
        let cpu = ticks.flatMap { current -> Double? in
            previousCPUTicks.flatMap { SystemLoadProbe.cpuFraction(between: $0, and: current) }
        }
        previousCPUTicks = ticks
        let gpu = SystemLoadProbe.gpuFraction()
        hardware = HardwareSample(
            cpuFraction: cpu ?? hardware.cpuFraction,
            gpuFraction: gpu,
            thermalState: ProcessInfo.processInfo.thermalState,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        append(&cpuHistory, cpu)
        append(&gpuHistory, gpu)
    }

    private func requestCeiling(for job: JobSnapshot, unit: ThroughputUnit) {
        guard unit == .megabytesPerSecond, let ceilingResolver, !ceilingRequested.contains(job.id),
              let path = job.destinationPath ?? job.sourcePath, !path.isEmpty else { return }
        ceilingRequested.insert(job.id)
        let id = job.id
        Task { [weak self] in
            let ceiling = await ceilingResolver(path)
            self?.ceilings[id] = ceiling
        }
    }

    private func pruneTracks() {
        guard tracks.count > Self.trackLimit else { return }
        let oldest = tracks.sorted { $0.value.lastTick < $1.value.lastTick }
            .prefix(tracks.count - Self.trackLimit)
        for (id, _) in oldest {
            tracks[id] = nil
        }
    }

    private func append(_ history: inout [Double], _ value: Double?) {
        guard let value else { return }
        history.append(value)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }
}
