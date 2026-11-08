import CameraToolkitCore
import SwiftUI

/// What a tile says about the files sharing it — a RAW's JPEG twin, a clip's
/// proxy and previews. Display only; the files stay separate on disk and in
/// the catalog.
struct CombinedFilesMarker: Equatable {
    /// A companion at or above this size has its size shown on the marker.
    /// Above DJI's telemetry and preview side files at their usual sizes,
    /// and below the proxies that take real space.
    static let largeByteCount: Int64 = 10_000_000
    /// Longest file list a tooltip spells out; a burst summarizes the rest.
    static let listedFileLimit = 12

    /// `+SCR`, or `+3` when more than one kind of file is combined.
    var title: String
    /// Total of the large companions, formatted; nil when none is large.
    var largeSize: String?
    var helpText: String
    var accessibilityText: String

    init?(stack: OrganizeStack) {
        guard stack.items.contains(where: { !$0.companions.isEmpty }) else { return nil }
        let companions = stack.items.flatMap(\.companions)
        let labels = Set(companions.map(Self.label))
        title = labels.count == 1 ? "+\(labels.first ?? "")" : "+\(companions.count)"

        let largeBytes = companions.lazy.map(\.size).filter { $0 >= Self.largeByteCount }.reduce(0, +)
        largeSize = largeBytes > 0 ? largeBytes.formattedBytes : nil

        let files = stack.files
        var lines = ["\(files.count) files shown as one · \(stack.byteCount.formattedBytes)"]
        lines += files.prefix(Self.listedFileLimit).map { "\($0.name) — \($0.size.formattedBytes)" }
        if files.count > Self.listedFileLimit {
            lines.append("and \(files.count - Self.listedFileLimit) more")
        }
        helpText = lines.joined(separator: "\n")
        accessibilityText = "Combined with \(companions.count) side file\(companions.count == 1 ? "" : "s")"
    }

    private static func label(_ file: OrganizeFile) -> String {
        switch file.fileExtension {
        case "photo-edit": "EDIT"
        case "textclipping": "CLIP"
        default: file.fileExtension.uppercased()
        }
    }
}

/// The marker over a tile's photo, in the tile's badge chrome.
struct CombinedFilesPill: View {
    let marker: CombinedFilesMarker

    var body: some View {
        HStack(spacing: 4) {
            Text(marker.title)
            if let largeSize = marker.largeSize {
                Text(largeSize)
                    .foregroundStyle(.orange)
            }
        }
        .lineLimit(1)
        .monospacedDigit()
        .photoBadgeScrim()
        .layoutPriority(-1)
        .help(marker.helpText)
    }
}

/// The marker in a list row's caption line.
struct CombinedFilesRowLabel: View {
    let marker: CombinedFilesMarker

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(marker.title)
                if let largeSize = marker.largeSize {
                    Text(largeSize)
                        .foregroundStyle(.orange)
                }
            }
        } icon: {
            Image(systemName: "paperclip")
        }
        .lineLimit(1)
        .help(marker.helpText)
    }
}
