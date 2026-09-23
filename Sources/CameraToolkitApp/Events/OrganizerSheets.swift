import AppKit
import CameraToolkitCore
import SwiftUI

struct EventDetailsSheet: View {
    let title: String
    let confirmTitle: String
    /// Candidate parents in sidebar order (the edited event and its subevents
    /// are already excluded, so a parent loop can't be picked).
    let parents: [(event: SavedCameraEvent, depth: Int)]
    let onCancel: () -> Void
    /// (name, date, storagePolicy, parentEventID) — a nil policy follows the
    /// parent's setting for a subevent, or the shared Buffer at top level.
    let onSave: (String, Date, EventStoragePolicy?, UUID?) -> Void

    @State private var name: String
    @State private var date: Date
    @State private var policy: EventStoragePolicy?
    @State private var parentEventID: UUID?
    @FocusState private var isNameFocused: Bool

    init(
        title: String,
        confirmTitle: String,
        initialName: String,
        initialDate: Date,
        initialPolicy: EventStoragePolicy?,
        initialParentEventID: UUID?,
        parents: [(event: SavedCameraEvent, depth: Int)],
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, Date, EventStoragePolicy?, UUID?) -> Void
    ) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.parents = parents
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: initialName)
        _date = State(initialValue: initialDate)
        _policy = State(initialValue: initialPolicy)
        _parentEventID = State(initialValue: initialParentEventID)
    }

    private var validation: EventNameValidation {
        EventNamePolicy.validate(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.headline)
                EventNameField(text: $name, isFocused: $isNameFocused, onSubmit: save)
                    .frame(height: 24)
            }
            if !name.isEmpty, let error = validation.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Inside event", selection: $parentEventID) {
                    Text("None — top level").tag(UUID?.none)
                    ForEach(parents, id: \.event.id) { row in
                        Text(String(repeating: "    ", count: row.depth) + row.event.name)
                            .tag(UUID?.some(row.event.id))
                    }
                }
                .help("A subevent's folder lives inside its parent event's folder.")
                if parentEventID == nil {
                    Picker("Keep on drive", selection: Binding(
                        get: { policy ?? .buffer },
                        set: { policy = $0 }
                    )) {
                        Text("Shared Buffer").tag(EventStoragePolicy.buffer)
                        Text("Private · NAS only").tag(EventStoragePolicy.archiveOnly)
                    }
                    .pickerStyle(.radioGroup)
                } else {
                    Picker("Keep on drive", selection: $policy) {
                        Text("Same as parent").tag(EventStoragePolicy?.none)
                        Text("Shared Buffer").tag(EventStoragePolicy?.some(.buffer))
                        Text("Private · NAS only").tag(EventStoragePolicy?.some(.archiveOnly))
                    }
                    .pickerStyle(.radioGroup)
                }
                Text(policyHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validation.isValid)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { isNameFocused = true }
    }

    private var policyHelp: String {
        let shared = "Originals go into the shared Camera Buffer, where anyone browsing the drive can see them."
        let private_ = "Originals never enter the shared Buffer. They wait in a hidden folder on the drive until they are archived to the NAS, and then you can take them off the drive."
        if parentEventID != nil, policy == nil {
            let parent = parents.first { $0.event.id == parentEventID }?.event
            let resolved = parent.map {
                EventHierarchy.resolvedPolicy(of: $0, in: parents.map(\.event))
            } ?? .buffer
            return "Follows the parent event's setting (currently \(resolved == .buffer ? "Shared Buffer" : "Private · NAS only"))."
        }
        return (policy ?? .buffer) == .buffer ? shared : private_
    }

    private func save() {
        guard validation.isValid else { return }
        onSave(validation.normalizedName, date, policy, parentEventID)
    }
}

/// AppKit field so a trailing space is visible immediately. SwiftUI's
/// grouped Form TextField on macOS swallows that space until the next key.
private struct EventNameField: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = "Beach day, Birthday, Client shoot…"
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, field.currentEditor() == nil {
            field.stringValue = text
        }
        if isFocused.wrappedValue, field.window?.firstResponder !== field.currentEditor() {
            field.window?.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: EventNameField
        init(_ parent: EventNameField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

struct ApplyPlanSheet: View {
    let plan: OrganizeApplyPlan
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plan.title)
                .font(.title2.bold())
            Text(summary)
                .foregroundStyle(.secondary)
            ApplyPlanSummaryCard(plan: plan)
            Text("Where each folder lands")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.groups) { group in
                        ApplyEventGroupCard(group: group)
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(minHeight: 120)
            Label(
                "Moves on the same drive are instant renames. Copies from another drive are checksum-verified and leave the originals in place. Nothing is overwritten, and Undo can move files back.",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680, height: 560)
    }

    private var summary: String {
        var parts: [String] = []
        if plan.moveCount > 0 {
            parts.append("\(plan.moveCount) instant move\(plan.moveCount == 1 ? "" : "s")")
        }
        if plan.copyCount > 0 {
            parts.append("\(plan.copyCount) verified cop\(plan.copyCount == 1 ? "y" : "ies")")
        }
        let events = plan.groups.count { !$0.moves.isEmpty || !$0.copies.isEmpty }
        return parts.joined(separator: " and ") + " · \(plan.byteCount.formattedBytes) into \(events) event\(events == 1 ? "" : "s")"
    }
}

struct RemovalConfirmSheet: View {
    let request: RemovalRequest
    let eventName: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.kind == .drive ? "Take \(eventName) off the drive?" : "Free up the source for \(eventName)?")
                .font(.title2.bold())
            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(request.fileCount) file\(request.fileCount == 1 ? "" : "s") · \(request.byteCount.formattedBytes)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            TextField("Type \(VerifiedRemovalService.confirmationToken) to continue", text: $confirmation)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(request.kind == .drive ? "Verify and Take Off Drive" : "Verify and Remove from Source", role: .destructive) {
                    onConfirm(confirmation)
                }
                .disabled(confirmation != VerifiedRemovalService.confirmationToken)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var explanation: String {
        switch request.kind {
        case .drive:
            "Camera Toolkit re-hashes every drive copy against its NAS copy. Only if all of them match, the drive copies move into the hidden _Trash folder on the same drive. They stay recoverable there until you empty it in Trash."
        case .source:
            "Camera Toolkit re-hashes every file on the card or unsorted folder against its drive copy. Only if all of them match, the source originals are permanently deleted. The drive copies stay."
        }
    }
}

/// Organizer Trash confirmation. Count and source sit in the header, each
/// volume's `_Trash` folder gets its own boxed row — the line the owner must
/// not miss — and a note keeps it distinct from Finder Trash. Esc cancels;
/// Move to Trash is the red default button.
struct TrashConfirmSheet: View {
    let request: PendingTrashRequest
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Move \(request.fileCount) file\(request.fileCount == 1 ? "" : "s") to Trash?")
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(request.byteCount.formattedBytes) · from \(request.locationName)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            destinationCard

            if !request.sampleNames.isEmpty {
                Text(fileList)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label {
                Text("\(Text("Not the Finder Trash.").fontWeight(.semibold)) Restore from the Trash window — nothing is permanently deleted until you empty it.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// The "where they go" card: one row per volume's `_Trash` folder so the
    /// destination reads as a destination, not a bullet inside a paragraph.
    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where they go")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if request.destinations.isEmpty {
                Text("No reachable files to move.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(request.destinations, id: \.trashFolderPath) { destination in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "externaldrive.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(destination.volumeLabel)
                                    .font(.headline)
                                if request.destinations.count > 1 {
                                    Spacer(minLength: 8)
                                    Text("\(destination.fileCount) file\(destination.fileCount == 1 ? "" : "s") · \(destination.byteCount.formattedBytes)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(destination.trashFolderPath)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        }
    }

    private var fileList: String {
        var list = request.sampleNames.joined(separator: ", ")
        if request.fileCount > request.sampleNames.count {
            list += " and \(request.fileCount - request.sampleNames.count) more"
        }
        return list
    }
}

/// The one compute sheet for face scans: quality tier plus Fast (pin the
/// Mac). No model names — the owner picks how hard to look, the models
/// are fixed.
struct FaceScanSheet: View {
    /// What is being scanned — an unsorted location's name or an event's
    /// breadcrumb title.
    let name: String
    /// MED and above need the converted detector package; without it the
    /// scan button stays off and the fix is spelled out inline.
    let engineInstalled: Bool
    let onCancel: () -> Void
    let onScan: (FaceScanOptions) -> Void

    @State private var mode: FaceScanGrade = .low
    @State private var fast = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan for Faces")
                .font(.title2.bold())
            Text(name)
                .foregroundStyle(.secondary)
            Form {
                Picker("Quality", selection: $mode) {
                    Text("Low").tag(FaceScanGrade.low)
                    Text("Medium").tag(FaceScanGrade.med)
                    Text("High").tag(FaceScanGrade.high)
                    Text("Extra High").tag(FaceScanGrade.xhigh)
                }
                .pickerStyle(.segmented)
                Toggle("Fast — pin the Mac", isOn: $fast)
                    .help("Uses every core it can and will run hot. Turn off to keep the machine quiet; same quality, longer wait.")
            }
            .formStyle(.grouped)
            Text(modeHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !engineInstalled {
                Label(
                    "Face scans need the face engine installed — run \(FaceSidecarInstallation.setupCommand) once on this Mac.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Scan") {
                    onScan(FaceScanOptions(mode: mode, fast: fast))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!engineInstalled)
            }
        }
        .padding(20)
        .frame(width: 460)
    }


    private var modeHelp: String {
        switch mode {
        case .med:
            "A more careful pass: stills plus a light sample of video frames, and it finds smaller faces down to about 40 px."
        case .high:
            "The deep pass: stills at two scales, faces down to about 30 px, and roughly one frame per second of video. Takes a while on big libraries."
        case .xhigh:
            "The everything pass: every burst frame, stills at three scales, faces down to about 30 px, about two video frames per second, and a second look at each face that sharpens your named people's templates. Best overnight, after naming people."
        default:
            "The quick pass: still photos only, faces large enough to matter. Videos are skipped."
        }
    }
}
