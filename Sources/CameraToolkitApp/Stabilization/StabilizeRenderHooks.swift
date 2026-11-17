import AppKit
import CameraToolkitCore
import Foundation

/// The places a render is asked about — Render before Sync to NAS, and
/// Render before Send to Immich — offer stabilization beside the grade.
extension ClipStabilizing {
    /// Every clip set to Stabilize that is not known to lack motion data,
    /// for planners that run off the main actor.
    func renderStabilizationMap() -> [String: RenderStabilization] {
        var map: [String: RenderStabilization] = [:]
        for key in settingsByKey.keys {
            if let stabilization = renderStabilization(forKey: key) { map[key] = stabilization }
        }
        return map
    }

    /// The Send to Immich question's Stabilize box: on when some pending
    /// clip is set to Stabilize; unavailable (with why) without Gyroflow.
    func stabilizeOption(for pending: [GradedSyncPlanner.PlacedRequest]) -> ImmichSendGradeAsk.RenderOption? {
        let count = pending.count { $0.request.stabilization != nil }
        guard count > 0 else { return nil }
        let ready = availability.isReady
        return ImmichSendGradeAsk.RenderOption(
            id: .stabilize,
            title: "Stabilize",
            detail: ready
                ? "\(count) clip\(count == 1 ? " is" : "s are") set to Stabilize: stabilized from the camera's gyro data first, then graded — one copy each."
                : (availability.problem ?? "Needs Gyroflow."),
            isOn: ready,
            isAvailable: ready
        )
    }

    /// The pending copies with each clip's stabilization as it is now (after
    /// the quick sheet changed it).
    func refreshStabilization(of pending: [GradedSyncPlanner.PlacedRequest]) -> [GradedSyncPlanner.PlacedRequest] {
        pending.map { item in
            var item = item
            item.request.stabilization = renderStabilization(forKey: item.request.sourceKey)
            return item
        }
    }
}

extension ImmichSendGradeAsk {
    /// Adds, replaces or removes the Stabilize box.
    func setStabilizeOption(_ option: RenderOption?) {
        options.removeAll { $0.id == .stabilize }
        if let option { options.append(option) }
    }
}

/// The Stabilize box on the Render before Sync alert.
enum StabilizeRenderAsk {
    static func checkbox(count: Int) -> NSButton {
        let box = NSButton(
            checkboxWithTitle: "Also stabilize the \(count) clip\(count == 1 ? "" : "s") set to Stabilize (Gyroflow, before grading)",
            target: nil, action: nil
        )
        box.state = .on
        return box
    }
}

extension Array where Element == GradedSyncPlanner.PlacedRequest {
    /// The same copies, graded only.
    func withoutStabilization() -> [GradedSyncPlanner.PlacedRequest] {
        map { item in
            var item = item
            item.request.stabilization = nil
            return item
        }
    }
}
