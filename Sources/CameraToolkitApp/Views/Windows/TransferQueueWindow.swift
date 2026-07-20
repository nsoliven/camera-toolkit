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
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transfer Queue"
        window.identifier = NSUserInterfaceItemIdentifier("CameraToolkitTransferQueueWindow")
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 400)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 460))
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct TransferQueueView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        Group {
            if let queue = model.transferQueue {
                queueContent(queue)
            } else {
                ContentUnavailableView(
                    "No Transfers Yet",
                    systemImage: "arrow.down.circle",
                    description: Text("Start Copy to Buffer from the camera browser. This window will show every file and open automatically.")
                )
            }
        }
        .frame(minWidth: 680, minHeight: 400)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func queueContent(_ queue: TransferQueueSnapshot) -> some View {
        VStack(spacing: 0) {
            summary(queue)
            Divider()

            if let message = queue.message {
                messageBanner(message, queue: queue)
                Divider()
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queue.items) { item in
                        queueRow(item)
                        if item.id != queue.items.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()
            locationFooter(queue)
        }
    }

    private func summary(_ queue: TransferQueueSnapshot) -> some View {
        HStack(spacing: 14) {
            Image(systemName: queueSymbol(queue.state))
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(queueColor(queue.state))
                .frame(width: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(queue.phase)
                    .font(.title2.bold())
                Text("\(queue.verifiedCount) of \(queue.items.count) files verified")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(queue.processedBytes.formattedBytes) of \(queue.totalBytes.formattedBytes)")
                    .font(.headline.monospacedDigit())
                if queue.state == .running, queue.bytesPerSecond > 0 {
                    Text("\(Int64(queue.bytesPerSecond).formattedBytes)/s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(queue.state == .completed ? "Checksum verified" : queue.state == .failed ? "Stopped safely" : "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if queue.state != .running {
                Button("Clear Queue") {
                    model.dismissTransferQueue()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            ProgressView(value: queue.progress)
                .tint(queueColor(queue.state))
                .progressViewStyle(.linear)
        }
    }

    private func messageBanner(_ message: String, queue: TransferQueueSnapshot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: queue.state == .failed ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                .foregroundStyle(queueColor(queue.state))
            Text(message)
                .font(.subheadline)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(queueColor(queue.state).opacity(0.10))
        .help(queue.technicalDetail ?? message)
    }

    private func queueRow(_ item: TransferQueueItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: itemSymbol(item.state))
                .font(.title3)
                .foregroundStyle(itemColor(item.state))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: item.relativePath).lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                let parent = URL(fileURLWithPath: item.relativePath).deletingLastPathComponent().path
                if parent != "." && parent != "/" {
                    Text(parent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            if item.size > 0,
               item.state == .copying || (item.state == .failed && item.copiedBytes > 0) {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: Double(item.copiedBytes), total: Double(item.size))
                        .tint(itemColor(item.state))
                        .frame(width: 160)
                    Text("\(item.copiedBytes.formattedBytes) / \(item.size.formattedBytes)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(item.size.formattedBytes)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(item.state.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(itemColor(item.state))
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .help(item.detail ?? item.state.label)
    }

    private func locationFooter(_ queue: TransferQueueSnapshot) -> some View {
        VStack(spacing: 8) {
            locationRow(label: "Camera", path: queue.sourcePath)
            locationRow(label: "Buffer", path: queue.destinationPath)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func locationRow(label: String, path: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("Open") {
                model.openEventFolder(path)
            }
        }
    }

    private func queueSymbol(_ state: TransferQueueState) -> String {
        switch state {
        case .running: "arrow.down.circle.fill"
        case .completed: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
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
