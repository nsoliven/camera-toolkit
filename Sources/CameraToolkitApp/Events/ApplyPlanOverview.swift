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

    /// A breadcrumb split into a lead ("Crucial ▸ … ▸ ") and the final
    /// folder ("2026-08-23 Beach Day"), so a view can squeeze the lead and
    /// keep the final folder readable — truncating it only at its tail.
    struct ShortPath: Equatable, Sendable {
        /// Drive and elided middle, ending in " ▸ ". Empty for a one-part path.
        var lead: String
        /// The final folder name.
        var leaf: String

        var text: String { lead + leaf }

        /// Leads to try, longest first, when the full text does not fit:
        /// this lead, then drive + "…", then just "…". The final folder is
        /// never what shrinks first.
        var fallbackLeads: [String] {
            guard !lead.isEmpty else { return [""] }
            let separator = " ▸ "
            var leads = [lead]
            let parts = lead.components(separatedBy: separator).filter { !$0.isEmpty }
            if parts.count > 2 || (parts.count == 2 && parts[1] != "…") {
                leads.append(parts[0] + separator + "…" + separator)
            }
            let minimal = "…" + separator
            if leads.last != minimal { leads.append(minimal) }
            return leads
        }
    }

    /// A readable breadcrumb that keeps the drive and the final folder:
    /// "Crucial ▸ … ▸ 2026-08-23 Beach Day". Paths short enough to read
    /// whole are left whole.
    static func short(_ path: String, maxComponents: Int = 3) -> String {
        shortParts(path, maxComponents: maxComponents).text
    }

    /// `short(_:)` as lead + final folder. The middle of the path is what
    /// gets elided, never the final folder.
    static func shortParts(_ path: String, maxComponents: Int = 3) -> ShortPath {
        let breadcrumb = OrganizeRouteLabel.breadcrumb(for: path)
        let separator = " ▸ "
        var parts = breadcrumb.components(separatedBy: separator)
        guard let leaf = parts.popLast(), !parts.isEmpty else {
            return ShortPath(lead: "", leaf: breadcrumb)
        }
        if parts.count + 1 > max(maxComponents, 2) {
            parts = [parts[0], "…"]
        }
        return ShortPath(lead: parts.joined(separator: separator) + separator, leaf: leaf)
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
        /// How many event folders this folder's files are split across.
        var eventCount: Int

        var fileCount: Int { moveCount + copyCount }

        /// "“Transfer 1” → 2 events" when the folder feeds more than one
        /// event, so the picture never reads as one folder → one event.
        var splitHint: String? {
            eventCount > 1 ? "“\(name)” → \(eventCount) events" : nil
        }

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
        /// "Crucial ▸ … ▸ " + "2026-08-23 Beach Day".
        var shortPathParts: ApplyPathLabel.ShortPath
        var driveName: String
        var moveCount: Int
        var copyCount: Int
        /// Every source folder that feeds this event, with its share.
        var routes: [Route]

        var shortPath: String { shortPathParts.text }

        /// The routes shown as rows, plus one summed row for the rest, so
        /// a long list stays short and the rows still add up to this card.
        func routeDisplay(limit: Int) -> (visible: [Route], overflow: RouteOverflow?) {
            guard routes.count > limit, limit > 0 else { return (routes, nil) }
            let visible = Array(routes.prefix(limit - 1))
            let rest = routes.dropFirst(limit - 1)
            return (visible, RouteOverflow(
                folderCount: rest.count,
                moveCount: rest.reduce(0) { $0 + $1.moveCount },
                copyCount: rest.reduce(0) { $0 + $1.copyCount },
                byteCount: rest.reduce(Int64(0)) { $0 + $1.byteCount }
            ))
        }

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

    /// One real route: the files one source folder sends to one event.
    /// A folder that feeds two events has two routes; an event fed by two
    /// folders has two routes. Summing routes by source gives the source
    /// totals, and summing them by event gives the event totals, exactly.
    struct Route: Identifiable, Equatable, Sendable {
        var id: String { "\(destinationIndex)|\(sourcePath)" }
        /// Index of the event group in the plan (and in `destinations`).
        var destinationIndex: Int
        var sourcePath: String
        var sourceName: String
        var sourceDriveName: String
        var moveCount: Int
        var copyCount: Int
        var photoCount: Int
        var videoCount: Int
        var otherCount: Int
        var byteCount: Int64
        /// The whole source folder's totals across every event.
        var sourceFileCount: Int
        var sourceEventCount: Int

        var fileCount: Int { moveCount + copyCount }

        var methods: [ApplyRouteMethod] {
            (moveCount > 0 ? [.rename] : []) + (copyCount > 0 ? [.verifiedCopy] : [])
        }

        /// "1 file · 2.08 GB", or "1 of 5 files · 2.08 GB" when the folder is
        /// split across events, so the share is never mistaken for the whole.
        var countsLine: String {
            let files = sourceEventCount > 1 && sourceFileCount != fileCount
                ? "\(fileCount.formatted()) of \(ApplyPlanOverview.plural(sourceFileCount, "file"))"
                : ApplyPlanOverview.plural(fileCount, "file")
            return "\(files) · \(byteCount.formattedBytes)"
        }

        /// "“A” → 2 events" when this route's folder is split.
        var splitHint: String? {
            sourceEventCount > 1 ? "“\(sourceName)” → \(sourceEventCount) events" : nil
        }
    }

    /// The folders past a section's row limit, summed into one row.
    struct RouteOverflow: Equatable, Sendable {
        var folderCount: Int
        var moveCount: Int
        var copyCount: Int
        var byteCount: Int64

        var fileCount: Int { moveCount + copyCount }

        var methods: [ApplyRouteMethod] {
            (moveCount > 0 ? [.rename] : []) + (copyCount > 0 ? [.verifiedCopy] : [])
        }

        /// "+ 3 more folders · 12 files · 1.2 GB"
        var line: String {
            "+ \(ApplyPlanOverview.plural(folderCount, "more folder")) · \(ApplyPlanOverview.plural(fileCount, "file")) · \(byteCount.formattedBytes)"
        }
    }

    var sources: [Source]
    var destinations: [Destination]
    /// Every route, grouped by event in plan order, sources sorted by path.
    var routes: [Route]
    var moveCount: Int
    var copyCount: Int
    var byteCount: Int64
    /// Events that receive at least one file (groups holding only
    /// disconnected files still get a card, but are not counted).
    var eventCount: Int
    var destinationDrives: [String]
    /// Per event, the files whose name is already taken there — identical
    /// copies and different files. Never counted in `moveCount`.
    var collisions: [ApplyCollisionSummary]

    var duplicateCount: Int { collisions.reduce(0) { $0 + $1.duplicateCount } }
    var conflictCount: Int { collisions.reduce(0) { $0 + $1.conflictCount } }

    init(plan: OrganizeApplyPlan) {
        let routes = Self.routes(for: plan)
        self.routes = routes
        sources = Self.sources(from: routes)

        let summaries = ApplyRouteDiagram.eventSummaries(for: plan)
        destinations = zip(plan.groups, summaries).enumerated().map { index, pair in
            let (group, summary) = pair
            return Destination(
                summary: summary,
                folderPath: group.destinationFolder,
                shortPathParts: ApplyPathLabel.shortParts(group.destinationFolder),
                driveName: ApplyPathLabel.driveName(for: group.destinationFolder),
                moveCount: group.moves.count,
                copyCount: group.copyFileCount,
                routes: routes.filter { $0.destinationIndex == index }
            )
        }

        moveCount = plan.moveCount
        copyCount = plan.copyCount
        byteCount = plan.byteCount
        eventCount = plan.groups.count { !$0.moves.isEmpty || !$0.copies.isEmpty }
        var drives: [String] = []
        for destination in destinations where destination.moveCount + destination.copyCount > 0 {
            if !drives.contains(destination.driveName) { drives.append(destination.driveName) }
        }
        destinationDrives = drives
        collisions = ApplyStatusWording.summaries(for: plan)
    }

    // MARK: - Routes (pure, unit-tested)

    /// The many-to-many source folder → event mapping, built from the same
    /// per-folder rows as the Details cards ("Where each folder lands"),
    /// merged per (event, source folder). String work only — no disk.
    static func routes(for plan: OrganizeApplyPlan) -> [Route] {
        var routes: [Route] = []
        for (index, group) in plan.groups.enumerated() {
            var bySource: [String: Route] = [:]
            for row in ApplyRouteDiagram.routes(for: group) {
                var route = bySource[row.sourcePath] ?? Route(
                    destinationIndex: index,
                    sourcePath: row.sourcePath,
                    sourceName: (row.sourcePath as NSString).lastPathComponent,
                    sourceDriveName: ApplyPathLabel.driveName(for: row.sourcePath),
                    moveCount: 0,
                    copyCount: 0,
                    photoCount: 0,
                    videoCount: 0,
                    otherCount: 0,
                    byteCount: 0,
                    sourceFileCount: 0,
                    sourceEventCount: 0
                )
                switch row.method {
                case .rename: route.moveCount += row.fileCount
                case .verifiedCopy: route.copyCount += row.fileCount
                }
                route.photoCount += row.photoCount
                route.videoCount += row.videoCount
                route.otherCount += row.otherCount
                route.byteCount += row.byteCount
                bySource[row.sourcePath] = route
            }
            routes += bySource.values.sorted {
                $0.sourcePath.localizedStandardCompare($1.sourcePath) == .orderedAscending
            }
        }

        var totals: [String: (files: Int, events: Int)] = [:]
        for route in routes where route.fileCount > 0 {
            let total = totals[route.sourcePath] ?? (0, 0)
            totals[route.sourcePath] = (total.files + route.fileCount, total.events + 1)
        }
        for index in routes.indices {
            let total = totals[routes[index].sourcePath] ?? (0, 0)
            routes[index].sourceFileCount = total.files
            routes[index].sourceEventCount = total.events
        }
        return routes
    }

    /// Source folder totals: the sum of each folder's routes.
    static func sources(from routes: [Route]) -> [Source] {
        var byPath: [String: Source] = [:]
        for route in routes {
            var source = byPath[route.sourcePath] ?? Source(
                path: route.sourcePath,
                name: route.sourceName,
                driveName: route.sourceDriveName,
                moveCount: 0,
                copyCount: 0,
                byteCount: 0,
                eventCount: 0
            )
            source.moveCount += route.moveCount
            source.copyCount += route.copyCount
            source.byteCount += route.byteCount
            if route.fileCount > 0 { source.eventCount += 1 }
            byPath[route.sourcePath] = source
        }
        return byPath.values.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    var fileCount: Int { moveCount + copyCount }

    var sentence: String {
        if fileCount == 0, !collisions.isEmpty {
            // Nothing is renamed or copied — say what is blocking instead
            // of implying Apply will do something.
            let lines = collisions.flatMap { [$0.duplicateLine, $0.conflictLine].compactMap { $0 } }
            return "Nothing can move yet. " + lines.joined(separator: ". ") + "."
        }
        return Self.sentence(
            moveCount: moveCount,
            copyCount: copyCount,
            sourceNames: sources.map(\.name),
            eventCount: eventCount,
            destinationDrives: destinationDrives
        )
    }

    var primaryActionTitle: String {
        if fileCount == 0, !collisions.isEmpty { return "Nothing to Move" }
        return Self.primaryActionTitle(moveCount: moveCount, copyCount: copyCount)
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
        sourceNames: [String],
        eventCount: Int,
        destinationDrives: [String]
    ) -> String {
        guard moveCount + copyCount > 0 else {
            return "Nothing needs to move. Every file is already in place or on a disconnected drive."
        }
        let from = fromPhrase(sourceNames: sourceNames)
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

    /// Where the files come from: every folder by name when there are few
    /// ("from “A” and “B”"), otherwise a count ("from 5 folders"). Folders
    /// that share a name are counted rather than listed, which would read
    /// as the same folder twice.
    static func fromPhrase(sourceNames: [String], maxNamed: Int = 3) -> String {
        guard !sourceNames.isEmpty else { return "" }
        let unique = Set(sourceNames).count == sourceNames.count
        guard unique, sourceNames.count <= maxNamed else {
            return " from \(sourceNames.count.formatted()) folders"
        }
        let quoted = sourceNames.map { "“\($0)”" }
        let list = quoted.count == 1
            ? quoted[0]
            : quoted.dropLast().joined(separator: ", ") + " and " + quoted[quoted.count - 1]
        return " from \(list)"
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
