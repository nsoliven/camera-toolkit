import CameraToolkitCore
import SwiftUI

/// The board's filter button. It only toggles `isPresented` and reports
/// its bounds; the popover itself is attached once, outside the bottom
/// bar's `ViewThatFits`, by `boardFilterPopover` — see there for why.
struct OrganizeFilterButton: View {
    @Binding var isPresented: Bool
    let search: OrganizeSearchFilter

    var body: some View {
        let active = search.activeRowCount
        Button {
            isPresented.toggle()
        } label: {
            Label(active > 0 ? "Filters On" : "Filter", systemImage: "line.3.horizontal.decrease")
                .symbolVariant(active > 0 ? .circle.fill : .none)
                .foregroundStyle(active > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .help(active > 0
            ? "\(active) filter\(active == 1 ? "" : "s") on — people, date, event, media kind, camera, or edit tag"
            : "Filter by people, date, event, media kind, camera, or edit tag")
        .anchorPreference(key: BoardFilterAnchorKey.self, value: .bounds) { $0 }
    }
}

/// Where the visible filter button sits, for the one popover presenter.
/// `ViewThatFits` forwards preferences only from the candidate it picked,
/// so this is always the button the owner can see.
struct BoardFilterAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Presents the filter panel from the filter button inside this view.
    ///
    /// Apply it OUTSIDE the bottom bar's `ViewThatFits`, never inside a
    /// candidate. A popover is a preference, and `ViewThatFits` picks its
    /// candidate — and so whose preferences it forwards — during layout.
    /// With the popover inside each candidate (each with its own
    /// presentation state), a filter edit that nudged the bar across a fit
    /// threshold swapped candidates mid-layout: the open popover's
    /// presentation vanished and came back, and every swap made SwiftUI's
    /// popover bridge re-update the popover and invalidate constraints
    /// inside the window's layout pass until AppKit threw "more Update
    /// Constraints in Window passes than there are views" (the 2026-09-24
    /// crash). Here one stable view owns the presentation; a candidate swap
    /// only moves the arrow.
    func boardFilterPopover(
        isPresented: Binding<Bool>,
        workspace: EventsWorkspace,
        stacks: [OrganizeStack],
        eventScope: Set<UUID>? = nil,
        search: Binding<OrganizeSearchFilter>,
        matchedCount: Int? = nil
    ) -> some View {
        overlayPreferenceValue(BoardFilterAnchorKey.self) { anchor in
            GeometryReader { proxy in
                // Before the first layout reports the button, point at the
                // bar's top edge rather than not presenting at all.
                let rect = anchor.map { proxy[$0] }
                    ?? CGRect(x: proxy.size.width / 2, y: 0, width: 1, height: 1)
                Color.clear
                    .allowsHitTesting(false)
                    .popover(
                        isPresented: isPresented,
                        attachmentAnchor: .rect(.rect(rect)),
                        arrowEdge: .top
                    ) {
                        OrganizeFilterPanel(
                            workspace: workspace,
                            stacks: stacks,
                            eventScope: eventScope,
                            search: search,
                            matchedCount: matchedCount
                        )
                    }
            }
        }
    }
}

/// The filter-builder panel the filter button opens. The search
/// text lives in the window's toolbar field; this panel holds condition
/// rows — People, Date, Event, Media, Camera. Every condition added ANDs into the
/// one group by default; an "or" group is a separate, labelled action.
/// Above them sit the subevent chips' "Always hiding" exclusions, which
/// AND with everything. All of it ANDs with the text; Clear All resets it.
///
/// Rows only offer values the board actually has: People lists the roster
/// members and unnamed groups the face index saw on these stacks, the date
/// pickers default to the board's own day range, and on an event board the
/// Event picker narrows to the board's family — the event plus its
/// subevents — since picks outside it cannot match there. Camera lists
/// each camera found on the board with its stack count.
///
/// The panel has a fixed width and scrolls past a fixed maximum height, so
/// adding rows never makes its ideal size depend on the board's layout.
struct OrganizeFilterPanel: View {
    let workspace: EventsWorkspace
    /// The unfiltered board's stacks — the People picker's options and the
    /// date picker's fallback bounds come from these.
    let stacks: [OrganizeStack]
    /// An event board's family scope — the Event picker offers just those
    /// events and drops "Not Sorted Yet", which can never match there.
    /// Nil on unsorted boards, where every event is a valid pick.
    var eventScope: Set<UUID>? = nil
    @Binding var search: OrganizeSearchFilter
    /// Stacks the current search keeps — the footer's "N of M" readout.
    var matchedCount: Int? = nil

    /// The properties a new or edited row can point at, in menu order.
    private var properties: [OrganizeFilterRow.Property] {
        [.people, .date, .event, .media, .camera]
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
        filterPanel
    }

    // MARK: - Filter panel

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !search.excludedEventIDs.isEmpty {
                        alwaysHidingSection
                    }
                    ForEach($search.groups) { $group in
                        if group.id != search.groups.first?.id {
                            orSeparator
                        }
                        ForEach($group.rows) { $row in
                            if row.id != group.rows.first?.id {
                                andConnector
                            }
                            conditionRow(row: $row) {
                                group.rows.removeAll { $0.id == row.id }
                                // An "or" group exists to OR against —
                                // removing its last row removes the group.
                                if group.rows.isEmpty, search.groups.count > 1 {
                                    search.groups.removeAll { $0.id == group.id }
                                }
                            }
                        }
                        // Once there is an "or", each group adds to itself;
                        // with one group the footer button below does.
                        if search.groups.count > 1 {
                            Button {
                                group.rows.append(OrganizeFilterRow(property: .people))
                            } label: {
                                Label("And…", systemImage: "plus")
                            }
                            .controlSize(.small)
                            .help("Add a condition to this group — every condition in it must match")
                        }
                    }
                    HStack(spacing: 8) {
                        if search.groups.count <= 1 {
                            addConditionButton(search.groups.isEmpty
                                ? "Add a condition"
                                : "Add another condition — photos must match every condition") {
                                search.addCondition(OrganizeFilterRow(property: .people))
                            }
                        }
                        if !search.groups.isEmpty {
                            Button("Add “Or” Group…") {
                                search.addOrGroup(OrganizeFilterRow(property: .people))
                            }
                            .controlSize(.small)
                            .help("Start a separate set of conditions — photos matching either set stay")
                        }
                    }
                    if search.groups.isEmpty {
                        Text("Each condition you add narrows the board — photos must match all of them.")
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

    /// The board-level exclusions the subevent chips write — hidden
    /// whatever the conditions below say, so they sit above them.
    private var alwaysHidingSection: some View {
        let events = workspace.sidebarEvents.map(\.event)
        let picked = events.filter { search.excludedEventIDs.contains($0.id) }
        let stale = search.excludedEventIDs
            .subtracting(events.map(\.id))
            .sorted { $0.uuidString < $1.uuidString }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Always hiding")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                ForEach(picked) { event in
                    valueChip(
                        workspace.eventTitle(event),
                        color: EventPalette.color(for: event.id),
                        help: "Photos in this event stay hidden, whatever the conditions below say"
                    ) {
                        search.excludedEventIDs.remove(event.id)
                    }
                }
                ForEach(stale, id: \.self) { id in
                    valueChip("Deleted event", symbol: "questionmark.folder") {
                        search.excludedEventIDs.remove(id)
                    }
                }
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// The word between two rows of one group — both must match.
    private var andConnector: some View {
        Text("and")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
    }

    /// The labelled break between groups — photos matching the group
    /// above or the one below stay, so it reads as a deliberate choice
    /// rather than a thin divider.
    private var orSeparator: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1).frame(maxWidth: 16)
            Text("\(Text("OR").fontWeight(.bold)) — or match this group instead")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    private func addConditionButton(_ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Add Condition", systemImage: "plus")
        }
        .controlSize(.small)
        .help(help)
    }

    // MARK: - Condition rows

    /// One builder row: property and operator on top, the picked values as
    /// removable chips underneath, and a control removing the whole row.
    @ViewBuilder
    private func conditionRow(row: Binding<OrganizeFilterRow>, onRemove: @escaping () -> Void) -> some View {
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
                        ForEach(OrganizeFilterRow.Operator.options(for: row.wrappedValue.property), id: \.self) { item in
                            Text(item.menuTitle).tag(item)
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
            case .camera:
                cameraValues(row)
            case .editTag:
                editTagValues(row)
            }
        }
        .padding(7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        // On an event board the picker narrows to the family — picks
        // outside it can't match there. A carried-over pick still renders
        // as a removable chip even though it is not offered again.
        let options = rows.filter { eventScope?.contains($0.event.id) ?? true }
        let offersUnsorted = eventScope == nil && !row.wrappedValue.includesUnsorted
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
            if options.isEmpty, !row.wrappedValue.includesUnsorted {
                Text("No events yet — sort items into one first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let unpicked = options.filter { !row.wrappedValue.eventIDs.contains($0.event.id) }
                Menu {
                    if offersUnsorted {
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
                .disabled(unpicked.isEmpty && !offersUnsorted)
                .help("Add an event to this row")
            }
        }
    }

    // MARK: - Media values

    /// The kinds a Media row can pick, in menu order — same three the old
    /// facet offered. The header's hot links label Media rows from the
    /// same titles.
    static let mediaOptions: [(kind: OrganizeMediaKind, title: String, symbol: String)] = [
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

    // MARK: - Camera values

    /// The cameras on this board with their stack counts. Files whose
    /// camera the background pass has not read yet sit under "Unknown
    /// camera" until it does.
    private func cameraValues(_ row: Binding<OrganizeFilterRow>) -> some View {
        let options = workspace.boardCameras(for: stacks)
        let picked = row.wrappedValue.cameraIDs
            .map { id in options.first { $0.id == id }?.camera ?? CameraCatalog.camera(id: id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return FlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
            ForEach(picked) { camera in
                let count = options.first { $0.id == camera.id }?.stackCount ?? 0
                valueChip(
                    camera.name,
                    symbol: camera.id == OrganizeCamera.unknownID ? "questionmark.circle" : "camera",
                    help: "\(count) item\(count == 1 ? "" : "s") on this board"
                ) {
                    row.wrappedValue.cameraIDs.remove(camera.id)
                }
            }
            if options.isEmpty {
                Text("No items on this board yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let unpicked = options.filter { !row.wrappedValue.cameraIDs.contains($0.id) }
                Menu {
                    ForEach(unpicked) { option in
                        Button {
                            row.wrappedValue.cameraIDs.insert(option.id)
                        } label: {
                            Label(
                                "\(option.camera.name) (\(option.stackCount.formatted()))",
                                systemImage: option.id == OrganizeCamera.unknownID ? "questionmark.circle" : "camera"
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
                .help("Add a camera to this row")
            }
        }
    }

    // MARK: - Edit tag values

    /// The first-level folders under the family's `Edited/` that link to
    /// this board's originals.
    private func editTagValues(_ row: Binding<OrganizeFilterRow>) -> some View {
        let options = workspace.boardEditTags(for: stacks, scope: eventScope)
        let picked = row.wrappedValue.editTags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return FlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
            ForEach(picked, id: \.self) { tag in
                let count = options.first { $0.tag == tag }?.stackCount ?? 0
                valueChip(tag, symbol: "slider.horizontal.3", help: "\(count) item\(count == 1 ? "" : "s") on this board have a \(tag) edit") {
                    row.wrappedValue.editTags.remove(tag)
                }
            }
            if options.isEmpty {
                Text(eventScope == nil
                    ? "Edit tags come from an event's Edited folder — open an event board."
                    : "No edits linked yet. Put edits in the event's Edited/<Tag>/ folder; each folder name is a tag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let unpicked = options.filter { !row.wrappedValue.editTags.contains($0.tag) }
                Menu {
                    ForEach(unpicked, id: \.tag) { option in
                        Button {
                            row.wrappedValue.editTags.insert(option.tag)
                        } label: {
                            Label("\(option.tag) (\(option.stackCount.formatted()))", systemImage: "slider.horizontal.3")
                        }
                    }
                } label: {
                    addValueLabel
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(unpicked.isEmpty)
                .help("Add an edit tag to this row")
            }
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

/// The active filter rows as hot links under the board's tag chips — one
/// chip per row carrying picks, labeled in plain language ("Event is any
/// of ● TRIP2026 / Matcha"). A tap suspends the row: it stays in the
/// panel with its picks, draws as an outline, and stops filtering; the
/// next tap resumes it. Rows in a group stay AND, groups stay OR.
struct OrganizeFilterHotLinks: View {
    let workspace: EventsWorkspace
    /// The unfiltered board's stacks — People chips resolve names from the
    /// same options the panel's People picker offers.
    let stacks: [OrganizeStack]
    @Binding var search: OrganizeSearchFilter

    var body: some View {
        FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(search.rowsWithValues) { row in
                chip(row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ row: OrganizeFilterRow) -> some View {
        Button {
            search.toggleRow(row.id)
        } label: {
            HStack(spacing: 4) {
                Text(row.property.title)
                    .fontWeight(.semibold)
                if row.property != .date {
                    Text(row.operator.title)
                        .foregroundStyle(.secondary)
                }
                valueLabel(for: row)
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(row.isEnabled ? Color.primary : Color.secondary)
            .background {
                if row.isEnabled {
                    Capsule().fill(Color.primary.opacity(0.12))
                } else {
                    Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                }
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(row.isEnabled
            ? "This filter is on — click to pause it (the row stays in the filter panel)"
            : "This filter is paused — click to turn it back on")
    }

    /// The picked values, rendered after the property and operator.
    @ViewBuilder
    private func valueLabel(for row: OrganizeFilterRow) -> some View {
        switch row.property {
        case .people:
            Text(peopleLabel(for: row))
        case .media:
            Text(mediaLabel(for: row))
        case .camera:
            Text(cameraLabel(for: row))
        case .editTag:
            Text(row.editTags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", "))
        case .date:
            Text(dateLabel(for: row))
        case .event:
            eventValueLabel(for: row)
        }
    }

    /// The People row's picks as "Alex, Person 1" — roster members and
    /// unnamed groups in the picker's order, then stale picks the board
    /// no longer offers.
    private func peopleLabel(for row: OrganizeFilterRow) -> String {
        let options = workspace.boardPeople(for: stacks).options
        let picked = options.filter { row.peopleIDs.contains($0.id) }.map(\.name)
        let stale = row.peopleIDs.count - picked.count
        return (picked + (stale > 0 ? [stale == 1 ? "Unknown person" : "\(stale) unknown people"] : []))
            .joined(separator: ", ")
    }

    /// The Media row's picks as "Stills, RAW" — the picker's titles, with
    /// "Other" for a kind the picker does not offer.
    private func mediaLabel(for row: OrganizeFilterRow) -> String {
        var titles = OrganizeFilterPanel.mediaOptions
            .filter { row.mediaKinds.contains($0.kind) }
            .map(\.title)
        if row.mediaKinds.contains(.other) { titles.append("Other") }
        return titles.joined(separator: ", ")
    }

    /// The Camera row's picks as "Osmo 360, Sony A7V".
    private func cameraLabel(for row: OrganizeFilterRow) -> String {
        row.cameraIDs
            .map { CameraCatalog.camera(id: $0).name }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .joined(separator: ", ")
    }

    /// The Date row's range as "Aug 26 – Aug 27", "from Aug 26", or
    /// "through Aug 27" for an open bound.
    private func dateLabel(for row: OrganizeFilterRow) -> String {
        func day(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }
        switch (row.dayStart, row.dayEnd) {
        case let (start?, end?): return "\(day(start)) – \(day(end))"
        case let (start?, nil): return "from \(day(start))"
        case let (nil, end?): return "through \(day(end))"
        case (nil, nil): return ""
        }
    }

    /// The Event row's picks — each with a dot of its palette color, plus
    /// the "Not Sorted Yet" pseudo-value and stale picks.
    private func eventValueLabel(for row: OrganizeFilterRow) -> some View {
        let events = workspace.sidebarEvents.map(\.event)
        let picked = events.filter { row.eventIDs.contains($0.id) }
        let stale = row.eventIDs.count - picked.count
        return HStack(spacing: 4) {
            if row.includesUnsorted {
                Text("Not Sorted Yet")
            }
            ForEach(Array(picked.enumerated()), id: \.element.id) { index, event in
                if index > 0 || row.includesUnsorted {
                    Text(",")
                }
                Circle()
                    .fill(EventPalette.color(for: event.id))
                    .frame(width: 6, height: 6)
                Text(workspace.eventTitle(event))
                    .lineLimit(1)
            }
            if stale > 0 {
                if !picked.isEmpty || row.includesUnsorted {
                    Text(",")
                }
                Text(stale == 1 ? "Deleted event" : "\(stale) deleted events")
            }
        }
    }
}

/// Left-to-right wrapping layout — chips flow onto the next line instead
/// of clipping. A child wider than the container is offered the container's
/// width, so it truncates instead of pushing the layout wider.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    /// Each child's size, measured once per width limit.
    struct Cache {
        var limit: CGFloat?
        var sizes: [CGSize] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    private func sizes(for subviews: Subviews, limit: CGFloat, cache: inout Cache) -> [CGSize] {
        if cache.limit == limit, cache.sizes.count == subviews.count {
            return cache.sizes
        }
        let sizes = subviews.map { subview -> CGSize in
            let ideal = subview.sizeThatFits(.unspecified)
            guard ideal.width > limit, limit.isFinite else { return ideal }
            let clamped = subview.sizeThatFits(ProposedViewSize(width: limit, height: nil))
            return CGSize(width: min(clamped.width, limit), height: clamped.height)
        }
        cache = Cache(limit: limit, sizes: sizes)
        return sizes
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let limit = proposal.width ?? .infinity
        let sizes = sizes(for: subviews, limit: limit, cache: &cache)
        var x: CGFloat = 0
        var height: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for size in sizes {
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

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let sizes = sizes(for: subviews, limit: bounds.width, cache: &cache)
        var index = 0
        var y = bounds.minY
        while index < subviews.count {
            let lineStart = index
            var lineWidth: CGFloat = 0
            var lineHeight: CGFloat = 0
            while index < subviews.count {
                let next = lineWidth + (index == lineStart ? 0 : horizontalSpacing) + sizes[index].width
                if index > lineStart, next > bounds.width { break }
                lineWidth = next
                lineHeight = max(lineHeight, sizes[index].height)
                index += 1
            }
            var x = alignment == .trailing ? bounds.maxX - lineWidth : bounds.minX
            for i in lineStart..<index {
                subviews[i].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(sizes[i])
                )
                x += sizes[i].width + horizontalSpacing
            }
            y += lineHeight + verticalSpacing
        }
    }
}
