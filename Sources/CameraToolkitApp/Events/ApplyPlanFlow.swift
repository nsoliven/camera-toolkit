import CameraToolkitCore
import SwiftUI

/// The apply sheet's before → after picture: the source folders on the
/// left, one labelled arrow per destination (Move or Copy + verify), and
/// one card per event folder on the right. Everything comes from
/// `ApplyPlanOverview`, so nothing here touches the filesystem.
struct ApplyPlanFlowView: View {
    let overview: ApplyPlanOverview

    /// Sources past this collapse into a "+N more" line; the full list
    /// stays in Details.
    private static let visibleSources = 4
    private static let sourceWidth: CGFloat = 176
    private static let arrowWidth: CGFloat = 100

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                columnHeader("From")
                ForEach(overview.sources.prefix(Self.visibleSources)) { source in
                    ApplySourceCard(source: source)
                }
                if overview.sources.count > Self.visibleSources {
                    let more = overview.sources.count - Self.visibleSources
                    Text("+ \(more) more folder\(more == 1 ? "" : "s") · see Details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.sourceWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Color.clear.frame(width: Self.arrowWidth, height: 1)
                    columnHeader("To")
                }
                ForEach(overview.destinations) { destination in
                    HStack(alignment: .center, spacing: 8) {
                        ApplyOperationArrow(methods: destination.methods)
                            .frame(width: Self.arrowWidth)
                        ApplyDestinationCard(destination: destination)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The shared card look: a quiet rounded fill that reads in light and dark
/// without custom chrome.
private struct ApplyFlowCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            )
    }
}

private extension View {
    func applyFlowCard() -> some View { modifier(ApplyFlowCard()) }
}

/// One source folder: which drive, how many files, and whether they leave
/// this folder (moves) or stay put (copies).
struct ApplySourceCard: View {
    let source: ApplyPlanOverview.Source

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(source.driveName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: source.driveName == "this Mac" ? "internaldrive.fill" : "externaldrive.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Label {
                Text(source.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
            }

            Text("\(ApplyPlanOverview.plural(source.fileCount, "file")) · \(source.byteCount.formattedBytes)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(source.fateLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .applyFlowCard()
        .help(source.path)
        .accessibilityElement(children: .combine)
    }
}

/// The labelled arrow between a source and a destination. A destination
/// reached both ways shows both labels, moves first.
struct ApplyOperationArrow: View {
    let methods: [ApplyRouteMethod]

    var body: some View {
        VStack(spacing: 6) {
            if methods.isEmpty {
                Image(systemName: "arrow.forward")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("nothing to move")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(methods, id: \.label) { method in
                VStack(spacing: 1) {
                    Image(systemName: method == .rename ? "arrow.forward" : "doc.on.doc")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint(method))
                    Text(method.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint(method))
                    Text(method.shortDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help(method.detail)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func tint(_ method: ApplyRouteMethod) -> Color {
        method == .verifiedCopy ? .blue : .accentColor
    }
}

/// One event folder: the event capsule (with the lock for private events),
/// the final folder as a short path (full path on hover), and the counts.
struct ApplyDestinationCard: View {
    let destination: ApplyPlanOverview.Destination

    var body: some View {
        let summary = destination.summary
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                EventChip(event: summary.event, isPrivate: summary.isPrivate)
                Text(summary.event.eventDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Label {
                Text(destination.shortPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: summary.isPrivate ? "lock.fill" : "folder.fill")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .help(destination.folderPath)

            Text(destination.countsLine)
                .font(.callout.monospacedDigit())

            if summary.isPrivate {
                Text("Private · kept in a hidden folder until it is archived")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let footnote = summary.footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .applyFlowCard()
        .accessibilityElement(children: .combine)
    }
}

/// The two or three safety lines under the flow.
struct ApplySafetyFactsView: View {
    let facts: [ApplySafetyFact]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(facts) { fact in
                Label {
                    Text(fact.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: fact.symbol)
                        .foregroundStyle(.green)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
