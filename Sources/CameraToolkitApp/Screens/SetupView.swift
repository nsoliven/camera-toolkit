import CameraToolkitCore
import SwiftUI

struct SetupView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Setup",
                title: "Camera Library setup",
                subtitle: "Pick the photo library, from folders, buffer, and photo list once. Real copy/delete buttons stay locked until the app has enough proof."
            )

            Panel(
                title: "Current Setup",
                symbol: "checklist",
                helpTitle: "Current Setup",
                helpText: "This is the small set of choices the app needs before it should move real files: photo library, from folder, buffer drive, photo list file, and backup folder."
            ) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(model.setupChecklist) { item in
                        SetupStatusTile(item: item)
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
                title: "My Presets",
                symbol: "rectangle.3.group",
                helpTitle: "My Presets",
                helpText: "A preset only selects saved folders and the camera label. It never starts a copy, deletes a file, or unlocks NAS and Immich writes."
            ) {
                Text("Pick the setup that matches what you plugged in. The card shows every setting it changes before you apply it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(model.setupPresets) { preset in
                        SetupPresetCard(preset: preset) {
                            model.applySetupPreset(preset)
                        }
                    }
                }
            }

            Panel(
                title: "Main Buttons",
                symbol: "point.3.connected.trianglepath.dotted",
                helpTitle: "Buttons",
                helpText: "The real movement buttons remain locked until the app has enough photo-list and proof-file evidence to avoid losing files."
            ) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], alignment: .leading, spacing: 12) {
                    SetupActionTile(
                        title: "Preview Copy",
                        symbol: "eye",
                        status: "Reads only",
                        detail: "Reads the from folder and buffer. Moves nothing.",
                        tint: AppTheme.mint
                    )
                    SetupActionTile(
                        title: "Copy to Buffer",
                        symbol: "square.and.arrow.down",
                        status: "Copy only",
                        detail: "Copies new files into the buffer. No delete, no overwrite.",
                        tint: AppTheme.mint
                    )
                    SetupActionTile(
                        title: "Check + Proof File",
                        symbol: "checkmark.shield",
                        status: "Prepare list first",
                        detail: "Will save proof in the library.",
                        tint: AppTheme.accent
                    )
                    SetupActionTile(
                        title: "Clear Buffer Space",
                        symbol: "externaldrive.badge.minus",
                        status: "Locked",
                        detail: "Will move aside only files already proven in the library.",
                        tint: AppTheme.amber
                    )
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

private struct SetupPresetCard: View {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: preset.symbol)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                    .frame(width: 36, height: 36)
                    .background(statusColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
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

            VStack(alignment: .leading, spacing: 6) {
                if let sourcePath = preset.sourcePath {
                    PresetSettingRow(label: "From", value: sourcePath)
                }
                if let bufferPath = preset.bufferPath {
                    PresetSettingRow(label: "Buffer", value: bufferPath)
                }
                if let libraryRootPath = preset.libraryRootPath {
                    PresetSettingRow(label: "Library", value: libraryRootPath)
                }
                if let deviceID = preset.deviceID {
                    PresetSettingRow(label: "Camera", value: deviceID)
                }
            }

            Button(action: apply) {
                Label(preset.isApplied ? "Preset Selected" : "Use This Preset", systemImage: preset.isApplied ? "checkmark.circle.fill" : "slider.horizontal.3")
            }
            .buttonStyle(.borderedProminent)
            .disabled(preset.isApplied)
            .help(preset.isAvailable ? "Select these settings. No files will move." : "Save these settings now; connect the missing drive before previewing or copying.")

            if !preset.isAvailable {
                Label("You can save this preset now, but connect the missing drive before Preview Files.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.amber)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 270, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(statusColor.opacity(preset.isApplied ? 0.5 : 0.18))
        }
    }
}

private struct PresetSettingRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
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
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SetupActionTile: View {
    var title: String
    var symbol: String
    var status: String
    var detail: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.headline)
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
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
