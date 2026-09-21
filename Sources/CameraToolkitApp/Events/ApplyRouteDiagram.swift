import AppKit
import CameraToolkitCore
import SwiftUI

/// How one source folder reaches an event folder in an apply plan.
enum ApplyRouteMethod: Equatable, Sendable {
    /// Same drive: an exclusive rename. Instant, never overwrites.
    case rename
    /// Cross drive: a checksum-verified copy that leaves the original.
    case verifiedCopy

    var label: String {
        switch self {
        case .rename: "Rename"
        case .verifiedCopy: "Verified copy"
        }
    }

    var detail: String {
        switch self {
        case .rename: "same drive — instant, nothing is overwritten"
        case .verifiedCopy: "checksum-verified — the originals stay put"
        }
    }

    var symbol: String {
        switch self {
        case .rename: "arrow.right"
        case .verifiedCopy: "checkmark.shield.fill"
        }
    }
}

/// One line of the apply diagram: "this folder → that place inside the
/// event". Moves are merged per source+destination folder pair; copies map
/// one-to-one onto the plan's copy batches.
struct ApplyRouteRow: Identifiable, Equatable, Sendable {
    var id: String
    var method: ApplyRouteMethod
    /// Absolute source folder (display only — the plan keeps the real paths).
    var sourcePath: String
    /// "A7V Card ▸ DCIM ▸ Transfer 1"
    var sourceLabel: String
    /// Where these files land, relative to the event folder — e.g.
    /// "Sony A7V ▸ Card Copy". Empty means the event folder itself.
    var destinationLabel: String
    var fileCount: Int
    var photoCount: Int
    var videoCount: Int
    var otherCount: Int
    var byteCount: Int64
    /// Sorted display names (moves) or source-relative paths (copies), for
    /// the "show file names" disclosure.
    var fileNames: [String]

    /// "36 files · 34 photos · 2 videos · 4 sidecars"
    var fileSummary: String {
        var parts = ["\(fileCount) file\(fileCount == 1 ? "" : "s")"]
        if photoCount > 0 { parts.append("\(photoCount) photo\(photoCount == 1 ? "" : "s")") }
        if videoCount > 0 { parts.append("\(videoCount) video\(videoCount == 1 ? "" : "s")") }
        if otherCount > 0 { parts.append("\(otherCount) sidecar/other") }
        return parts.joined(separator: " · ")
    }
}

enum ApplyRouteDiagram {
    /// The "where does each folder land" rows for one event group.
    static func routes(for group: OrganizeApplyPlan.EventGroup) -> [ApplyRouteRow] {
        var rows: [ApplyRouteRow] = []

        // Moves merge by (source folder, destination folder) so a burst of
        // 40 frames is one readable line instead of 40 rows.
        var merged: [String: ApplyRouteRow] = [:]
        for move in group.moves {
            let sourceFolder = (move.sourcePath as NSString).deletingLastPathComponent
            let destinationFolder = (move.destinationPath as NSString).deletingLastPathComponent
            let key = sourceFolder + "\u{0}" + destinationFolder
            let name = (move.sourcePath as NSString).lastPathComponent
            if var row = merged[key] {
                row.fileCount += 1
                row.byteCount += move.byteCount
                row.fileNames.append(name)
                count(kindOf(name), into: &row)
                merged[key] = row
            } else {
                var row = ApplyRouteRow(
                    id: "move|\(key)",
                    method: .rename,
                    sourcePath: sourceFolder,
                    sourceLabel: OrganizeRouteLabel.breadcrumb(for: sourceFolder),
                    destinationLabel: OrganizeRouteLabel.subpath(of: destinationFolder, under: group.destinationFolder),
                    fileCount: 0,
                    photoCount: 0,
                    videoCount: 0,
                    otherCount: 0,
                    byteCount: 0,
                    fileNames: []
                )
                row.fileCount = 1
                row.byteCount = move.byteCount
                row.fileNames = [name]
                count(kindOf(name), into: &row)
                merged[key] = row
            }
        }
        rows.append(contentsOf: merged.values)

        for (index, batch) in group.copies.enumerated() {
            var row = ApplyRouteRow(
                id: "copy|\(index)",
                method: .verifiedCopy,
                sourcePath: batch.sourceRoot,
                sourceLabel: OrganizeRouteLabel.breadcrumb(for: batch.sourceRoot),
                destinationLabel: OrganizeRouteLabel.subpath(of: batch.destinationRoot, under: group.destinationFolder),
                fileCount: batch.files.count,
                photoCount: 0,
                videoCount: 0,
                otherCount: 0,
                byteCount: batch.files.reduce(Int64(0)) { $0 + $1.size },
                fileNames: batch.files.map(\.path)
            )
            for file in batch.files {
                count(kindOf(file.path), into: &row)
            }
            rows.append(row)
        }

        for index in rows.indices {
            rows[index].fileNames.sort()
        }
        return rows.sorted { lhs, rhs in
            if lhs.method != rhs.method { return lhs.method == .rename }
            return lhs.sourceLabel.localizedStandardCompare(rhs.sourceLabel) == .orderedAscending
        }
    }

    /// Every route row across all groups, for the compact in-flight banner.
    static func routes(for plan: RunningApplyPlan) -> [ApplyRouteRow] {
        plan.groups.flatMap { group in
            routes(for: group).map { row in
                var row = row
                row.id = "\(group.id.uuidString)|\(row.id)"
                // The banner has no per-event header, so each row carries its
                // event folder in the destination label.
                row.destinationLabel = ([group.event.name] + (row.destinationLabel.isEmpty ? [] : [row.destinationLabel]))
                    .joined(separator: " ▸ ")
                return row
            }
        }
    }

    private static func kindOf(_ path: String) -> OrganizeMediaKind {
        OrganizeFileClassifier.kind(forExtension: (path as NSString).pathExtension)
    }

    private static func count(_ kind: OrganizeMediaKind, into row: inout ApplyRouteRow) {
        switch kind {
        case .raw, .photo: row.photoCount += 1
        case .video: row.videoCount += 1
        case .other: row.otherCount += 1
        }
    }
}

/// A method pill: "Rename" or "Verified copy", with the safety story on
/// hover and underneath.
private struct ApplyMethodBadge: View {
    let method: ApplyRouteMethod

    var body: some View {
        Label(method.label, systemImage: method.symbol)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(method == .verifiedCopy ? Color.blue.opacity(0.14) : Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(method == .verifiedCopy ? Color.blue : Color.secondary)
            .help(method.detail)
    }
}

/// One "source folder → place inside the event" row.
struct ApplyRouteRowView: View {
    let route: ApplyRouteRow
    /// Compact drops the per-file disclosure for the in-flight banner.
    var compact = false

    @State private var showFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(route.sourceLabel)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(route.sourcePath)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(route.destinationLabel.isEmpty ? "Event folder" : route.destinationLabel)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                ApplyMethodBadge(method: route.method)
            }
            HStack(spacing: 6) {
                Text(route.fileSummary)
                Text("·")
                Text(route.byteCount.formattedBytes)
                if route.videoCount > 0 {
                    Label("\(route.videoCount)", systemImage: "video.fill")
                        .foregroundStyle(.blue)
                }
                if !compact, !route.fileNames.isEmpty {
                    Spacer(minLength: 4)
                    Button {
                        showFiles.toggle()
                    } label: {
                        Label(showFiles ? "Hide names" : "File names", systemImage: showFiles ? "chevron.down" : "chevron.right")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 22)

            if showFiles, !compact {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(route.fileNames.prefix(200), id: \.self) { name in
                        HStack(spacing: 5) {
                            Image(systemName: fileSymbol(for: name))
                                .frame(width: 12)
                                .foregroundStyle(.secondary)
                            Text(name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if route.fileNames.count > 200 {
                        Text("… and \(route.fileNames.count - 200) more")
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
                .padding(.top, 2)
                .textSelection(.enabled)
            }
        }
    }

    private func fileSymbol(for name: String) -> String {
        switch OrganizeFileClassifier.kind(forExtension: (name as NSString).pathExtension) {
        case .video: "video.fill"
        case .raw, .photo: "photo"
        case .other: "doc"
        }
    }
}

/// One card per event in the apply sheet: the destination folder up top,
/// then one route row per source folder.
struct ApplyEventGroupCard: View {
    let group: OrganizeApplyPlan.EventGroup

    var body: some View {
        let routes = ApplyRouteDiagram.routes(for: group)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                EventChip(event: group.event, isPrivate: group.isPrivate)
                Text(group.event.eventDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text("\(fileCount) file\(fileCount == 1 ? "" : "s") · \(group.byteCount.formattedBytes)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Label {
                Text(OrganizeRouteLabel.breadcrumb(for: group.destinationFolder))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: group.isPrivate ? "lock.fill" : "folder.fill")
            }
            .foregroundStyle(.secondary)
            .help("The event folder these files land in: \(group.destinationFolder)")

            if !routes.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(routes) { route in
                        ApplyRouteRowView(route: route)
                    }
                }
            }

            let footnotes = [
                group.alreadyThere == 0 ? nil : "\(group.alreadyThere) already in place",
                group.unavailable == 0 ? nil : "\(group.unavailable) on a disconnected drive"
            ].compactMap { $0 }
            if !footnotes.isEmpty {
                Text(footnotes.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var fileCount: Int {
        group.moves.count + group.copyFileCount + group.alreadyThere + group.unavailable
    }
}

/// The compact diagram boards show while an apply's rename job runs:
/// "Transfer 1 → Beach Day ▸ Sony A7V ▸ Card Copy", one line per source
/// folder, capped so the status strip stays thin.
struct ApplyProgressBanner: View {
    let running: RunningApplyPlan

    var body: some View {
        let routes = ApplyRouteDiagram.routes(for: running)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Applying — \(running.title)")
                    .font(.caption.weight(.semibold))
                Text("nothing is overwritten")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(routes.prefix(5)) { route in
                HStack(spacing: 6) {
                    Image(systemName: route.method.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(route.sourceLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    Text(route.destinationLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
            }
            if routes.count > 5 {
                Text("… and \(routes.count - 5) more folder\(routes.count - 5 == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
    }
}
