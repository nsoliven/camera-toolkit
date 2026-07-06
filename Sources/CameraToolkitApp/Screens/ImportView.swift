import CameraToolkitCore
import SwiftUI

struct ImportView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Import",
                title: "Plan imports against your archive",
                subtitle: "Pick a source, preview the checksum-safe copy plan against the configured Archive Folder, then use safety tests for disposable checks."
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
                        title: "Create Test Data",
                        symbol: "wand.and.stars",
                        isDisabled: model.isBusy,
                        helpTitle: "Create Test Data",
                        helpText: "Creates camera-style test files, an existing archive file, and a buffer file so you can test the workflow safely.",
                        action: model.seedSimulation
                    )

                    HelpedCommandButton(
                        title: "Preview Copy Plan",
                        symbol: "eye",
                        prominence: .primary,
                        isDisabled: model.isBusy,
                        helpTitle: "Preview Copy Plan",
                        helpText: "Scans the configured source and archive folders, then shows which files are new, already present, or conflicting before anything copies.",
                        action: model.previewImport
                    )

                    HelpedCommandButton(
                        title: "Run Import Safety Test",
                        symbol: "checkmark.seal",
                        isDisabled: model.isBusy,
                        helpTitle: "Run Import Safety Test",
                        helpText: "Copies only new test files, refuses overwrites, compares checksums, and writes a manifest if verification passes.",
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
            TransferFlowPanel(
                plan: model.activePlan,
                sourceURL: model.planFileSourceURL,
                openFile: model.openPlanFile,
                revealFile: model.revealPlanFileInFinder
            )
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
