import SwiftUI

struct OverviewView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Native archive console",
                title: "Camera workflow control center",
                subtitle: "Configured paths, transfer tools, editor handoff, and Immich checks live in one workspace. Execution stays locked until you deliberately add a real run path."
            )

            CommandBar {
                HelpedCommandButton(
                    title: "Run Safety Test",
                    symbol: "play.circle",
                    prominence: .primary,
                    isDisabled: model.isBusy,
                    helpTitle: "Run Safety Test",
                    helpText: "This creates disposable camera-style test files, copies new files into a test archive, writes and verifies a manifest, then quarantines only files proven safe.",
                    action: model.runFullSimulation
                )

                HelpedCommandButton(
                    title: "Reset Test Data",
                    symbol: "arrow.counterclockwise",
                    isDisabled: model.isBusy,
                    helpTitle: "Reset Test Data",
                    helpText: "This recreates the disposable source, archive, and buffer folders so you can test the workflow again from a clean state.",
                    action: model.seedSimulation
                )
            }

            LocationStatusGrid(locations: model.locations)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    WorkflowPlanPanel(plan: model.workflowPlan(.importArchive))
                        .frame(minWidth: 0, maxWidth: .infinity)
                    WorkflowPlanPanel(plan: model.workflowPlan(.freeUpBuffer))
                        .frame(minWidth: 0, maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 16) {
                    WorkflowPlanPanel(plan: model.workflowPlan(.importArchive))
                    WorkflowPlanPanel(plan: model.workflowPlan(.freeUpBuffer))
                }
            }

            let fileActions = TransferFlowPanel(
                plan: model.activePlan,
                sourceURL: model.planFileSourceURL,
                openFile: model.openPlanFile,
                revealFile: model.revealPlanFileInFinder
            )

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    fileActions
                        .frame(minWidth: 0, maxWidth: .infinity)
                    SafetyPanel(checks: model.safetyChecks)
                }

                VStack(alignment: .leading, spacing: 16) {
                    fileActions
                    SafetyPanel(checks: model.safetyChecks)
                }
            }

            SimulationSummaryPanel(summary: model.simulationSummary, statusMessage: model.statusMessage)
            JobsStrip(jobs: model.jobs)
        }
    }
}
