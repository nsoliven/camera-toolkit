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
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("CT-Stabilize-\(UUID().uuidString)", isDirectory: true)
        defer { if ProcessInfo.processInfo.environment["CT_STABILIZE_KEEP"] != "1" { try? FileManager.default.removeItem(at: out) } }
        let request = StabilizeRequest(
            source: clip, settings: StabilizationSettings(smoothing: .medium), sourceKey: "real|0|0",
            sourceModifiedAt: Date(), outputFolder: out.appendingPathComponent("Edited/Stabilized", isDirectory: true)
        )
        let started = Date()
        let result = try Stabilizer(installation: installation).render(request, progress: { step in
            if step.frame % 60 == 0 { print("progress \(step.phase) \(step.frame)/\(step.totalFrames)") }
        })
        print("Stabilized in \(Date().timeIntervalSince(started)) s → \(result.url.path)")
        XCTAssertEqual(Stabilizer.identity(at: result.url, sourceKey: "real|0|0", settings: request.settings), .same, "the comment tag reads back")
    }
}
