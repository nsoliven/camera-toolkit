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

// Shared Settings rows. The panes themselves live in SettingsPanes.swift.

/// "Last backup: 2 hours ago, local and NAS", a warning when backups are
/// stale or failing, and Back Up Now — one Form row each.
struct CatalogBackupStatusRows: View {
    @Bindable var model: DashboardModel

    var body: some View {
        LabeledContent("Last backup") {
            Text(DashboardModel.catalogBackupDescription(model.catalogBackupSummary))
                .foregroundStyle(.secondary)
        }
        .onAppear { model.refreshCatalogBackupSummary() }
        if let warning = DashboardModel.catalogBackupWarning(model.catalogBackupSummary) {
            Label {
                Text(warning)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            .foregroundStyle(.orange)
        }
        HStack {
            Spacer()
            Button("Restore Face Labels…") { model.restoreFaceLabelsFromBackup() }
            Button(model.isBackingUpCatalog ? "Backing Up…" : "Back Up Now") {
                model.backUpCatalogNow()
            }
            .disabled(model.isBackingUpCatalog)
        }
    }
}

struct PathSettingRow: View {
    var title: String
    @Binding var path: String
    var choose: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                PathAutocompleteField(path: $path, placeholder: "Choose a path")
                    .frame(minWidth: 220)
                Button("Choose…", action: choose)
            }
        }
    }
}

struct LocationSettingsSection: View {
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
            HStack {
                Spacer()
                Button(addTitle) { model.addConfiguredLocation(role: role) }
            }
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
                Button("Remove Location", systemImage: "trash", role: .destructive) {
                    model.removeConfiguredLocation(currentLocation)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove this location from the list — no files change")
                .disabled(!canRemove)
            }
            PathAutocompleteField(
                path: Binding(
                    get: { currentLocation.path },
                    set: { model.setConfiguredLocationPath(location, to: $0) }
                ),
                placeholder: "Choose a folder"
            )
        }
    }
}

/// Opens the same typed-DELETE sheet the Trash window uses, so there is
/// one permanent-delete path in the app. The sheet's result stays under
/// the row.
struct EmptyTrashSettingsRow: View {
    @Bindable var model: DashboardModel
    @State private var showEmptyTrash = false
    @State private var message: String?

    var body: some View {
        LabeledContent {
            Button("Empty Trash…", role: .destructive) {
                showEmptyTrash = true
            }
            .disabled(model.isBusy)
        } label: {
            Text("Empty Trash")
            Text(message ?? "Permanently deletes everything in the _Trash folders after you type DELETE.")
        }
        .sheet(isPresented: $showEmptyTrash) {
            EmptyTrashSheet(model: model, fileCount: nil, byteCount: nil) { summary in
                message = summary
            }
        }
    }
}
