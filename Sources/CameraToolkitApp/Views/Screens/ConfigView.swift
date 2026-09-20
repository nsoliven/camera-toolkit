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
            }

            LocationSettingsSection(
                title: "Camera Sources",
                role: .importSource,
                addTitle: "Add Camera Source",
                model: model
            )
            LocationSettingsSection(
                title: "Library Targets",
                role: .archive,
                addTitle: "Add Library Target",
                model: model
            )
            LocationSettingsSection(
                title: "Buffer Drives",
                role: .buffer,
                addTitle: "Add Buffer Drive",
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
                TrashBatchesView(model: model)
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
                Text("Consecutive frames up to a second apart always chain into a burst. With recovery on, consecutive frames up to the gap limit are compared with Apple Vision and merged when they look alike. Lower distance limits are stricter.")
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
                Button("Empty Taken-Off Files", role: .destructive, action: emptyRemovedFiles)
                    .disabled(confirmation != FreeUpService.confirmationToken || model.isBusy)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func emptyRemovedFiles() {
        let root = EventStorageLocations(configuration: model.configuration).removedFilesRoot
        do {
            let result = try FreeUpService().emptyTrash(trashRoot: root, confirm: confirmation)
            message = result.deletedBatches.isEmpty
                ? "There was nothing to empty."
                : "Permanently deleted \(result.deletedBatches.count) batch(es), freeing \(result.freedBytes.formattedBytes)."
        } catch {
            message = error.localizedDescription
        }
        confirmation = ""
        NotificationCenter.default.post(name: .cameraToolkitMediaTrashChanged, object: nil)
    }
}

/// Lists `_Trash` batches under every configured drive's Trash root and the
/// Buffer's removed-files folder, with a Restore button per batch.
private struct TrashBatchesView: View {
    @Bindable var model: DashboardModel
    @State private var batches: [MediaTrashBatch]?
    @State private var message: String?

    var body: some View {
        Group {
            if let batches {
                if batches.isEmpty {
                    Text("No Trash batches on any configured drive.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(batches) { batch in
                        LabeledContent {
                            HStack(spacing: 10) {
                                Text("\(batch.fileCount) file\(batch.fileCount == 1 ? "" : "s") · \(batch.byteCount.formattedBytes)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Restore") { restore(batch) }
                                    .disabled(model.isBusy)
                                    .help(batch.segments.allSatisfy(\.hasManifest)
                                        ? "Rename every file back to its recorded location. Existing files are never replaced."
                                        : "This batch has no manifest of where its files lived, so it cannot be restored here.")
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(batch.createdAt == .distantPast
                                    ? batch.name
                                    : batch.createdAt.formatted(date: .abbreviated, time: .shortened))
                                Text(whereabouts(batch))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            } else {
                Text("Reading Trash folders…")
                    .foregroundStyle(.secondary)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .cameraToolkitStorageLocationsChanged)) { _ in
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cameraToolkitMediaTrashChanged)) { _ in
            reload()
        }
    }

    /// `_Trash` roots to look under: the configured removed-files folder plus
    /// `.Camera Toolkit/_Trash` on the volume of every configured location.
    private func trashRoots() -> [URL] {
        let locations = EventStorageLocations(configuration: model.configuration)
        var roots = [locations.removedFilesRoot]
        var seen = Set(roots.map { EventStorageLocations.pathKey($0.path) })
        var paths = model.configuration.configuredLocations.map(\.path)
        paths.append(model.configuration.bufferPath)
        paths.append(model.configuration.privateStagingPath)
        paths.append(model.configuration.cameraLibraryRootPath)
        for path in paths {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
            guard let volume = VolumeInfo.volumeRoot(for: url) else { continue }
            let root = volume
                .appendingPathComponent(EventStorageLocations.toolkitFolderName, isDirectory: true)
                .appendingPathComponent("_Trash", isDirectory: true)
            if seen.insert(EventStorageLocations.pathKey(root.path)).inserted {
                roots.append(root)
            }
        }
        return roots
    }

    private func whereabouts(_ batch: MediaTrashBatch) -> String {
        let places = batch.segments.map { segment -> String in
            if let volume = VolumeInfo.volumeRoot(for: segment.folder) {
                return volume.lastPathComponent
            }
            // <root>/.Camera Toolkit/_Trash/<batch> → the folder holding .Camera Toolkit
            return segment.folder
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent
        }
        return Array(Set(places)).sorted().joined(separator: ", ")
    }

    private func reload() {
        let roots = trashRoots()
        let fallback = EventStorageLocations(configuration: model.configuration).removedFilesRoot
        Task { @MainActor in
            let found = await Task.detached(priority: .utility) {
                MediaTrashService(removedFilesRoot: fallback).listBatches(under: roots)
            }.value
            batches = found
        }
    }

    private func restore(_ batch: MediaTrashBatch) {
        let fallback = EventStorageLocations(configuration: model.configuration).removedFilesRoot
        model.runBackgroundJob(
            action: .organize,
            runningNote: "Restoring \(batch.fileCount) file(s) from Trash",
            logTitle: "Restored a Trash batch",
            logDetail: "Renamed files back to the paths their batch manifest recorded. Existing files were never replaced.",
            operation: { progress in
                MediaTrashService(removedFilesRoot: fallback).restore(batch: batch) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Restoring", command: ""))
                }
            },
            completion: { report in
                var parts = ["Restored \(report.restored.count) file(s) (\(report.restoredBytes.formattedBytes)) back to where they lived."]
                if !report.conflicts.isEmpty {
                    parts.append("\(report.conflicts.count) stayed in Trash because a file already exists at the original path.")
                }
                if !report.missing.isEmpty {
                    parts.append("\(report.missing.count) recorded file(s) were no longer in the batch.")
                }
                if !report.failed.isEmpty {
                    parts.append("\(report.failed.count) could not move back: \(report.failed.values.first ?? "")")
                }
                let summary = parts.joined(separator: " ")
                message = summary
                NotificationCenter.default.post(name: .cameraToolkitMediaTrashChanged, object: nil)
                reload()
                return summary
            }
        )
    }
}
