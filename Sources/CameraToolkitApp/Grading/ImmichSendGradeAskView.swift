import CameraToolkitCore
import SwiftUI

/// Send to Immich's question when log clips would reach Immich flat: what
/// is wrong, a few clips before and after, what rendering does, and the
/// three ways on. Shown in place of the send sheet's event list.
struct ImmichSendGradeAskView: View {
    let grading: ClipGrading
    @Bindable var ask: ImmichSendGradeAsk

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)]

    var body: some View {
        switch ask.stage {
        case .checking(let line):
            VStack(alignment: .leading, spacing: 14) {
                Text("Send to Immich").font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(line).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                HStack {
                    Spacer()
                    Button("Cancel") { grading.answerImmichSendAsk(.cancel) }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 520)
        case .asking:
            question
        case .choosingLooks:
            if let blanket = ask.blanket {
                BlanketGradeSheet(
                    model: blanket,
                    onCancel: { grading.cancelChoosingLooks() },
                    onApply: { grading.applyLooksAndSend() }
                )
            }
        }
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "camera.filters").foregroundStyle(Color.orange)
                Text("Render before sending?").font(.title2.weight(.semibold))
            }
            Text(ask.headline)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if !ask.previews.isEmpty {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(ask.previews) { row in
                        BlanketGradeCell(row: row)
                    }
                }
                if ask.count > ask.previews.count {
                    Text("and \(ask.count - ask.previews.count) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(ask.options) { option in
                    Toggle(isOn: Binding(get: { option.isOn }, set: { ask.setOption(option.id, on: $0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.title)
                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!option.isAvailable)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(whereLines, id: \.self) { line in
                    Label(line, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                }
                Text("Originals are only read. Each copy is checked, then joins its event's album in place of the flat original; the album keeps photos you added yourself.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { grading.answerImmichSendAsk(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Send as They Are") { grading.answerImmichSendAsk(.sendAsTheyAre) }
                Button("Choose Looks First…") { grading.answerImmichSendAsk(.chooseLooksFirst) }
                    .disabled(!ask.isOn(.grade))
                Button("Render and Send") { grading.answerImmichSendAsk(.renderAndSend) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!ask.rendersAnything)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private var whereLines: [String] {
        let formatter = ByteCountFormatter()
        var lines: [String] = []
        if ask.onNASCount > 0 {
            lines.append("\(ask.onNASCount) cop\(ask.onNASCount == 1 ? "y goes" : "ies go") straight into the NAS event's Edited/\(GradedRenderNaming.folderName), then Immich scans.")
        }
        if ask.onDriveCount > 0 {
            lines.append("\(ask.onDriveCount) cop\(ask.onDriveCount == 1 ? "y goes" : "ies go") into Edited/\(GradedRenderNaming.folderName) on the drive; Sync to NAS carries \(ask.onDriveCount == 1 ? "it" : "them") to Immich.")
        }
        if ask.estimatedBytes > 0 {
            lines.append("About \(formatter.string(fromByteCount: ask.estimatedBytes)) in all. The render shows in Jobs, where Stop removes any partial copy.")
        }
        if ask.unchecked > 0 {
            lines.append("\(ask.unchecked) could not be checked in time (the NAS may be asleep); their render looks again first and never makes a second copy.")
        }
        return lines
    }
}

/// The graded-copy lines under one event in the send's result.
struct ImmichSendGradedLines: View {
    let result: ImmichSendResult

    var body: some View {
        if result.gradedInAlbum > 0 {
            Label("\(result.gradedInAlbum.formatted()) graded cop\(result.gradedInAlbum == 1 ? "y" : "ies") in the album in place of the flat original\(result.gradedInAlbum == 1 ? "" : "s")", systemImage: "camera.filters")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if result.gradedWaiting > 0 {
            Label("\(result.gradedWaiting.formatted()) graded cop\(result.gradedWaiting == 1 ? "y" : "ies") waiting for Immich scan: added on the next check", systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if result.gradedOnDrive > 0 {
            Label("\(result.gradedOnDrive.formatted()) graded cop\(result.gradedOnDrive == 1 ? "y is" : "ies are") on the drive: Sync to NAS carries \(result.gradedOnDrive == 1 ? "it" : "them") to Immich", systemImage: "externaldrive")
                .font(.callout)
                .foregroundStyle(Color.orange)
        }
    }
}
