import AppKit
import CameraToolkitCore
import SwiftUI

/// The Settings window's toolbar panes, in toolbar order. Each pane has a
/// fixed content size so the window resizes to it when the pane changes,
/// the way a Mac settings window does.
enum SettingsPane: Int, CaseIterable, Identifiable {
    case locations
    case library
    case organizing
    case services
    case advanced

    var id: Int { rawValue }

    /// The pane's toolbar item identifier.
    var toolbarIdentifier: String { "CameraToolkit.Settings.\(title)" }

    var title: String {
        switch self {
        case .locations: "Locations"
        case .library: "Library"
        case .organizing: "Organizing"
        case .services: "Services"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .locations: "externaldrive"
        case .library: "photo.stack"
        case .organizing: "square.stack.3d.down.right"
        case .services: "network"
        case .advanced: "gearshape.2"
        }
    }

    var contentSize: NSSize {
        switch self {
        case .locations: NSSize(width: 680, height: 640)
        case .library: NSSize(width: 680, height: 640)
        case .organizing: NSSize(width: 680, height: 430)
        case .services: NSSize(width: 680, height: 620)
        case .advanced: NSSize(width: 680, height: 250)
        }
    }

    /// The pane's SwiftUI content, framed to the pane's size.
    @MainActor
    func view(model: DashboardModel) -> AnyView {
        let content: AnyView = switch self {
        case .locations: AnyView(LocationsSettingsPane(model: model))
        case .library: AnyView(LibrarySettingsPane(model: model))
        case .organizing: AnyView(OrganizingSettingsPane(model: model))
        case .services: AnyView(ServicesSettingsPane(model: model))
        case .advanced: AnyView(AdvancedSettingsPane(model: model))
        }
        return AnyView(
            content
                .formStyle(.grouped)
                .frame(width: contentSize.width, height: contentSize.height)
        )
    }
}

// MARK: - Locations

/// Where the Buffer, private folder, and NAS live, plus every configured
/// camera source, library target, and buffer drive.
struct LocationsSettingsPane: View {
    @Bindable var model: DashboardModel

    /// The three place probes, run off the main actor — they touch the
    /// file system and may wait on a slow network mount. nil until the
    /// first probe lands.
    @State private var places: [PlaceStatus]?
    /// Bumped to re-probe; mount and unmount notifications bump it too so
    /// this pane updates itself when a drive or share comes or goes.
    @State private var placeStatusRevision = 0

    private var locations: EventStorageLocations {
        EventStorageLocations(configuration: model.configuration)
    }

    /// What the probe depends on: the three URLs and the revision.
    private var probeKey: [String] {
        [
            locations.bufferRoot.path,
            locations.privateStagingRoot.path,
            locations.libraryRoot.path,
            String(placeStatusRevision),
        ]
    }

    var body: some View {
        Form {
            Section {
                placeRow(0, title: "Shared Buffer", symbol: "externaldrive.fill", tint: .blue, missingIsFine: false) {
                    if model.chooseFolder(title: "Choose the Shared Buffer Folder", keyPath: \.bufferPath) {
                        NotificationCenter.default.post(name: .cameraToolkitStorageLocationsChanged, object: nil)
                    }
                }
                placeRow(1, title: "Private (hidden)", symbol: "lock.fill", tint: .purple, missingIsFine: true) {
                    if model.chooseFolder(title: "Choose the Private Folder", keyPath: \.privateStagingPath) {
                        NotificationCenter.default.post(name: .cameraToolkitStorageLocationsChanged, object: nil)
                    }
                }
                placeRow(2, title: "NAS Library", symbol: "server.rack", tint: .green, missingIsFine: false) {
                    model.chooseCameraLibraryRoot()
                }
            } header: {
                Text("Where Things Live")
            } footer: {
                Text("Shared events live in the Buffer. Private events wait in the hidden folder until they’re on the NAS. The NAS library is the permanent home.")
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
        }
        .task(id: probeKey) {
            let buffer = locations.bufferRoot
            let privateRoot = locations.privateStagingRoot
            let library = locations.libraryRoot
            places = await Task.detached(priority: .utility) {
                [
                    PlaceStatus.check(buffer),
                    PlaceStatus.check(privateRoot, includeFreeSpace: false),
                    PlaceStatus.check(library, includeFreeSpace: false),
                ]
            }.value
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            placeStatusRevision &+= 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            placeStatusRevision &+= 1
        }
    }

    @ViewBuilder
    private func placeRow(
        _ index: Int,
        title: String,
        symbol: String,
        tint: Color,
        missingIsFine: Bool,
        change: @escaping () -> Void
    ) -> some View {
        if let places, index < places.count {
            PlaceRow(
                title: title,
                symbol: symbol,
                tint: tint,
                status: places[index],
                missingIsFine: missingIsFine,
                onRefresh: { placeStatusRevision &+= 1 },
                change: change
            )
        } else {
            LabeledContent {
                ProgressView()
                    .controlSize(.small)
            } label: {
                Label(title, systemImage: symbol)
            }
        }
    }
}

// MARK: - Library

/// The photo library and its catalog, private events, and the Trash.
struct LibrarySettingsPane: View {
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
                    title: "NAS mirror root",
                    path: Binding(
                        get: { model.configuration.archiveLayoutRootPath },
                        set: { model.setConfigPath(\.archiveLayoutRootPath, to: $0) }
                    ),
                    choose: {
                        _ = model.chooseFolder(title: "Choose the NAS Mirror Root", keyPath: \.archiveLayoutRootPath)
                    }
                )
                .help("Sync to NAS puts every drive file at the same <year>/<event>/… path under this folder. Events archived before the mirror layout stay readable where they are.")
                LabeledContent("NAS share") {
                    TextField("", text: Binding(
                        get: { model.configuration.nasSMBURL },
                        set: { value in model.updateConfiguration { $0.nasSMBURL = value.trimmingCharacters(in: .whitespacesAndNewlines) } }
                    ), prompt: Text("smb://nas.local/share"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                    .help("Connect to NAS… mounts this share with the password saved in your keychain, or opens it in Finder to ask for one.")
                }
                Toggle("Connect to the NAS automatically", isOn: Binding(
                    get: { model.configuration.nasAutoConnect },
                    set: { value in model.updateConfiguration { $0.nasAutoConnect = value } }
                ))
                .disabled(NASConnectionSettings.shareURL(from: model.configuration.nasSMBURL) == nil)
                .help("At launch, mount the share with the keychain's saved password when it is not connected. When the share is on Wi-Fi while an Ethernet link to the NAS is up, reconnect it over Ethernet when no job is using the NAS. Needs the NAS share address above.")
                Stepper(
                    "Parallel transfers (\(model.configuration.nasSyncParallelTransfers))",
                    value: Binding(
                        get: { model.configuration.nasSyncParallelTransfers },
                        set: { value in model.updateConfiguration { $0.nasSyncParallelTransfers = NASSyncOptions.clamp(value) } }
                    ),
                    in: NASSyncOptions.parallelRange
                )
                .help("Sync to NAS copies this many files at once. Each copy is still checked by SHA-256 before it gets its real name.")
                Toggle("Verify on NAS via SSH", isOn: Binding(
                    get: { model.configuration.nasSyncVerifyViaSSH },
                    set: { value in model.updateConfiguration { $0.nasSyncVerifyViaSSH = value } }
                ))
                .help("Hash each batch of copies on the NAS (sync, then sha256sum) instead of reading every byte back over SMB. Uses the system ssh with your own keys and ~/.ssh/config; nothing secret is stored. Without a host and server path, copies are re-read over SMB.")
                if model.configuration.nasSyncVerifyViaSSH {
                    LabeledContent("SSH host") {
                        TextField("", text: Binding(
                            get: { model.configuration.nasSyncSSHHost },
                            set: { value in model.updateConfiguration { $0.nasSyncSSHHost = value.trimmingCharacters(in: .whitespacesAndNewlines) } }
                        ), prompt: Text("nas or user@host"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                    }
                    LabeledContent("Share path on the NAS") {
                        TextField("", text: Binding(
                            get: { model.configuration.nasSyncSSHServerPath },
                            set: { value in model.updateConfiguration { $0.nasSyncSSHServerPath = value.trimmingCharacters(in: .whitespacesAndNewlines) } }
                        ), prompt: Text("/mnt/pool/dataset"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                        .help("The folder the SMB share points at, as the NAS sees it: /Volumes/<share>/x is <this path>/x over SSH.")
                    }
                }
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
                LabeledContent("Photo list") {
                    Button("Prepare Photo List") { model.prepareLibraryCatalog() }
                }
            }

            Section("Backups") {
                CatalogBackupStatusRows(model: model)
            }

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
                EmptyTrashSettingsRow(model: model)
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
                    Text("Browse and restore files")
                    Text("The Trash window lists every file in _Trash with previews, search, and per-file restore — the trash-can button in the Organize sidebar opens the same place.")
                }
            } header: {
                Text("Trash")
            } footer: {
                Text("Move to Trash in the organizer renames files into the drive's own .Camera Toolkit/_Trash folder and records where each file lived in a manifest, so a batch stays restorable even when it came from a card, an external drive, or the NAS. Restore puts files back where they were; nothing is deleted here unless you empty the folder above.")
            }
        }
    }
}

// MARK: - Organizing

/// Burst grouping and the defaults a new import starts with.
struct OrganizingSettingsPane: View {
    @Bindable var model: DashboardModel
    // The organizer reads these same keys, so they stay exactly as they were.
    @AppStorage(BurstGroupingConfiguration.visualRecoveryDefaultsKey) private var burstVisualRecovery = true
    @AppStorage(BurstGroupingConfiguration.maximumGapDefaultsKey) private var burstMaximumGap = 2.0
    @AppStorage(BurstGroupingConfiguration.maximumVisionDistanceDefaultsKey) private var burstVisionDistance = 0.48

    var body: some View {
        Form {
            Section {
                Toggle("Recover matching frames", isOn: $burstVisualRecovery)
                LabeledContent("Recovery gap limit") {
                    HStack {
                        Slider(value: $burstMaximumGap, in: 1.5...5, step: 0.5) {
                            Text("Recovery gap limit")
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        Text("\(burstMaximumGap, specifier: "%.1f") s")
                            .monospacedDigit()
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
                .disabled(!burstVisualRecovery)
                LabeledContent("Similarity distance limit") {
                    HStack {
                        Slider(value: $burstVisionDistance, in: 0.2...0.9, step: 0.02) {
                            Text("Similarity distance limit")
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        Text(burstVisionDistance, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
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
        }
    }
}

// MARK: - Services

/// Immich and the read-only TrueNAS capacity connection.
struct ServicesSettingsPane: View {
    @Bindable var model: DashboardModel

    var body: some View {
        Form {
            Section("Immich") {
                TextField(
                    "Server URL",
                    text: Binding(
                        get: { model.configuration.immichServerURL },
                        set: { model.setImmichServerURL($0) }
                    )
                )
                SecureField("API key", text: $model.immichAPIKeyDraft)
                LabeledContent("Status") {
                    Text(model.immichConnectionStatus)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Save Key") { model.saveImmichAPIKey() }
                    Button(model.immichIsTestingConnection ? "Testing…" : "Test Connection") {
                        model.testImmichConnection()
                    }
                    .disabled(model.immichIsTestingConnection)
                }
            }

            Section {
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
                .help("Leave Dataset blank to match the mounted Library root to its TrueNAS SMB share automatically.")
                SecureField("API key", text: $model.trueNASAPIKeyDraft)

                LabeledContent("TLS certificate") {
                    HStack {
                        Text(model.configuration.trueNASTLSPinnedCertificateSHA256.isEmpty ? "System trust only" : "Pinned to this NAS")
                            .foregroundStyle(
                                model.configuration.trueNASTLSPinnedCertificateSHA256.isEmpty
                                    ? Color.secondary
                                    : Color.green
                            )
                        Button(model.trueNASIsInspectingCertificate ? "Reading…" : "Trust Current Certificate") {
                            model.trustCurrentTrueNASCertificate()
                        }
                        .disabled(model.trueNASIsInspectingCertificate || model.trueNASIsTestingConnection)
                    }
                }
                LabeledContent("Status") {
                    Text(model.trueNASConnectionStatus)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Save Key") { model.saveTrueNASAPIKey() }
                    Button(model.trueNASIsTestingConnection ? "Testing…" : "Test NAS") {
                        model.testTrueNASConnection()
                    }
                    .disabled(model.trueNASIsTestingConnection || model.trueNASIsInspectingCertificate)
                }
            } header: {
                Text("TrueNAS Capacity")
            } footer: {
                Text("Leave Dataset blank to match the mounted Library root to its TrueNAS SMB share automatically. The mounted SMB folder provides files. This read-only TrueNAS connection provides exact ZFS dataset and pool capacity. The API key stays in macOS Keychain; only the server, dataset, username, and pinned certificate fingerprint are saved locally.")
            }
        }
    }
}

// MARK: - Advanced

/// Test data and the activity log.
struct AdvancedSettingsPane: View {
    @Bindable var model: DashboardModel

    var body: some View {
        Form {
            Section {
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
            } header: {
                Text("Local App Data")
            } footer: {
                Text("API keys are stored in macOS Keychain. Paths and preferences are stored locally.")
            }
        }
    }
}
