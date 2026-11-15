import AppKit
import CameraToolkitCore
import SwiftUI

/// The one "put this in an event" control shared by the unsorted board's
/// assign bar and the burst preview overlay: up to three recent-event
/// chips wired to the 1–3 keys, then an "Event…" button that opens
/// `EventPickerSheet` (or the caller's own, via `onChooseEvent`) — search
/// over every event, recents first, and
/// "New Event…" for create-and-assign. Replaces the every-event chip
/// strip and flat "All Events" menu, which did not scale past a handful
/// of events.
struct EventAssignControls: View {
    /// How the targets draw. `.chips` is the preview overlay's row of
    /// glass buttons behind a "Move to:" caption; the glass styles are for
    /// the board's bottom bar — `.glass` with names, `.glassNumbers` as
    /// numbered keycaps for narrow windows, `.menu` as one "Sort Into"
    /// menu for the narrowest. Every style is drawn as a button (glass,
    /// a keycap for the shortcut, a small colour dot for the event) and
    /// never as the filled event-colour capsule — that capsule is
    /// `EventChip`, which only ever means "this photo is in this event".
    enum Style {
        case chips
        case glass
        case glassNumbers
        case menu
    }

    let workspace: EventsWorkspace
    /// Verb in tooltips and the sheet title — "Sort into" on an unsorted
    /// board, "Move to" on an event board.
    var verb = "Sort into"
    /// A target that can't be picked — the board's own event when moving
    /// stacks between events. Dropped from the chips and the picker alike.
    var excludedEventID: UUID? = nil
    /// The event the previewed stack is already wholly in. Its recent
    /// button reads as current — a checkmark, disabled — instead of as one
    /// more place to move it.
    var currentEventID: UUID? = nil
    /// False when there is nothing to assign: chips dim and the picker's
    /// event rows deactivate, while "New Event…" stays reachable.
    var canAssign = true
    var style: Style = .chips
    /// The picker sheet's presentation, owned by the caller. Pass it when
    /// this control sits inside a `ViewThatFits` candidate and attach
    /// `eventPickerSheet` outside the `ViewThatFits`: a presentation inside
    /// a candidate only exists while layout keeps picking that candidate,
    /// so a width change mid-flow would drop or re-present the sheet (the
    /// filter popover crashed this way). Nil keeps the sheet on the control.
    var pickerPresented: Binding<Bool>? = nil
    /// Opens the caller's own picker instead — the unsorted board's Sort
    /// Into sheet, presented from the window root. Takes precedence over
    /// `pickerPresented`; the control then attaches no sheet of its own.
    var onChooseEvent: (() -> Void)? = nil
    let onAssign: (SavedCameraEvent) -> Void
    let onNewEvent: () -> Void

    @State private var ownPickerPresented = false

    private var isPickerPresented: Binding<Bool> {
        pickerPresented ?? $ownPickerPresented
    }

    private func chooseEvent() {
        if let onChooseEvent {
            onChooseEvent()
        } else {
            isPickerPresented.wrappedValue = true
        }
    }

    var body: some View {
        let recents = Array(workspace.assignableRecents(excluding: excludedEventID).enumerated())
        Group {
            switch style {
            case .chips:
                HStack(spacing: 8) {
                    if !recents.isEmpty {
                        Text("\(verb.capitalizedFirstLetter):")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                    ForEach(recents, id: \.element.id) { index, event in
                        quickAssignButton(event, index: index, showsName: true)
                    }
                    Button {
                        chooseEvent()
                    } label: {
                        Label("Event…", systemImage: "calendar")
                    }
                    .help("Search every event by name, or create a new one")
                    .accessibilityLabel("\(verb.capitalizedFirstLetter) another event…")
                }
                // Glass reads on the preview's black backdrop in both
                // appearances; a bordered button vanished in light mode.
                // The overlay is always dark, so its buttons are too.
                .buttonStyle(.glass)
                .environment(\.colorScheme, .dark)
            case .glass, .glassNumbers:
                HStack(spacing: 6) {
                    ForEach(recents, id: \.element.id) { index, event in
                        quickAssignButton(event, index: index, showsName: style == .glass)
                    }
                    Button {
                        chooseEvent()
                    } label: {
                        Label("Event…", systemImage: "calendar")
                    }
                    .labelStyle(style == .glassNumbers ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                    .help("Search every event by name, or create a new one")
                    .accessibilityLabel("\(verb.capitalizedFirstLetter) another event…")
                }
                .buttonStyle(.glass)
            case .menu:
                Menu {
                    ForEach(recents, id: \.element.id) { index, event in
                        let isCurrent = event.id == currentEventID
                        Button {
                            onAssign(event)
                        } label: {
                            if isCurrent {
                                Label("\(index + 1)  \(workspace.eventTitle(event))", systemImage: "checkmark")
                            } else {
                                Text("\(index + 1)  \(workspace.eventTitle(event))")
                            }
                        }
                        .disabled(!canAssign || isCurrent)
                        .accessibilityLabel(accessibilityLabel(for: event, isCurrent: isCurrent))
                    }
                    if !recents.isEmpty {
                        Divider()
                    }
                    Button("Choose Event…") { chooseEvent() }
                    Button("New Event…") { onNewEvent() }
                } label: {
                    Label(verb.capitalizedFirstWord, systemImage: "tray.and.arrow.down")
                }
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .fixedSize()
                .help("\(verb) a recent event (1–3), or pick any event")
            }
        }
        .modifier(OwnPickerSheet(
            isEnabled: pickerPresented == nil && onChooseEvent == nil,
            isPresented: $ownPickerPresented,
            workspace: workspace,
            verb: verb,
            excludedEventID: excludedEventID,
            canAssign: canAssign,
            onPick: onAssign,
            onNewEvent: onNewEvent
        ))
    }

    /// One recent target as a button: keycap, colour dot (a checkmark when
    /// the photo is already there), lock for private, then the name.
    private func quickAssignButton(_ event: SavedCameraEvent, index: Int, showsName: Bool) -> some View {
        let isCurrent = event.id == currentEventID
        return Button {
            onAssign(event)
        } label: {
            QuickAssignLabel(
                number: index + 1,
                name: event.name,
                color: EventPalette.color(for: event.id),
                isPrivate: workspace.resolvedPolicy(for: event) == .archiveOnly,
                isCurrent: isCurrent,
                showsName: showsName
            )
        }
        .disabled(!canAssign || isCurrent)
        .help(help(for: event, index: index, isCurrent: isCurrent))
        .accessibilityLabel(accessibilityLabel(for: event, isCurrent: isCurrent))
        .accessibilityHint(isCurrent ? "" : "Shortcut: \(index + 1)")
    }

    private func help(for event: SavedCameraEvent, index: Int, isCurrent: Bool) -> String {
        let title = workspace.eventTitle(event)
        if isCurrent {
            return "Already in \(title)"
        }
        return "\(verb.capitalizedFirstLetter) \(title) (\(index + 1))"
    }

    private func accessibilityLabel(for event: SavedCameraEvent, isCurrent: Bool) -> String {
        let title = workspace.eventTitle(event)
        let privacy = workspace.resolvedPolicy(for: event) == .archiveOnly ? ", private" : ""
        return isCurrent ? "Already in \(title)\(privacy)" : "\(verb.capitalizedFirstLetter) \(title)\(privacy)"
    }
}

/// A quick-assign button's content: the digit as a keycap-style shortcut
/// hint, the event's colour as a small dot (a checkmark when the photo is
/// already there), a lock for private events, and the name. Text stays in
/// the button's own foreground colour — the event colour is only the dot —
/// so it never reads as the filled assignment badge.
struct QuickAssignLabel: View {
    let number: Int
    let name: String
    let color: Color
    var isPrivate = false
    var isCurrent = false
    var showsName = true

    var body: some View {
        HStack(spacing: 6) {
            ShortcutKeycap(text: "\(number)")
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
            } else {
                // A non-template bitmap: glass buttons can draw their label
                // monochrome, which would bleach a plain shape's fill.
                Image(nsImage: Self.dot(color))
                    .accessibilityHidden(true)
            }
            if showsName {
                if isPrivate {
                    Image(systemName: "lock.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                Text(name)
                    .lineLimit(1)
            }
        }
    }
}

extension QuickAssignLabel {
    /// An 8 pt circle in `color`, marked non-template so button styles
    /// keep its colour.
    static func dot(_ color: Color) -> NSImage {
        let fill = NSColor(color)
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A key drawn as a small outlined keycap — the shortcut hint on a button.
struct ShortcutKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 11)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.7), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

/// Picks between two label styles at runtime.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some LabelStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

private extension String {
    /// "sort into" → "Sort Into"-style title case for a menu label.
    var capitalizedFirstWord: String {
        split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// "sort into" → "Sort into", for sentence-style help and VoiceOver.
    var capitalizedFirstLetter: String {
        prefix(1).uppercased() + dropFirst()
    }
}

/// One row of the event picker: an event in one section, with its sidebar
/// indent. Plain data, so the picker's filtering, ordering and keyboard
/// highlight are decided (and tested) outside SwiftUI.
struct EventPickerEntry: Identifiable, Equatable {
    enum Section: String, Equatable {
        case recent
        case all
        case matches

        var title: String {
            switch self {
            case .recent: "Recent"
            case .all: "All Events"
            case .matches: "Matches"
            }
        }
    }

    var section: Section
    var eventID: UUID
    /// Sidebar depth: 0 for a top-level event, 1+ for a subevent. Recent
    /// rows are flat (they show the breadcrumb title instead).
    var depth: Int
    var id: String { "\(section.rawValue):\(eventID.uuidString)" }
}

enum EventPickerList {
    /// The picker's rows. Recent events that match come first. Without a
    /// search, every event follows in sidebar order with its indent —
    /// recents included, so the tree under a parent stays whole. With a
    /// search, the other matches follow in sidebar order. `sidebarRows`
    /// is the sidebar already filtered by the query; `allowedIDs` (nil =
    /// every event) and `excludedID` drop events that are not targets.
    static func entries(
        recentIDs: [UUID],
        sidebarRows: [(id: UUID, depth: Int)],
        allowedIDs: Set<UUID>?,
        excludedID: UUID?,
        searching: Bool
    ) -> [EventPickerEntry] {
        let rows = sidebarRows.filter { row in
            row.id != excludedID && (allowedIDs?.contains(row.id) ?? true)
        }
        let rowIDs = Set(rows.map(\.id))
        var seen = Set<UUID>()
        let recent = recentIDs.filter { rowIDs.contains($0) && seen.insert($0).inserted }
        var entries = recent.map { EventPickerEntry(section: .recent, eventID: $0, depth: 0) }
        if searching {
            entries += rows.filter { !seen.contains($0.id) }
                .map { EventPickerEntry(section: .matches, eventID: $0.id, depth: $0.depth) }
        } else {
            entries += rows.map { EventPickerEntry(section: .all, eventID: $0.id, depth: $0.depth) }
        }
        return entries
    }

    /// The highlighted row: `current` while it is still listed, otherwise
    /// the first row (what Return picks right after typing).
    static func highlight(_ current: String?, in entries: [EventPickerEntry]) -> String? {
        if let current, entries.contains(where: { $0.id == current }) { return current }
        return entries.first?.id
    }

    /// The highlight after an arrow key: `delta` rows on, clamped to the
    /// list's ends.
    static func move(_ current: String?, by delta: Int, in entries: [EventPickerEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        guard let id = highlight(current, in: entries),
              let index = entries.firstIndex(where: { $0.id == id }) else { return entries.first?.id }
        let next = min(max(index + delta, 0), entries.count - 1)
        return entries[next].id
    }
}

/// The searchable event picker — the unsorted board's "Sort Into…" sheet
/// and the "Event…" button's sheet. The search field has focus: typing
/// filters, ↑/↓ move the highlight, Return picks the highlighted event,
/// Esc cancels, and a double-click picks a row. Recent events lead, then
/// every event in sidebar order with subevents indented. "New Event…"
/// hands the same selection to the New Event sheet. Picking only calls
/// `onPick`; what that does (a catalog-only sort) is the caller's.
struct EventPickerSheet: View {
    let workspace: EventsWorkspace
    var verb = "Sort into"
    /// A line under the title — what will be sorted, and from where.
    var summary: String? = nil
    var excludedEventID: UUID? = nil
    /// Only these events are offered (nil = every event).
    var allowedEventIDs: Set<UUID>? = nil
    var canAssign = true
    let onPick: (SavedCameraEvent) -> Void
    /// Nil hides the New Event… button (a picker that only chooses).
    var onNewEvent: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlightedID: String?
    /// Set once a choice is made, so a Return the field and the default
    /// button both see can never pick twice.
    @State private var finished = false
    @State private var refocus = 0

    private var searching: Bool { !OrganizeSearch.needle(query).isEmpty }

    var body: some View {
        let rows = workspace.sidebarRows(matching: query)
        let eventsByID = Dictionary(rows.map { ($0.event.id, $0.event) }, uniquingKeysWith: { first, _ in first })
        let entries = EventPickerList.entries(
            recentIDs: workspace.recentEvents.map(\.id),
            sidebarRows: rows.map { (id: $0.event.id, depth: $0.depth) },
            allowedIDs: allowedEventIDs,
            excludedID: excludedEventID,
            searching: searching
        )
        let current = EventPickerList.highlight(highlightedID, in: entries)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(verb) an Event")
                    .font(.title2.bold())
                if let summary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                EventPickerSearchField(
                    text: $query,
                    refocus: refocus,
                    onMove: { highlightedID = EventPickerList.move(current, by: $0, in: entries) },
                    onSubmit: { submit(current, eventsByID: eventsByID, entries: entries) },
                    onCancel: cancel
                )
                .frame(height: 20)
                if !query.isEmpty {
                    Button {
                        query = ""
                        refocus += 1
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
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            VStack(alignment: .leading, spacing: 0) {
                                if index == 0 || entries[index - 1].section != entry.section {
                                    sectionHeader(entry.section.title)
                                }
                                if let event = eventsByID[entry.eventID] {
                                    row(entry, event: event, isHighlighted: entry.id == current)
                                }
                            }
                            .id(entry.id)
                        }
                        if entries.isEmpty {
                            Text(searching
                                ? "No events match “\(query)”."
                                : "No events yet — make one below.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 12)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: current) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            Divider()
            HStack {
                if let onNewEvent {
                    Button {
                        guard !finished else { return }
                        finished = true
                        onNewEvent()
                        dismiss()
                    } label: {
                        Label("New Event…", systemImage: "plus")
                    }
                    .help("Create an event and \(verb.lowercased()) the selection into it")
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(verb.capitalizedFirstWord) {
                    submit(current, eventsByID: eventsByID, entries: entries)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAssign || current == nil)
            }
        }
        .padding(20)
        .frame(width: 480, height: 520)
        .onChange(of: query) { highlightedID = nil }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(_ entry: EventPickerEntry, event: SavedCameraEvent, isHighlighted: Bool) -> some View {
        // The tree shows each event's own name under its indent; flat
        // sections (Recent, Matches) show the breadcrumb.
        let title = entry.section == .all ? event.name : workspace.eventTitle(event)
        return EventPickerRow(
            title: title,
            detail: event.eventDate.formatted(date: .abbreviated, time: .omitted),
            color: EventPalette.color(for: event.id),
            isPrivate: workspace.resolvedPolicy(for: event) == .archiveOnly,
            depth: entry.depth,
            isHighlighted: isHighlighted,
            isEnabled: canAssign,
            onHighlight: {
                highlightedID = entry.id
                refocus += 1
            },
            onPick: { pick(event) }
        )
        .help("\(verb) \(workspace.eventTitle(event)) — double-click, or press Return")
    }

    private func submit(_ current: String?, eventsByID: [UUID: SavedCameraEvent], entries: [EventPickerEntry]) {
        guard let current,
              let entry = entries.first(where: { $0.id == current }),
              let event = eventsByID[entry.eventID] else { return }
        pick(event)
    }

    private func pick(_ event: SavedCameraEvent) {
        guard canAssign, !finished else { return }
        finished = true
        onPick(event)
        dismiss()
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        onCancel?()
        dismiss()
    }
}

/// One picker row: indent, the event's color dot, its title, a lock for
/// private events, and its date. A click highlights it, a double-click
/// picks it.
private struct EventPickerRow: View {
    let title: String
    var detail: String? = nil
    var color: Color = .accentColor
    var isPrivate = false
    var depth = 0
    var isHighlighted = false
    var isEnabled = true
    let onHighlight: () -> Void
    let onPick: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(title)
                .lineLimit(1)
            if isPrivate {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 8 + CGFloat(depth) * 16)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture(count: 2) { if isEnabled { onPick() } }
        .simultaneousGesture(TapGesture().onEnded { onHighlight() })
        .onHover { isHovered = $0 }
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if isEnabled { onPick() } }
    }

    private var background: Color {
        if isHighlighted { return Color.accentColor.opacity(0.25) }
        return isHovered && isEnabled ? Color.accentColor.opacity(0.1) : .clear
    }
}

/// The picker's search field: an AppKit text field so ↑/↓, Return and
/// Esc reach the picker while the field keeps the typing. It takes focus
/// when it appears and again whenever `refocus` changes.
private struct EventPickerSearchField: NSViewRepresentable {
    @Binding var text: String
    var refocus: Int
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = "Search events"
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Search events")
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.lastRefocus != refocus {
            context.coordinator.lastRefocus = refocus
            if field.currentEditor() == nil {
                field.window?.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: EventPickerSearchField
        var lastRefocus: Int

        init(_ parent: EventPickerSearchField) {
            self.parent = parent
            lastRefocus = parent.refocus
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}

/// The control's own picker sheet, attached only when the caller did not
/// take the presentation over with `pickerPresented`.
private struct OwnPickerSheet: ViewModifier {
    let isEnabled: Bool
    @Binding var isPresented: Bool
    let workspace: EventsWorkspace
    let verb: String
    let excludedEventID: UUID?
    let canAssign: Bool
    let onPick: (SavedCameraEvent) -> Void
    let onNewEvent: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.eventPickerSheet(
                isPresented: $isPresented,
                workspace: workspace,
                verb: verb,
                excludedEventID: excludedEventID,
                canAssign: canAssign,
                onPick: onPick,
                onNewEvent: onNewEvent
            )
        } else {
            content
        }
    }
}

extension View {
    /// `EventAssignControls`' event picker, for a caller that owns the
    /// presentation (see `EventAssignControls.pickerPresented`).
    func eventPickerSheet(
        isPresented: Binding<Bool>,
        workspace: EventsWorkspace,
        verb: String,
        excludedEventID: UUID? = nil,
        canAssign: Bool = true,
        onPick: @escaping (SavedCameraEvent) -> Void,
        onNewEvent: @escaping () -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            EventPickerSheet(
                workspace: workspace,
                verb: verb,
                excludedEventID: excludedEventID,
                canAssign: canAssign,
                onPick: onPick,
                onNewEvent: onNewEvent
            )
        }
    }
}
