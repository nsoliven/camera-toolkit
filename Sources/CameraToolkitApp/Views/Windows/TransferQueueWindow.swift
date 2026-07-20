import AppKit
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
        window.minSize = NSSize(width: 720, height: 440)
        window.maxSize = NSSize(width: 1_080, height: 720)
        window.contentViewController = controller
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

    var body: some View {
        Group {
            if let queue = model.transferQueue {
                queueContent(queue)
            } else {
                ContentUnavailableView(
                    "No Transfers Yet",
                    systemImage: "arrow.down.circle",
                    description: Text("Start Copy to Buffer from the camera browser. This window opens automatically when a transfer starts.")
                )
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func queueContent(_ queue: TransferQueueSnapshot) -> some View {
        VStack(spacing: 0) {
            summary(queue)

            if let message = queue.message {
                Divider()
                messageBanner(message, queue: queue)
            }

            Divider()
            queueList(queue)
            Divider()
            locationFooter(queue)
        }
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
                            TransferSpeedGuideView(queue: queue)
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
            $0.state == .copied || $0.state == .verified || $0.state == .alreadyPresent
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
        case .conflict: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func itemColor(_ state: TransferQueueItemState) -> Color {
        switch state {
        case .waiting: .secondary
        case .copying, .copied, .verifying: .blue
        case .verified, .alreadyPresent: .green
        case .conflict, .failed: .orange
        }
    }
}
