import Foundation

// MARK: - Phases and profiles

/// One phase of the standard test. Durations are fixed so results compare
/// across cables, enclosures, and ports.
public enum StabilityPhaseKind: String, Codable, Sendable, CaseIterable {
    case sustainedWrite
    case sustainedRead
    case mixedBurst
    case idleWatch

    public var title: String {
        switch self {
        case .sustainedWrite: "Sustained write"
        case .sustainedRead: "Sustained read"
        case .mixedBurst: "Mixed burst"
        case .idleWatch: "Idle watch"
        }
    }

    /// Idle watch moves no bytes by design — every other phase does.
    public var movesBytes: Bool { self != .idleWatch }
}

public struct StabilityPhase: Equatable, Codable, Sendable {
    public var kind: StabilityPhaseKind
    public var seconds: TimeInterval

    public init(kind: StabilityPhaseKind, seconds: TimeInterval) {
        self.kind = kind
        self.seconds = seconds
    }
}

/// The fixed test profiles. Quick is a smoke check; Standard is the
/// default grading run every new cable or enclosure should pass before it
/// is trusted with Buffer work; Soak repeats the Standard cycle.
public enum StabilityProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case quick
    case standard
    case soak

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quick: "Quick"
        case .standard: "Standard"
        case .soak: "Soak"
        }
    }

    /// Nominal length for a writable drive — the phases below sum to it.
    public var durationMinutes: Int {
        switch self {
        case .quick: 2
        case .standard: 10
        case .soak: 30
        }
    }

    public var pickerLabel: String {
        "\(title) · \(durationMinutes) min"
    }

    public var detail: String {
        switch self {
        case .quick:
            "One minute of sustained writing, then a sustained read of what was written, then a mixed burst. A smoke check, not proof."
        case .standard:
            "Three minutes of sustained writing, three minutes reading it back uncached, two minutes of parallel mixed reads plus a writer, then two minutes of idle watch to catch a link that drops after load."
        case .soak:
            "The Standard cycle repeated three times — half an hour of pressure for a drive that only fails when hot or worn in."
        }
    }

    /// One pass of the profile. Quick skips the idle watch; Standard is a
    /// single full cycle; Soak runs the Standard cycle three times.
    private var cycles: Int {
        self == .soak ? 3 : 1
    }

    private var cyclePhases: [StabilityPhase] {
        switch self {
        case .quick:
            [
                StabilityPhase(kind: .sustainedWrite, seconds: 60),
                StabilityPhase(kind: .sustainedRead, seconds: 40),
                StabilityPhase(kind: .mixedBurst, seconds: 20)
            ]
        case .standard, .soak:
            [
                StabilityPhase(kind: .sustainedWrite, seconds: 180),
                StabilityPhase(kind: .sustainedRead, seconds: 180),
                StabilityPhase(kind: .mixedBurst, seconds: 120),
                StabilityPhase(kind: .idleWatch, seconds: 120)
            ]
        }
    }

    /// The phase schedule for a target. Read-only drives (camera cards)
    /// get the read and burst phases only — never a write.
    public func phases(canWrite: Bool) -> [StabilityPhase] {
        var schedule: [StabilityPhase] = []
        for _ in 0..<cycles {
            for phase in cyclePhases {
                if canWrite {
                    schedule.append(phase)
                } else if phase.kind == .sustainedRead || phase.kind == .mixedBurst {
                    schedule.append(phase)
                }
            }
        }
        return schedule
    }
}

// MARK: - Run measurements

/// A stretch where the drive answered but no bytes moved — at
/// `StabilityTestService.stallWarningSeconds` it becomes a warning.
public struct StabilityStall: Equatable, Codable, Sendable {
    public var phase: StabilityPhaseKind
    public var seconds: TimeInterval

    public init(phase: StabilityPhaseKind, seconds: TimeInterval) {
        self.phase = phase
        self.seconds = seconds
    }
}

/// Per-phase throughput stats built from the ~1 Hz byte samples.
public struct StabilityPhaseMetrics: Equatable, Codable, Sendable {
    public var kind: StabilityPhaseKind
    /// How long the phase actually ran.
    public var seconds: TimeInterval
    public var bytesMoved: Int64
    /// Per-sample bytes/second observed during the phase.
    public var samplesBytesPerSecond: [Double]
    /// False when the run ended mid-phase.
    public var completed: Bool

    public init(
        kind: StabilityPhaseKind,
        seconds: TimeInterval,
        bytesMoved: Int64,
        samplesBytesPerSecond: [Double],
        completed: Bool
    ) {
        self.kind = kind
        self.seconds = seconds
        self.bytesMoved = bytesMoved
        self.samplesBytesPerSecond = samplesBytesPerSecond
        self.completed = completed
    }

    public var minBytesPerSecond: Double { samplesBytesPerSecond.min() ?? 0 }
    public var maxBytesPerSecond: Double { samplesBytesPerSecond.max() ?? 0 }

    /// Median of the per-second samples — the "typical" figure the UI and
    /// verdict quote, so a single dip does not define the run.
    public var typicalBytesPerSecond: Double {
        Self.median(samplesBytesPerSecond)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// Median of the first vs last third of samples — the large mid-run
    /// slowdown check. Nil when there are too few samples to split.
    func thirdMedians() -> (first: Double, last: Double)? {
        guard samplesBytesPerSecond.count >= 9 else { return nil }
        let third = samplesBytesPerSecond.count / 3
        return (
            Self.median(Array(samplesBytesPerSecond.prefix(third))),
            Self.median(Array(samplesBytesPerSecond.suffix(third)))
        )
    }
}

/// Everything the verdict needs, gathered during a run. Pure input so the
/// grading rules stay unit-testable without hardware.
public struct StabilityRunSummary: Equatable, Sendable {
    /// Counter deltas between run start and the last successful sample.
    public var counterDelta: [String: Int64]
    /// The mount stopped answering or the volume node vanished.
    public var mountLost: Bool
    /// A hard failure text: I/O error, or the watchdog's stalled-drive
    /// abort. Counters alone can't see a drive that hung silently.
    public var failureMessage: String?
    /// Stretches where work returned but no bytes moved for ≥2 s.
    public var stalls: [StabilityStall]
    public var phases: [StabilityPhaseMetrics]
    /// Every scheduled phase ran to its deadline.
    public var finishedAllPhases: Bool

    public init(
        counterDelta: [String: Int64] = [:],
        mountLost: Bool = false,
        failureMessage: String? = nil,
        stalls: [StabilityStall] = [],
        phases: [StabilityPhaseMetrics] = [],
        finishedAllPhases: Bool = false
    ) {
        self.counterDelta = counterDelta
        self.mountLost = mountLost
        self.failureMessage = failureMessage
        self.stalls = stalls
        self.phases = phases
        self.finishedAllPhases = finishedAllPhases
    }

    public var connectDelta: Int64 {
        counterDelta[USBPortHealthSample.CounterKey.connectCount] ?? 0
    }

    public var enumerationFailureDelta: Int64 {
        counterDelta[USBPortHealthSample.CounterKey.enumerationFailureCount] ?? 0
    }

    public var addressFailureDelta: Int64 {
        counterDelta[USBPortHealthSample.CounterKey.addressFailureCount] ?? 0
    }

    public var overCurrentDelta: Int64 {
        counterDelta[USBPortHealthSample.CounterKey.overCurrentCount] ?? 0
    }

    public var linkErrorDelta: Int64 {
        counterDelta[USBPortHealthSample.CounterKey.linkErrorCount] ?? 0
    }

    public var eof2ViolationDelta: Int64 {
        counterDelta.reduce(0) {
            $1.key.hasPrefix(USBPortHealthSample.CounterKey.eof2ViolationPrefix) ? $0 + $1.value : $0
        }
    }

    /// Median across every byte-moving phase's per-second samples.
    public var overallTypicalBytesPerSecond: Double {
        StabilityPhaseMetrics.median(
            phases.filter(\.kind.movesBytes).flatMap(\.samplesBytesPerSecond)
        )
    }
}

// MARK: - Verdict

/// The graded result: pass, warning, or fail, each with plain-words
/// reasons and what to try next.
public struct StabilityVerdict: Equatable, Codable, Sendable {
    public enum Grade: String, Codable, Sendable {
        case pass
        case warning
        case fail
    }

    public var grade: Grade
    public var headline: String
    public var reasons: [String]
    public var advice: String

    public init(grade: Grade, headline: String, reasons: [String], advice: String) {
        self.grade = grade
        self.headline = headline
        self.reasons = reasons
        self.advice = advice
    }

    /// Under half of the detected link's typical range counts as slow.
    private static let lowThroughputFraction = 0.5
    /// A last-third typical under half of the first-third typical counts
    /// as a large mid-run slowdown.
    private static let slowdownFraction = 0.5

    public static func evaluate(
        summary: StabilityRunSummary,
        typicalRangeMBps: ClosedRange<Double>? = nil
    ) -> StabilityVerdict {
        var failures: [String] = []
        var failureAdvice: [String] = []
        var warnings: [String] = []

        if summary.mountLost {
            failures.append("The volume unmounted or disappeared during the test.")
            failureAdvice.append(
                "Reseat or replace the cable first — that is the cheapest fix and the most common cause. If a known-good cable also drops here, suspect the enclosure, then the Mac's port."
            )
        }
        if summary.connectDelta > 0 {
            failures.append(
                "The port logged \(summary.connectDelta) new connection\(summary.connectDelta == 1 ? "" : "s") — the link dropped and renegotiated under load."
            )
            failureAdvice.append(
                "The connection reset \(summary.connectDelta) time\(summary.connectDelta == 1 ? "" : "s") under load. Replace the cable first; if a known-good cable also fails, suspect the enclosure or port."
            )
        }
        if summary.enumerationFailureDelta > 0 {
            failures.append(
                "The enclosure failed to identify itself \(summary.enumerationFailureDelta) time\(summary.enumerationFailureDelta == 1 ? "" : "s") (enumeration failures)."
            )
            failureAdvice.append(
                "Replace the cable first; if a known-good cable also produces enumeration failures, suspect the enclosure's bridge chip or the port."
            )
        }
        if summary.addressFailureDelta > 0 {
            failures.append(
                "The device failed its address assignment \(summary.addressFailureDelta) time\(summary.addressFailureDelta == 1 ? "" : "s") on reconnect."
            )
            failureAdvice.append(
                "Address failures follow bad enumerations — replace the cable first, then suspect the enclosure or port."
            )
        }
        if summary.eof2ViolationDelta > 0 {
            failures.append(
                "The port counted \(summary.eof2ViolationDelta) packet-framing (EOF2) violation\(summary.eof2ViolationDelta == 1 ? "" : "s") — the signal was corrupted on the wire."
            )
            failureAdvice.append(
                "Framing violations point at the wire: replace the cable first; if they persist, suspect the port or the enclosure's PHY."
            )
        }
        if summary.overCurrentDelta > 0 {
            failures.append(
                "The port reported over-current — the enclosure tried to draw more power than the port allows."
            )
            failureAdvice.append(
                "Try a powered hub or dock, or a different cable rated for the enclosure's draw. If over-current repeats, suspect the enclosure."
            )
        }
        if summary.linkErrorDelta > 0 {
            failures.append(
                "The port counted \(summary.linkErrorDelta) new link error\(summary.linkErrorDelta == 1 ? "" : "s") — the signal was marginal under load."
            )
            failureAdvice.append(
                "Link errors mean signal integrity: replace the cable first; if they persist, try another port, then suspect the enclosure."
            )
        }
        if let failure = summary.failureMessage {
            failures.append("I/O failed: \(failure)")
            failureAdvice.append(
                "An I/O error under load means the cable, enclosure, or port could not keep up. Replace the cable first; if a known-good cable also fails, suspect the enclosure or port."
            )
        }

        if !failures.isEmpty {
            return StabilityVerdict(
                grade: .fail,
                headline: "Connection unstable under load",
                reasons: failures,
                advice: failureAdvice.first ?? "Replace the cable first."
            )
        }

        if !summary.finishedAllPhases {
            warnings.append("The run ended before its last phase — the results cover only part of the profile.")
        }

        for stall in summary.stalls {
            warnings.append(
                "No data moved for \(Int(stall.seconds.rounded()))s during \(stall.phase.title.lowercased()) — the enclosure briefly stopped answering."
            )
        }

        if let range = typicalRangeMBps {
            let typical = summary.overallTypicalBytesPerSecond
            let floor = range.lowerBound * lowThroughputFraction
            if typical > 0, typical / 1_000_000 < floor {
                warnings.append(
                    "Typical throughput was about \(Int((typical / 1_000_000).rounded())) MB/s — under half of the \(Int(range.lowerBound.rounded()))–\(Int(range.upperBound.rounded())) MB/s a link like this typically carries."
                )
            }
        }

        for phase in summary.phases where phase.completed && phase.kind.movesBytes {
            guard let thirds = phase.thirdMedians() else { continue }
            guard thirds.first > 0,
                  thirds.last < thirds.first * slowdownFraction else { continue }
            warnings.append(
                "Throughput fell from about \(Int((thirds.first / 1_000_000).rounded())) to \(Int((thirds.last / 1_000_000).rounded())) MB/s across the \(phase.kind.title.lowercased()) phase. A long sustained write can outrun an SSD's fast cache, and a warm enclosure can throttle — that slowdown is normal after tens of GB and is not a fault by itself. Treat it as a clue only if drops or stalls come with it."
            )
        }

        if !warnings.isEmpty {
            return StabilityVerdict(
                grade: .warning,
                headline: "Passed with warnings",
                reasons: warnings,
                advice: "No resets or link errors, so the cable is probably fine — but keep the warnings in mind if transfers ever feel slow or stall. Rerun Standard after the drive cools if you want a clean baseline."
            )
        }

        return StabilityVerdict(
            grade: .pass,
            headline: "Stable under load",
            reasons: ["No drops, resets, link errors, over-current, stalls, or I/O errors across the whole profile."],
            advice: "This cable + enclosure + port held up. Worth re-running Standard after a cable swap or enclosure firmware update."
        )
    }
}

// MARK: - Saved record

/// One completed (or failed) run, stored for comparison in the feature's
/// own history file. Per-phase min/typical/max are baked in — the raw
/// per-second samples are not kept.
public struct StabilityPhaseRecord: Codable, Equatable, Sendable {
    public var kind: StabilityPhaseKind
    public var seconds: TimeInterval
    public var bytesMoved: Int64
    public var minBytesPerSecond: Double
    public var typicalBytesPerSecond: Double
    public var maxBytesPerSecond: Double
    public var completed: Bool

    public init(metrics: StabilityPhaseMetrics) {
        kind = metrics.kind
        seconds = metrics.seconds
        bytesMoved = metrics.bytesMoved
        minBytesPerSecond = metrics.minBytesPerSecond
        typicalBytesPerSecond = metrics.typicalBytesPerSecond
        maxBytesPerSecond = metrics.maxBytesPerSecond
        completed = metrics.completed
    }

    public init(
        kind: StabilityPhaseKind,
        seconds: TimeInterval,
        bytesMoved: Int64,
        minBytesPerSecond: Double,
        typicalBytesPerSecond: Double,
        maxBytesPerSecond: Double,
        completed: Bool
    ) {
        self.kind = kind
        self.seconds = seconds
        self.bytesMoved = bytesMoved
        self.minBytesPerSecond = minBytesPerSecond
        self.typicalBytesPerSecond = typicalBytesPerSecond
        self.maxBytesPerSecond = maxBytesPerSecond
        self.completed = completed
    }
}

public struct StabilityTestRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var finishedAt: Date
    /// `StabilityProfile.rawValue`.
    public var profile: String
    public var cableLabel: String
    public var portLabel: String
    public var grade: StabilityVerdict.Grade
    public var headline: String
    public var reasons: [String]
    public var advice: String
    public var phases: [StabilityPhaseRecord]
    /// Counter name → count added during the run.
    public var counterDeltas: [String: Int64]
    public var linkBitsPerSecond: Int64?
    public var powerSinkAllocation: Int64?
    /// The enclosure's bridge identity — plus the volume UUID so units
    /// sharing a placeholder serial stay distinguishable.
    public var enclosure: USBDeviceIdentity?
    public var volumeUUID: String?
    public var durationSeconds: TimeInterval
    /// False when the run was cut short by a drop or I/O error.
    public var completed: Bool

    public init(
        id: UUID = UUID(),
        finishedAt: Date,
        profile: String,
        cableLabel: String,
        portLabel: String,
        grade: StabilityVerdict.Grade,
        headline: String,
        reasons: [String],
        advice: String,
        phases: [StabilityPhaseRecord],
        counterDeltas: [String: Int64],
        linkBitsPerSecond: Int64? = nil,
        powerSinkAllocation: Int64? = nil,
        enclosure: USBDeviceIdentity? = nil,
        volumeUUID: String? = nil,
        durationSeconds: TimeInterval,
        completed: Bool
    ) {
        self.id = id
        self.finishedAt = finishedAt
        self.profile = profile
        self.cableLabel = cableLabel
        self.portLabel = portLabel
        self.grade = grade
        self.headline = headline
        self.reasons = reasons
        self.advice = advice
        self.phases = phases
        self.counterDeltas = counterDeltas
        self.linkBitsPerSecond = linkBitsPerSecond
        self.powerSinkAllocation = powerSinkAllocation
        self.enclosure = enclosure
        self.volumeUUID = volumeUUID
        self.durationSeconds = durationSeconds
        self.completed = completed
    }

    /// Failures counted in the deltas — the number the history table shows.
    public var failureTotal: Int64 {
        (counterDeltas[USBPortHealthSample.CounterKey.enumerationFailureCount] ?? 0)
            + (counterDeltas[USBPortHealthSample.CounterKey.addressFailureCount] ?? 0)
            + counterDeltas.reduce(0) {
                $1.key.hasPrefix(USBPortHealthSample.CounterKey.eof2ViolationPrefix) ? $0 + $1.value : $0
            }
            + (counterDeltas[USBPortHealthSample.CounterKey.linkErrorCount] ?? 0)
            + (counterDeltas[USBPortHealthSample.CounterKey.overCurrentCount] ?? 0)
    }

    /// Compare key: the volume UUID when known — units sharing a
    /// placeholder serial stay apart — falling back to the enclosure
    /// identity tuple for volumes that never had one.
    public func isSameDrive(asVolumeUUID uuid: String?, enclosure: USBDeviceIdentity?) -> Bool {
        if let uuid, let volumeUUID {
            return uuid == volumeUUID
        }
        guard let enclosure, let mine = self.enclosure else { return false }
        return mine.vendorID == enclosure.vendorID
            && mine.productID == enclosure.productID
            && mine.serialNumber == enclosure.serialNumber
    }
}

// MARK: - Plain-text report

/// The Copy Report summary — plain text, no paths, no machine names.
public enum StabilityReportFormatter {
    public static func text(for record: StabilityTestRecord) -> String {
        var lines: [String] = []
        lines.append("Cable & Enclosure Stability Test")
        lines.append("Date: \(record.finishedAt.formatted(date: .abbreviated, time: .shortened))")
        lines.append("Profile: \(record.profile.capitalized) (\(formattedDuration(record.durationSeconds))\(record.completed ? "" : ", ended early"))")
        if let enclosure = record.enclosure {
            var device = "Enclosure: \(enclosure.displayName)"
            var ids: [String] = []
            if let vendor = enclosure.vendorID, let product = enclosure.productID {
                ids.append(String(format: "vid %04x pid %04x", vendor, product))
            }
            if let bcd = enclosure.deviceVersionBCD {
                ids.append(String(format: "bcd %04x", bcd))
            }
            if let serial = enclosure.serialNumber, !serial.isEmpty {
                ids.append("serial \(serial)")
            }
            if !ids.isEmpty {
                device += " — \(ids.joined(separator: ", "))"
            }
            lines.append(device)
        }
        if !record.cableLabel.isEmpty || !record.portLabel.isEmpty {
            lines.append("Cable: \(record.cableLabel.isEmpty ? "not labelled" : record.cableLabel) · Port: \(record.portLabel.isEmpty ? "not labelled" : record.portLabel)")
        }
        if let bits = record.linkBitsPerSecond {
            lines.append("Link: \(formattedBitsPerSecond(bits)) negotiated\(record.powerSinkAllocation.map { " · power sink \($0)" } ?? "")")
        }
        lines.append("")
        lines.append("Verdict: \(record.grade.rawValue.uppercased()) — \(record.headline)")
        for reason in record.reasons {
            lines.append("  • \(reason)")
        }
        for phase in record.phases {
            let stats = phase.kind.movesBytes
                ? "min \(mbps(phase.minBytesPerSecond)) · typical \(mbps(phase.typicalBytesPerSecond)) · max \(mbps(phase.maxBytesPerSecond)) MB/s"
                : "no I/O by design"
            lines.append("  \(phase.kind.title) — \(formattedDuration(phase.seconds)) — \(stats)\(phase.completed ? "" : " (cut short)")")
        }
        if !record.counterDeltas.isEmpty {
            lines.append("")
            lines.append("Port counters added during the run:")
            for key in record.counterDeltas.keys.sorted() {
                lines.append("  \(counterName(key)) +\(record.counterDeltas[key] ?? 0)")
            }
        }
        lines.append("")
        lines.append("What to do: \(record.advice)")
        return lines.joined(separator: "\n")
    }

    private static func mbps(_ bytesPerSecond: Double) -> Int {
        Int((bytesPerSecond / 1_000_000).rounded())
    }

    private static func formattedBitsPerSecond(_ bits: Int64) -> String {
        if bits < 1_000_000_000 {
            return "\(bits / 1_000_000) Mb/s"
        }
        let gigabits = Double(bits) / 1_000_000_000
        return gigabits.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(gigabits)) Gb/s"
            : String(format: "%.1f Gb/s", gigabits)
    }

    private static func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Friendlier names for the counters the verdict watches.
    static func counterName(_ key: String) -> String {
        switch key {
        case USBPortHealthSample.CounterKey.connectCount: "connects"
        case USBPortHealthSample.CounterKey.enumerationFailureCount: "enumeration failures"
        case USBPortHealthSample.CounterKey.addressFailureCount: "address failures"
        case USBPortHealthSample.CounterKey.overCurrentCount: "over-current"
        case USBPortHealthSample.CounterKey.linkErrorCount: "link errors"
        case USBPortHealthSample.CounterKey.powerStateTime: "power-state time"
        default:
            key.hasPrefix(USBPortHealthSample.CounterKey.eof2ViolationPrefix)
                ? "EOF2 framing violations"
                : key
        }
    }
}
