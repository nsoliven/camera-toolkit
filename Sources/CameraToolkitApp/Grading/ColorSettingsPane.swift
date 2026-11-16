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

/// Settings › Color, in the order a picture is built: the conversion each
/// log profile gets (log → Rec.709), Sony's official conversion, the
/// default look on top, imported LUTs with what each expects, and whether
/// graded copies go along with Sync to NAS (and so into Immich).
struct ColorSettingsPane: View {
    @Bindable var model: DashboardModel
    var library: LUTLibrary = GradingStorage.library
    @State private var luts: [ImportedLUT] = []
    @State private var importProblems: [String] = []
    @State private var askSony = false
    @State private var sonyStatus: String?
    @State private var sonyBusy = false

    var body: some View {
        Form {
            Section {
                // One row per profile, written out: a grouped form lays a
                // section's last rows out wrongly when they come from a ForEach.
                conversionPicker(.sLog3SGamut3Cine)
                conversionPicker(.sLog3SGamut3)
                conversionPicker(.djiDLogM)
            } header: {
                Text("1 · Conversion (log → Rec.709)")
            } footer: {
                Text("Every log clip is first converted to a normal Rec.709 picture. Sony S-Log3 is read from the camera's XML; DJI files don't say when they are D-Log M, so mark those clips from their Color menu and import DJI's D-Log M LUT here. Originals are never changed.")
            }

            Section {
                LabeledContent("Sony S-Log3 · S-Gamut3.Cine") {
                    Text(sonyConversionStatus)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Button(sonyBusy ? "Downloading…" : "Get Sony’s Official Conversion LUTs…", systemImage: "arrow.down.circle") {
                        askSony = true
                    }
                    .disabled(sonyBusy)
                    Spacer()
                    Button("Open Sony’s LUT Page") { NSWorkspace.shared.open(SonyConversionLUTs.sourcePage) }
                        .buttonStyle(.borderless)
                }
                if let sonyStatus {
                    Text(sonyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Sony’s Conversion")
            } footer: {
                Text("Sony publishes s709 — the Rec.709 look its current cameras use, and the one an A7V's own clip metadata names — as a free LUT. Camera Toolkit downloads it from Sony when you ask (nothing of Sony's ships with the app), checks it is a zip of .cube files, imports it as the S-Log3 conversion, and uses it by default. Until then the built-in conversion, computed from Sony's published S-Log3 curve and S-Gamut3.Cine primaries, is used.")
            }

            Section {
                lookPicker(.sLog3SGamut3Cine)
                lookPicker(.sLog3SGamut3)
                lookPicker(.djiDLogM)
            } header: {
                Text("2 · Default Look (on top of the conversion)")
            } footer: {
                Text("A look is creative colour on the converted Rec.709 picture. A clip with no grade of its own gets its profile's default look; choose per clip in the grade panel (G).")
            }

            Section {
                if luts.isEmpty {
                    Text("No LUTs yet. Import conversion LUTs (log in, like Sony's or DJI's) or creative look LUTs (Rec.709 in).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(luts) { lut in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lut.name)
                                Text(lut.cubeSize.map { "3D · \($0)-point" } ?? "1D")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("Expects", selection: roleBinding(for: lut)) {
                                ForEach(roleOptions, id: \.0) { option in
                                    Text(option.1).tag(option.0)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .help("What the LUT expects in. A LUT that takes log footage (even a creative one) is a conversion and replaces step 1; a LUT that takes Rec.709 is a look and goes on top. The two can never be stacked the wrong way.")
                            Button("Remove", role: .destructive) {
                                try? library.remove(id: lut.id)
                                reload(notify: true)
                            }
                            .buttonStyle(.borderless)
                            .help("Take it off the list (the copy goes to the Trash). Clips using it fall back until it is imported again.")
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
                Text("Each .cube is checked, then copied into Camera Toolkit's folder in Application Support. What it expects is guessed from its name (SLog3, SGamut3, D-Log M… mean a conversion) — correct it here if the guess is wrong.")
            }

            Section {
                Toggle("Send graded versions of log videos to Immich", isOn: Binding(
                    get: { model.configuration.renderGradedCopiesBeforeSync },
                    set: { value in model.updateConfiguration { $0.renderGradedCopiesBeforeSync = value } }
                ))
            } header: {
                Text("Immich")
            } footer: {
                Text("Before each Sync to NAS, Camera Toolkit renders the Rec.709 copy (conversion, then look) of the log clips in the events being synced, into each event's Edited/\(GradedRenderNaming.folderName) at its final name; it asks first when there are more than a few. Sync carries the copies to the NAS, where Immich's external library picks them up next to the flat originals. Nothing is uploaded and nothing is written to Immich itself.")
            }
        }
        .onAppear { reload(notify: false) }
        .onReceive(NotificationCenter.default.publisher(for: .cameraToolkitLUTsChanged)) { _ in reload(notify: false) }
        .alert("Download Sony’s conversion LUTs?", isPresented: $askSony) {
            Button("Download from Sony") { downloadSony() }
            Button("Open Sony’s Page Instead") { NSWorkspace.shared.open(SonyConversionLUTs.sourcePage) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Camera Toolkit fetches “Slog3-S-Gamut3.Cine To s709 V200” (about 230 KB) over HTTPS from the address Sony's LUT page links:\n\n\(SonyConversionLUTs.s709Archive.absoluteString)\n\nIt checks the file is a zip of .cube LUTs, imports them as the S-Log3 conversion, and makes s709 the default. Sony's page asks for a few details before its own download button; open it instead to download there and import the file yourself.")
        }
    }

    private var sonyConversionStatus: String {
        let resolver = GradeResolver(defaults: model.configuration.gradeDefaults, lutRoles: Dictionary(luts.map { ($0.id, $0.role) }, uniquingKeysWith: { a, _ in a }))
        switch resolver.conversion(for: ClipGrade(), profile: .sLog3SGamut3Cine) {
        case .lut(let id): return luts.first { $0.id == id }?.name ?? "Sony LUT"
        case .builtIn: return "Built-in (Sony math)"
        case .none: return "Off"
        }
    }

    private func conversionPicker(_ profile: LogProfile) -> some View {
        Picker(profile.displayName, selection: conversionBinding(for: profile)) {
            ForEach(conversionOptions(for: profile), id: \.0) { option in
                Text(option.1).tag(option.0)
            }
        }
    }

    private func lookPicker(_ profile: LogProfile) -> some View {
        Picker(profile.displayName, selection: lookBinding(for: profile)) {
            ForEach(lookOptions, id: \.0) { option in
                Text(option.1).tag(option.0)
            }
        }
    }

    private func conversionOptions(for profile: LogProfile) -> [(GradeConversion, String)] {
        var options: [(GradeConversion, String)] = [(.auto, automaticName(for: profile))]
        if profile.hasBuiltInConversion { options.append((.builtIn, "Built-in (Sony math)")) }
        options += luts.filter { $0.role == .conversion(profile) }.map { (.lut($0.id), $0.name) }
        options.append((.off, "Don’t convert — show it flat"))
        return options
    }

    private var lookOptions: [(GradeLook, String)] {
        [(.none, "No look")] + BuiltInLook.allCases.map { (.builtIn($0), $0.displayName) }
            + luts.filter { $0.role == .look }.map { (.lut($0.id), $0.name) }
    }

    private var roleOptions: [(LUTRole, String)] {
        [(.look, "Look · Rec.709 in")] + LogProfile.allCases.map { (.conversion($0), "Conversion · \($0.displayName) in") }
    }

    private func automaticName(for profile: LogProfile) -> String {
        profile.hasBuiltInConversion ? "Built-in (Sony math)" : "None until a LUT is imported"
    }

    private func conversionBinding(for profile: LogProfile) -> Binding<GradeConversion> {
        Binding(
            get: { model.configuration.gradeDefaults.conversion(for: profile) },
            set: { conversion in model.updateConfiguration { $0.gradeDefaults.setConversion(conversion, for: profile) } }
        )
    }

    private func lookBinding(for profile: LogProfile) -> Binding<GradeLook> {
        Binding(
            get: { model.configuration.gradeDefaults.look(for: profile) ?? .none },
            set: { look in model.updateConfiguration { $0.gradeDefaults.setLook(look, for: profile) } }
        )
    }

    private func roleBinding(for lut: ImportedLUT) -> Binding<LUTRole> {
        Binding(
            get: { lut.role },
            set: { role in
                try? library.setRole(id: lut.id, to: role)
                // A LUT that stopped being a conversion (or a look) is no
                // longer offered where it was chosen.
                model.updateConfiguration { configuration in
                    for profile in LogProfile.allCases {
                        if configuration.gradeDefaults.conversion(for: profile) == .lut(lut.id), role != .conversion(profile) {
                            configuration.gradeDefaults.setConversion(.auto, for: profile)
                        }
                        if configuration.gradeDefaults.look(for: profile) == .lut(lut.id), role != .look {
                            configuration.gradeDefaults.setLook(nil, for: profile)
                        }
                    }
                }
                reload(notify: true)
            }
        )
    }

    private func reload(notify: Bool) {
        luts = library.list()
        if notify { NotificationCenter.default.post(name: .cameraToolkitLUTsChanged, object: nil) }
    }

    private func downloadSony() {
        sonyBusy = true
        sonyStatus = "Downloading from \(SonyConversionLUTs.s709Archive.host ?? "Sony")…"
        let library = self.library
        Task { @MainActor in
            do {
                let result = try await SonyConversionLUTs.download(into: library)
                if let s709 = result.s709 {
                    model.updateConfiguration { $0.gradeDefaults.setConversion(.lut(s709.id), for: .sLog3SGamut3Cine) }
                }
                sonyStatus = "Imported \(result.imported.map(\.name).joined(separator: ", ")) from \(SonyConversionLUTs.s709Archive.absoluteString)."
                    + (result.s709 != nil ? " S-Log3 clips now use it." : "")
            } catch {
                sonyStatus = error.localizedDescription
            }
            sonyBusy = false
            reload(notify: true)
        }
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
