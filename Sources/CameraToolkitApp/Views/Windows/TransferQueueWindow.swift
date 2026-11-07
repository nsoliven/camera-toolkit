import AppKit
import CameraToolkitCore
import SwiftUI

@MainActor
final class TransferQueueWindowController: NSObject, NSWindowDelegate {
    static let shared = TransferQueueWindowController()

    private var window: NSWindow?

    func show(model: DashboardModel) {
        if let window {
            CameraToolkitWindowFactory.present(window)
            return
        }

        let window = CameraToolkitWindowFactory.make(
            .transferQueue,
            identifier: "CameraToolkitTransferQueueWindow",
            title: "Jobs",
            initialContentSize: NSSize(width: 1_080, height: 720),
            rootView: TransferQueueView(model: model)
        )
        window.delegate = self
        self.window = window
        CameraToolkitWindowFactory.present(window)
    }
}

/// The Jobs window: one screen. Every job — running ones pinned on top,
/// then everything recorded, by day — in the list on the left; the one
/// selected opened on the right in the same live layout whether it is
/// running or ended (`JobActivityDetail`), with its files below. A card
/// transfer also shows its route and per-file progress there.
struct TransferQueueView: View {
    @Bindable var model: DashboardModel
    @State private var showingSpeedGuide = false
    @State private var monitor = JobActivityMonitor()
    @State private var history: JobHistoryBrowser
    @State private var selection: UUID?

    /// `history` is a seam for the snapshot harness, which hands in a
    /// reader it already loaded.
    init(model: DashboardModel, selection: UUID? = nil, history: JobHistoryBrowser? = nil) {
        self.model = model
        _history = State(initialValue: history ?? JobHistoryBrowser(model: model))
        _selection = State(initialValue: selection)
    }

    /// Re-reads on selection and whenever a recorded job ends.
    private struct LoadKey: Equatable {
        var selection: UUID?
        var revision: Int
    }

    /// How often a running job's graph and counts are reread.
    static let livePollInterval: Duration = .seconds(2)

    private var sections: JobsList.Sections {
        // A job this session records is listed under its recorded title
        // even before the history list rereads it.
        let recorded = Set(history.jobs.map(\.id))
        let recording = model.jobs.compactMap { job in
            recorded.contains(job.id) ? nil : model.jobHistoryRecorders[job.id]?.currentJob()
        }
        return JobsList.sections(session: model.jobs, history: history.jobs + recording)
    }

    var body: some View {
        let sections = sections
        let shown = selection ?? Self.defaultSelection(sections)
        Group {
            if sections.isEmpty, model.pendingTransferBatches.isEmpty, model.transferQueue == nil, !history.hasLoaded {
                // The first read of the history is still on its way.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sections.isEmpty, model.pendingTransferBatches.isEmpty, model.transferQueue == nil {
                ContentUnavailableView(
                    "No Jobs Yet",
                    systemImage: "list.bullet.clipboard",
                    description: Text("Card copies, syncs to the NAS, face scans, and other background work appear here — while they run, and afterwards with their speed and files.")
                )
            } else {
                HSplitView {
                    JobsSidebar(model: model, sections: sections, selection: $selection, message: history.message)
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 380, maxHeight: .infinity)
                    detailPane(shown, sections: sections)
                        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(
            minWidth: CameraToolkitPopOutWindow.transferQueue.minimumContentSize.width,
            maxWidth: .infinity,
            minHeight: CameraToolkitPopOutWindow.transferQueue.minimumContentSize.height,
            maxHeight: .infinity
        )
        .navigationTitle("Jobs")
        .navigationSubtitle(windowSubtitle)
        .toolbar { toolbar }
        .task(id: model.jobHistoryRevision) {
            await history.reload()
        }
        .task(id: LoadKey(selection: shown, revision: model.jobHistoryRevision)) {
            await history.open(shown)
            // A running job keeps growing: reread its samples (from the
            // recorder in memory) every poll, its files every third.
            var polls = 0
            while !Task.isCancelled, let id = shown, isRunning(id) {
                try? await Task.sleep(for: Self.livePollInterval)
                guard !Task.isCancelled else { return }
                polls += 1
                await history.open(id, reloadItems: polls % 3 == 0)
            }
        }
        .onChange(of: firstLiveJobID) { _, newID in
            // A job that starts is the one to watch.
            if let newID { selection = newID }
        }
    }

    static func defaultSelection(_ sections: JobsList.Sections) -> UUID? {
        sections.active.first?.id ?? sections.all.first?.id
    }

    private var firstLiveJobID: UUID? {
        model.jobs.first { $0.state == .running || $0.state == .queued }?.id
    }

    private func isRunning(_ id: UUID) -> Bool {
        model.jobs.contains { $0.id == id && ($0.state == .running || $0.state == .queued) }
    }

    @ViewBuilder
    private func detailPane(_ id: UUID?, sections: JobsList.Sections) -> some View {
        if let id, let index = model.pendingTransferBatches.firstIndex(where: { $0.id == id }) {
            QueuedBatchDetail(model: model, batch: model.pendingTransferBatches[index], position: index + 1)
        } else if let id, let entry = sections.all.first(where: { $0.id == id }) {
            let transfer = model.transferQueue.flatMap { queue in
                JobsList.transferJobID(for: queue, in: sections.all) == id ? queue : nil
            }
            JobDetailContainer(
                model: model,
                live: model.jobs.first { $0.id == id },
                detail: history.detail?.job.id == id ? history.detail : nil,
                monitor: monitor,
                transfer: transfer
            )
            .id(entry.id)
        } else {
            ContentUnavailableView(
                "Select a Job",
                systemImage: "chart.xyaxis.line",
                description: Text("Pick a job to see its speed over the whole run and its files.")
            )
        }
    }

    // MARK: - Title and toolbar

    /// The card transfer's phase and counts while one runs, else what the
    /// window is waiting on.
    private var windowSubtitle: String {
        if let queue = model.transferQueue, queue.state == .running {
            return "\(queue.phase) · \(CardTransferSection.queueSummary(queue))"
        }
        if let job = model.jobs.first(where: { $0.state == .running || $0.state == .queued }) {
            return job.note
        }
        if !model.pendingTransferBatches.isEmpty {
            return "Transfers waiting — the list is saved. Start it when the camera and Buffer are connected."
        }
        return ""
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let queue = model.transferQueue {
            ToolbarItem {
                Button("Speed Guide", systemImage: "gauge.with.dots.needle.50percent") {
                    showingSpeedGuide.toggle()
                }
                .help("Compare this transfer with USB, Thunderbolt, camera, and SD card speeds")
                .popover(isPresented: $showingSpeedGuide, arrowEdge: .bottom) {
                    TransferSpeedGuideView(queue: queue, model: model)
                }
            }
            ToolbarItem {
                Menu("Show in Finder", systemImage: "folder") {
                    Button("Show Camera") {
                        CardTransferSection.revealFolder(queue.sourcePath)
                    }
                    Button("Show Buffer") {
                        CardTransferSection.revealFolder(queue.destinationPath)
                    }
                }
                .help("Open the camera or Buffer folder of the card transfer in Finder")
            }
            if queue.state != .running {
                ToolbarItem {
                    Button("Clear", systemImage: "xmark.circle") {
                        model.dismissTransferQueue()
                    }
                    .help("Clear the finished card transfer's file list. Its job stays in the list.")
                }
            }
        }
        if !model.pendingTransferBatches.isEmpty {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button {
                    model.resumePendingTransfers()
                } label: {
                    Label("Start Next Transfer", systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .disabled(model.isBusy || model.isStorageBenchmarkRunning)
                .help(model.isBusy
                    ? "Starts automatically after the current job"
                    : "Copy the next waiting batch to the Buffer")
            }
        }
    }
}

/// The selected job: its detail pane on top (scrolling when tall), its
/// files — or, for a card transfer, the per-file queue — underneath. Owns
/// the graph's zoom and the pointer state the graph and the file list
/// share, so both reset when another job is picked.
private struct JobDetailContainer: View {
    @Bindable var model: DashboardModel
    let live: JobSnapshot?
    let detail: JobHistoryDetail?
    let monitor: JobActivityMonitor
    let transfer: TransferQueueSnapshot?
    @State private var zoom = JobHistoryZoom(full: 0...1)
    @State private var hover = JobHistoryHover()
    @State private var fileFilter = JobHistoryFileFilter.all

    private var duration: Double { detail?.graph.duration ?? 1 }

    var body: some View {
        Group {
            if live == nil, detail == nil {
                // Only the history knows this job, and it is still being read.
                ProgressView("Reading the job…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let transfer {
                VSplitView {
                    pane.frame(minHeight: 280, idealHeight: 470, maxHeight: .infinity)
                    CardTransferSection(model: model, queue: transfer)
                        .frame(minHeight: 160, idealHeight: 260, maxHeight: .infinity)
                }
            } else if let detail, !detail.items.isEmpty {
                VSplitView {
                    pane.frame(minHeight: 280, idealHeight: 470, maxHeight: .infinity)
                    JobHistoryFileTable(items: detail.items, zoom: $zoom, hover: hover, filter: $fileFilter)
                        .frame(minHeight: 140, idealHeight: 240, maxHeight: .infinity)
                }
            } else {
                pane
            }
        }
        .onChange(of: duration, initial: true) { _, duration in
            zoom.setFull(0...max(duration, 1))
        }
    }

    private var pane: some View {
        ScrollView {
            JobActivityDetail(
                live: live, detail: detail, monitor: monitor, zoom: $zoom, hover: hover,
                showIssues: transfer == nil && !(detail?.items.isEmpty ?? true) ? { fileFilter = .issues } : nil
            )
        }
    }
}

/// The job list: waiting card batches, running jobs, then every past job
/// by day.
private struct JobsSidebar: View {
    @Bindable var model: DashboardModel
    let sections: JobsList.Sections
    @Binding var selection: UUID?
    let message: String?

    var body: some View {
        List(selection: $selection) {
            if !sections.running.isEmpty {
                Section("Running") {
                    ForEach(sections.running) { entry in
                        JobListRow(entry: entry, live: model.jobs.first { $0.id == entry.id })
                            .tag(entry.id)
                    }
                }
            }
            // Waiting their turn, in the order they will start: card copies
            // saved for later, then any job the gate holds.
            if !model.pendingTransferBatches.isEmpty || !sections.queued.isEmpty {
                Section {
                    ForEach(Array(model.pendingTransferBatches.enumerated()), id: \.element.id) { index, batch in
                        pendingBatchRow(batch, position: index + 1)
                            .tag(batch.id)
                    }
                    ForEach(sections.queued) { entry in
                        JobListRow(entry: entry, live: model.jobs.first { $0.id == entry.id })
                            .tag(entry.id)
                    }
                } header: {
                    Text(model.isBusy ? "Queued · starts after the current job" : "Queued")
                }
            }
            ForEach(sections.days) { day in
                Section(day.title) {
                    ForEach(day.entries) { entry in
                        JobListRow(entry: entry, live: nil)
                            .tag(entry.id)
                    }
                }
            }
            if let message {
                Section {
                    Label(message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func pendingBatchRow(_ batch: PendingTransferBatch, position: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: position <= 50 ? "\(position).circle.fill" : "circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
                .accessibilityLabel("Position \(position)")
            VStack(alignment: .leading, spacing: 2) {
                Text(batch.eventName.isEmpty ? "Queued Transfer" : batch.eventName)
                    .lineLimit(1)
                Text("\(batch.files.count) file\(batch.files.count == 1 ? "" : "s") · \(batch.totalBytes.formattedBytes)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help("\(batch.sourcePath) → \(batch.destinationPath)")
            Spacer(minLength: 4)
            Button("Remove Batch", systemImage: "xmark.circle") {
                model.removePendingTransferBatch(batch.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove this waiting batch. No files will be changed.")
        }
    }
}

/// One job in the list: what it was, and either its live progress or
/// when it ran, how long, and what it moved.
struct JobListRow: View {
    let entry: JobListEntry
    /// The session's job, for a running row's progress and current step.
    let live: JobSnapshot?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(entry.startedAt, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                switch entry.status {
                case .running(let progress):
                    ProgressView(value: progress)
                        .controlSize(.small)
                    Text(liveLine(progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .queued:
                    Text("Waiting to start")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .ended(let outcome):
                    HStack(spacing: 4) {
                        if outcome != .succeeded, let display = entry.display {
                            Text(display.label.replacingOccurrences(of: "Done · ", with: ""))
                                .foregroundStyle(display.tone.color)
                                .fontWeight(.semibold)
                        }
                        Text(endedLine)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch entry.status {
        case .queued: "clock"
        case .running: entry.action.map(Self.runningSymbol) ?? "arrow.trianglehead.2.clockwise.rotate.90"
        case .ended(let outcome): entry.display?.symbol ?? outcome.symbol
        }
    }

    private var tint: Color {
        switch entry.status {
        case .queued, .running: .blue
        case .ended(let outcome): entry.display?.tone.color ?? outcome.tint
        }
    }

    /// "61% · Copying to NAS · DSC00001.ARW"
    private func liveLine(_ progress: Double) -> String {
        var parts = [progress.formatted(.percent.precision(.fractionLength(0)))]
        if let item = live?.telemetry?.activeItems.first {
            parts.append("\(item.step) · \(item.name)")
        } else if let note = live?.note, !note.isEmpty {
            parts.append(note)
        }
        return parts.joined(separator: " · ")
    }

    /// "3:12 · 2.2 GB · 98 MB/s"
    private var endedLine: String {
        var parts: [String] = []
        if let end = entry.endedAt {
            parts.append(JobActivityDetail.durationText(end.timeIntervalSince(entry.startedAt)))
        }
        if let detail = entry.detail { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    static func runningSymbol(_ action: JobAction) -> String {
        switch action {
        case .faceScan: "person.crop.rectangle.stack"
        case .organize: "rectangle.3.group"
        case .nasRename: "arrow.left.arrow.right"
        case .ingestCard: "arrow.down.circle"
        case .freeUp: "trash"
        case .immichScan, .immichUpload: "square.and.arrow.up"
        case .verifyManifest: "checkmark.shield"
        case .diskSpeed, .networkSpeed: "gauge.with.dots.needle.33percent"
        default: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }
}

/// A card copy waiting its turn: what it will copy, from where to where,
/// and the controls the queue already has — start it now when nothing
/// else runs, or take it off the queue (no files change).
private struct QueuedBatchDetail: View {
    @Bindable var model: DashboardModel
    let batch: PendingTransferBatch
    let position: Int

    var body: some View {
        let photos = batch.files.count { kind($0.path) == .photo || kind($0.path) == .raw }
        let videos = batch.files.count { kind($0.path) == .video }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "clock")
                        .font(.title)
                        .foregroundStyle(.blue)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(batch.eventName.isEmpty ? "Queued Transfer" : batch.eventName)
                            .font(.title3.weight(.semibold))
                        Text(position == 1
                            ? (model.isBusy ? "Next — starts automatically after the current job" : "Next — waiting for the camera and Buffer")
                            : "Number \(position) in the queue")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    JobHistoryOutcomeBadge(display: JobOutcomeDisplay(label: "Queued", symbol: "clock", tone: .running))
                }
                WrappingRowLayout(spacing: 26, rowSpacing: 8) {
                    fact("Files", "\(batch.files.count.formatted())")
                    fact("Size", batch.totalBytes.formattedBytes)
                    if photos > 0 { fact("Photos", photos.formatted()) }
                    if videos > 0 { fact("Videos", videos.formatted()) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    route("From", batch.sourcePath, symbol: "sdcard")
                    route("To", batch.destinationPath, symbol: "externaldrive")
                }
                Text("Copies each file to the Buffer, then re-reads both and compares SHA-256 before it counts as copied. Nothing is removed from the card.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if position == 1 {
                        Button("Start Now", systemImage: "play.fill") { model.resumePendingTransfers() }
                            .disabled(model.isBusy || model.isStorageBenchmarkRunning)
                    }
                    Button("Remove from Queue", systemImage: "xmark.circle") { model.removePendingTransferBatch(batch.id) }
                        .help("Take this batch off the queue. No files will be changed.")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func kind(_ path: String) -> OrganizeMediaKind {
        OrganizeFileClassifier.kind(forExtension: (path as NSString).pathExtension)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }

    private func route(_ label: String, _ path: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A card transfer's own view under its job: camera → Buffer, its message,
/// every file with its progress, and Free Up Camera once all of them are
/// verified.
struct CardTransferSection: View {
    @Bindable var model: DashboardModel
    let queue: TransferQueueSnapshot
    @State private var showingSourceCleanup = false

    var body: some View {
        VStack(spacing: 0) {
            routeDiagram(queue)
            if let message = queue.message {
                Divider()
                messageBanner(message, queue: queue)
            }
            Divider()
            queueTable(queue)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                locationFooter(queue)
            }
            .background(.bar)
        }
        .sheet(isPresented: $showingSourceCleanup) {
            SourceCleanupSheet(model: model, queue: queue)
        }
    }

    /// "This source folder → this destination" — the same readable route the
    /// apply sheet draws, so a running transfer is obvious at a glance.
    private func routeDiagram(_ queue: TransferQueueSnapshot) -> some View {
        let photos = queue.items.count { fileKind($0.relativePath) == .photo || fileKind($0.relativePath) == .raw }
        let videos = queue.items.count { fileKind($0.relativePath) == .video }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("From")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                routeEndpoint(path: queue.sourcePath, symbol: "sdcard")
            }
            Image(systemName: "arrow.right.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("To")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                routeEndpoint(path: queue.destinationPath, symbol: "externaldrive")
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(queue.items.count) file\(queue.items.count == 1 ? "" : "s") · \(queue.totalBytes.formattedBytes)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if photos > 0 || videos > 0 {
                    HStack(spacing: 6) {
                        if photos > 0 {
                            Label("\(photos)", systemImage: "photo")
                        }
                        if videos > 0 {
                            Label("\(videos)", systemImage: "video.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func routeEndpoint(path: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(OrganizeRouteLabel.breadcrumb(for: path))
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(path)
    }

    private func fileKind(_ path: String) -> OrganizeMediaKind {
        OrganizeFileClassifier.kind(forExtension: (path as NSString).pathExtension)
    }

    private func messageBanner(_ message: String, queue: TransferQueueSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: queue.state == .failed ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                .foregroundStyle(queueColor(queue.state))
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(queueColor(queue.state).quinary)
        .help(queue.technicalDetail ?? message)
    }

    // MARK: - File queue

    /// Every file in the transfer as a native table: resizable columns,
    /// row selection, and ⌘C come with it.
    private func queueTable(_ queue: TransferQueueSnapshot) -> some View {
        Table(queue.items) {
            TableColumn("Name") { item in
                HStack(spacing: 8) {
                    Image(systemName: itemSymbol(item.state))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(itemColor(item.state))
                        .frame(width: 18)
                    Text(URL(fileURLWithPath: item.relativePath).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(item.detail ?? item.state.label)
            }
            .width(min: 160, ideal: 240)

            TableColumn("Folder") { item in
                Text(shortParentPath(item.relativePath))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(item.relativePath)
            }
            .width(min: 100, ideal: 170)

            TableColumn("Progress") { item in
                if showsItemProgress(item) {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(item.copiedBytes), total: Double(max(item.size, 1)))
                            .tint(itemColor(item.state))
                        Text("\(item.copiedBytes.formattedBytes) / \(item.size.formattedBytes)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                } else {
                    Text(item.size.formattedBytes)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 190)

            TableColumn("Status") { item in
                statusColumn(item, queue: queue)
            }
            .width(min: 90, ideal: 130)
        }
    }

    private func statusColumn(_ item: TransferQueueItem, queue: TransferQueueSnapshot) -> some View {
        let status = queue.statusText(for: item)
        return HStack(spacing: 4) {
            Text(status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor(item, queue: queue))
                .lineLimit(1)
            if let detail = status.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(status.detail ?? status.label)
    }

    private func statusColor(_ item: TransferQueueItem, queue: TransferQueueSnapshot) -> Color {
        if queue.statusText(for: item).label == "Starting" {
            return .blue
        }
        return itemColor(item.state)
    }

    private func locationFooter(_ queue: TransferQueueSnapshot) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                locationLabel(
                    title: "Camera",
                    value: URL(fileURLWithPath: queue.sourcePath).lastPathComponent,
                    symbol: "camera"
                )
                .help(queue.sourcePath)
                locationLabel(
                    title: "Buffer",
                    value: shortDestination(queue.destinationPath),
                    symbol: "externaldrive"
                )
                .help(queue.destinationPath)
            }

            Spacer(minLength: 12)

            // A permanent camera cleanup stays in the window, never a
            // prominent toolbar item.
            if canFreeUpCamera(queue) {
                Button("Free Up Camera…", role: .destructive) {
                    model.prepareSourceCleanup()
                    showingSourceCleanup = true
                }
                .help("Permanently remove only these checksum-matched files from the camera after one fresh recheck")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    static func revealFolder(_ path: String) {
        let url = URL(fileURLWithPath: DashboardModel.expandedPath(path), isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func canFreeUpCamera(_ queue: TransferQueueSnapshot) -> Bool {
        queue.state == .completed
            && queue.verifiedCount == queue.items.count
            && queue.items.contains { $0.state == .verified || $0.state == .alreadyPresent }
    }

    private func locationLabel(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func showsItemProgress(_ item: TransferQueueItem) -> Bool {
        item.size > 0 && (item.state == .copying || (item.state == .failed && item.copiedBytes > 0))
    }

    static func queueSummary(_ queue: TransferQueueSnapshot) -> String {
        if queue.state == .running,
           !queue.items.isEmpty,
           queue.items.allSatisfy({ $0.state == .waiting }) {
            return "Opening Camera and Buffer · file 1 starts next"
        }
        let completed = queue.items.count {
            $0.state == .copied
                || $0.state == .verified
                || $0.state == .alreadyPresent
                || $0.state == .sourceRemoved
        }
        if let activeIndex = queue.items.firstIndex(where: {
            $0.state == .copying || $0.state == .verifying || $0.state == .failed
        }) {
            let verb = queue.state == .failed ? "Stopped on" : "Working on"
            return "\(verb) file \(activeIndex + 1) of \(queue.items.count) · \(completed) copied · \(queue.verifiedCount) verified"
        }
        return "\(completed) copied · \(queue.verifiedCount) of \(queue.items.count) verified"
    }

    private func shortParentPath(_ path: String) -> String {
        let components = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .pathComponents
            .filter { $0 != "/" }
        return components.suffix(2).joined(separator: " / ")
    }

    private func shortDestination(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .pathComponents
            .filter { $0 != "/" }
            .suffix(2)
            .joined(separator: " / ")
    }

    private func queueColor(_ state: TransferQueueState) -> Color {
        switch state {
        case .running: .blue
        case .completed: .green
        case .failed: .orange
        case .cancelled: .secondary
        }
    }

    private func itemSymbol(_ state: TransferQueueItemState) -> String {
        switch state {
        case .waiting: "clock"
        case .copying: "arrow.down.circle.fill"
        case .copied: "document.badge.clock"
        case .verifying: "checkmark.circle.badge.questionmark"
        case .verified, .alreadyPresent: "checkmark.circle.fill"
        case .sourceRemoved: "externaldrive.badge.minus"
        case .conflict: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func itemColor(_ state: TransferQueueItemState) -> Color {
        switch state {
        case .waiting: .secondary
        case .copying, .copied, .verifying: .blue
        case .verified, .alreadyPresent: .green
        case .sourceRemoved: .teal
        case .conflict, .failed: .orange
        }
    }
}

extension JobAction {
    /// Short label the Jobs window shows for each kind of background job.
    var displayName: String {
        switch self {
        case .previewFiles: "Preview Files"
        case .prepareTestData: "Prepare Test Data"
        case .ingestCard: "Copy to Buffer"
        case .syncBuffer: "Archive / Sync"
        case .freeUp: "Free Up Space"
        case .checkout: "Check Out"
        case .checkinExports: "Check In Exports"
        case .immichScan: "Immich Check"
        case .verifyManifest: "Verify Manifest"
        case .diskSpeed: "Disk Speed Test"
        case .networkSpeed: "Network Speed Test"
        case .organize: "Organize"
        case .immichUpload: "Immich Upload"
        case .faceScan: "Face Scan"
        case .nasRename: "NAS Rename"
        }
    }
}

extension JobState {
    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

private struct SourceCleanupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: DashboardModel
    let queue: TransferQueueSnapshot

    @State private var confirmation = ""
    @State private var attemptedRemoval = false

    private var removableItems: [TransferQueueItem] {
        queue.items.filter { $0.state == .verified || $0.state == .alreadyPresent }
    }

    private var removableBytes: Int64 {
        removableItems.reduce(Int64(0)) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "externaldrive.badge.minus")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Free Up Camera")
                        .font(.title2.weight(.semibold))
                    Text("\(removableItems.count) file\(removableItems.count == 1 ? "" : "s") · \(removableBytes.formattedBytes)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Buffer copies are checksum verified", systemImage: "checkmark.shield.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Text("Camera Toolkit will hash every source file and its Buffer copy again. It removes nothing unless the entire selected set still matches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .groupBoxed()

            VStack(alignment: .leading, spacing: 6) {
                Label("Permanent removal", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Text("This frees space on \(URL(fileURLWithPath: queue.sourcePath).lastPathComponent). The camera files cannot be restored from Trash; the verified Buffer copies stay untouched.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Type REMOVE to continue")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
                TextField("REMOVE", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isSourceCleanupRunning || model.sourceCleanupMessage != nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .groupBoxed()

            if model.isSourceCleanupRunning {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(model.sourceCleanupJob?.note ?? "Rechecking files")
                        Spacer()
                        Text((model.sourceCleanupJob?.progress ?? 0).formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ProgressView(value: model.sourceCleanupJob?.progress ?? 0)
                        .progressViewStyle(.linear)
                }
            }

            if let message = model.sourceCleanupMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = cleanupError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(model.sourceCleanupMessage == nil ? "Cancel" : "Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isSourceCleanupRunning)

                if model.sourceCleanupMessage == nil {
                    Button("Recheck & Remove", role: .destructive) {
                        attemptedRemoval = true
                        model.removeVerifiedSourceFiles(
                            queueID: queue.id,
                            confirmation: confirmation
                        )
                    }
                    // Permanent camera deletion is never the Return key's
                    // default — it takes a click after typing REMOVE.
                    .disabled(
                        confirmation != SourceCleanupService.confirmationToken
                            || model.isSourceCleanupRunning
                    )
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(model.isSourceCleanupRunning)
    }

    private var cleanupError: String? {
        if let error = model.sourceCleanupError {
            return error
        }
        guard attemptedRemoval,
              model.sourceCleanupJob?.state == .failed else {
            return nil
        }
        return model.sourceCleanupJob?.note
    }
}

private extension View {
    /// Wraps a sheet callout in the native macOS group box.
    func groupBoxed() -> some View {
        GroupBox { self }
    }
}
