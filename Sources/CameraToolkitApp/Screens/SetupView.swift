import CameraToolkitCore
import SwiftUI

struct SetupView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Setup",
                title: "Camera Library setup",
                subtitle: "Choose the camera workflow and confirm where originals will live."
            )

            Panel(
                title: "Current Setup",
                symbol: "checklist",
                helpTitle: "Current Setup",
                helpText: "This is the small set of choices the app needs before it should move real files: photo library, from folder, buffer drive, photo list file, and backup folder."
            ) {
                VStack(spacing: 0) {
                    ForEach(model.setupChecklist) { item in
                        SetupStatusTile(item: item)
                        if item.id != model.setupChecklist.last?.id {
                            Divider()
                        }
                    }
                }

                CommandBar {
                    HelpedCommandButton(
                        title: "Use Mounted Drives",
                        symbol: "sparkles",
                        prominence: .primary,
                        isDisabled: model.isBusy,
                        helpTitle: "Use Mounted Drives",
                        helpText: "Fills setup from the mounted photo library folder, Action Camera, Camera Card, and Photo Workspace if they are present. No files are moved.",
                        action: model.applyRecommendedCameraSetup
                    )

                    HelpedCommandButton(
                        title: "Choose Library",
                        symbol: "folder.badge.gearshape",
                        isDisabled: model.isBusy,
                        helpTitle: "Choose Library",
                        helpText: "Pick the Camera folder on the NAS. The app sets up Inbox, Originals, Edited, Selects, Shared, and proof files from it.",
                        action: model.chooseCameraLibraryRoot
                    )

                    HelpedCommandButton(
                        title: "Prepare Photo List",
                        symbol: "cylinder.split.1x2",
                        isDisabled: model.isBusy,
                        helpTitle: "Prepare Photo List",
                        helpText: "Creates missing library folders, creates or updates the local photo list, and writes a timestamped backup.",
                        action: model.prepareLibraryCatalog
                    )
                }
            }

            Panel(
                title: "Camera Import",
                symbol: "camera",
                helpTitle: "Camera Import",
                helpText: "Choose the camera you plugged in. This selects the complete card as the source and the established Photo Workspace Camera Buffer as the destination. Nothing moves until you preview and copy."
            ) {
                Text("These are complete ingest workflows, not independent drive presets.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(model.setupPresets) { preset in
                        SetupPresetRow(preset: preset) {
                            model.applySetupPreset(preset)
                        }
                        if preset.id != model.setupPresets.last?.id {
                            Divider()
                        }
                    }
                }
            }

            Panel(
                title: "Folder Map",
                symbol: "folder",
                helpTitle: "Folder Map",
                helpText: "The Camera Library root owns these standard folders. Photos stay on disk; the local photo list tracks where files live."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.cameraLibraryFolderRows) { row in
                        SetupPathRow(row: row)
                    }
                    Divider()
                    SetupPathRow(row: SetupPathStatus(
                        title: "Photo list",
                        path: model.configuration.catalogDatabasePath,
                        exists: model.catalogDatabaseExists,
                        symbol: "cylinder"
                    ))
                    SetupPathRow(row: SetupPathStatus(
                        title: "Photo list backups",
                        path: model.configuration.catalogBackupFolderPath,
                        exists: model.catalogBackupFolderExists,
                        symbol: "externaldrive.badge.checkmark"
                    ))
                }

                Text(model.catalogMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SetupPresetRow: View {
    var preset: CameraSetupPreset
    var apply: () -> Void

    private var statusText: String {
        if preset.isApplied { return "Selected" }
        return preset.isAvailable ? "Connected" : "Not mounted"
    }

    private var statusColor: Color {
        if preset.isApplied { return AppTheme.accent }
        return preset.isAvailable ? AppTheme.mint : AppTheme.amber
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: preset.symbol)
                .font(.title3)
                .foregroundStyle(statusColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.title)
                            .font(.headline)
                        Text(preset.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }

                Text(preset.effect)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if let sourcePath = preset.sourcePath, let bufferPath = preset.bufferPath {
                    HStack(spacing: 8) {
                        Text(sourcePath)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                        Text(bufferPath)
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }

                HStack {
                    if preset.isApplied {
                        Label("Selected for next import", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(AppTheme.mint)
                    } else {
                        Button("Use for Next Import", systemImage: "arrow.right.circle", action: apply)
                            .buttonStyle(.borderedProminent)
                    }

                    if !preset.isAvailable {
                        Label("Connect the missing drive before previewing", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(AppTheme.amber)
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }
}

private struct SetupStatusTile: View {
    var item: SetupChecklistItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(item.isReady ? AppTheme.mint : AppTheme.amber)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

private struct SetupPathRow: View {
    var row: SetupPathStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: row.symbol)
                .foregroundStyle(row.exists ? AppTheme.mint : AppTheme.amber)
                .frame(width: 22)
            Text(row.title)
                .font(.callout.weight(.semibold))
                .frame(width: 112, alignment: .leading)
            Text(row.path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(row.exists ? "Ready" : "Missing")
                .font(.caption.weight(.semibold))
                .foregroundStyle(row.exists ? AppTheme.mint : AppTheme.amber)
        }
    }
}
