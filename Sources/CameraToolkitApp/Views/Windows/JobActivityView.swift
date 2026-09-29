import CameraToolkitCore
import Charts
import SwiftUI

/// The Jobs window's activity pane — the "what is it actually doing" card
/// under an expanded job row: the files in flight and their pipeline step,
/// live counters, the job's speed against its link, where the time goes,
/// machine pressure, and the real model packages in use. Everything shown
/// comes from the job's own progress counters or from hardware probes; a
/// counter the system cannot report is left out, never faked.
struct JobActivityDetail: View {
    let job: JobSnapshot
    let monitor: JobActivityMonitor
    /// False renders the monitor's current state without sampling — the
    /// off-screen snapshot harness feeds it synthetic samples instead.
    var sampling = true
    /// Uptime the snapshot harness pins "now" to.
    var fixedUptime: TimeInterval?
    /// The job's recorded samples so far, for the chart's "Whole job"
    /// range; nil hides the range toggle (a job this session did not
    /// record, the snapshot harness).
    var wholeJobSamples: (() -> [JobHistorySample])?
    static let chartRangeDefaultsKey = "jobs.throughputChartRange"
    @AppStorage(JobActivityDetail.chartRangeDefaultsKey) private var chartRange = ThroughputChartRange.recent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
                .onChange(of: context.date, initial: true) {
                    if sampling { monitor.tick(job: job) }
                }
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            headline(now: now)
            progressAndCounts
            throughputCard(now: fixedUptime ?? ProcessInfo.processInfo.systemUptime)
            debugLines
        }
        .padding(.leading, 36)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Rows for a job with a fixed set of parallel transfers (Sync to
    /// NAS), in row order; empty for other jobs.
    private var transferRows: [JobActiveItem] {
        (job.telemetry?.activeItems ?? []).filter { $0.slot != nil }.sorted { ($0.slot ?? 0) < ($1.slot ?? 0) }
    }

    @ViewBuilder
    private func headline(now: Date) -> some View {
        if let configuration = job.telemetry?.configuration, job.action == .syncBuffer || !transferRows.isEmpty {
            transferHeadline(configuration: configuration, now: now)
        } else {
            itemHeadline(now: now)
        }
    }

    /// "4 transfers in parallel · SSH verify", the job's status on its own
    /// line, then one steady row per transfer.
    @ViewBuilder
    private func transferHeadline(configuration: String, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(configuration)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(timingText(now: now))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(job.telemetry?.step ?? (job.note.isEmpty ? job.action.displayName : job.note))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !transferRows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(transferRows, id: \.slot) { item in
                        TransferRow(item: item)
                    }
                }
                .transaction { $0.animation = nil }
            }
        }
    }

    @ViewBuilder
    private func itemHeadline(now: Date) -> some View {
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
                .lineLimit(1)
                .fixedSize()
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
        if let estimate = monitor.remainingEstimate(for: job) {
            text += " · \(Self.remainingText(estimate))"
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
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(job.progress.formatted(.percent.precision(.fractionLength(0))))
                    .foregroundStyle(.secondary)
                    .fixedSize()
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
        if let work = job.telemetry?.work, let label = work.unitLabel {
            // Video-heavy scans: the frame plan is the honest progress unit.
            if let total = work.unitsTotal {
                let approx = work.totalIsEstimate ? "~" : ""
                parts.append("\(work.unitsDone.formatted()) of \(approx)\(total.formatted()) \(label)")
            } else {
                parts.append("\(work.unitsDone.formatted()) \(label)")
            }
        }
        if job.totalBytes > 0 {
            parts.append("\(job.processedBytes.formattedBytes) of \(job.totalBytes.formattedBytes) read")
        }
        if let counters = job.telemetry?.counters {
            parts.append(contentsOf: counters.map { "\($0.value.formatted()) \($0.label.lowercased())" })
        }
        return parts.isEmpty ? "Waiting for the job to report" : parts.joined(separator: " · ")
    }

    // MARK: - Throughput

    /// The speed card: big fixed-width readouts, a labelled chart against
    /// the link's ceiling, and — for jobs that time their phases — where
    /// the time goes.
    private func throughputCard(now: TimeInterval) -> some View {
        let live = monitor.readout(for: job, now: now)
        let wholeJob = chartRange == .wholeJob ? wholeJobSamples : nil
        let readout = wholeJob.map { samples in
            live.wholeJob(samples: samples(), elapsed: max((job.finishedAt ?? Date()).timeIntervalSince(job.createdAt), 0))
        } ?? live
        return VStack(alignment: .leading, spacing: 10) {
            // Metrics, range picker and hardware share one row while the
            // card is wide enough; narrower, the picker and hardware drop
            // to a second row instead of squeezing past the card's edge.
            // A custom Layout rather than ViewThatFits: ViewThatFits
            // renders every variant, and a second live segmented picker
            // inside a table row makes AppKit's accessibility walk
            // re-enter the view graph until the pane hangs.
            MetricsRowLayout {
                readouts(readout)
                rangePicker
                hardwareStrip
            }
            ThroughputChart(readout: readout, wholeJob: wholeJob != nil)
                // A range switch changes every scale and series at once;
                // rebuild the chart instead of animating its axis marks
                // between domains, and never let the marks paint outside
                // the slot. The ticks reuse the same view, like the
                // transfer rows.
                .id(chartRange)
                .transaction { $0.animation = nil }
                .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132)
                .clipped()
            if let telemetry = job.telemetry, !telemetry.phaseShares.isEmpty {
                PhaseBreakdown(shares: telemetry.phaseShares)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    /// The "Last 3 min / Whole job" switch; absent for jobs this session
    /// did not record (the toggle needs the recorder's samples).
    @ViewBuilder
    private var rangePicker: some View {
        if wholeJobSamples != nil {
            Picker("Chart range", selection: $chartRange) {
                Text("Last 3 min").tag(ThroughputChartRange.recent)
                Text("Whole job").tag(ThroughputChartRange.wholeJob)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Show the last three minutes, or every second of this job from its recorded history")
        }
    }

    private func readouts(_ readout: JobThroughputReadout) -> some View {
        let unit = readout.unit.axisLabel
        let bytes = readout.unit == .megabytesPerSecond
        let current: String? = readout.current.map { bytes ? JobThroughputFormat.rate($0) : JobThroughputFormat.itemRate($0) }
        let average: String? = readout.average.map { bytes ? JobThroughputFormat.rate($0) : JobThroughputFormat.itemRate($0) }
        // A job with parallel transfers reports them together.
        let combined = job.telemetry?.transferBytes != nil
        let nowLabel = combined ? "now · combined" : "now"
        let nowCaption: String = readout.heldFor.map { "\(nowLabel) · held \(Self.durationText($0))" } ?? nowLabel
        let nowHelp: String = (readout.isHeld
            ? "No progress reported for a few seconds — the last smoothed speed is held, not blanked."
            : "Smoothed over about the last 5 seconds") + (combined ? " All parallel transfers together." : "")
        let filesUnit = job.action == .faceScan ? "photos/s" : "files/s"
        return HStack(alignment: .firstTextBaseline, spacing: 22) {
            // A finished job has no current speed: its average leads.
            if job.state == .running || job.state == .queued {
                ThroughputValue(value: current, unit: unit, caption: nowCaption, prominent: true, faded: readout.isHeld, help: nowHelp)
            }
            ThroughputValue(value: average, unit: unit, caption: combined ? "average · combined" : "average", prominent: !(job.state == .running || job.state == .queued), help: "Everything this job has moved, over its elapsed time" + (combined ? ", all parallel transfers together" : ""))
            if let files = readout.filesPerSecond {
                ThroughputValue(value: JobThroughputFormat.itemRate(files), unit: filesUnit, caption: "files", faded: readout.isHeld, help: readout.wholeJobRate ? "Files finished per second over the whole job so far" : "Finished files per second, smoothed")
            }
            if let frames = readout.framesPerSecond {
                ThroughputValue(value: JobThroughputFormat.itemRate(frames), unit: "frames/s", caption: "video", help: "Video frames decoded per second, smoothed")
            }
        }
    }

    // MARK: - Machine pressure

    /// CPU, GPU and thermal in one compact strip. Counters macOS does not
    /// expose are left out rather than shown as "n/a"; the tooltip says why.
    private var hardwareStrip: some View {
        HStack(spacing: 12) {
            metricCell(
                "CPU",
                fraction: monitor.hardware.cpuFraction,
                history: monitor.cpuHistory,
                help: "System-wide CPU load across all cores. Neural Engine load is not shown: macOS only reports it through powermetrics, which needs administrator rights."
            )
            if monitor.hardware.gpuFraction != nil || !monitor.gpuHistory.isEmpty {
                metricCell(
                    "GPU",
                    fraction: monitor.hardware.gpuFraction,
                    history: monitor.gpuHistory,
                    help: "GPU device utilization reported by the driver"
                )
            }
            thermalCell
        }
    }

    private func metricCell(
        _ label: String,
        fraction: Double?,
        history: [Double],
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    // "CPU" must never fold to one letter per line.
                    .fixedSize()
                Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? JobThroughputFormat.placeholder)
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                    .frame(minWidth: 32, alignment: .trailing)
            }
            Sparkline(samples: history, tint: .secondary, fixedPeak: 1)
                .frame(width: 64, height: 14)
        }
        .fixedSize()
        .help(help)
    }

    private var thermalCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("THERMAL")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(thermalLabel)
                .font(.caption)
                .foregroundStyle(thermalColor)
                .lineLimit(1)
                .frame(height: 14)
        }
        .fixedSize()
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
                .lineLimit(2)
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
            .background(stepColor(step).quinary, in: Capsule())
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
        case "flush", "flushing to nas": .orange
        case "rename": .purple
        case "copying to nas": .blue
        case "re-reading nas copy": .green
        case "hashing drive copy": .teal
        default: .secondary
        }
    }

    /// Anything past this reads as "many hours" — a four-day estimate is
    /// noise, not information.
    static let remainingDisplayCap: TimeInterval = 99 * 3600

    /// "~1 h 5 m left", "~12 m left", "under a minute left",
    /// "estimating…", or "many hours left" past `remainingDisplayCap`.
    static func remainingText(_ estimate: JobActivityMonitor.RemainingEstimate) -> String {
        guard case .seconds(let interval) = estimate else { return "estimating…" }
        guard interval.isFinite, interval <= remainingDisplayCap else { return "many hours left" }
        let minutes = Int((max(interval, 0) / 60).rounded())
        if interval < 60 { return "under a minute left" }
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "~\(hours) h left" : "~\(hours) h \(rest) m left"
        }
        return "~\(minutes) m left"
    }

    nonisolated static func durationText(_ interval: TimeInterval) -> String {
        let seconds = Int(max(interval, 0).rounded())
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A small live line graph — samples oldest → newest, autoscaled to the
/// window peak (or to `fixedPeak`, so a 20 % load does not fill the
/// track) with a soft fill. Empty data draws an empty track.
struct Sparkline: View {
    var samples: [Double]
    var tint: Color = .accentColor
    var fixedPeak: Double?

    var body: some View {
        Canvas { context, size in
            guard let peak = fixedPeak ?? samples.max(), peak > 0, samples.count > 1 else { return }
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

/// The throughput chart's time range: the rolling live window, or every
/// recorded second of the job.
enum ThroughputChartRange: String {
    case recent
    case wholeJob
}

/// One labelled readout: a fixed-width number that never blanks between
/// samples (a held value fades instead), its unit, and what it measures.
struct ThroughputValue: View {
    var value: String?
    var unit: String
    var caption: String
    var prominent = false
    var faded = false
    var help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption.uppercased())
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? JobThroughputFormat.placeholder)
                    .font(.system(size: prominent ? 28 : 18, weight: prominent ? .semibold : .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(value == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .opacity(faded ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.4), value: faded)
        }
        // A fixed slot: the unit and the next readout stay put as digits
        // and the "held" caption come and go.
        .frame(minWidth: prominent ? 132 : 96, alignment: .leading)
        .help(help)
    }
}

/// The speed card's header: readouts on the left, the range picker and
/// the hardware strip on the right — all on one row while they fit, and
/// on two rows (readouts above, picker and hardware below) when they do
/// not, so the pane never needs more width than the window gives it.
/// Each subview is laid out once — unlike `ViewThatFits`, which would
/// keep a second copy of the segmented picker alive and make AppKit's
/// accessibility walk re-enter the table's view graph until it hangs.
private struct MetricsRowLayout: Layout {
    var spacing = 16.0
    var rowSpacing = 8.0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rowHeight = sizes.map(\.height).max() ?? 0
        let oneRow = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
        guard let limit = proposal.width, oneRow > limit, sizes.count > 1 else {
            return CGSize(width: min(oneRow, proposal.width ?? oneRow), height: rowHeight)
        }
        let secondHeight = sizes.dropFirst().map(\.height).max() ?? 0
        // Folded, the row claims the offered width so its second line
        // reaches the card's right edge like the single row does.
        return CGSize(
            width: limit,
            height: sizes[0].height + rowSpacing + secondHeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let oneRow = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
        if oneRow <= bounds.width || subviews.count < 2 {
            // One row: the readouts lead, the rest trail in order.
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .init(sizes[0]))
            placeTrailing(subviews, sizes: sizes, in: bounds, y: bounds.minY, from: 1)
        } else {
            // Two rows: readouts above, picker and hardware below, still
            // trailing and still in order.
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .init(sizes[0]))
            placeTrailing(subviews, sizes: sizes, in: bounds, y: bounds.minY + sizes[0].height + rowSpacing, from: 1)
        }
    }

    /// Lays out `subviews[from...]` at `bounds`' trailing edge, in index
    /// order left to right.
    private func placeTrailing(_ subviews: Subviews, sizes: [CGSize], in bounds: CGRect, y: CGFloat, from start: Int) {
        var trailing = bounds.maxX
        for index in subviews.indices.dropFirst(start).reversed() {
            trailing -= sizes[index].width
            subviews[index].place(at: CGPoint(x: trailing, y: y), anchor: .topLeading, proposal: .init(sizes[index]))
            trailing -= spacing
        }
    }
}

/// Throughput over the last few minutes: one smoothed line per series
/// (a Sync job's copy/write and verify/re-read rates), a labelled y-axis in
/// MB/s on a scale that does not jump with every spike, elapsed job time
/// along x, and the link's expected ceiling as a dashed rule.
struct ThroughputChart: View {
    let readout: JobThroughputReadout
    /// Drawn over the whole job rather than the rolling window.
    var wholeJob = false

    static let seriesColors: [String: Color] = [
        "Throughput": .blue,
        "Files": .blue,
        "Overall": .gray,
        "Copy (write)": .blue,
        "Verify (re-read)": .green,
        "Verify (on NAS)": .mint,
        "Hash (drive read)": .teal,
    ]

    private var colorDomain: [String] { readout.series }
    private var colorRange: [Color] { readout.series.map { Self.seriesColors[$0] ?? .gray } }

    var body: some View {
        if readout.points.isEmpty {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, lineWidth: 1)
                .overlay {
                    Text(readout.average == nil ? "Waiting for the job to move data…" : "No live samples — this job ran while the pane was closed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(readout.points) { point in
                if readout.series.count == 1 {
                    AreaMark(
                        x: .value("Elapsed", point.elapsed),
                        y: .value(readout.unit.axisLabel, point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        .linearGradient(
                            colors: [(Self.seriesColors[point.series] ?? .blue).opacity(0.22), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                LineMark(
                    x: .value("Elapsed", point.elapsed),
                    y: .value(readout.unit.axisLabel, point.value),
                    series: .value("Series", point.series)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .foregroundStyle(by: .value("Series", point.series))
            }
            if let ceiling = readout.ceiling {
                RuleMark(y: .value("Ceiling", ceiling.megabytesPerSecond))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(Color.gray)
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("\(ceiling.caption) expected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale(domain: colorDomain, range: colorRange)
        .chartLegend(readout.series.count > 1 ? .visible : .hidden)
        .chartLegend(position: .top, alignment: .trailing, spacing: 4)
        .chartYScale(domain: 0...max(readout.yUpper, 1))
        .chartXScale(domain: readout.xDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Self.axisNumber(number))
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartYAxisLabel(readout.unit.axisLabel, position: .topLeading)
        .chartXAxis {
            AxisMarks(values: .stride(by: Self.xStride(readout.xDomain))) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(JobActivityDetail.durationText(seconds))
                            .monospacedDigit()
                    }
                }
            }
        }
        .accessibilityLabel(wholeJob ? "Throughput over the whole job" : "Throughput over the last \(Int(JobThroughputTrack.chartWindow / 60)) minutes")
    }

    static func axisNumber(_ value: Double) -> String {
        value >= 10 || value == 0 ? Int(value.rounded()).formatted() : String(format: "%.1f", value)
    }

    /// Tick spacing for elapsed time: every 15 s for a young job, 30 s
    /// once the window is full, and a round step for about six ticks over
    /// a whole job.
    static func xStride(_ domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        if span > JobThroughputTrack.chartWindow { return max(JobHistoryChartMath.timeStride(span), 30) }
        return span > 120 ? 30 : 15
    }
}

/// One parallel transfer: its phase, the file, a bar of the bytes it has
/// moved in that phase, and its own smoothed speed. Every piece has a
/// fixed width, so a row reused by the next file does not reflow.
struct TransferRow: View {
    let item: JobActiveItem

    static func color(_ phase: String?) -> Color {
        switch phase {
        case "Copying": .blue
        case "Flushing": .orange
        case "Verifying": .green
        case "Verifying on NAS": .mint
        case "Hashing": .teal
        case "Renaming": .purple
        case "Failed": .red
        case "Conflict": .orange
        default: .secondary
        }
    }

    var body: some View {
        let phase = item.phase ?? item.step
        HStack(spacing: 8) {
            Text(phase)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Self.color(item.phase))
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
            Text(item.name)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.path)
            ProgressView(value: item.byteFraction ?? 0)
                .progressViewStyle(.linear)
                .tint(Self.color(item.phase))
                .frame(width: 120)
            Text(JobThroughputFormat.sizeProgress(done: item.bytesDone ?? 0, total: item.bytesTotal ?? 0))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 128, alignment: .trailing)
            Text("\(JobThroughputFormat.rate(JobThroughputFormat.megabytes(item.bytesPerSecond ?? 0))) MB/s")
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .frame(width: 84, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where the job's time went — a thin stacked bar plus
/// "Copy 30% · Flush 40% · Verify 25% · Rename 5%", with the speed each
/// data-moving phase ran at.
struct PhaseBreakdown: View {
    let shares: [JobPhaseShare]

    static func color(_ phase: String) -> Color {
        switch phase {
        case "Copy": .blue
        case "Flush": .orange
        case "Verify": .green
        case "Remote verify (NAS)": .mint
        case "Hash": .teal
        case "Rename": .purple
        default: .gray
        }
    }

    /// "Copy 30% · Flush 40% · Verify 25% · Rename 5%"
    static func summary(_ shares: [JobPhaseShare]) -> String {
        shares.map { "\($0.label) \($0.percent)%" }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("BUSY TIME")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .help("Share of the time spent in each phase, summed over the parallel transfers")
                GeometryReader { geometry in
                    HStack(spacing: 1) {
                        ForEach(shares, id: \.label) { share in
                            Rectangle()
                                .fill(Self.color(share.label).gradient)
                                .frame(width: max(geometry.size.width * share.fraction - 1, 1))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
            }
            HStack(spacing: 12) {
                ForEach(shares, id: \.label) { share in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Self.color(share.label))
                            .frame(width: 7, height: 7)
                        Text("\(share.label) \(share.percent)%")
                            .font(.caption.monospacedDigit())
                        if let rate = share.bytesPerSecond {
                            Text("\(JobThroughputFormat.rate(JobThroughputFormat.megabytes(rate))) MB/s")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help("\(share.label): \(JobActivityDetail.durationText(share.seconds)) so far" + (share.bytesPerSecond.map { " at \(JobThroughputFormat.rate(JobThroughputFormat.megabytes($0))) MB/s while running" } ?? ""))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.summary(shares))
        }
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
