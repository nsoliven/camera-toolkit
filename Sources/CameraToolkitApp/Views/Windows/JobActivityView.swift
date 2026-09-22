import CameraToolkitCore
import SwiftUI

/// The Jobs window's activity pane — the "what is it actually doing" card
/// under an expanded job row: the files in flight and their pipeline step,
/// live counters, a media read-rate graph, machine pressure, and the real
/// model packages in use. Everything shown comes from the job's own
/// progress counters or from hardware probes; a counter the system cannot
/// report is labeled "n/a", never faked.
struct JobActivityDetail: View {
    let job: JobSnapshot
    let monitor: JobActivityMonitor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
                .onChange(of: context.date, initial: true) {
                    monitor.tick(job: job)
                }
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            headline(now: now)
            progressAndCounts
            throughputAndHardware
            debugLines
        }
        .padding(.leading, 48)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - What is running right now

    /// The files the job holds this instant — basenames, not library paths
    /// — each tagged with its pipeline step. Falls back to the job's last
    /// reported path for jobs without per-worker telemetry.
    private var headlineItems: [JobActiveItem] {
        if let items = job.telemetry?.activeItems, !items.isEmpty {
            return items
        }
        if let path = job.currentPath, !path.isEmpty {
            return [JobActiveItem(
                name: (path as NSString).lastPathComponent,
                path: path,
                step: headlineStep
            )]
        }
        return []
    }

    private var headlineStep: String {
        job.telemetry?.step ?? phaseStep
    }

    /// For jobs without telemetry the coarse phase is the best step label
    /// we honestly have.
    private var phaseStep: String {
        let phase = job.note.lowercased()
        let step: String
        switch true {
        case phase.contains("verif"), phase.contains("check"): step = "Verify"
        case phase.contains("copy"): step = "Copy"
        case phase.contains("hash"), phase.contains("read"): step = "Read"
        case phase.contains("detect"): step = "Detect"
        case phase.contains("match"): step = "Match"
        case phase.contains("group"): step = "Group"
        case phase.contains("remov"): step = "Remove"
        case phase.contains("upload"), phase.contains("send"): step = "Upload"
        default: step = "Work"
        }
        return step
    }

    @ViewBuilder
    private func headline(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let first = headlineItems.first {
                stepChip(first.step)
                Text(first.name)
                    .font(.callout.weight(.semibold).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(first.path)
                if headlineItems.count > 1 {
                    Text("+\(headlineItems.count - 1) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(job.note.isEmpty ? job.action.displayName : job.note)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(timingText(now: now))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }

        // A parallel job's other in-flight files — the per-worker view.
        if headlineItems.count > 1 {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190, maximum: 300), spacing: 8)],
                alignment: .leading,
                spacing: 4
            ) {
                ForEach(headlineItems.dropFirst().prefix(11), id: \.path) { item in
                    HStack(spacing: 6) {
                        Text(item.step)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(stepColor(item.step))
                            .frame(width: 44, alignment: .leading)
                        Text(item.name)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.path)
                    }
                }
                if headlineItems.count > 12 {
                    Text("+\(headlineItems.count - 12) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func timingText(now: Date) -> String {
        let end = job.finishedAt ?? now
        let elapsed = max(end.timeIntervalSince(job.createdAt), 0)
        var text = Self.durationText(elapsed)
        if job.state == .running, let eta = monitor.estimatedRemaining(for: job) {
            text += " · ~\(Self.durationText(eta)) left"
        }
        return text
    }

    // MARK: - Progress and counters

    private var progressAndCounts: some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: min(max(job.progress, 0), 1))
                .tint(job.state.tint)
            HStack(spacing: 6) {
                Text(countsText)
                Spacer(minLength: 8)
                Text(job.progress.formatted(.percent.precision(.fractionLength(0))))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
        }
    }

    /// "3,412 of 8,200 files · 4,788 to go · 61 faces · 2 failed · 2.1 GB read"
    /// — real counters only; whatever a job does not report does not appear.
    private var countsText: String {
        var parts: [String] = []
        if job.totalFiles > 0 {
            parts.append("\(job.processedFiles.formatted()) of \(job.totalFiles.formatted()) files")
            let remaining = max(job.totalFiles - job.processedFiles, 0)
            if job.state == .running, remaining > 0 {
                parts.append("\(remaining.formatted()) to go")
            }
        } else if job.processedFiles > 0 {
            parts.append("\(job.processedFiles.formatted()) files")
        }
        if job.totalBytes > 0 {
            parts.append("\(job.processedBytes.formattedBytes) of \(job.totalBytes.formattedBytes) read")
        }
        if let counters = job.telemetry?.counters {
            parts.append(contentsOf: counters.map { "\($0.value.formatted()) \($0.label.lowercased())" })
        }
        return parts.isEmpty ? "Waiting for the job to report" : parts.joined(separator: " · ")
    }

    // MARK: - Throughput and machine pressure

    private var throughputAndHardware: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Sparkline(samples: monitor.readRateHistory)
                    .frame(height: 44)
                Text(readRateCaption)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                metricCell(
                    "CPU",
                    fraction: monitor.hardware.cpuFraction,
                    history: monitor.cpuHistory,
                    help: "System-wide CPU load across all cores"
                )
                metricCell(
                    "GPU",
                    fraction: monitor.hardware.gpuFraction,
                    history: monitor.gpuHistory,
                    help: monitor.hardware.gpuFraction == nil
                        ? "This Mac's GPU driver does not report utilization — shown as n/a rather than guessed"
                        : "GPU device utilization reported by the driver"
                )
                metricCell(
                    "ANE",
                    fraction: nil,
                    history: [],
                    help: "Neural Engine activity is only measurable via powermetrics, which needs sudo — not sampled"
                )
                thermalCell
            }
        }
    }

    private var readRateCaption: String {
        let current = monitor.readRateHistory.last ?? job.bytesPerSecond
        if current > 0 {
            var text = "Read \(Int64(current).formattedBytes)/s"
            if monitor.peakReadRate > 0 {
                text += " · peak \(Int64(monitor.peakReadRate).formattedBytes)/s"
            }
            return text
        }
        if job.state == .running {
            return job.totalBytes > 0 ? "Reading…" : "This job reports no byte counters — graph shows media bytes only"
        }
        return "No read rate recorded"
    }

    private func metricCell(
        _ label: String,
        fraction: Double?,
        history: [Double],
        help: String
    ) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Sparkline(samples: history, tint: .secondary)
                .frame(width: 52, height: 14)
            Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a")
                .font(.caption.monospacedDigit())
                .foregroundStyle(fraction == nil ? .tertiary : .primary)
        }
        .frame(width: 56)
        .help(help)
    }

    private var thermalCell: some View {
        VStack(spacing: 3) {
            Text("THERMAL")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Sparkline(samples: [])
                .hidden()
                .frame(width: 52, height: 14)
            Text(thermalLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(thermalColor)
        }
        .frame(width: 56)
        .help("System thermal state" + (monitor.hardware.lowPowerMode ? " · Low Power Mode is on" : ""))
    }

    private var thermalLabel: String {
        if monitor.hardware.lowPowerMode { return "Low Power" }
        switch monitor.hardware.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private var thermalColor: Color {
        switch monitor.hardware.thermalState {
        case .nominal: return .secondary
        case .fair: return .orange
        case .serious, .critical: return .red
        @unknown default: return .secondary
        }
    }

    // MARK: - Models and configuration (debug pane)

    /// The debug lines the owner asked for: real package names — never the
    /// product euphemisms — plus how the pass is configured.
    @ViewBuilder
    private var debugLines: some View {
        if let telemetry = job.telemetry, !telemetry.models.isEmpty || !telemetry.facts.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if !telemetry.models.isEmpty {
                    debugLine("MODELS", telemetry.models.joined(separator: " · "))
                }
                if !telemetry.facts.isEmpty {
                    debugLine("SCAN", telemetry.facts.joined(separator: " · "))
                }
            }
        }
    }

    private func debugLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Pieces

    private func stepChip(_ step: String) -> some View {
        Text(step)
            .font(.caption2.weight(.bold))
            .foregroundStyle(stepColor(step))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(stepColor(step).opacity(0.12), in: Capsule())
    }

    private func stepColor(_ step: String) -> Color {
        switch step.lowercased() {
        case "decode", "read": .teal
        case "detect": .blue
        case "align": .purple
        case "embed": .indigo
        case "match": .orange
        case "group": .mint
        case "write": .pink
        case "copy": .blue
        case "verify": .green
        case "remove": .red
        case "upload": .cyan
        default: .secondary
        }
    }

    static func durationText(_ interval: TimeInterval) -> String {
        let seconds = Int(max(interval, 0).rounded())
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A small live line graph — samples oldest → newest, autoscaled to the
/// window peak with a soft fill. Empty data draws an empty track.
struct Sparkline: View {
    var samples: [Double]
    var tint: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard let peak = samples.max(), peak > 0, samples.count > 1 else { return }
            let stepX = size.width / CGFloat(samples.count - 1)
            var line = Path()
            for (index, value) in samples.enumerated() {
                let point = CGPoint(
                    x: CGFloat(index) * stepX,
                    y: size.height - CGFloat(min(max(value, 0) / peak, 1)) * (size.height - 1)
                )
                if index == 0 {
                    line.move(to: point)
                } else {
                    line.addLine(to: point)
                }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(tint.opacity(0.15)))
            context.stroke(line, with: .color(tint), lineWidth: 1.5)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

extension JobState {
    /// Row/detail accent per state — shared by the Jobs list and the
    /// activity pane.
    var tint: Color {
        switch self {
        case .running, .queued: .blue
        case .done: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}
