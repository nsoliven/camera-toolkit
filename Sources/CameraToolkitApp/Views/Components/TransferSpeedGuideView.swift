import SwiftUI

private struct SpeedReferenceRow: Identifiable {
    var id: String { title }
    var title: String
    var detail: String
    var result: String
}

struct TransferSpeedGuideView: View {
    let queue: TransferQueueSnapshot

    @State private var connectedLinks: [USBLinkSnapshot] = []
    @State private var isLoadingLinks = true

    private let connectionRows = [
        SpeedReferenceRow(title: "USB 2.0", detail: "480 Mb/s · 60 MB/s wire ceiling", result: "30–45 MB/s typical"),
        SpeedReferenceRow(title: "USB 3.2 Gen 1", detail: "5 Gb/s · formerly USB 3.0", result: "350–500 MB/s"),
        SpeedReferenceRow(title: "USB 3.2 Gen 2", detail: "10 Gb/s · USB NVMe enclosure", result: "700–1,050 MB/s"),
        SpeedReferenceRow(title: "USB 3.2 Gen 2x2", detail: "20 Gb/s · host must support 2x2", result: "1,500–2,100 MB/s"),
        SpeedReferenceRow(title: "Thunderbolt 3 / 4", detail: "40 Gb/s · NVMe enclosure", result: "2,000–3,200 MB/s")
    ]

    private let mediaRows = [
        SpeedReferenceRow(title: "DJI Osmo 360 internal", detail: "USB 3.1 direct to Mac", result: "up to 600 MB/s"),
        SpeedReferenceRow(title: "UHS-I SD / microSD", detail: "standard bus ceiling", result: "up to 104 MB/s"),
        SpeedReferenceRow(title: "UHS-II SD", detail: "extra contact row required", result: "up to 312 MB/s"),
        SpeedReferenceRow(title: "Samsung EVO Plus (light blue)", detail: "U3 · A2 · V30 · compatible reader", result: "up to 160 MB/s read"),
        SpeedReferenceRow(title: "Samsung PRO Plus", detail: "U3 · A2 · V30 · compatible reader", result: "up to 180 / 130 MB/s")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transfer Speed Guide")
                        .font(.headline)
                    Text("Find the slowest link in the chain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(liveSpeed)
                        .font(.headline.monospacedDigit())
                    Text("job average")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    bottleneckCallout

                    if isLoadingLinks || !connectedLinks.isEmpty {
                        speedSection(title: "Connected USB links") {
                            if isLoadingLinks {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Reading negotiated link speeds…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
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

                    speedSection(title: "Connections and enclosures") {
                        ForEach(connectionRows) { row in
                            speedRow(title: row.title, detail: row.detail, result: row.result)
                        }
                    }

                    speedSection(title: "Cameras and cards") {
                        ForEach(mediaRows) { row in
                            speedRow(title: row.title, detail: row.detail, result: row.result)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("How to read these numbers")
                            .font(.caption.weight(.semibold))
                        Text("USB labels use bits per second; file copies use bytes per second. Eight bits equal one byte, and protocol overhead lowers real transfers. The speed above is a whole-job average; verification alternates between the camera and Buffer, so the negotiated USB links are the better bottleneck evidence. The slowest source, cable, reader, enclosure, or destination sets the final speed.")
                        Text("U3 and V30 guarantee at least 30 MB/s sustained write. A2 is an app-performance rating—there is no A3 SD class.")
                        Text("Published ceilings: USB-IF, Intel, SD Association, DJI, and Samsung. Typical large-file ranges are approximate.")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
        .frame(width: 490, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: bottleneckSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(bottleneckColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(bottleneckTitle)
                    .font(.subheadline.weight(.semibold))
                Text(bottleneckDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(bottleneckColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
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

    private func speedSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 11)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func speedRow(title: String, detail: String, result: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(result)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
