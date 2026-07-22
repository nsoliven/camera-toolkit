import AppKit
import SwiftUI

@MainActor
final class DriveInformationWindowController: NSObject, NSWindowDelegate {
    static let shared = DriveInformationWindowController()

    private let inspector = DriveInformationViewModel()
    private var window: NSWindow?

    func show(
        request: DriveInformationRequest,
        capacity: StorageCapacitySnapshot?,
        model: DashboardModel
    ) {
        inspector.inspect(request, authoritativeCapacity: capacity)

        if let window {
            window.title = "\(request.name) Information"
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(
            rootView: DriveInformationView(inspector: inspector, dashboardModel: model)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(request.name) Information"
        window.identifier = NSUserInterfaceItemIdentifier("CameraToolkitDriveInformationWindow")
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = controller
        CameraToolkitWindowSizing.configure(window, as: .driveInformation)
        window.setContentSize(NSSize(width: 760, height: 680))
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        inspector.stop()
    }
}

private struct DriveInformationView: View {
    @Bindable var inspector: DriveInformationViewModel
    @Bindable var dashboardModel: DashboardModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let snapshot = inspector.snapshot {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if !snapshot.isMounted {
                            unavailableCard(snapshot)
                        } else {
                            capacityCard(snapshot)
                            healthCard(snapshot)
                            if case .trueNAS = snapshot.capacity?.source {
                                trueNASCard(snapshot)
                            }
                            detailCard(snapshot)
                        }
                    }
                    .padding(18)
                }
            } else {
                loadingContent
            }
        }
        .frame(
            minWidth: CameraToolkitPopOutWindow.driveInformation.minimumContentSize.width,
            maxWidth: .infinity,
            minHeight: CameraToolkitPopOutWindow.driveInformation.minimumContentSize.height,
            maxHeight: .infinity
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.opacity(0.11))
                Image(systemName: inspector.request?.symbol ?? "externaldrive.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(inspector.request?.name ?? "Drive Information")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 7) {
                    Text(inspector.request?.role ?? "Location")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                    if let path = inspector.request?.path {
                        Text(path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }

            Spacer(minLength: 10)

            Button("Show in Finder") {
                guard let request = inspector.request else { return }
                let url = URL(
                    fileURLWithPath: DashboardModel.expandedPath(request.path),
                    isDirectory: true
                )
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(inspector.snapshot?.isMounted != true)

            Button {
                inspector.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh drive information")
            .disabled(inspector.isLoading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var loadingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Reading storage information…")
                .font(.headline)
            Text("Capacity, disk model, and SMART status are checked in the background.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableCard(_ snapshot: DriveInformationSnapshot) -> some View {
        callout(
            title: "Location is not mounted",
            detail: snapshot.errorMessage ?? "Connect the drive or mount the network share, then refresh.",
            symbol: "externaldrive.badge.exclamationmark",
            color: .orange
        )
    }

    private func capacityCard(_ snapshot: DriveInformationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Storage", symbol: "chart.bar.fill")
            if let capacity = snapshot.capacity, let usedBytes = snapshot.usedBytes {
                ProgressView(value: capacity.usedFraction)
                    .progressViewStyle(.linear)
                    .tint(capacityColor(capacity))

                HStack(spacing: 0) {
                    storageMetric("USED", usedBytes.formattedWholeStorage)
                    Divider().frame(height: 34).padding(.horizontal, 18)
                    storageMetric("FREE", capacity.availableBytes.formattedWholeStorage)
                    Divider().frame(height: 34).padding(.horizontal, 18)
                    storageMetric("CAPACITY", capacity.totalBytes.formattedWholeStorage)
                    Spacer(minLength: 0)
                    Text(capacity.usedFraction.formatted(.percent.precision(.fractionLength(0))) + " used")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(capacityExplanation(capacity))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Capacity is unavailable for this mounted location.")
                    .foregroundStyle(.secondary)
            }
        }
        .driveInformationCard()
    }

    private func healthCard(_ snapshot: DriveInformationSnapshot) -> some View {
        let presentation = healthPresentation(snapshot)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: presentation.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(presentation.color)
                .frame(width: 34, height: 34)
                .background(presentation.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.headline)
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .driveInformationCard()
    }

    private func trueNASCard(_ snapshot: DriveInformationSnapshot) -> some View {
        guard case .trueNAS(
            let dataset,
            let pool,
            let poolAvailable,
            let poolTotal,
            let poolHealthy
        ) = snapshot.capacity?.source else {
            return AnyView(EmptyView())
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("TrueNAS", symbol: "server.rack")
                HStack(spacing: 10) {
                    Label(
                        poolHealthy ? "Pool reports healthy" : "Pool needs attention",
                        systemImage: poolHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(poolHealthy ? Color.green : Color.red)
                    Spacer()
                    Text("\(poolAvailable.formattedWholeStorage) free of \(poolTotal.formattedWholeStorage)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                infoRow("Dataset", dataset)
                infoRow("Pool", pool)
                Text("This verifies dataset and pool capacity. Individual NAS disk SMART details remain on TrueNAS because SMB does not expose them to macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .driveInformationCard()
        )
    }

    private func detailCard(_ snapshot: DriveInformationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Volume and Hardware", symbol: "externaldrive.fill")
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading,
                spacing: 14
            ) {
                detailFact("Volume", snapshot.volumeName)
                detailFact("Connection", snapshot.connection)
                detailFact("Mount point", snapshot.mountPoint, monospaced: true)
                detailFact("Format", snapshot.fileSystem)
                if snapshot.isNetworkShare {
                    detailFact("Hardware", "Managed by the NAS")
                } else {
                    detailFact("Model", snapshot.model)
                    detailFact("Media", snapshot.mediaName)
                    detailFact("Media type", mediaType(snapshot))
                    detailFact("Device", snapshot.deviceIdentifier.map { "/dev/\($0)" }, monospaced: true)
                    detailFact("Physical disk", snapshot.physicalDiskIdentifier.map { "/dev/\($0)" }, monospaced: true)
                }
                detailFact("Access", snapshot.isWritable.map { $0 ? "Read and write" : "Read only" })
                detailFact("Location", locationDescription(snapshot))
                detailFact("Ejectable", yesNo(snapshot.isEjectable))
                detailFact("Volume UUID", snapshot.volumeUUID, monospaced: true)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    guard let path = inspector.request?.path else { return }
                    FileClipboardWriter.copyPaths([
                        URL(fileURLWithPath: DashboardModel.expandedPath(path), isDirectory: true)
                    ])
                } label: {
                    Label("Copy Path", systemImage: "doc.on.clipboard")
                }

                Button {
                    StorageBenchmarkWindowController.shared.show(model: dashboardModel)
                } label: {
                    Label("Run Speed Test", systemImage: "gauge.with.dots.needle.50percent")
                }
                .disabled(dashboardModel.isBusy)

                Spacer()

                Text("Checked \(snapshot.checkedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .driveInformationCard()
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
    }

    private func storageMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private func detailFact(
        _ label: String,
        _ value: String?,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Group {
                if monospaced {
                    Text(value ?? "Unavailable")
                        .font(.caption.monospaced())
                } else {
                    Text(value ?? "Unavailable")
                        .font(.caption)
                }
            }
            .foregroundStyle(value == nil ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func healthPresentation(
        _ snapshot: DriveInformationSnapshot
    ) -> (title: String, detail: String, symbol: String, color: Color) {
        switch snapshot.smartHealth {
        case .verified:
            return (
                "SMART health verified",
                "macOS reports \(snapshot.smartStatus ?? "Verified") for this physical drive.",
                "checkmark.shield.fill",
                .green
            )
        case .warning(let status):
            return (
                "SMART status: \(status)",
                "The drive returned a status Camera Toolkit does not recognize as a clean verification. Check Disk Utility before deleting source files.",
                "exclamationmark.triangle.fill",
                .orange
            )
        case .failing(let status):
            return (
                "SMART health warning",
                "The drive reports \(status). Stop relying on this device and make a verified copy as soon as possible.",
                "exclamationmark.octagon.fill",
                .red
            )
        case .notSupported:
            return (
                "SMART is not exposed",
                "This is common for SD cards, cameras, and USB readers. It does not mean the media is failing; this connection simply cannot report SMART health.",
                "questionmark.diamond.fill",
                .secondary
            )
        case .unavailable where snapshot.isNetworkShare:
            return (
                "Drive health lives on the NAS",
                "SMB exposes the share, not its physical disks. Check TrueNAS for per-disk SMART tests and alerts.",
                "server.rack",
                .blue
            )
        case .unavailable:
            return (
                "SMART status unavailable",
                "macOS did not return a SMART status for this device or location.",
                "questionmark.diamond.fill",
                .secondary
            )
        }
    }

    private func capacityColor(_ capacity: StorageCapacitySnapshot) -> Color {
        if case .networkShareEstimate = capacity.source { return .orange }
        if case .trueNAS(_, _, _, _, false) = capacity.source { return .red }
        if capacity.availableFraction < 0.10 { return .red }
        if capacity.availableFraction < 0.20 { return .orange }
        return .blue
    }

    private func capacityExplanation(_ capacity: StorageCapacitySnapshot) -> String {
        switch capacity.source {
        case .localVolume:
            return "Measured from the mounted volume."
        case .networkShareEstimate:
            return "SMB estimate from macOS. Configure the TrueNAS connection in Settings for authoritative dataset and pool capacity."
        case .trueNAS(let dataset, let pool, _, _, let healthy):
            return "Verified against TrueNAS dataset \(dataset) on pool \(pool), which reports \(healthy ? "healthy" : "a problem")."
        }
    }

    private func mediaType(_ snapshot: DriveInformationSnapshot) -> String? {
        if snapshot.isSolidState == true { return "Solid state" }
        if snapshot.isSolidState == false { return "Rotational" }
        return snapshot.mediaType?.capitalized
    }

    private func locationDescription(_ snapshot: DriveInformationSnapshot) -> String? {
        if snapshot.isNetworkShare { return "Network share" }
        if snapshot.isInternal == true { return "Internal" }
        if snapshot.isInternal == false { return "External" }
        if snapshot.isRemovable == true { return "Removable" }
        return nil
    }

    private func yesNo(_ value: Bool?) -> String? {
        value.map { $0 ? "Yes" : "No" }
    }

    private func callout(title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .driveInformationCard()
    }
}

private extension View {
    func driveInformationCard() -> some View {
        padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}
