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
                        if !benchmark.results.isEmpty, !benchmark.pathVerdicts.isEmpty {
                            verdictSection
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
        let context = benchmark.linkContexts[target.id]
        let canWrite = target.access == .readWrite && target.isAvailable

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
                    if let context {
                        Text(context.headline + (context.detected ? "" : " · typical"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let detail = context.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } else if let capacity = target.totalCapacity {
                        Text(capacity.formattedBytes)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 16) {
                        resultValue(
                            title: "READ",
                            measurement: result?.read,
                            typical: context?.typicalRead
                        )
                        if target.access == .readWrite {
                            resultValue(
                                title: "WRITE",
                                measurement: result?.write,
                                typical: context?.typicalWrite
                            )
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Read") {
                            benchmark.run(target, kind: .read)
                        }
                        .disabled(benchmark.isRunning || model.isBusy || !target.isAvailable)
                        if target.access == .readWrite {
                            Button("Write") {
                                benchmark.run(target, kind: .write)
                            }
                            .disabled(benchmark.isRunning || model.isBusy || !canWrite)
                        }
                    }
                    .controlSize(.small)
                }
            }

            if isActive {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if let kind = benchmark.activeKind {
                            Text(kind == .read ? "Read test" : "Write test")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(targetColor(target))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(targetColor(target).opacity(0.10), in: Capsule())
                        }
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
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isActive ? targetColor(target).opacity(0.45) : Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func resultValue(
        title: String,
        measurement: StorageBenchmarkMeasurement?,
        typical: ClosedRange<Double>?
    ) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(measurement.map { speed($0.bytesPerSecond) } ?? "–")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
            if let typical {
                Text("typ. \(TransferSpeedReference.formattedRange(typical))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var verdictSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHERE THE BOTTLENECK IS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(benchmark.pathVerdicts) { verdict in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(verdict.title)
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 4)
                        chainView(verdict)
                    }
                    Text(verdict.headline)
                        .font(.caption.weight(.semibold))
                    Text(verdict.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func chainView(_ verdict: StoragePathVerdict) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(verdict.links.enumerated()), id: \.element.id) { index, link in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                let isBottleneck = index == verdict.bottleneckIndex
                VStack(alignment: .leading, spacing: 1) {
                    Text(link.name)
                        .font(.caption2.weight(isBottleneck ? .semibold : .regular))
                    Text("\(Int(link.megabytesPerSecond.rounded())) MB/s · \(link.isMeasured ? "measured" : link.detail)")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(isBottleneck ? .orange : .secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    (isBottleneck ? Color.orange : Color.primary).opacity(isBottleneck ? 0.14 : 0.05),
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
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
            Text("Camera cards stay read-only: the app samples existing media and writes nothing on them. Buffer and library destinations get a hidden temporary file that is written, flushed, read back uncached, and removed — including a Buffer drive that is also a camera source. Tests run one at a time and cannot start during a transfer.")
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

    private func speed(_ bytesPerSecond: Double) -> String {
        "\(Int64(max(bytesPerSecond, 0)).formattedBytes)/s"
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
