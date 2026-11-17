import CameraToolkitCore
import Foundation
import SwiftUI

/// The quick (blanket) sheet's Stabilize choice: one pass sets the look and
/// the stabilization of every chosen clip, and the render does both.
struct BlanketStabilizeChoice: Equatable {
    var isOn = false
    var smoothing: StabilizationSmoothing = .medium
    /// What the clips had when the sheet opened: Apply leaves stabilization
    /// alone unless the toggle or the smoothing moved.
    var initiallyOn = false
    var initialSmoothing: StabilizationSmoothing = .medium
    /// Clips with motion data; nil while the probe is counting.
    var withMotion: Int?
    var withoutMotion = 0
    /// Why Gyroflow can't run, when it can't.
    var problem: String?

    var changed: Bool { isOn != initiallyOn || (isOn && smoothing != initialSmoothing) }
}

/// Stabilize on/off and Low / Medium / High, with the count of clips that
/// can be stabilized and the count skipped (no motion data).
struct BlanketStabilizeControls: View {
    @Binding var choice: BlanketStabilizeChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Toggle(isOn: $choice.isOn) {
                    Label("Stabilize", systemImage: "gyroscope")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled((choice.withMotion == 0 || choice.problem != nil) && !choice.initiallyOn)
                Picker("Smoothing", selection: $choice.smoothing) {
                    ForEach(StabilizationSmoothing.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                .disabled(!choice.isOn)
                Spacer()
            }
            Group {
                if let withMotion = choice.withMotion {
                    Text("\(withMotion) with motion data\(choice.isOn ? " are stabilized, then graded" : " can be stabilized")"
                        + (choice.withoutMotion > 0 ? " · \(choice.withoutMotion) skipped: no motion data in the file" : ""))
                } else {
                    Text("Looking for motion data…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let problem = choice.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }
}

extension ClipStabilizing {
    /// Fills the sheet's choice for these clips (file key, file): probes
    /// them, counts, and starts the toggle where the clips already are.
    func fillBlanketChoice(_ model: BlanketGradeModel, clips: [(key: String, url: URL)]) async {
        let todo = clips.filter { motion[$0.key] == nil }
        if !todo.isEmpty {
            let answers = await Task.detached(priority: .userInitiated) {
                todo.map { ($0.key, MotionDataProbe.probe($0.url)) }
            }.value
            for (key, answer) in answers { setMotion(answer, forKey: key) }
        }
        var choice = BlanketStabilizeChoice()
        let able = clips.filter { motion[$0.key] != .absent }
        choice.withMotion = able.count
        choice.withoutMotion = clips.count - able.count
        let existing = able.compactMap { settingsByKey[$0.key] }
        choice.initiallyOn = !able.isEmpty && existing.count == able.count
        choice.isOn = choice.initiallyOn
        choice.initialSmoothing = existing.first?.smoothing ?? lastSmoothing
        choice.smoothing = choice.initialSmoothing
        choice.problem = availability.problem
        model.stabilize = choice
    }

    func fillBlanketChoice(_ model: BlanketGradeModel, items: [OrganizeItem]) async {
        await fillBlanketChoice(model, clips: items.filter(Self.isStabilizable).map { (Self.fileKey($0), $0.primary.url) })
    }

    /// Applies the sheet's choice to these clips (one Undo step). Returns
    /// how many are stabilized now, or nil when the choice changed nothing.
    @discardableResult
    func applyBlanketChoice(_ choice: BlanketStabilizeChoice, keys: [String]) -> Int? {
        guard choice.changed else { return nil }
        let targets = keys.filter { motion[$0] != .absent }
        if choice.isOn {
            let settings = StabilizationSettings(smoothing: choice.smoothing)
            setStabilization(byKey: targets.map { ($0, settings) }, undoTitle: "Stabilize \(targets.count) Clip\(targets.count == 1 ? "" : "s")")
            return targets.count
        }
        setStabilization(byKey: keys.map { ($0, nil) }, undoTitle: "Turn Off Stabilization")
        return 0
    }

    @discardableResult
    func applyBlanketChoice(_ choice: BlanketStabilizeChoice, items: [OrganizeItem]) -> Int? {
        applyBlanketChoice(choice, keys: items.filter(Self.isStabilizable).map(Self.fileKey))
    }
}
