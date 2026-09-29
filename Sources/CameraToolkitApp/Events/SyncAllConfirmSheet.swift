import CameraToolkitCore
import SwiftUI

/// Sync All to NAS confirmation: every event with files not on the NAS
/// yet, with counts and sizes, most first. Reads the presence index live,
/// so Check Again updates it in place. Sync All runs the same Sync to NAS
/// job as an event's button — only missing files are copied, every copy is
/// hash-verified, and nothing on the NAS is overwritten.
struct SyncAllConfirmSheet: View {
    let workspace: EventsWorkspace
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let presence = workspace.nasPresence
        let report = presence.report
        let rows = report.map { report in
            NASSyncAllRow.rows(
                report: report,
                events: workspace.model.configuration.savedEvents,
                title: workspace.eventTitle,
                isPrivate: { workspace.resolvedPolicy(for: $0) == .archiveOnly }
            )
        } ?? []
        let blocker = workspace.syncAllBlocker
        SheetScaffold(
            title: "Sync all events to the NAS?",
            subtitle: subtitle(report),
            systemImage: "arrow.up.to.line.circle.fill",
            iconTint: .green,
            height: rows.count > 6 ? 560 : nil
        ) {
            if report == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking what is not on the NAS…")
                        .foregroundStyle(.secondary)
                }
            } else if rows.isEmpty {
                Text("Every event file on the drive is already on the NAS. Sync All still verifies any copy no sync has checked yet.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(rows) { row in
                            rowView(row)
                        }
                    }
                    .padding(10)
                }
                .frame(minHeight: 60, maxHeight: rows.count > 6 ? .infinity : CGFloat(rows.count) * 26 + 20)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            if let report, report.total.differentFiles > 0 {
                Label(
                    "\(NASPendingText.files(report.total.differentFiles)) already on the NAS with different contents stay untouched and are listed in the job's report.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .symbolRenderingMode(.multicolor)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("Copies only files missing on the NAS, each to the same path it has on the drive, and checks every copy's SHA-256 before naming it. Nothing on the NAS is overwritten.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            reconcileSection
            if let note = presence.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let blocker {
                Text(blocker)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Check Again") { presence.refresh(.manual) }
                .disabled(presence.isChecking || !workspace.nasIsConnected)
                .help("List the NAS again now")
            Button("Verify NAS Copies") {
                onCancel()
                workspace.verifyNASCopies()
            }
            .disabled(blocker != nil)
            .help("Re-hash every NAS copy Sync to NAS verified and compare it with the recorded SHA-256. Nothing is deleted or replaced.")
            Button("Sync All", action: onConfirm)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(blocker != nil)
        }
    }

    /// "Reconcile NAS after moves": what the sync renames on the NAS
    /// instead of copying, and the stale duplicates it sets aside. Counts
    /// come from Sync to NAS's records and the drive, not from the NAS.
    @ViewBuilder
    private var reconcileSection: some View {
        @Bindable var workspace = workspace
        let preview = workspace.reconcilePreview
        let driveMounted = workspace.syncAllDriveMounted
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Reconcile NAS after moves", isOn: driveMounted ? $workspace.syncAllReconcile : .constant(false))
                .disabled(!driveMounted)
            if !driveMounted {
                Text("The Buffer isn't connected, so nothing can be proven stale and nothing is set aside. NAS copies that a move left behind are still renamed to where the catalog looks for them.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(reconcileDetail(preview))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reconcileDetail(_ preview: NASReconcilePreview?) -> String {
        var lines: [String] = []
        if let preview {
            if preview.renames > 0 {
                lines.append("\(NASPendingText.files(preview.renames)) (\(preview.renameBytes.formattedBytes)) will be renamed on the NAS from the old path instead of copied.")
            }
            if preview.staleDuplicates > 0 {
                lines.append("\(NASPendingText.files(preview.staleDuplicates)) (\(preview.staleBytes.formattedBytes)) stale duplicate\(preview.staleDuplicates == 1 ? "" : "s") of files already at their right path will be set aside in .Camera Toolkit/_Stale Copies on the NAS — never deleted.")
            }
            if preview.renames == 0, preview.staleDuplicates == 0 {
                lines.append("Nothing found: no NAS copy waits at an old path and no stale duplicate is on the NAS.")
            }
            if preview.queuedRenames > 0 {
                lines.append("\(preview.queuedRenames.formatted()) rename\(preview.queuedRenames == 1 ? "" : "s") queued by earlier moves are applied first, whatever this is set to.")
            }
        } else {
            lines.append("Looking for NAS copies left at old paths by earlier moves…")
        }
        return lines.joined(separator: " ")
    }

    private func subtitle(_ report: NASPresenceReport?) -> String {
        guard let report else { return "Looking at the drive and the NAS" }
        let pending = report.total.pendingFiles
        let head = pending > 0
            ? "\(NASPendingText.files(pending)) · \(report.total.pendingBytes.formattedBytes) not on the NAS yet"
            : "Nothing left to copy"
        return head + " · " + NASPendingText.freshness(report, now: Date())
    }

    private func rowView(_ row: NASSyncAllRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.isPrivate ? "lock.fill" : "circle.fill")
                .imageScale(row.isPrivate ? .medium : .small)
                .foregroundStyle(EventPalette.color(for: row.id))
            Text(row.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if row.differentFiles > 0 {
                Text("\(row.differentFiles) differ")
                    .foregroundStyle(.orange)
            }
            if row.pendingFiles > 0 {
                Text("\(NASPendingText.files(row.pendingFiles)) · \(row.pendingBytes.formattedBytes)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout.monospacedDigit())
    }
}
