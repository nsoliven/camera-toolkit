import AppKit
import CameraToolkitCore
import Charts
import SwiftUI

/// The Jobs window's detail pane for one job — the same "Now" layout
/// whether the job is running or ended long ago: what it is and when, live
/// progress and the files in flight while it runs, the speed readouts and
/// the speed graph over its whole run, what it did to its files, and how
/// it was configured and why it stopped. Every value comes from the job's
/// own counters, its recorded samples, or hardware probes; anything not
/// reported is left out, never faked.
struct JobActivityDetail: View {
    /// This session's job — live counters, transfers and telemetry. Nil
    /// for a job only the history knows.
    let live: JobSnapshot?
    /// The recorded job: row, samples, files and graph. Nil until the store
    /// answers, or when recording is off.
    let detail: JobHistoryDetail?
    let monitor: JobActivityMonitor
    @Binding var zoom: JobHistoryZoom
    let hover: JobHistoryHover
    /// False renders the monitor's current state without sampling — the
    /// off-screen snapshot harness feeds it synthetic samples instead.
    var sampling = true
    /// Uptime and wall time the snapshot harness pins "now" to.
    var fixedUptime: TimeInterval?
    var fixedNow: Date?
    /// Opens the Files list on its Issues filter; nil when there is no list.
    var showIssues: (() -> Void)?
    /// Opens a file's two copies side by side; nil where there is nothing
    /// to compare (not a Sync to NAS job).
    var compare: ((JobHistoryItem, CompareRequest.Mode) -> Void)?

    var isLive: Bool {
        guard let live else { return false }
        return live.state == .running || live.state == .queued
    }

    private var kind: String { detail?.job.kind ?? live?.action.rawValue ?? "" }

    private var usesGPU: Bool { kind == JobAction.faceScan.rawValue }

    var body: some View {
        if isLive, let live {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(now: fixedNow ?? context.date)
                    .onChange(of: context.date, initial: true) {
                        if sampling { monitor.tick(job: live) }
                    }
            }
        } else {
            content(now: fixedNow ?? Date())
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(now: now)
            if isLive, let live {
                JobLiveHero(job: live, remaining: remainingLine)
            } else {
                finishedHero(now: now)
                problems
            }
            if showsTally { tally }
            speedCard(now: now)
            details
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var remainingLine: String? {
        guard isLive, let live, let estimate = monitor.remainingEstimate(for: live) else { return nil }
        return JobActivityDetail.remainingText(estimate)
    }

    /// While a job runs the hero already says its files and bytes; only a
    /// sync has more to add (copied against already there and verified).
    private var showsTally: Bool {
        !isLive || kind == JobAction.syncBuffer.rawValue
    }

    // MARK: - Finished

    private func finishedHero(now: Date) -> some View {
        let hero = JobDetailFacts.finishedHero(
            job: detail?.job, live: live, outcome: outcome, display: display,
            graph: graph(now: now), elapsed: elapsed(now: now)
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(hero.headline)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(display.tone == .failure || display.tone == .warning ? display.tone.color : .primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let value = hero.value {
                    Text(value)
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if let subline = hero.subline {
                Text(subline)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Why a finished job ended the way it did: right under its result, so
    /// a conflict or a failure is never below the fold.
    @ViewBuilder
    private var problems: some View {
        if let checks = detail?.job.summary?.cardClearChecks {
            let lines = CardClearWording.finishedChecks(checks)
            if !lines.isEmpty {
                CardClearChecksView(lines: lines, showsResults: true)
            }
        }
        if let job = detail?.job {
            JobIssueSection(job: job, items: detail?.items ?? [], showIssues: showIssues, compare: compare)
        }
    }

    // MARK: - Header

    /// The job's recorded title, naming the pass that is running now.
    private var title: String {
        let recorded = detail?.job.title ?? live?.action.displayName ?? "Job"
        guard isLive, let pass = live?.telemetry?.scanPass else { return recorded }
        return pass.title(forRecorded: recorded)
    }

    private var outcome: JobHistoryOutcome {
        if isLive { return .running }
        if let live { return JobHistoryOutcome(live.state) }
        guard let job = detail?.job else { return .interrupted }
        return job.outcome == .running ? .interrupted : job.outcome
    }

    private var startedAt: Date? { live?.createdAt ?? detail?.job.startedAt }
    private var endedAt: Date? { isLive ? nil : (live?.finishedAt ?? detail?.job.endedAt) }

    private func elapsed(now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max((endedAt ?? now).timeIntervalSince(startedAt), 0)
    }

    private func header(now: Date) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isLive ? (live.map { JobListRow.runningSymbol($0.action) } ?? display.symbol) : display.symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(display.tone == .success ? .secondary : display.tone.color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(timing(now: now))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            JobHistoryOutcomeBadge(display: display)
        }
    }

    private var display: JobOutcomeDisplay {
        JobDetailFacts.outcomeDisplay(outcome, job: isLive ? nil : detail?.job)
    }

    /// "Today 12:31 – 12:33" or "Started 12:31 · 0:42"; the result and the
    /// time left have their own place.
    private func timing(now: Date) -> String {
        guard let startedAt else { return "" }
        let when = JobDetailFacts.when(start: startedAt, end: endedAt, now: now)
        return isLive ? "\(when) · \(JobActivityDetail.durationText(elapsed(now: now)))" : when
    }

    // MARK: - Speed

    private func graph(now: Date) -> JobSpeedGraph {
        detail?.graph ?? JobSpeedGraph.build(samples: [], kind: kind, duration: elapsed(now: now))
    }

    private func readouts(now: Date, graph: JobSpeedGraph) -> [JobReadout] {
        if let live, isLive || detail == nil {
            return JobDetailFacts.liveReadouts(monitor.readout(for: live, now: fixedUptime ?? ProcessInfo.processInfo.systemUptime), graph: graph, job: live)
        }
        if let job = detail?.job {
            return JobDetailFacts.finishedReadouts(job: job, graph: graph)
        }
        return []
    }

    private var phaseShares: [JobPhaseShare] {
        if let shares = live?.telemetry?.phaseShares, !shares.isEmpty { return shares }
        return detail?.job.summary.map { JobTelemetry.shares(of: $0.phases) } ?? []
    }

    /// The readouts and the speed graph.
    private func speedCard(now: Date) -> some View {
        let graph = graph(now: now)
        let values = readouts(now: now, graph: graph)
        return VStack(alignment: .leading, spacing: 14) {
            if !values.isEmpty {
                WrappingRowLayout(spacing: 28) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, readout in
                        ThroughputValue(value: readout.value, unit: readout.unit, caption: readout.caption, prominent: readout.prominent, faded: readout.faded, help: readout.help)
                    }
                }
            }
            JobSpeedGraphView(
                graph: graph,
                samples: detail?.samples ?? [],
                kind: kind,
                isLive: isLive,
                zoom: $zoom,
                hover: hover,
                flights: detail?.flights,
                items: detail?.items ?? []
            )
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Tally

    @ViewBuilder
    private var tally: some View {
        let items = JobDetailFacts.tally(job: detail?.job, live: live, items: detail?.items ?? [])
        if !items.isEmpty {
            WrappingRowLayout(spacing: 32, rowSpacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.value)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(item.tone.color)
                            .lineLimit(1)
                    }
                    .help(item.help ?? "")
                }
            }
        }
    }

    // MARK: - Details

    /// What most people never need: how the job was set up, which models
    /// it runs, where the time went, and the machine while it runs.
    @ViewBuilder
    private var details: some View {
        let configuration = JobDetailFacts.configuration(job: detail?.job, live: live)
        let telemetry = live?.telemetry
        let hasModels = !(telemetry?.models.isEmpty ?? true) || !(telemetry?.facts.isEmpty ?? true)
        // One phase over the whole job says nothing a bar could add.
        let hasPhases = phaseShares.count > 1
        if isLive || hasModels || hasPhases || !configuration.isEmpty {
            JobDetailsSection {
                VStack(alignment: .leading, spacing: 10) {
                    if !configuration.isEmpty {
                        Text(configuration)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    debugLines
                    if hasPhases {
                        PhaseBreakdown(shares: phaseShares)
                    }
                    if isLive {
                        hardwareStrip
                    }
                }
            }
        }
    }

    /// CPU, GPU and thermal in one compact strip. Counters macOS does not
    /// expose are left out rather than shown as "n/a"; the tooltip says why.
    private var hardwareStrip: some View {
        HStack(spacing: 16) {
            metricCell(
                "CPU",
                fraction: monitor.hardware.cpuFraction,
                history: monitor.cpuHistory,
                help: "System-wide CPU load across all cores. Neural Engine load is not shown: macOS only reports it through powermetrics, which needs administrator rights."
            )
            if usesGPU, monitor.hardware.gpuFraction != nil || !monitor.gpuHistory.isEmpty {
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
                    .font(.caption)
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
            Text("Thermal")
                .font(.caption)
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

    /// The debug lines the owner asked for: real package names — never the
    /// product euphemisms — plus how the pass is configured.
    @ViewBuilder
    private var debugLines: some View {
        if let telemetry = live?.telemetry, !telemetry.models.isEmpty || !telemetry.facts.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if !telemetry.models.isEmpty {
                    debugLine(telemetry.scanPass?.isMultiPass == true ? "\(telemetry.scanPass?.subject.title ?? "") models" : "Models", telemetry.models.joined(separator: " · "))
                }
                if !telemetry.facts.isEmpty {
                    debugLine("Settings", telemetry.facts.joined(separator: " · "))
                }
            }
        }
    }

    private func debugLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    /// Anything past this reads as "many hours" — a four-day estimate is
    /// noise, not information.
    static let remainingDisplayCap: TimeInterval = 99 * 3600

    /// "~1 h 5 m left", "~12 m left", "under a minute left", or "many
    /// hours left" past `remainingDisplayCap`. Nil until there is a real
    /// estimate: the window says nothing rather than promising one.
    static func remainingText(_ estimate: JobActivityMonitor.RemainingEstimate) -> String? {
        guard case .seconds(let interval) = estimate else { return nil }
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

/// Details folded away until asked for. Keeps its own open state so the
/// live pane's once-a-second redraw does not close it.
private struct JobDetailsSection<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content()
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Details")
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
        }
    }
}

/// The hero's progress bar: blue whatever the system accent, and in one
/// segment per pass for a job in passes, the earlier ones full. The fill
/// only ever grows, even as the next pass's counts restart.
struct JobPassBar: View {
    var segments = 1
    /// The whole job, 0...1.
    let fraction: Double

    static func segmentFill(_ segment: Int, count: Int, fraction: Double) -> Double {
        min(max(fraction * Double(count) - Double(segment), 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 3
            let count = max(segments, 1)
            let width = max((geometry.size.width - gap * CGFloat(count - 1)) / CGFloat(count), 0)
            HStack(spacing: gap) {
                ForEach(0..<count, id: \.self) { segment in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.blue)
                            .frame(width: width * Self.segmentFill(segment, count: count, fraction: fraction))
                    }
                    .frame(width: width)
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    }
}

/// The big answer for a running job: what it is doing, how far along, when
/// it will finish, then its counts and the file in hand.
private struct JobLiveHero: View {
    let job: JobSnapshot
    let remaining: String?

    private var percent: String {
        job.progress.formatted(.percent.precision(.fractionLength(0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(JobDetailFacts.liveHeadline(job))
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(percent)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .fixedSize()
            }
            if let subline = JobDetailFacts.liveSubline(job, remaining: remaining) {
                Text(subline)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            JobPassBar(segments: job.telemetry?.scanPass?.count ?? 1, fraction: min(max(job.progress, 0), 1))
            Text(JobDetailFacts.liveCounts(job))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            headline
        }
    }

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
    var headline: some View {
        if job.telemetry?.configuration != nil, job.action == .syncBuffer || !transferRows.isEmpty {
            transferHeadline
        } else {
            itemHeadline
        }
    }

    /// One steady row per parallel transfer; how they are set up lives
    /// under Details.
    @ViewBuilder
    private var transferHeadline: some View {
        VStack(alignment: .leading, spacing: 6) {
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

    /// The one file to look at, and how many more are in flight.
    @ViewBuilder
    private var itemHeadline: some View {
        if let first = headlineItems.first {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(first.step)
                    .foregroundStyle(stepColor(first.step))
                Text(first.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(first.path)
                if headlineItems.count > 1 {
                    Text("+\(headlineItems.count - 1) more")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout.monospacedDigit())
        }
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
        case "checking drive copy": .teal
        case "checking nas copy": .green
        case "checking card file": .blue
        case "deleting from card": .red
        default: .secondary
        }
    }

}

/// Why a job ended the way it did, in place: a one-line answer that opens
/// into the closing note one clause per line, every conflicting or failed
/// file with its reason and what to do about it, the full report in
/// Finder, and a jump to the Files list's Issues. Nothing is cut off —
/// every line wraps, and the pane around it scrolls.
private struct JobIssueSection: View {
    let job: JobHistoryJob
    let items: [JobHistoryItem]
    let showIssues: (() -> Void)?
    let compare: ((JobHistoryItem, CompareRequest.Mode) -> Void)?
    @State private var expanded = true

    /// Files listed here before the rest wait in the Files list.
    static let listedLimit = 25

    var body: some View {
        let summary = job.summary
        let parts: (clauses: [String], reportPath: String?) = summary?.note.map(JobDetailFacts.noteParts) ?? ([], nil)
        let issues = items.filter { $0.outcome == .failed || $0.outcome == .conflict }
        let notes: [String] = [
            summary?.timings?.remoteFallbackReason.map { "NAS-side hashing fell back to SMB: \($0)" },
            (summary?.hashMismatches ?? 0) > 0 ? "\(summary?.hashMismatches ?? 0) NAS cop\(summary?.hashMismatches == 1 ? "y" : "ies") did not match the drive's SHA-256" : nil,
            (summary?.notAttempted ?? 0) > 0 ? "\(summary?.notAttempted ?? 0) not attempted" : nil,
        ].compactMap { $0 }
        let display = JobDetailFacts.outcomeDisplay(job.outcome, job: job)
        let hasIssues = job.outcome != .succeeded || !issues.isEmpty || !notes.isEmpty
        if hasIssues {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if !parts.clauses.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array((parts.clauses + notes).enumerated()), id: \.offset) { _, clause in
                                Label {
                                    Text(clause).fixedSize(horizontal: false, vertical: true)
                                } icon: {
                                    Image(systemName: "circle.fill").font(.system(size: 4))
                                }
                            }
                        }
                        .font(.callout)
                    }
                    if !issues.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(issues.prefix(Self.listedLimit).enumerated()), id: \.offset) { _, item in
                                issueRow(item)
                            }
                            if issues.count > Self.listedLimit {
                                Text("+\((issues.count - Self.listedLimit).formatted()) more in the Files list")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        if !issues.isEmpty, let showIssues {
                            Button("Show in Files", systemImage: "line.3.horizontal.decrease.circle", action: showIssues)
                                .help("Show only the files with problems in the list below")
                        }
                        if let path = parts.reportPath, FileManager.default.fileExists(atPath: path) {
                            Button("Reveal Report", systemImage: "doc.text.magnifyingglass") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                            .help("Show the job's full per-file report in Finder")
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: display.symbol)
                        .foregroundStyle(display.tone.color)
                    Text(JobDetailFacts.issueHeadline(job))
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(display.tone.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func issueRow(_ item: JobHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.outcome.label(kind: job.kind))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(item.outcome.tint(kind: job.kind))
                Text(item.fileName)
                    .font(.callout)
                    .help(item.relativePath)
                if item.outcome == .conflict, let compare {
                    Button("Compare…") { compare(item, .conflict) }
                        .controlSize(.small)
                        .help("See both versions side by side and choose which to keep")
                }
            }
            if let error = item.error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(JobDetailFacts.advice(for: item, kind: job.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension JobTallyItem.Tone {
    var color: Color {
        switch self {
        case .normal: .primary
        case .warning: .orange
        case .failure: .red
        }
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
        VStack(alignment: .leading, spacing: 1) {
            Text(caption.prefix(1).uppercased() + caption.dropFirst())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? JobThroughputFormat.placeholder)
                    .font(.system(size: prominent ? 22 : 17, weight: prominent ? .semibold : .regular))
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
        .frame(minWidth: prominent ? 118 : 88, alignment: .leading)
        .help(help)
    }
}

/// Lays its subviews out left to right and wraps to a new row when the
/// next one does not fit — the readouts, the machine strip and the tally
/// keep their fixed widths and never push the pane wider than the window.
/// Each subview is laid out once (unlike `ViewThatFits`, which keeps a copy
/// of every variant alive).
struct WrappingRowLayout: Layout {
    var spacing: CGFloat = 22
    var rowSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .init(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, width limit: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > limit {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
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
                .frame(width: 104, alignment: .leading)
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.path)
            ProgressView(value: item.byteFraction ?? 0)
                .progressViewStyle(.linear)
                .tint(Self.color(item.phase))
                .frame(width: 90)
            Text(JobThroughputFormat.sizeProgress(done: item.bytesDone ?? 0, total: item.bytesTotal ?? 0))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 116, alignment: .trailing)
            Text("\(JobThroughputFormat.rate(JobThroughputFormat.megabytes(item.bytesPerSecond ?? 0))) MB/s")
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .frame(width: 80, alignment: .trailing)
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
        case "Remove": .orange
        case "Check": .gray
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
                Text("Busy time")
                    .font(.caption)
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
            WrappingRowLayout(spacing: 12, rowSpacing: 4) {
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
