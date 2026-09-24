import AppKit
import CameraToolkitCore
import SwiftUI

/// The one "put this in an event" control shared by the unsorted board's
/// assign bar and the burst preview overlay: up to three recent-event
/// chips wired to the 1–3 keys, then an "Event…" button that opens
/// `EventPickerSheet` — search over every event, recents first, and
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
    let onAssign: (SavedCameraEvent) -> Void
    let onNewEvent: () -> Void

    @State private var isPickerPresented = false

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
                        isPickerPresented = true
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
                        isPickerPresented = true
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
                    Button("Choose Event…") { isPickerPresented = true }
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
        .sheet(isPresented: $isPickerPresented) {
            EventPickerSheet(
                workspace: workspace,
                verb: verb,
                excludedEventID: excludedEventID,
                canAssign: canAssign,
                onPick: onAssign,
                onNewEvent: onNewEvent
            )
        }
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

/// The searchable event picker behind "Event…". Matching recents pin to a
/// Recent section; every other match follows in sidebar order under its
/// breadcrumb title ("TRIP2026 / Matcha"). Return picks the top match and
/// "New Event…" runs the same create-and-assign flow as everywhere else.
struct EventPickerSheet: View {
    let workspace: EventsWorkspace
    var verb = "Sort into"
    var excludedEventID: UUID? = nil
    var canAssign = true
    let onPick: (SavedCameraEvent) -> Void
    let onNewEvent: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var searching: Bool { !OrganizeSearch.needle(query).isEmpty }

    private var sections: (recent: [SavedCameraEvent], other: [(event: SavedCameraEvent, depth: Int)]) {
        workspace.eventPickerSections(matching: query, excluding: excludedEventID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(verb) an Event")
                .font(.title2.bold())
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search events", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(pickFirst)
                if !query.isEmpty {
                    Button {
                        query = ""
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !sections.recent.isEmpty {
                        sectionHeader("Recent")
                        ForEach(sections.recent) { event in
                            eventRow(event)
                        }
                    }
                    if !sections.other.isEmpty {
                        sectionHeader(searching ? "Matches" : "All Events")
                        ForEach(sections.other, id: \.event.id) { row in
                            eventRow(row.event)
                        }
                    }
                    if sections.recent.isEmpty && sections.other.isEmpty {
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
            Divider()
            HStack {
                Button {
                    // Close first so the New Event sheet opens cleanly.
                    dismiss()
                    onNewEvent()
                } label: {
                    Label("New Event…", systemImage: "plus")
                }
                .help("Create an event and \(verb.lowercased()) the selection into it")
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 500)
        .onAppear { searchFocused = true }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func eventRow(_ event: SavedCameraEvent) -> some View {
        EventPickerRow(
            title: workspace.eventTitle(event),
            detail: event.eventDate.formatted(date: .abbreviated, time: .omitted),
            color: EventPalette.color(for: event.id),
            isPrivate: workspace.resolvedPolicy(for: event) == .archiveOnly,
            isEnabled: canAssign
        ) {
            pick(event)
        }
        .help("\(verb) \(workspace.eventTitle(event))")
    }

    private func pick(_ event: SavedCameraEvent) {
        guard canAssign else { return }
        onPick(event)
        dismiss()
    }

    private func pickFirst() {
        guard let event = sections.recent.first ?? sections.other.first?.event else { return }
        pick(event)
    }
}

/// One tappable picker row: the event's color dot, breadcrumb title, a
/// lock for private events, and its date — with a hover highlight.
private struct EventPickerRow: View {
    let title: String
    var detail: String? = nil
    var color: Color = .accentColor
    var isPrivate = false
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
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
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                isHovered && isEnabled ? Color.accentColor.opacity(0.15) : .clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovered = $0 }
    }
}
