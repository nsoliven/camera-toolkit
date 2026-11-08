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
    @State private var monitor: JobActivityMonitor
    @State private var history: JobHistoryBrowser
    @State private var selection: UUID?

    /// `history` is a seam for the snapshot harness, which hands in a
    /// reader it already loaded.
    init(model: DashboardModel, selection: UUID? = nil, history: JobHistoryBrowser? = nil, monitor: JobActivityMonitor? = nil) {
        self.model = model
        _history = State(initialValue: history ?? JobHistoryBrowser(model: model))
        _selection = State(initialValue: selection)
        _monitor = State(initialValue: monitor ?? JobActivityMonitor())
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
        return JobsList.sections(session: model.jobs, history: history.jobs + recording, queueOrder: model.queuedFileJobs.map(\.id))
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
        } else if let id, let job = model.jobs.first(where: { $0.id == id && $0.state == .queued }) {
            QueuedFileJobDetail(
                model: model,
                job: job,
                position: (sections.queued.firstIndex { $0.id == id } ?? 0) + 1,
                runningTitle: sections.running.first?.title
            )
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
    @State private var compareRequest: CompareRequest?
    @State private var compareProblem: String?

    /// Comparing works on Sync to NAS rows: their paths are NAS mirror paths.
    private var compare: ((JobHistoryItem, CompareRequest.Mode) -> Void)? {
        guard detail?.job.kind == JobAction.syncBuffer.rawValue else { return nil }
        return { item, mode in
            if let pair = model.comparePair(for: item) {
                compareRequest = CompareRequest(pair: pair, mode: mode, fileName: item.fileName)
            } else {
                compareProblem = "The drive copy of \(item.fileName) was not found. Connect the drive it was synced from, then try again."
            }
        }
    }

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
                    JobHistoryFileTable(items: detail.items, zoom: $zoom, hover: hover, filter: $fileFilter, kind: detail.job.kind, compare: compare)
                        .frame(minHeight: 140, idealHeight: 240, maxHeight: .infinity)
                }
            } else {
                pane
            }
        }
        .onChange(of: duration, initial: true) { _, duration in
            zoom.setFull(0...max(duration, 1))
        }
        .sheet(item: $compareRequest) { request in
            FileCompareSheet(model: model, request: request)
        }
        .alert("Can't Compare", isPresented: Binding(get: { compareProblem != nil }, set: { if !$0 { compareProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(compareProblem ?? "")
        }
    }

    private var pane: some View {
        ScrollView {
            JobActivityDetail(
                live: live, detail: detail, monitor: monitor, zoom: $zoom, hover: hover,
                showIssues: transfer == nil && !(detail?.items.isEmpty ?? true) ? { fileFilter = .issues } : nil,
                compare: compare
            )
        }
    }
}

/// The job list: waiting card batches, running jobs, then every past job
/// by day, with runs of identical clean jobs folded. Drawn rather than an
/// `AppKit` source list so the selected row is a calm neutral highlight in
/// every system accent colour, and a row's progress bar stays readable.
private struct JobsSidebar: View {
    @Bindable var model: DashboardModel
    let sections: JobsList.Sections
    @Binding var selection: UUID?
    let message: String?
    @State private var openRuns: Set<UUID> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: .sectionHeaders) {
                    if !sections.running.isEmpty {
                        Section {
                            ForEach(sections.running) { entry in
                                row(entry, live: model.jobs.first { $0.id == entry.id })
                            }
                        } header: {
                            header("Running")
                        }
                    }
                    // Waiting their turn, in the order they will start: card
                    // copies saved for later, then any job the gate holds.
                    if !model.pendingTransferBatches.isEmpty || !sections.queued.isEmpty {
                        Section {
                            ForEach(Array(model.pendingTransferBatches.enumerated()), id: \.element.id) { index, batch in
                                pendingBatchRow(batch, position: index + 1)
                                    .background(highlight(for: batch.id))
                                    .contentShape(Rectangle())
                                    .onTapGesture { selection = batch.id }
                                    .id(batch.id)
                            }
                            ForEach(sections.queued) { entry in
                                row(entry, live: model.jobs.first { $0.id == entry.id })
                            }
                        } header: {
                            header(model.isBusy ? "Queued · starts after the current job" : "Queued")
                        }
                    }
                    ForEach(sections.days) { day in
                        Section {
                            ForEach(day.items) { item in
                                switch item {
                                case .job(let entry):
                                    row(entry, live: nil)
                                case .run(let run):
                                    runRow(run)
                                    if isOpen(run) {
                                        ForEach(run.entries) { entry in
                                            row(entry, live: nil)
                                                .padding(.leading, 12)
                                        }
                                    }
                                }
                            }
                        } header: {
                            header(day.title)
                        }
                    }
                    if let message {
                        Label(message, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                move(direction)
                if let selection { proxy.scrollTo(selection) }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Selected rows are a neutral fill, so nothing here can read as an
    /// error however the system accent is set.
    @ViewBuilder
    private func highlight(for id: UUID) -> some View {
        if selection == id {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.09))
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(.bar)
    }

    private func row(_ entry: JobListEntry, live: JobSnapshot?) -> some View {
        JobListRow(entry: entry, live: live)
            .background(highlight(for: entry.id))
            .contentShape(Rectangle())
            .onTapGesture { selection = entry.id }
            .accessibilityAddTraits(selection == entry.id ? [.isButton, .isSelected] : .isButton)
            .id(entry.id)
    }

    private func isOpen(_ run: JobListRun) -> Bool {
        openRuns.contains(run.id) || run.entries.contains { $0.id == selection }
    }

    /// "Copied queue to buffer  7" — what they are, how many, and when.
    private func runRow(_ run: JobListRun) -> some View {
        let open = isOpen(run)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            Text(run.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(run.entries.count.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .background(.quinary, in: Capsule())
            Spacer(minLength: 4)
            Text("\(run.oldestStart.formatted(date: .omitted, time: .shortened)) – \(run.newestStart.formatted(date: .omitted, time: .shortened))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if openRuns.contains(run.id) { openRuns.remove(run.id) } else { openRuns.insert(run.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(open ? "Hides these jobs" : "Lists these jobs")
        .id(run.id)
    }

    /// The rows arrow keys walk, top to bottom; a closed run counts as its
    /// newest job, and selecting that opens it.
    private var visibleIDs: [UUID] {
        var ids = sections.running.map(\.id) + model.pendingTransferBatches.map(\.id) + sections.queued.map(\.id)
        for day in sections.days {
            for item in day.items {
                switch item {
                case .job(let entry): ids.append(entry.id)
                case .run(let run): ids.append(contentsOf: isOpen(run) ? run.entries.map(\.id) : [run.id])
                }
            }
        }
        return ids
    }

    private func move(_ direction: MoveCommandDirection) {
        let ids = visibleIDs
        guard !ids.isEmpty else { return }
        guard let current = selection, let index = ids.firstIndex(of: current) else {
            selection = ids.first
            return
        }
        switch direction {
        case .up: selection = ids[max(index - 1, 0)]
        case .down: selection = ids[min(index + 1, ids.count - 1)]
        default: break
        }
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// A thin determinate bar that stays visible on any row background.
private struct JobRowProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.blue)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    }
}

/// One job in the list: what it was, and either its live progress or
/// when it ran, how long, and what it moved. Status reads the same way on
/// every row: blue while running, quiet when done, orange or red only when
/// something needs a look.
struct JobListRow: View {
    let entry: JobListEntry
    /// The session's job, for a running row's progress and current step.
    let live: JobSnapshot?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusGlyph
                .frame(width: 16)
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
                    JobRowProgressBar(fraction: progress)
                        .padding(.vertical, 2)
                    Text(liveLine(progress))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .queued:
                    Text("Waiting to start")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .ended(let outcome):
                    HStack(spacing: 5) {
                        if outcome != .succeeded || entry.display?.tone == .warning, let display = entry.display {
                            Text(display.label.replacingOccurrences(of: "Done · ", with: ""))
                                .foregroundStyle(display.tone.color)
                                .fontWeight(.medium)
                        }
                        Text(endedLine)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var statusGlyph: some View {
        Image(systemName: symbol)
            .font(.callout)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
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
        case .queued: .secondary
        case .running: .blue
        case .ended(let outcome):
            switch entry.display?.tone {
            case .success, .neutral: .secondary
            case .warning: .orange
            case .failure: .red
            case .running, nil: outcome.tint
            }
        }
    }

    /// "61% · Copying to NAS · DSC00001.ARW", or for a scan in passes,
    /// "50% · Pass 2 of 2 · Dogs".
    private func liveLine(_ progress: Double) -> String {
        var parts = [progress.formatted(.percent.precision(.fractionLength(0)))]
        if let label = live?.telemetry?.scanPass?.label {
            parts.append(label)
        } else if let item = live?.telemetry?.activeItems.first {
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

/// A deleting or space-freeing job waiting for the job gate (Clear from
/// Card, Take Off Drive, Free Up Source, Free Up Camera): what it will do,
/// its phases, where it stands in the queue, and Cancel — safe, since
/// nothing has run. Its typed confirmation already happened; starting it
/// stays with the queue.
private struct QueuedFileJobDetail: View {
    @Bindable var model: DashboardModel
    let job: JobSnapshot
    let position: Int
    let runningTitle: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "clock")
                        .font(.title)
                        .foregroundStyle(.blue)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(JobDetailFacts.plural(job.note.isEmpty ? job.action.displayName : job.note))
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(queueLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    JobHistoryOutcomeBadge(display: JobOutcomeDisplay(label: "Queued", symbol: "clock", tone: .running))
                }
                if !job.detail.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WHAT IT WILL DO")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(job.detail)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                let phases = Self.phases(job.detail)
                if !phases.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                            if index > 0 {
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Label(phase, systemImage: "circle.fill")
                                .labelStyle(PhaseChipLabelStyle(color: PhaseBreakdown.color(phase)))
                        }
                    }
                }
                Button("Cancel Job", systemImage: "xmark.circle", role: .destructive) {
                    model.cancelQueuedFileJob(id: job.id)
                }
                .help("Take this job off the queue. It has not started, so nothing changes.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var queueLine: String {
        let place = position == 1 ? "Next in the queue" : "Number \(position) in the queue"
        guard let runningTitle else { return "\(place) — starts in a moment" }
        return "\(place) — starts when “\(runningTitle)” finishes"
    }

    /// The phases the queued job's description names, in the order it
    /// runs them ("re-hashes … then removing" → Verify → Remove).
    static func phases(_ detail: String) -> [String] {
        let text = detail.lowercased()
        var found: [(Int, String)] = []
        for (needle, phase) in [("verify", "Verify"), ("re-hash", "Verify"), ("remov", "Remove"), ("delet", "Remove"), ("moving it into", "Move to Trash")] {
            if let range = text.range(of: needle) {
                let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                if !found.contains(where: { $0.1 == phase }) { found.append((offset, phase)) }
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

private struct PhaseChipLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .font(.system(size: 7))
                .foregroundStyle(color)
            configuration.title
                .font(.callout)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: Capsule())
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
        case .resolveConflict: "Resolve Conflict"
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
