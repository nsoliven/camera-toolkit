import CameraToolkitCore
import SwiftUI

struct ImportView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Import",
                title: "Review the copy before bytes move",
                subtitle: "Choose a local source or seed demo data, preview the immutable archive write, then run the simulation."
            )

            Panel(title: "Import Setup", symbol: "square.and.arrow.down") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                    GridRow {
                        Text("Source")
                        TextField("Source folder", text: $model.importSourcePath)
                            .textFieldStyle(.roundedBorder)
                    }
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
                            Text("Simulation Archive").tag(TransferLocation.nas)
                            Text("Simulation Buffer").tag(TransferLocation.drive)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                CommandBar {
                    CommandButton(
                        title: "Choose Folder",
                        symbol: "folder",
                        isDisabled: model.isBusy,
                        action: model.chooseImportFolder
                    )

                    CommandButton(
                        title: "Seed Demo",
                        symbol: "wand.and.stars",
                        isDisabled: model.isBusy,
                        action: model.seedSimulation
                    )

                    CommandButton(
                        title: "Preview",
                        symbol: "eye",
                        prominence: .primary,
                        isDisabled: model.isBusy,
                        action: model.previewImport
                    )

                    CommandButton(
                        title: "Run Simulation Import",
                        symbol: "checkmark.seal",
                        isDisabled: model.isBusy,
                        action: model.runSimulationImport
                    )
                }
            }

            TransferFlowPanel(plan: model.activePlan)
            SimulationSummaryPanel(summary: model.simulationSummary, statusMessage: model.statusMessage)
        }
    }
}
