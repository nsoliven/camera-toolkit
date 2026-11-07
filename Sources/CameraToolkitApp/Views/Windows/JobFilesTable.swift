import CameraToolkitCore
import SwiftUI

/// The Jobs window's file list for a recorded job — every file it moved or
/// checked, filterable, sortable, tied to the speed graph by the pointer —
/// and the labels the window uses for how jobs and files ended.
struct JobHistoryOutcomeBadge: View {
    let display: JobOutcomeDisplay

    init(display: JobOutcomeDisplay) {
        self.display = display
    }

    init(outcome: JobHistoryOutcome) {
        display = JobDetailFacts.outcomeDisplay(outcome, job: nil)
    }

    var body: some View {
        Text(display.label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(display.tone.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(display.tone.color.quinary, in: Capsule())
    }
}

extension JobOutcomeDisplay.Tone {
    var color: Color {
        switch self {
        case .running: .blue
        case .success: .green
        case .warning: .orange
        case .failure: .red
        case .neutral: .secondary
        }
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
struct JobHistoryFileTable: View {
    let items: [JobHistoryItem]
    @Binding var zoom: JobHistoryZoom
    let hover: JobHistoryHover
    /// Shared with the issue section, which can jump here to Issues.
    @Binding var filter: JobHistoryFileFilter
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
