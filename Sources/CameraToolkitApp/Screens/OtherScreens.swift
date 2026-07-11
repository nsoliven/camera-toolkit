import CameraToolkitCore
import SwiftUI

struct LibraryView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Library",
                title: "Open photos like a Mac app",
                subtitle: "Browse the chosen from folder, then click a photo to open a protected edit copy in Preview by default."
            )

            Panel(
                title: "Photos to Edit",
                symbol: "photo.stack",
                helpTitle: "Photos to Edit",
                helpText: "This scans the from folder from Config. Clicking a photo copies it into the edit folder before opening it, so the original file is not modified by an editor."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    DetailLine(title: "From", value: model.configuration.importSourcePath)
                    DetailLine(title: "Opens With", value: model.configuration.externalEditor.displayName)
                    DetailLine(title: "Working Copies", value: model.configuration.editorWorkingFolderPath)
                    if let lastOpenedWorkingCopyPath = model.lastOpenedWorkingCopyPath {
                        DetailLine(title: "Last Opened", value: lastOpenedWorkingCopyPath)
                    }
                }

                CommandBar {
                    HelpedCommandButton(
                        title: "Choose From Folder",
                        symbol: "folder",
                        isDisabled: model.isBusy,
                        helpTitle: "Choose From Folder",
                        helpText: "Pick the folder the Library tab scans for supported photo files.",
                        action: model.chooseImportFolder
                    )

                    HelpedCommandButton(
                        title: "Refresh",
                        symbol: "arrow.clockwise",
                        prominence: .primary,
                        isDisabled: model.isBusy,
                        helpTitle: "Refresh",
                        helpText: "Rescans the selected from folder and lists supported photo files.",
                        action: model.refreshLibraryFiles
                    )

                    HelpedCommandButton(
                        title: "Edit Config",
                        symbol: "slider.horizontal.3",
                        isDisabled: model.isBusy,
                        helpTitle: "Edit Config",
                        helpText: "Open Config to change the default editor, edit-copy folder, or from folder.",
                        action: { model.selectedSection = .config }
                    )
                }
            }

            WorkflowPlanPanel(plan: model.workflowPlan(.editorCheckout))

            Panel(
                title: "Photos",
                symbol: "photo.on.rectangle.angled",
                helpTitle: "Photos",
                helpText: "Single-clicking a row opens an edit copy in the configured editor. Preview is the default editor, and the real originals stay untouched."
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
            HeaderView(eyebrow: "Drive", title: "Clear space without losing originals", subtitle: "Only clear buffer space after the app proves the same files are already in the photo library.")
            WorkflowPlanPanel(plan: model.workflowPlan(.freeUpBuffer))
            CommandBar {
                HelpedCommandButton(
                    title: "Test Clear Space",
                    symbol: "archivebox",
                    prominence: .primary,
                    isDisabled: model.isBusy,
                    helpTitle: "Test Clear Space",
                    helpText: "Looks at disposable buffer files and moves aside only files that already match the test library. Files missing from the library stay put.",
                    action: model.runSimulationFreeUp
                )

                HelpedCommandButton(
                    title: "Reset Test Data",
                    symbol: "arrow.counterclockwise",
                    isDisabled: model.isBusy,
                    helpTitle: "Reset Test Data",
                    helpText: "Rebuilds the disposable from folder, test library, and buffer folders so the clear-space test starts from known data.",
                    action: model.seedSimulation
                )
            }
            Panel(
                title: "Speed Tests",
                symbol: "speedometer",
                helpTitle: "Speed Tests",
                helpText: "These write and read one temporary test file in the configured folder, report live throughput, and remove the test file when finished."
            ) {
                HStack(spacing: 12) {
                    MetricPill(title: "Buffer", value: model.expandedBufferRootPath, symbol: "externaldrive", tint: AppTheme.mint)
                    MetricPill(title: "Photo Library", value: model.expandedLibraryRootPath, symbol: "network", tint: AppTheme.accent)
                }

                CommandBar {
                    HelpedCommandButton(
                        title: "Test Buffer Speed",
                        symbol: "speedometer",
                        prominence: .primary,
                        isDisabled: model.isBusy,
                        helpTitle: "Test Buffer Speed",
                        helpText: "Measures write and read speed in the configured buffer folder using a temporary file.",
                        action: model.runBufferSpeedTest
                    )

                    HelpedCommandButton(
                        title: "Test Library Speed",
                        symbol: "network",
                        isDisabled: model.isBusy,
                        helpTitle: "Test Library Speed",
                        helpText: "Measures write and read speed in the configured photo library using a temporary file.",
                        action: model.runLibraryNetworkSpeedTest
                    )
                }
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
                subtitle: "Check Immich before any real upload path is enabled."
            )
            Panel(
                title: "Connection",
                symbol: "sparkles.rectangle.stack",
                helpTitle: "Immich Connection",
                helpText: "Connection testing checks Immich health, version, and current user. The API key is stored in macOS Keychain, and uploads remain locked until the copy path is separately proven safe."
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
                title: "Upload Lock",
                symbol: "lock.shield",
                helpTitle: "Upload Lock",
                helpText: "Immich upload needs photo bytes, timestamps, and API-key permission. This app connects first, then keeps real upload disabled until the copy check is finished."
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
            HeaderView(eyebrow: "Jobs", title: "Every action leaves a trail", subtitle: "Actions are saved in plain language with what ran, whether it passed, and what the latest status was.")
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
                title: "Advanced paths",
                subtitle: "Setup keeps the main choices simple. This screen lets you inspect and edit the exact saved paths."
            )

            Panel(
                title: "Camera Library",
                symbol: "folder.badge.gearshape",
                helpTitle: "Camera Library",
                helpText: "The library root is the folder that owns Inbox, Originals, Edited, Selects, Shared, and proof files."
            ) {
                ConfigPathRow(
                    title: "Library Root",
                    detail: "The main photo folder.",
                    path: Binding(
                        get: { model.configuration.cameraLibraryRootPath },
                        set: { model.setCameraLibraryRoot($0) }
                    ),
                    helpText: "Choose the folder that owns Inbox, Originals, Edited, Selects, Shared, and proof files.",
                    browse: model.chooseCameraLibraryRoot
                )

                ConfigPathRow(
                    title: "Photo List DB",
                    detail: "Local database for file relationships.",
                    path: Binding(
                        get: { model.configuration.catalogDatabasePath },
                        set: { model.setConfigPath(\.catalogDatabasePath, to: $0) }
                    ),
                    helpText: "The local SQLite database tracks saved places, library folders, batches, assets, and file copies.",
                    browse: model.chooseCatalogDatabaseFile
                )

                ConfigPathRow(
                    title: "Photo List Backups",
                    detail: "Timestamped SQLite copies.",
                    path: Binding(
                        get: { model.configuration.catalogBackupFolderPath },
                        set: { model.setConfigPath(\.catalogBackupFolderPath, to: $0) }
                    ),
                    helpText: "Prepare Photo List writes timestamped backups here, usually inside the photo library proof folder.",
                    browse: { model.chooseFolder(title: "Choose Photo List Backup Folder", keyPath: \.catalogBackupFolderPath) }
                )

                CommandBar {
                    HelpedCommandButton(
                        title: "Open Setup",
                        symbol: "checklist",
                        helpTitle: "Open Setup",
                        helpText: "Return to the simpler setup screen.",
                        action: { model.selectedSection = .setup }
                    )
                    HelpedCommandButton(
                        title: "Prepare Photo List",
                        symbol: "cylinder.split.1x2",
                        prominence: .primary,
                        helpTitle: "Prepare Photo List",
                        helpText: "Creates missing library folders, creates or updates the local photo list, and writes a timestamped backup.",
                        action: model.prepareLibraryCatalog
                    )
                }
            }

            Panel(
                title: "Saved Places",
                symbol: "externaldrive.connected.to.line.below",
                helpTitle: "Saved Places",
                helpText: "Add named folders you actually use: camera folders, homelab/NAS photo libraries, and portable buffer drives. The selected folder in each group drives Library, Preview Copy, and locked move plans."
            ) {
                ConfigLocationSection(
                    title: "From Folders",
                    subtitle: "Camera cards, mounted camera folders, or staging folders the app can copy from.",
                    role: .importSource,
                    emptyText: "Add a camera folder.",
                    addTitle: "Add From Folder",
                    model: model
                )

                Divider()

                ConfigLocationSection(
                    title: "Photo Library Targets",
                    subtitle: "Long-term folders, usually your homelab/NAS photo library.",
                    role: .archive,
                    emptyText: "Add your photo library folder.",
                    addTitle: "Add Library",
                    model: model
                )

                Divider()

                ConfigLocationSection(
                    title: "Buffer Drives",
                    subtitle: "Temporary travel or working storage that can later be checked against the photo library.",
                    role: .buffer,
                    emptyText: "Add a portable buffer folder.",
                    addTitle: "Add Buffer",
                    model: model
                )
            }

            Panel(
                title: "Test Data",
                symbol: "testtube.2",
                helpTitle: "Test Data",
                helpText: "These local paths are only for disposable safety tests and app logs. They are not your real camera folder, photo library, or portable buffer unless you explicitly add those as saved places above."
            ) {
                ConfigPathRow(
                    title: "Test Data Root",
                    detail: "Disposable from folder, library, and buffer live under this folder.",
                    path: Binding(
                        get: { model.configuration.demoRootPath },
                        set: { model.setConfigPath(\.demoRootPath, to: $0) }
                    ),
                    helpText: "Safety tests create disposable files under this root. Keep it somewhere local and safe to reset.",
                    browse: { model.chooseFolder(title: "Choose Test Data Root", keyPath: \.demoRootPath) }
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
                        FormFieldLabel(title: "Camera", helpText: "The device label stored with future proof files.")
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
                            Text("Photo Library").tag(TransferLocation.nas)
                            Text("Buffer").tag(TransferLocation.drive)
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
                helpText: "Preview is the default. The Library tab opens an edit copy from this folder so editor apps do not change the original photo."
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
                        FormFieldLabel(title: "Edit Copies", helpText: "Camera Toolkit copies photos here before opening them in Preview, Photomator, or Topaz Photo.")
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
                        helpText: "Pick where protected edit copies are created before an external editor opens them.",
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
                title: "Technical Tools",
                symbol: "wrench.and.screwdriver",
                helpTitle: "Technical Tools",
                helpText: "These are for advanced command previews. Normal app buttons use the tested Swift copy code."
            ) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                    GridRow {
                        FormFieldLabel(title: "rclone", helpText: "Used to preview copy/check commands. The app does not execute these commands in locked mode.")
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
                        FormFieldLabel(title: "exiftool", helpText: "Used to preview read-only photo-info commands for future batch naming and proof files.")
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
                    MetricPill(title: "Copy tool", value: "rclone preview", symbol: "arrow.left.arrow.right", tint: AppTheme.accent)
                    MetricPill(title: "Photo info", value: "exiftool read-only", symbol: "camera.metering.matrix", tint: AppTheme.mint)
                    MetricPill(title: "Real writes", value: "locked", symbol: "lock", tint: AppTheme.amber)
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

private struct ConfigLocationSection: View {
    var title: String
    var subtitle: String
    var role: ConfiguredLocationRole
    var emptyText: String
    var addTitle: String
    @Bindable var model: DashboardModel

    private var locations: [ConfiguredLocation] {
        model.configuration.locations(role: role)
    }

    private var selectedID: UUID? {
        model.configuration.selectedLocationID(for: role)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    model.addConfiguredLocation(role: role)
                } label: {
                    Label(addTitle, systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .fixedSize()
            }

            if locations.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 10) {
                    ForEach(locations) { location in
                        ConfigLocationRow(
                            location: location,
                            isSelected: selectedID == location.id,
                            canRemove: locations.count > 1,
                            model: model
                        )
                    }
                }
            }
        }
    }
}

private struct ConfigLocationRow: View {
    var location: ConfiguredLocation
    var isSelected: Bool
    var canRemove: Bool
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? AppTheme.mint : AppTheme.accent)
                    .frame(width: 28, height: 28)
                    .background((isSelected ? AppTheme.mint : AppTheme.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

                TextField(
                    "Name",
                    text: Binding(
                        get: { currentLocation.name },
                        set: { model.setConfiguredLocationName(location, to: $0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, maxWidth: 260)

                if isSelected {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mint)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Use") {
                        model.useConfiguredLocation(currentLocation)
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                }

                Spacer()

                Button {
                    model.chooseConfiguredLocationFolder(currentLocation)
                } label: {
                    Label("Browse", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .fixedSize()

                Button(role: .destructive) {
                    model.removeConfiguredLocation(currentLocation)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(!canRemove)
                .help(canRemove ? "Remove \(currentLocation.name)" : "Keep at least one \(currentLocation.role.displayName.lowercased())")
            }

            PathAutocompleteField(
                path: Binding(
                    get: { currentLocation.path },
                    set: { model.setConfiguredLocationPath(location, to: $0) }
                ),
                placeholder: "/Volumes/path"
            )
            .frame(height: 28)
        }
        .padding(12)
        .background(isSelected ? AppTheme.mint.opacity(0.08) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? AppTheme.mint.opacity(0.32) : Color.primary.opacity(0.08))
        )
    }

    private var currentLocation: ConfiguredLocation {
        model.configuration.configuredLocations.first { $0.id == location.id } ?? location
    }

    private var iconName: String {
        switch location.role {
        case .importSource: "camera.viewfinder"
        case .archive: "network"
        case .buffer: "externaldrive"
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
            Text("Refresh scans the selected from folder for JPG, HEIC, TIFF, and common RAW formats.")
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
