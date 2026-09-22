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
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: TrashBrowserView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_060, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Trash"
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        CameraToolkitWindowSizing.configure(window, as: .trash)
        window.setContentSize(NSSize(width: 1_060, height: 700))
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

private struct TrashDaySection: Identifiable {
    /// `yyyy-MM-dd` in the local calendar.
    var id: String
    var date: Date
    var items: [MediaTrashItem]
}

/// The Trash board itself — also what Settings links to, so there is exactly
/// one list of trashed files in the app.
struct TrashBrowserView: View {
    @Bindable var model: DashboardModel

    @AppStorage("CameraToolkit.trash.tileWidth") private var tileWidth = 200.0
    /// nil while the first scan of the Trash roots is in flight.
    @State private var batches: [MediaTrashBatch]?
    @State private var items: [MediaTrashItem] = []
    @State private var query = MediaTrashQuery()
    @State private var selectedIDs: Set<String> = []
    @State private var anchorID: String?
    @State private var focusedID: String?
    @State private var showEmptyTrash = false
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
        if items.isEmpty { return "Nothing in Trash" }
        let bytes = items.reduce(Int64(0)) { $0 + $1.size }
        let base = "\(items.count) file\(items.count == 1 ? "" : "s") · \(bytes.formattedBytes) · \(batches.count) batch\(batches.count == 1 ? "" : "es")"
        return query.isEmpty ? base : "\(filtered.count) of \(base)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            actionBar
            Divider()
            content
            Divider()
            footerLine
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "trash.fill")
                        .foregroundStyle(.orange)
                    Text("Trash")
                        .font(.title2.bold())
                        .lineLimit(1)
                }
                Text(summaryLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            searchField
            dateRange
            Slider(value: $tileWidth, in: 96...360)
                .frame(width: 90)
                .help("Tile size — smaller fits more files on screen")
            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Re-read the Trash folders — the board already refreshes itself after every Trash, restore, or Empty")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Name, event, or person", text: $query.text)
                .textFieldStyle(.plain)
                .frame(width: 150)
                .focused($searchFocused)
            if !query.text.isEmpty {
                Button {
                    query.text = ""
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
        .help("Filter by file name, event, or confirmed person (⌘F)")
    }

    /// From/Through pickers over each item's `sortDate` — the capture date
    /// the board recorded at trash time, else the day it was trashed.
    private var dateRange: some View {
        let bounds = dayBounds
        return HStack(spacing: 6) {
            Text("From")
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
            if query.dayStart != nil {
                clearDateButton { query.dayStart = nil }
            }
            Text("Through")
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
            if query.dayEnd != nil {
                clearDateButton { query.dayEnd = nil }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .help("Keep only files shot (or trashed) inside this day range")
    }

    private func clearDateButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    /// The pickers' fallback bounds — the Trash's own day span so an unset
    /// end still shows a meaningful date instead of today.
    private var dayBounds: (first: Date, last: Date) {
        let dates = items.map(\.sortDate)
        return (dates.min() ?? Date(), dates.max() ?? Date())
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Text(selectedIDs.isEmpty ? "Select files to restore them" : "\(selectedIDs.count) selected")
                .font(.callout.weight(.semibold))
                .frame(minWidth: 140, alignment: .leading)
            Button {
                restore(selectionItems())
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIDs.isEmpty || model.isBusy)
            .help("Rename the selected files back to the paths they were trashed from. Existing files are never replaced.")
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            batchMenu
            Button(role: .destructive) {
                showEmptyTrash = true
            } label: {
                Label("Empty Trash…", systemImage: "trash.slash")
            }
            .disabled(items.isEmpty || model.isBusy)
            .help("Permanently delete everything inside the _Trash folders — a typed DELETE confirmation is required")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
            Label("Batches", systemImage: "square.stack.3d.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
        Task { @MainActor in
            let found = await Task.detached(priority: .utility) {
                let service = MediaTrashService(removedFilesRoot: fallback)
                let batches = service.listBatches(under: roots)
                return (batches, batches.flatMap { $0.items(eventNames: names) })
            }.value
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
                TileThumbnail(url: item.fileURL, kind: kind, pixelSize: Int(width * 2))
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
            .background(Color.black.opacity(0.12))
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

/// Permanent delete, behind the same typed DELETE confirmation the Settings
/// row uses. Covers exactly the roots the browser lists — nothing outside a
/// `_Trash` folder is touched.
private struct EmptyTrashSheet: View {
    @Bindable var model: DashboardModel
    let fileCount: Int
    let byteCount: Int64

    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash.slash.fill")
                    .font(.title)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Empty Trash?")
                        .font(.title2.bold())
                    Text("\(fileCount) file\(fileCount == 1 ? "" : "s") · \(byteCount.formattedBytes) will be permanently deleted.")
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
                dismiss()
                return summary
            }
        )
    }
}
