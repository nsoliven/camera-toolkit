import CameraToolkitCore
import Darwin
import Foundation

/// A smoothed rate of a cumulative counter (bytes, files, frames) that holds
/// its last value when the counter does not move, instead of dropping to
/// zero on every quiet tick.
///
/// Job counters move in steps — a 4 MB chunk, a finished file — so a 1 Hz
/// sampler sees many ticks with no change even while the job runs at full
/// speed. The rate is therefore measured between *change points*: when the
/// counter moves, the delta is spread over the whole time since it last
/// moved, then folded into an EWMA with a ~5 s time constant. A real stall
/// still shows up — the next change arrives after a long gap and pulls the
/// rate down — and `secondsSinceChange` says how long the value has been
/// held.
struct HeldRate: Equatable, Sendable {
    var timeConstant: TimeInterval = 5

    /// Units per second; nil until the counter has moved once.
    private(set) var value: Double?
    private var lastCount: Double?
    private var lastChange: TimeInterval?

    mutating func observe(_ count: Double, at now: TimeInterval) {
        guard let lastCount, let lastChange else {
            lastCount = count
            lastChange = now
            return
        }
        if count < lastCount {
            // A counter that restarts (a new pass) is a new baseline, not
            // negative progress; the held rate stays.
            self.lastCount = count
            self.lastChange = now
            return
        }
        guard count > lastCount, now > lastChange else { return }
        let span = now - lastChange
        let instantaneous = (count - lastCount) / span
        if let value {
            let alpha = 1 - exp(-span / timeConstant)
            self.value = value + alpha * (instantaneous - value)
        } else {
            value = instantaneous
        }
        self.lastCount = count
        self.lastChange = now
    }

    func secondsSinceChange(at now: TimeInterval) -> TimeInterval? {
        lastChange.map { max(now - $0, 0) }
    }
}

/// A chart y-axis upper bound that grows at once when the data needs more
/// room but only shrinks when the data falls far below it — so one spike
/// does not rescale the chart on every sample.
struct StableScale: Equatable, Sendable {
    private(set) var upper: Double = 0

    /// `visibleMax` is the largest plotted value; `floor` keeps a known
    /// ceiling (the link's) on the chart.
    mutating func update(visibleMax: Double, floor: Double = 0, minimum: Double = 1) {
        let target = Self.nice(max(visibleMax * 1.15, floor, minimum))
        if target > upper || target < upper * 0.4 {
            upper = target
        }
    }

    /// The next "nice" axis bound at or above `value`: 1, 2, 2.5, 5 × 10ⁿ.
    static func nice(_ value: Double) -> Double {
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

/// One plotted point: elapsed job time, series, value (MB/s or items/s).
struct ThroughputPoint: Identifiable, Equatable, Sendable {
    var elapsed: TimeInterval
    var series: String
    var value: Double
    var id: String { "\(series)-\(elapsed)" }
}

/// What the chart's y-axis counts.
enum ThroughputUnit: Equatable, Sendable {
    case megabytesPerSecond
    case filesPerSecond

    var axisLabel: String {
        switch self {
        case .megabytesPerSecond: "MB/s"
        case .filesPerSecond: "files/s"
        }
    }
}

/// The dashed "expected ceiling" on the chart: what the link a job's
/// destination sits behind typically carries, from the same detection the
/// storage speed test uses. Only drawn when the link was actually detected.
struct JobLinkCeiling: Equatable, Sendable {
    /// Short link name — "1 GbE", "Wi-Fi 866 Mb/s", "USB 10 Gb/s".
    var label: String
    var megabytesPerSecond: Double

    /// "1 GbE ≈ 115 MB/s"
    var caption: String {
        "\(label) ≈ \(JobThroughputFormat.rate(megabytesPerSecond)) MB/s"
    }

    /// The ceiling for a detected link, nil for a guessed one. Network
    /// shares use the wire's typical top (the NAS pool figures are only
    /// estimates); local disks use the slower of bus and media.
    static func from(_ context: StorageLinkContext) -> JobLinkCeiling? {
        guard context.detected else { return nil }
        let range: ClosedRange<Double>?
        switch context.medium {
        case .ethernet, .wifi, .networkShare:
            range = context.linkTypicalMBps
        default:
            range = context.typicalRead
        }
        guard let range, range.upperBound > 0 else { return nil }
        return JobLinkCeiling(label: shortLabel(context), megabytesPerSecond: range.upperBound)
    }

    private static func shortLabel(_ context: StorageLinkContext) -> String {
        let bits = context.negotiatedBitsPerSecond
        switch context.medium {
        case .ethernet:
            guard let bits else { return "Ethernet" }
            let megabits = Double(bits) / 1_000_000
            if megabits >= 1_000 {
                let gigabits = megabits / 1_000
                let text = gigabits.rounded() == gigabits
                    ? String(Int(gigabits))
                    : String(format: "%.1f", gigabits)
                return "\(text) GbE"
            }
            return "\(Int(megabits.rounded())) MbE"
        case .wifi:
            return bits.map { "Wi-Fi \(Int((Double($0) / 1_000_000).rounded())) Mb/s" } ?? "Wi-Fi"
        case .usb:
            return bits.map { "USB \(StorageLinkInspector.formattedBitsPerSecond($0))" } ?? "USB"
        case .thunderbolt: return "Thunderbolt"
        case .internalStorage: return "Internal disk"
        case .networkShare: return "Network"
        case .unknown: return "Link"
        }
    }

    /// Detects the link behind `path` — shell probes (route, ifconfig,
    /// diskutil), so it runs detached, once per job.
    static func resolve(path: String) async -> JobLinkCeiling? {
        await Task.detached(priority: .utility) {
            guard let mount = MountedVolumeProbe.statFSInfo(path) else { return nil }
            let isNetwork = mount.fileSystemType == "smbfs" || mount.fileSystemType == "nfs"
                || mount.mountSource.hasPrefix("//")
            if isNetwork {
                return from(StorageLinkInspector.networkContext(mountSource: mount.mountSource))
            }
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey])
            let volumeURL = values?.volume ?? url
            let volume = MountedVolumeInfo(
                url: volumeURL,
                name: values?.volumeName ?? volumeURL.lastPathComponent,
                fileSystemType: mount.fileSystemType,
                mountSource: mount.mountSource,
                isRemovable: false,
                isEjectable: false,
                isReadOnly: false,
                isDiskImage: false,
                totalCapacity: nil
            )
            return from(StorageLinkInspector.localContext(
                volume: volume,
                diskInfo: StorageLinkInspector.diskVolumeInfo(at: volumeURL),
                usbDevices: StorageLinkInspector.usbHostDevices(),
                isCameraSource: false
            ))
        }.value
    }
}

/// Fixed-shape number formatting for the throughput readouts, so values
/// keep their width from one sample to the next.
enum JobThroughputFormat {
    /// Placeholder with the same visual weight as a number.
    static let placeholder = "—"

    /// MB/s (decimal megabytes, as the speed test reports): one decimal
    /// under 100, whole numbers from there, thousands grouped.
    static func rate(_ megabytesPerSecond: Double) -> String {
        let value = max(megabytesPerSecond, 0)
        guard value.isFinite else { return placeholder }
        if value < 100 { return String(format: "%.1f", value) }
        return Int(value.rounded()).formatted()
    }

    /// Items per second: two decimals under 1 (a slow video scan is
    /// 0.25 files/s), one under 100, whole numbers from there.
    static func itemRate(_ perSecond: Double) -> String {
        let value = max(perSecond, 0)
        guard value.isFinite else { return placeholder }
        if value < 1 { return String(format: "%.2f", value) }
        if value < 100 { return String(format: "%.1f", value) }
        return Int(value.rounded()).formatted()
    }

    /// "120.3 / 200.0 MB", or in GB from 1 GB; decimal units, like the
    /// rates.
    static func sizeProgress(done: Int64, total: Int64) -> String {
        let gigabytes = total >= 1_000_000_000
        let divisor = gigabytes ? 1_000_000_000.0 : 1_000_000.0
        let unit = gigabytes ? "GB" : "MB"
        return String(format: "%.1f / %.1f %@", Double(max(done, 0)) / divisor, Double(max(total, 0)) / divisor, unit)
    }

    static func megabytes(_ bytesPerSecond: Double) -> Double {
        bytesPerSecond / 1_000_000
    }
}
