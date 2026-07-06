import CameraToolkitCore
import SwiftUI

struct TransferFlowPanel: View {
    var plan: CopyPlan

    var body: some View {
        Panel(title: "Current Plan", symbol: "arrow.triangle.2.circlepath") {
            HStack(spacing: 12) {
                FlowNode(title: "Card", symbol: "sdcard", tint: AppTheme.accent)
                FlowArrow(label: "copy")
                FlowNode(title: "Archive", symbol: "server.rack", tint: AppTheme.mint)
                FlowArrow(label: "verify")
                FlowNode(title: "Manifest", symbol: "checkmark.seal", tint: .purple)
            }
            .padding(.vertical, 4)

            HStack(spacing: 12) {
                MetricPill(title: "New files", value: "\(plan.new.count)", symbol: "plus.circle", tint: AppTheme.mint)
                MetricPill(title: "Already there", value: "\(plan.existing.count)", symbol: "checkmark.circle", tint: AppTheme.accent)
                MetricPill(title: "Conflicts", value: "\(plan.conflicts.count)", symbol: "exclamationmark.triangle", tint: AppTheme.amber)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.new.prefix(5)) { file in
                    HStack {
                        Image(systemName: file.path.hasSuffix(".MP4") ? "video" : "photo")
                            .foregroundStyle(.secondary)
                        Text(file.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                        Spacer()
                        Text(file.size.formattedBytes)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if plan.new.isEmpty {
                    Text("No new files in the current plan.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct FlowNode: View {
    var title: String
    var symbol: String
    var tint: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 52, height: 46)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity)
    }
}

struct FlowArrow: View {
    var label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 46)
    }
}

struct SimulationSummaryPanel: View {
    var summary: SimulationSummary?
    var statusMessage: String

    var body: some View {
        Panel(title: "Simulation Result", symbol: "checklist.checked") {
            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                MetricPill(title: "Copied", value: "\(summary?.copiedCount ?? 0)", symbol: "doc.on.doc", tint: AppTheme.accent)
                MetricPill(title: "Quarantined", value: "\(summary?.quarantinedCount ?? 0)", symbol: "archivebox", tint: AppTheme.mint)
                MetricPill(title: "Left unsafe", value: "\(summary?.leftUnsafeCount ?? 0)", symbol: "exclamationmark.triangle", tint: AppTheme.amber)
            }

            if let summary {
                VStack(alignment: .leading, spacing: 6) {
                    PathRow(title: "Root", path: summary.root)
                    PathRow(title: "Source", path: summary.sourcePath)
                    PathRow(title: "Archive", path: summary.archivePath)
                    PathRow(title: "Buffer", path: summary.bufferPath)
                }
            }
        }
    }
}

private struct PathRow: View {
    var title: String
    var path: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct JobsStrip: View {
    var jobs: [JobSnapshot]

    var body: some View {
        Panel(title: "Recent Jobs", symbol: "list.bullet.clipboard") {
            ForEach(jobs.prefix(5)) { job in
                HStack(spacing: 12) {
                    Circle()
                        .fill(color(for: job.state))
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.action.displayName)
                            .font(.headline)
                        Text(job.note)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProgressView(value: job.progress)
                        .frame(width: 180)
                    Text("\(Int(job.progress * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    private func color(for state: JobState) -> Color {
        switch state {
        case .queued: .secondary
        case .running: AppTheme.amber
        case .done: AppTheme.mint
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}
