import CameraToolkitCore
import Foundation

/// Path wording for the apply sheet, from path strings alone — no
/// filesystem calls, so it is safe to use while building a view.
enum ApplyPathLabel {
    /// The drive a path lives on: the volume name for `/Volumes/<name>/…`,
    /// otherwise "this Mac" (the startup disk).
    static func driveName(for path: String) -> String {
        let components = standardizedComponents(path)
        if components.count >= 2, components[0] == "Volumes" {
            return components[1]
        }
        return "this Mac"
    }

    /// A readable breadcrumb that keeps the drive and the final folder:
    /// "Crucial ▸ … ▸ 2026-08-23 Beach Day". Paths short enough to read
    /// whole are left whole.
    static func short(_ path: String, maxComponents: Int = 3) -> String {
        let breadcrumb = OrganizeRouteLabel.breadcrumb(for: path)
        let parts = breadcrumb.components(separatedBy: " ▸ ")
        guard parts.count > max(maxComponents, 2) else { return breadcrumb }
        return [parts[0], "…", parts[parts.count - 1]].joined(separator: " ▸ ")
    }

    /// The display name of the deepest folder shared by every path: its
    /// last component (the drive name when the paths share only a volume
    /// root). Nil when they share nothing more specific than `/` or
    /// `/Volumes`.
    static func commonFolderName(of paths: [String]) -> String? {
        let split = paths.map(standardizedComponents)
        guard var common = split.first else { return nil }
        for components in split.dropFirst() {
            var shared = 0
            while shared < common.count, shared < components.count, common[shared] == components[shared] {
                shared += 1
            }
            common = Array(common.prefix(shared))
        }
        if common.isEmpty || common == ["Volumes"] { return nil }
        return common.last
    }

    private static func standardizedComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            .split(separator: "/")
            .map(String.init)
    }
}

/// One safety line under the apply flow.
struct ApplySafetyFact: Identifiable, Equatable, Sendable {
    var id: String { symbol }
    var symbol: String
    var text: String
}

/// Everything the apply sheet's before → after flow shows, derived from the
/// plan alone. Purely presentational: it never changes what Apply does.
struct ApplyPlanOverview: Sendable {
    /// A folder files leave (moves) or are read from (copies).
    struct Source: Identifiable, Equatable, Sendable {
        var id: String { path }
        var path: String
        var name: String
        var driveName: String
        var moveCount: Int
        var copyCount: Int
        var byteCount: Int64

        var fileCount: Int { moveCount + copyCount }

        /// What happens to the files in this folder.
        var fateLine: String {
            switch (moveCount > 0, copyCount > 0) {
            case (true, true): "Some move out · some are copied"
            case (false, true): "Originals stay here"
            default: "Files move out of this folder"
            }
        }
    }

    /// One event folder files land in.
    struct Destination: Identifiable, Sendable {
        var id: UUID { summary.id }
        var summary: ApplyEventSummary
        var folderPath: String
        var shortPath: String
        var driveName: String
        var moveCount: Int
        var copyCount: Int

        /// The operations that reach this folder, moves first.
        var methods: [ApplyRouteMethod] {
            (moveCount > 0 ? [.rename] : []) + (copyCount > 0 ? [.verifiedCopy] : [])
        }

        /// "33 photos · 3 videos · 3 sidecars · 2.22 GB"
        var countsLine: String {
            ApplyPlanOverview.countsLine(
                photos: summary.imageCount,
                videos: summary.videoCount,
                sidecars: summary.otherCount,
                byteCount: summary.byteCount
            )
        }
    }

    var sources: [Source]
    var destinations: [Destination]
    var moveCount: Int
    var copyCount: Int
    var byteCount: Int64
    /// Events that receive at least one file (groups holding only
    /// disconnected files still get a card, but are not counted).
    var eventCount: Int
    var sourceName: String?
    var destinationDrives: [String]

    init(plan: OrganizeApplyPlan) {
        var sourcesByPath: [String: Source] = [:]
        for group in plan.groups {
            for route in ApplyRouteDiagram.routes(for: group) {
                var source = sourcesByPath[route.sourcePath] ?? Source(
                    path: route.sourcePath,
                    name: (route.sourcePath as NSString).lastPathComponent,
                    driveName: ApplyPathLabel.driveName(for: route.sourcePath),
                    moveCount: 0,
                    copyCount: 0,
                    byteCount: 0
                )
                switch route.method {
                case .rename: source.moveCount += route.fileCount
                case .verifiedCopy: source.copyCount += route.fileCount
                }
                source.byteCount += route.byteCount
                sourcesByPath[route.sourcePath] = source
            }
        }
        sources = sourcesByPath.values.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

        let summaries = ApplyRouteDiagram.eventSummaries(for: plan)
        destinations = zip(plan.groups, summaries).map { group, summary in
            Destination(
                summary: summary,
                folderPath: group.destinationFolder,
                shortPath: ApplyPathLabel.short(group.destinationFolder),
                driveName: ApplyPathLabel.driveName(for: group.destinationFolder),
                moveCount: group.moves.count,
                copyCount: group.copyFileCount
            )
        }

        moveCount = plan.moveCount
        copyCount = plan.copyCount
        byteCount = plan.byteCount
        eventCount = plan.groups.count { !$0.moves.isEmpty || !$0.copies.isEmpty }
        sourceName = ApplyPathLabel.commonFolderName(of: sources.map(\.path))
        var drives: [String] = []
        for destination in destinations where destination.moveCount + destination.copyCount > 0 {
            if !drives.contains(destination.driveName) { drives.append(destination.driveName) }
        }
        destinationDrives = drives
    }

    var fileCount: Int { moveCount + copyCount }

    var sentence: String {
        Self.sentence(
            moveCount: moveCount,
            copyCount: copyCount,
            sourceName: sourceName,
            sourceFolderCount: sources.count,
            eventCount: eventCount,
            destinationDrives: destinationDrives
        )
    }

    var primaryActionTitle: String {
        Self.primaryActionTitle(moveCount: moveCount, copyCount: copyCount)
    }

    var safetyFacts: [ApplySafetyFact] {
        Self.safetyFacts(moveCount: moveCount, copyCount: copyCount)
    }

    // MARK: - Wording (pure, unit-tested)

    /// The one plain-language sentence at the top of the sheet. Moves are
    /// same-drive renames by construction (`DriveMoveService` refuses
    /// anything else); copies are the cross-drive, checksum-verified
    /// transfers that leave the originals in place.
    static func sentence(
        moveCount: Int,
        copyCount: Int,
        sourceName: String?,
        sourceFolderCount: Int,
        eventCount: Int,
        destinationDrives: [String]
    ) -> String {
        guard moveCount + copyCount > 0 else {
            return "Nothing needs to move. Every file is already in place or on a disconnected drive."
        }
        let from: String
        if let sourceName {
            from = " from “\(sourceName)”"
        } else if sourceFolderCount > 1 {
            from = " from \(sourceFolderCount) folders"
        } else {
            from = ""
        }
        let into = " into \(plural(eventCount, "event"))"
        let on: String = switch destinationDrives.count {
        case 0: ""
        case 1: " on \(destinationDrives[0])"
        default: " on \(destinationDrives.count) drives"
        }

        switch (moveCount > 0, copyCount > 0) {
        case (true, false):
            return "\(plural(moveCount, "file")) \(moveCount == 1 ? "moves" : "move")\(from)\(into)\(on). "
                + "\(moveCount == 1 ? "It is" : "They are") renamed on the same drive, so no files are copied or deleted."
        case (false, true):
            return "\(plural(copyCount, "file")) \(copyCount == 1 ? "is" : "are") copied\(from)\(into)\(on) and checksum-verified. "
                + "The originals stay where they are."
        default:
            return "\(plural(moveCount, "file")) \(moveCount == 1 ? "moves" : "move") and \(copyCount.formatted()) \(copyCount == 1 ? "is" : "are") copied\(from)\(into)\(on). "
                + "Moves are instant renames on the same drive. Copies come from another drive, are checksum-verified, and leave the originals in place."
        }
    }

    /// The confirm button names the action: "Move 40 Files",
    /// "Copy 1 File", "Move & Copy 43 Files".
    static func primaryActionTitle(moveCount: Int, copyCount: Int) -> String {
        let total = moveCount + copyCount
        let files = "\(total.formatted()) \(total == 1 ? "File" : "Files")"
        switch (moveCount > 0, copyCount > 0) {
        case (true, true): return "Move & Copy \(files)"
        case (true, false): return "Move \(files)"
        case (false, true): return "Copy \(files)"
        case (false, false): return "Apply"
        }
    }

    /// Two or three short safety lines. Undo applies only to moves (the
    /// journal records renames); the checksum line appears only when the
    /// plan copies something.
    static func safetyFacts(moveCount: Int, copyCount: Int) -> [ApplySafetyFact] {
        var facts = [ApplySafetyFact(
            symbol: "checkmark.circle",
            text: "Nothing is overwritten. A file already at the destination is left alone."
        )]
        if moveCount > 0 {
            facts.append(ApplySafetyFact(
                symbol: "arrow.uturn.backward",
                text: "Undo moves the files back where they were."
            ))
        }
        if copyCount > 0 {
            facts.append(ApplySafetyFact(
                symbol: "checkmark.shield",
                text: "Copies are checksum-verified, and the originals stay on their drive."
            ))
        }
        return facts
    }

    /// "33 photos · 3 videos · 3 sidecars · 2.22 GB" — zero counts are left
    /// out; the size is always shown.
    static func countsLine(photos: Int, videos: Int, sidecars: Int, byteCount: Int64) -> String {
        var parts: [String] = []
        if photos > 0 { parts.append(plural(photos, "photo")) }
        if videos > 0 { parts.append(plural(videos, "video")) }
        if sidecars > 0 { parts.append(plural(sidecars, "sidecar")) }
        if parts.isEmpty { parts.append("No files to move") }
        parts.append(byteCount.formattedBytes)
        return parts.joined(separator: " · ")
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
    }
}
