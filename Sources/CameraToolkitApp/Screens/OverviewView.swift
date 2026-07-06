import SwiftUI

struct OverviewView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Native archive console",
                title: "Photo ingest without scary buttons",
                subtitle: "Plan first, verify by checksum, quarantine before deletion, and keep the archive immutable."
            )

            CommandBar {
                CommandButton(
                    title: "Run Full Simulation",
                    symbol: "play.circle",
                    prominence: .primary,
                    isDisabled: model.isBusy,
                    action: model.runFullSimulation
                )

                CommandButton(
                    title: "Reset Demo Data",
                    symbol: "arrow.counterclockwise",
                    isDisabled: model.isBusy,
                    action: model.seedSimulation
                )
            }

            LocationStatusGrid(locations: model.locations)

            HStack(alignment: .top, spacing: 16) {
                TransferFlowPanel(plan: model.activePlan)
                    .frame(minWidth: 0, maxWidth: .infinity)
                SafetyPanel(checks: model.safetyChecks)
            }

            SimulationSummaryPanel(summary: model.simulationSummary, statusMessage: model.statusMessage)
            JobsStrip(jobs: model.jobs)
        }
    }
}
