import Foundation

/// Stabilize, then grade: one final `Edited/Rec709/<name>_709.mov`.
///
/// The clip is stabilized first, while it is still log (Gyroflow warps the
/// picture and leaves its values alone, written as 10-bit ProRes 422 HQ),
/// and the grade is drawn from that. The stabilized ProRes is an
/// intermediate: it is written into the graded folder's temporary folder
/// (same volume, skipped by Sync and the edit-tag scan), the graded copy
/// reads it, and it is deleted once the graded copy is in place — or on
/// Stop or failure. Only the graded copy was asked for, so only it is kept;
/// a stabilized-only copy is its own request (`Stabilizer.render`).
public enum StabilizedGradeChain {
    public struct Prepared: Sendable {
        /// Reads its frames from the intermediate.
        public var request: GradedRenderRequest
        public var intermediate: URL
    }

    /// Makes the intermediate for `request` (which must carry
    /// `stabilization`) and returns the request pointed at it.
    public static func prepare(
        _ request: GradedRenderRequest,
        stabilizer: Stabilizer?,
        rangeOf: (URL) -> VideoSignalRange? = { _ in nil },
        progress: @escaping @Sendable (Stabilizer.Progress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> Prepared {
        guard let stabilization = request.stabilization else {
            throw ToolkitError.commandFailed("Nothing to stabilize for \(request.source.lastPathComponent).")
        }
        guard let stabilizer else {
            throw Stabilizer.Failure.unavailable(StabilizerAvailability.notInstalled.problem ?? "Needs Gyroflow.")
        }
        StabilizedRenderNaming.removeStalePartials(in: request.outputFolder)
        let intermediate = try stabilizer.stabilize(
            source: request.source,
            settings: stabilization.settings,
            into: request.outputFolder,
            codec: .proResHQ,
            comment: StabilizedRenderNaming.tag(sourceKey: request.sourceKey, settings: stabilization.settings),
            progress: progress,
            isCancelled: isCancelled
        )
        var chained = request
        chained.decodeSource = intermediate
        // The copy's tags keep the original's recipe; the picture is drawn
        // with the range the intermediate was written in.
        chained.decodeRange = rangeOf(intermediate)
        return Prepared(request: chained, intermediate: intermediate)
    }

    /// Deletes the intermediate (only a stabilizer partial, by name).
    public static func cleanUp(_ prepared: Prepared?) {
        if let prepared { Stabilizer.removePartial(prepared.intermediate) }
    }
}
