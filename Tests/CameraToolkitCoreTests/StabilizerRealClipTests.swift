import AVFoundation
@testable import CameraToolkitCore
import XCTest

/// Opt-in checks against a real clip, never run by default:
///
///     CT_STABILIZE_CLIP=/path/to/C0001.MP4 swift test --filter StabilizerRealClipTests
///
/// The probe test reads only the clip's movie header. With
/// `CT_STABILIZE_GYROFLOW=1` as well, and a Gyroflow that can run headless
/// (the download from gyroflow.xyz, not the App Store build), the whole clip
/// is stabilized into a temporary folder next to nothing else, and the copy
/// is checked. The clip itself is only read.
final class StabilizerRealClipTests: XCTestCase {
    private var clip: URL? {
        ProcessInfo.processInfo.environment["CT_STABILIZE_CLIP"].map { URL(fileURLWithPath: $0) }
    }

    func testRealClipHasMotionData() throws {
        guard let clip else { throw XCTSkip("Set CT_STABILIZE_CLIP to a camera clip.") }
        let answer = MotionDataProbe.probe(clip)
        print("Motion data probe: \(answer)")
        XCTAssertTrue(answer.isPresent, "\(answer)")
    }

    func testRealClipStabilizesWithGyroflow() throws {
        guard let clip else { throw XCTSkip("Set CT_STABILIZE_CLIP to a camera clip.") }
        guard ProcessInfo.processInfo.environment["CT_STABILIZE_GYROFLOW"] == "1" else { throw XCTSkip("Set CT_STABILIZE_GYROFLOW=1 to run Gyroflow.") }
        let availability = StabilizerAvailability(GyroflowInstallation.locate())
        guard let installation = availability.installation else { throw XCTSkip(availability.problem ?? "No Gyroflow.") }
        let base = ProcessInfo.processInfo.environment["CT_STABILIZE_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let out = base.appendingPathComponent("CT-Stabilize-\(UUID().uuidString)", isDirectory: true)
        defer { if ProcessInfo.processInfo.environment["CT_STABILIZE_KEEP"] != "1" { try? FileManager.default.removeItem(at: out) } }
        let request = StabilizeRequest(
            source: clip, settings: StabilizationSettings(smoothing: .medium), sourceKey: "real|0|0",
            sourceModifiedAt: Date(), outputFolder: out.appendingPathComponent("Edited/Stabilized", isDirectory: true)
        )
        let started = Date()
        if let trim = ProcessInfo.processInfo.environment["CT_STABILIZE_TRIM"]?.split(separator: "-").compactMap({ Double($0) }), trim.count == 2 {
            // A window of a long clip: the same Gyroflow run, trimmed.
            let partial = try Stabilizer(installation: installation).stabilize(
                source: clip, settings: request.settings, into: request.outputFolder, trim: trim[0]...trim[1],
                comment: StabilizedRenderNaming.tag(sourceKey: "real|0|0", settings: request.settings)
            )
            let target = request.outputFolder.appendingPathComponent(StabilizedRenderNaming.candidateName(forSource: clip, attempt: 1))
            try NASFileIO.renameExclusive(from: partial.path, to: target.path)
            Stabilizer.removePartial(partial)
            print("Gyroflow used: \(installation.appURL.path) (App Store build: \(installation.isAppStoreBuild))")
            print("Stabilized \(trim[0])–\(trim[1]) s in \(Date().timeIntervalSince(started)) s → \(target.path)")
            return
        }
        let result = try Stabilizer(installation: installation).render(request, progress: { step in
            if step.frame % 60 == 0 { print("progress \(step.phase) \(step.frame)/\(step.totalFrames)") }
        })
        print("Gyroflow used: \(installation.appURL.path) (App Store build: \(installation.isAppStoreBuild))")
        print("Stabilized in \(Date().timeIntervalSince(started)) s → \(result.url.path)")
        XCTAssertEqual(Stabilizer.identity(at: result.url, sourceKey: "real|0|0", settings: request.settings), .same, "the comment tag reads back")
    }
}
