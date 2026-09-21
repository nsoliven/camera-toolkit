import CameraToolkitCore
import SwiftUI

/// Face boxes drawn over the photo in `StackPreviewOverlay`, aligned to the
/// canvas's reported image frame so zoom and pan keep them attached.
///
/// Confirmed faces get a solid named box; proposed matches get a weaker
/// dashed box with a "?" and a one-click confirm; unnamed detections stay
/// faint until hovered, where a "+" opens the tag picker. Clicking a box
/// body is intentionally transparent — the click falls through to the
/// canvas's zoom; only the chips' buttons consume events.
struct FaceBoxesOverlay: View {
    let faces: [FaceRecord]
    var personNames: [UUID: String] = [:]
    /// Quarter-turns clockwise applied to the decoded image right now.
    var rotation: Int = 0
    /// The photo's displayed rect in this view's coordinates — `.zero`
    /// hides everything (no photo on screen yet).
    var imageFrame: CGRect = .zero
    var onConfirm: (FaceRecord) -> Void = { _ in }
    /// A face plus its box rect in this view's space, to anchor the picker.
    var onTag: (FaceRecord, CGRect) -> Void = { _, _ in }

    @State private var hovered: UUID?

    var body: some View {
        if !imageFrame.isEmpty {
            ZStack {
                ForEach(faces) { face in
                    faceGroup(face)
                }
            }
        }
    }

    /// The face's box in this overlay's coordinate space: stored
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

    private func color(for face: FaceRecord) -> Color {
        face.personID.map { EventPalette.color(for: $0) } ?? .gray
    }

    @ViewBuilder
    private func faceGroup(_ face: FaceRecord) -> some View {
        let boxRect = displayRect(for: face)
        let isHovered = hovered == face.id
        // The chip strip rides just under the box — or just over it near
        // the photo's bottom edge — and the hover region covers both, so
        // the pointer can travel from box to chip without dropping.
        let chipHeight: CGFloat = 22
        let chipBelow = boxRect.maxY + chipHeight + 6 <= imageFrame.maxY
        let strip = CGRect(
            x: boxRect.midX - 70,
            y: chipBelow ? boxRect.maxY : boxRect.minY - chipHeight - 6,
            width: 140,
            height: chipHeight + 6
        )
        let groupRect = boxRect.union(strip)

        ZStack {
            boxShape(face, hovered: isHovered)
                .frame(width: boxRect.width, height: boxRect.height)
                .position(
                    x: boxRect.midX - groupRect.minX,
                    y: boxRect.midY - groupRect.minY
                )
                .allowsHitTesting(false)
            if showsChip(face, hovered: isHovered) {
                chip(for: face, boxRect: boxRect, hovered: isHovered)
                    .fixedSize()
                    .position(
                        x: boxRect.midX - groupRect.minX,
                        y: (chipBelow
                            ? boxRect.maxY + chipHeight / 2 + 3
                            : boxRect.minY - chipHeight / 2 - 3) - groupRect.minY
                    )
            }
        }
        .frame(width: groupRect.width, height: groupRect.height)
        .position(x: groupRect.midX, y: groupRect.midY)
        .onHover { inside in
            hovered = inside ? face.id : (hovered == face.id ? nil : hovered)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: face))
    }

    /// Box fill/stroke per state: solid+bright for confirmed, dashed for
    /// proposed, faint dashed for anything unnamed.
    @ViewBuilder
    private func boxShape(_ face: FaceRecord, hovered: Bool) -> some View {
        let color = color(for: face)
        switch face.state {
        case .confirmed:
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(color, lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(hovered ? 0.22 : 0.12))
                )
        case .proposed:
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(hovered ? 0.18 : 0.08))
                )
        case .cached, .other:
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    color.opacity(hovered ? 0.95 : 0.5),
                    style: StrokeStyle(lineWidth: 1.25, dash: [4, 3])
                )
        }
    }

    private func showsChip(_ face: FaceRecord, hovered: Bool) -> Bool {
        switch face.state {
        case .confirmed, .proposed:
            return true
        case .cached, .other:
            return hovered
        }
    }

    /// The name chip below the box: solid color for confirmed people, a
    /// dark capsule with confirm/tag buttons for everything still movable.
    @ViewBuilder
    private func chip(for face: FaceRecord, boxRect: CGRect, hovered: Bool) -> some View {
        let name = face.personID.flatMap { personNames[$0] }
        switch face.state {
        case .confirmed:
            HStack(spacing: 3) {
                Image(systemName: "person.fill")
                    .font(.system(size: 8))
                Text(name ?? "Confirmed")
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color(for: face), in: Capsule())
        case .proposed:
            HStack(spacing: 5) {
                Text(name.map { "\($0)?" } ?? "Match?")
                    .lineLimit(1)
                if let score = face.matchScore {
                    Text("\(Int((score * 100).rounded()))%")
                        .foregroundStyle(.white.opacity(0.65))
                }
                Button {
                    onConfirm(face)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Confirm this is \(name ?? "the match") — confirmed faces are frozen")
                tagButton(for: face, boxRect: boxRect)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.75), in: Capsule())
            .overlay {
                Capsule().strokeBorder(color(for: face).opacity(0.8), lineWidth: 1)
            }
        case .cached, .other:
            HStack(spacing: 5) {
                Text(name ?? "Face")
                    .lineLimit(1)
                tagButton(for: face, boxRect: boxRect)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.7), in: Capsule())
        }
    }

    /// The "+" affordance that opens the person picker for this face.
    private func tagButton(for face: FaceRecord, boxRect: CGRect) -> some View {
        Button {
            onTag(face, boxRect)
        } label: {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.white.opacity(0.9))
        }
        .buttonStyle(.plain)
        .help("Tag this face as a person")
    }

    private func accessibilityLabel(for face: FaceRecord) -> String {
        let name = face.personID.flatMap { personNames[$0] }
        switch face.state {
        case .confirmed: return "Confirmed face: \(name ?? "unknown")"
        case .proposed: return "Proposed face: \(name ?? "unknown")"
        case .other: return "Grouped face: \(name ?? "unnamed")"
        case .cached: return "Unmatched face"
        }
    }
}

/// What the tag picker is tagging — an existing detection, or a box the
/// owner drew. `anchor` positions the picker in canvas coordinates.
struct FaceTagRequest: Identifiable {
    enum Target {
        case face(UUID)
        case drawnBox(NormalizedFaceBox, crop: Data?)
    }

    let id = UUID()
    var target: Target
    var anchor: CGRect
}

/// The person picker that slides over the photo when a face is tagged:
/// pick an existing roster person, or type a name to create one. All
/// writes land in the face catalog — the photo file is never touched.
struct FaceTagPicker: View {
    let people: [FacePerson]
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
            HStack {
                Text("Tag this face")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")
            }
            TextField("Person name", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .onSubmit(submit)
            if filtered.isEmpty {
                Text(people.isEmpty ? "No people yet — type a name to create one." : "No match for “\(trimmedQuery)”.")
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
                    Label("New person “\(trimmedQuery)”", systemImage: "plus.circle.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            Text("Catalog only — the photo file is never modified.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
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
                    .fill(Color.white.opacity(hovered ? 0.12 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The trailing inspector that `i` slides out on the burst preview: people
/// on the frame, capture time, camera and exposure when EXIF carries them,
/// and the file's own name and size.
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
            .padding(12)
        }
        .frame(width: 252)
        .background(.ultraThinMaterial)
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
        inspectorSection("File", icon: "doc") {
            VStack(alignment: .leading, spacing: 6) {
                row("Name", item.primary.name)
                let size = item.primary.size.formattedBytes
                row("Size", item.companions.isEmpty ? size : "\(size) + \(item.companions.count) sidecar\(item.companions.count == 1 ? "" : "s")")
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
