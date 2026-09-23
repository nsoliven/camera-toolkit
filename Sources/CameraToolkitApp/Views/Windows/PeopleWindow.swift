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
            CameraToolkitWindowFactory.present(window)
            return
        }

        let window = CameraToolkitWindowFactory.make(
            .people,
            identifier: "CameraToolkitPeopleWindow",
            title: "People",
            initialContentSize: NSSize(width: 880, height: 620),
            rootView: PeopleView(model: model, workspace: workspace)
        )
        window.delegate = self
        self.window = window
        CameraToolkitWindowFactory.present(window)
    }
}

/// The face review surface: the Approved list of people the user named
/// or confirmed, and the Inbox of everything the machine classified —
/// automatic clusters and "looks like" rows that stay unapproved until
/// the user approves, merges, or junks them. Everything here is catalog
/// data — no photo is ever written to.
private struct PeopleView: View {
    @Bindable var model: DashboardModel
    @Bindable var workspace: EventsWorkspace

    @State private var approved: [FacePerson] = []
    @State private var inbox: [FacePerson] = []
    @State private var expanded: Set<UUID> = []
    /// The highlighted list row — double-click or Return opens its grid.
    @State private var selectedPersonID: UUID?
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
    /// Filters the approved and Inbox lists.
    @State private var searchText = ""
    /// Filters the open detail grid — separate state so a list query does
    /// not hide detections when a person opens.
    @State private var gridSearchText = ""

    private struct NamingRequest: Identifiable {
        var id: UUID { person.id }
        var person: FacePerson
        var title: String
        var initialName: String
        var isApproval: Bool
    }

    var body: some View {
        Group {
            if let detail {
                PersonFacesGrid(
                    workspace: workspace,
                    person: detail,
                    needle: OrganizeSearch.needle(gridSearchText),
                    onBack: { self.detail = nil },
                    onOpenPhoto: { previewFace = $0 }
                )
            } else {
                reviewList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                if !workspace.faceEngineInstalled {
                    Label {
                        Text("Face engine not installed — run \(FaceSidecarInstallation.setupCommand) once on this Mac.")
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 7)
                }
                statusBar
            }
            .background(.bar)
        }
        .overlay {
            if let previewFace {
                FacePhotoPreviewOverlay(face: previewFace) {
                    self.previewFace = nil
                }
            }
        }
        .navigationTitle(detail.map(displayName) ?? "People")
        .navigationSubtitle(windowSubtitle)
        .searchable(
            text: Binding(get: { activeQuery }, set: { activeQuery = $0 }),
            placement: .toolbar,
            prompt: detail == nil ? "Search people" : "Search photos"
        )
        .toolbar { toolbar }
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
                initialName: request.initialName,
                onCancel: { naming = nil },
                onSave: { name in
                    naming = nil
                    if request.isApproval {
                        workspace.nameGroup(request.person.id, name: name)
                    } else {
                        workspace.renamePerson(request.person.id, name: name)
                    }
                }
            )
        }
        .alert(
            "Remove “\(junkTarget.map(displayName) ?? "")”?",
            isPresented: Binding(get: { junkTarget != nil }, set: { if !$0 { junkTarget = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let junkTarget { workspace.junkGroup(junkTarget.id) }
                junkTarget = nil
            }
            Button("Cancel", role: .cancel) { junkTarget = nil }
        } message: {
            Text("The Inbox row and its face detections are dropped from the index. Photos are untouched, and a rescan will not bring them back at the same quality.")
        }
    }

    /// The list's one-line explanation, or the setup command when the face
    /// engine is missing. Inside a person's grid the grid says what it shows.
    private var windowSubtitle: String {
        guard workspace.faceEngineInstalled else {
            return "Face engine not installed"
        }
        if detail != nil {
            return "Double-click opens the photo · right-click for actions"
        }
        return "A scan never adds faces to Approved — its clusters and lookalikes wait in the Inbox."
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if detail != nil {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") {
                    detail = nil
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to People (⌘[)")
            }
        }
        ToolbarItem {
            Button {
                workspace.rematchFaces()
            } label: {
                Label("Re-match", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
            }
            .disabled(model.isBusy || (approved.isEmpty && inbox.isEmpty))
            .help("Re-file stored faces into the Inbox — lookalikes beside the approved people they resemble, strangers into fresh clusters. Reads the catalog's stored vectors only: no rescan, and no files or events move.")
        }
        ToolbarItem {
            // The catalog wipe sits one menu deeper than Re-match, so it is
            // never a single stray click away.
            Menu {
                Button("Clear Face Scan…", systemImage: "trash", role: .destructive) {
                    clearingFaceIndex = true
                }
                .disabled(model.isBusy)
                .help("Throw away the face index so a scan can start over. Catalog rows only — no file is touched.")
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("More face index actions")
        }
    }

    /// One search field serves both contexts: in the lists it edits
    /// `searchText`, inside a person's grid it edits `gridSearchText` — so a
    /// list query never hides detections after the grid opens.
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

    /// What the row is called: a suggestion row wears its target's name
    /// under "Looks like".
    private func displayName(_ person: FacePerson) -> String {
        person.suggestedPersonName.map { "Looks like \($0)" } ?? person.name
    }

    /// A person or Inbox row matches when its name hits — a suggestion row
    /// also matches its target's name — or when one of its member
    /// detections sits on a photo whose file name hits. Catalog data only.
    private func personMatches(_ person: FacePerson) -> Bool {
        OrganizeSearch.matches(person.name, needle: needle)
            || OrganizeSearch.matches(person.suggestedPersonName ?? "", needle: needle)
            || workspace.faces(for: person.id).contains {
                OrganizeSearch.matches(facePhotoName($0), needle: needle)
            }
    }

    private var filteredApproved: [FacePerson] {
        guard !needle.isEmpty else { return approved }
        return approved.filter(personMatches)
    }

    private var filteredInbox: [FacePerson] {
        guard !needle.isEmpty else { return inbox }
        return inbox.filter(personMatches)
    }

    // MARK: - The two lists

    @ViewBuilder
    private var reviewList: some View {
        if approved.isEmpty && inbox.isEmpty {
            ContentUnavailableView(
                "No People Yet",
                systemImage: "person.crop.rectangle.stack",
                description: Text("Run a face scan on an Unsorted folder — the clusters and lookalikes it finds land in the Inbox.")
            )
            .frame(maxHeight: .infinity)
        } else if filteredApproved.isEmpty && filteredInbox.isEmpty {
            ContentUnavailableView(
                "No Matches",
                systemImage: "magnifyingglass",
                description: Text("No people or photo names match “\(searchText)”.")
            )
            .frame(maxHeight: .infinity)
        } else {
            List(selection: $selectedPersonID) {
                if !filteredApproved.isEmpty {
                    Section {
                        ForEach(filteredApproved) { person in
                            personRow(person)
                        }
                    } header: {
                        Text("Approved · \(filteredApproved.count)")
                    }
                }
                if !filteredInbox.isEmpty {
                    Section {
                        ForEach(filteredInbox) { person in
                            personRow(person)
                        }
                    } header: {
                        Text("Inbox · \(filteredInbox.count)")
                    } footer: {
                        Text("The machine's guesses — approve, merge, or junk. Nothing here names an event until you do.")
                    }
                }
            }
            .listStyle(.inset)
            // Double-click (or Return) opens the full detection grid; the
            // context menu carries every row action.
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let person = person(in: ids) {
                    actionsMenu(for: person)
                }
            } primaryAction: { ids in
                if let person = person(in: ids) {
                    detail = person
                }
            }
        }
    }

    private func person(in ids: Set<UUID>) -> FacePerson? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return approved.first { $0.id == id } ?? inbox.first { $0.id == id }
    }

    // MARK: - Rows

    /// One person or Inbox row: a disclosure for the member strip, one
    /// visible action for Inbox rows, and everything else behind the
    /// trailing actions menu (and the same menu on right-click).
    private func personRow(_ person: FacePerson) -> some View {
        DisclosureGroup(isExpanded: expandedBinding(person.id)) {
            memberStrip(person)
        } label: {
            HStack(spacing: 10) {
                PersonCover(workspace: workspace, personID: person.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(person))
                        .font(.headline)
                    Text(person.isRoster
                        ? "\(person.faceCount) confirmed detection\(person.faceCount == 1 ? "" : "s")"
                        : inboxSubtitle(person))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !person.isRoster {
                    inboxPrimaryAction(person)
                }
                Menu {
                    actionsMenu(for: person)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Actions for \(displayName(person))")
            }
            .padding(.vertical, 4)
        }
        .tag(person.id)
    }

    /// The one inline action an Inbox row shows: merge into the approved
    /// person it resembles, else approve it under a name.
    @ViewBuilder
    private func inboxPrimaryAction(_ person: FacePerson) -> some View {
        if let targetID = person.suggestedPersonID, let target = person.suggestedPersonName {
            Button("Merge into \(target)") {
                workspace.mergePerson(person.id, into: targetID)
            }
            .buttonStyle(.bordered)
            .help("Confirms every face here onto \(target) — the faces move because you said so")
        } else {
            Button("Approve…") {
                approve(person)
            }
            .buttonStyle(.bordered)
            .help("Makes this an approved person and confirms just these faces — nothing else moves")
        }
    }

    private func actionsMenu(for person: FacePerson) -> PersonActionsMenu {
        PersonActionsMenu(
            person: person,
            displayName: displayName(person),
            approved: approved,
            onShowGrid: { detail = person },
            onToggleMembers: { toggleExpanded(person.id) },
            membersShown: expanded.contains(person.id),
            onMerge: { target in workspace.mergePerson(person.id, into: target) },
            onRename: {
                naming = NamingRequest(
                    person: person,
                    title: "Rename \(person.name)",
                    initialName: person.name,
                    isApproval: false
                )
            },
            onMoveToInbox: { workspace.demotePerson(person.id) },
            onApprove: { approve(person) },
            onJunk: { junkTarget = person }
        )
    }

    private func approve(_ person: FacePerson) {
        naming = NamingRequest(
            person: person,
            title: "Approve \(displayName(person))",
            // A "Looks like X" pile starts blank — approving it as "X" would
            // just duplicate the approved person.
            initialName: person.suggestedPersonID == nil ? person.name : "",
            isApproval: true
        )
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expanded.insert(id)
                } else {
                    expanded.remove(id)
                }
            }
        )
    }

    private func inboxSubtitle(_ person: FacePerson) -> String {
        let count = "\(person.faceCount) detection\(person.faceCount == 1 ? "" : "s")"
        if let target = person.suggestedPersonName {
            return "\(count) · resembles \(target)"
        }
        return "\(count) · grouped automatically"
    }

    // MARK: - Shared pieces

    private var statusBar: some View {
        HStack {
            Text("\(approved.count) approved · \(inbox.count) in the Inbox")
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

    /// The member strip: an approved person previews its strongest dozen
    /// detections; an Inbox person shows every member in review order —
    /// stored match score, strongest first, weak ones last — because the
    /// user opened the row specifically to see the doubtful faces.
    private func memberStrip(_ person: FacePerson) -> some View {
        let all = person.isRoster ? workspace.faces(for: person.id) : workspace.inboxFaces(for: person.id)
        let members = person.isRoster ? Array(all.prefix(12)) : all
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(members) { face in
                    FaceCropView(face: face)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .bottomLeading) {
                            if !person.isRoster {
                                scoreBadge(face)
                            }
                        }
                        .overlay {
                            if person.isRoster && face.id == person.coverFaceID {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .padding(2)
                                    .background(.black.opacity(0.6), in: Circle())
                                    .foregroundStyle(.yellow)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                    .padding(1)
                            }
                        }
                        .onTapGesture(count: 2) { previewFace = face }
                        .contextMenu {
                            FaceContextMenu(workspace: workspace, face: face, person: person, onOpenPhoto: { previewFace = $0 })
                        }
                        .help("\(facePhotoName(face))\(face.matchScore.map { " · match \(Int($0 * 100))%" } ?? "") · double-click opens the photo")
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
                    .help("Show every detection of \(displayName(person)) in a grid")
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// The stored match score on an Inbox face — the number that sorted
    /// it. A nil score is a cluster seed, shown at the top with the
    /// strongest instead of pretending to be a zero.
    private func scoreBadge(_ face: FaceRecord) -> some View {
        Text(face.matchScore.map { "\(Int($0 * 100))%" } ?? "seed")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(.black.opacity(0.65), in: Capsule())
            .foregroundStyle(.white)
            .padding(2)
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
        approved = snapshot.approved
        inbox = snapshot.inbox
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

/// Every action on one People row — the trailing actions menu and the
/// row's context menu show the same items. All writes hit the catalog only.
private struct PersonActionsMenu: View {
    let person: FacePerson
    let displayName: String
    let approved: [FacePerson]
    let onShowGrid: () -> Void
    let onToggleMembers: () -> Void
    let membersShown: Bool
    let onMerge: (UUID) -> Void
    let onRename: () -> Void
    let onMoveToInbox: () -> Void
    let onApprove: () -> Void
    let onJunk: () -> Void

    /// Approved people this row can merge into. An Inbox suggestion's own
    /// target has its dedicated item, so it is left out of the submenu.
    private var mergeTargets: [FacePerson] {
        if person.isRoster {
            return approved.filter { $0.id != person.id }
        }
        return approved.filter { $0.id != person.suggestedPersonID }
    }

    var body: some View {
        Button(person.isRoster ? "Show All Detections" : "Review All Detections", systemImage: "square.grid.2x2", action: onShowGrid)
        Button(membersShown ? "Hide Member Faces" : "Show Member Faces", systemImage: "person.crop.rectangle.stack", action: onToggleMembers)
        Divider()
        if !person.isRoster, let targetID = person.suggestedPersonID, let target = person.suggestedPersonName {
            Button("Merge into \(target)", systemImage: "arrow.triangle.merge") {
                onMerge(targetID)
            }
        }
        Menu("Merge Into", systemImage: "arrow.triangle.merge") {
            ForEach(mergeTargets) { target in
                Button(target.name) { onMerge(target.id) }
            }
        }
        .disabled(mergeTargets.isEmpty)
        if person.isRoster {
            Button("Rename…", systemImage: "pencil", action: onRename)
            Button("Move to Inbox", systemImage: "tray", action: onMoveToInbox)
                .help("Faces stay grouped as an unapproved Inbox cluster — confirmed faces keep their state")
        } else {
            Button("Approve…", systemImage: "checkmark.circle", action: onApprove)
                .help("Makes this an approved person and confirms just these faces — nothing else moves")
            Divider()
            Button("Junk…", systemImage: "xmark.bin", role: .destructive, action: onJunk)
                .help("Drop this row — statues, strangers, duplicates of nothing")
        }
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
            if let target = person.suggestedPersonName {
                Button("Confirm \(target)") {
                    workspace.confirmFace(face.id)
                }
                Button("Not \(target)") {
                    workspace.rejectFace(face.id)
                }
            } else {
                Button("Not This Group") {
                    workspace.rejectFace(face.id)
                }
            }
            if face.state != .confirmed {
                Button("Junk Face", role: .destructive) {
                    workspace.junkFace(face.id)
                }
            }
        }
    }
}

/// Every detection of one approved person or Inbox row as a scrollable
/// grid — what the "N detections" count expands into. An Inbox grid is
/// the same uncapped, score-sorted order as the strip: strongest first,
/// weak matches at the bottom. Single-click selects, double-click opens
/// the source photo, right-click offers cover and review actions.
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
        // The person's name is the window title and Back lives in the
        // toolbar; this strip only says what the grid holds.
        HStack(spacing: 10) {
            PersonCover(workspace: workspace, personID: person.id)
            Text(needle.isEmpty
                ? "\(faces.count) detection\(faces.count == 1 ? "" : "s") in \(photoCount) photo\(photoCount == 1 ? "" : "s")\(person.isRoster ? "" : " · weakest matches last")"
                : "\(visibleFaces.count) of \(faces.count) detections")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func cell(_ face: FaceRecord) -> some View {
        Color(nsColor: .controlColor)
            .aspectRatio(1, contentMode: .fit)
            .overlay { FaceCropView(face: face) }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottomLeading) {
                if !person.isRoster {
                    Text(face.matchScore.map { "\(Int($0 * 100))%" } ?? "seed")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .overlay {
                if face.id == person.coverFaceID {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .padding(3)
                        .background(.black.opacity(0.6), in: Circle())
                        .foregroundStyle(.yellow)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(3)
                }
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
            .help("\(photoName(face))\(face.matchScore.map { " · match \(Int($0 * 100))%" } ?? "")")
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
        // Approved people keep their portrait order; an Inbox row reviews
        // weakest-last by stored match score — the strip's order exactly.
        faces = person.isRoster
            ? workspace.faces(for: person.id)
            : workspace.inboxFaces(for: person.id)
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
            GlassEffectContainer {
                HStack(spacing: 8) {
                    if let url {
                        Button("Reveal in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        Button("Open", systemImage: "arrow.up.forward.app") {
                            PhotomatorLauncher.open(url)
                        }
                        .help("Open in Photomator, or the default app when it is not installed")
                    }
                    // Esc is handled by the overlay's key handler, so this
                    // button carries no shortcut of its own.
                    Button("Close", systemImage: "xmark") {
                        onDismiss()
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    .help("Close the preview (Esc)")
                }
                .buttonStyle(.glass)
            }
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
