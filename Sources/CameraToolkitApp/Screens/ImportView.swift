import CameraToolkitCore
import SwiftUI

struct ImportView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Import",
                title: "Move camera files",
                subtitle: "Use the buffer when you want a working copy. Use the photo library or NAS when you want long-term storage."
            )

            SimpleCameraFlowPanel(model: model, showsActions: false, showsFolderChoices: true, showsMoves: false, showsPaths: false)
            QueueFileViewerPanel(model: model)
            JobsStrip(jobs: model.jobs)

            Panel(
                title: "Folders for This Copy",
                symbol: "square.and.arrow.down",
                helpTitle: "Current Batch Folders",
                helpText: "These are the exact folders for the selected from folder, camera, and trip. The buffer folders are used first; the library folders are used later."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ConfigSummaryRow(title: "From", value: model.configuration.importSourcePath)
                    ConfigSummaryRow(title: "Buffer Copies", value: model.expandedBufferIngestPath)
                    ConfigSummaryRow(title: "Edited Exports", value: model.expandedBufferExportsPath)
                    ConfigSummaryRow(title: "Edit Side Files", value: model.expandedBufferEditsPath)
                    ConfigSummaryRow(title: "PC Work", value: model.expandedEditorWorkingFolderPath)
                    ConfigSummaryRow(title: "Library Originals", value: model.expandedLibraryOriginalsPath)
                    ConfigSummaryRow(title: "Library Edits", value: model.expandedLibraryEditedPath)
                    ConfigSummaryRow(title: "Photo List", value: model.configuration.catalogDatabasePath)
                    ConfigSummaryRow(title: "Camera", value: model.configuration.selectedDeviceID)
                    ConfigSummaryRow(title: "Trip", value: model.configuration.eventName)
                }
            }
        }
    }
}

private struct QueueFileViewerPanel: View {
    @Bindable var model: DashboardModel

    var body: some View {
        Panel(
            title: "File Queue",
            symbol: "tray.and.arrow.down",
            helpTitle: "File Queue",
            helpText: "Preview fills this list with files that are not in the buffer yet. Check the files you want, then copy the queue to the buffer."
        ) {
            HStack(spacing: 12) {
                MetricPill(title: "Queued", value: model.queueSummary, symbol: "checklist.checked", tint: AppTheme.mint)
                MetricPill(title: "New", value: "\(model.activePlan.new.count)", symbol: "plus.circle", tint: AppTheme.accent)
                MetricPill(title: "Already In Buffer", value: "\(model.activePlan.existing.count)", symbol: "checkmark.circle", tint: .secondary)
                MetricPill(title: "Needs Review", value: "\(model.activePlan.conflicts.count)", symbol: "exclamationmark.triangle", tint: AppTheme.amber)
            }

            NextStepCallout(step: nextStep)

            CommandBar {
                HelpedCommandButton(
                    title: "Preview Files",
                    symbol: "eye",
                    prominence: .primary,
                    isDisabled: model.isBusy,
                    helpTitle: "Preview Files",
                    helpText: "Scan the from folder, compare it to the buffer, and queue new files. Nothing is copied yet.",
                    action: model.previewImport
                )

                HelpedCommandButton(
                    title: model.activePlan.new.isEmpty ? "Add All New" : "Queue All \(model.activePlan.new.count)",
                    symbol: "checklist.checked",
                    isDisabled: model.isBusy || model.activePlan.new.isEmpty,
                    helpTitle: "Queue All New",
                    helpText: "Put every new file from the preview into the queue.",
                    action: model.queueAllNewFiles
                )

                HelpedCommandButton(
                    title: "Clear Queue",
                    symbol: "xmark.circle",
                    isDisabled: model.isBusy || model.queuedFiles.isEmpty,
                    helpTitle: "Clear Queue",
                    helpText: "Remove every file from the queue. No files on disk are changed.",
                    action: model.clearQueue
                )

                HelpedCommandButton(
                    title: model.queuedFiles.isEmpty ? "Copy Queue to Buffer" : "Copy \(model.queuedFiles.count) to Buffer",
                    symbol: "externaldrive.badge.plus",
                    isDisabled: model.isBusy || model.queuedFiles.isEmpty,
                    helpTitle: "Copy Queue to Buffer",
                    helpText: "Copy only queued files into the buffer. Nothing is deleted or overwritten.",
                    action: model.copyQueuedFilesToBuffer
                )
            }

            if model.activePlan.new.isEmpty {
                QueueEmptyState()
            } else {
                VStack(spacing: 0) {
                    ForEach(model.activePlan.new.prefix(300)) { file in
                        QueueFileRow(
                            file: file,
                            isQueued: model.isQueued(file),
                            canOpenSource: model.planFileSourceURL(file) != nil,
                            toggle: { model.toggleQueuedFile(file) },
                            open: { model.openPlanFile(file) },
                            reveal: { model.revealPlanFileInFinder(file) }
                        )
                        if file.id != model.activePlan.new.prefix(300).last?.id {
                            Divider()
                        }
                    }

                    if model.activePlan.new.count > 300 {
                        Text("Showing first 300 new files. Copy still uses the queue, not this display limit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var nextStep: NextStep {
        if model.isBusy {
            return NextStep(
                title: "Wait for the current action",
                detail: "The progress row below is still running. When it finishes, choose files and copy the queue.",
                symbol: "hourglass",
                tint: AppTheme.amber
            )
        }

        if model.activePlan.new.isEmpty {
            return NextStep(
                title: "Next: Preview files",
                detail: "Click Preview Files to scan the from folder and show files that are not in the buffer yet.",
                symbol: "eye",
                tint: AppTheme.accent
            )
        }

        if model.queuedFiles.isEmpty {
            return NextStep(
                title: "Next: Put files in the queue",
                detail: "Click Queue All \(model.activePlan.new.count), or check individual files below. Copy stays disabled until something is queued.",
                symbol: "checklist.checked",
                tint: AppTheme.mint
            )
        }

        return NextStep(
            title: "Next: Copy the queue",
            detail: "Click Copy \(model.queuedFiles.count) to Buffer. It copies only queued files and does not delete or overwrite originals.",
            symbol: "externaldrive.badge.plus",
            tint: AppTheme.mint
        )
    }
}

private struct NextStep {
    var title: String
    var detail: String
    var symbol: String
    var tint: Color
}

private struct NextStepCallout: View {
    var step: NextStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: step.symbol)
                .font(.headline)
                .foregroundStyle(step.tint)
                .frame(width: 34, height: 34)
                .background(step.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.headline)
                Text(step.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(12)
        .background(step.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(step.tint.opacity(0.22))
        )
    }
}

private struct QueueEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview files to fill the queue.")
                .font(.headline)
            Text("Choose your from folder and buffer above, then click Preview Files. New files will appear here with checkboxes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct QueueFileRow: View {
    var file: FileRecord
    var isQueued: Bool
    var canOpenSource: Bool
    var toggle: () -> Void
    var open: () -> Void
    var reveal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: isQueued ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isQueued ? AppTheme.mint : .secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isQueued ? "Remove from queue" : "Add to queue")

            Image(systemName: file.path.hasSuffix(".MP4") ? "video" : "photo")
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.path)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isQueued ? "Queued for buffer" : "Not queued")
                    .font(.caption)
                    .foregroundStyle(isQueued ? AppTheme.mint : .secondary)
            }

            Spacer(minLength: 12)

            Text(file.size.formattedBytes)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 84, alignment: .trailing)

            HStack(spacing: 6) {
                Button(action: open) {
                    Image(systemName: "eye")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(!canOpenSource)
                .help(canOpenSource ? "Open an edit copy" : "From folder is not mounted")

                Button(action: reveal) {
                    Image(systemName: "folder")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(!canOpenSource)
                .help(canOpenSource ? "Reveal original in Finder" : "From folder is not mounted")
            }
        }
        .padding(.vertical, 9)
    }
}

private struct ConfigSummaryRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}
