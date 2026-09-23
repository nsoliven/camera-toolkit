import AppKit
import CameraToolkitCore
import SwiftUI

extension ConfiguredLocationRole {
    var settingsCurrentLabel: String {
        switch self {
        case .importSource: "Import Default"
        case .archive: "Originals Destination"
        case .buffer: "Buffer Destination"
        }
    }

    var settingsSelectionButtonTitle: String {
        switch self {
        case .importSource: "Set as Default"
        case .archive: "Use for Originals"
        case .buffer: "Use as Buffer"
        }
    }

    var settingsSelectionExplanation: String {
        switch self {
        case .importSource:
            "Import Default is the camera or card Camera Toolkit starts with. You can still browse any connected source from the sidebar."
        case .archive:
            "Originals Destination receives the permanent, checksum-verified archive after files are copied to the buffer."
        case .buffer:
            "Buffer Destination receives the first temporary, checksum-verified copy from a camera or card."
        }
    }
}

struct ConfigView: View {
    @Bindable var model: DashboardModel
    @AppStorage(BurstGroupingConfiguration.visualRecoveryDefaultsKey) private var burstVisualRecovery = true
    @AppStorage(BurstGroupingConfiguration.maximumGapDefaultsKey) private var burstMaximumGap = 2.0
    @AppStorage(BurstGroupingConfiguration.maximumVisionDistanceDefaultsKey) private var burstVisionDistance = 0.48
    /// Bumped to re-run the `PlaceStatus.check` probes in `body` — volume
    /// mount and unmount notifications bump it too so this window updates
    /// itself when a drive or share appears or disappears.
    @State private var placeStatusRevision = 0

    var body: some View {
        Form {
            Section {
                PlaceRow(
                    title: "Shared Buffer",
                    symbol: "externaldrive.fill",
                    tint: .blue,
                    status: PlaceStatus.check(EventStorageLocations(configuration: model.configuration).bufferRoot),
                    missingIsFine: false,
                    onRefresh: { placeStatusRevision &+= 1 }
                ) {
                    if model.chooseFolder(title: "Choose the Shared Buffer Folder", keyPath: \.bufferPath) {
                        NotificationCenter.default.post(name: .cameraToolkitStorageLocationsChanged, object: nil)
                    }
                }
                PlaceRow(
                    title: "Private (hidden)",
                    symbol: "lock.fill",
                    tint: .purple,
                    status: PlaceStatus.check(EventStorageLocations(configuration: model.configuration).privateStagingRoot, includeFreeSpace: false),
                    missingIsFine: true,
                    onRefresh: { placeStatusRevision &+= 1 }
                ) {
                    if model.chooseFolder(title: "Choose the Private Folder", keyPath: \.privateStagingPath) {
                        NotificationCenter.default.post(name: .cameraToolkitStorageLocationsChanged, object: nil)
                    }
                }
                PlaceRow(
                    title: "NAS Library",
                    symbol: "server.rack",
                    tint: .green,
                    status: PlaceStatus.check(EventStorageLocations(configuration: model.configuration).libraryRoot, includeFreeSpace: false),
                    missingIsFine: false,
                    onRefresh: { placeStatusRevision &+= 1 }
                ) {
                    model.chooseCameraLibraryRoot()
                }
            } header: {
                Text("Where Things Live")
            } footer: {
                Text("Shared events live in the Buffer. Private events wait in the hidden folder until they’re on the NAS. The NAS library is the permanent home.")
            }

            Section("Photo Library") {
                PathSettingRow(
                    title: "Library root",
                    path: Binding(
                        get: { model.configuration.cameraLibraryRootPath },
                        set: { model.setCameraLibraryRoot($0) }
                    ),
                    choose: { model.chooseCameraLibraryRoot() }
                )
                PathSettingRow(
                    title: "Photo list database",
                    path: Binding(
                        get: { model.configuration.catalogDatabasePath },
                        set: { model.setConfigPath(\.catalogDatabasePath, to: $0) }
                    ),
                    choose: { model.chooseCatalogDatabaseFile() }
                )
                PathSettingRow(
                    title: "Photo list backups",
                    path: Binding(
                        get: { model.configuration.catalogBackupFolderPath },
                        set: { model.setConfigPath(\.catalogBackupFolderPath, to: $0) }
                    ),
                    choose: {
                        _ = model.chooseFolder(
                            title: "Choose Photo List Backup Folder",
                            keyPath: \.catalogBackupFolderPath
                        )
                    }
                )
                Button("Prepare Photo List") { model.prepareLibraryCatalog() }
                CatalogBackupStatusRow(model: model)
            }

            LocationSettingsSection(
                title: "Camera Sources",
                role: .importSource,
                addTitle: "Add Camera Source…",
                model: model
            )
            LocationSettingsSection(
                title: "Library Targets",
                role: .archive,
                addTitle: "Add Library Target…",
                model: model
            )
            LocationSettingsSection(
                title: "Buffer Drives",
                role: .buffer,
                addTitle: "Add Buffer Drive…",
                model: model
            )

            Section {
                PathSettingRow(
                    title: "Private staging",
                    path: Binding(
                        get: { model.configuration.privateStagingPath },
                        set: { model.setConfigPath(\.privateStagingPath, to: $0) }
                    ),
                    choose: {
                        _ = model.chooseFolder(title: "Choose Private Staging Folder", keyPath: \.privateStagingPath)
                    }
                )
                LabeledContent("In use") {
                    Text(EventStorageLocations(configuration: model.configuration).privateStagingRoot.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Taken off the drive") {
                    Text(EventStorageLocations(configuration: model.configuration).removedFilesRoot.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                EmptyRemovedFilesRow(model: model)
            } header: {
                Text("Private Events")
            } footer: {
                Text("Events marked Private · NAS only never enter the shared Buffer. Their originals wait in the private staging folder, which Finder hides, until they are archived to the NAS. Leave the path empty to use a hidden folder on the Buffer drive. Files taken off the drive stay recoverable until you empty them here.")
            }

            Section {
                LabeledContent {
                    Button("Open Trash…") {
                        TrashWindowController.shared.show(model: model)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Browse and restore files")
                        Text("The Trash window lists every file in _Trash with previews, search, and per-file restore — the trash-can button in the Organize sidebar opens the same place.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Trash")
            } footer: {
                Text("Move to Trash in the organizer renames files into the drive's own .Camera Toolkit/_Trash folder and records where each file lived in a manifest, so a batch stays restorable even when it came from a card, an external drive, or the NAS. Restore puts files back where they were; nothing is deleted here unless you empty the folder above.")
            }

            Section {
                Toggle("Recover matching frames", isOn: $burstVisualRecovery)
                LabeledContent("Recovery gap limit") {
                    Text("\(burstMaximumGap, specifier: "%.1f") s")
                        .monospacedDigit()
                }
                Slider(value: $burstMaximumGap, in: 1.5...5, step: 0.5)
                    .disabled(!burstVisualRecovery)
                LabeledContent("Similarity distance limit") {
                    Text(burstVisionDistance, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                }
                Slider(value: $burstVisionDistance, in: 0.2...0.9, step: 0.02)
                    .disabled(!burstVisualRecovery)
            } header: {
                Text("Burst Grouping")
            } footer: {
                Text("Consecutive frames up to a second apart always chain into a burst. With recovery on, consecutive frames up to the gap limit are compared with Apple Vision and merged when they look alike. Lower distance limits are stricter. These sliders apply on the next regroup — press Regroup Bursts on an Unsorted board to re-run grouping without re-reading files.")
            }

            Section("Import Defaults") {
                Picker(
                    "Camera",
                    selection: Binding(
                        get: { model.configuration.selectedDeviceID },
                        set: { model.setDeviceID($0) }
                    )
                ) {
                    Text("Generic Camera").tag("generic-camera")
                    Text("Sony A7V").tag("sony-a7v")
                    Text("DJI Osmo 360").tag("osmo-360")
                    Text("DJI Mini 2").tag("dji-mini-2")
                    Text("DJI Nano").tag("dji-nano")
                    Text("DJI Action 6").tag("action-6")
                    Text("iPhone").tag("iphone")
                }
                TextField(
                    "Default event name",
                    text: Binding(
                        get: { model.configuration.eventName },
                        set: { model.setEventName($0) }
                    )
                )
            }

            Section("Immich") {
                TextField(
                    "Server URL",
                    text: Binding(
                        get: { model.configuration.immichServerURL },
                        set: { model.setImmichServerURL($0) }
                    )
                )
                SecureField("API key", text: $model.immichAPIKeyDraft)
                Text(model.immichConnectionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Save Key") { model.saveImmichAPIKey() }
                    Button(model.immichIsTestingConnection ? "Testing…" : "Test Connection") {
                        model.testImmichConnection()
                    }
                    .disabled(model.immichIsTestingConnection)
                }
            }

            Section("TrueNAS Capacity") {
                TextField(
                    "Server URL",
                    text: Binding(
                        get: { model.configuration.trueNASServerURL },
                        set: { model.setTrueNASServerURL($0) }
                    ),
                    prompt: Text("https://nas.example.com")
                )
                TextField(
                    "API username",
                    text: Binding(
                        get: { model.configuration.trueNASUsername },
                        set: { model.setTrueNASUsername($0) }
                    )
                )
                TextField(
                    "Dataset",
                    text: Binding(
                        get: { model.configuration.trueNASDataset },
                        set: { model.setTrueNASDataset($0) }
                    ),
                    prompt: Text("Optional — detect from mounted SMB share")
                )
                Text("Leave Dataset blank to match the mounted Library root to its TrueNAS SMB share automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("API key", text: $model.trueNASAPIKeyDraft)

                LabeledContent("TLS certificate") {
                    Text(model.configuration.trueNASTLSPinnedCertificateSHA256.isEmpty ? "System trust only" : "Pinned to this NAS")
                        .foregroundStyle(
                            model.configuration.trueNASTLSPinnedCertificateSHA256.isEmpty
                                ? Color.secondary
                                : Color.green
                        )
                }
                Text(model.trueNASConnectionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button(model.trueNASIsInspectingCertificate ? "Reading…" : "Trust Current Certificate") {
                        model.trustCurrentTrueNASCertificate()
                    }
                    .disabled(model.trueNASIsInspectingCertificate || model.trueNASIsTestingConnection)
                    Button("Save Key") { model.saveTrueNASAPIKey() }
                    Button(model.trueNASIsTestingConnection ? "Testing…" : "Test NAS") {
                        model.testTrueNASConnection()
                    }
                    .disabled(model.trueNASIsTestingConnection || model.trueNASIsInspectingCertificate)
                }
                Text("The mounted SMB folder provides files. This read-only TrueNAS connection provides exact ZFS dataset and pool capacity. The API key stays in macOS Keychain; only the server, dataset, username, and pinned certificate fingerprint are saved locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local App Data") {
                PathSettingRow(
                    title: "Test data",
                    path: Binding(
                        get: { model.configuration.demoRootPath },
                        set: { model.setConfigPath(\.demoRootPath, to: $0) }
                    ),
                    choose: {
                        _ = model.chooseFolder(title: "Choose Test Data Folder", keyPath: \.demoRootPath)
                    }
                )
                PathSettingRow(
                    title: "Activity log",
                    path: Binding(
                        get: { model.configuration.activityLogPath },
                        set: { model.setConfigPath(\.activityLogPath, to: $0) }
                    ),
                    choose: { model.chooseActivityLogFile() }
                )
                Text("API keys are stored in macOS Keychain. Paths and preferences are stored locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            placeStatusRevision &+= 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            placeStatusRevision &+= 1
        }
    }
}

/// "Last backup: 2 hours ago, local and NAS", a warning when backups are
/// stale or failing, and Back Up Now.
private struct CatalogBackupStatusRow: View {
    @Bindable var model: DashboardModel

    var body: some View {
        LabeledContent("Backups") {
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Text(DashboardModel.catalogBackupDescription(model.catalogBackupSummary))
                        .foregroundStyle(.secondary)
                    Button(model.isBackingUpCatalog ? "Backing Up…" : "Back Up Now") {
                        model.backUpCatalogNow()
                    }
                    .disabled(model.isBackingUpCatalog)
                    Button("Restore Face Labels…") { model.restoreFaceLabelsFromBackup() }
                }
                if let warning = DashboardModel.catalogBackupWarning(model.catalogBackupSummary) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
        .onAppear { model.refreshCatalogBackupSummary() }
    }
}

private struct PathSettingRow: View {
    var title: String
    @Binding var path: String
    var choose: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                PathAutocompleteField(path: $path, placeholder: "Choose a path")
                    .frame(minWidth: 320, minHeight: 28)
                Button("Choose…", action: choose)
            }
        }
    }
}

private struct LocationSettingsSection: View {
    var title: String
    var role: ConfiguredLocationRole
    var addTitle: String
    @Bindable var model: DashboardModel

    private var locations: [ConfiguredLocation] {
        model.configuration.locations(role: role)
    }

    var body: some View {
        Section {
            ForEach(locations) { location in
                LocationSettingRow(
                    location: location,
                    isSelected: model.configuration.selectedLocationID(for: role) == location.id,
                    canRemove: locations.count > 1,
                    model: model
                )
            }
            Button(addTitle) { model.addConfiguredLocation(role: role) }
        } header: {
            Text(title)
        } footer: {
            Text(role.settingsSelectionExplanation)
        }
    }
}

private struct LocationSettingRow: View {
    var location: ConfiguredLocation
    var isSelected: Bool
    var canRemove: Bool
    @Bindable var model: DashboardModel

    private var currentLocation: ConfiguredLocation {
        model.configuration.configuredLocations.first { $0.id == location.id } ?? location
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(
                    "Name",
                    text: Binding(
                        get: { currentLocation.name },
                        set: { model.setConfiguredLocationName(location, to: $0) }
                    )
                )
                if isSelected {
                    Label(currentLocation.role.settingsCurrentLabel, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help(currentLocation.role.settingsSelectionExplanation)
                } else {
                    Button(currentLocation.role.settingsSelectionButtonTitle) {
                        model.useConfiguredLocation(currentLocation)
                    }
                    .help(currentLocation.role.settingsSelectionExplanation)
                }
                Button("Choose…") { model.chooseConfiguredLocationFolder(currentLocation) }
                Button(role: .destructive) {
                    model.removeConfiguredLocation(currentLocation)
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(!canRemove)
            }
            PathAutocompleteField(
                path: Binding(
                    get: { currentLocation.path },
                    set: { model.setConfiguredLocationPath(location, to: $0) }
                ),
                placeholder: "Choose a folder"
            )
            .frame(minHeight: 28)
        }
    }
}

private struct EmptyRemovedFilesRow: View {
    @Bindable var model: DashboardModel
    @State private var confirmation = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Type DELETE to empty permanently", text: $confirmation)
                    .frame(maxWidth: 260)
                Button("Empty Trash", role: .destructive, action: emptyRemovedFiles)
                    .disabled(confirmation != FreeUpService.confirmationToken || model.isBusy)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Empties every `_Trash` root the Trash section lists — the configured
    /// removed-files folder plus each configured volume's Trash — off the
    /// main thread. A root that fails keeps its batches and is reported.
    private func emptyRemovedFiles() {
        let roots = EventStorageLocations(configuration: model.configuration).trashRoots()
        let token = confirmation
        model.runBackgroundJob(
            action: .freeUp,
            runningNote: "Emptying Trash folders",
            logTitle: "Emptied Trash",
            logDetail: "Permanently removed _Trash batches under every configured Trash root after the DELETE confirmation.",
            operation: { _ in
                let service = FreeUpService()
                var deleted: [String] = []
                var freed: Int64 = 0
                var failures: [String] = []
                for root in roots {
                    do {
                        let result = try service.emptyTrash(trashRoot: root, confirm: token)
                        deleted.append(contentsOf: result.deletedBatches)
                        freed += result.freedBytes
                    } catch {
                        failures.append("\(root.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return (deleted, freed, failures)
            },
            completion: { outcome in
                var parts = [
                    outcome.0.isEmpty
                        ? (outcome.2.isEmpty ? "There was nothing to empty." : "Nothing was deleted.")
                        : "Permanently deleted \(outcome.0.count) batch(es), freeing \(outcome.1.formattedBytes)."
                ]
                parts.append(contentsOf: outcome.2)
                let summary = parts.joined(separator: " ")
                message = summary
                confirmation = ""
                NotificationCenter.default.post(name: .cameraToolkitMediaTrashChanged, object: nil)
                return summary
            }
        )
    }
}

