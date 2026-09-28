import AppKit
import CameraToolkitCore
import SwiftUI

/// The Duplicates pop-out window: every photo held by two events (or an
/// event and an unsorted folder) as byte-identical copies, side by side,
/// with Keep in A only / Keep in B only / Keep Both. Same-name files that
/// hold different pictures are listed separately, for information only.
@MainActor
final class DuplicatesWindowController: NSObject, NSWindowDelegate {
    static let shared = DuplicatesWindowController()

    private var window: NSWindow?

    /// `eventID` focuses the window on that event's largest pair.
    func show(model: DashboardModel, workspace: EventsWorkspace, focusingEvent eventID: UUID? = nil) {
        if let eventID {
            workspace.duplicateReview.focus(onEvent: eventID)
        }
        if let window {
            CameraToolkitWindowFactory.present(window)
            return
        }
        let window = CameraToolkitWindowFactory.make(
            .duplicates,
            identifier: "CameraToolkitDuplicatesWindow",
            title: "Duplicates",
            initialContentSize: NSSize(width: 1_080, height: 680),
            rootView: DuplicatesView(model: model, workspace: workspace, review: workspace.duplicateReview)
        )
        window.delegate = self
        self.window = window
        CameraToolkitWindowFactory.present(window)
    }
}

struct DuplicatesView: View {
    @Bindable var model: DashboardModel
    let workspace: EventsWorkspace
    @Bindable var review: DuplicateReviewModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()
                        statusBar
                    }
                    .background(.bar)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Duplicates")
        .navigationSubtitle("Identical copies are found by content, never by name")
        .toolbar { toolbar }
        .alert(
            review.pending.map { "Keep in \(review.title($0.keep)) only?" } ?? "",
            isPresented: Binding(get: { review.pending != nil }, set: { if !$0 { review.pending = nil } }),
            presenting: review.pending
        ) { request in
            Button(DuplicateReviewWording.confirmButton(request), role: .destructive) {
                review.confirm(request)
            }
            Button("Cancel", role: .cancel) { review.pending = nil }
        } message: { request in
            Text(DuplicateReviewWording.confirmation(
                request,
                keepName: review.title(request.keep),
                dropName: review.title(request.drop)
            ))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Toggle(isOn: $review.includeUnsorted) {
                Label("Include Unsorted Folders", systemImage: "tray.full")
            }
            .disabled(review.isScanning)
            .help("Also compare the unsorted folders already open in the sidebar against the events")
        }
        ToolbarItem {
            if review.isScanning {
                Button("Stop", systemImage: "stop.fill") { review.stopScan() }
                    .help("Stop comparing. Results so far are kept.")
            } else {
                Button(review.report == nil ? "Scan" : "Scan Again", systemImage: "doc.on.doc") { review.scan() }
                    .help("Compare every event's photos on this Mac's drives by size, then by SHA-256. Files already checked and unchanged are not read again. Nothing is moved.")
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $review.selection) {
            if review.report != nil, review.pairs.isEmpty, review.collisionPairs.isEmpty {
                Text("No photo is in two places.")
                    .foregroundStyle(.secondary)
            }
            if !review.pairs.isEmpty {
                Section("Identical Copies") {
                    ForEach(review.pairs) { summary in
                        pairRow(summary.pair, detail: DuplicateReviewWording.pairLine(summary))
                            .tag(DuplicateReviewSelection.identical(summary.pair))
                    }
                }
            }
            if !review.collisionPairs.isEmpty {
                Section {
                    ForEach(review.collisionPairs) { summary in
                        pairRow(summary.pair, detail: ApplyPlanOverview.plural(summary.collisions.count, "shared name"))
                            .tag(DuplicateReviewSelection.sameName(summary.pair))
                    }
                } header: {
                    Text("Same Name, Different Photo")
                } footer: {
                    Text("Not duplicates — cameras reuse file numbers. Shown so a taken name makes sense.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if review.reviewedCount > 0 {
                Section {
                    HStack {
                        Text("\(ApplyPlanOverview.plural(review.reviewedCount, "group")) kept both")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show Again") { review.resetReviewed() }
                            .buttonStyle(.borderless)
                            .help("Flag every Keep Both group for review again")
                    }
                    .font(.callout)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if review.report == nil {
                ContentUnavailableView {
                    Label("Find Duplicates", systemImage: "doc.on.doc")
                } description: {
                    Text("Compares every event’s photos by size, then byte for byte. Nothing moves until you choose.")
                } actions: {
                    Button(review.isScanning ? "Scanning…" : "Scan") { review.scan() }
                        .buttonStyle(.glassProminent)
                        .disabled(review.isScanning)
                }
            }
        }
    }

    private func pairRow(_ pair: DuplicateOwnerPair, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                ownerLabel(pair.first)
                Image(systemName: "arrow.left.arrow.right")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                ownerLabel(pair.second)
            }
            .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func ownerLabel(_ owner: DuplicateOwner) -> some View {
        HStack(spacing: 3) {
            Image(systemName: review.symbol(owner))
                .imageScale(.small)
                .foregroundStyle(owner.eventID.map { EventPalette.color(for: $0) } ?? .secondary)
            Text(review.title(owner))
                .truncationMode(.middle)
        }
        .help(review.isPrivate(owner) ? "\(review.title(owner)) — private event" : review.title(owner))
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch review.selection {
        case .identical(let pair)?:
            if let summary = review.summary(for: pair) {
                IdenticalPairDetail(model: model, review: review, summary: summary)
            } else {
                ContentUnavailableView("Nothing Left Here", systemImage: "checkmark.circle", description: Text("Every copy in this pair was resolved."))
            }
        case .sameName(let pair)?:
            SameNameDetail(review: review, pair: pair, collisions: review.collisions(for: pair))
        case nil:
            ContentUnavailableView(
                "Choose a Pair",
                systemImage: "rectangle.split.2x1",
                description: Text("Pick two places on the left to see their copies side by side.")
            )
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if review.isScanning {
                if let progress = review.progress, progress.totalBytes > 0 {
                    ProgressView(value: Double(progress.processedBytes), total: Double(progress.totalBytes))
                        .frame(width: 140)
                    Text("Comparing \(progress.processedFiles.formatted()) of \(ApplyPlanOverview.plural(progress.totalFiles, "file")) · \(progress.currentPath ?? "")")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finding files with matching sizes…")
                }
            } else {
                Text(review.message ?? "Nothing moves until you confirm. Removed copies go to the drive’s Trash and can be restored.")
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// Two places' identical copies, one row per photo, with the actions.
private struct IdenticalPairDetail: View {
    @Bindable var model: DashboardModel
    @Bindable var review: DuplicateReviewModel
    let summary: DuplicatePairSummary

    private var pair: DuplicateOwnerPair { summary.pair }

    /// The ticked groups, or every group when none is ticked.
    private var targets: [DuplicateGroup] {
        let checked = summary.groups.filter { review.checkedGroupIDs.contains($0.id) }
        return checked.isEmpty ? summary.groups : checked
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(summary.groups) { group in
                    row(group)
                }
            }
            .listStyle(.inset)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(DuplicateReviewWording.pairLine(summary))
                    .font(.headline)
                Spacer()
                let checked = review.checkedGroupIDs.intersection(Set(summary.groups.map(\.id))).count
                Text(checked == 0 ? "Acting on all \(summary.fileCount.formatted())" : "Acting on \(checked.formatted()) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(checked == summary.fileCount ? "Select None" : "Select All") {
                    let ids = Set(summary.groups.map(\.id))
                    if checked == summary.fileCount {
                        review.checkedGroupIDs.subtract(ids)
                    } else {
                        review.checkedGroupIDs.formUnion(ids)
                    }
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                keepButton(pair.first)
                keepButton(pair.second)
                Button("Keep Both") { review.keepBoth(targets) }
                    .buttonStyle(.glass)
                    .help("Leave both copies where they are and stop flagging these")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func keepButton(_ owner: DuplicateOwner) -> some View {
        Button("Keep in \(review.title(owner)) Only…") {
            review.requestKeep(owner, in: pair, groups: targets)
        }
        .buttonStyle(.glass)
        .lineLimit(1)
        .disabled(model.isBusy)
        .help("The other copies go to the drive’s Trash after you confirm — restorable from the Trash window")
    }

    private func row(_ group: DuplicateGroup) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { review.checkedGroupIDs.contains(group.id) },
                set: { on in
                    if on { review.checkedGroupIDs.insert(group.id) } else { review.checkedGroupIDs.remove(group.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .padding(.top, 24)
            DuplicateCopyCell(review: review, owner: pair.first, copies: group.copies(of: pair.first))
            Image(systemName: group.isOneFile ? "link" : "equal")
                .foregroundStyle(.secondary)
                .padding(.top, 24)
                .help(group.isOneFile ? "One file listed in both places" : "Byte-identical (SHA-256 \(group.sha256.prefix(12))…)")
            DuplicateCopyCell(review: review, owner: pair.second, copies: group.copies(of: pair.second))
            Menu {
                Button("Keep in \(review.title(pair.first)) Only…") { review.requestKeep(pair.first, in: pair, groups: [group]) }
                Button("Keep in \(review.title(pair.second)) Only…") { review.requestKeep(pair.second, in: pair, groups: [group]) }
                Divider()
                Button("Keep Both") { review.keepBoth([group]) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .disabled(model.isBusy)
            .padding(.top, 22)
        }
        .padding(.vertical, 4)
    }
}

/// One side of a row: the thumbnail from the board's decode pipeline, the
/// name, size, capture time, and the folder it sits in.
private struct DuplicateCopyCell: View {
    let review: DuplicateReviewModel
    let owner: DuplicateOwner
    let copies: [DuplicateCopy]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let copy = copies.first {
                TileThumbnail(
                    url: URL(filePath: copy.path),
                    kind: OrganizeFileClassifier.kind(forExtension: (copy.fileName as NSString).pathExtension),
                    pointSize: 96
                )
                .frame(width: 96, height: 64)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: review.symbol(owner))
                            .imageScale(.small)
                            .foregroundStyle(owner.eventID.map { EventPalette.color(for: $0) } ?? .secondary)
                        Text(review.title(owner))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    Text(copy.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle(copy))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(review.place(of: copy))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(copy.path)
                    if copies.count > 1 {
                        Text("+\(copies.count - 1) more here")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if let copy = copies.first {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: copy.path)])
                }
            }
        }
    }

    private func subtitle(_ copy: DuplicateCopy) -> String {
        let date = (copy.captureDate ?? copy.modifiedAt).formatted(date: .abbreviated, time: .shortened)
        return "\(copy.byteCount.formattedBytes) · \(copy.captureDate == nil ? "modified " : "")\(date)"
    }
}

/// Same-name files that hold different pictures. Informational: nothing to
/// resolve, because Move to Event keeps both under a new name.
private struct SameNameDetail: View {
    let review: DuplicateReviewModel
    let pair: DuplicateOwnerPair
    let collisions: [DuplicateNameCollision]

    var body: some View {
        VStack(spacing: 0) {
            Label {
                Text("These share a file name but hold different pictures — cameras reuse frame numbers. They are not duplicates. Moving one into the other place keeps both, under a new name like \(collisions.first.map { KeepBothNaming.suffixed($0.fileName, 2) } ?? "DSC00001 (2).ARW").")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            List {
                ForEach(collisions) { collision in
                    HStack(alignment: .top, spacing: 10) {
                        DuplicateCopyCell(review: review, owner: pair.first, copies: collision.copies.filter { $0.owner == pair.first })
                        Image(systemName: "notequal")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                        DuplicateCopyCell(review: review, owner: pair.second, copies: collision.copies.filter { $0.owner == pair.second })
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
        }
    }
}
