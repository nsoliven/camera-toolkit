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

    var body: some View {
        Form {
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
