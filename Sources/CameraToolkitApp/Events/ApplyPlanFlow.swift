import CameraToolkitCore
import SwiftUI

/// The apply sheet's before → after picture, drawn as the plan's real
/// routes: one lane per event, with every source folder that feeds it on
/// the left (each with its share of files and its own Move or Copy +
/// verify arrow) and the event card on the right. A folder split across
/// events appears in each lane with its partial count and a "→ 2 events"
/// hint, so rows never read as one folder → one event. Everything comes
/// from `ApplyPlanOverview`, so nothing here touches the filesystem.
struct ApplyPlanFlowView: View {
    let overview: ApplyPlanOverview

    /// Routes past this per lane collapse into one summed row; the full
    /// list stays in Details.
    private static let visibleRoutesPerEvent = 5
    private static let sourceWidth: CGFloat = 196
    private static let arrowWidth: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                columnHeader("From")
                    .frame(width: Self.sourceWidth, alignment: .leading)
                Color.clear.frame(width: Self.arrowWidth, height: 1)
                columnHeader("To")
            }
            .padding(.horizontal, 8)
            ForEach(overview.destinations) { destination in
                lane(for: destination)
            }
        }
    }

    private func lane(for destination: ApplyPlanOverview.Destination) -> some View {
        let display = destination.routeDisplay(limit: Self.visibleRoutesPerEvent)
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if display.visible.isEmpty, display.overflow == nil {
                    HStack(spacing: 8) {
                        Text("No files to move")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: Self.sourceWidth, alignment: .leading)
                        ApplyOperationArrow(methods: [])
                            .frame(width: Self.arrowWidth)
                    }
                }
                ForEach(display.visible) { route in
                    HStack(alignment: .center, spacing: 8) {
                        ApplyRouteSourceCard(route: route)
                            .frame(width: Self.sourceWidth)
                        ApplyOperationArrow(methods: route.methods)
                            .frame(width: Self.arrowWidth)
                    }
                }
                if let overflow = display.overflow {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(overflow.line)
                                .font(.caption.monospacedDigit())
                            Text("Listed in Details")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .applyFlowCard()
                        .frame(width: Self.sourceWidth)
                        ApplyOperationArrow(methods: overflow.methods)
                            .frame(width: Self.arrowWidth)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            ApplyDestinationCard(destination: destination)
        }
        // Equal-height columns: the destination card grows to the height of
        // its routes instead of floating in the middle of them.
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.8), lineWidth: 0.5)
        )
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
    var fillHeight = false

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            )
    }
}

private extension View {
    func applyFlowCard(fillHeight: Bool = false) -> some View { modifier(ApplyFlowCard(fillHeight: fillHeight)) }
}

/// One route's source: the folder, its drive, and the share of its files
/// that go to this lane's event. A folder split across events says so.
struct ApplyRouteSourceCard: View {
    let route: ApplyPlanOverview.Route

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(route.sourceDriveName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: route.sourceDriveName == "this Mac" ? "internaldrive.fill" : "externaldrive.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Label {
                Text(route.sourceName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
            }

            Text(route.countsLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let splitHint = route.splitHint {
                Label(splitHint, systemImage: "arrow.triangle.branch")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("This folder's files are split across \(route.sourceEventCount) events. Each event shows its share.")
            }
        }
        .applyFlowCard()
        .help(route.sourcePath)
        .accessibilityElement(children: .combine)
    }
}

/// A short path that gives the final folder the room: the lead shortens
/// first (full lead, then drive ▸ …, then …), and only then does the final
/// folder truncate, at its tail. The full path belongs in `.help`.
struct ApplyShortPathText: View {
    let parts: ApplyPathLabel.ShortPath

    var body: some View {
        let leads = parts.fallbackLeads
        ViewThatFits(in: .horizontal) {
            ForEach(Array(leads.enumerated()), id: \.offset) { _, lead in
                Text(lead + parts.leaf)
                    .lineLimit(1)
                    .fixedSize()
            }
            // Nothing fits whole: keep the shortest lead and cut the final
            // folder at its end.
            HStack(spacing: 0) {
                Text(leads.last ?? "")
                    .fixedSize()
                Text(parts.leaf)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.text)
    }
}

/// The labelled arrow on one route. A route that both moves and copies
/// (rare) shows both labels, moves first.
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
                ApplyShortPathText(parts: destination.shortPathParts)
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
        // Spans the lane, so every route's arrow lands on the card.
        .applyFlowCard(fillHeight: true)
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
