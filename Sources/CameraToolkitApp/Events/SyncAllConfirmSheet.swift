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
            Button("Sync All", action: onConfirm)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(blocker != nil)
        }
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
