import CameraToolkitCore
import Foundation

/// Read-time rules for side files sharing a tile. Nothing here writes: the
/// catalog keeps one row per file, and these only decide what is drawn and
/// what must clear together.
extension EventsWorkspace {
    /// Each catalog row's owner under every path it can be drawn at.
    func sideFileOwnership() -> SideFileOwnership {
        refreshIndexIfNeeded(tracking: false)
        return SideFileOwnership(owners: assignmentsByPathKey.mapValues {
            SideFileOwnership.Owner(eventID: $0.eventID, fileSize: $0.fileSize)
        })
    }

    /// The files a board draws for these rows, and whose each one is.
    nonisolated static func drawnFiles(
        for assignments: some Collection<PhotoEventAssignment>,
        path: (PhotoEventAssignment) -> String?
    ) -> (files: [OrganizeFile], ownership: SideFileOwnership) {
        var files: [OrganizeFile] = []
        files.reserveCapacity(assignments.count)
        var owners: [String: SideFileOwnership.Owner] = [:]
        owners.reserveCapacity(assignments.count)
        for assignment in assignments {
            guard let drawnAt = path(assignment) else { continue }
            let file = OrganizeFile(literalPath: drawnAt, size: assignment.fileSize, modifiedAt: assignment.modifiedAt)
            files.append(file)
            owners[file.pathKey] = SideFileOwnership.Owner(eventID: assignment.eventID, fileSize: assignment.fileSize)
        }
        return (files, SideFileOwnership(owners: owners))
    }

    /// What Clear from Card treats as one all-or-nothing unit, primary
    /// first. A side file drawn apart because its assignment differs still
    /// clears with its partner, so a card file can never go while the side
    /// file beside it is unsorted or unverified. Only boards that show such
    /// a tile pay for pairing again.
    nonisolated static func cardClearUnits(_ items: [OrganizeItem]) -> [[OrganizeFile]] {
        let drawnApart = items.contains { item in
            item.kind == .other || OrganizeFileClassifier.formerlyStandaloneExtensions.contains(item.primary.fileExtension)
        }
        guard drawnApart else { return items.map(\.files) }
        return OrganizeFileClassifier.pair(items.flatMap(\.files)).map { [$0.primary] + $0.companions }
    }

    /// A sort can leave one half of a combined tile behind (its copy already
    /// lives in another event). That tile was grouped before the sort, so
    /// the board scans again to draw the two apart.
    func rescanIfSideFilesParted(_ stacks: [OrganizeStack], in location: ConfiguredLocation) {
        let ownership = sideFileOwnership()
        let parted = stacks.contains { stack in
            stack.items.contains { item in
                item.companions.contains { ownership.keepsApart(primary: item.primary, sideFile: $0) }
            }
        }
        if parted { scan(location, force: true) }
    }
}
