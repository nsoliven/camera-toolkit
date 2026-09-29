import AppKit
import CameraToolkitCore
import Charts
import SwiftUI

/// The Jobs window's History: every recorded job, newest first, and the
/// one selected opened beside it — its totals, a zoomable speed chart over
/// the whole run, and every file it moved. Read from `job-history.sqlite`
/// through `JobHistoryBrowser`; nothing here writes.
struct JobHistoryView: View {
    @Bindable var model: DashboardModel
    let browser: JobHistoryBrowser
    @State private var selection: UUID?

    init(model: DashboardModel, browser: JobHistoryBrowser, selection: UUID? = nil) {
        self.model = model
        self.browser = browser
        _selection = State(initialValue: selection ?? browser.detail?.job.id)
    }

    /// Re-reads on selection and whenever a recorded job ends.
    private struct LoadKey: Equatable {
        var selection: UUID?
        var revision: Int
    }

    var body: some View {
        HSplitView {
            JobHistoryList(browser: browser, selection: $selection)
                // 220 + the divider + 440 stays under the window's 720
                // minimum; more and the detail pane runs off the edge.
                .frame(minWidth: 220, idealWidth: 290, maxWidth: 400, maxHeight: .infinity)
            detailPane
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: model.jobHistoryRevision) {
            await browser.reload()
            if selection == nil { selection = browser.jobs.first?.id }
        }
        .task(id: LoadKey(selection: selection, revision: model.jobHistoryRevision)) {
            await browser.open(selection)
            // A job still running keeps growing: reread it (and the list
            // row) as its batches land.
            while !Task.isCancelled, let detail = browser.detail, browser.isLive(detail.job) {
                try? await Task.sleep(for: .seconds(JobHistoryRecorder.flushInterval))
                guard !Task.isCancelled else { return }
                await browser.open(selection)
                await browser.reload()
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let detail = browser.detail, detail.job.id == selection {
            JobHistoryDetailView(detail: detail, isLive: browser.isLive(detail.job))
                .id(detail.job.id)
        } else if selection != nil, browser.isLoadingDetail {
            ProgressView("Reading the job…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                browser.jobs.isEmpty ? "No Recorded Jobs" : "Select a Job",
                systemImage: "chart.xyaxis.line",
                description: Text(browser.jobs.isEmpty
                    ? "Jobs are recorded from now on — each one's speed, second by second, and every file it moved."
                    : "Pick a job to see its whole run and its files.")
            )
        }
    }
}

// MARK: - List

private struct JobHistoryList: View {
    let browser: JobHistoryBrowser
    @Binding var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let message = browser.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            List(browser.jobs, selection: $selection) { job in
                JobHistoryRow(job: job)
                    .tag(job.id)
            }
            .listStyle(.inset)
            .overlay {
                if browser.hasLoaded, browser.jobs.isEmpty, browser.message == nil {
                    Text("No jobs recorded yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One past job: what it was, when, how long, how much it moved and how
/// fast, how it ended, and its file counts.
private struct JobHistoryRow: View {
    let job: JobHistoryJob

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.outcome.symbol)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(job.outcome.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(job.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    JobHistoryOutcomeBadge(outcome: job.outcome)
                }
                Text("\(job.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(JobActivityDetail.durationText(job.duration()))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(JobHistoryText.movedAndSpeed(job))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let counts = JobHistoryText.counts(job) {
                    Text(counts)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
        .help(job.summary?.note ?? job.title)
    }
}

struct JobHistoryOutcomeBadge: View {
    let outcome: JobHistoryOutcome

    var body: some View {
        Text(outcome.label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(outcome.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(outcome.tint.quinary, in: Capsule())
    }
}

extension JobHistoryOutcome {
    var label: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }

    var symbol: String {
        switch self {
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case .interrupted: "bolt.horizontal.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .secondary
        case .interrupted: .orange
        }
    }
}

extension JobHistoryItemOutcome {
    var label: String {
        switch self {
        case .copied: "Copied"
        case .matched: "Already on NAS"
        case .alreadyVerified: "Verified before"
        case .conflict: "Conflict"
        case .failed: "Failed"
        }
    }

    var tint: Color {
        switch self {
        case .copied: .green
        case .matched, .alreadyVerified: .secondary
        case .conflict: .orange
        case .failed: .red
        }
    }
}

/// The strings History shows, kept pure for tests.
enum JobHistoryText {
    /// "12.4 GB moved · 104.2 MB/s average"
    static func movedAndSpeed(_ job: JobHistoryJob, now: Date = Date()) -> String {
        let verb = job.kind == JobAction.syncBuffer.rawValue ? "copied" : "moved"
        var parts = [job.bytesDone > 0 ? "\(job.bytesDone.formattedBytes) \(verb)" : "Nothing \(verb)"]
        if let rate = job.averageBytesPerSecond(now: now) {
            parts.append("\(JobThroughputFormat.rate(JobThroughputFormat.megabytes(rate))) MB/s average")
        }
        return parts.joined(separator: " · ")
    }

    /// "120 copied · 4,000 already on NAS · 2 conflicts · 1 failed"; the
    /// file total for jobs without per-file outcomes; nil with no files.
    static func counts(_ job: JobHistoryJob) -> String? {
        let already = job.matchedExisting + job.alreadyVerified
        var parts: [String] = []
        if job.copied > 0 { parts.append("\(job.copied.formatted()) copied") }
        if already > 0 { parts.append("\(already.formatted()) already on NAS") }
        if job.conflicts > 0 { parts.append("\(job.conflicts.formatted()) conflict\(job.conflicts == 1 ? "" : "s")") }
        if job.failed > 0 { parts.append("\(job.failed.formatted()) failed") }
        if parts.isEmpty, job.totalFiles > 0 { parts.append("\(job.totalFiles.formatted()) files") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "0:12:04 – 0:15:10 of 1:02:33"
    static func range(_ zoom: JobHistoryZoom) -> String {
        "\(JobActivityDetail.durationText(zoom.visible.lowerBound)) – \(JobActivityDetail.durationText(zoom.visible.upperBound)) of \(JobActivityDetail.durationText(zoom.fullSpan))"
    }

    /// A file's exact stats, for its row's tooltip.
    static func item(_ item: JobHistoryItem) -> String {
        var lines = ["\(item.relativePath)", "\(item.byteCount.formattedBytes) (\(item.byteCount.formatted()) bytes) · \(item.outcome.label)"]
        if let start = item.start {
            lines.append("In flight \(JobActivityDetail.durationText(start)) → \(JobActivityDetail.durationText(item.end)) · \(seconds(item.end - start))")
        } else {
            lines.append("Settled at \(JobActivityDetail.durationText(item.end)) without a transfer")
        }
        var timing: [String] = []
        if let copy = item.copySeconds { timing.append("copy \(seconds(copy))") }
        if let verify = item.verifySeconds {
            timing.append("verify \(seconds(verify))\(item.verifyMethod.map { $0 == "ssh" ? " on the NAS (SSH)" : " over SMB" } ?? "")")
        }
        if !timing.isEmpty { lines.append(timing.joined(separator: " · ")) }
        if let speed = item.averageMegabytesPerSecond { lines.append("\(JobThroughputFormat.rate(speed)) MB/s over its time in flight") }
        if let slot = item.slot { lines.append("Transfer \(slot + 1)") }
        if let error = item.error { lines.append(error) }
        return lines.joined(separator: "\n")
    }

    /// "4.1 s", "0.25 s", "1:02"
    static func seconds(_ value: Double) -> String {
        if value >= 60 { return JobActivityDetail.durationText(value) }
        return value < 1 ? String(format: "%.2f s", value) : String(format: "%.1f s", value)
    }
}

// MARK: - Detail

/// Pointer state the chart and the file table share. Only the views that
/// draw it read it, so moving the pointer never redraws the chart's lines.
@MainActor
@Observable
final class JobHistoryHover {
    /// Job time under the pointer on the chart.
    var t: Double?
    /// Files (indexes into the job's items) in flight at `t`.
    var inFlight: Set<Int> = []
    /// The file row under the pointer in the table.
    var row: Int?
}

struct JobHistoryDetailView: View {
    let detail: JobHistoryDetail
    let isLive: Bool
    @State private var zoom: JobHistoryZoom
    @State private var hover: JobHistoryHover

    /// `hover` and `zoom` are seams for the snapshot harness.
    init(detail: JobHistoryDetail, isLive: Bool, hover: JobHistoryHover = JobHistoryHover(), zoom: JobHistoryZoom? = nil) {
        self.detail = detail
        self.isLive = isLive
        _zoom = State(initialValue: zoom ?? JobHistoryZoom(full: 0...detail.chart.duration))
        _hover = State(initialValue: hover)
    }

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 10) {
                JobHistorySummaryHeader(job: detail.job, items: detail.items)
                JobHistoryChartCard(detail: detail, zoom: $zoom, hover: hover)
            }
            .padding(12)
            .frame(minHeight: 470, idealHeight: 540, maxHeight: .infinity, alignment: .top)
            JobHistoryFileTable(items: detail.items, zoom: $zoom, hover: hover)
                .frame(minHeight: 140, idealHeight: 260, maxHeight: .infinity)
        }
        .onChange(of: detail.chart.duration) { _, duration in
            zoom.setFull(0...duration)
        }
    }
}

/// Totals, speed, where the time went, how it verified — and every
/// failure with its error text.
private struct JobHistorySummaryHeader: View {
    let job: JobHistoryJob
    let items: [JobHistoryItem]

    private var issues: [JobHistoryItem] {
        items.filter { $0.outcome == .failed || $0.outcome == .conflict }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(job.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                JobHistoryOutcomeBadge(outcome: job.outcome)
                Spacer(minLength: 8)
                Text(dateRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                ThroughputValue(value: JobActivityDetail.durationText(job.duration()), unit: "", caption: "duration", help: "Wall time from start to end")
                ThroughputValue(value: job.bytesDone.formattedBytes, unit: "", caption: job.kind == JobAction.syncBuffer.rawValue ? "copied" : "moved", help: "\(job.bytesDone.formatted()) bytes" + (job.totalBytes > 0 ? " of \(job.totalBytes.formattedBytes) planned" : ""))
                ThroughputValue(
                    value: job.averageBytesPerSecond().map { JobThroughputFormat.rate(JobThroughputFormat.megabytes($0)) },
                    unit: "MB/s",
                    caption: job.transferBytes != nil ? "average · combined" : "average",
                    help: "Everything the job moved over its wall time" + (job.transferBytes != nil ? ", all parallel transfers together (copies and SMB re-reads)" : "")
                )
                if let counts = JobHistoryText.counts(job) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FILES")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(counts)
                            .font(.callout.monospacedDigit())
                            .lineLimit(2)
                    }
                }
            }
            if !configurationLine.isEmpty {
                Text(configurationLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let phases = job.summary?.phases, !JobTelemetry.shares(of: phases).isEmpty {
                PhaseBreakdown(shares: JobTelemetry.shares(of: phases))
            }
            problems
        }
    }

    private var dateRange: String {
        let start = job.startedAt.formatted(date: .abbreviated, time: .standard)
        guard let end = job.endedAt else { return "\(start) · running" }
        return "\(start) – \(end.formatted(date: .omitted, time: .standard))"
    }

    /// "4 transfers in parallel · SSH verify · NAS SHA-256 (ssh host) · 2 fell back to SMB"
    private var configurationLine: String {
        var parts: [String] = []
        if let configuration = job.configuration { parts.append(configuration) }
        if let timings = job.summary?.timings {
            // "SMB verify" already says it; the NAS-side label names the host.
            if job.summary?.verifyMethod == "ssh", !timings.verification.isEmpty { parts.append(timings.verification) }
            if timings.remoteBatches > 0 { parts.append("\(timings.remoteBatches) NAS batch\(timings.remoteBatches == 1 ? "" : "es")") }
            if timings.remoteFallbacks > 0 { parts.append("\(timings.remoteFallbacks) fell back to SMB") }
        }
        return parts.joined(separator: " · ")
    }

    /// Why it stopped, why NAS-side hashing fell back, and each failed or
    /// conflicting file with its error — selectable, so it can be copied.
    @ViewBuilder
    private var problems: some View {
        let summary = job.summary
        let notes: [String] = [
            job.outcome == .succeeded ? nil : summary?.note,
            summary?.stoppedReason,
            summary?.timings?.remoteFallbackReason.map { "NAS-side hashing fell back: \($0)" },
            (summary?.hashMismatches ?? 0) > 0 ? "\(summary?.hashMismatches ?? 0) NAS cop\(summary?.hashMismatches == 1 ? "y" : "ies") did not match the drive's SHA-256" : nil,
            (summary?.notAttempted ?? 0) > 0 ? "\(summary?.notAttempted ?? 0) not attempted" : nil,
        ].compactMap { $0 }
        if !notes.isEmpty || !issues.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(job.outcome == .failed ? .red : .orange)
                    }
                    ForEach(Array(issues.prefix(200).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(item.outcome.label)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(item.outcome.tint)
                                .frame(width: 54, alignment: .leading)
                            Text(item.fileName)
                                .font(.caption.monospaced())
                                .help(item.relativePath)
                            Text(item.error ?? "")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if issues.count > 200 {
                        Text("+\(issues.count - 200) more in the file list")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // As tall as its lines, up to five of them; then it scrolls.
            .frame(height: min(84, CGFloat(notes.count + min(issues.count, 201)) * 17))
        }
    }
}

// MARK: - Chart

/// The speed chart over the whole job: zoom and pan on time, hover for the
/// exact values and the files in flight.
private struct JobHistoryChartCard: View {
    let detail: JobHistoryDetail
    @Binding var zoom: JobHistoryZoom
    let hover: JobHistoryHover

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("SPEED")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(JobHistoryText.range(zoom))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Drag across to zoom in · scroll or pinch to zoom · double-click to fit")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                ControlGroup {
                    Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                        zoom.zoom(by: 0.5, around: (zoom.visible.lowerBound + zoom.visible.upperBound) / 2)
                    }
                    Button("Zoom In", systemImage: "plus.magnifyingglass") {
                        zoom.zoom(by: 2, around: (zoom.visible.lowerBound + zoom.visible.upperBound) / 2)
                    }
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .fixedSize()
                Button("Fit") { zoom.fit() }
                    .controlSize(.small)
                    .disabled(zoom.isFit)
                    .help("Show the whole job")
            }
            if detail.samples.isEmpty {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary, lineWidth: 1)
                    .overlay {
                        Text("No speed samples were recorded for this job.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 160)
            } else {
                JobHistoryPlot(detail: detail, zoom: $zoom, hover: hover)
                    .frame(minHeight: 160, maxHeight: .infinity)
                    // Legend, axes and the hover readout stay inside the
                    // card's slot even across a zoom redraw.
                    .clipped()
                JobHistoryOverview(chart: detail.chart, zoom: $zoom)
                    .frame(height: 30)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One drawn point.
private struct JobHistoryPlotPoint: Identifiable {
    var id: Int
    var series: String
    var t: Double
    var value: Double
}

/// The lines. Redrawn only when the zoom or the width changes — every
/// pointer-driven highlight is drawn by `JobHistoryPlotInteraction` on top.
private struct JobHistoryPlot: View {
    let detail: JobHistoryDetail
    @Binding var zoom: JobHistoryZoom
    let hover: JobHistoryHover
    @State private var plotWidth: CGFloat = 600

    private var colorRange: [Color] { detail.chart.series.map { ThroughputChart.seriesColors[$0] ?? .gray } }

    var body: some View {
        let visible = zoom.visible
        // About one point per 3 px column pair — a min and a max each.
        let lines = detail.chart.visiblePoints(in: visible, buckets: max(Int(plotWidth / 3), 60))
        var points: [JobHistoryPlotPoint] = []
        for line in lines {
            for point in line.points {
                points.append(JobHistoryPlotPoint(id: points.count, series: line.series, t: point.t, value: point.value))
            }
        }
        let unit = detail.chart.unit.axisLabel
        return Chart(points) { point in
            LineMark(
                x: .value("Elapsed", point.t),
                y: .value(unit, point.value),
                series: .value("Series", point.series)
            )
            .interpolationMethod(.linear)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .foregroundStyle(by: .value("Series", point.series))
        }
        .chartForegroundStyleScale(domain: detail.chart.series, range: colorRange)
        .chartLegend(detail.chart.series.count > 1 ? .visible : .hidden)
        .chartLegend(position: .top, alignment: .trailing, spacing: 4)
        .chartXScale(domain: visible)
        .chartYScale(domain: 0...detail.chart.yUpper)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(ThroughputChart.axisNumber(number))
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartYAxisLabel(unit, position: .topLeading)
        .chartXAxis {
            AxisMarks(values: .stride(by: JobHistoryChartMath.timeStride(zoom.span))) { value in
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
        .chartPlotStyle { $0.clipped() }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                JobHistoryPlotInteraction(
                    proxy: proxy,
                    plot: proxy.plotFrame.map { geometry[$0] } ?? CGRect(origin: .zero, size: geometry.size),
                    detail: detail,
                    zoom: $zoom,
                    hover: hover,
                    plotWidth: $plotWidth
                )
            }
        }
        .accessibilityLabel("Speed over the whole job")
    }
}

/// Everything the pointer does on the chart: the hover rule and its
/// readout, the dragged zoom range, the hovered file's span, pinch and
/// scroll zoom, double-click to fit.
private struct JobHistoryPlotInteraction: View {
    let proxy: ChartProxy
    let plot: CGRect
    let detail: JobHistoryDetail
    @Binding var zoom: JobHistoryZoom
    let hover: JobHistoryHover
    @Binding var plotWidth: CGFloat
    @State private var drag: (from: Double, to: Double)?
    @State private var magnifyBase: JobHistoryZoom?
    @State private var scrollMonitor = JobHistoryScrollMonitor()

    private func time(atX x: CGFloat) -> Double? {
        proxy.value(atX: x - plot.minX, as: Double.self).map { min(max($0, zoom.visible.lowerBound), zoom.visible.upperBound) }
    }

    private func x(_ t: Double) -> CGFloat? {
        proxy.position(forX: t).map { $0 + plot.minX }
    }

    /// A vertical band over `range`, clipped to the plot.
    @ViewBuilder
    private func band(_ range: ClosedRange<Double>, color: Color) -> some View {
        if let left = x(max(range.lowerBound, zoom.visible.lowerBound)), let right = x(min(range.upperBound, zoom.visible.upperBound)), right >= left {
            Rectangle()
                .fill(color)
                .frame(width: max(right - left, 1.5), height: plot.height)
                .offset(x: left, y: plot.minY)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard plot.contains(location), let t = time(atX: location.x) else {
                            clearHover()
                            return
                        }
                        hover.t = t
                        let flying = Set(detail.flights.inFlight(at: t))
                        if flying != hover.inFlight { hover.inFlight = flying }
                    case .ended:
                        clearHover()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            guard let from = time(atX: value.startLocation.x), let to = time(atX: value.location.x) else { return }
                            drag = (from, to)
                        }
                        .onEnded { _ in
                            if let drag, abs(drag.to - drag.from) > 0.5 {
                                zoom.show(min(drag.from, drag.to)...max(drag.from, drag.to))
                            }
                            drag = nil
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let base = magnifyBase ?? zoom
                            if magnifyBase == nil { magnifyBase = zoom }
                            var next = base
                            next.zoom(by: value.magnification, around: time(atX: value.startLocation.x) ?? (base.visible.lowerBound + base.visible.upperBound) / 2)
                            zoom = next
                        }
                        .onEnded { _ in magnifyBase = nil }
                )
                .onTapGesture(count: 2) { zoom.fit() }

            if let row = hover.row, detail.items.indices.contains(row), let start = detail.items[row].start {
                band(start...detail.items[row].end, color: Color.accentColor.opacity(0.18))
                    .allowsHitTesting(false)
            }
            if let drag {
                band(min(drag.from, drag.to)...max(drag.from, drag.to), color: Color.secondary.opacity(0.2))
                    .allowsHitTesting(false)
            }
            if let t = hover.t, let ruleX = x(t) {
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 1, height: plot.height)
                    .offset(x: ruleX, y: plot.minY)
                    .allowsHitTesting(false)
                JobHistoryHoverReadout(t: t, detail: detail, inFlight: hover.inFlight)
                    .frame(width: JobHistoryHoverReadout.width)
                    .offset(x: ruleX + 14 + JobHistoryHoverReadout.width > plot.maxX ? ruleX - 14 - JobHistoryHoverReadout.width : ruleX + 14, y: plot.minY + 4)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            plotWidth = plot.width
            scrollMonitor.install { event in scroll(event) }
        }
        .onDisappear { scrollMonitor.remove() }
        .onChange(of: plot.width) { _, width in plotWidth = width }
    }

    private func clearHover() {
        if hover.t != nil { hover.t = nil }
        if !hover.inFlight.isEmpty { hover.inFlight = [] }
    }

    /// Over the chart: vertical scroll zooms about the pointer, sideways
    /// scroll pans. Anywhere else the event goes on as usual.
    private func scroll(_ event: NSEvent) -> Bool {
        guard let anchor = hover.t else { return false }
        let scale: Double = event.hasPreciseScrollingDeltas ? 1 : 8
        let dx = Double(event.scrollingDeltaX) * scale
        let dy = Double(event.scrollingDeltaY) * scale
        if abs(dx) > abs(dy) {
            zoom.pan(by: -dx * zoom.span / max(Double(plot.width), 1))
        } else if dy != 0 {
            zoom.zoom(by: exp(dy * 0.01), around: anchor)
        }
        return true
    }
}

/// A scroll-wheel monitor for the chart — SwiftUI has no scroll-wheel
/// gesture on macOS. Installed while the chart is on screen; the handler
/// passes events through unless the pointer is over the plot.
@MainActor
final class JobHistoryScrollMonitor {
    private var monitor: Any?

    /// `handler` answers true when it used the event.
    func install(_ handler: @escaping @MainActor (NSEvent) -> Bool) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let used = MainActor.assumeIsolated { handler(event) }
            return used ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The hover readout: the exact time, every series' speed that second,
/// how busy the transfers were, and the files in flight.
private struct JobHistoryHoverReadout: View {
    static let width: CGFloat = 250
    let t: Double
    let detail: JobHistoryDetail
    let inFlight: Set<Int>

    var body: some View {
        let sample = JobHistoryAnalysis.nearestSample(detail.samples, to: t)
        let flying = inFlight.sorted().prefix(8).map { detail.items[$0] }
        VStack(alignment: .leading, spacing: 3) {
            Text(JobActivityDetail.durationText(t))
                .font(.caption.weight(.semibold).monospacedDigit())
            ForEach(detail.chart.series, id: \.self) { series in
                HStack(spacing: 5) {
                    Circle()
                        .fill(ThroughputChart.seriesColors[series] ?? .gray)
                        .frame(width: 6, height: 6)
                    Text(series)
                    Spacer(minLength: 6)
                    Text(sample?.value(ofSeries: series).map { detail.chart.unit == .megabytesPerSecond ? "\(JobThroughputFormat.rate($0)) MB/s" : "\(JobThroughputFormat.itemRate($0)) files/s" } ?? JobThroughputFormat.placeholder)
                        .monospacedDigit()
                }
                .font(.caption2)
            }
            if let sample {
                Text(machineLine(sample))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let estimate = estimateLine(sample) {
                    Text(estimate)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if !inFlight.isEmpty {
                Text("IN FLIGHT (\(inFlight.count))")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                ForEach(Array(flying.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 5) {
                        Text(item.fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(item.byteCount.formattedBytes)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2.monospaced())
                }
                if inFlight.count > flying.count {
                    Text("+\(inFlight.count - flying.count) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary, lineWidth: 1))
    }

    /// "Said ~10 m left · finished 8 m later"
    private func estimateLine(_ sample: JobHistorySample) -> String? {
        guard let remaining = sample.secondsRemaining else { return nil }
        return JobHistoryEstimateText.line(
            remaining: remaining,
            error: detail.job.endedAt == nil ? nil : sample.estimateError(actualDuration: detail.job.duration())
        )
    }

    /// "3 transfers busy · CPU 23% · GPU 4%"
    private func machineLine(_ sample: JobHistorySample) -> String {
        var parts: [String] = []
        if sample.activeTransfers > 0 { parts.append("\(sample.activeTransfers) transfer\(sample.activeTransfers == 1 ? "" : "s") busy") }
        if let cpu = sample.cpu { parts.append("CPU \(Int((cpu * 100).rounded()))%") }
        if let gpu = sample.gpu { parts.append("GPU \(Int((gpu * 100).rounded()))%") }
        return parts.isEmpty ? "at \(JobActivityDetail.durationText(sample.t))" : parts.joined(separator: " · ")
    }
}

/// The whole job in miniature under the chart, with the visible stretch
/// marked. Click or drag on it to move the view there.
private struct JobHistoryOverview: View {
    let chart: JobHistoryChartData
    @Binding var zoom: JobHistoryZoom

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let full = zoom.full
            let span = max(full.upperBound - full.lowerBound, 1)
            let primary = chart.series.first.flatMap { chart.points[$0] } ?? []
            let points = JobHistoryAnalysis.downsample(primary, in: full, buckets: max(Int(width / 2), 20))
            let tint = chart.series.first.flatMap { ThroughputChart.seriesColors[$0] } ?? .blue
            Canvas { context, size in
                guard points.count > 1 else { return }
                var line = Path()
                for (index, point) in points.enumerated() {
                    let location = CGPoint(
                        x: CGFloat((point.t - full.lowerBound) / span) * size.width,
                        y: size.height - CGFloat(min(point.value / chart.yUpper, 1)) * (size.height - 2) - 1
                    )
                    if index == 0 { line.move(to: location) } else { line.addLine(to: location) }
                }
                context.stroke(line, with: .color(tint.opacity(0.7)), lineWidth: 1)
                let left = CGFloat((zoom.visible.lowerBound - full.lowerBound) / span) * size.width
                let right = CGFloat((zoom.visible.upperBound - full.lowerBound) / span) * size.width
                let window = CGRect(x: left, y: 0, width: max(right - left, 2), height: size.height)
                context.fill(Path(roundedRect: window, cornerRadius: 3), with: .color(Color.accentColor.opacity(0.16)))
                context.stroke(Path(roundedRect: window, cornerRadius: 3), with: .color(Color.accentColor.opacity(0.7)), lineWidth: 1)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        zoom.center(on: full.lowerBound + Double(value.location.x / width) * span)
                    }
            )
            .help("The whole job. Click or drag to move the chart's view.")
        }
    }
}

// MARK: - Files

/// A file row, with plain sort keys.
struct JobHistoryFileRow: Identifiable, Hashable {
    let id: Int
    let item: JobHistoryItem

    var name: String { item.fileName }
    var size: Int64 { item.byteCount }
    var start: Double { item.start ?? item.end }
    var duration: Double { item.duration ?? 0 }
    var speed: Double { item.averageMegabytesPerSecond ?? 0 }
    var outcome: String { item.outcome.label }
}

enum JobHistoryFileFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case transferred = "Copied"
    case skipped = "Already There"
    case issues = "Issues"

    var id: String { rawValue }

    func includes(_ outcome: JobHistoryItemOutcome) -> Bool {
        switch self {
        case .all: true
        case .transferred: outcome == .copied
        case .skipped: outcome == .matched || outcome == .alreadyVerified
        case .issues: outcome == .conflict || outcome == .failed
        }
    }

    /// Rows of `items` this filter keeps, sorted.
    static func rows(_ items: [JobHistoryItem], filter: JobHistoryFileFilter, sortedBy order: [KeyPathComparator<JobHistoryFileRow>]) -> [JobHistoryFileRow] {
        items.indices.compactMap { filter.includes(items[$0].outcome) ? JobHistoryFileRow(id: $0, item: items[$0]) : nil }
            .sorted(using: order)
    }
}

/// Every file of the job. Hovering a row marks its span on the chart;
/// clicking one zooms the chart to it; the chart's pointer marks the rows
/// in flight.
private struct JobHistoryFileTable: View {
    let items: [JobHistoryItem]
    @Binding var zoom: JobHistoryZoom
    let hover: JobHistoryHover
    @State private var filter = JobHistoryFileFilter.all
    @State private var selection: JobHistoryFileRow.ID?
    @State private var sortOrder = [KeyPathComparator(\JobHistoryFileRow.start)]

    var body: some View {
        let rows = JobHistoryFileFilter.rows(items, filter: filter, sortedBy: sortOrder)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Files")
                    .font(.headline)
                Text("\(rows.count.formatted()) of \(items.count.formatted())")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("Show", selection: $filter) {
                    ForEach(JobHistoryFileFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if items.isEmpty {
                Text("This job recorded no per-file rows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { row in
                        JobHistoryCell(row: row, hover: hover) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(row.item.outcome.tint)
                                    .frame(width: 7, height: 7)
                                Text(row.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .width(min: 160, ideal: 260)
                    TableColumn("Size", value: \.size) { row in
                        JobHistoryCell(row: row, hover: hover) {
                            Text(row.size.formattedBytes).monospacedDigit()
                        }
                    }
                    .width(min: 60, ideal: 80)
                    TableColumn("Start", value: \.start) { row in
                        JobHistoryCell(row: row, hover: hover) {
                            Text(JobActivityDetail.durationText(row.start)).monospacedDigit()
                        }
                    }
                    .width(min: 56, ideal: 70)
                    TableColumn("Duration", value: \.duration) { row in
                        JobHistoryCell(row: row, hover: hover) {
                            Text(row.item.duration.map(JobHistoryText.seconds) ?? JobThroughputFormat.placeholder).monospacedDigit()
                        }
                    }
                    .width(min: 56, ideal: 72)
                    TableColumn("Speed", value: \.speed) { row in
                        JobHistoryCell(row: row, hover: hover) {
                            Text(row.item.averageMegabytesPerSecond.map { "\(JobThroughputFormat.rate($0)) MB/s" } ?? JobThroughputFormat.placeholder).monospacedDigit()
                        }
                    }
                    .width(min: 70, ideal: 86)
                    TableColumn("Outcome", value: \.outcome) { row in
                        JobHistoryCell(row: row, hover: hover) {
                            let method = row.item.verifyMethod.map { $0 == "ssh" ? " · SSH" : " · SMB" } ?? ""
                            Text("\(Text(row.outcome).foregroundStyle(row.item.outcome.tint))\(Text(method).foregroundStyle(.secondary))")
                        }
                    }
                    .width(min: 90, ideal: 130)
                }
                .font(.caption)
                .onChange(of: selection) { _, id in
                    guard let id, items.indices.contains(id), let start = items[id].start else { return }
                    zoom.show(start...items[id].end, padding: 0.6)
                }
            }
        }
    }
}

/// One table cell: reports the pointer to the chart, shows the file's
/// exact stats as its tooltip, and tints while the chart's pointer is
/// inside the file's time in flight.
private struct JobHistoryCell<Content: View>: View {
    let row: JobHistoryFileRow
    let hover: JobHistoryHover
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
            .background(hover.inFlight.contains(row.id) ? Color.accentColor.opacity(0.22) : Color.clear)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hover.row = row.id
                } else if hover.row == row.id {
                    hover.row = nil
                }
            }
            .help(JobHistoryText.item(row.item))
    }
}

/// How a recorded time-left estimate reads next to what really happened.
enum JobHistoryEstimateText {
    static func line(remaining: Double, error: Double?) -> String {
        let said = "Said ~\(JobActivityDetail.durationText(remaining.rounded())) left"
        guard let error else { return said }
        // Within a minute (or 5 %) of the real end counts as on time.
        if abs(error) < max(60, remaining * 0.05) { return said + " · on time" }
        let off = JobActivityDetail.durationText(abs(error).rounded())
        return said + (error > 0 ? " · finished \(off) sooner" : " · finished \(off) later")
    }
}
