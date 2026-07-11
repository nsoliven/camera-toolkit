import CameraToolkitCore
import SwiftUI

struct SimpleCameraFlowPanel: View {
    @Bindable var model: DashboardModel
    var showsActions: Bool = true
    var showsFolderChoices: Bool = false
    var showsMoves: Bool = true
    var showsPaths: Bool = true

    private var places: [CameraPlace] {
        [
            CameraPlace(
                title: "Camera / Folder",
                detail: "The folder you copy from",
                path: model.configuration.importSourcePath,
                symbol: "sdcard",
                tint: AppTheme.accent
            ),
            CameraPlace(
                title: "Buffer",
                detail: "Working scratch space",
                path: model.expandedBufferRootPath,
                symbol: "externaldrive",
                tint: AppTheme.mint
            ),
            CameraPlace(
                title: "Photo Library / NAS",
                detail: "Long-term home for originals",
                path: model.expandedLibraryRootPath,
                symbol: "building.columns",
                tint: AppTheme.amber
            ),
            CameraPlace(
                title: "PC Work",
                detail: "Optional local edit space",
                path: model.expandedEditorWorkingFolderPath,
                symbol: "desktopcomputer",
                tint: .secondary
            )
        ]
    }

    private var moves: [CameraMove] {
        [
            CameraMove(
                title: "From Folder -> Buffer",
                status: "Ready",
                detail: "Best default when you want a fast working copy before saving to the photo library.",
                tint: AppTheme.mint
            ),
            CameraMove(
                title: "From Folder -> Photo Library",
                status: "Direct",
                detail: "Valid when you want to skip the buffer; still preview, check, and never delete the camera folder.",
                tint: AppTheme.accent
            ),
            CameraMove(
                title: "Buffer -> Photo Library",
                status: "Save",
                detail: "After edits, copy Originals to Originals and finished exports to Edited.",
                tint: AppTheme.amber
            ),
            CameraMove(
                title: "Photo Library -> Buffer or PC",
                status: "Edit copy",
                detail: "Use this when an older shoot needs another edit pass.",
                tint: .secondary
            ),
            CameraMove(
                title: "Edited Files -> Photo Library",
                status: "Save",
                detail: "Finished JPEG, TIFF, video, or delivery files belong with the library record.",
                tint: AppTheme.mint
            )
        ]
    }

    var body: some View {
        Panel(
            title: showsFolderChoices ? "Pick Folders" : "Places and Moves",
            symbol: "arrow.triangle.branch",
            helpTitle: showsFolderChoices ? "Pick Folders" : "Places and Moves",
            helpText: showsFolderChoices
                ? "Choose the folders for this copy: where photos come from, where buffer copies go, where the library lives, and where edit copies open."
                : "The app has four places: from folder, buffer, photo library, and optional PC work folder. The buttons choose a move between places."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if showsFolderChoices {
                    CameraFolderChoiceGrid(model: model)
                } else {
                    CameraPlacesGrid(places: places)
                }

                if showsActions {
                    CommandBar {
                        if showsFolderChoices {
                            HelpedCommandButton(
                                title: "Preview Files",
                                symbol: "eye",
                                prominence: .primary,
                                isDisabled: model.isBusy,
                                helpTitle: "Preview Files",
                                helpText: "Scan the from folder, compare it to the buffer, and queue new files. Nothing is copied yet.",
                                action: model.previewImport
                            )

                            HelpedCommandButton(
                                title: "Add All New",
                                symbol: "checklist.checked",
                                isDisabled: model.isBusy || model.activePlan.new.isEmpty,
                                helpTitle: "Add All New",
                                helpText: "Put every new file from the preview into the queue.",
                                action: model.queueAllNewFiles
                            )

                            HelpedCommandButton(
                                title: "Copy Queue to Buffer",
                                symbol: "externaldrive.badge.plus",
                                isDisabled: model.isBusy || model.queuedFiles.isEmpty,
                                helpTitle: "Copy Queue to Buffer",
                                helpText: "Copy only queued files into the buffer. Nothing is deleted or overwritten.",
                                action: model.copyQueuedFilesToBuffer
                            )
                        } else {
                            HelpedCommandButton(
                                title: "Preview Copy",
                                symbol: "eye",
                                prominence: .primary,
                                isDisabled: model.isBusy,
                                helpTitle: "Preview Copy",
                                helpText: "Check what would copy from the selected folder into the buffer before writing anything.",
                                action: model.previewImport
                            )

                            HelpedCommandButton(
                                title: "Copy to Buffer",
                                symbol: "externaldrive.badge.plus",
                                isDisabled: model.isBusy,
                                helpTitle: "Copy to Buffer",
                                helpText: "Copy new files from the selected folder into the buffer. Nothing is deleted or overwritten.",
                                action: model.copySourceToBuffer
                            )

                            HelpedCommandButton(
                                title: "Setup",
                                symbol: "checklist",
                                isDisabled: model.isBusy,
                                helpTitle: "Setup",
                                helpText: "Choose the from folder, buffer folder, photo library, photo list, and backup folder.",
                                action: { model.selectedSection = .setup }
                            )
                        }
                    }
                }

                if showsMoves {
                    CameraMovesList(moves: moves)
                }

                if showsPaths {
                    VStack(alignment: .leading, spacing: 8) {
                        SimpleCameraFlowPathRow(title: "Copy from", path: model.configuration.importSourcePath)
                        SimpleCameraFlowPathRow(title: "Buffer copies", path: model.expandedBufferIngestPath)
                        SimpleCameraFlowPathRow(title: "Export edits", path: model.expandedBufferExportsPath)
                        SimpleCameraFlowPathRow(title: "PC work", path: model.expandedEditorWorkingFolderPath)
                        SimpleCameraFlowPathRow(title: "Library originals", path: model.expandedLibraryOriginalsPath)
                        SimpleCameraFlowPathRow(title: "Library edits", path: model.expandedLibraryEditedPath)
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct CameraFolderChoiceGrid: View {
    @Bindable var model: DashboardModel

    private let columns = [
        GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            CameraFolderChoiceCard(
                title: "From Folder",
                detail: "Camera or card folder",
                path: model.configuration.importSourcePath,
                symbol: "sdcard",
                tint: AppTheme.accent,
                savedLocations: model.configuration.locations(role: .importSource),
                selectedID: model.configuration.selectedLocationID(for: .importSource),
                chooseTitle: "Choose From Folder",
                chooseAction: model.chooseImportFolder,
                useLocation: model.useConfiguredLocation
            )

            CameraFolderChoiceCard(
                title: "Buffer",
                detail: "Fast working copy",
                path: model.expandedBufferRootPath,
                symbol: "externaldrive",
                tint: AppTheme.mint,
                savedLocations: model.configuration.locations(role: .buffer),
                selectedID: model.configuration.selectedLocationID(for: .buffer),
                chooseTitle: "Choose Buffer",
                chooseAction: model.chooseBufferFolder,
                useLocation: model.useConfiguredLocation
            )

            CameraFolderChoiceCard(
                title: "Photo Library",
                detail: "Long-term home",
                path: model.expandedLibraryRootPath,
                symbol: "building.columns",
                tint: AppTheme.amber,
                savedLocations: model.configuration.locations(role: .archive),
                selectedID: model.configuration.selectedLocationID(for: .archive),
                chooseTitle: "Choose Library",
                chooseAction: model.chooseCameraLibraryRoot,
                useLocation: model.useConfiguredLocation
            )

            CameraFolderChoiceCard(
                title: "Edit Copies",
                detail: "Local editor folder",
                path: model.expandedEditorWorkingFolderPath,
                symbol: "desktopcomputer",
                tint: .secondary,
                savedLocations: [],
                selectedID: nil,
                chooseTitle: "Choose Edit Folder",
                chooseAction: model.chooseEditorWorkingFolder,
                useLocation: { _ in }
            )
        }
    }
}

private struct CameraFolderChoiceCard: View {
    var title: String
    var detail: String
    var path: String
    var symbol: String
    var tint: Color
    var savedLocations: [ConfiguredLocation]
    var selectedID: UUID?
    var chooseTitle: String
    var chooseAction: () -> Void
    var useLocation: (ConfiguredLocation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.headline)
                    .frame(width: 34, height: 34)
                    .foregroundStyle(tint)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }

            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(minHeight: 32, alignment: .topLeading)

            HStack(spacing: 8) {
                Button(action: chooseAction) {
                    Label("Choose", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .fixedSize()

                Menu {
                    ForEach(savedLocations) { location in
                        Button {
                            useLocation(location)
                        } label: {
                            Label(location.name, systemImage: location.id == selectedID ? "checkmark.circle.fill" : "folder")
                        }
                    }
                } label: {
                    Label("Saved", systemImage: "list.bullet")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .disabled(savedLocations.isEmpty)
                .fixedSize()
            }
        }
        .padding(12)
        .frame(minHeight: 156, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.22))
        )
    }
}

private struct CameraPlace: Identifiable {
    var id: String { title }
    var title: String
    var detail: String
    var path: String
    var symbol: String
    var tint: Color
}

private struct CameraMove: Identifiable {
    var id: String { title }
    var title: String
    var status: String
    var detail: String
    var tint: Color
}

private struct CameraPlacesGrid: View {
    var places: [CameraPlace]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(places) { place in
                CameraPlaceCard(place: place)
                if place.id != places.last?.id {
                    Divider()
                }
            }
        }
    }
}

private struct CameraPlaceCard: View {
    var place: CameraPlace

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: place.symbol)
                .font(.headline)
                .frame(width: 24)
                .foregroundStyle(place.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(place.title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(place.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(place.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CameraMovesList: View {
    var moves: [CameraMove]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(moves) { move in
                CameraMoveRow(move: move)
                if move.id != moves.last?.id {
                    Divider()
                }
            }
        }
    }
}

private struct CameraMoveRow: View {
    var move: CameraMove

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(move.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(move.title)
                        .font(.callout.weight(.semibold))
                    Text(move.status)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(move.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(move.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                Text(move.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 9)
    }
}

private struct SimpleCameraFlowStep: Identifiable {
    var id: Int { number }
    var number: Int
    var badge: String
    var title: String
    var detail: String
    var symbol: String
    var tint: Color
}

private struct SimpleCameraFlowPath: View {
    var steps: [SimpleCameraFlowStep]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    SimpleCameraFlowStepCard(step: step)
                        .frame(minWidth: 118, maxWidth: .infinity)
                    if index < steps.count - 1 {
                        SimpleCameraFlowConnector()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    SimpleCameraFlowStepRow(step: step)
                    if index < steps.count - 1 {
                        VerticalFlowConnector()
                    }
                }
            }
        }
    }
}

private struct SimpleCameraFlowStepCard: View {
    var step: SimpleCameraFlowStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                StepNumberBadge(number: step.number, tint: step.tint)
                Spacer(minLength: 8)
                Text(step.badge)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(step.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(step.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(minHeight: 118, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(step.tint.opacity(0.18))
        )
    }
}

private struct SimpleCameraFlowConnector: View {
    var body: some View {
        HStack(spacing: 3) {
            Rectangle()
                .fill(AppTheme.accent.opacity(0.34))
                .frame(width: 12, height: 2)
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.accent)
        }
        .frame(width: 28)
        .accessibilityHidden(true)
    }
}

private struct SimpleCameraFlowStepRow: View {
    var step: SimpleCameraFlowStep

    var body: some View {
        HStack(spacing: 12) {
            StepNumberBadge(number: step.number, tint: step.tint)
            Image(systemName: step.symbol)
                .font(.headline)
                .foregroundStyle(step.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(step.title)
                        .font(.headline)
                    Text(step.badge)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(step.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(step.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SimpleCameraFlowPathRow: View {
    var title: String
    var path: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct TransferFlowPanel: View {
    var plan: CopyPlan
    var sourceURL: (FileRecord) -> URL? = { _ in nil }
    var openFile: ((FileRecord) -> Void)?
    var revealFile: ((FileRecord) -> Void)?

    var body: some View {
        Panel(
            title: "Copy Plan",
            symbol: "arrow.triangle.2.circlepath",
            helpTitle: "Copy Plan",
            helpText: "This shows what would copy. New files can be copied, files already there are skipped, and conflicts need your review."
        ) {
            CopyFlowPath()

            HStack(spacing: 12) {
                MetricPill(title: "New files", value: "\(plan.new.count)", symbol: "plus.circle", tint: AppTheme.mint)
                MetricPill(title: "Already there", value: "\(plan.existing.count)", symbol: "checkmark.circle", tint: AppTheme.accent)
                MetricPill(title: "Conflicts", value: "\(plan.conflicts.count)", symbol: "exclamationmark.triangle", tint: AppTheme.amber)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.new.prefix(5)) { file in
                    CopyPlanFileRow(
                        file: file,
                        url: sourceURL(file),
                        openFile: openFile,
                        revealFile: revealFile
                    )
                }
                if plan.new.isEmpty {
                    Text("No new files in the current plan.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct CopyFlowPath: View {
    private let stages = [
        FlowStage(number: 1, title: "From", subtitle: "Selected folder", symbol: "sdcard", tint: AppTheme.accent),
        FlowStage(number: 2, title: "Copy", subtitle: "No overwrite", symbol: "arrow.right.doc.on.clipboard", tint: AppTheme.mint),
        FlowStage(number: 3, title: "Check", subtitle: "Compare copied bytes", symbol: "checkmark.shield", tint: AppTheme.amber),
        FlowStage(number: 4, title: "Proof File", subtitle: "Save what happened", symbol: "checklist.checked", tint: .purple)
    ]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    FlowStageCard(stage: stage)
                        .frame(minWidth: 130, maxWidth: .infinity)
                    if index < stages.count - 1 {
                        FlowConnector()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    FlowStageRow(stage: stage)
                    if index < stages.count - 1 {
                        VerticalFlowConnector()
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FlowStage: Identifiable {
    var id: Int { number }
    var number: Int
    var title: String
    var subtitle: String
    var symbol: String
    var tint: Color
}

private struct FlowStageCard: View {
    var stage: FlowStage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                StepNumberBadge(number: stage.number, tint: stage.tint)
                Spacer(minLength: 8)
                Image(systemName: stage.symbol)
                    .font(.title3)
                    .frame(width: 40, height: 36)
                    .foregroundStyle(stage.tint)
                    .background(stage.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(stage.title)
                    .font(.headline)
                Text(stage.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(minHeight: 116, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(stage.tint.opacity(0.18))
        )
    }
}

private struct FlowStageRow: View {
    var stage: FlowStage

    var body: some View {
        HStack(spacing: 12) {
            StepNumberBadge(number: stage.number, tint: stage.tint)
            Image(systemName: stage.symbol)
                .font(.headline)
                .foregroundStyle(stage.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.title)
                    .font(.headline)
                Text(stage.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StepNumberBadge: View {
    var number: Int
    var tint: Color

    var body: some View {
        VStack(spacing: 1) {
            Text("STEP")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(tint)
            Text("\(number)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .frame(width: 42, height: 42)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.22))
        )
    }
}

private struct FlowConnector: View {
    var body: some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(AppTheme.accent.opacity(0.34))
                .frame(width: 28, height: 2)
            Image(systemName: "arrow.right.circle.fill")
                .font(.headline)
                .foregroundStyle(AppTheme.accent)
        }
        .frame(width: 54)
        .accessibilityHidden(true)
    }
}

private struct VerticalFlowConnector: View {
    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(AppTheme.accent.opacity(0.34))
                .frame(width: 2, height: 16)
                .padding(.leading, 20)
            Image(systemName: "arrow.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.accent)
            Spacer()
        }
        .accessibilityHidden(true)
    }
}

private struct CopyPlanFileRow: View {
    var file: FileRecord
    var url: URL?
    var openFile: ((FileRecord) -> Void)?
    var revealFile: ((FileRecord) -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.path.hasSuffix(".MP4") ? "video" : "photo")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(file.path)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            Text(file.size.formattedBytes)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)

            HStack(spacing: 6) {
                if let openFile {
                    PlanFileActionButton(
                        symbol: "eye",
                        help: "Open a protected working copy"
                    ) {
                        openFile(file)
                    }
                }

                if let revealFile {
                    PlanFileActionButton(
                        symbol: "folder",
                        help: "Reveal original file in Finder"
                    ) {
                        revealFile(file)
                    }
                }

                if let url {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("Share original file")
                    .accessibilityLabel("Share \(file.path)")
                }
            }
            .frame(width: actionClusterWidth, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var actionClusterWidth: CGFloat {
        var count = 0
        if openFile != nil { count += 1 }
        if revealFile != nil { count += 1 }
        if url != nil { count += 1 }
        return CGFloat(max(count, 1)) * 34
    }
}

private struct PlanFileActionButton: View {
    var symbol: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct WorkflowPlanPanel: View {
    var plan: WorkflowPlan?

    var body: some View {
        Panel(
            title: plan?.title ?? "Move Plan",
            symbol: "point.topleft.down.curvedto.point.bottomright.up",
            helpTitle: "Move Plan",
            helpText: "This shows plain-language steps. Details still show exact commands when useful. Locked steps do not run."
        ) {
            if let plan {
                HStack(spacing: 12) {
                    MetricPill(title: "Status", value: plan.status.displayName, symbol: plan.status.symbol, tint: plan.status.tint)
                    MetricPill(title: "Steps", value: "\(plan.steps.count)", symbol: "list.bullet.rectangle", tint: AppTheme.accent)
                    MetricPill(title: "Writes", value: "\(plan.steps.filter(\.writesFiles).count)", symbol: "pencil.and.outline", tint: AppTheme.amber)
                }

                Text(plan.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                WorkflowStepTimeline(steps: plan.steps)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Safety Checks")
                        .font(.headline)
                    ForEach(plan.gates) { gate in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: gate.isSatisfied ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(gate.isSatisfied ? AppTheme.mint : AppTheme.amber)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(gate.title)
                                    .font(.callout.weight(.semibold))
                                Text(gate.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                    }
                }
            } else {
                Text("No plan available yet. Open Config and refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WorkflowPlanStepRow: View {
    var step: WorkflowPlanStep
    var number: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StepNumberBadge(number: number, tint: stepTint)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(step.title, systemImage: step.writesFiles ? "pencil.and.outline" : "eye")
                        .font(.headline)
                    Text(step.isExecutableNow ? "ready" : "locked")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(stepTint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(stepTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    Spacer()
                }

                Text(step.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                if let endpoint = step.endpoint {
                    Text(endpoint)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.accent)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                if let command = step.command, !command.isEmpty {
                    Text(command.shellPreview)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                        .truncationMode(.middle)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(stepTint.opacity(0.14))
        )
    }

    private var stepTint: Color {
        step.isExecutableNow ? AppTheme.mint : AppTheme.amber
    }
}

private struct WorkflowStepTimeline: View {
    var steps: [WorkflowPlanStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                WorkflowPlanStepRow(step: step, number: index + 1)
                if index < steps.count - 1 {
                    WorkflowStepConnector()
                }
            }
        }
    }
}

private struct WorkflowStepConnector: View {
    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(AppTheme.amber.opacity(0.28))
                .frame(width: 2, height: 18)
                .padding(.leading, 33)
            Image(systemName: "arrow.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.amber)
            Text("then")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 3)
        .accessibilityHidden(true)
    }
}

private extension WorkflowPlanStatus {
    var displayName: String {
        switch self {
        case .ready: "Ready"
        case .needsConfig: "Needs Setup"
        case .locked: "Locked"
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle"
        case .needsConfig: "slider.horizontal.3"
        case .locked: "lock"
        }
    }

    var tint: Color {
        switch self {
        case .ready: AppTheme.mint
        case .needsConfig: AppTheme.amber
        case .locked: AppTheme.amber
        }
    }
}

private extension Array where Element == String {
    var shellPreview: String {
        map { value in
            if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: #""'\"#))) == nil {
                return value
            }
            return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        .joined(separator: " ")
    }
}

struct SimulationSummaryPanel: View {
    var summary: SimulationSummary?
    var statusMessage: String

    var body: some View {
        Panel(
            title: "Safety Test Result",
            symbol: "checklist.checked",
            helpTitle: "Safety Test Result",
            helpText: "This summarizes the last test. Files copied to the test library, proven matches moved aside, and unsafe files stayed put."
        ) {
            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                MetricPill(title: "Copied", value: "\(summary?.copiedCount ?? 0)", symbol: "doc.on.doc", tint: AppTheme.accent)
                MetricPill(title: "Moved aside", value: "\(summary?.quarantinedCount ?? 0)", symbol: "archivebox", tint: AppTheme.mint)
                MetricPill(title: "Left alone", value: "\(summary?.leftUnsafeCount ?? 0)", symbol: "exclamationmark.triangle", tint: AppTheme.amber)
            }

            if let summary {
                VStack(alignment: .leading, spacing: 6) {
                    PathRow(title: "Root", path: summary.root)
                    PathRow(title: "From", path: summary.sourcePath)
                    PathRow(title: "Library", path: summary.archivePath)
                    PathRow(title: "Buffer", path: summary.bufferPath)
                }
            }
        }
    }
}

private struct PathRow: View {
    var title: String
    var path: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct ActivityLogPanel: View {
    var entries: [ActivityLogEntry]

    var body: some View {
        Panel(
            title: "Permanent Activity Log",
            symbol: "clock.arrow.circlepath",
            helpTitle: "Permanent Activity Log",
            helpText: "This is saved on disk and survives app restarts. It records the actions you took in normal language, so you can answer: what did I do, when did it happen, and did it pass?"
        ) {
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No saved actions yet.")
                        .font(.headline)
                    Text("Run a safety test, preview a copy plan, or create test data and the app will append an entry here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
                    ForEach(entries.prefix(30)) { entry in
                        ActivityLogRow(entry: entry)
                        if entry.id != entries.prefix(30).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct ActivityLogRow: View {
    var entry: ActivityLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.title)
                        .font(.headline)
                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(entry.summary)
                    .font(.callout)
                Text(entry.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Text(entry.state.activityLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.vertical, 12)
    }

    private var icon: String {
        switch entry.state {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "minus.circle.fill"
        case .running: "clock.fill"
        case .queued: "circle.dashed"
        }
    }

    private var color: Color {
        switch entry.state {
        case .done: AppTheme.mint
        case .failed: .red
        case .cancelled: .secondary
        case .running: AppTheme.amber
        case .queued: .secondary
        }
    }
}

struct JobsStrip: View {
    var jobs: [JobSnapshot]
    @State private var selectedJob: JobSnapshot?

    var body: some View {
        Panel(
            title: "Current Session",
            symbol: "list.bullet.clipboard",
            helpTitle: "Current Session",
            helpText: "These rows are the live jobs from this app session. The permanent activity log above is the durable history that survives restarts."
        ) {
            if jobs.isEmpty {
                Text("No actions in this app session yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(jobs.prefix(5)) { job in
                    JobSessionRow(job: job, tint: color(for: job.state)) {
                        selectedJob = job
                    }
                }
            }
        }
        .sheet(item: $selectedJob) { selectedJob in
            JobDetailSheet(job: jobs.first(where: { $0.id == selectedJob.id }) ?? selectedJob)
        }
        .onChange(of: jobs) { _, newJobs in
            guard let selectedJob,
                  let updatedJob = newJobs.first(where: { $0.id == selectedJob.id }) else {
                return
            }
            self.selectedJob = updatedJob
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

private struct JobSessionRow: View {
    var job: JobSnapshot
    var tint: Color
    var openDetails: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(tint)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.action.displayName)
                    .font(.headline)
                Text(job.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let currentPath = job.currentPath, !currentPath.isEmpty {
                    Text(currentPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if job.bytesPerSecond > 0 {
                Text("\(Int64(job.bytesPerSecond).formattedBytes)/s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 86, alignment: .trailing)
            }

            ProgressView(value: job.progress)
                .frame(width: 180)

            Text("\(Int(job.progress * 100))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            Button(action: openDetails) {
                Image(systemName: "info.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open job details")
            .accessibilityLabel("Open details for \(job.action.displayName)")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: openDetails)
    }
}

private struct JobDetailSheet: View {
    var job: JobSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.action.displayName)
                        .font(.title2.weight(.semibold))
                    Text(job.state.activityLabel)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(stateTint)
                }
                Spacer()
                Text("\(Int(job.progress * 100))%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
            }

            ProgressView(value: job.progress)

            HStack(spacing: 12) {
                MetricPill(title: "Files", value: filesText, symbol: "doc.on.doc", tint: AppTheme.accent)
                MetricPill(title: "Bytes", value: bytesText, symbol: "externaldrive", tint: AppTheme.mint)
                MetricPill(title: "Speed", value: speedText, symbol: "speedometer", tint: AppTheme.amber)
            }

            VStack(alignment: .leading, spacing: 10) {
                JobDetailLine(title: "Now", value: job.note)
                if !job.detail.isEmpty {
                    JobDetailLine(title: "Progress", value: job.detail)
                }
                if let sourcePath = job.sourcePath {
                    JobDetailLine(title: "From", value: sourcePath)
                }
                if let destinationPath = job.destinationPath {
                    JobDetailLine(title: "To", value: destinationPath)
                }
                if let currentPath = job.currentPath {
                    JobDetailLine(title: "Current File", value: currentPath)
                }
            }

            if !job.command.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Technical command")
                        .font(.headline)
                    Text(job.command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 680)
        .frame(minHeight: 420)
    }

    private var filesText: String {
        guard job.totalFiles > 0 else {
            return "\(job.processedFiles)"
        }
        return "\(job.processedFiles)/\(job.totalFiles)"
    }

    private var bytesText: String {
        guard job.totalBytes > 0 else {
            return job.processedBytes > 0 ? job.processedBytes.formattedBytes : "-"
        }
        return "\(job.processedBytes.formattedBytes) / \(job.totalBytes.formattedBytes)"
    }

    private var speedText: String {
        job.bytesPerSecond > 0 ? "\(Int64(job.bytesPerSecond).formattedBytes)/s" : "-"
    }

    private var stateTint: Color {
        switch job.state {
        case .queued: .secondary
        case .running: AppTheme.amber
        case .done: AppTheme.mint
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}

private struct JobDetailLine: View {
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }
}

extension JobState {
    var activityLabel: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .done: "Saved"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
