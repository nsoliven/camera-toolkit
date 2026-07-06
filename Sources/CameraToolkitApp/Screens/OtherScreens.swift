import CameraToolkitCore
import SwiftUI

struct LibraryView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Library",
                title: "Open photos like a Mac app",
                subtitle: "Browse the configured source folder, then click a photo to open a protected working copy in Preview by default."
            )

            Panel(
                title: "Photo Source",
                symbol: "photo.stack",
                helpTitle: "Photo Source",
                helpText: "This scans the Import Source from Config. Clicking a photo copies it into the Editor Working Copies folder before opening it, so the original source file is not modified by an editor."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    DetailLine(title: "Source", value: model.configuration.importSourcePath)
                    DetailLine(title: "Opens With", value: model.configuration.externalEditor.displayName)
                    DetailLine(title: "Working Copies", value: model.configuration.editorWorkingFolderPath)
                    if let lastOpenedWorkingCopyPath = model.lastOpenedWorkingCopyPath {
                        DetailLine(title: "Last Opened", value: lastOpenedWorkingCopyPath)
                    }
                }

                CommandBar {
                    HelpedCommandButton(
                        title: "Choose Source",
                        symbol: "folder",
                        isDisabled: model.isBusy,
                        helpTitle: "Choose Source",
                        helpText: "Pick the folder the Library tab scans for supported photo files.",
                        action: model.chooseImportFolder
                    )

                    HelpedCommandButton(
                        title: "Refresh",
                        symbol: "arrow.clockwise",
                        prominence: .primary,
                        isDisabled: model.isBusy,
                        helpTitle: "Refresh",
                        helpText: "Rescans the configured source folder and lists supported photo files.",
                        action: model.refreshLibraryFiles
                    )

                    HelpedCommandButton(
                        title: "Edit Config",
                        symbol: "slider.horizontal.3",
                        isDisabled: model.isBusy,
                        helpTitle: "Edit Config",
                        helpText: "Open Config to change the default editor, working-copy folder, or source path.",
                        action: { model.selectedSection = .config }
                    )
                }
            }

            WorkflowPlanPanel(plan: model.workflowPlan(.editorCheckout))

            Panel(
                title: "Photos",
                symbol: "photo.on.rectangle.angled",
                helpTitle: "Photos",
                helpText: "Single-clicking a row opens a working copy in the configured editor. Preview is the default editor, and real archive/source originals stay untouched."
            ) {
                if model.libraryFiles.isEmpty {
                    EmptyLibraryState(refresh: model.refreshLibraryFiles)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.libraryFiles.prefix(80)) { file in
                            PhotoFileRow(file: file, editorName: model.configuration.externalEditor.displayName) {
                                model.openLibraryFile(file)
                            }
                            if file.id != model.libraryFiles.prefix(80).last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            SimulationSummaryPanel(summary: model.simulationSummary, statusMessage: model.statusMessage)
        }
        .onAppear {
            if model.libraryFiles.isEmpty {
                model.refreshLibraryFiles()
            }
        }
    }
}

struct DriveView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(eyebrow: "Drive", title: "Free space without losing originals", subtitle: "Free-up is quarantine-only after a live checksum comparison against the archive.")
            WorkflowPlanPanel(plan: model.workflowPlan(.freeUpBuffer))
            CommandBar {
                HelpedCommandButton(
                    title: "Try Free-Up Demo",
                    symbol: "archivebox",
                    prominence: .primary,
                    isDisabled: model.isBusy,
                    helpTitle: "Try Free-Up Demo",
                    helpText: "Looks at fake buffer files and moves only files that match the archive checksum into a local quarantine folder. Files missing from the archive stay put.",
                    action: model.runSimulationFreeUp
                )

                HelpedCommandButton(
                    title: "Reset Demo",
                    symbol: "arrow.counterclockwise",
                    isDisabled: model.isBusy,
                    helpTitle: "Reset Demo",
                    helpText: "Rebuilds the fake card, archive, and buffer folders so the free-up demo starts from known local test data.",
                    action: model.seedSimulation
                )
            }
            SafetyPanel(checks: model.safetyChecks)
            SimulationSummaryPanel(summary: model.simulationSummary, statusMessage: model.statusMessage)
        }
    }
}

struct ImmichView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Immich",
                title: "Connection before upload",
                subtitle: "Use the current Immich API for health, version, and user checks before any real upload path is enabled."
            )
            Panel(
                title: "Connection",
                symbol: "sparkles.rectangle.stack",
                helpTitle: "Immich Connection",
                helpText: "Connection testing uses Immich ping, server version, and current-user endpoints. The API key is stored in macOS Keychain, and uploads remain locked until the transfer path is separately proven safe."
            ) {
                HStack(spacing: 12) {
                    MetricPill(
                        title: "Server",
                        value: model.configuration.immichServerURL.isEmpty ? "not configured" : model.configuration.immichServerURL,
                        symbol: "network",
                        tint: model.immichConnectionReport == nil ? AppTheme.amber : AppTheme.mint
                    )
                    MetricPill(
                        title: "User",
                        value: model.immichConnectionReport?.userEmail ?? "not connected",
                        symbol: "person.crop.circle",
                        tint: AppTheme.accent
                    )
                }

                Text(model.immichConnectionStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                CommandBar {
                    HelpedCommandButton(
                        title: model.immichIsTestingConnection ? "Testing" : "Test Connection",
                        symbol: "bolt.horizontal.circle",
                        prominence: .primary,
                        isDisabled: model.immichIsTestingConnection,
                        helpTitle: "Test Connection",
                        helpText: "Calls the Immich server with the configured URL and Keychain API key. No files are uploaded.",
                        action: model.testImmichConnection
                    )

                    HelpedCommandButton(
                        title: "Edit Config",
                        symbol: "slider.horizontal.3",
                        isDisabled: model.immichIsTestingConnection,
                        helpTitle: "Edit Config",
                        helpText: "Open Config to edit the Immich server URL and API key.",
                        action: { model.selectedSection = .config }
                    )
                }
            }

            Panel(
                title: "Upload Gate",
                symbol: "lock.shield",
                helpTitle: "Upload Gate",
                helpText: "Immich upload requires asset bytes, created and modified timestamps, and API-key permission. This app connects first, then keeps real upload disabled until source-copy verification is finished."
            ) {
                HStack(spacing: 12) {
                    MetricPill(title: "API", value: "latest OpenAPI checked", symbol: "checkmark.seal", tint: AppTheme.mint)
                    MetricPill(title: "Uploads", value: "locked for now", symbol: "lock", tint: AppTheme.amber)
                }
            }

            WorkflowPlanPanel(plan: model.workflowPlan(.immichUpload))
        }
    }
}

struct JobsView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(eyebrow: "Jobs", title: "Every action leaves a trail", subtitle: "Each demo action records what ran, whether it passed, and what the latest status was.")
            ActivityLogPanel(entries: model.activityLog)
            JobsStrip(jobs: model.jobs)
        }
    }
}

struct ConfigView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Config",
                title: "One place for paths and defaults",
                subtitle: "Browse with Finder-style panels or type paths directly. Config saves automatically and survives app restarts."
            )

            Panel(
                title: "Folders",
                symbol: "folder",
                helpTitle: "Folders",
                helpText: "These paths are saved in Camera Toolkit config. Demo Root is used by the safe demo today; the archive, buffer, and log paths are kept here so real integrations have one source of truth later."
            ) {
                ConfigPathRow(
                    title: "Demo Root",
                    detail: "Fake card, demo archive, and demo buffer live under this folder.",
                    path: Binding(
                        get: { model.configuration.demoRootPath },
                        set: { model.setConfigPath(\.demoRootPath, to: $0) }
                    ),
                    helpText: "The safe demo creates fake files under this root. Keep it somewhere local and disposable.",
                    browse: { model.chooseFolder(title: "Choose Demo Root", keyPath: \.demoRootPath) }
                )

                ConfigPathRow(
                    title: "Import Source",
                    detail: "The source folder used by Preview Copy and demo import.",
                    path: Binding(
                        get: { model.configuration.importSourcePath },
                        set: { model.setConfigPath(\.importSourcePath, to: $0) }
                    ),
                    helpText: "Use this for a local folder you want to scan. Demo mode still writes only to demo storage.",
                    browse: { model.chooseFolder(title: "Choose Import Source", keyPath: \.importSourcePath) }
                )

                ConfigPathRow(
                    title: "Archive Folder",
                    detail: "Long-term verified archive target for future real mode.",
                    path: Binding(
                        get: { model.configuration.archivePath },
                        set: { model.setConfigPath(\.archivePath, to: $0) }
                    ),
                    helpText: "This is saved now but not used for real writes until real storage mode is intentionally unlocked.",
                    browse: { model.chooseFolder(title: "Choose Archive Folder", keyPath: \.archivePath) }
                )

                ConfigPathRow(
                    title: "Buffer Folder",
                    detail: "Temporary working storage for future free-up checks.",
                    path: Binding(
                        get: { model.configuration.bufferPath },
                        set: { model.setConfigPath(\.bufferPath, to: $0) }
                    ),
                    helpText: "This is the place the app will eventually free up after checksum verification. Demo mode keeps this local.",
                    browse: { model.chooseFolder(title: "Choose Buffer Folder", keyPath: \.bufferPath) }
                )

                ConfigPathRow(
                    title: "Activity Log",
                    detail: "Permanent action log JSONL file.",
                    path: Binding(
                        get: { model.configuration.activityLogPath },
                        set: { model.setConfigPath(\.activityLogPath, to: $0) }
                    ),
                    helpText: "Jobs writes plain activity history here so the Jobs screen can reload it after restart.",
                    browse: model.chooseActivityLogFile
                )

                Text(model.configMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Panel(
                title: "Batch Defaults",
                symbol: "camera.metering.matrix",
                helpTitle: "Batch Defaults",
                helpText: "These defaults are saved with config and reused across launches. They describe the batch; they do not make real storage writable."
            ) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                    GridRow {
                        FormFieldLabel(title: "Camera", helpText: "The device label stored with future manifests.")
                        Picker(
                            "Camera",
                            selection: Binding(
                                get: { model.configuration.selectedDeviceID },
                                set: { value in model.setDeviceID(value) }
                            )
                        ) {
                            Text("Sony A7V").tag("sony-a7v")
                            Text("DJI Osmo 360").tag("osmo-360")
                            Text("DJI Mini 2").tag("dji-mini-2")
                            Text("iPhone").tag("iphone")
                        }
                    }

                    GridRow {
                        FormFieldLabel(title: "Trip", helpText: "A human name for the import batch.")
                        TextField(
                            "Trip name",
                            text: Binding(
                                get: { model.configuration.eventName },
                                set: { value in model.setEventName(value) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        FormFieldLabel(title: "Destination", helpText: "The configured destination preference for imports.")
                        Picker(
                            "Destination",
                            selection: Binding(
                                get: { model.configuration.importDestination },
                                set: { value in model.setImportDestination(value) }
                            )
                        ) {
                            Text("Demo Archive").tag(TransferLocation.nas)
                            Text("Demo Buffer").tag(TransferLocation.drive)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }

            Panel(
                title: "Immich",
                symbol: "sparkles.rectangle.stack",
                helpTitle: "Immich",
                helpText: "The server URL is stored in config. The API key is stored separately in macOS Keychain, not in the JSON config or activity log."
            ) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                    GridRow {
                        FormFieldLabel(title: "Server URL", helpText: "Use the base Immich URL, such as http://photos.local:2283. The app normalizes it to the /api endpoint internally.")
                        TextField(
                            "http://photos.local:2283",
                            text: Binding(
                                get: { model.configuration.immichServerURL },
                                set: { value in model.setImmichServerURL(value) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        FormFieldLabel(title: "API Key", helpText: "Saved in macOS Keychain under the Camera Toolkit service. It is not written to config.json.")
                        SecureField(
                            "Immich API key",
                            text: Binding(
                                get: { model.immichAPIKeyDraft },
                                set: { model.immichAPIKeyDraft = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }

                Text(model.immichConnectionStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                CommandBar {
                    HelpedCommandButton(
                        title: "Save Key",
                        symbol: "key",
                        isDisabled: model.immichIsTestingConnection,
                        helpTitle: "Save Key",
                        helpText: "Stores the API key in macOS Keychain. Leave the field empty and save to remove it.",
                        action: model.saveImmichAPIKey
                    )

                    HelpedCommandButton(
                        title: model.immichIsTestingConnection ? "Testing" : "Test Connection",
                        symbol: "bolt.horizontal.circle",
                        prominence: .primary,
                        isDisabled: model.immichIsTestingConnection,
                        helpTitle: "Test Connection",
                        helpText: "Calls Immich ping, server version, and current user endpoints. No files are uploaded.",
                        action: model.testImmichConnection
                    )
                }
            }

            Panel(
                title: "External Editors",
                symbol: "paintbrush.pointed",
                helpTitle: "External Editors",
                helpText: "Preview is the default. The Library tab opens a working copy from this folder so editor apps do not mutate the original source photo."
            ) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                    GridRow {
                        FormFieldLabel(title: "Default Editor", helpText: "Choose which app opens when you click a photo in Library. Preview is the safest default because it is built into macOS.")
                        Picker(
                            "Default Editor",
                            selection: Binding(
                                get: { model.configuration.externalEditor },
                                set: { value in model.setExternalEditor(value) }
                            )
                        ) {
                            ForEach(ExternalEditor.allCases, id: \.self) { editor in
                                Text(editor.displayName).tag(editor)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    GridRow {
                        FormFieldLabel(title: "Working Copies", helpText: "Camera Toolkit copies photos here before opening them in Preview, Photomator, or Topaz Photo.")
                        PathAutocompleteField(
                            path: Binding(
                                get: { model.configuration.editorWorkingFolderPath },
                                set: { model.setConfigPath(\.editorWorkingFolderPath, to: $0) }
                            ),
                            placeholder: "/Users/you/Pictures/Camera Toolkit Working Copies"
                        )
                        .frame(height: 28)
                    }
                }

                CommandBar {
                    HelpedCommandButton(
                        title: "Choose Folder",
                        symbol: "folder",
                        helpTitle: "Choose Working Folder",
                        helpText: "Pick where protected working copies are created before an external editor opens them.",
                        action: model.chooseEditorWorkingFolder
                    )

                    HelpedCommandButton(
                        title: "Open Library",
                        symbol: "photo.stack",
                        prominence: .primary,
                        helpTitle: "Open Library",
                        helpText: "Go to Library and click a photo to open a working copy in the configured editor.",
                        action: { model.selectedSection = .library }
                    )
                }
            }

            Panel(
                title: "Transfer Tools",
                symbol: "wrench.and.screwdriver",
                helpTitle: "Transfer Tools",
                helpText: "The app keeps stable transfer logic in tested Swift services while preserving rclone-style safety rules for copy, checksum, and immutable archive writes. These paths are used for plan previews only in this locked build."
            ) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                    GridRow {
                        FormFieldLabel(title: "rclone", helpText: "Used to preview immutable copy and checksum commands. The app does not execute these commands in locked mode.")
                        TextField(
                            "rclone",
                            text: Binding(
                                get: { model.configuration.rcloneBinaryPath },
                                set: { model.setRcloneBinaryPath($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        FormFieldLabel(title: "exiftool", helpText: "Used to preview read-only metadata commands for future batch naming and manifests.")
                        TextField(
                            "exiftool",
                            text: Binding(
                                get: { model.configuration.exiftoolBinaryPath },
                                set: { model.setExiftoolBinaryPath($0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }

                HStack(spacing: 12) {
                    MetricPill(title: "Transfer engine", value: "rclone planned", symbol: "arrow.left.arrow.right", tint: AppTheme.accent)
                    MetricPill(title: "Metadata", value: "exiftool read-only", symbol: "camera.metering.matrix", tint: AppTheme.mint)
                    MetricPill(title: "Real execution", value: "locked", symbol: "lock", tint: AppTheme.amber)
                }
            }

            WorkflowPlanPanel(plan: model.workflowPlan(.metadataRead))
        }
    }
}

private struct ConfigPathRow: View {
    var title: String
    var detail: String
    @Binding var path: String
    var helpText: String
    var browse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.headline)
                HelpButton(title: title, message: helpText)
                Spacer()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                PathAutocompleteField(path: $path, placeholder: "/Users/you/path")
                    .frame(height: 28)
                Button(action: browse) {
                    Label("Browse", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .fixedSize()
            }
        }
    }
}

private struct DetailLine: View {
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct EmptyLibraryState: View {
    var refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No photo files listed yet.")
                .font(.headline)
            Text("Refresh scans the configured Import Source for JPG, HEIC, TIFF, and common RAW formats.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CommandButton(
                title: "Refresh",
                symbol: "arrow.clockwise",
                prominence: .primary,
                action: refresh
            )
        }
    }
}

private struct PhotoFileRow: View {
    var file: FileRecord
    var editorName: String
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "photo")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(file.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(file.size.formattedBytes)
                        .font(.callout.monospacedDigit())
                    Label(editorName, systemImage: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .help("Open a working copy in \(editorName)")
    }
}

#Preview("Overview") {
    AppShell(model: .preview)
        .frame(width: 1200, height: 780)
}
