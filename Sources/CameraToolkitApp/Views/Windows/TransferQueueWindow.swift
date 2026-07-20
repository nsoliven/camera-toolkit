import AppKit
import CameraToolkitCore
import SwiftUI

@MainActor
final class TransferQueueWindowController: NSObject, NSWindowDelegate {
    static let shared = TransferQueueWindowController()

    private var window: NSWindow?

    func show(model: DashboardModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: TransferQueueView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transfer Queue"
        window.identifier = NSUserInterfaceItemIdentifier("CameraToolkitTransferQueueWindow")
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = controller
        CameraToolkitWindowSizing.configure(window, as: .transferQueue)
        window.setContentSize(NSSize(width: 840, height: 500))
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct TransferQueueView: View {
    @Bindable var model: DashboardModel
    @State private var showingSpeedGuide = false
    @State private var showingSourceCleanup = false

    var body: some View {
        Group {
            if let queue = model.transferQueue {
                queueContent(queue)
            } else if !model.pendingTransferBatches.isEmpty {
                pendingOnlyContent
            } else {
                ContentUnavailableView(
                    "No Transfers Yet",
                    systemImage: "arrow.down.circle",
                    description: Text("Start Copy to Buffer from the camera browser. This window opens automatically when a transfer starts.")
                )
            }
        }
        .frame(
            minWidth: CameraToolkitPopOutWindow.transferQueue.minimumContentSize.width,
            maxWidth: .infinity,
            minHeight: CameraToolkitPopOutWindow.transferQueue.minimumContentSize.height,
            maxHeight: .infinity
        )
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func queueContent(_ queue: TransferQueueSnapshot) -> some View {
        VStack(spacing: 0) {
            summary(queue)

            if let message = queue.message {
                Divider()
                messageBanner(message, queue: queue)
            }

            if !model.pendingTransferBatches.isEmpty {
                Divider()
                pendingBatchesSection
            }

            Divider()
            queueList(queue)
            Divider()
            locationFooter(queue)
        }
        .sheet(isPresented: $showingSourceCleanup) {
            SourceCleanupSheet(model: model, queue: queue)
        }
    }

    private var pendingOnlyContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transfers Waiting")
                        .font(.headline)
                    Text("The list is saved. Start it when the camera and Buffer are connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start Next Transfer") {
                    model.resumePendingTransfers()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.isStorageBenchmarkRunning)
            }
            .padding(16)
            .background(.bar)

            Divider()
            pendingBatchesSection
            Spacer(minLength: 0)
        }
    }

    private var pendingBatchesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("UP NEXT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("\(model.pendingTransferFileCount) file\(model.pendingTransferFileCount == 1 ? "" : "s") · \(model.pendingTransferByteCount.formattedBytes)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isBusy {
                    Text("Starts automatically after the current job")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Start Next") {
                        model.resumePendingTransfers()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.pendingTransferBatches.enumerated()), id: \.element.id) { index, batch in
                        pendingBatchRow(batch, position: index + 1)
                        if batch.id != model.pendingTransferBatches.last?.id {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
            .frame(maxHeight: model.transferQueue == nil ? .infinity : 116)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func pendingBatchRow(_ batch: PendingTransferBatch, position: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(position)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.blue)
                .frame(width: 24, height: 24)
                .background(Color.blue.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(batch.eventName.isEmpty ? "Queued Transfer" : batch.eventName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(URL(fileURLWithPath: batch.sourcePath).lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(batch.files.count) file\(batch.files.count == 1 ? "" : "s") · \(batch.totalBytes.formattedBytes)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                model.removePendingTransferBatch(batch.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this waiting batch. No files will be changed.")
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private func summary(_ queue: TransferQueueSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(queueColor(queue.state).opacity(0.12))
                    Image(systemName: queueSymbol(queue.state))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(queueColor(queue.state))
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(queue.phase)
                        .font(.headline)
                    Text(queueSummary(queue))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(phaseByteSummary(queue))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if queue.state == .running, queue.bytesPerSecond > 0 {
                            Text("\(Int64(queue.bytesPerSecond).formattedBytes)/s avg")
                                .monospacedDigit()
                                .help("Average for this copy or verification job. Verification alternates between camera and Buffer reads, so this is not an instantaneous camera-link measurement.")
                        } else {
                            Text(queueStateNote(queue.state))
                        }
                        Button {
                            showingSpeedGuide.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Compare this transfer with USB, Thunderbolt, camera, and SD card speeds")
                        .popover(isPresented: $showingSpeedGuide, arrowEdge: .bottom) {
                            TransferSpeedGuideView(queue: queue, model: model)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if queue.state != .running {
                    Button("Clear") {
                        model.dismissTransferQueue()
                    }
                    .help("Clear this finished transfer from the queue")
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(phaseProgressLabel(queue))
                    Spacer()
                    Text(queue.progress.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ProgressView(value: queue.progress)
                    .tint(queueColor(queue.state))
                    .progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.bar)
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
        .background(queueColor(queue.state).opacity(0.08))
        .help(queue.technicalDetail ?? message)
    }

    private func queueList(_ queue: TransferQueueSnapshot) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(queue.items) { item in
                    queueRow(item, queue: queue)
                    if item.id != queue.items.last?.id {
                        Divider().padding(.leading, 54)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func queueRow(_ item: TransferQueueItem, queue: TransferQueueSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: itemSymbol(item.state))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(itemColor(item.state))
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: item.relativePath).lastPathComponent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(shortParentPath(item.relativePath))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 5) {
                if showsItemProgress(item) {
                    ProgressView(value: Double(item.copiedBytes), total: Double(max(item.size, 1)))
                        .tint(itemColor(item.state))
                        .frame(width: 150)
                    Text("\(item.copiedBytes.formattedBytes) / \(item.size.formattedBytes)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(item.size.formattedBytes)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 168, alignment: .trailing)

            statusColumn(item, queue: queue)
                .frame(width: 112, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .help(item.detail ?? item.state.label)
    }

    private func statusColumn(_ item: TransferQueueItem, queue: TransferQueueSnapshot) -> some View {
        let status = queue.statusText(for: item)
        return VStack(alignment: .trailing, spacing: 2) {
            Text(status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor(item, queue: queue))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor(item, queue: queue).opacity(0.10), in: Capsule())

            if let detail = status.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
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

            if canFreeUpCamera(queue) {
                Button("Free Up Camera…", role: .destructive) {
                    model.prepareSourceCleanup()
                    showingSourceCleanup = true
                }
                .tint(.red)
                .help("Permanently remove only these checksum-matched files from the camera after one fresh recheck")
            }

            Button("Show Camera") {
                model.openEventFolder(queue.sourcePath)
            }
            Button("Show Buffer") {
                model.openEventFolder(queue.destinationPath)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
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

    private func queueSummary(_ queue: TransferQueueSnapshot) -> String {
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

    private func phaseByteSummary(_ queue: TransferQueueSnapshot) -> String {
        let processed = queue.phaseProcessedBytes ?? queue.processedBytes
        let total = queue.phaseTotalBytes ?? queue.totalBytes
        return "\(processed.formattedBytes) / \(total.formattedBytes)"
    }

    private func phaseProgressLabel(_ queue: TransferQueueSnapshot) -> String {
        let phase = queue.phase.lowercased()
        if phase.contains("verif") || phase.contains("check") { return "Verification progress" }
        if queue.state == .failed { return "Progress when stopped" }
        if queue.state == .completed { return "Transfer complete" }
        return "Copy progress"
    }

    private func queueStateNote(_ state: TransferQueueState) -> String {
        switch state {
        case .running: ""
        case .completed: "Checksum verified"
        case .failed: "Stopped safely"
        case .cancelled: "Cancelled"
        }
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

    private func queueSymbol(_ state: TransferQueueState) -> String {
        switch state {
        case .running: "arrow.down"
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .cancelled: "xmark"
        }
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
        case .copied: "doc.badge.clock"
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
            .padding(12)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

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
            .padding(12)
            .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

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
                .disabled(model.isSourceCleanupRunning)

                if model.sourceCleanupMessage == nil {
                    Button("Recheck & Remove", role: .destructive) {
                        attemptedRemoval = true
                        model.removeVerifiedSourceFiles(
                            queueID: queue.id,
                            confirmation: confirmation
                        )
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        confirmation != SourceCleanupService.confirmationToken
                            || model.isSourceCleanupRunning
                    )
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
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
