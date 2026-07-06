import CameraToolkitCore
import SwiftUI

struct ImportView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Import",
                title: "Preview the copy before bytes move",
                subtitle: "Pick a local source or make fake demo files, inspect the plan, then run the import against the demo archive."
            )

            Panel(
                title: "Configured Import",
                symbol: "square.and.arrow.down",
                helpTitle: "Configured Import",
                helpText: "Import reads from the persistent Config tab. Use Edit Config to change folders, camera, trip name, or destination in one place."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ConfigSummaryRow(title: "Source", value: model.configuration.importSourcePath)
                    ConfigSummaryRow(title: "Camera", value: model.configuration.selectedDeviceID)
                    ConfigSummaryRow(title: "Trip", value: model.configuration.eventName)
                    ConfigSummaryRow(title: "Destination", value: model.configuration.importDestination.rawValue.capitalized)
                }

                CommandBar {
                    HelpedCommandButton(
                        title: "Make Demo Files",
                        symbol: "wand.and.stars",
                        isDisabled: model.isBusy,
                        helpTitle: "Make Demo Files",
                        helpText: "Creates fake camera files, a fake existing archive file, and a fake buffer file so you can test the workflow safely.",
                        action: model.seedSimulation
                    )

                    HelpedCommandButton(
                        title: "Preview Copy",
                        symbol: "eye",
                        prominence: .primary,
                        isDisabled: model.isBusy,
                        helpTitle: "Preview Copy",
                        helpText: "Scans the source and archive, then shows which files are new, already present, or conflicting before anything copies.",
                        action: model.previewImport
                    )

                    HelpedCommandButton(
                        title: "Run Demo Import",
                        symbol: "checkmark.seal",
                        isDisabled: model.isBusy,
                        helpTitle: "Run Demo Import",
                        helpText: "Copies only new files into the demo archive, refuses overwrites, compares checksums, and writes a manifest if verification passes.",
                        action: model.runSimulationImport
                    )

                    HelpedCommandButton(
                        title: "Edit Config",
                        symbol: "slider.horizontal.3",
                        isDisabled: model.isBusy,
                        helpTitle: "Edit Config",
                        helpText: "Open Config to change folders, device defaults, trip name, and the permanent log location.",
                        action: { model.selectedSection = .config }
                    )
                }
            }

            WorkflowPlanPanel(plan: model.workflowPlan(.importArchive))
            TransferFlowPanel(plan: model.activePlan)
            SimulationSummaryPanel(summary: model.simulationSummary, statusMessage: model.statusMessage)
        }
    }
}

private struct ConfigSummaryRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}
