import CameraToolkitCore
import Charts
import SwiftUI

/// The Jobs window's speed graph over a job's whole run, running or ended:
/// one rate (MB/s, or files/s for jobs that only count files) as a line
/// over a soft area, its average as a dashed rule and its peak as a dot,
/// with what the job was doing (Check, Copy, Verify) in lanes underneath.
/// Gaps in the recording stay gaps. Drag across to zoom in, double-click
/// to fit. A job too short to chart, or one that copied nothing, gets a
/// sentence instead.
struct JobSpeedGraphView: View {
    let graph: JobSpeedGraph
    let samples: [JobHistorySample]
    let kind: String
    let isLive: Bool
    @Binding var zoom: JobHistoryZoom
    let hover: JobHistoryHover
    var flights: JobHistoryFlightIndex?
    var items: [JobHistoryItem] = []

    static let height: CGFloat = 170

    /// "2.5", "50", "1,200" — the y-axis labels.
    static func axisNumber(_ value: Double) -> String {
        value >= 10 || value == 0 ? Int(value.rounded()).formatted() : String(format: "%.1f", value)
    }

    var body: some View {
        if let sentence = JobDetailFacts.graphSummary(graph, kind: kind, isLive: isLive) {
            JobSpeedGraphSummary(text: sentence, graph: graph, isLive: isLive)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if !zoom.isFit {
                    HStack(spacing: 8) {
                        Text(JobHistoryText.range(zoom))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Show Whole Job") { zoom.fit() }
                            .controlSize(.small)
                    }
                }
                JobSpeedPlot(graph: graph, samples: samples, kind: kind, zoom: $zoom, hover: hover, flights: flights, items: items)
            }
        }
    }
}

/// The sentence a short or empty job shows in the graph's place — compact,
/// so the card does not look like a chart that failed to load.
private struct JobSpeedGraphSummary: View {
    let text: String
    let graph: JobSpeedGraph
    let isLive: Bool

    private var symbol: String {
        switch graph.summary {
        case .nothingMoved: "checkmark.circle"
        case .tooShort: isLive ? "gauge.with.dots.needle.33percent" : "bolt"
        default: "chart.line.flattrend.xyaxis"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// One drawn column of one segment.
private struct JobSpeedMark: Identifiable {
    var id: Int
    var segment: Int
    var t: Double
    var mean: Double
    var low: Double
    var high: Double
}

/// The chart itself and the phase lanes under it, sharing the plot's
/// horizontal frame so a lane lines up with the line above it.
private struct JobSpeedPlot: View {
    let graph: JobSpeedGraph
    let samples: [JobHistorySample]
    let kind: String
    @Binding var zoom: JobHistoryZoom
    let hover: JobHistoryHover
    let flights: JobHistoryFlightIndex?
    let items: [JobHistoryItem]
    /// The plot's frame inside the chart, and the chart's width — read
    /// from the chart so the lanes under it line up with its x-axis.
    @State private var plot = CGRect(x: 40, y: 0, width: 300, height: JobSpeedGraphView.height)
    @State private var chartWidth: CGFloat = 340

    static let tint = Color.blue

    var body: some View {
        let visible = zoom.visible
        let columns = graph.visibleBuckets(in: visible, buckets: max(Int(plot.width / 3), 60))
        var marks: [JobSpeedMark] = []
        for (segment, buckets) in columns.enumerated() {
            for bucket in buckets {
                marks.append(JobSpeedMark(id: marks.count, segment: segment, t: bucket.t, mean: bucket.mean, low: bucket.low, high: bucket.high))
            }
        }
        let showsRange = marks.contains { $0.high > $0.low }
        let unit = Self.unit(graph.metric, kind: kind)
        return VStack(alignment: .leading, spacing: 6) {
            Text(unit)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Chart {
                ForEach(marks) { mark in
                    if showsRange {
                        AreaMark(
                            x: .value("Elapsed", mark.t),
                            yStart: .value("Low", mark.low),
                            yEnd: .value("High", mark.high),
                            series: .value("Range", "range-\(mark.segment)")
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Self.tint.opacity(0.14))
                    }
                    AreaMark(
                        x: .value("Elapsed", mark.t),
                        yStart: .value("Zero", 0),
                        yEnd: .value(unit, mark.mean),
                        series: .value("Area", "area-\(mark.segment)")
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(colors: [Self.tint.opacity(0.22), Self.tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(
                        x: .value("Elapsed", mark.t),
                        y: .value(unit, mark.mean),
                        series: .value("Line", "line-\(mark.segment)")
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Self.tint)
                }
                if let average = graph.average {
                    RuleMark(y: .value("Average", average))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color.secondary)
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            Text("avg \(Self.format(average, unit: unit))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                }
                if let peak = graph.peak, visible.contains(peak.t) {
                    // A burst far above the run sits on the top edge,
                    // labelled with its real value.
                    PointMark(x: .value("Elapsed", peak.t), y: .value(unit, min(peak.value, graph.yUpper)))
                        .symbolSize(28)
                        .symbol(graph.peakIsOffScale ? .triangle : .circle)
                        .foregroundStyle(Self.tint)
                        .annotation(position: graph.peakIsOffScale ? .bottom : .top, alignment: .center, spacing: 3, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .chart))) {
                            Text("peak \(Self.format(peak.value, unit: unit))\(graph.peakIsOffScale ? " · off scale" : "")")
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(Self.tint)
                        }
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: visible)
            .chartYScale(domain: 0...graph.yUpper)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(JobSpeedGraphView.axisNumber(number))
                                .monospacedDigit()
                        }
                    }
                }
            }
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
                    let frame = proxy.plotFrame.map { geometry[$0] } ?? CGRect(origin: .zero, size: geometry.size)
                    JobSpeedInteraction(proxy: proxy, plot: frame, graph: graph, samples: samples, kind: kind, zoom: $zoom, hover: hover, flights: flights, items: items)
                        .onAppear {
                            plot = frame
                            chartWidth = geometry.size.width
                        }
                        .onChange(of: frame) { _, newFrame in plot = newFrame }
                        .onChange(of: geometry.size.width) { _, width in chartWidth = width }
                }
            }
            .frame(height: JobSpeedGraphView.height)
            .transaction { $0.animation = nil }
            .accessibilityLabel("Speed over the whole job in \(unit)")

            if graph.showsPhases {
                JobPhaseLanes(graph: graph, visible: visible, leading: plot.minX, trailing: max(chartWidth - plot.maxX, 0))
            }
        }
    }

    static func unit(_ metric: JobSpeedGraph.Metric?, kind: String) -> String {
        switch metric {
        case .filesPerSecond: JobDetailFacts.filesUnit(kind)
        case .megabytesPerSecond: "MB/s"
        case nil: ""
        }
    }

    static func format(_ value: Double, unit: String) -> String {
        unit == "MB/s" ? "\(JobThroughputFormat.rate(value)) MB/s" : "\(JobThroughputFormat.itemRate(value)) \(unit)"
    }
}

/// What the job was doing when — one thin lane per phase under the plot,
/// labelled in the y-axis gutter.
private struct JobPhaseLanes: View {
    let graph: JobSpeedGraph
    let visible: ClosedRange<Double>
    /// The y-axis gutter left of the plot, where the labels go.
    let leading: CGFloat
    /// Space right of the plot.
    let trailing: CGFloat

    var body: some View {
        let kinds = JobSpeedGraph.Phase.allCases.filter { phase in graph.phases.contains { $0.phase == phase } }
        let span = max(visible.upperBound - visible.lowerBound, .leastNonzeroMagnitude)
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(kinds, id: \.self) { phase in
                HStack(spacing: 0) {
                    Text(phase.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(width: max(leading - 6, 0), alignment: .trailing)
                        .padding(.trailing, 6)
                    Canvas { context, size in
                        let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                        context.fill(track, with: .color(.secondary.opacity(0.08)))
                        for piece in graph.phases where piece.phase == phase && piece.end >= visible.lowerBound && piece.start <= visible.upperBound {
                            let left = CGFloat((max(piece.start, visible.lowerBound) - visible.lowerBound) / span) * size.width
                            let right = CGFloat((min(piece.end, visible.upperBound) - visible.lowerBound) / span) * size.width
                            let rect = CGRect(x: left, y: 0, width: max(right - left, 2), height: size.height)
                            context.fill(Path(roundedRect: rect, cornerRadius: size.height / 2), with: .color(PhaseBreakdown.color(phase.breakdownLabel)))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 6)
                    Color.clear.frame(width: trailing, height: 1)
                }
                .help("\(phase.label): \(JobActivityDetail.durationText(graph.phases.filter { $0.phase == phase }.reduce(0) { $0 + $1.end - $1.start })) in all")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Phases: " + kinds.map(\.label).joined(separator: ", "))
    }
}

extension JobSpeedGraph.Phase {
    /// The label `PhaseBreakdown` colours by, so a lane and the busy-time
    /// bar agree.
    var breakdownLabel: String {
        switch self {
        case .check: "Check"
        case .hash: "Hash"
        case .copy: "Copy"
        case .verify: "Verify"
        }
    }
}

/// The pointer on the chart: a rule and a card with that moment's numbers,
/// a dragged range to zoom into, double-click to fit.
private struct JobSpeedInteraction: View {
    let proxy: ChartProxy
    let plot: CGRect
    let graph: JobSpeedGraph
    let samples: [JobHistorySample]
    let kind: String
    @Binding var zoom: JobHistoryZoom
    let hover: JobHistoryHover
    let flights: JobHistoryFlightIndex?
    let items: [JobHistoryItem]
    @State private var drag: (from: Double, to: Double)?

    private func time(atX x: CGFloat) -> Double? {
        proxy.value(atX: x - plot.minX, as: Double.self).map { min(max($0, zoom.visible.lowerBound), zoom.visible.upperBound) }
    }

    private func x(_ t: Double) -> CGFloat? {
        proxy.position(forX: t).map { $0 + plot.minX }
    }

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
                        let flying = Set(flights?.inFlight(at: t) ?? [])
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
                .onTapGesture(count: 2) { zoom.fit() }

            if let row = hover.row, items.indices.contains(row), let start = items[row].start {
                band(start...items[row].end, color: Color.accentColor.opacity(0.18))
                    .allowsHitTesting(false)
            }
            if let drag {
                band(min(drag.from, drag.to)...max(drag.from, drag.to), color: Color.secondary.opacity(0.2))
                    .allowsHitTesting(false)
            }
            if let t = hover.t, let ruleX = x(t) {
                Rectangle()
                    .fill(Color.primary.opacity(0.45))
                    .frame(width: 1, height: plot.height)
                    .offset(x: ruleX, y: plot.minY)
                    .allowsHitTesting(false)
                let width = JobSpeedHoverCard.width
                JobSpeedHoverCard(
                    lines: JobDetailFacts.hoverLines(
                        sample: JobSpeedGraph.sample(near: t, in: samples, within: graph.gapThreshold),
                        t: t, graph: graph, kind: kind
                    ),
                    inFlight: hover.inFlight.count
                )
                .frame(width: width)
                .offset(x: ruleX + 12 + width > plot.maxX ? ruleX - 12 - width : ruleX + 12, y: plot.minY + 2)
                .allowsHitTesting(false)
            }
        }
    }

    private func clearHover() {
        if hover.t != nil { hover.t = nil }
        if !hover.inFlight.isEmpty { hover.inFlight = [] }
    }
}

/// The hover card: the moment, then label–value rows.
private struct JobSpeedHoverCard: View {
    static let width: CGFloat = 196
    let lines: (title: String, rows: [(label: String, value: String)])
    let inFlight: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(lines.title)
                .font(.caption.weight(.semibold).monospacedDigit())
            ForEach(Array(lines.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    if !row.label.isEmpty {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(row.value)
                        .monospacedDigit()
                }
                .font(.caption2)
            }
            if inFlight > 0 {
                Text("\(inFlight) file\(inFlight == 1 ? "" : "s") in flight — marked in the list")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary, lineWidth: 1))
    }
}
