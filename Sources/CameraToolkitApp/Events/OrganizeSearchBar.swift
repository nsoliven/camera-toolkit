import CameraToolkitCore
import SwiftUI

/// The board's search field plus its filter popover — the Immich pattern
/// shaped for Camera Toolkit. The field keeps the free-text match (file
/// name, burst, origin folder, event title); focusing it or tapping the
/// funnel opens a panel of filter chips — People, Date, Event, Media —
/// whose selections AND together with the text. Clear All resets it all.
///
/// Every facet only offers values the board actually has: People lists the
/// roster members and unnamed groups the face index saw on these stacks,
/// the date pickers default to the board's own day range, and the Event
/// facet is hidden on event boards where it would be a no-op.
struct OrganizeSearchBar: View {
    let workspace: EventsWorkspace
    /// The unfiltered board's stacks — the People picker's options and the
    /// date picker's fallback bounds come from these.
    let stacks: [OrganizeStack]
    /// Event boards hide the Event facet — every stack there is in it.
    var showsEventFacet = true
    @Binding var search: OrganizeSearchFilter
    /// The parent's ⌘F focus state — the field stays the find target, and
    /// gaining focus opens the panel.
    var focused: FocusState<Bool>.Binding
    /// Stacks the current search keeps — the footer's "N of M" readout.
    var matchedCount: Int? = nil

    @State private var showFilters = false
    @State private var facet = Facet.people

    private enum Facet: CaseIterable {
        case people, date, event, media

        var title: String {
            switch self {
            case .people: "People"
            case .date: "Date"
            case .event: "Event"
            case .media: "Media"
            }
        }

        var symbol: String {
            switch self {
            case .people: "person.2"
            case .date: "calendar"
            case .event: "rectangle.stack"
            case .media: "photo.on.rectangle.angled"
            }
        }
    }

    private var facets: [Facet] {
        showsEventFacet ? Facet.allCases : Facet.allCases.filter { $0 != .event }
    }

    /// Picks inside one facet — the chip's badge number.
    private func selectionCount(_ facet: Facet) -> Int {
        switch facet {
        case .people: search.peopleIDs.count
        case .date: (search.dayStart == nil && search.dayEnd == nil) ? 0 : 1
        case .event: search.eventIDs.count + (search.includeUnsorted ? 1 : 0)
        case .media: search.mediaKinds.count
        }
    }

    /// Facets filtering right now — the funnel's accent state. Counts only
    /// the chips this board shows: an Event pick carried over from an
    /// unsorted board must not badge an event board's hidden facet.
    private var visibleFacetCount: Int {
        facets.reduce(0) { $0 + (selectionCount($1) > 0 ? 1 : 0) }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $search.text)
                .textFieldStyle(.plain)
                .frame(width: 130)
                .focused(focused)
            if !search.text.isEmpty {
                Button {
                    search.text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
            Button {
                showFilters.toggle()
            } label: {
                Image(systemName: visibleFacetCount > 0
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(visibleFacetCount > 0 ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Filter by people, date, event, or media kind")
        }
        .font(.callout)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help("Filter by file name, burst, folder, or event (⌘F)")
        .popover(isPresented: $showFilters, arrowEdge: .bottom) {
            filterPanel
        }
        .onChange(of: focused.wrappedValue) { _, isFocused in
            if isFocused { showFilters = true }
        }
    }

    // MARK: - Filter panel

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(facets, id: \.self) { item in
                    facetChip(item)
                }
                Spacer(minLength: 0)
            }
            Divider()
            Group {
                switch facet {
                case .people: peoplePanel
                case .date: datePanel
                case .event: eventPanel
                case .media: mediaPanel
                }
            }
            .frame(minHeight: 110, alignment: .top)
            Divider()
            HStack {
                Button("Clear All") {
                    search = OrganizeSearchFilter()
                }
                .disabled(search.isEmpty)
                .help("Reset the search text and every filter")
                Spacer()
                if let matchedCount, !search.isEmpty {
                    Text("\(matchedCount) of \(stacks.count) item\(stacks.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private func facetChip(_ item: Facet) -> some View {
        let count = selectionCount(item)
        let isCurrent = facet == item
        return Button {
            facet = item
        } label: {
            HStack(spacing: 4) {
                Image(systemName: item.symbol)
                    .font(.caption2)
                Text(item.title)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            isCurrent ? Color.accentColor : Color.secondary.opacity(0.35),
                            in: Capsule()
                        )
                        .foregroundStyle(isCurrent ? .white : .primary)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isCurrent ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - People

    private var peoplePanel: some View {
        let people = workspace.boardPeople(for: stacks).options
        return Group {
            if people.isEmpty {
                Text("No people found on this board yet. Run Scan for Faces from the ••• menu to index them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(people) { person in
                            personRow(person)
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
    }

    private func personRow(_ person: FacePerson) -> some View {
        let isOn = search.peopleIDs.contains(person.id)
        return FilterRow(isOn: isOn, symbol: person.isRoster ? "person.fill" : "person.crop.circle.dashed") {
            search.peopleIDs.formSymmetricDifference([person.id])
        } label: {
            Text(person.name)
                .lineLimit(1)
            if !person.isRoster {
                Text("group")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text("\(person.faceCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(person.isRoster
            ? "\(person.faceCount) face\(person.faceCount == 1 ? "" : "s") on this board"
            : "Unnamed group — \(person.faceCount) face\(person.faceCount == 1 ? "" : "s") on this board. Name it in the People window.")
    }

    // MARK: - Date

    /// The board's own day span — the pickers' fallback so an unset end
    /// still shows a meaningful date instead of today.
    private var boardDayRange: (first: Date, last: Date) {
        let dates = stacks.flatMap { [$0.captureDate, $0.endDate] }
        return (dates.min() ?? Date(), dates.max() ?? Date())
    }

    private var datePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("From")
                    .frame(width: 46, alignment: .leading)
                DatePicker(
                    "From",
                    selection: Binding(
                        get: { search.dayStart ?? boardDayRange.first },
                        set: { day in
                            search.dayStart = day
                            if let end = search.dayEnd, day > end { search.dayEnd = day }
                        }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
                if search.dayStart != nil {
                    clearButton { search.dayStart = nil }
                }
            }
            HStack(spacing: 6) {
                Text("Through")
                    .frame(width: 46, alignment: .leading)
                DatePicker(
                    "Through",
                    selection: Binding(
                        get: { search.dayEnd ?? boardDayRange.last },
                        set: { day in
                            search.dayEnd = day
                            if let start = search.dayStart, day < start { search.dayStart = day }
                        }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
                if search.dayEnd != nil {
                    clearButton { search.dayEnd = nil }
                }
            }
            Text("Keeps stacks shot on any day inside the range — endpoints included.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Event

    private var eventPanel: some View {
        let rows = workspace.sidebarEvents
        return VStack(alignment: .leading, spacing: 0) {
            FilterRow(isOn: search.includeUnsorted, symbol: "questionmark.folder") {
                search.includeUnsorted.toggle()
            } label: {
                Text("Not Sorted Yet")
                    .lineLimit(1)
                Spacer(minLength: 6)
            }
            .help("Stacks with no event assignment at all")
            if rows.isEmpty {
                Text("No events yet — sort items into one first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.event.id) { row in
                            eventRow(row)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
    }

    private func eventRow(_ row: (event: SavedCameraEvent, depth: Int)) -> some View {
        let isOn = search.eventIDs.contains(row.event.id)
        return FilterRow(isOn: isOn, color: EventPalette.color(for: row.event.id)) {
            search.eventIDs.formSymmetricDifference([row.event.id])
        } label: {
            Text(workspace.eventTitle(row.event))
                .lineLimit(1)
                .padding(.leading, CGFloat(row.depth) * 10)
            if workspace.resolvedPolicy(for: row.event) == .archiveOnly {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.purple)
            }
            Spacer(minLength: 6)
        }
        .help(workspace.eventTitle(row.event))
    }

    // MARK: - Media

    private var mediaPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                mediaChip(.photo, title: "Stills", symbol: "photo")
                mediaChip(.raw, title: "RAW", symbol: "camera.aperture")
                mediaChip(.video, title: "Video", symbol: "video.fill")
                Spacer(minLength: 0)
            }
            Text("A stack matches when any item in it is a picked kind.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mediaChip(_ kind: OrganizeMediaKind, title: String, symbol: String) -> some View {
        let isOn = search.mediaKinds.contains(kind)
        return Button {
            search.mediaKinds.formSymmetricDifference([kind])
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption2)
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isOn ? .white : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isOn ? Color.accentColor : Color.primary.opacity(0.06),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .help("Stacks containing \(title.lowercased()) items")
    }

    // MARK: - Rows

    private func clearButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear")
    }
}

/// Hover-highlighted toggle row for the filter panel's pickers.
private struct FilterRow<Content: View>: View {
    let isOn: Bool
    var symbol: String? = nil
    var color: Color? = nil
    let action: () -> Void
    @ViewBuilder let label: () -> Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let color {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                if let symbol {
                    Image(systemName: symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                label()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                isHovered ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
