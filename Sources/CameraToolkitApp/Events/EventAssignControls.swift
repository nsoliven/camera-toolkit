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
    let workspace: EventsWorkspace
    /// Verb in tooltips and the sheet title — "Sort into" on an unsorted
    /// board, "Move to" on an event board.
    var verb = "Sort into"
    /// A target that can't be picked — the board's own event when moving
    /// stacks between events. Dropped from the chips and the picker alike.
    var excludedEventID: UUID? = nil
    /// False when there is nothing to assign: chips dim and the picker's
    /// event rows deactivate, while "New Event…" stays reachable.
    var canAssign = true
    let onAssign: (SavedCameraEvent) -> Void
    let onNewEvent: () -> Void

    @State private var isPickerPresented = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(workspace.assignableRecents(excluding: excludedEventID).enumerated()), id: \.element.id) { index, event in
                Button {
                    onAssign(event)
                } label: {
                    EventChip(
                        event: event,
                        number: index + 1,
                        isPrivate: workspace.resolvedPolicy(for: event) == .archiveOnly
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canAssign)
                .opacity(canAssign ? 1 : 0.5)
                .help("\(verb) \(workspace.eventTitle(event)) (press \(index + 1))")
            }
            Button {
                isPickerPresented = true
            } label: {
                Label("Event…", systemImage: "calendar")
            }
            .help("Search every event by name, or create a new one")
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
}

/// The searchable event picker behind "Event…". Matching recents pin to a
/// Recent section; every other match follows in sidebar order under its
/// breadcrumb title ("PHIL2026 / Matcha"). Return picks the top match and
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
