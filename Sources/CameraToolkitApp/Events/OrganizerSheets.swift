import AppKit
import CameraToolkitCore
import SwiftUI

/// The one layout every organizer sheet shares: an optional leading SF
/// Symbol, a bold title (and subtitle), the content, then a trailing
/// button row — Cancel left of the confirm button, as macOS sheets do.
/// Buttons are standard push buttons: the sheet is already the glass layer
/// on macOS 26, and `.keyboardShortcut(.defaultAction)` alone gives the
/// default button its accent fill, so there is no glass or explicit
/// prominent style inside sheet content.
struct SheetScaffold<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var iconTint: Color = .accentColor
    var width: CGFloat = 520
    /// Fixed height for sheets whose content scrolls (the apply plan);
    /// nil lets the sheet fit its content.
    var height: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(iconTint)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content()
            HStack {
                Spacer()
                actions()
            }
        }
        .padding(20)
        .frame(width: width, height: height)
        .presentationSizing(.fitted)
    }
}

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
        SheetScaffold(title: title) {
            // One grouped Form for every field, so the name sits in the same
            // visual system as the date and pickers.
            Form {
                Section {
                    LabeledContent("Name") {
                        EventNameField(text: $name, isFocused: $isNameFocused, onSubmit: save)
                            .frame(height: 24)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Inside event", selection: $parentEventID) {
                        Text("None — top level").tag(UUID?.none)
                        ForEach(parents, id: \.event.id) { row in
                            Text(String(repeating: "    ", count: row.depth) + row.event.name)
                                .tag(UUID?.some(row.event.id))
                        }
                    }
                    .help("A subevent's folder lives inside its parent event's folder.")
                } footer: {
                    if !name.isEmpty, let error = validation.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Section {
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
                } footer: {
                    Text(policyHelp)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle, action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(!validation.isValid)
        }
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

/// The Apply confirmation as a before → after picture: a plain-language
/// sentence, then From (source folders) → labelled arrows → To (event
/// folders), a few safety lines, and the full table and per-folder file
/// lists under a collapsed Details disclosure. Purely presentational —
/// Apply runs exactly the plan it was handed.
struct ApplyPlanSheet: View {
    let plan: OrganizeApplyPlan
    let onCancel: () -> Void
    let onApply: () -> Void
    /// Opens the organizer Trash confirmation for the identical copies.
    var onTrashDuplicates: () -> Void = {}
    /// Moves the name conflicts in under a free "(N)" name.
    var onKeepBoth: () -> Void = {}

    /// Built once per sheet from the plan (string work only, no disk).
    private let overview: ApplyPlanOverview
    @State private var showDetails = false

    init(
        plan: OrganizeApplyPlan,
        onCancel: @escaping () -> Void,
        onApply: @escaping () -> Void,
        onTrashDuplicates: @escaping () -> Void = {},
        onKeepBoth: @escaping () -> Void = {}
    ) {
        self.plan = plan
        self.onCancel = onCancel
        self.onApply = onApply
        self.onTrashDuplicates = onTrashDuplicates
        self.onKeepBoth = onKeepBoth
        overview = ApplyPlanOverview(plan: plan)
    }

    var body: some View {
        SheetScaffold(title: plan.title, subtitle: overview.sentence, width: 680, height: 600) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if overview.fileCount > 0 || overview.collisions.isEmpty {
                        ApplyPlanFlowView(overview: overview)
                    }
                    if !overview.collisions.isEmpty {
                        ApplyCollisionsView(
                            collisions: overview.collisions,
                            onTrashDuplicates: onTrashDuplicates,
                            onKeepBoth: onKeepBoth
                        )
                    }
                    DisclosureGroup(isExpanded: $showDetails) {
                        VStack(alignment: .leading, spacing: 10) {
                            ApplyPlanSummaryCard(plan: plan)
                            Text("Where each folder lands")
                                .font(.headline)
                                .padding(.top, 4)
                            ForEach(plan.groups) { group in
                                ApplyEventGroupCard(group: group)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Details")
                            .font(.headline)
                    }
                }
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
            Divider()
            ApplySafetyFactsView(facts: overview.safetyFacts)
        } actions: {
            Button(plan.isEmpty ? "Close" : "Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            // Non-destructive (nothing is overwritten, Undo moves files
            // back), so Return confirms; the default-button fill is the
            // system's, not an explicit prominent style.
            Button(overview.primaryActionTitle, action: onApply)
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty)
        }
    }
}

/// The Apply sheet's "needs a decision" box: files whose name is already
/// taken in their event. Identical copies are already in the event and can
/// go to the recoverable Trash; different files can move in under a free
/// "(N)" name. Neither happens without the owner pressing the button.
struct ApplyCollisionsView: View {
    let collisions: [ApplyCollisionSummary]
    let onTrashDuplicates: () -> Void
    let onKeepBoth: () -> Void

    var body: some View {
        let duplicates = collisions.filter { $0.duplicateCount > 0 }
        let conflicts = collisions.filter { $0.conflictCount > 0 }
        VStack(alignment: .leading, spacing: 12) {
            Text("Already taken in the event")
                .font(.headline)
            if !duplicates.isEmpty {
                row(
                    symbol: "checkmark.circle.fill",
                    tint: .green,
                    lines: duplicates.compactMap(\.duplicateLine),
                    names: duplicates.flatMap(\.duplicateNames),
                    detail: "The event already has these exact bytes, so they are not pending. The copies here are spare and stay until you choose.",
                    button: Button("Move Duplicate\(duplicates.reduce(0) { $0 + $1.duplicateCount } == 1 ? "" : "s") to Trash…", role: .destructive, action: onTrashDuplicates)
                        .help("Opens the Trash confirmation. Files go to the drive’s _Trash folder and can be restored from the Trash window.")
                )
            }
            if !conflicts.isEmpty {
                row(
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    lines: conflicts.compactMap(\.conflictLine) + conflicts.compactMap(\.heldBackLine),
                    names: conflicts.flatMap(\.conflictNames),
                    detail: "Two cameras or a reset counter can reuse a name. Keep Both moves this file in as \(conflicts.first?.keepBothExample ?? "“name (2)”"), next to the other one. Nothing is replaced, and Undo moves it back.",
                    button: Button("Keep Both", action: onKeepBoth)
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.quinary, in: .rect(cornerRadius: 10, style: .continuous))
    }

    private func row<B: View>(symbol: String, tint: Color, lines: [String], names: [String], detail: String, button: B) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Text(line + ".")
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(Self.nameList(names))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                button
                    .padding(.top, 2)
            }
        }
    }

    static func nameList(_ names: [String], limit: Int = 3) -> String {
        let shown = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? "\(shown) and \(names.count - limit) more" : shown
    }
}

struct RemovalConfirmSheet: View {
    let request: RemovalRequest
    let eventName: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var confirmation = ""

    /// The destructive button unlocks only on the exact token — no
    /// trimming, no case folding. The service checks it again.
    static func isConfirmed(_ typed: String) -> Bool {
        typed == VerifiedRemovalService.confirmationToken
    }

    var body: some View {
        SheetScaffold(
            title: request.kind == .drive ? "Take \(eventName) off the drive?" : "Free up the source for \(eventName)?",
            systemImage: "externaldrive.badge.minus",
            // Red for the permanent source delete, orange for the drive
            // copies that stay recoverable in _Trash.
            iconTint: request.kind == .source ? .red : .orange
        ) {
            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(request.fileCount) file\(request.fileCount == 1 ? "" : "s") · \(request.byteCount.formattedBytes)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            LabeledContent("Type \(VerifiedRemovalService.confirmationToken) to continue") {
                TextField(
                    "Type \(VerifiedRemovalService.confirmationToken) to continue",
                    text: $confirmation,
                    prompt: Text(VerifiedRemovalService.confirmationToken)
                )
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .autocorrectionDisabled()
                .frame(width: 180)
            }
        } actions: {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            // Deliberately not the default button: Return must never run a
            // verified removal. Only the typed token unlocks it.
            Button(request.kind == .drive ? "Verify and Take Off Drive" : "Verify and Remove from Source", role: .destructive) {
                onConfirm(confirmation)
            }
            .disabled(!Self.isConfirmed(confirmation))
        }
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
/// volume's `_Trash` folder gets its own row in a tinted group box — the
/// line the owner must not miss — and a note keeps it distinct from Finder
/// Trash. Esc cancels; Move to Trash is the red default button (the move
/// is recoverable from the Trash window, which is why Return may run it).
struct TrashConfirmSheet: View {
    let request: PendingTrashRequest
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        SheetScaffold(
            title: "Move \(request.fileCount) file\(request.fileCount == 1 ? "" : "s") to Trash?",
            subtitle: "\(request.byteCount.formattedBytes) · from \(request.locationName)",
            systemImage: "trash.fill",
            iconTint: .orange
        ) {
            destinationCard

            if let note = request.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                    .symbolRenderingMode(.multicolor)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Move to Trash", role: .destructive, action: onConfirm)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// The "where they go" box: one row per volume's `_Trash` folder so the
    /// destination reads as a destination, not a bullet inside a paragraph.
    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where they go")
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
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
            // A hierarchical orange fill (tracks dark mode and Increase
            // Contrast) keeps the destination the line nobody misses.
            .background(.orange.quinary, in: .rect(cornerRadius: 10, style: .continuous))
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
        SheetScaffold(title: "Scan for Faces", subtitle: name, width: 460) {
            Form {
                Section {
                    Picker("Quality", selection: $mode) {
                        Text("Low").tag(FaceScanGrade.low)
                        Text("Medium").tag(FaceScanGrade.med)
                        Text("High").tag(FaceScanGrade.high)
                        Text("Extra High").tag(FaceScanGrade.xhigh)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Fast — pin the Mac", isOn: $fast)
                        .help("Uses every core it can and will run hot. Turn off to keep the machine quiet; same quality, longer wait.")
                } footer: {
                    Text(modeHelp)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !engineInstalled {
                    Section {
                        Label {
                            Text("Face scans need the face engine installed — run \(FaceSidecarInstallation.setupCommand) once on this Mac.")
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Scan") {
                onScan(FaceScanOptions(mode: mode, fast: fast))
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!engineInstalled)
        }
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
