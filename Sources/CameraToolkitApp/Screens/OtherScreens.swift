import CameraToolkitCore
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
                MetricPill(title: "Server", value: "offline in demo", symbol: "network", tint: AppTheme.amber)
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

struct ConfigView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderView(
                eyebrow: "Config",
                title: "One place for paths and defaults",
                subtitle: "Browse with Finder-style panels or type paths directly. Config saves automatically and survives app restarts."
            )

            Panel(
                title: "Folders",
                symbol: "folder",
                helpTitle: "Folders",
                helpText: "These paths are saved in Camera Toolkit config. Demo Root is used by the safe demo today; the archive, buffer, and log paths are kept here so real integrations have one source of truth later."
            ) {
                ConfigPathRow(
                    title: "Demo Root",
                    detail: "Fake card, demo archive, and demo buffer live under this folder.",
                    path: Binding(
                        get: { model.configuration.demoRootPath },
                        set: { model.setConfigPath(\.demoRootPath, to: $0) }
                    ),
                    helpText: "The safe demo creates fake files under this root. Keep it somewhere local and disposable.",
                    browse: { model.chooseFolder(title: "Choose Demo Root", keyPath: \.demoRootPath) }
                )

                ConfigPathRow(
                    title: "Import Source",
                    detail: "The source folder used by Preview Copy and demo import.",
                    path: Binding(
                        get: { model.configuration.importSourcePath },
                        set: { model.setConfigPath(\.importSourcePath, to: $0) }
                    ),
                    helpText: "Use this for a local folder you want to scan. Demo mode still writes only to demo storage.",
                    browse: { model.chooseFolder(title: "Choose Import Source", keyPath: \.importSourcePath) }
                )

                ConfigPathRow(
                    title: "Archive Folder",
                    detail: "Long-term verified archive target for future real mode.",
                    path: Binding(
                        get: { model.configuration.archivePath },
                        set: { model.setConfigPath(\.archivePath, to: $0) }
                    ),
                    helpText: "This is saved now but not used for real writes until real storage mode is intentionally unlocked.",
                    browse: { model.chooseFolder(title: "Choose Archive Folder", keyPath: \.archivePath) }
                )

                ConfigPathRow(
                    title: "Buffer Folder",
                    detail: "Temporary working storage for future free-up checks.",
                    path: Binding(
                        get: { model.configuration.bufferPath },
                        set: { model.setConfigPath(\.bufferPath, to: $0) }
                    ),
                    helpText: "This is the place the app will eventually free up after checksum verification. Demo mode keeps this local.",
                    browse: { model.chooseFolder(title: "Choose Buffer Folder", keyPath: \.bufferPath) }
                )

                ConfigPathRow(
                    title: "Activity Log",
                    detail: "Permanent action log JSONL file.",
                    path: Binding(
                        get: { model.configuration.activityLogPath },
                        set: { model.setConfigPath(\.activityLogPath, to: $0) }
                    ),
                    helpText: "Jobs writes plain activity history here so the Jobs screen can reload it after restart.",
                    browse: model.chooseActivityLogFile
                )

                Text(model.configMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Panel(
                title: "Batch Defaults",
                symbol: "camera.metering.matrix",
                helpTitle: "Batch Defaults",
                helpText: "These defaults are saved with config and reused across launches. They describe the batch; they do not make real storage writable."
            ) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                    GridRow {
                        FormFieldLabel(title: "Camera", helpText: "The device label stored with future manifests.")
                        Picker(
                            "Camera",
                            selection: Binding(
                                get: { model.configuration.selectedDeviceID },
                                set: { value in model.setDeviceID(value) }
                            )
                        ) {
                            Text("Sony A7V").tag("sony-a7v")
                            Text("DJI Osmo 360").tag("osmo-360")
                            Text("DJI Mini 2").tag("dji-mini-2")
                            Text("iPhone").tag("iphone")
                        }
                    }

                    GridRow {
                        FormFieldLabel(title: "Trip", helpText: "A human name for the import batch.")
                        TextField(
                            "Trip name",
                            text: Binding(
                                get: { model.configuration.eventName },
                                set: { value in model.setEventName(value) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        FormFieldLabel(title: "Destination", helpText: "The configured destination preference for imports.")
                        Picker(
                            "Destination",
                            selection: Binding(
                                get: { model.configuration.importDestination },
                                set: { value in model.setImportDestination(value) }
                            )
                        ) {
                            Text("Demo Archive").tag(TransferLocation.nas)
                            Text("Demo Buffer").tag(TransferLocation.drive)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }

            Panel(title: "External Tools", symbol: "wrench.and.screwdriver") {
                MetricPill(title: "Transfer engine", value: "rclone command builder ready", symbol: "arrow.left.arrow.right", tint: AppTheme.accent)
                MetricPill(title: "Metadata", value: "exiftool planned", symbol: "camera.metering.matrix", tint: AppTheme.mint)
                MetricPill(title: "Uploads", value: "immich-go planned", symbol: "icloud.and.arrow.up", tint: .purple)
            }
        }
    }
}

private struct ConfigPathRow: View {
    var title: String
    var detail: String
    @Binding var path: String
    var helpText: String
    var browse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.headline)
                HelpButton(title: title, message: helpText)
                Spacer()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                PathAutocompleteField(path: $path, placeholder: "/Users/you/path")
                    .frame(height: 28)
                Button(action: browse) {
                    Label("Browse", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .fixedSize()
            }
        }
    }
}

#Preview("Overview") {
    AppShell(model: .preview)
        .frame(width: 1200, height: 780)
}
