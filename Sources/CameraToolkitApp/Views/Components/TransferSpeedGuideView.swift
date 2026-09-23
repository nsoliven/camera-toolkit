import SwiftUI

struct TransferSpeedGuideView: View {
    let queue: TransferQueueSnapshot
    @Bindable var model: DashboardModel

    @State private var connectedLinks: [USBLinkSnapshot] = []
    @State private var isLoadingLinks = true

    private let connectionRows = TransferSpeedReference.connectionRows
    private let mediaRows = TransferSpeedReference.mediaRows

    var body: some View {
        Form {
            Section {
                bottleneckCallout
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Label("Transfer Speed Guide", systemImage: "gauge.with.dots.needle.50percent")
                        .font(.headline)
                    Spacer()
                    Text(liveSpeed)
                        .font(.headline.monospacedDigit())
                    Text("job average")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoadingLinks || !connectedLinks.isEmpty {
                Section("Connected USB links") {
                    if isLoadingLinks {
                        LabeledContent("Reading negotiated link speeds…") {
                            ProgressView().controlSize(.small)
                        }
                    } else {
                        ForEach(connectedLinks) { link in
                            speedRow(
                                title: link.name,
                                detail: link.interfaceName,
                                result: "\(link.formattedLinkRate) → \(link.theoreticalMegabytesPerSecond) MB/s max"
                            )
                        }
                    }
                }
            }

            Section("Connections and enclosures") {
                ForEach(connectionRows) { row in
                    speedRow(title: row.title, detail: row.detail, result: row.result)
                }
            }

            Section {
                ForEach(mediaRows) { row in
                    speedRow(title: row.title, detail: row.detail, result: row.result)
                }
            } header: {
                Text("Cameras and cards")
            } footer: {
                VStack(alignment: .leading, spacing: 5) {
                    Text("USB labels use bits per second; file copies use bytes per second. Eight bits equal one byte, and protocol overhead lowers real transfers. The speed above is a whole-job average; verification alternates between the camera and Buffer, so the negotiated USB links are the better bottleneck evidence. The slowest source, cable, reader, enclosure, or destination sets the final speed.")
                    Text("U3 and V30 guarantee at least 30 MB/s sustained write. A2 is an app-performance rating—there is no A3 SD class.")
                    Text("Published ceilings: USB-IF, Intel, SD Association, DJI, and Samsung. Typical large-file ranges are approximate.")
                        .foregroundStyle(.tertiary)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button {
                        StorageBenchmarkWindowController.shared.show(model: model)
                    } label: {
                        Label("Run Storage Speed Tests…", systemImage: "gauge.with.dots.needle.50percent")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        // The popover supplies its own glass background.
        .scrollContentBackground(.hidden)
        .frame(width: 490)
        .frame(minHeight: 360, idealHeight: 620, maxHeight: 620)
        .task {
            connectedLinks = await USBLinkProbe.connectedStorageLinks()
            isLoadingLinks = false
        }
    }

    private var liveSpeed: String {
        guard queue.bytesPerSecond > 0 else { return "No sample" }
        return "\(Int64(queue.bytesPerSecond).formattedBytes)/s"
    }

    private var bottleneckCallout: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(bottleneckTitle)
                    .font(.subheadline.weight(.semibold))
                Text(bottleneckDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: bottleneckSymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(bottleneckColor)
                .font(.title3)
        }
    }

    private var osmoLink: USBLinkSnapshot? {
        connectedLinks.first { $0.name.localizedCaseInsensitiveContains("Osmo") }
    }

    private var isOsmoSource: Bool {
        queue.sourcePath.localizedCaseInsensitiveContains("osmo")
    }

    private var bottleneckTitle: String {
        if isLoadingLinks { return "Checking the connection chain" }
        if isOsmoSource, let osmoLink, osmoLink.bitsPerSecond <= 500_000_000 {
            return "Current connection is USB 2.0 — not the camera limit"
        }
        if queue.bytesPerSecond > 0, queue.bytesPerSecond < 55_000_000 {
            return "Result resembles USB 2.0 or slower media"
        }
        return "Compare the live result with the guide"
    }

    private var bottleneckDetail: String {
        if isLoadingLinks {
            return "Camera Toolkit is reading the negotiated USB link speeds without interrupting the transfer."
        }
        if isOsmoSource, let osmoLink, osmoLink.bitsPerSecond <= 500_000_000 {
            let measuredNote = queue.bytesPerSecond > 0
                ? "Your current rate is normal for that link."
                : "A transfer through this link will usually land around 30–45 MB/s."
            return "This Osmo-to-Mac path negotiated \(osmoLink.formattedLinkRate), whose wire ceiling is \(osmoLink.theoreticalMegabytesPerSecond) MB/s. That does not make the camera a 60 MB/s device. \(measuredNote) DJI rates Osmo 360 internal-memory copies up to 600 MB/s over USB 3.1, so try DJI's USB 3.1 cable or another verified USB 3 data cable connected directly to the Mac."
        }
        return "A fast enclosure cannot outrun a slower camera, card, cable, or reader. Compare the measured rate with every link below; the lowest matching result is usually the bottleneck."
    }

    private var bottleneckSymbol: String {
        isLoadingLinks || !hasLikelyBottleneck ? "info.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var bottleneckColor: Color {
        isLoadingLinks || !hasLikelyBottleneck ? .blue : .orange
    }

    private var hasLikelyBottleneck: Bool {
        if isOsmoSource, let osmoLink, osmoLink.bitsPerSecond <= 500_000_000 {
            return true
        }
        return queue.bytesPerSecond > 0 && queue.bytesPerSecond < 55_000_000
    }

    private func speedRow(title: String, detail: String, result: String) -> some View {
        LabeledContent {
            Text(result)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
        } label: {
            Text(title)
            Text(detail)
        }
    }
}
