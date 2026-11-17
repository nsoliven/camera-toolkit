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

    /// With `CT_STABILIZE_INTERMEDIATE` (a stabilized ProRes of the clip,
    /// e.g. from the test above with `CT_STABILIZE_KEEP=1`): grades it the
    /// way a stabilize-then-grade render does, as S-Log3, into
    /// `CT_STABILIZE_OUT`, and checks the copy.
    func testRealStabilizedIntermediateGrades() throws {
        guard let clip, let intermediate = ProcessInfo.processInfo.environment["CT_STABILIZE_INTERMEDIATE"].map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("Set CT_STABILIZE_CLIP and CT_STABILIZE_INTERMEDIATE.")
        }
        let base = ProcessInfo.processInfo.environment["CT_STABILIZE_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let out = base.appendingPathComponent("CT-Grade-\(UUID().uuidString)/Edited/Rec709", isDirectory: true)
        var request = GradedRenderRequest(
            source: clip,
            recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine, range: .full),
            sourceKey: "real|0|0", sourceModifiedAt: Date(), outputFolder: out
        )
        request.stabilization = RenderStabilization(settings: StabilizationSettings(smoothing: .medium))
        request.decodeSource = intermediate
        request.decodeRange = try GradedVideoExporter.blocking { await GradeRenderer.shared.signalRange(of: intermediate) }
        let started = Date()
        let result = try GradedVideoExporter().render(request)
        print("Decode range of the intermediate: \(String(describing: request.decodeRange))")
        print("Graded from the stabilized intermediate in \(Date().timeIntervalSince(started)) s → \(result.url.path)")
        XCTAssertEqual(GradedVideoExporter.readTags(result.url)?.grade, GradedVideoExporter.renderFingerprint(of: request))
    }

    /// With `CT_GYROFLOW_SIGNATURE=1`: the downloaded Gyroflow in
    /// ~/Applications or /Applications passes the Developer ID check, and
    /// `locate` picks it. Reads signatures only; runs nothing.
    func testInstalledGyroflowSignature() throws {
        guard ProcessInfo.processInfo.environment["CT_GYROFLOW_SIGNATURE"] == "1" else { throw XCTSkip("Set CT_GYROFLOW_SIGNATURE=1.") }
        for root in GyroflowInstallation.defaultSearchRoots() {
            let app = root.appendingPathComponent("Gyroflow.app")
            guard let installation = GyroflowInstallation.inspect(appURL: app) else { continue }
            print("\(app.path): App Store \(installation.isAppStoreBuild), version \(installation.version ?? "?"), Developer ID check \(GyroflowSignature.isGenuineDownload(app))")
        }
        let chosen = try XCTUnwrap(GyroflowInstallation.locate())
        print("Chosen: \(chosen.appURL.path)")
        XCTAssertFalse(chosen.isAppStoreBuild)
        XCTAssertTrue(GyroflowSignature.isGenuineDownload(chosen.appURL))
    }

    /// With `CT_STABILIZE_CLIP` and `CT_STABILIZE_GYROFLOW=1`: Stop three
    /// seconds into a real render ends Gyroflow and leaves no file behind.
    func testRealStopLeavesNothing() throws {
        guard let clip, ProcessInfo.processInfo.environment["CT_STABILIZE_GYROFLOW"] == "1" else { throw XCTSkip("Set CT_STABILIZE_CLIP and CT_STABILIZE_GYROFLOW=1.") }
        guard let installation = StabilizerAvailability(GyroflowInstallation.locate()).installation else { throw XCTSkip("No Gyroflow that can render here.") }
        let base = ProcessInfo.processInfo.environment["CT_STABILIZE_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let out = base.appendingPathComponent("CT-Stop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let folder = out.appendingPathComponent("Edited/Stabilized", isDirectory: true)
        let started = Date()
        XCTAssertThrowsError(try Stabilizer(installation: installation).stabilize(
            source: clip, settings: StabilizationSettings(), into: folder, isCancelled: { Date().timeIntervalSince(started) > 3 }
        )) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let left = (try? FileManager.default.subpathsOfDirectory(atPath: out.path)) ?? []
        print("Stopped after \(Date().timeIntervalSince(started)) s; left: \(left)")
        XCTAssertTrue(left.allSatisfy { !$0.contains(".mov") }, "\(left)")
        XCTAssertTrue(StabilizerProcesses.running.isEmpty)
    }
}
