import CameraToolkitCore
import SwiftUI

/// The Apply sheet's taken-name box, as a decision: each file here next to
/// the file already in the event, a verdict, a recommendation in plain
/// words, and a choice that defaults to it. One conflict gets the large
/// side-by-side comparison; several get a compact list with per-row
/// choices and a bulk "Keep Both for all different photos".
///
/// Nothing here touches the disk from a view body: facts (size, capture
/// time, the free "(N)" name) load in `.task` off the main actor, and
/// thumbnails come from `TileImageLoader`, which decodes a RAW's embedded
/// preview on its own queue.
struct ApplyCollisionDecisionView: View {
    let items: [ApplyCollisionItem]
    @Binding var choices: [String: ApplyCollisionChoice]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if items.count == 1, let item = items.first {
                ApplyCollisionComparisonCard(item: item, choice: binding(for: item))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        ApplyCollisionRow(item: item, choice: binding(for: item))
                    }
                }
                .background(.background.opacity(0.6), in: .rect(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.quinary, in: .rect(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                Text(items.count == 1 ? "Needs a decision" : "\(items.count) files need a decision")
                    .font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            let different = items.filter { !$0.isIdentical }
            if items.count > 1, !different.isEmpty {
                Button("Keep Both for All Different \(different.allSatisfy(\.isPhoto) ? "Photos" : "Files")") {
                    choices = ApplyCollisionResolution.keepBothForAllDifferent(items, choices)
                }
                .controlSize(.small)
                .disabled(different.allSatisfy { ApplyCollisionResolution.choice(for: $0, in: choices) == .keepBoth })
            }
            if items.count > 1 {
                Button("Leave All Here") {
                    choices = ApplyCollisionResolution.leaveAll(items)
                }
                .controlSize(.small)
            }
        }
    }

    private func binding(for item: ApplyCollisionItem) -> Binding<ApplyCollisionChoice> {
        Binding(
            get: { ApplyCollisionResolution.choice(for: item, in: choices) },
            set: { choices[item.id] = $0 }
        )
    }
}

/// Both sides of one taken name, read off the main actor.
struct ApplyCollisionPairFacts: Equatable, Sendable {
    var source: ApplyCollisionFileFacts
    var existing: ApplyCollisionFileFacts
    /// The name Keep Both would use now, e.g. "DSC0001 (2).ARW".
    var keepBothName: String?

    static func load(for item: ApplyCollisionItem) async -> ApplyCollisionPairFacts {
        let collision = item.collision
        let companions = item.companions
        let isIdentical = item.isIdentical
        return await Task.detached(priority: .userInitiated) {
            ApplyCollisionPairFacts(
                source: ApplyCollisionCheck.facts(atPath: collision.move.sourcePath),
                existing: ApplyCollisionCheck.facts(atPath: collision.move.destinationPath),
                keepBothName: isIdentical ? nil : ApplyCollisionCheck.keepBothName(for: collision, companions: companions)
            )
        }.value
    }
}

/// The single-conflict layout: "This photo" and "Already in <event>" side
/// by side, the verdict between them, the recommendation, and the choice.
struct ApplyCollisionComparisonCard: View {
    let item: ApplyCollisionItem
    @Binding var choice: ApplyCollisionChoice
    @State private var facts: ApplyCollisionPairFacts?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ApplyCollisionSide(
                    title: item.isPhoto ? "This photo" : "This file",
                    path: item.sourcePath,
                    facts: facts?.source,
                    thumbnailHeight: 112
                )
                Image(systemName: item.isIdentical ? "equal.circle.fill" : "notequal.circle.fill")
                    .font(.title)
                    .foregroundStyle(item.isIdentical ? Color.green : Color.orange)
                    .padding(.top, 50)
                    .accessibilityHidden(true)
                ApplyCollisionSide(
                    title: "Already in \(item.eventName)",
                    path: item.existingPath,
                    facts: facts?.existing,
                    thumbnailHeight: 112
                )
            }
            Text(ApplyCollisionResolution.verdict(
                isIdentical: item.isIdentical,
                isPhoto: item.isPhoto,
                source: facts?.source,
                existing: facts?.existing
            ))
            .font(.callout.weight(.semibold))
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(ApplyCollisionResolution.recommendation(for: item, keepBothName: facts?.keepBothName))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                }
                .font(.callout)
                HStack(spacing: 10) {
                    Picker("Choice", selection: $choice) {
                        ForEach(item.choices, id: \.self) { option in
                            Text(option == item.recommendedChoice ? "\(option.title) (recommended)" : option.title)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Text(ApplyCollisionResolution.outcome(for: item, choice: choice, keepBothName: facts?.keepBothName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.6), in: .rect(cornerRadius: 8, style: .continuous))
        }
        .task(id: item.id) { facts = await ApplyCollisionPairFacts.load(for: item) }
    }
}

/// One side of the comparison: thumbnail, capture time, size and folder.
struct ApplyCollisionSide: View {
    let title: String
    let path: String
    let facts: ApplyCollisionFileFacts?
    var thumbnailHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            ApplyCollisionThumbnail(path: path, maxPixels: 512)
                .frame(maxWidth: .infinity)
                .frame(height: thumbnailHeight)
            Text((path as NSString).lastPathComponent)
                .font(.callout.monospaced().weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 2) {
                Label(Self.dateLine(facts), systemImage: "camera")
                Label(facts?.byteCount.map(\.formattedBytes) ?? "—", systemImage: "doc")
                Label(ApplyPathLabel.short((path as NSString).deletingLastPathComponent), systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help((path as NSString).deletingLastPathComponent)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: .rect(cornerRadius: 8, style: .continuous))
    }

    static func dateLine(_ facts: ApplyCollisionFileFacts?) -> String {
        guard let facts else { return "Reading…" }
        if let captured = facts.captureDate {
            return "Taken " + captured.formatted(date: .abbreviated, time: .shortened)
        }
        if let modified = facts.modifiedAt {
            return "File date " + modified.formatted(date: .abbreviated, time: .shortened)
        }
        return "Date unknown"
    }
}

/// A compact row for plans with several taken names.
struct ApplyCollisionRow: View {
    let item: ApplyCollisionItem
    @Binding var choice: ApplyCollisionChoice
    @State private var facts: ApplyCollisionPairFacts?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 4) {
                ApplyCollisionThumbnail(path: item.sourcePath, maxPixels: 384)
                    .frame(width: 56, height: 42)
                    .help("This \(item.isPhoto ? "photo" : "file")")
                Image(systemName: item.isIdentical ? "equal" : "notequal")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(item.isIdentical ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                ApplyCollisionThumbnail(path: item.existingPath, maxPixels: 384)
                    .frame(width: 56, height: 42)
                    .help("Already in \(item.eventName)")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.callout.monospaced().weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ApplyCollisionResolution.verdict(
                    isIdentical: item.isIdentical,
                    isPhoto: item.isPhoto,
                    source: facts?.source,
                    existing: facts?.existing
                ))
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                Text(ApplyCollisionResolution.outcome(for: item, choice: choice, keepBothName: facts?.keepBothName))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Picker("Choice for \(item.fileName)", selection: $choice) {
                ForEach(item.choices, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .task(id: item.id) { facts = await ApplyCollisionPairFacts.load(for: item) }
    }
}

/// A thumbnail from the shared tile loader (embedded RAW preview, decoded
/// off the main actor). A placeholder shows until it lands or if it fails.
struct ApplyCollisionThumbnail: View {
    let path: String
    var maxPixels: Int
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: path) {
            let url = URL(fileURLWithPath: path)
            if let cached = TileImageLoader.shared.cachedImage(for: url, maximumPixelSize: maxPixels) {
                image = cached
                return
            }
            image = await TileImageLoader.shared.image(for: url, maximumPixelSize: maxPixels, priority: .high)
            failed = image == nil
        }
    }
}
