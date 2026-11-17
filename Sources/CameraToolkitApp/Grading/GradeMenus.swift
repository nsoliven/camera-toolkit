import CameraToolkitCore
import SwiftUI

/// What the blanket sheet applies to.
struct BlanketGradeRequest: Identifiable {
    let id = UUID()
    /// "3 selected clips", "Beach Day", "Card".
    let scopeTitle: String
    let items: [OrganizeItem]
    /// The board's event, for rendering clips not assigned to one.
    var boardEventID: UUID?
}

/// The board menus' Color submenu: blanket apply, copy/paste, profile
/// marks, render. Shown only when the menu's stacks hold a gradable clip.
struct GradeMenuItems: View {
    let workspace: EventsWorkspace
    /// The stacks the menu acts on (the selection, or the clicked stack).
    let targets: [OrganizeStack]
    /// Every stack on the board, for "All Log Clips in …".
    let boardStacks: () -> [OrganizeStack]
    let boardTitle: String
    let boardEventID: UUID?
    let onBlanket: (BlanketGradeRequest) -> Void

    var body: some View {
        let grading = workspace.grading
        let items = targets.flatMap(\.items).filter(ClipGrading.isGradable)
        Menu("Color") {
            Button("Apply Look to Log Clips…") {
                onBlanket(BlanketGradeRequest(
                    scopeTitle: items.count == 1 ? items[0].primary.name : "\(items.count) selected clips",
                    items: items,
                    boardEventID: boardEventID
                ))
            }
            .disabled(items.isEmpty)
            Button("Apply Look to All Log Clips in \(boardTitle)…") {
                onBlanket(BlanketGradeRequest(
                    scopeTitle: boardTitle,
                    items: boardStacks().flatMap(\.items).filter(ClipGrading.isGradable),
                    boardEventID: boardEventID
                ))
            }
            Divider()
            Button("Copy Grade") {
                if let first = items.first { grading.copyGrade(from: first) }
            }
            .disabled(items.count != 1)
            Button("Paste Grade") { grading.pasteGrade(to: items) }
                .disabled(grading.clipboard == nil || items.isEmpty)
            Button("Remove Grade") { grading.removeGrade(from: items) }
                .disabled(items.isEmpty)
            Menu("Footage Is") {
                Button("As the Camera Says") { grading.markProfile(.detected, for: items) }
                Divider()
                ForEach(LogProfile.allCases, id: \.self) { profile in
                    Button(profile.displayName) { grading.markProfile(.marked(profile), for: items) }
                }
                Button("Not Log") { grading.markProfile(.notLog, for: items) }
            }
            .disabled(items.isEmpty)
            .help("DJI files don't say when they are D-Log M — mark them here.")
            Divider()
            Button("Render Graded Copies") {
                grading.renderGradedCopies(of: targets, boardEventID: boardEventID)
            }
            .disabled(items.isEmpty)
            .help("Rec.709 HEVC copies into the event's Edited/\(GradedRenderNaming.folderName). Originals are only read.")
            StabilizeMenuItems(workspace: workspace, targets: targets, boardStacks: boardStacks, boardTitle: boardTitle, boardEventID: boardEventID)
        }
    }
}
