import SwiftUI

struct OverviewView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Native archive console",
                title: "Try the photo workflow with fake files",
                subtitle: "The demo builds a fake card, copies into a local archive, verifies checksums, and quarantines only files proven safe."
            )

            CommandBar {
                HelpedCommandButton(
                    title: "Try Safe Demo",
                    symbol: "play.circle",
                    prominence: .primary,
                    isDisabled: model.isBusy,
                    helpTitle: "What happens in the safe demo?",
                    helpText: "This creates a fake camera card, copies new files into a fake archive, writes and verifies a manifest, then moves one already-verified buffer file into a local quarantine folder. It does not touch real storage.",
                    action: model.runFullSimulation
                )

                HelpedCommandButton(
                    title: "Reset Demo",
                    symbol: "arrow.counterclockwise",
                    isDisabled: model.isBusy,
                    helpTitle: "Reset Demo",
                    helpText: "This recreates the fake card, fake archive, and fake buffer folders so you can run the workflow again from a clean local test state.",
                    action: model.seedSimulation
                )
            }

            LocationStatusGrid(locations: model.locations)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    TransferFlowPanel(plan: model.activePlan)
                        .frame(minWidth: 0, maxWidth: .infinity)
                    SafetyPanel(checks: model.safetyChecks)
                }

                VStack(alignment: .leading, spacing: 16) {
                    TransferFlowPanel(plan: model.activePlan)
                    SafetyPanel(checks: model.safetyChecks)
                }
            }

            SimulationSummaryPanel(summary: model.simulationSummary, statusMessage: model.statusMessage)
            JobsStrip(jobs: model.jobs)
        }
    }
}
