import CameraToolkitCore
import SwiftUI

/// Face and dog boxes drawn over the photo in `StackPreviewOverlay`,
/// aligned to the canvas's reported image frame so zoom and pan keep them
/// attached.
///
/// The chrome stays hidden until the pointer comes near a box: each stored
/// detection owns invisible proximity targets — its displayed box grown by
/// `FaceHoverRegion.margin`, plus the chip strip — that reveal a solid
/// named box (confirmed), a dashed "?" box with a one-click confirm
/// (proposed), or a faint dashed box with a "+" tag button (unnamed). One
/// box shows at a time; leaving the neighborhood hides it again. The
/// targets never hit-test, so clicks still fall through to the canvas's
/// zoom and pan — only the chips' buttons consume events.
///
/// Dogs come from the pet index and behave exactly like faces; their chips
/// carry a paw and an unnamed dog's box is tinted warm instead of gray.
/// Every action hands back the box's subject, so the caller can route a
/// dog to the pet index and a face to the catalog.
struct FaceBoxesOverlay: View {
    let faces: [FaceRecord]
    var personNames: [UUID: String] = [:]
    /// Dog detections on the frame, from the pet index.
    var pets: [FaceRecord] = []
    var petNames: [UUID: String] = [:]
    /// Quarter-turns clockwise applied to the decoded image right now.
    var rotation: Int = 0
    /// The photo's displayed rect in this view's coordinates — `.zero`
    /// hides everything (no photo on screen yet).
    var imageFrame: CGRect = .zero
    var onConfirm: (FaceRecord, FaceGallerySubject) -> Void = { _, _ in }
    /// A box plus its rect in this view's space, to anchor the picker.
    var onTag: (FaceRecord, FaceGallerySubject, CGRect) -> Void = { _, _, _ in }

    /// The tint of a dog box nobody has named yet.
    static let unnamedPetColor = Color.orange

    /// One drawn box: the two indexes keep their own ids, so a box is
    /// keyed by subject and id together.
    struct Entry: Identifiable, Equatable {
        struct Key: Hashable {
            let subject: FaceGallerySubject
            let face: UUID
        }

        let face: FaceRecord
        let subject: FaceGallerySubject
        var id: Key { Key(subject: subject, face: face.id) }
    }

    /// Faces first, then dogs — the order the boxes stack in.
    static func entries(faces: [FaceRecord], pets: [FaceRecord]) -> [Entry] {
        faces.map { Entry(face: $0, subject: .people) }
            + pets.map { Entry(face: $0, subject: .pets) }
    }

    /// One proximity tracker firing — a box's expanded rect or its chip
    /// strip. The regions overlap, so inside-ness is tracked per part: a
    /// box counts as near while any of its parts holds the pointer, and
    /// one part exiting can't drop the chrome while another still holds.
    private struct InsidePart: Hashable {
        let entry: Entry.Key
        let part: Int
    }

    /// Parts currently holding the pointer, in entry order — the last
    /// entry's box is the one whose chrome is up, and leaving it falls
    /// back to whatever the pointer is still inside.
    @State private var insideParts: [InsidePart] = []

    /// The box to reveal — nil keeps the photo clean.
    private var hovered: Entry.Key? { insideParts.last?.entry }

    private var allEntries: [Entry] { Self.entries(faces: faces, pets: pets) }

    var body: some View {
        ZStack {
            if !imageFrame.isEmpty {
                ForEach(allEntries) { entry in
                    faceGroup(entry)
                }
            }
        }
        .onChange(of: allEntries.map(\.id)) { _, ids in
            // A removed box's target dies without an exit event — drop it
            // so a stale winner can't mask the box now under the pointer.
            insideParts.removeAll { !ids.contains($0.entry) }
        }
        .onChange(of: imageFrame.isEmpty) { _, empty in
            if empty { insideParts.removeAll() }
        }
    }

    private func setHovered(_ part: InsidePart, _ inside: Bool) {
        insideParts.removeAll { $0 == part }
        if inside { insideParts.append(part) }
    }

    /// The box in this overlay's coordinate space: stored
    /// bottom-left-normalized → top-left-normalized → rotated like the
    /// decoded image → scaled into the displayed rect.
    private func displayRect(for face: FaceRecord) -> CGRect {
        let normalized = FaceBoxProjection.rotatedTopLeftRect(
            FaceBoxProjection.topLeftRect(of: face.box),
            quarterTurnsCW: rotation
        )
        return CGRect(
            x: imageFrame.minX + normalized.minX * imageFrame.width,
            y: imageFrame.minY + normalized.minY * imageFrame.height,
            width: normalized.width * imageFrame.width,
            height: normalized.height * imageFrame.height
        )
    }

    private func color(for entry: Entry) -> Color {
        if let personID = entry.face.personID { return EventPalette.color(for: personID) }
        return entry.subject == .pets ? Self.unnamedPetColor : .gray
    }

    private func name(for entry: Entry) -> String? {
        let names = entry.subject == .pets ? petNames : personNames
        return entry.face.personID.flatMap { names[$0] }
    }

    @ViewBuilder
    private func faceGroup(_ entry: Entry) -> some View {
        let boxRect = displayRect(for: entry.face)
        let isHovered = hovered == entry.id
        // The chip strip rides just under the box — or just over it near
        // the photo's bottom edge — and its rect stays a hover target of
        // its own, so the pointer can travel from box to chip without
        // dropping even when the strip sits wider than a narrow box.
        let chipHeight: CGFloat = 22
        let chipBelow = boxRect.maxY + chipHeight + 6 <= imageFrame.maxY
        let strip = CGRect(
            x: boxRect.midX - 70,
            y: chipBelow ? boxRect.maxY : boxRect.minY - chipHeight - 6,
            width: 140,
            height: chipHeight + 6
        )
        let regions = FaceHoverRegion.rects(boxRect: boxRect, chipStrip: strip)
        let groupRect = regions.box.union(regions.strip)

        ZStack {
            // The invisible targets exist while the chrome is hidden, so
            // approaching the box can reveal it — and they never
            // hit-test, so zoom/pan clicks still reach the canvas.
            proximityTarget(regions.box, in: groupRect, part: InsidePart(entry: entry.id, part: 0))
            proximityTarget(regions.strip, in: groupRect, part: InsidePart(entry: entry.id, part: 1))
            if isHovered {
                Group {
                    boxShape(entry)
                        .frame(width: boxRect.width, height: boxRect.height)
                        .position(
                            x: boxRect.midX - groupRect.minX,
                            y: boxRect.midY - groupRect.minY
                        )
                        .allowsHitTesting(false)
                    chip(for: entry, boxRect: boxRect)
                        .fixedSize()
                        .position(
                            x: boxRect.midX - groupRect.minX,
                            y: (chipBelow
                                ? boxRect.maxY + chipHeight / 2 + 3
                                : boxRect.minY - chipHeight / 2 - 3) - groupRect.minY
                        )
                }
                .transition(.opacity)
            }
        }
        .frame(width: groupRect.width, height: groupRect.height)
        .position(x: groupRect.midX, y: groupRect.midY)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: entry))
    }

    /// A hover-only region: an AppKit tracking view reports pointer
    /// enter/exit while never hit-testing, so the same rect stays
    /// transparent to the clicks that drive zoom and pan. A SwiftUI
    /// target can't do both — `allowsHitTesting(false)` would silence the
    /// hover together with the clicks.
    private func proximityTarget(_ rect: CGRect, in groupRect: CGRect, part: InsidePart) -> some View {
        HoverTrackingView { inside in setHovered(part, inside) }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX - groupRect.minX, y: rect.midY - groupRect.minY)
    }

    /// Box fill/stroke per state, drawn only while revealed: solid+bright
    /// for confirmed, dashed for proposed, faint dashed for unnamed.
    @ViewBuilder
    private func boxShape(_ entry: Entry) -> some View {
        let color = color(for: entry)
        switch entry.face.state {
        case .confirmed:
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(color, lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.22))
                )
        case .proposed:
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.18))
                )
        case .cached, .other:
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    color.opacity(0.95),
                    style: StrokeStyle(lineWidth: 1.25, dash: [4, 3])
                )
        }
    }

    /// A small paw leading every dog chip — the one mark that tells a dog
    /// box from a face box.
    @ViewBuilder
    private func petMark(_ entry: Entry) -> some View {
        if entry.subject == .pets {
            Image(systemName: "pawprint.fill")
                .font(.caption2)
                .imageScale(.small)
        }
    }

    /// The name chip below the box: solid color for confirmed names, a
    /// dark capsule with confirm/tag buttons for everything still movable.
    @ViewBuilder
    private func chip(for entry: Entry, boxRect: CGRect) -> some View {
        let face = entry.face
        let name = name(for: entry)
        let isPet = entry.subject == .pets
        switch face.state {
        case .confirmed:
            HStack(spacing: 3) {
                Image(systemName: isPet ? "pawprint.fill" : "person.fill")
                    .font(.caption2)
                    .imageScale(.small)
                Text(name ?? "Confirmed")
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color(for: entry), in: Capsule())
        case .proposed:
            HStack(spacing: 5) {
                petMark(entry)
                Text(name.map { "\($0)?" } ?? "Match?")
                    .lineLimit(1)
                if let score = face.matchScore {
                    Text("\(Int((score * 100).rounded()))%")
                        .foregroundStyle(.white.opacity(0.65))
                }
                Button {
                    onConfirm(face, entry.subject)
                } label: {
                    Label("Confirm", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Confirm this is \(name ?? "the match") — confirmed \(isPet ? "dogs" : "faces") are frozen")
                tagButton(for: entry, boxRect: boxRect)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.75), in: Capsule())
            .overlay {
                Capsule().strokeBorder(color(for: entry).opacity(0.8), lineWidth: 1)
            }
        case .cached, .other:
            HStack(spacing: 5) {
                petMark(entry)
                Text(name ?? (isPet ? "Dog" : "Face"))
                    .lineLimit(1)
                tagButton(for: entry, boxRect: boxRect)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.7), in: Capsule())
        }
    }

    /// The "+" affordance that opens the picker for this box — people for
    /// a face, pets for a dog.
    private func tagButton(for entry: Entry, boxRect: CGRect) -> some View {
        let isPet = entry.subject == .pets
        return Button {
            onTag(entry.face, entry.subject, boxRect)
        } label: {
            Label(isPet ? "Tag Dog" : "Tag Face", systemImage: "plus.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.white.opacity(0.9))
        }
        .buttonStyle(.plain)
        .help(isPet ? "Tag this dog as a pet" : "Tag this face as a person")
    }

    private func accessibilityLabel(for entry: Entry) -> String {
        let name = name(for: entry)
        let noun = entry.subject == .pets ? "dog" : "face"
        switch entry.face.state {
        case .confirmed: return "Confirmed \(noun): \(name ?? "unknown")"
        case .proposed: return "Proposed \(noun): \(name ?? "unknown")"
        case .other: return "Grouped \(noun): \(name ?? "unnamed")"
        case .cached: return "Unmatched \(noun)"
        }
    }
}

/// What the tag picker is tagging — an existing detection, or a box the
/// owner drew. `anchor` positions the picker in canvas coordinates.
/// `subject` says which index the detection lives in: a dog box tags
/// against the pets, never the people. A drawn box is always a face.
struct FaceTagRequest: Identifiable {
    enum Target {
        case face(UUID)
        case drawnBox(NormalizedFaceBox, crop: Data?)
    }

    let id = UUID()
    var target: Target
    var anchor: CGRect
    var subject: FaceGallerySubject = .people
}

/// The person picker the burst overlay shows in a native popover anchored
/// on the face being tagged: pick an existing roster person, or type a
/// name to create one. The popover supplies the chrome and dismisses on
/// Esc or a click outside. All writes land in the face catalog — the
/// photo file is never touched. With `subject` `.pets` the same picker
/// lists the approved pets for a dog box, and its writes land in the pet
/// index instead.
struct FaceTagPicker: View {
    let people: [FacePerson]
    var subject: FaceGallerySubject = .people
    var onPick: (FacePerson) -> Void = { _ in }
    var onCreate: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}

    @State private var query = ""
    @FocusState private var queryFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filtered: [FacePerson] {
        guard !trimmedQuery.isEmpty else { return people }
        return people.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    private var canCreate: Bool {
        !trimmedQuery.isEmpty && !people.contains {
            $0.name.localizedCaseInsensitiveCompare(trimmedQuery) == .orderedSame
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subject == .pets ? "Tag This Dog" : "Tag This Face")
                .font(.headline)
            TextField(subject == .pets ? "Pet name" : "Person name", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .onSubmit(submit)
            if filtered.isEmpty {
                Text(people.isEmpty ? "No \(subject.nounPlural) yet — type a name to create one." : "No match for “\(trimmedQuery)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filtered) { person in
                            FaceTagPersonRow(person: person) {
                                onPick(person)
                            }
                        }
                    }
                }
                .frame(maxHeight: 168)
            }
            if canCreate {
                Button {
                    onCreate(trimmedQuery)
                } label: {
                    Label("New \(subject == .pets ? "Pet" : "Person") “\(trimmedQuery)”", systemImage: "plus.circle.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
            }
            Text(subject == .pets
                ? "Pet index only — the photo file is never modified."
                : "Catalog only — the photo file is never modified.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 260)
        .onAppear { queryFocused = true }
        .onKeyPress(.escape) {
            onCancel()
            return .handled
        }
    }

    /// Return picks the exact-named person or the top of the filtered list;
    /// with no match it creates the typed name.
    private func submit() {
        guard !trimmedQuery.isEmpty else { return }
        if let exact = filtered.first(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmedQuery) == .orderedSame
        }) {
            onPick(exact)
        } else if filtered.count == 1 {
            onPick(filtered[0])
        } else {
            onCreate(trimmedQuery)
        }
    }
}

/// One roster row in the tag picker: color dot, name, stored face count.
private struct FaceTagPersonRow: View {
    let person: FacePerson
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(EventPalette.color(for: person.id))
                    .frame(width: 8, height: 8)
                Text(person.name)
                    .lineLimit(1)
                Spacer()
                Text("\(person.faceCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary.opacity(hovered ? 1 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The trailing inspector that `i` slides out on the burst preview: people
/// on the frame, capture time, camera and exposure when EXIF carries them,
/// and the file's own name and size. It draws no background of its own —
/// the host puts it on glass.
struct FrameInspectorPanel: View {
    let item: OrganizeItem
    /// nil = the file was never face-scanned.
    var photoRecord: FacePhotoRecord? = nil
    var faces: [FaceRecord] = []
    var personNames: [UUID: String] = [:]
    var metadata: PhotoMetadata? = nil
    /// False while the background EXIF read is still running.
    var metadataLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                peopleSection
                captureSection
                cameraSection
                fileSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var peopleSection: some View {
        inspectorSection("People", icon: "person.2") {
            if faces.isEmpty {
                Text(photoRecord == nil ? "Not scanned for faces" : "Scanned — no faces found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(faces.filter { $0.personID != nil }) { face in
                        personRow(face)
                    }
                    let unnamed = faces.count - faces.count(where: { $0.personID != nil })
                    if unnamed > 0 {
                        Text("\(unnamed) face\(unnamed == 1 ? "" : "s") not yet matched")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func personRow(_ face: FaceRecord) -> some View {
        let name = face.personID.flatMap { personNames[$0] } ?? "Unknown"
        let color = face.personID.map { EventPalette.color(for: $0) } ?? .gray
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(name)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 0)
            switch face.state {
            case .confirmed:
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundStyle(color)
                    .help("Confirmed")
            case .proposed:
                Text("?")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .help("Proposed — not confirmed yet")
            default:
                Text("unnamed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var captureSection: some View {
        inspectorSection("Capture", icon: "calendar") {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.captureDate.formatted(date: .abbreviated, time: .standard))
                    .font(.callout)
                if !item.hasCameraDate {
                    Text("from file date")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var cameraSection: some View {
        if let metadata, metadata.hasCameraFields {
            inspectorSection("Camera", icon: "camera") {
                VStack(alignment: .leading, spacing: 6) {
                    if let camera = metadata.cameraDisplay { row("Camera", camera) }
                    if let lens = metadata.lens { row("Lens", lens) }
                    if let shutter = metadata.shutterDisplay { row("Shutter", shutter) }
                    if let aperture = metadata.apertureDisplay { row("Aperture", aperture) }
                    if let iso = metadata.isoDisplay { row("ISO", iso) }
                    if let focal = metadata.focalDisplay { row("Focal", focal) }
                    if let dimensions = metadata.dimensionsDisplay { row("Dimensions", dimensions) }
                }
            }
        } else if !metadataLoaded, item.kind == .raw || item.kind == .photo {
            inspectorSection("Camera", icon: "camera") {
                Text("Reading metadata…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var fileSection: some View {
        inspectorSection("File", icon: "document") {
            VStack(alignment: .leading, spacing: 6) {
                row("Name", item.primary.name)
                let size = item.primary.size.formattedBytes
                row("Size", item.companions.isEmpty ? size : "\(size) + \(item.companions.count) sidecar\(item.companions.count == 1 ? "" : "s")")
                ForEach(item.companions, id: \.path) { companion in
                    row("With", "\(companion.name) · \(companion.size.formattedBytes)")
                }
                row("Kind", kindLabel)
            }
        }
    }

    private var kindLabel: String {
        switch item.kind {
        case .raw: "RAW"
        case .photo: "Photo"
        case .video: "Video"
        case .other: "File"
        }
    }

    // MARK: - Pieces

    private func inspectorSection<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}
