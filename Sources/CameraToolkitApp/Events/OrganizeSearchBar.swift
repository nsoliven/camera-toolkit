import CameraToolkitCore
import SwiftUI

/// The board's search field plus its filter-builder popover. The field
/// keeps the free-text match (file name, burst, origin folder, event
/// title); focusing it or tapping the funnel opens a panel of condition
/// rows — People, Date, Event, Media — ANDed inside a group, with groups
/// ORed. Both AND with the text. Clear All resets it all.
///
/// Rows only offer values the board actually has: People lists the roster
/// members and unnamed groups the face index saw on these stacks, the date
/// pickers default to the board's own day range, and the Event property is
/// hidden on event boards where it would be a no-op.
struct OrganizeSearchBar: View {
    let workspace: EventsWorkspace
    /// The unfiltered board's stacks — the People picker's options and the
    /// date picker's fallback bounds come from these.
    let stacks: [OrganizeStack]
    /// Event boards hide the Event property — every stack there is in it.
    var showsEventFacet = true
    @Binding var search: OrganizeSearchFilter
    /// The parent's ⌘F focus state — the field stays the find target, and
    /// gaining focus opens the panel.
    var focused: FocusState<Bool>.Binding
    /// Stacks the current search keeps — the footer's "N of M" readout.
    var matchedCount: Int? = nil

    @State private var showFilters = false

    /// The properties a new or edited row can point at, in menu order.
    private var properties: [OrganizeFilterRow.Property] {
        let all: [OrganizeFilterRow.Property] = [.people, .date, .event, .media]
        return showsEventFacet ? all : all.filter { $0 != .event }
    }

    /// Rows filtering right now — the funnel's accent state. Counts only
    /// what this board shows: an Event row carried over from an unsorted
    /// board must not badge an event board's hidden property.
    private var visibleRowCount: Int {
        search.groups.reduce(0) { count, group in
            count + group.rows.filter {
                !$0.isEmpty && (showsEventFacet || $0.property != .event)
            }.count
        }
    }

    /// The people this board can offer a People row — roster members and
    /// unnamed groups the face index saw on these stacks, roster first.
    private var peopleOptions: [FacePerson] {
        workspace.boardPeople(for: stacks).options
    }

    /// The board's own day span — the pickers' fallback so an unset end
    /// still shows a meaningful date instead of today.
    private var boardDayRange: (first: Date, last: Date) {
        let dates = stacks.flatMap { [$0.captureDate, $0.endDate] }
        return (dates.min() ?? Date(), dates.max() ?? Date())
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
                Image(systemName: visibleRowCount > 0
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(visibleRowCount > 0 ? Color.accentColor : Color.secondary)
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
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($search.groups) { $group in
                        if group.id != search.groups.first?.id {
                            orSeparator
                        }
                        ForEach($group.rows) { $row in
                            conditionRow(row: $row) {
                                group.rows.removeAll { $0.id == row.id }
                                // A second group exists to OR against —
                                // removing its last row removes the group.
                                if group.rows.isEmpty, search.groups.count > 1 {
                                    search.groups.removeAll { $0.id == group.id }
                                }
                            }
                        }
                        addFilterButton("Add a row to this group — every row in a group must match") {
                            group.rows.append(OrganizeFilterRow(property: .people))
                        }
                    }
                    if !search.groups.isEmpty {
                        orSeparator
                    }
                    addFilterButton(search.groups.isEmpty
                        ? "Add a condition row"
                        : "Start another group — a stack stays when any group matches") {
                        search.groups.append(OrganizeFilterGroup(
                            rows: [OrganizeFilterRow(property: .people)]
                        ))
                    }
                    if search.groups.isEmpty {
                        Text("Rows in a group all have to match; groups joined by “or” match either way.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 360)
            Divider()
            HStack {
                Button("Clear All") {
                    search = OrganizeSearchFilter()
                }
                .disabled(search.isUntouched)
                .help("Reset the search text and every filter")
                Spacer()
                if let matchedCount, !search.isEmpty {
                    Text("\(matchedCount) of \(stacks.count) item\(stacks.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .frame(width: 400)
    }

    /// The "or" line between groups — rows above and below it OR.
    private var orSeparator: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
            Text("or")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
        }
    }

    private func addFilterButton(_ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Filter", systemImage: "plus")
        }
        .controlSize(.small)
        .help(help)
    }

    // MARK: - Condition rows

    /// One builder row: property and operator on top, the picked values as
    /// removable chips underneath, and a control removing the whole row.
    /// An Event row carried to an event board stays in the filter but
    /// renders nothing — it does not filter there.
    @ViewBuilder
    private func conditionRow(row: Binding<OrganizeFilterRow>, onRemove: @escaping () -> Void) -> some View {
        if row.wrappedValue.property == .event, !showsEventFacet {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Picker("Property", selection: Binding(
                        get: { row.wrappedValue.property },
                        set: { row.wrappedValue.setProperty($0) }
                    )) {
                        ForEach(properties, id: \.self) { property in
                            Text(property.title).tag(property)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()

                    if row.wrappedValue.property != .date {
                        Picker("Operator", selection: row.operator) {
                            ForEach(OrganizeFilterRow.Operator.allCases, id: \.self) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                    }
                    Spacer(minLength: 4)
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this row")
                }

                switch row.wrappedValue.property {
                case .date:
                    dateValues(row)
                case .people:
                    peopleValues(row)
                case .event:
                    eventValues(row)
                case .media:
                    mediaValues(row)
                }
            }
            .padding(7)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// A removable picked value inside a row.
    private func valueChip(
        _ title: String,
        symbol: String? = nil,
        color: Color? = nil,
        help: String? = nil,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            if let color {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this value")
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.09), in: Capsule())
        .help(help ?? title)
    }

    /// The small circled plus that opens a row's value picker.
    private var addValueLabel: some View {
        Image(systemName: "plus")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .background(Color.primary.opacity(0.07), in: Circle())
    }

    // MARK: - People values

    private func peopleValues(_ row: Binding<OrganizeFilterRow>) -> some View {
        let options = peopleOptions
        let picked = options.filter { row.wrappedValue.peopleIDs.contains($0.id) }
        // Picks the board no longer offers stay removable as stale chips.
        let stale = row.wrappedValue.peopleIDs
            .subtracting(options.map(\.id))
            .sorted { $0.uuidString < $1.uuidString }
        return FlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
            ForEach(picked) { person in
                valueChip(
                    person.name,
                    symbol: person.isRoster ? "person.fill" : "person.crop.circle.dashed",
                    help: person.isRoster
                        ? "\(person.faceCount) face\(person.faceCount == 1 ? "" : "s") on this board"
                        : "Unnamed group — \(person.faceCount) face\(person.faceCount == 1 ? "" : "s") on this board. Name it in the People window."
                ) {
                    row.wrappedValue.peopleIDs.remove(person.id)
                }
            }
            ForEach(stale, id: \.self) { id in
                valueChip("Unknown person", symbol: "person.fill.questionmark") {
                    row.wrappedValue.peopleIDs.remove(id)
                }
            }
            if options.isEmpty {
                Text("No people found on this board yet. Run Scan for Faces from the ••• menu to index them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let unpicked = options.filter { !row.wrappedValue.peopleIDs.contains($0.id) }
                Menu {
                    ForEach(unpicked) { person in
                        Button {
                            row.wrappedValue.peopleIDs.insert(person.id)
                        } label: {
                            Label(
                                person.name,
                                systemImage: person.isRoster ? "person.fill" : "person.crop.circle.dashed"
                            )
                        }
                    }
                } label: {
                    addValueLabel
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(unpicked.isEmpty)
                .help("Add a person to this row")
            }
        }
    }

    // MARK: - Event values

    private func eventValues(_ row: Binding<OrganizeFilterRow>) -> some View {
        let rows = workspace.sidebarEvents
        let picked = rows.filter { row.wrappedValue.eventIDs.contains($0.event.id) }
        let stale = row.wrappedValue.eventIDs
            .subtracting(rows.map(\.event.id))
            .sorted { $0.uuidString < $1.uuidString }
        return FlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
            if row.wrappedValue.includesUnsorted {
                valueChip("Not Sorted Yet", symbol: "questionmark.folder", help: "Stacks with no event assignment at all") {
                    row.wrappedValue.includesUnsorted = false
                }
            }
            ForEach(picked, id: \.event.id) { eventRow in
                valueChip(
                    workspace.eventTitle(eventRow.event),
                    color: EventPalette.color(for: eventRow.event.id)
                ) {
                    row.wrappedValue.eventIDs.remove(eventRow.event.id)
                }
            }
            ForEach(stale, id: \.self) { id in
                valueChip("Deleted event", symbol: "questionmark.folder") {
                    row.wrappedValue.eventIDs.remove(id)
                }
            }
            if rows.isEmpty, !row.wrappedValue.includesUnsorted {
                Text("No events yet — sort items into one first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let unpicked = rows.filter { !row.wrappedValue.eventIDs.contains($0.event.id) }
                Menu {
                    if !row.wrappedValue.includesUnsorted {
                        Button {
                            row.wrappedValue.includesUnsorted = true
                        } label: {
                            Label("Not Sorted Yet", systemImage: "questionmark.folder")
                        }
                    }
                    ForEach(unpicked, id: \.event.id) { eventRow in
                        Button {
                            row.wrappedValue.eventIDs.insert(eventRow.event.id)
                        } label: {
                            Label {
                                Text(workspace.eventTitle(eventRow.event))
                            } icon: {
                                Circle()
                                    .fill(EventPalette.color(for: eventRow.event.id))
                                    .frame(width: 7, height: 7)
                            }
                        }
                    }
                } label: {
                    addValueLabel
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(unpicked.isEmpty && row.wrappedValue.includesUnsorted)
                .help("Add an event to this row")
            }
        }
    }

    // MARK: - Media values

    /// The kinds a Media row can pick, in menu order — same three the old
    /// facet offered.
    private static let mediaOptions: [(kind: OrganizeMediaKind, title: String, symbol: String)] = [
        (.photo, "Stills", "photo"),
        (.raw, "RAW", "camera.aperture"),
        (.video, "Video", "video.fill"),
    ]

    private func mediaValues(_ row: Binding<OrganizeFilterRow>) -> some View {
        let picked = Self.mediaOptions.filter { row.wrappedValue.mediaKinds.contains($0.kind) }
        return FlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
            ForEach(picked, id: \.kind) { option in
                valueChip(option.title, symbol: option.symbol, help: "Stacks containing \(option.title.lowercased()) items") {
                    row.wrappedValue.mediaKinds.remove(option.kind)
                }
            }
            let unpicked = Self.mediaOptions.filter { !row.wrappedValue.mediaKinds.contains($0.kind) }
            Menu {
                ForEach(unpicked, id: \.kind) { option in
                    Button {
                        row.wrappedValue.mediaKinds.insert(option.kind)
                    } label: {
                        Label(option.title, systemImage: option.symbol)
                    }
                }
            } label: {
                addValueLabel
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(unpicked.isEmpty)
            .help("Add a media kind to this row")
        }
    }

    // MARK: - Date values

    private func dateValues(_ row: Binding<OrganizeFilterRow>) -> some View {
        HStack(spacing: 6) {
            Text("From")
            DatePicker(
                "From",
                selection: Binding(
                    get: { row.wrappedValue.dayStart ?? boardDayRange.first },
                    set: { day in
                        row.wrappedValue.dayStart = day
                        if let end = row.wrappedValue.dayEnd, day > end { row.wrappedValue.dayEnd = day }
                    }
                ),
                displayedComponents: .date
            )
            .labelsHidden()
            if row.wrappedValue.dayStart != nil {
                clearButton { row.wrappedValue.dayStart = nil }
            }
            Text("Through")
            DatePicker(
                "Through",
                selection: Binding(
                    get: { row.wrappedValue.dayEnd ?? boardDayRange.last },
                    set: { day in
                        row.wrappedValue.dayEnd = day
                        if let start = row.wrappedValue.dayStart, day < start { row.wrappedValue.dayStart = day }
                    }
                ),
                displayedComponents: .date
            )
            .labelsHidden()
            if row.wrappedValue.dayEnd != nil {
                clearButton { row.wrappedValue.dayEnd = nil }
            }
        }
        .font(.caption)
    }

    private func clearButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear")
    }
}

/// Left-to-right wrapping layout — a row's value chips flow onto the next
/// line instead of clipping.
private struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0
        var height: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                x = 0
                height += lineHeight + verticalSpacing
                lineHeight = 0
            }
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, min(x - horizontalSpacing, limit))
        }
        return CGSize(width: usedWidth, height: height + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
