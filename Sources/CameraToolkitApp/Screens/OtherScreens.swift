import SwiftUI

struct LibraryView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(eyebrow: "Library", title: "Archive browser", subtitle: "A native view for batches, manifests, and checkout-ready folders.")
            SimulationSummaryPanel(summary: model.simulationSummary, statusMessage: model.statusMessage)
        }
    }
}

struct DriveView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(eyebrow: "Drive", title: "Free space without losing originals", subtitle: "Free-up is quarantine-only after a live checksum comparison against the archive.")
            CommandBar {
                HelpedCommandButton(
                    title: "Try Free-Up Demo",
                    symbol: "archivebox",
                    prominence: .primary,
                    isDisabled: model.isBusy,
                    helpTitle: "Try Free-Up Demo",
                    helpText: "Looks at fake buffer files and moves only files that match the archive checksum into a local quarantine folder. Files missing from the archive stay put.",
                    action: model.runSimulationFreeUp
                )

                HelpedCommandButton(
                    title: "Reset Demo",
                    symbol: "arrow.counterclockwise",
                    isDisabled: model.isBusy,
                    helpTitle: "Reset Demo",
                    helpText: "Rebuilds the fake card, archive, and buffer folders so the free-up demo starts from known local test data.",
                    action: model.seedSimulation
                )
            }
            SafetyPanel(checks: model.safetyChecks)
            SimulationSummaryPanel(summary: model.simulationSummary, statusMessage: model.statusMessage)
        }
    }
}

struct ImmichView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(eyebrow: "Immich", title: "Library scan and upload control", subtitle: "Keep Immich as the view layer while the archive remains the source of truth.")
            Panel(title: "Connection", symbol: "sparkles.rectangle.stack") {
                MetricPill(title: "Server", value: "offline in simulation", symbol: "network", tint: AppTheme.amber)
                MetricPill(title: "External library", value: "Camera Archive", symbol: "rectangle.stack.badge.play", tint: AppTheme.mint)
            }
        }
    }
}

struct JobsView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(eyebrow: "Jobs", title: "Every action leaves a trail", subtitle: "Each demo action records what ran, whether it passed, and what the latest status was.")
            ActivityLogPanel(entries: model.activityLog)
            JobsStrip(jobs: model.jobs)
        }
    }
}

struct SettingsView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderView(eyebrow: "Settings", title: "Machine-local configuration", subtitle: "Paths and secrets stay out of git. Real integration comes after the safe demo coverage is strong.")
            Panel(title: "External Tools", symbol: "wrench.and.screwdriver") {
                MetricPill(title: "Transfer engine", value: "rclone command builder ready", symbol: "arrow.left.arrow.right", tint: AppTheme.accent)
                MetricPill(title: "Metadata", value: "exiftool planned", symbol: "camera.metering.matrix", tint: AppTheme.mint)
                MetricPill(title: "Uploads", value: "immich-go planned", symbol: "icloud.and.arrow.up", tint: .purple)
            }
            SimulationSummaryPanel(summary: model.simulationSummary, statusMessage: model.statusMessage)
        }
    }
}

#Preview("Overview") {
    AppShell(model: .preview)
        .frame(width: 1200, height: 780)
}
