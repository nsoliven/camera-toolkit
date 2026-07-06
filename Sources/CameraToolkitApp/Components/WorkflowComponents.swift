import CameraToolkitCore
import SwiftUI

struct TransferFlowPanel: View {
    var plan: CopyPlan
    var sourceURL: (FileRecord) -> URL? = { _ in nil }
    var openFile: ((FileRecord) -> Void)?
    var revealFile: ((FileRecord) -> Void)?

    var body: some View {
        Panel(
            title: "Copy Plan",
            symbol: "arrow.triangle.2.circlepath",
            helpTitle: "Copy Plan",
            helpText: "This is the dry-run view. New files can be copied, already archived files are skipped, and conflicts mean the same path exists with different bytes."
        ) {
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
                    CopyPlanFileRow(
                        file: file,
                        url: sourceURL(file),
                        openFile: openFile,
                        revealFile: revealFile
                    )
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

private struct CopyPlanFileRow: View {
    var file: FileRecord
    var url: URL?
    var openFile: ((FileRecord) -> Void)?
    var revealFile: ((FileRecord) -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.path.hasSuffix(".MP4") ? "video" : "photo")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(file.path)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            Text(file.size.formattedBytes)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)

            HStack(spacing: 6) {
                if let openFile {
                    PlanFileActionButton(
                        symbol: "eye",
                        help: "Open a protected working copy"
                    ) {
                        openFile(file)
                    }
                }

                if let revealFile {
                    PlanFileActionButton(
                        symbol: "folder",
                        help: "Reveal source file in Finder"
                    ) {
                        revealFile(file)
                    }
                }

                if let url {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("Share source file")
                    .accessibilityLabel("Share \(file.path)")
                }
            }
            .frame(width: actionClusterWidth, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var actionClusterWidth: CGFloat {
        var count = 0
        if openFile != nil { count += 1 }
        if revealFile != nil { count += 1 }
        if url != nil { count += 1 }
        return CGFloat(max(count, 1)) * 34
    }
}

private struct PlanFileActionButton: View {
    var symbol: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct WorkflowPlanPanel: View {
    var plan: WorkflowPlan?

    var body: some View {
        Panel(
            title: plan?.title ?? "Workflow Plan",
            symbol: "point.topleft.down.curvedto.point.bottomright.up",
            helpTitle: "Workflow Plan",
            helpText: "This shows the exact planned paths, commands, endpoints, and safety gates. Locked plans are not executed by the app."
        ) {
            if let plan {
                HStack(spacing: 12) {
                    MetricPill(title: "Status", value: plan.status.displayName, symbol: plan.status.symbol, tint: plan.status.tint)
                    MetricPill(title: "Steps", value: "\(plan.steps.count)", symbol: "list.bullet.rectangle", tint: AppTheme.accent)
                    MetricPill(title: "Writes", value: "\(plan.steps.filter(\.writesFiles).count)", symbol: "pencil.and.outline", tint: AppTheme.amber)
                }

                Text(plan.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.steps) { step in
                        WorkflowPlanStepRow(step: step)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Safety Gates")
                        .font(.headline)
                    ForEach(plan.gates) { gate in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: gate.isSatisfied ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(gate.isSatisfied ? AppTheme.mint : AppTheme.amber)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(gate.title)
                                    .font(.callout.weight(.semibold))
                                Text(gate.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                    }
                }
            } else {
                Text("No plan available yet. Open Config and refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WorkflowPlanStepRow: View {
    var step: WorkflowPlanStep

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(step.title, systemImage: step.writesFiles ? "pencil.and.outline" : "eye")
                    .font(.headline)
                Text(step.isExecutableNow ? "available now" : "locked")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(step.isExecutableNow ? AppTheme.mint : AppTheme.amber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((step.isExecutableNow ? AppTheme.mint : AppTheme.amber).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                Spacer()
            }

            Text(step.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            if let endpoint = step.endpoint {
                Text(endpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.accent)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            if let command = step.command, !command.isEmpty {
                Text(command.shellPreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
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

private extension WorkflowPlanStatus {
    var displayName: String {
        switch self {
        case .ready: "Ready"
        case .needsConfig: "Needs Config"
        case .locked: "Locked"
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle"
        case .needsConfig: "slider.horizontal.3"
        case .locked: "lock"
        }
    }

    var tint: Color {
        switch self {
        case .ready: AppTheme.mint
        case .needsConfig: AppTheme.amber
        case .locked: AppTheme.amber
        }
    }
}

private extension Array where Element == String {
    var shellPreview: String {
        map { value in
            if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: #""'\"#))) == nil {
                return value
            }
            return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        .joined(separator: " ")
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
        Panel(
            title: "Safety Test Result",
            symbol: "checklist.checked",
            helpTitle: "Safety Test Result",
            helpText: "This summarizes the last safety test. Copied files reached the test archive, quarantined files were proven safe to move out of the buffer, and left-alone files were not safe to remove."
        ) {
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

struct ActivityLogPanel: View {
    var entries: [ActivityLogEntry]

    var body: some View {
        Panel(
            title: "Permanent Activity Log",
            symbol: "clock.arrow.circlepath",
            helpTitle: "Permanent Activity Log",
            helpText: "This is saved on disk and survives app restarts. It records the actions you took in normal language, so you can answer: what did I do, when did it happen, and did it pass?"
        ) {
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No saved actions yet.")
                        .font(.headline)
                    Text("Run a safety test, preview a copy plan, or create test data and the app will append an entry here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
                    ForEach(entries.prefix(30)) { entry in
                        ActivityLogRow(entry: entry)
                        if entry.id != entries.prefix(30).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct ActivityLogRow: View {
    var entry: ActivityLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.title)
                        .font(.headline)
                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(entry.summary)
                    .font(.callout)
                Text(entry.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Text(entry.state.activityLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.vertical, 12)
    }

    private var icon: String {
        switch entry.state {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "minus.circle.fill"
        case .running: "clock.fill"
        case .queued: "circle.dashed"
        }
    }

    private var color: Color {
        switch entry.state {
        case .done: AppTheme.mint
        case .failed: .red
        case .cancelled: .secondary
        case .running: AppTheme.amber
        case .queued: .secondary
        }
    }
}

struct JobsStrip: View {
    var jobs: [JobSnapshot]

    var body: some View {
        Panel(
            title: "Current Session",
            symbol: "list.bullet.clipboard",
            helpTitle: "Current Session",
            helpText: "These rows are the live jobs from this app session. The permanent activity log above is the durable history that survives restarts."
        ) {
            if jobs.isEmpty {
                Text("No actions in this app session yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
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

extension JobState {
    var activityLabel: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .done: "Saved"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
