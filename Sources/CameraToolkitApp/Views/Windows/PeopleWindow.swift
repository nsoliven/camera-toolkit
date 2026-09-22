import AppKit
import AVFoundation
import CameraToolkitCore
import SwiftUI

@MainActor
final class PeopleWindowController: NSObject, NSWindowDelegate {
    static let shared = PeopleWindowController()

    private var window: NSWindow?

    func show(model: DashboardModel, workspace: EventsWorkspace) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: PeopleView(model: model, workspace: workspace))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "People"
        window.identifier = NSUserInterfaceItemIdentifier("CameraToolkitPeopleWindow")
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 880, height: 620))
        window.minSize = NSSize(width: 640, height: 420)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

/// The face review surface: named people, auto-formed groups waiting for a
/// name, and the proposed matches that need a yes/no. Everything here is
/// catalog data — no photo is ever written to.
private struct PeopleView: View {
    @Bindable var model: DashboardModel
    @Bindable var workspace: EventsWorkspace

    @State private var tab = Tab.people
    @State private var roster: [FacePerson] = []
    @State private var groups: [FacePerson] = []
    @State private var unsure: [FaceRecord] = []
    @State private var expanded: Set<UUID> = []
    @State private var naming: NamingRequest?
    @State private var junkTarget: FacePerson?
    /// Shows the Clear Face Scan confirmation sheet.
    @State private var clearingFaceIndex = false
    /// The scan grades stored on `face_photos` — the footer's quality list.
    @State private var scanGrades: [FaceScanGrade] = []
    /// The person opened into the full detection grid.
    @State private var detail: FacePerson?
    /// The face whose source photo fills the preview overlay.
    @State private var previewFace: FaceRecord?
    /// Filters the people/group/unsure lists.
    @State private var searchText = ""
    /// Filters the open detail grid — separate state so a list query does
    /// not hide detections when a person opens.
    @State private var gridSearchText = ""

    private enum Tab: String, CaseIterable, Identifiable {
        case people = "People"
        case groups = "New Groups"
        case unsure = "Unsure"
        var id: String { rawValue }
    }

    private struct NamingRequest: Identifiable {
        var id: UUID { person.id }
        var person: FacePerson
        var title: String
        var isGroup: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let detail {
                PersonFacesGrid(
                    workspace: workspace,
                    person: detail,
                    needle: OrganizeSearch.needle(gridSearchText),
                    onBack: { self.detail = nil },
                    onOpenPhoto: { previewFace = $0 }
                )
            } else {
                Picker("Review", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text("\(tab.rawValue) \(tabCount(tab))").tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                switch tab {
                case .people: rosterList
                case .groups: groupsList
                case .unsure: unsureList
                }
            }

            Divider()
            statusBar
        }
        .overlay {
            if let previewFace {
                FacePhotoPreviewOverlay(face: previewFace) {
                    self.previewFace = nil
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear(perform: reload)
        .onChange(of: workspace.facesRevision) { reload() }
        .sheet(isPresented: $clearingFaceIndex) {
            ClearFaceScanSheet(
                counts: workspace.faceIndexCounts(),
                onCancel: { clearingFaceIndex = false },
                onClear: {
                    clearingFaceIndex = false
                    workspace.clearFaceIndex()
                }
            )
        }
        .sheet(item: $naming) { request in
            NamePersonSheet(
                title: request.title,
                initialName: request.isGroup ? "" : request.person.name,
                onCancel: { naming = nil },
                onSave: { name in
                    naming = nil
                    if request.isGroup {
                        workspace.nameGroup(request.person.id, name: name)
                    } else {
                        workspace.renamePerson(request.person.id, name: name)
                    }
                }
            )
        }
        .alert(
            "Remove “\(junkTarget?.name ?? "")”?",
            isPresented: Binding(get: { junkTarget != nil }, set: { if !$0 { junkTarget = nil } })
        ) {
            Button("Remove Group", role: .destructive) {
                if let junkTarget { workspace.junkGroup(junkTarget.id) }
                junkTarget = nil
            }
            Button("Cancel", role: .cancel) { junkTarget = nil }
        } message: {
            Text("The group and its face detections are dropped from the index. Photos are untouched, and a rescan will not bring them back at the same quality.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("People")
                    .font(.headline)
                Text(workspace.faceEngineInstalled
                    ? "Faces are matched on-device. Name a group and its faces become that person everywhere."
                    : "Face engine not installed — run \(FaceSidecarInstallation.setupCommand) once on this Mac.")
                    .font(.caption)
                    .foregroundStyle(workspace.faceEngineInstalled ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer()
            searchField
            Button {
                workspace.rematchFaces()
            } label: {
                Label("Re-match", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.isBusy || (roster.isEmpty && groups.isEmpty && unsure.isEmpty))
            .help("Match stored faces to named people and rebuild the unnamed groups — a group that collected different people can split. Reads the catalog's stored vectors only: no rescan, and no files or events move.")
            Button {
                clearingFaceIndex = true
            } label: {
                Label("Clear Face Scan…", systemImage: "trash")
            }
            .disabled(model.isBusy)
            .help("Throw away the face index so a scan can start over. Catalog rows only — no file is touched.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// One field serves both contexts: in the lists it edits `searchText`,
    /// inside a person's grid it edits `gridSearchText` — so a list query
    /// never hides detections after the grid opens.
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                detail == nil ? "Search people" : "Search photos",
                text: detail == nil ? $searchText : $gridSearchText
            )
            .textFieldStyle(.plain)
            .frame(width: 150)
            if !activeQuery.isEmpty {
                Button {
                    activeQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .font(.callout)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(detail == nil
            ? "Filter people, groups, and matches by name or photo file name"
            : "Filter this grid by photo file name")
    }

    private var activeQuery: String {
        get { detail == nil ? searchText : gridSearchText }
        nonmutating set {
            if detail == nil {
                searchText = newValue
            } else {
                gridSearchText = newValue
            }
        }
    }

    /// Normalized list query — empty means "show everything".
    private var needle: String {
        OrganizeSearch.needle(searchText)
    }

    /// A person or group matches when its name hits or when one of its
    /// member detections sits on a photo whose file name hits — the owner's
    /// "find every face of Eileen" path. Catalog data only.
    private func personMatches(_ person: FacePerson) -> Bool {
        OrganizeSearch.matches(person.name, needle: needle)
            || workspace.faces(for: person.id).contains {
                OrganizeSearch.matches(facePhotoName($0), needle: needle)
            }
    }

    private var filteredRoster: [FacePerson] {
        guard !needle.isEmpty else { return roster }
        return roster.filter(personMatches)
    }

    private var filteredGroups: [FacePerson] {
        guard !needle.isEmpty else { return groups }
        return groups.filter(personMatches)
    }

    private var filteredUnsure: [FaceRecord] {
        guard !needle.isEmpty else { return unsure }
        return unsure.filter {
            OrganizeSearch.matches(facePhotoName($0), needle: needle)
                || OrganizeSearch.matches(personName(of: $0), needle: needle)
        }
    }

    private func personName(of face: FaceRecord) -> String? {
        face.personID.flatMap { try? workspace.faceStore.person($0) }?.name
    }

    private func tabCount(_ tab: Tab) -> String {
        switch tab {
        case .people: "\(roster.count)"
        case .groups: "\(groups.count)"
        case .unsure: "\(unsure.count)"
        }
    }

    // MARK: - People (roster)

    @ViewBuilder
    private var rosterList: some View {
        if roster.isEmpty {
            ContentUnavailableView(
                "No Named People Yet",
                systemImage: "person.crop.rectangle.stack",
                description: Text("Run a face scan on an Unsorted folder, then name a group in New Groups.")
            )
            .frame(maxHeight: .infinity)
        } else if filteredRoster.isEmpty {
            ContentUnavailableView(
                "No Matches",
                systemImage: "magnifyingglass",
                description: Text("No people or photo names match “\(searchText)”.")
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(filteredRoster) { person in
                    personRow(person)
                }
            }
            .listStyle(.inset)
        }
    }

    private func personRow(_ person: FacePerson) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                PersonCover(workspace: workspace, personID: person.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(.headline)
                    Text("\(person.faceCount) detection\(person.faceCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    detail = person
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .buttonStyle(.borderless)
                .help("Show all \(person.faceCount) detections in a grid")
                Button {
                    toggleExpanded(person.id)
                } label: {
                    Image(systemName: expanded.contains(person.id) ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                .help("Show member faces")
                Menu("Merge Into") {
                    ForEach(roster.filter { $0.id != person.id }) { target in
                        Button(target.name) { workspace.mergePerson(person.id, into: target.id) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(roster.count < 2)
                Button("Rename…") {
                    naming = NamingRequest(person: person, title: "Rename \(person.name)", isGroup: false)
                }
                Button("Remove from Roster") {
                    workspace.demotePerson(person.id)
                }
                .help("Faces stay grouped as an unnamed cluster under New Groups")
            }
            if expanded.contains(person.id) {
                memberStrip(person)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - New Groups (unnamed clusters)

    @ViewBuilder
    private var groupsList: some View {
        if groups.isEmpty {
            ContentUnavailableView(
                "No New Groups",
                systemImage: "person.2.crop.square.stack",
                description: Text("Unmatched faces cluster here after a face scan. Name the ones that matter.")
            )
            .frame(maxHeight: .infinity)
        } else if filteredGroups.isEmpty {
            ContentUnavailableView(
                "No Matches",
                systemImage: "magnifyingglass",
                description: Text("No groups or photo names match “\(searchText)”.")
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(filteredGroups) { group in
                    groupRow(group)
                }
            }
            .listStyle(.inset)
        }
    }

    private func groupRow(_ group: FacePerson) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                PersonCover(workspace: workspace, personID: group.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.headline)
                    Text("\(group.faceCount) detection\(group.faceCount == 1 ? "" : "s") · grouped automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    detail = group
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .buttonStyle(.borderless)
                .help("Show all \(group.faceCount) detections in a grid")
                Button {
                    toggleExpanded(group.id)
                } label: {
                    Image(systemName: expanded.contains(group.id) ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                .help("Show member faces")
                Menu("Merge Into") {
                    ForEach(roster) { target in
                        Button(target.name) { workspace.mergePerson(group.id, into: target.id) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(roster.isEmpty)
                Button("Name…") {
                    naming = NamingRequest(person: group, title: "Name \(group.name)", isGroup: true)
                }
                .help("Adds this person to the roster and re-matches every stored face")
                Button("Junk…", role: .destructive) {
                    junkTarget = group
                }
                .help("Drop this cluster — statues, strangers, duplicates of nothing")
            }
            if expanded.contains(group.id) {
                memberStrip(group)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Unsure (proposed matches)

    @ViewBuilder
    private var unsureList: some View {
        if unsure.isEmpty {
            ContentUnavailableView(
                "Nothing to Confirm",
                systemImage: "checkmark.circle",
                description: Text("Proposed matches land here after a face scan. Confirm the right ones and the model learns nothing extra — it just keeps them frozen.")
            )
            .frame(maxHeight: .infinity)
        } else if filteredUnsure.isEmpty {
            ContentUnavailableView(
                "No Matches",
                systemImage: "magnifyingglass",
                description: Text("No proposed matches or photo names match “\(searchText)”.")
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(filteredUnsure) { face in
                    unsureRow(face)
                }
            }
            .listStyle(.inset)
        }
    }

    private func unsureRow(_ face: FaceRecord) -> some View {
        let personName = personName(of: face) ?? "this person"
        return HStack(spacing: 10) {
            FaceCropView(face: face)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text("Is this \(personName)?")
                    .font(.headline)
                Text("\(facePhotoName(face)) · match \(Int((face.matchScore ?? 0) * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Not \(personName)") {
                workspace.rejectFace(face.id)
            }
            .help("Removes the face — it lands in another group and can never be matched to \(personName) again")
            Button("Confirm") {
                workspace.confirmFace(face.id)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Freezes this face as \(personName) — confirmed faces are never reclassified")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Shared pieces

    private var statusBar: some View {
        HStack {
            Text("\(roster.count) named · \(groups.count) unnamed group\(groups.count == 1 ? "" : "s") · \(unsure.count) to confirm")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(FaceScanSummaryText.quality(scanGrades)) · faces only read photos; nothing is written to media")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func memberStrip(_ person: FacePerson) -> some View {
        let all = workspace.faces(for: person.id)
        let members = Array(all.prefix(12))
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(members) { face in
                    FaceCropView(face: face)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            if face.id == person.coverFaceID {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .padding(2)
                                    .background(.black.opacity(0.6), in: Circle())
                                    .foregroundStyle(.yellow)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                    .padding(1)
                            }
                        }
                        .overlay {
                            if face.state == .proposed {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.orange, lineWidth: 2)
                            }
                        }
                        .onTapGesture(count: 2) { previewFace = face }
                        .contextMenu {
                            FaceContextMenu(workspace: workspace, face: face, person: person, onOpenPhoto: { previewFace = $0 })
                        }
                        .help("\(facePhotoName(face)) · \(face.state.rawValue) · double-click opens the photo")
                }
                if all.count > members.count {
                    Button {
                        detail = person
                    } label: {
                        Text("All \(all.count) ›")
                            .font(.caption.weight(.semibold))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.borderless)
                    .help("Show every detection of \(person.name) in a grid")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func facePhotoName(_ face: FaceRecord) -> String {
        face.photoPath.isEmpty ? face.photoID : (face.photoPath as NSString).lastPathComponent
    }

    private func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    private func reload() {
        let snapshot = workspace.faceSnapshot()
        roster = snapshot.roster
        groups = snapshot.groups
        unsure = snapshot.unsure
        scanGrades = workspace.storedFaceScanGrades()
    }
}

/// The People window footer's index-grade text: the scan qualities the
/// catalog actually stores, in the scan sheet's words — or a plain
/// "nothing scanned" note when the index is empty. Pure so tests pin the
/// wording without opening a window.
enum FaceScanSummaryText {
    /// "Medium quality" for one grade, "Low, Medium quality" when the
    /// index mixes passes, "No face scan stored" when it holds nothing.
    static func quality(_ grades: [FaceScanGrade]) -> String {
        let names = grades.compactMap(\.displayName)
        guard !names.isEmpty else { return "No face scan stored" }
        return "\(names.joined(separator: ", ")) quality"
    }
}

/// Confirmation for throwing away the face index: leads with the live
/// counts of what will be removed and states plainly that only the four
/// face tables' catalog rows go — nothing on disk is touched. A sheet,
/// not a typed-token gate: this is not media trash.
private struct ClearFaceScanSheet: View {
    let counts: FaceIndexCounts
    let onCancel: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clear Face Scan")
                .font(.title3.bold())
            VStack(alignment: .leading, spacing: 5) {
                Text("This removes the face index stored in the local catalog:")
                VStack(alignment: .leading, spacing: 2) {
                    Text("· \(counts.scannedPhotos) scanned photo\(counts.scannedPhotos == 1 ? "" : "s")")
                    Text("· \(counts.faces) detected face\(counts.faces == 1 ? "" : "s")")
                    Text("· \(counts.namedPeople) named \(counts.namedPeople == 1 ? "person" : "people")")
                    Text("· \(counts.unnamedGroups) unnamed group\(counts.unnamedGroups == 1 ? "" : "s")")
                }
                .font(.callout.weight(.semibold))
                .padding(.leading, 8)
            }
            Text("Only catalog rows are deleted — face_photos, faces, people, face_templates, and face_rejections. Photos, RAW, video, XMP sidecars, event assignments, events, and .Camera Toolkit/_Trash are not touched. Nothing is moved or deleted on disk.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Afterward the next face scan will not skip those files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Clear Face Scan", role: .destructive, action: onClear)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Small name prompt shared by Rename and Name-group.
private struct NamePersonSheet: View {
    let title: String
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var name: String
    @FocusState private var focused: Bool

    init(title: String, initialName: String, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.title = title
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.bold())
            TextField("Name", text: $name, prompt: Text("Who is this?"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { focused = true }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}

/// A person's cover crop, loaded lazily so the list does not deserialize
/// every member embedding up front.
private struct PersonCover: View {
    let workspace: EventsWorkspace
    let personID: UUID
    @State private var face: FaceRecord?

    var body: some View {
        Group {
            if let face {
                FaceCropView(face: face)
            } else {
                Image(systemName: "person.crop.square")
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .background(Color(nsColor: .controlColor), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear(perform: load)
        .onChange(of: workspace.facesRevision) { load() }
    }

    private func load() {
        face = (try? workspace.faceStore.coverFace(personID: personID)) ?? nil
    }
}

/// The stored aligned JPEG crop of one detected face.
private struct FaceCropView: View {
    let face: FaceRecord

    var body: some View {
        if let data = face.crop, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
        } else {
            Image(systemName: "person.crop.square")
                .resizable()
                .scaledToFit()
                .padding(10)
                .foregroundStyle(.secondary)
        }
    }
}

/// The face context menu shared by the member strip and the detail grid —
/// photo navigation plus review actions. All writes hit the catalog only.
private struct FaceContextMenu: View {
    let workspace: EventsWorkspace
    let face: FaceRecord
    let person: FacePerson
    let onOpenPhoto: (FaceRecord) -> Void

    var body: some View {
        if !face.photoPath.isEmpty {
            Button("Open Photo") { onOpenPhoto(face) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: face.photoPath)])
            }
            Divider()
        }
        if face.id == person.coverFaceID {
            Text("Cover Photo")
        } else {
            Button("Set as Cover") { workspace.setCoverFace(face.id, for: person.id) }
        }
        if person.isRoster {
            Button("Pin as Match Reference") {
                workspace.pinTemplate(face.id, for: person.id)
            }
            Button("Not \(person.name)") {
                workspace.rejectFace(face.id)
            }
        } else {
            Button("Not This Group") {
                workspace.rejectFace(face.id)
            }
        }
    }
}

/// Every detection of one person or group as a scrollable grid — what the
/// "N detections" count expands into. Single-click selects, double-click
/// opens the source photo, right-click offers cover and review actions.
private struct PersonFacesGrid: View {
    let workspace: EventsWorkspace
    /// Normalized query narrowing the grid by photo file name; empty shows
    /// every detection.
    let needle: String
    let onBack: () -> Void
    let onOpenPhoto: (FaceRecord) -> Void

    @State private var person: FacePerson
    @State private var faces: [FaceRecord] = []
    @State private var selectedID: UUID?

    init(
        workspace: EventsWorkspace,
        person: FacePerson,
        needle: String,
        onBack: @escaping () -> Void,
        onOpenPhoto: @escaping (FaceRecord) -> Void
    ) {
        self.workspace = workspace
        self.needle = needle
        self.onBack = onBack
        self.onOpenPhoto = onOpenPhoto
        _person = State(initialValue: person)
    }

    /// Distinct source files the detections came from — several faces of
    /// the same person can sit in one photo.
    private var photoCount: Int {
        Set(faces.map(\.photoID)).count
    }

    /// The detections surviving the photo-name query. Filtering happens on
    /// the already-loaded face rows — no disk or catalog round-trips.
    private var visibleFaces: [FaceRecord] {
        guard !needle.isEmpty else { return faces }
        return faces.filter { OrganizeSearch.matches(photoName($0), needle: needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            gridHeader
            Divider()
            if faces.isEmpty {
                ContentUnavailableView(
                    "No Detections",
                    systemImage: "person.crop.rectangle",
                    description: Text("Every face counted here has been moved or removed.")
                )
                .frame(maxHeight: .infinity)
            } else if visibleFaces.isEmpty {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "magnifyingglass",
                    description: Text("No detection's photo name matches the search.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 84, maximum: 120), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(visibleFaces) { face in
                            cell(face)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: workspace.facesRevision) { reload() }
    }

    private var gridHeader: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
            }
            PersonCover(workspace: workspace, personID: person.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.headline)
                Text(needle.isEmpty
                    ? "\(faces.count) detection\(faces.count == 1 ? "" : "s") in \(photoCount) photo\(photoCount == 1 ? "" : "s")"
                    : "\(visibleFaces.count) of \(faces.count) detections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Double-click opens the photo · right-click for actions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func cell(_ face: FaceRecord) -> some View {
        Color(nsColor: .controlColor)
            .aspectRatio(1, contentMode: .fit)
            .overlay { FaceCropView(face: face) }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if face.id == person.coverFaceID {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .padding(3)
                        .background(.black.opacity(0.6), in: Circle())
                        .foregroundStyle(.yellow)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(3)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange, lineWidth: 2)
                    .opacity(face.state == .proposed ? 1 : 0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2.5)
                    .opacity(face.id == selectedID ? 1 : 0)
            }
            .onTapGesture { selectedID = face.id }
            .simultaneousGesture(TapGesture(count: 2).onEnded { onOpenPhoto(face) })
            .contextMenu {
                FaceContextMenu(workspace: workspace, face: face, person: person, onOpenPhoto: onOpenPhoto)
            }
            .help("\(photoName(face)) · \(face.state.rawValue)")
    }

    private func photoName(_ face: FaceRecord) -> String {
        face.photoPath.isEmpty ? face.photoID : (face.photoPath as NSString).lastPathComponent
    }

    private func reload() {
        guard let fresh = workspace.person(person.id) else {
            // The person was merged or junked while open — return to the list.
            onBack()
            return
        }
        person = fresh
        faces = workspace.faces(for: person.id)
        if let selectedID, !faces.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }
}

/// Full-size preview of the photo a detection lives on. Stills decode
/// through `TileImageLoader` into the shared zoom canvas with the detected
/// box marked; clips probe through `VideoPreviewSupport` and play in the
/// AppKit `AVPlayerView` wrapper — SwiftUI's `VideoPlayer` aborts this
/// binary, so it is never used here. Read-only: nothing is written back.
private struct FacePhotoPreviewOverlay: View {
    let face: FaceRecord
    let onDismiss: () -> Void

    @State private var image: CGImage?
    @State private var failed = false
    @State private var videoPlayer: AVPlayer?
    /// nil = still probing, false = can't play in-app.
    @State private var videoPlayable: Bool?
    /// Zoomed or panned past fit — the face box only makes sense at fit.
    @State private var zoomedIn = false
    @FocusState private var isFocused: Bool

    private var url: URL? {
        face.photoPath.isEmpty ? nil : URL(fileURLWithPath: face.photoPath)
    }

    private var isVideo: Bool {
        guard let url else { return false }
        return OrganizeFileClassifier.kind(forExtension: url.pathExtension) == .video
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.95)
            VStack(spacing: 10) {
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(isVideo
                    ? "Space play/pause · O open · Esc close"
                    : "Click zoom · drag pan · + − 0 zoom · O open · Esc close")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(16)
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .escape:
                onDismiss()
                return .handled
            case .space:
                if isVideo {
                    togglePlayback()
                } else {
                    onDismiss()
                }
                return .handled
            default:
                if press.modifiers.isEmpty, press.characters.lowercased() == "o", let url {
                    PhotomatorLauncher.open(url)
                    return .handled
                }
                return .ignored
            }
        }
        .task(id: face.id) { await load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(url?.lastPathComponent ?? face.photoID)
                    .font(.headline)
                    .foregroundStyle(.white)
                if let url {
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let url {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button {
                    PhotomatorLauncher.open(url)
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                .help("Open in Photomator, or the default app when it is not installed")
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    @ViewBuilder
    private var content: some View {
        if isVideo {
            videoPane
        } else {
            InteractivePreviewCanvas(
                image: image,
                isLoading: !failed,
                file: url,
                unavailableTitle: "No Preview",
                unavailableDescription: "Camera Toolkit could not decode a preview for this file.",
                onZoomChange: { zoom in
                    zoomedIn = zoom > 1.02
                }
            )
            .overlay { faceBox }
        }
    }

    /// The detection's box drawn on the fitted photo — hidden once the user
    /// zooms, since the canvas pans the image under it.
    private var faceBox: some View {
        GeometryReader { geometry in
            if let image, !zoomedIn {
                let fit = fittedRect(
                    imageSize: CGSize(width: image.width, height: image.height),
                    in: geometry.size
                )
                let rect = CGRect(
                    x: fit.minX + face.box.x * fit.width,
                    y: fit.minY + (1 - face.box.y - face.box.height) * fit.height,
                    width: face.box.width * fit.width,
                    height: face.box.height * fit.height
                )
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.yellow, lineWidth: 3)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .allowsHitTesting(false)
    }

    /// Where the image sits inside the canvas at fit — mirrors the canvas's
    /// own padding and centering so the box tracks the photo exactly.
    private func fittedRect(imageSize: CGSize, in canvasSize: CGSize) -> CGRect {
        let scale = PreviewZoomMath.fitScale(imageSize: imageSize, canvasSize: canvasSize)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (canvasSize.width - size.width) / 2,
            y: (canvasSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Real playback via AVKit's `AVPlayerView` (wrapped by
    /// `VideoPreviewPane`). A clip the probe can't prove playable keeps its
    /// poster with a can't-play note and Finder/Open fallbacks.
    private var videoPane: some View {
        ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .opacity(videoPlayer == nil ? 1 : 0)
            }
            if let videoPlayer {
                VideoPreviewPane(player: videoPlayer)
            } else if videoPlayable == false {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("This clip can't play in-app.")
                        .foregroundStyle(.white.opacity(0.8))
                    if let url {
                        HStack(spacing: 12) {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            Button("Open") {
                                PhotomatorLauncher.open(url)
                            }
                        }
                        .foregroundStyle(.white)
                    }
                }
                .padding(24)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .onDisappear {
            videoPlayer?.pause()
        }
    }

    private func togglePlayback() {
        guard let videoPlayer else { return }
        if videoPlayer.timeControlStatus == .playing {
            videoPlayer.pause()
        } else {
            videoPlayer.play()
        }
    }

    private func load() async {
        guard let url else {
            failed = true
            return
        }
        failed = false
        videoPlayer?.pause()
        videoPlayer = nil
        videoPlayable = nil
        // Drop the previous photo up front — a stale frame must never stand
        // in for a different face's file while the new decode runs.
        image = nil
        if let full = TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 2_400) {
            image = full
        } else {
            image = TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 1_280)
                ?? TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 768)
                ?? TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: 384)
            if let decoded = await TileImageLoader.shared.image(for: url, maximumPixelSize: 2_400, priority: .high),
               !Task.isCancelled {
                image = decoded
            }
            if !Task.isCancelled, image == nil {
                failed = true
            }
        }
        if isVideo {
            // The poster is already up; now prove the clip can actually play
            // before handing it to AVPlayer. The probe is bounded, so an
            // unopenable codec or a stalled source ends on the can't-play
            // affordances instead of a dead spinner.
            let player = await VideoPreviewSupport.readyPlayer(for: url)
            guard !Task.isCancelled else { return }
            if let player {
                videoPlayable = true
                videoPlayer = player
                player.play()
            } else {
                videoPlayable = false
            }
        }
    }
}
