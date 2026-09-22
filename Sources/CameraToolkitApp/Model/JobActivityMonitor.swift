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

/// Rolling samples for the Jobs window's activity pane: media read rate
/// (bytes/second deltas of the job's own byte counter, not a synthetic
/// gauge), system CPU and GPU load, thermal state. Owned by the window
/// view and ticked at ~1 Hz by a TimelineView — sampling never runs inside
/// the job's worker threads.
@MainActor
@Observable
final class JobActivityMonitor {
    struct HardwareSample: Equatable, Sendable {
        var cpuFraction: Double?
        var gpuFraction: Double?
        var thermalState: ProcessInfo.ThermalState = .nominal
        var lowPowerMode = false
    }

    /// ~4 minutes of 1 Hz samples.
    static let historyLimit = 240

    private(set) var hardware = HardwareSample(
        thermalState: ProcessInfo.processInfo.thermalState,
        lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
    )
    /// Instantaneous media bytes/second per tick — real deltas of
    /// `processedBytes`, clamped at zero when a phase resets the counter.
    private(set) var readRateHistory: [Double] = []
    private(set) var cpuHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    /// Exponentially smoothed rate for the ETA readout — less jumpy than
    /// the raw per-second deltas the graph shows.
    private(set) var smoothedReadRate: Double = 0
    private(set) var peakReadRate: Double = 0

    private var previousCPUTicks: SystemLoadProbe.CPUTicks?
    private var observedJobID: UUID?
    private var lastByteCount: Int64 = 0
    private var lastByteUptime: TimeInterval = 0
    private var hasByteBaseline = false

    /// One sample. Called on every TimelineView tick while the pane is on
    /// screen — everything here is a microseconds-cheap syscall.
    func tick(job: JobSnapshot?) {
        let ticks = SystemLoadProbe.cpuTicks()
        let cpu = ticks.flatMap { current -> Double? in
            previousCPUTicks.flatMap { SystemLoadProbe.cpuFraction(between: $0, and: current) }
        }
        previousCPUTicks = ticks
        let gpu = SystemLoadProbe.gpuFraction()
        hardware = HardwareSample(
            cpuFraction: cpu,
            gpuFraction: gpu,
            thermalState: ProcessInfo.processInfo.thermalState,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        append(&cpuHistory, cpu)
        append(&gpuHistory, gpu)

        guard let job else { return }
        if job.id != observedJobID { resetByteHistory(for: job.id) }
        guard job.state == .running || job.state == .queued else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let bytes = job.processedBytes
        if hasByteBaseline, now > lastByteUptime {
            let rate = Double(max(bytes - lastByteCount, 0)) / (now - lastByteUptime)
            smoothedReadRate = smoothedReadRate > 0
                ? smoothedReadRate * 0.55 + rate * 0.45
                : rate
            peakReadRate = max(peakReadRate, rate)
            append(&readRateHistory, rate)
        }
        lastByteCount = bytes
        lastByteUptime = now
        hasByteBaseline = true
    }

    /// Byte-rate ETA when the job reports byte counters; nil when there is
    /// no honest way to estimate.
    func estimatedRemaining(for job: JobSnapshot) -> TimeInterval? {
        guard job.state == .running, job.totalBytes > 0, smoothedReadRate > 1 else {
            return nil
        }
        let remaining = max(job.totalBytes - job.processedBytes, 0)
        return remaining > 0 ? Double(remaining) / smoothedReadRate : 0
    }

    private func resetByteHistory(for id: UUID) {
        observedJobID = id
        readRateHistory = []
        smoothedReadRate = 0
        peakReadRate = 0
        hasByteBaseline = false
    }

    private func append(_ history: inout [Double], _ value: Double?) {
        guard let value else { return }
        history.append(value)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }
}
