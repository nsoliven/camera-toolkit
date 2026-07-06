import CameraToolkitCore
import SwiftUI

struct OverviewView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HeaderView(
                    eyebrow: "Native archive console",
                    title: "Photo ingest without scary buttons",
                    subtitle: "Plan first, verify by checksum, quarantine before deletion, and keep the archive immutable."
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 14)], spacing: 14) {
                    ForEach(model.locations) { location in
                        LocationStatusCard(location: location)
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    TransferFlowPanel(model: model)
                    SafetyPanel(checks: model.safetyChecks)
                }

                JobsStrip(jobs: model.jobs)
            }
        }
    }
}

struct HeaderView: View {
    var eyebrow: String
    var title: String
    var subtitle: String

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                Text(title)
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Label("Mock mode", systemImage: "testtube.2")
                    .font(.headline)
                    .foregroundStyle(AppTheme.amber)
                Text("No real volumes touched")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct LocationStatusCard: View {
    var location: LocationCard

    var body: some View {
        Panel(title: nil, symbol: nil) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(tint)
                Spacer()
                Label(location.status.rawValue, systemImage: location.status.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(location.title)
                    .font(.title3.weight(.semibold))
                Text(location.subtitle)
                    .foregroundStyle(.secondary)
                Text(location.detail)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
    }

    private var icon: String {
        switch location.kind {
        case .card: "sdcard"
        case .drive: "externaldrive"
        case .nas: "server.rack"
        case .immich: "sparkles.rectangle.stack"
        case .mac: "macbook"
        }
    }

    private var tint: Color {
        switch location.status {
        case .ready: AppTheme.mint
        case .warning: AppTheme.amber
        case .offline: .red
        }
    }
}

struct TransferFlowPanel: View {
    @Bindable var model: DashboardModel

    var body: some View {
        Panel(title: "Current Plan", symbol: "arrow.triangle.2.circlepath") {
            HStack(spacing: 12) {
                FlowNode(title: "Card", symbol: "sdcard", tint: AppTheme.accent)
                FlowArrow(label: "copy")
                FlowNode(title: "NAS", symbol: "server.rack", tint: AppTheme.mint)
                FlowArrow(label: "watch")
                FlowNode(title: "Immich", symbol: "sparkles", tint: .purple)
            }
            .padding(.vertical, 4)

            HStack(spacing: 12) {
                MetricPill(title: "New files", value: "\(model.activePlan.new.count)", symbol: "plus.circle", tint: AppTheme.mint)
                MetricPill(title: "Already there", value: "\(model.activePlan.existing.count)", symbol: "checkmark.circle", tint: AppTheme.accent)
                MetricPill(title: "Conflicts", value: "\(model.activePlan.conflicts.count)", symbol: "exclamationmark.triangle", tint: AppTheme.amber)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.activePlan.new.prefix(4)) { file in
                    HStack {
                        Image(systemName: file.path.hasSuffix(".MP4") ? "video" : "photo")
                            .foregroundStyle(.secondary)
                        Text(file.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                        Spacer()
                        Text(file.size.formattedBytes)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct FlowNode: View {
    var title: String
    var symbol: String
    var tint: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 52, height: 46)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity)
    }
}

struct FlowArrow: View {
    var label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 46)
    }
}

struct SafetyPanel: View {
    var checks: [SafetyCheck]

    var body: some View {
        Panel(title: "Safety Gates", symbol: "lock.shield") {
            ForEach(checks) { check in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: check.state.symbol)
                        .font(.title3)
                        .foregroundStyle(color(for: check.state))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(check.title)
                            .font(.headline)
                        Text(check.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if check.id != checks.last?.id {
                    Divider()
                }
            }
        }
        .frame(width: 360)
    }

    private func color(for state: SafetyState) -> Color {
        switch state {
        case .passed: AppTheme.mint
        case .attention: AppTheme.amber
        case .blocked: .red
        }
    }
}

struct JobsStrip: View {
    var jobs: [JobSnapshot]

    var body: some View {
        Panel(title: "Recent Jobs", symbol: "list.bullet.clipboard") {
            ForEach(jobs) { job in
                HStack(spacing: 12) {
                    Circle()
                        .fill(color(for: job.state))
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.action.displayName)
                            .font(.headline)
                        Text(job.note)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProgressView(value: job.progress)
                        .frame(width: 180)
                    Text("\(Int(job.progress * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    private func color(for state: JobState) -> Color {
        switch state {
        case .queued: .secondary
        case .running: AppTheme.amber
        case .done: AppTheme.mint
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}

struct ImportView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Import",
                title: "Review the copy before bytes move",
                subtitle: "Pick a source, choose the camera, preview the immutable archive write, then run verification."
            )
            Panel(title: "Import Setup", symbol: "square.and.arrow.down") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                    GridRow {
                        Text("Camera")
                        Picker("Camera", selection: $model.selectedDevice) {
                            Text("Sony A7V").tag("sony-a7v")
                            Text("DJI Osmo 360").tag("osmo-360")
                            Text("DJI Mini 2").tag("dji-mini-2")
                            Text("iPhone").tag("iphone")
                        }
                    }
                    GridRow {
                        Text("Trip")
                        TextField("Trip name", text: $model.eventName)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Destination")
                        Picker("Destination", selection: $model.importDestination) {
                            Text("Home Server").tag(TransferLocation.nas)
                            Text("Portable Drive").tag(TransferLocation.drive)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                HStack {
                    Button {
                    } label: {
                        Label("Choose Folder", systemImage: "folder")
                    }
                    Button {
                    } label: {
                        Label("Preview", systemImage: "eye")
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Text("Run buttons are disabled until real-volume integration is explicitly enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TransferFlowPanel(model: model)
            Spacer()
        }
    }
}

struct LibraryView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(eyebrow: "Library", title: "Archive browser", subtitle: "A native view for batches, manifests, and checkout-ready folders.")
            Panel(title: "Batches", symbol: "photo.stack") {
                ContentUnavailableView("Archive browser is next", systemImage: "photo.stack", description: Text("The safety core is in place first; real NAS browsing will be wired behind read-only checks."))
            }
            Spacer()
        }
    }
}

struct DriveView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(eyebrow: "Drive", title: "Free space without losing originals", subtitle: "Free-up is quarantine-only after a live checksum comparison against the archive.")
            SafetyPanel(checks: model.safetyChecks)
            Spacer()
        }
    }
}

struct ImmichView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(eyebrow: "Immich", title: "Library scan and upload control", subtitle: "Keep Immich as the view layer while the archive remains the source of truth.")
            Panel(title: "Connection", symbol: "sparkles.rectangle.stack") {
                MetricPill(title: "Server", value: "immich.solnas.net", symbol: "network", tint: AppTheme.accent)
                MetricPill(title: "External library", value: "Camera Archive", symbol: "rectangle.stack.badge.play", tint: AppTheme.mint)
            }
            Spacer()
        }
    }
}

struct JobsView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(eyebrow: "Jobs", title: "Every action leaves a trail", subtitle: "Long-running work is owned by a serialized job runner, not by view state.")
            JobsStrip(jobs: model.jobs)
            Spacer()
        }
    }
}

struct SettingsView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderView(eyebrow: "Settings", title: "Machine-local configuration", subtitle: "Paths and secrets stay out of git. Real integration comes after test coverage.")
            Panel(title: "External Tools", symbol: "wrench.and.screwdriver") {
                MetricPill(title: "Transfer engine", value: "rclone", symbol: "arrow.left.arrow.right", tint: AppTheme.accent)
                MetricPill(title: "Metadata", value: "exiftool", symbol: "camera.metering.matrix", tint: AppTheme.mint)
                MetricPill(title: "Uploads", value: "immich-go", symbol: "icloud.and.arrow.up", tint: .purple)
            }
            Spacer()
        }
        .padding(28)
        .background(AppTheme.background)
    }
}

extension Int64 {
    var formattedBytes: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}

extension JobAction {
    var displayName: String {
        switch self {
        case .ingestCard: "Import"
        case .syncBuffer: "Sync buffer"
        case .freeUp: "Free up"
        case .checkout: "Checkout"
        case .checkinExports: "Upload edits"
        case .immichScan: "Immich scan"
        case .verifyManifest: "Verify manifest"
        }
    }
}

#Preview("Overview") {
    AppShell(model: .preview)
        .frame(width: 1200, height: 780)
}
