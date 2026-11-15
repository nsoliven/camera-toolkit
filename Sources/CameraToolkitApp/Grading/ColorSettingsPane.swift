import AppKit
import CameraToolkitCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Imported LUTs were added, renamed or removed (Settings › Color).
    static let cameraToolkitLUTsChanged = Notification.Name("CameraToolkit.LUTsChanged")
}

enum GradingStorage {
    /// The one LUT library: the grading model and Settings share it.
    static let library = LUTLibrary(folder: LUTLibrary.defaultFolder(
        applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    ))
}

/// Settings › Color: the default look per log profile, imported LUTs, and
/// whether graded copies go along with Sync to NAS (and so into Immich).
struct ColorSettingsPane: View {
    @Bindable var model: DashboardModel
    var library: LUTLibrary = GradingStorage.library
    @State private var luts: [ImportedLUT] = []
    @State private var importProblems: [String] = []

    var body: some View {
        Form {
            Section {
                ForEach(LogProfile.allCases, id: \.self) { profile in
                    Picker(profile.displayName, selection: defaultBinding(for: profile)) {
                        Text("None — show it flat").tag(GradeLook?.none)
                        if profile.hasBuiltInConversion {
                            Text("Rec.709 (built in)").tag(GradeLook?.some(.rec709))
                        }
                        ForEach(luts) { lut in
                            Text(lut.name).tag(GradeLook?.some(.lut(lut.id)))
                        }
                    }
                }
            } header: {
                Text("Default Looks")
            } footer: {
                Text("A log clip with no grade of its own is shown, played and rendered with its profile's default — new clips get it as soon as they appear. Sony S-Log3 is read from the camera's XML; DJI files don't say when they are D-Log M, so mark those clips from their Color menu. Originals are never changed.")
            }

            Section {
                if luts.isEmpty {
                    Text("No LUTs yet. Import Sony's official LUTs, DJI's D-Log M to Rec.709 LUT, or any creative .cube look.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(luts) { lut in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lut.name)
                                Text(lut.cubeSize.map { "3D · \($0)-point" } ?? "1D")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                try? library.remove(id: lut.id)
                                reload(notify: true)
                            }
                            .buttonStyle(.borderless)
                            .help("Take it off the list (the copy goes to the Trash). Clips using it show without a look until it is imported again.")
                        }
                    }
                }
                HStack {
                    Button("Import LUTs…", systemImage: "square.and.arrow.down") { importLUTs() }
                    Spacer()
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([library.folder])
                    }
                    .buttonStyle(.borderless)
                }
                ForEach(importProblems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Imported LUTs")
            } footer: {
                Text("Each .cube file is checked, then copied into Camera Toolkit's own folder in Application Support. 1D and 3D LUTs, with or without DOMAIN_MIN/MAX, are supported.")
            }

            Section {
                Toggle("Send graded versions of log videos to Immich", isOn: Binding(
                    get: { model.configuration.renderGradedCopiesBeforeSync },
                    set: { value in model.updateConfiguration { $0.renderGradedCopiesBeforeSync = value } }
                ))
            } header: {
                Text("Immich")
            } footer: {
                Text("Before each Sync to NAS, Camera Toolkit renders a Rec.709 copy (with its look) of every graded log clip in the events being synced, into the event's Edited/\(GradedRenderNaming.folderName) folder at its final name. Sync then carries it to the NAS, where Immich's external library picks it up next to the flat original. Nothing is uploaded and nothing is written to Immich itself.")
            }
        }
        .onAppear { reload(notify: false) }
        .onReceive(NotificationCenter.default.publisher(for: .cameraToolkitLUTsChanged)) { _ in reload(notify: false) }
    }

    private func defaultBinding(for profile: LogProfile) -> Binding<GradeLook?> {
        Binding(
            get: { model.configuration.gradeDefaults.look(for: profile) },
            set: { look in model.updateConfiguration { $0.gradeDefaults.setLook(look, for: profile) } }
        )
    }

    private func reload(notify: Bool) {
        luts = library.list()
        if notify { NotificationCenter.default.post(name: .cameraToolkitLUTsChanged, object: nil) }
    }

    private func importLUTs() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.prompt = "Import"
        panel.message = "Choose .cube LUT files. They are copied in; the originals stay where they are."
        guard panel.runModal() == .OK else { return }
        importProblems = []
        for url in panel.urls {
            do {
                try library.importLUT(from: url)
            } catch {
                importProblems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reload(notify: true)
    }
}
