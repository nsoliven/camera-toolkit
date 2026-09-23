import AppKit
import CameraToolkitCore
import SwiftUI

/// The Trash pop-out window: one flat, searchable, date-filterable board of
/// every file sitting in `.Camera Toolkit/_Trash` on any configured drive.
/// Tiles decode the copy inside the batch folder — never the original path —
/// and restore uses the batch manifest's recorded origins.
@MainActor
final class TrashWindowController: NSObject, NSWindowDelegate {
    static let shared = TrashWindowController()
    static let windowIdentifier = "CameraToolkitTrashWindow"

    private var window: NSWindow?

    func show(model: DashboardModel) {
        if let window {
            CameraToolkitWindowFactory.present(window)
            return
        }

        let window = CameraToolkitWindowFactory.make(
            .trash,
            identifier: Self.windowIdentifier,
            title: "Trash",
            initialContentSize: NSSize(width: 1_060, height: 700),
            rootView: TrashBrowserView(model: model)
        )
        window.delegate = self
        self.window = window
        CameraToolkitWindowFactory.present(window)
    }
}

private struct TrashDaySection: Identifiable {
    /// `yyyy-MM-dd` in the local calendar.
    var id: String
    var date: Date
    var items: [MediaTrashItem]
}

/// Generations for Trash board reloads. Every read takes the next stamp and
/// only the newest may publish: a slow listing that lands late is dropped
/// instead of painting an older list over the current one. `reading` stays
/// set while a read is in flight so the summary can say the board is
/// re-reading instead of implying the old list is still current.
struct TrashReloadGate {
    private(set) var latest = 0
    private(set) var reading = false

    /// Starts a read, superseding every earlier one.
    mutating func begin() -> Int {
        latest += 1
        reading = true
        return latest
    }

    /// True only for the newest read — the caller may publish its list. A
    /// superseded read returns false and leaves `reading` set for the read
    /// that replaced it.
    mutating func finish(_ stamp: Int) -> Bool {
        guard stamp == latest else { return false }
        reading = false
        return true
    }
}

/// The Trash board itself — also what Settings links to, so there is exactly
/// one list of trashed files in the app.
struct TrashBrowserView: View {
    @Bindable var model: DashboardModel

    @AppStorage("CameraToolkit.trash.tileWidth") private var tileWidth = 200.0
    /// nil while the first scan of the Trash roots is in flight.
    @State private var batches: [MediaTrashBatch]?
    @State private var items: [MediaTrashItem] = []
    @State private var reloads = TrashReloadGate()
    @State private var query = MediaTrashQuery()
    @State private var selectedIDs: Set<String> = []
    @State private var anchorID: String?
    @State private var focusedID: String?
    @State private var showEmptyTrash = false
    @State private var showDateRange = false
    @State private var message: String?
    @State private var columns = 1
    @FocusState private var gridFocused: Bool
    @FocusState private var searchFocused: Bool

    /// Live event titles so manifests that recorded only `eventID` still tag
    /// the event when it exists today; `.task(id:)` keys on this so a rename
    /// re-resolves without a rescan.
    private var eventNames: [UUID: String] {
        let events = model.configuration.savedEvents
        return Dictionary(
            events.map { ($0.id, EventHierarchy.displayName(of: $0, in: events)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var filtered: [MediaTrashItem] {
        items.filter { query.matches($0) }
    }

    /// Day sections newest-first, matching how `listBatches` orders batches —
    /// Trash is a "what did I just set aside" story.
    private var sections: [TrashDaySection] {
        let calendar = Calendar.current
        var byDay: [String: (date: Date, items: [MediaTrashItem])] = [:]
        for item in filtered {
            let components = calendar.dateComponents([.year, .month, .day], from: item.sortDate)
            let key = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
            if byDay[key] == nil {
                byDay[key] = (calendar.startOfDay(for: item.sortDate), [])
            }
            byDay[key]?.items.append(item)
        }
        return byDay.keys.sorted().reversed().compactMap { key in
            byDay[key].map {
                TrashDaySection(
                    id: key,
                    date: $0.date,
                    items: $0.items.sorted {
                        if $0.sortDate != $1.sortDate { return $0.sortDate > $1.sortDate }
                        return $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
                    }
                )
            }
        }
    }

    private var orderedIDs: [String] {
        sections.flatMap(\.items).map(\.id)
    }

    private var summaryLine: String {
        guard let batches else { return "Reading Trash folders…" }
        if reloads.reading { return "Re-reading Trash folders…" }
        if items.isEmpty { return "Nothing in Trash" }
        let bytes = items.reduce(Int64(0)) { $0 + $1.size }
        let base = "\(items.count) file\(items.count == 1 ? "" : "s") · \(bytes.formattedBytes) · \(batches.count) batch\(batches.count == 1 ? "" : "es")"
        return query.isEmpty ? base : "\(filtered.count) of \(base)"
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    if let message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                    }
                    footerLine
                }
                .background(.bar)
            }
            .navigationTitle("Trash")
            .navigationSubtitle(subtitle)
            .searchable(text: $query.text, placement: .toolbar, prompt: "Name, event, or person")
            .searchFocused($searchFocused)
            .toolbar { toolbar }
            .sheet(isPresented: $showEmptyTrash) {
                EmptyTrashSheet(
                    model: model,
                    fileCount: items.count,
                    byteCount: items.reduce(Int64(0)) { $0 + $1.size }
                )
            }
            .task(id: eventNames) { reload() }
            .onReceive(NotificationCenter.default.publisher(for: .cameraToolkitMediaTrashChanged)) { _ in
                reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: .cameraToolkitStorageLocationsChanged)) { _ in
                reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: BrowserCommand.notification)) { notification in
                guard let raw = notification.object as? String, let command = BrowserCommand(rawValue: raw) else { return }
                handle(command)
            }
    }

    // MARK: - Toolbar

    /// The window subtitle: the selection while there is one, else what the
    /// Trash holds.
    private var subtitle: String {
        selectedIDs.isEmpty ? summaryLine : "\(selectedIDs.count) selected · \(summaryLine)"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            dateRangeButton
        }
        ToolbarItem {
            Slider(value: $tileWidth, in: 96...360) {
                Text("Tile Size")
            } minimumValueLabel: {
                Image(systemName: "photo")
                    .imageScale(.small)
            } maximumValueLabel: {
                Image(systemName: "photo")
                    .imageScale(.large)
            }
            .frame(width: 130)
            .help("Tile size — smaller fits more files on screen")
        }
        ToolbarItem {
            Button("Reload", systemImage: "arrow.clockwise") {
                reload()
            }
            .help("Re-read the Trash folders — the board already refreshes itself after every Trash, restore, or Empty")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            batchMenu
        }
        ToolbarItem {
            Button("Empty Trash…", systemImage: "trash", role: .destructive) {
                showEmptyTrash = true
            }
            .disabled(items.isEmpty || model.isBusy)
            .help("Permanently delete everything inside the _Trash folders — a typed DELETE confirmation is required")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button {
                restore(selectionItems())
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .disabled(selectedIDs.isEmpty || model.isBusy)
            .help("Rename the selected files back to the paths they were trashed from. Existing files are never replaced.")
        }
    }

    /// From/Through pickers over each item's `sortDate` — the capture date
    /// the board recorded at trash time, else the day it was trashed. A
    /// popover, because a toolbar menu cannot host date pickers.
    private var dateRangeButton: some View {
        let isFiltering = query.dayStart != nil || query.dayEnd != nil
        return Button {
            showDateRange.toggle()
        } label: {
            Label("Dates", systemImage: isFiltering ? "calendar.badge.checkmark" : "calendar")
        }
        .help("Keep only files shot (or trashed) inside a day range")
        .popover(isPresented: $showDateRange, arrowEdge: .bottom) {
            TrashDateRangeForm(query: $query, bounds: dayBounds)
        }
    }

    /// The pickers' fallback bounds — the Trash's own day span so an unset
    /// end still shows a meaningful date instead of today.
    private var dayBounds: (first: Date, last: Date) {
        let dates = items.map(\.sortDate)
        return (dates.min() ?? Date(), dates.max() ?? Date())
    }

    /// Whole-batch restore, kept reachable now that Settings no longer lists
    /// batches: every batch the browser can see, newest first.
    private var batchMenu: some View {
        Menu {
            let batches = batches ?? []
            if batches.isEmpty {
                Text("No batches in Trash")
            } else {
                ForEach(batches) { batch in
                    Button {
                        restore(batch)
                    } label: {
                        let title = batch.createdAt == .distantPast
                            ? batch.name
                            : batch.createdAt.formatted(date: .abbreviated, time: .shortened)
                        Text("Restore \(title) — \(batch.fileCount) file\(batch.fileCount == 1 ? "" : "s")")
                    }
                    .disabled(batch.entries.isEmpty)
                }
            }
        } label: {
            Label("Batches", systemImage: "square.stack")
        }
        .disabled(model.isBusy)
        .help("Restore an entire Trash batch — every file back to its recorded location")
    }

    // MARK: - Board

    @ViewBuilder
    private var content: some View {
        if batches == nil {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading Trash folders…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            ContentUnavailableView(
                "Trash Is Empty",
                systemImage: "trash",
                description: Text("Files you move to Trash from the organizer land here, grouped by the day they were shot or trashed.")
            )
            .frame(maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView(
                "No Matches",
                systemImage: "magnifyingglass",
                description: Text("Nothing in Trash matches the current search and date range — clearing them shows everything.")
            )
            .frame(maxHeight: .infinity)
        } else {
            board
        }
    }

    private var board: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth * 1.3), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 14,
                    pinnedViews: [.sectionHeaders]
                ) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                tile(item, orderedIDs: orderedIDs)
                            }
                        } header: {
                            TrashDayHeader(
                                section: section,
                                onSelect: {
                                    selectedIDs = Set(section.items.map(\.id))
                                    anchorID = section.items.first?.id
                                    focusedID = section.items.last?.id
                                    gridFocused = true
                                }
                            )
                        }
                    }
                }
                .padding(16)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { updateColumns(geometry.size.width) }
                            .onChange(of: geometry.size.width) { _, width in updateColumns(width) }
                    }
                }
            }
            .focusable()
            .focused($gridFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                handleKey(press, orderedIDs: orderedIDs, proxy: proxy)
            }
            .onAppear { gridFocused = true }
            .onChange(of: focusedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private func tile(_ item: MediaTrashItem, orderedIDs: [String]) -> some View {
        TrashTileView(
            item: item,
            width: tileWidth,
            isSelected: selectedIDs.contains(item.id),
            isFocused: focusedID == item.id
        )
        .id(item.id)
        .onTapGesture {
            select(item, orderedIDs: orderedIDs)
            gridFocused = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.fileName)
        .accessibilityValue(item.eventName ?? "")
        .accessibilityAddTraits(selectedIDs.contains(item.id) ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            select(item, orderedIDs: orderedIDs)
        }
        .contextMenu { contextMenu(item) }
    }

    @ViewBuilder
    private func contextMenu(_ item: MediaTrashItem) -> some View {
        let targets = targetIDs(including: item.id)
        let targetItems = items.filter { targets.contains($0.id) }
        Button("Restore\(targetItems.count > 1 ? " \(targetItems.count) Files" : "")") {
            selectedIDs = targets
            restore(targetItems)
        }
        .disabled(model.isBusy)
        if let batch = batches?.first(where: { $0.name == item.batchName }) {
            Button("Restore Entire \(item.batchName) Batch") {
                restore(batch)
            }
            .disabled(batch.entries.isEmpty || model.isBusy)
            .help(batch.entries.isEmpty
                ? "This batch has no manifest of where its files lived, so it cannot be restored."
                : "Rename every file in this batch back to its recorded location.")
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(targetItems.map(\.fileURL))
        }
        Button("Select All") {
            selectedIDs = Set(orderedIDs)
        }
    }

    private var footerLine: some View {
        OrganizeStatusLine(model: model)
    }

    // MARK: - Selection

    /// The stack of ids a click or menu acts on: the current selection when
    /// the touched item is part of it, else just the touched item.
    private func targetIDs(including id: String) -> Set<String> {
        selectedIDs.contains(id) ? selectedIDs : [id]
    }

    private func selectionItems() -> [MediaTrashItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    private func select(_ item: MediaTrashItem, orderedIDs: [String]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchorID,
           let from = orderedIDs.firstIndex(of: anchorID),
           let to = orderedIDs.firstIndex(of: item.id) {
            selectedIDs = Set(orderedIDs[min(from, to)...max(from, to)])
        } else if flags.contains(.command) {
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
            anchorID = item.id
        } else {
            selectedIDs = [item.id]
            anchorID = item.id
        }
        focusedID = item.id
    }

    private func updateColumns(_ width: CGFloat) {
        columns = max(1, Int((width - 32 + 12) / (tileWidth + 12)))
    }

    // MARK: - Commands

    /// ⌘A and ⌘F land here through the shared BrowserCommand bus — answer
    /// them only while this window is key so the organize board keeps them
    /// when it is.
    private func handle(_ command: BrowserCommand) {
        guard NSApp.keyWindow?.identifier?.rawValue == TrashWindowController.windowIdentifier else { return }
        guard command.isAllowedWhileTyping || !KeyboardTextFocus.isTypingInTextField() else { return }
        switch command {
        case .selectAll:
            selectedIDs = Set(orderedIDs)
        case .find:
            searchFocused = true
        case .reload:
            reload()
        default:
            break
        }
    }

    private func handleKey(_ press: KeyPress, orderedIDs: [String], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !KeyboardTextFocus.isTypingInTextField() else { return .ignored }
        let current = focusedID.flatMap { orderedIDs.firstIndex(of: $0) }
        func move(_ delta: Int) -> KeyPress.Result {
            guard !orderedIDs.isEmpty else { return .handled }
            let target = min(max((current ?? -1) + delta, 0), orderedIDs.count - 1)
            let id = orderedIDs[target]
            if press.modifiers.contains(.shift), let anchorID,
               let from = orderedIDs.firstIndex(of: anchorID) {
                selectedIDs = Set(orderedIDs[min(from, target)...max(from, target)])
            } else {
                selectedIDs = [id]
                anchorID = id
            }
            focusedID = id
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(id)
            }
            return .handled
        }
        guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
        switch press.key {
        case .leftArrow: return move(-1)
        case .rightArrow: return move(1)
        case .upArrow: return move(-columns)
        case .downArrow: return move(columns)
        case .escape:
            selectedIDs.removeAll()
            focusedID = nil
            anchorID = nil
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: - Loading and jobs

    private func reload() {
        let configuration = model.configuration
        let locations = EventStorageLocations(configuration: configuration)
        let roots = locations.trashRoots()
        let fallback = locations.removedFilesRoot
        let names = eventNames
        let stamp = reloads.begin()
        Task { @MainActor in
            let found = await Task.detached(priority: .utility) {
                let service = MediaTrashService(removedFilesRoot: fallback)
                let batches = service.listBatches(under: roots)
                return (batches, batches.flatMap { $0.items(eventNames: names) })
            }.value
            // A newer read superseded this one while it listed — drop the
            // stale result instead of painting an older list back.
            guard reloads.finish(stamp) else { return }
            batches = found.0
            items = found.1
            selectedIDs = selectedIDs.intersection(Set(found.1.map(\.id)))
            if let focusedID, !found.1.contains(where: { $0.id == focusedID }) {
                self.focusedID = nil
                anchorID = nil
            }
        }
    }

    private func restore(_ batch: MediaTrashBatch) {
        let fallback = EventStorageLocations(configuration: model.configuration).removedFilesRoot
        model.runBackgroundJob(
            action: .organize,
            runningNote: "Restoring \(batch.fileCount) file(s) from Trash",
            logTitle: "Restored a Trash batch",
            logDetail: "Renamed files back to the paths their batch manifest recorded. Existing files were never replaced.",
            operation: { progress in
                MediaTrashService(removedFilesRoot: fallback).restore(batch: batch) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Restoring", command: ""))
                }
            },
            completion: { report in
                let summary = Self.restoreSummary(report)
                message = summary
                NotificationCenter.default.post(name: .cameraToolkitMediaTrashChanged, object: nil)
                return summary
            }
        )
    }

    private func restore(_ items: [MediaTrashItem]) {
        guard !items.isEmpty else { return }
        let fallback = EventStorageLocations(configuration: model.configuration).removedFilesRoot
        model.runBackgroundJob(
            action: .organize,
            runningNote: "Restoring \(items.count) file(s) from Trash",
            logTitle: "Restored files from Trash",
            logDetail: "Renamed the selected files back to the paths their batch manifests recorded. Existing files were never replaced.",
            operation: { progress in
                MediaTrashService(removedFilesRoot: fallback).restore(items: items) { update in
                    progress(DashboardModel.jobUpdate(from: update, notePrefix: "Restoring", command: ""))
                }
            },
            completion: { report in
                let summary = Self.restoreSummary(report)
                message = summary
                NotificationCenter.default.post(name: .cameraToolkitMediaTrashChanged, object: nil)
                return summary
            }
        )
    }

    private static func restoreSummary(_ report: MediaTrashRestoreReport) -> String {
        var parts = ["Restored \(report.restored.count) file(s) (\(report.restoredBytes.formattedBytes)) back to where they lived."]
        if !report.conflicts.isEmpty {
            parts.append("\(report.conflicts.count) stayed in Trash because a file already exists at the original path.")
        }
        if !report.missing.isEmpty {
            parts.append("\(report.missing.count) recorded file(s) were no longer in the batch.")
        }
        if !report.failed.isEmpty {
            parts.append("\(report.failed.count) could not move back: \(report.failed.values.first ?? "")")
        }
        return parts.joined(separator: " ")
    }
}

/// The Trash's day-range filter, shown in a popover from the toolbar. An
/// unset end shows the Trash's own first or last day instead of today.
private struct TrashDateRangeForm: View {
    @Binding var query: MediaTrashQuery
    let bounds: (first: Date, last: Date)

    var body: some View {
        Form {
            Section {
                LabeledContent("From") {
                    HStack(spacing: 6) {
                        DatePicker(
                            "From",
                            selection: Binding(
                                get: { query.dayStart ?? bounds.first },
                                set: { day in
                                    query.dayStart = day
                                    if let end = query.dayEnd, day > end { query.dayEnd = day }
                                }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        clearButton("Clear From Date", isSet: query.dayStart != nil) { query.dayStart = nil }
                    }
                }
                LabeledContent("Through") {
                    HStack(spacing: 6) {
                        DatePicker(
                            "Through",
                            selection: Binding(
                                get: { query.dayEnd ?? bounds.last },
                                set: { day in
                                    query.dayEnd = day
                                    if let start = query.dayStart, day < start { query.dayStart = day }
                                }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        clearButton("Clear Through Date", isSet: query.dayEnd != nil) { query.dayEnd = nil }
                    }
                }
            } footer: {
                HStack {
                    Text("Shot, or trashed when no capture date is known.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show All Dates") {
                        query.dayStart = nil
                        query.dayEnd = nil
                    }
                    .disabled(query.dayStart == nil && query.dayEnd == nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Clears one end of the range. Kept in the layout while unset (just
    /// hidden) so the pickers do not jump.
    private func clearButton(_ title: String, isSet: Bool, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: "xmark.circle.fill", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(title)
            .opacity(isSet ? 1 : 0)
            .disabled(!isSet)
    }
}

/// One pinned day row in the Trash board — same rhythm as the board's group
/// headers, with a Select that picks the whole day.
private struct TrashDayHeader: View {
    let section: TrashDaySection
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
            Text(section.date.formatted(date: .complete, time: .omitted))
                .font(.title3.weight(.semibold))
            Text("\(section.items.count) file\(section.items.count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select", action: onSelect)
                .buttonStyle(.borderless)
                .font(.callout)
                .disabled(section.items.isEmpty)
                .help("Select everything trashed or shot this day")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// One file in the Trash: the preview decodes the copy inside the batch
/// folder, and the chips carry the manifest's tags — the event it belonged
/// to and the confirmed people on it, exactly as they were at trash time.
private struct TrashTileView: View {
    let item: MediaTrashItem
    let width: CGFloat
    let isSelected: Bool
    let isFocused: Bool

    private var kind: OrganizeMediaKind {
        OrganizeFileClassifier.kind(forExtension: (item.fileName as NSString).pathExtension)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                TileThumbnail(url: item.fileURL, kind: kind, pointSize: width)
                VStack {
                    HStack {
                        Spacer(minLength: 0)
                        if kind == .video {
                            Image(systemName: "play.fill")
                                .font(.caption)
                                .padding(5)
                                .background(.black.opacity(0.6), in: Circle())
                                .foregroundStyle(.white)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        if let eventName = item.eventName {
                            tag(
                                eventName,
                                symbol: "calendar",
                                color: item.eventID.map { EventPalette.color(for: $0) } ?? EventPalette.color(forName: eventName)
                            )
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(6)
            }
            .frame(width: width, height: width * 2 / 3)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 3 : (isFocused ? 2 : 0.5))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !item.personNames.isEmpty {
                    FlowLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                        ForEach(item.personNames, id: \.self) { name in
                            personChip(name)
                        }
                    }
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .help(tooltip)
    }

    private var borderColor: Color {
        if isSelected { return .accentColor }
        if isFocused { return .accentColor.opacity(0.6) }
        return .primary.opacity(0.1)
    }

    /// The date the board sorts and filters by — labeled "Trashed" when it
    /// is the trash day because no capture date was known.
    private var subtitle: String {
        let date = item.sortDate.formatted(date: .abbreviated, time: .shortened)
        let prefix = item.capturedAt == nil ? "Trashed " : ""
        return "\(prefix)\(date) · \(item.size.formattedBytes)"
    }

    private var tooltip: String {
        var lines = [item.originalAbsolutePath ?? item.relativePath]
        lines.append("Trashed \(item.trashedAt.formatted(date: .abbreviated, time: .shortened)) · batch \(item.batchName)")
        if let capturedAt = item.capturedAt {
            lines.append("Shot \(capturedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if let eventName = item.eventName {
            lines.append("Event: \(eventName)")
        }
        if !item.personNames.isEmpty {
            lines.append("People: \(item.personNames.joined(separator: ", "))")
        }
        if let location = item.originalLocationName {
            lines.append("From: \(location)")
        }
        return lines.joined(separator: "\n")
    }

    private func tag(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }

    private func personChip(_ name: String) -> some View {
        Label(name, systemImage: "person.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(EventPalette.color(forName: name), in: Capsule())
    }
}

/// Permanent delete, behind a typed DELETE confirmation. The Trash window
/// and Settings both present this one sheet. Covers exactly the roots the
/// browser lists — nothing outside a `_Trash` folder is touched.
struct EmptyTrashSheet: View {
    @Bindable var model: DashboardModel
    /// What the Trash window counted; nil when the caller (Settings) has
    /// not listed the Trash.
    let fileCount: Int?
    let byteCount: Int64?
    /// Receives the job's summary once the delete finishes.
    var onFinished: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash.fill")
                    .font(.title)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Empty Trash?")
                        .font(.title2.bold())
                    Text(countLine)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Label {
                Text("This permanently deletes every batch inside the _Trash folders on your configured drives and the removed-files folder. Files anywhere else are never touched.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            TextField("Type \(FreeUpService.confirmationToken) to continue", text: $confirmation)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Empty Trash", role: .destructive, action: empty)
                    .disabled(confirmation != FreeUpService.confirmationToken || model.isBusy)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var countLine: String {
        guard let fileCount, let byteCount else {
            return "Everything in the _Trash folders will be permanently deleted."
        }
        return "\(fileCount) file\(fileCount == 1 ? "" : "s") · \(byteCount.formattedBytes) will be permanently deleted."
    }

    private func empty() {
        let roots = EventStorageLocations(configuration: model.configuration).trashRoots()
        let token = confirmation
        model.runBackgroundJob(
            action: .freeUp,
            runningNote: "Emptying Trash folders",
            logTitle: "Emptied Trash",
            logDetail: "Permanently removed _Trash batches under every configured Trash root after the DELETE confirmation.",
            operation: { _ in
                let service = FreeUpService()
                var deleted: [String] = []
                var freed: Int64 = 0
                var failures: [String] = []
                for root in roots {
                    do {
                        let result = try service.emptyTrash(trashRoot: root, confirm: token)
                        deleted.append(contentsOf: result.deletedBatches)
                        freed += result.freedBytes
                    } catch {
                        failures.append("\(root.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return (deleted, freed, failures)
            },
            completion: { outcome in
                var parts = [
                    outcome.0.isEmpty
                        ? (outcome.2.isEmpty ? "There was nothing to empty." : "Nothing was deleted.")
                        : "Permanently deleted \(outcome.0.count) batch(es), freeing \(outcome.1.formattedBytes)."
                ]
                parts.append(contentsOf: outcome.2)
                let summary = parts.joined(separator: " ")
                confirmation = ""
                NotificationCenter.default.post(name: .cameraToolkitMediaTrashChanged, object: nil)
                onFinished?(summary)
                dismiss()
                return summary
            }
        )
    }
}
