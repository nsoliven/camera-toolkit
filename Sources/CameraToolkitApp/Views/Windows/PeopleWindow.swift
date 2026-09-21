import AppKit
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

            Divider()
            statusBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear(perform: reload)
        .onChange(of: workspace.facesRevision) { reload() }
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
                Text(workspace.faceModelInstalled
                    ? "Faces are matched on-device. Name a group and its faces become that person everywhere."
                    : "Face model not installed — run scripts/convert-arcface.sh once on this Mac.")
                    .font(.caption)
                    .foregroundStyle(workspace.faceModelInstalled ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                workspace.rematchFaces()
            } label: {
                Label("Re-match", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(roster.isEmpty || model.isBusy)
            .help("Compare every stored face against the current roster. No photos are re-read.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        } else {
            List {
                ForEach(roster) { person in
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
                    Text("\(person.faceCount) face\(person.faceCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
        } else {
            List {
                ForEach(groups) { group in
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
                    Text("\(group.faceCount) face\(group.faceCount == 1 ? "" : "s") · grouped automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
                Button("Junk", role: .destructive) {
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
        } else {
            List {
                ForEach(unsure) { face in
                    unsureRow(face)
                }
            }
            .listStyle(.inset)
        }
    }

    private func unsureRow(_ face: FaceRecord) -> some View {
        let personName = face.personID.flatMap { try? workspace.faceStore.person($0) }?.name ?? "this person"
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
            .help("Moves the face back into the unnamed groups")
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
            Text("LOW quality · faces only read photos; nothing is written to media")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func memberStrip(_ person: FacePerson) -> some View {
        let members = Array(workspace.faces(for: person.id).prefix(12))
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(members) { face in
                    FaceCropView(face: face)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            if face.state == .proposed {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.orange, lineWidth: 2)
                            }
                        }
                        .contextMenu {
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
                        .help("\(facePhotoName(face)) · \(face.state.rawValue)")
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
