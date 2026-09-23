import CameraToolkitCore
import SwiftUI

/// The Cable & Enclosure Stability sheet — setup (cable label, port,
/// profile), the live run (phase, countdown, throughput, counter deltas,
/// mount state), the verdict, and this drive's history.
struct StabilityTestView: View {
    var target: StorageBenchmarkTarget
    var linkContext: StorageLinkContext?
    @Bindable var stability: StabilityTestViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRecordID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if stability.isRunning {
                        liveSection
                    }
                    if let verdict = stability.verdict {
                        verdictCard(verdict)
                    }
                    if let error = stability.errorMessage {
                        callout(title: "Could not run the test", detail: error,
                                symbol: "exclamationmark.triangle.fill", color: .orange)
                    }
                    if !stability.isRunning {
                        setupSection
                    }
                    historySection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.teal.opacity(0.11))
                Image(systemName: "cable.connector")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.teal)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("Cable & Enclosure Stability")
                    .font(.title2.weight(.semibold))
                Text("\(target.name) — \(linkContext?.headline ?? "link not detected")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if stability.isRunning {
                Button("Stop", role: .cancel) { stability.cancel() }
                    .help("Ends the run now and removes the temporary file")
            }
            Button("Close") { dismiss() }
                .disabled(stability.isRunning)
                .help(stability.isRunning ? "Stop the test before closing" : "")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.bar)
    }

    // MARK: - Setup

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Cable")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    HStack(spacing: 8) {
                        TextField("e.g. Anker 1 m — name it so runs compare", text: $stability.cableLabel)
                            .textFieldStyle(.roundedBorder)
                        if !stability.knownCableLabels.isEmpty {
                            Menu {
                                ForEach(stability.knownCableLabels, id: \.self) { label in
                                    Button(label) { stability.cableLabel = label }
                                }
                            } label: {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 22)
                            .help("Cables you have named before")
                        }
                    }
                }
                GridRow {
                    Text("Port")
                        .foregroundStyle(.secondary)
                    Picker("Port", selection: $stability.portLabel) {
                        ForEach(stability.portChoices, id: \.self) { choice in
                            Text(choice).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .leading)
                    .help(
                        stability.detectedPortLabel.map {
                            "Detected as \($0) from the USB registry — pick another if that is wrong"
                        } ?? "The port could not be detected — pick the one the cable is in"
                    )
                }
                GridRow {
                    Text("Profile")
                        .foregroundStyle(.secondary)
                    Picker("Profile", selection: $stability.selectedProfile) {
                        ForEach(StabilityProfile.allCases) { profile in
                            Text(profile.pickerLabel).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .leading)
                }
            }
            .font(.callout)

            Text(stability.selectedProfile.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !stability.usbCountersAvailable {
                Label("USB counters not available on this connection — the test still grades drops, stalls, and throughput.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Start \(stability.selectedProfile.title) Test") {
                    stability.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(stability.isDashboardBusy)
                Text(stability.isDashboardBusy
                     ? "A copy or checksum job is running — the test refuses to start during a transfer."
                     : stability.canWrite
                        ? "Writes a bounded temporary area (≤ 8 GB) inside this drive's Buffer folder, then removes it."
                        : "Read-only drive — the test samples existing media and writes nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    // MARK: - Live run

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(stability.phaseTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.teal.opacity(0.10), in: Capsule())
                Text("phase \(stability.phaseIndex + 1) of \(stability.phaseCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(durationText(stability.phaseRemaining)) left in phase · \(durationText(stability.runRemaining)) overall")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Sparkline(samples: stability.throughputHistory, tint: .teal)
                .frame(height: 56)
            HStack {
                Text(stability.liveBytesPerSecond > 0
                     ? "\(Int64(stability.liveBytesPerSecond).formattedBytes)/s"
                     : "—")
                    .font(.caption.monospacedDigit())
                Spacer()
                mountBadge
            }

            countersGrid
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.teal.opacity(0.45), lineWidth: 1)
        }
    }

    private var mountBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(stability.mounted ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(stability.mounted ? "Mounted" : "Disappeared")
                .font(.caption.weight(.medium))
                .foregroundStyle(stability.mounted ? Color.secondary : Color.red)
        }
    }

    private var countersGrid: some View {
        let delta = stability.counterDelta
        return Group {
            if stability.usbCountersAvailable {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    counterCell("Connects", delta[USBPortHealthSample.CounterKey.connectCount] ?? 0)
                    counterCell("Enum fails", delta[USBPortHealthSample.CounterKey.enumerationFailureCount] ?? 0)
                    counterCell("Address fails", delta[USBPortHealthSample.CounterKey.addressFailureCount] ?? 0)
                    counterCell("Link errors", delta[USBPortHealthSample.CounterKey.linkErrorCount] ?? 0)
                    counterCell("Over-current", delta[USBPortHealthSample.CounterKey.overCurrentCount] ?? 0)
                    counterCell("EOF2 violations", eof2Delta(delta))
                }
            } else {
                Label("USB counters not available on this connection", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func eof2Delta(_ delta: [String: Int64]) -> Int64 {
        delta.reduce(0) {
            $1.key.hasPrefix(USBPortHealthSample.CounterKey.eof2ViolationPrefix) ? $0 + $1.value : $0
        }
    }

    private func counterCell(_ title: String, _ value: Int64) -> some View {
        VStack(spacing: 2) {
            Text("+\(value)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(value > 0 ? .red : .primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            (value > 0 ? Color.red : Color.primary).opacity(value > 0 ? 0.10 : 0.04),
            in: RoundedRectangle(cornerRadius: 7)
        )
    }

    // MARK: - Verdict

    private func verdictCard(_ verdict: StabilityVerdict) -> some View {
        let color: Color = switch verdict.grade {
        case .pass: .green
        case .warning: .orange
        case .fail: .red
        }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: verdict.grade == .pass
                      ? "checkmark.seal.fill"
                      : verdict.grade == .warning
                        ? "exclamationmark.triangle.fill"
                        : "xmark.octagon.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(color)
                Text(verdict.headline)
                    .font(.headline)
                Spacer()
                Text(verdict.grade.rawValue.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.12), in: Capsule())
            }
            ForEach(verdict.reasons, id: \.self) { reason in
                Text("• \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let record = stability.record {
                ForEach(Array(record.phases.enumerated()), id: \.offset) { _, phase in
                    HStack(spacing: 6) {
                        Text(phase.kind.title)
                            .frame(width: 108, alignment: .leading)
                        if phase.kind.movesBytes {
                            Text("min \(mbps(phase.minBytesPerSecond)) · typical \(mbps(phase.typicalBytesPerSecond)) · max \(mbps(phase.maxBytesPerSecond)) MB/s")
                        } else {
                            Text("no I/O by design")
                        }
                        if !phase.completed {
                            Text("(cut short)")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            Text(verdict.advice)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if let record = stability.record {
                Button("Copy Report") { stability.copyReport(for: record) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.3), lineWidth: 1)
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PREVIOUS RUNS ON THIS DRIVE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let record = selectedRecord {
                    Button("Copy Report") { stability.copyReport(for: record) }
                        .controlSize(.small)
                }
            }
            if stability.history.isEmpty {
                Text("No runs recorded for this drive yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(stability.history) { record in
                    historyRow(record)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var selectedRecord: StabilityTestRecord? {
        if let selectedRecordID,
           let record = stability.history.first(where: { $0.id == selectedRecordID }) {
            return record
        }
        return stability.history.first
    }

    private func historyRow(_ record: StabilityTestRecord) -> some View {
        let isSelected = selectedRecord?.id == record.id
        let write = record.phases.first { $0.kind == .sustainedWrite }
        let read = record.phases.first { $0.kind == .sustainedRead }
        return HStack(spacing: 10) {
            Text(record.grade.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(record.grade == .pass ? Color.green : record.grade == .warning ? Color.orange : Color.red)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(record.cableLabel.isEmpty ? "Unnamed cable" : record.cableLabel) · \(record.portLabel.isEmpty ? "port ?" : record.portLabel)")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(record.finishedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.profile.capitalized)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let write, write.typicalBytesPerSecond > 0 {
                metricText("W", write.typicalBytesPerSecond)
            }
            if let read, read.typicalBytesPerSecond > 0 {
                metricText("R", read.typicalBytesPerSecond)
            }
            if record.failureTotal > 0 {
                Text("\(record.failureTotal) fails")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { selectedRecordID = record.id }
    }

    private func metricText(_ label: String, _ bytesPerSecond: Double) -> some View {
        Text("\(label) \(Int((bytesPerSecond / 1_000_000).rounded())) MB/s")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
            Text("The test writes only inside a bounded hidden temporary area on writable drives and never touches existing files; read-only drives are never written. Other Camera Toolkit work on this drive is paused while it runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private func callout(title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
    }

    private func mbps(_ bytesPerSecond: Double) -> Int {
        Int((bytesPerSecond / 1_000_000).rounded())
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0).rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
