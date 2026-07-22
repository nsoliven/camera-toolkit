import AppKit
import CameraToolkitCore
import SwiftUI

@MainActor
final class StorageBenchmarkWindowController: NSObject, NSWindowDelegate {
    static let shared = StorageBenchmarkWindowController()

    private let benchmarkModel = StorageBenchmarkViewModel()
    private var window: NSWindow?

    func show(model: DashboardModel) {
        benchmarkModel.refresh(from: model)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(
            rootView: StorageBenchmarkView(model: model, benchmark: benchmarkModel)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Storage Speed Tests"
        window.identifier = NSUserInterfaceItemIdentifier("CameraToolkitStorageBenchmarkWindow")
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = controller
        CameraToolkitWindowSizing.configure(window, as: .storageSpeedTests)
        window.setContentSize(NSSize(width: 820, height: 640))
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct StorageBenchmarkView: View {
    @Bindable var model: DashboardModel
    @Bindable var benchmark: StorageBenchmarkViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let osmoLink, osmoLink.bitsPerSecond <= 500_000_000 {
                        osmoLinkWarning(osmoLink)
                    }
                    if let globalError = benchmark.errors["global"] {
                        messageCallout(
                            title: "Speed test could not start",
                            detail: globalError,
                            symbol: "exclamationmark.triangle.fill",
                            color: .orange
                        )
                    }
                    if benchmark.targets.isEmpty {
                        ContentUnavailableView(
                            "No Storage Locations",
                            systemImage: "externaldrive.badge.questionmark",
                            description: Text("Connect a drive or add camera, Buffer, and photo-library locations in Settings.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 280)
                    } else {
                        ForEach(benchmark.targets) { target in
                            targetCard(target)
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            safetyFooter
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.opacity(0.11))
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("Storage Speed Tests")
                    .font(.title2.weight(.semibold))
                Text("Measure the source, Buffer, and library separately to find the slowest link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Picker("Sample", selection: $benchmark.sampleSize) {
                ForEach(BenchmarkSampleSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            }
            .labelsHidden()
            .frame(width: 96)
            .disabled(benchmark.isRunning)
            .help("Larger samples take longer but reduce cache and startup distortion")

            if benchmark.isRunning {
                Button("Stop", role: .cancel) {
                    benchmark.cancel()
                }
            } else {
                Button("Test All") {
                    benchmark.runAll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || benchmark.targets.allSatisfy { !$0.isAvailable })
            }

            Button {
                benchmark.refresh(from: model)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh connected drives and negotiated USB links")
            .disabled(benchmark.isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func targetCard(_ target: StorageBenchmarkTarget) -> some View {
        let isActive = benchmark.activeTargetID == target.id
        let result = benchmark.results[target.id]
        let error = benchmark.errors[target.id]

        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: targetSymbol(target))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(targetColor(target))
                    .frame(width: 32, height: 32)
                    .background(targetColor(target).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(target.name)
                            .font(.headline)
                        Text(target.isAvailable ? target.roleSummary : "Offline")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(target.isAvailable ? targetColor(target) : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                (target.isAvailable ? targetColor(target) : Color.secondary).opacity(0.10),
                                in: Capsule()
                            )
                    }
                    Text(target.volumeRoot.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)

                if let result {
                    resultColumns(result)
                } else if !isActive {
                    Text(accessLabel(target))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                Button(buttonTitle(target)) {
                    benchmark.run(target)
                }
                .disabled(benchmark.isRunning || model.isBusy || !target.isAvailable)
                .frame(width: 132)
            }

            if isActive {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(benchmark.phase)
                            .lineLimit(1)
                        Spacer()
                        if benchmark.liveBytesPerSecond > 0 {
                            Text(speed(benchmark.liveBytesPerSecond))
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ProgressView(value: benchmark.progress)
                        .progressViewStyle(.linear)
                        .tint(targetColor(target))
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let diagnosis = diagnosis(target: target, result: result) {
                Label(diagnosis, systemImage: "lightbulb.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isActive ? targetColor(target).opacity(0.45) : Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func resultColumns(_ result: StorageBenchmarkResult) -> some View {
        HStack(spacing: 16) {
            resultValue(title: "READ", value: speed(result.read.bytesPerSecond))
            if let write = result.write {
                resultValue(title: "WRITE", value: speed(write.bytesPerSecond))
            }
        }
    }

    private func resultValue(title: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
    }

    private func osmoLinkWarning(_ link: USBLinkSnapshot) -> some View {
        messageCallout(
            title: "Osmo is connected at USB 2.0, not USB 3.1",
            detail: "The live link is \(link.formattedLinkRate), only \(link.theoreticalMegabytesPerSecond) MB/s before overhead. DJI rates the camera up to 600 MB/s only with a USB 3.1 data link. Use File Transfer: USB and connect the official USB-C data cable directly to the Mac, then refresh this window.",
            symbol: "cable.connector.slash",
            color: .orange
        )
    }

    private func messageCallout(title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
    }

    private var safetyFooter: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
            Text("Camera and card sources are read-only: the app samples existing media and writes nothing. Buffer and library tests create one hidden temporary file, flush it, read it uncached, and remove it. Tests run one drive at a time and cannot start during a transfer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private var osmoLink: USBLinkSnapshot? {
        benchmark.connectedLinks.first { $0.name.localizedCaseInsensitiveContains("Osmo") }
    }

    private func diagnosis(
        target: StorageBenchmarkTarget,
        result: StorageBenchmarkResult?
    ) -> String? {
        guard let result else { return nil }
        if target.name.localizedCaseInsensitiveContains("Osmo"),
           let osmoLink,
           osmoLink.bitsPerSecond <= 500_000_000 {
            return "This read result is constrained by the current USB 2.0 negotiation; retest after the link shows USB 3.x."
        }
        guard target.roleNames.contains("Buffer"),
              let sourceResult = StorageBenchmarkTargetDiscovery
                .currentSourceTarget(in: benchmark.targets, transferQueue: model.transferQueue)
                .flatMap({ benchmark.results[$0.id] }) else {
            return nil
        }
        let destinationRate = result.write?.bytesPerSecond ?? result.read.bytesPerSecond
        if destinationRate > sourceResult.read.bytesPerSecond * 1.5 {
            let ratio = destinationRate / max(sourceResult.read.bytesPerSecond, 1)
            return "About \(ratio.formatted(.number.precision(.fractionLength(1))))× faster than the source—the Buffer is not the bottleneck."
        }
        return "Close to the source rate; this drive may also limit the copy."
    }

    private func speed(_ bytesPerSecond: Double) -> String {
        "\(Int64(max(bytesPerSecond, 0)).formattedBytes)/s"
    }

    private func buttonTitle(_ target: StorageBenchmarkTarget) -> String {
        guard target.isAvailable else { return "Offline" }
        return target.access == .readOnly ? "Test Read" : "Test Read + Write"
    }

    private func accessLabel(_ target: StorageBenchmarkTarget) -> String {
        if let capacity = target.totalCapacity {
            return "\(capacity.formattedBytes)\n\(target.access == .readOnly ? "Read-only test" : "Temporary-file test")"
        }
        return target.access == .readOnly ? "Read-only test" : "Temporary-file test"
    }

    private func targetSymbol(_ target: StorageBenchmarkTarget) -> String {
        if target.roleNames.contains("Camera Source") { return "camera.fill" }
        if target.roleNames.contains("Buffer") { return "externaldrive.fill.badge.checkmark" }
        if target.roleNames.contains("Photo Library") { return "photo.stack.fill" }
        return "externaldrive.fill"
    }

    private func targetColor(_ target: StorageBenchmarkTarget) -> Color {
        if !target.isAvailable { return .secondary }
        if target.roleNames.contains("Camera Source") { return .blue }
        if target.roleNames.contains("Buffer") { return .teal }
        if target.roleNames.contains("Photo Library") { return .orange }
        return .secondary
    }
}
