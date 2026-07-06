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
                title: "Import Setup",
                symbol: "square.and.arrow.down",
                helpTitle: "Import Setup",
                helpText: "These controls describe what would be imported. In this build, the destination is still a fake local archive, so changing these values cannot write to your real NAS or camera card."
            ) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                    GridRow {
                        FormFieldLabel(
                            title: "Source",
                            helpText: "The folder being scanned as if it were a camera card. For safe demo runs, this points at the fake card folder under Application Support."
                        )
                        TextField("Source folder", text: $model.importSourcePath)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        FormFieldLabel(
                            title: "Camera",
                            helpText: "The device label that will be saved into manifests later. It helps batches stay searchable, but it does not change file bytes."
                        )
                        Picker("Camera", selection: $model.selectedDevice) {
                            Text("Sony A7V").tag("sony-a7v")
                            Text("DJI Osmo 360").tag("osmo-360")
                            Text("DJI Mini 2").tag("dji-mini-2")
                            Text("iPhone").tag("iphone")
                        }
                    }
                    GridRow {
                        FormFieldLabel(
                            title: "Trip",
                            helpText: "A human name for the batch. Think shoot, day, client, vacation, or project."
                        )
                        TextField("Trip name", text: $model.eventName)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        FormFieldLabel(
                            title: "Destination",
                            helpText: "Where the demo import goes. Archive means the long-term verified copy. Buffer means temporary working storage."
                        )
                        Picker("Destination", selection: $model.importDestination) {
                            Text("Demo Archive").tag(TransferLocation.nas)
                            Text("Demo Buffer").tag(TransferLocation.drive)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                CommandBar {
                    HelpedCommandButton(
                        title: "Choose Folder",
                        symbol: "folder",
                        isDisabled: model.isBusy,
                        helpTitle: "Choose Folder",
                        helpText: "Pick a local folder to scan. This only previews and runs against the demo archive right now.",
                        action: model.chooseImportFolder
                    )

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
                }
            }

            TransferFlowPanel(plan: model.activePlan)
            SimulationSummaryPanel(summary: model.simulationSummary, statusMessage: model.statusMessage)
        }
    }
}
