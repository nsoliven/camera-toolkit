import AVFoundation
@testable import CameraToolkitCore
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Opt-in: renders before/after PNGs from a real clip so the look can be
/// judged by eye, and checks that the playback path (a video composition)
/// grades a frame the same way the still path does.
///
///     CT_GRADE_SAMPLE_CLIP=/path/to/clip.MP4 CT_GRADE_SAMPLE_OUT=/tmp/out \
///         swift test --filter GradeSampleFrameTests
///
/// The clip is only read. Nothing is written beside it.
final class GradeSampleFrameTests: XCTestCase {
    func testRenderSampleFrames() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let clipPath = env["CT_GRADE_SAMPLE_CLIP"], let outPath = env["CT_GRADE_SAMPLE_OUT"] else {
            throw XCTSkip("Set CT_GRADE_SAMPLE_CLIP and CT_GRADE_SAMPLE_OUT to render sample frames.")
        }
        let clip = URL(fileURLWithPath: clipPath)
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let companions = [clip.deletingPathExtension().appendingPathExtension("XML"),
                          URL(fileURLWithPath: clip.deletingPathExtension().path + "M01.XML")]
        let profile = LogProfileDetector.profile(clip: clip, companions: companions) ?? .sLog3SGamut3Cine
        let renderer = GradeRenderer()
        let range = await renderer.signalRange(of: clip) ?? .full
        let asset = AVURLAsset(url: clip)
        let duration = try await asset.load(.duration).seconds
        let seconds = Double(env["CT_GRADE_SAMPLE_AT"] ?? "") ?? min(5, duration / 2)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_920, height: 1_920)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let frame = try await generator.image(at: time).image
        let name = clip.deletingPathExtension().lastPathComponent
        let recipe = GradeRecipe(grade: .rec709, profile: profile, range: range)
        try writePNG(frame, to: out.appendingPathComponent("\(name)-before.png"))
        let graded = try XCTUnwrap(renderer.grade(frame, recipe: recipe))
        try writePNG(graded, to: out.appendingPathComponent("\(name)-after-rec709.png"))
        var warm = ClipGrade.rec709
        warm.exposure = 0.3
        warm.temperature = 18
        warm.contrast = 15
        warm.saturation = 10
        let warmGraded = try XCTUnwrap(renderer.grade(frame, recipe: GradeRecipe(grade: warm, profile: profile, range: range)))
        try writePNG(warmGraded, to: out.appendingPathComponent("\(name)-after-rec709-warm.png"))
        let split = try XCTUnwrap(sideBySide(frame, graded, renderer: renderer))
        try writePNG(split, to: out.appendingPathComponent("\(name)-wipe.png"))

        // The playback path must agree with the still path.
        let live = GradeLiveState(recipe: recipe)
        let composition = try await renderer.videoComposition(for: asset, live: live)
        let playback = AVAssetImageGenerator(asset: asset)
        playback.videoComposition = composition
        playback.maximumSize = generator.maximumSize
        playback.requestedTimeToleranceBefore = .zero
        playback.requestedTimeToleranceAfter = .zero
        let played = try await playback.image(at: time).image
        try writePNG(played, to: out.appendingPathComponent("\(name)-after-playback-path.png"))
        let difference = meanDifference(graded, played)
        print("profile \(profile.rawValue) range \(range.rawValue); still vs playback mean difference \(difference)")
        XCTAssertLessThan(difference, 0.03)

        // CT_GRADE_SAMPLE_RENDER=1 also renders the graded copy (hardware
        // HEVC) into the output folder — never beside the clip.
        guard env["CT_GRADE_SAMPLE_RENDER"] == "1" else { return }
        let values = try clip.resourceValues(forKeys: [.contentModificationDateKey])
        let request = GradedRenderRequest(
            source: clip, recipe: recipe, sourceKey: "sample", sourceModifiedAt: values.contentModificationDate ?? Date(),
            outputFolder: out.appendingPathComponent("Edited/\(GradedRenderNaming.folderName)", isDirectory: true),
            make: "Sony", model: "sample"
        )
        let started = ContinuousClock.now
        let outcome = try GradedVideoExporter(renderer: renderer).render(request)
        let elapsed = ContinuousClock.now - started
        print("rendered \(outcome.url.lastPathComponent) in \(elapsed) for a \(duration) s clip")
        let copy = AVURLAsset(url: outcome.url)
        let tracks = try await copy.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(formats.first)
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let rate = try await track.load(.estimatedDataRate)
        let audio = try await copy.loadTracks(withMediaType: .audio)
        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
        print("copy: \(size) @ \(fps) fps, \(Int(rate / 1_000_000)) Mb/s, audio tracks \(audio.count), primaries \(extensions["CVImageBufferColorPrimaries"] ?? "-"), transfer \(extensions["CVImageBufferTransferFunction"] ?? "-"), depth \(extensions["BitsPerComponent"] ?? "-")")
        let copyFrame = try await AVAssetImageGenerator(asset: copy).image(at: time).image
        try writePNG(copyFrame, to: out.appendingPathComponent("\(name)-after-rendered-copy.png"))
    }

    private func sideBySide(_ before: CGImage, _ after: CGImage, renderer: GradeRenderer) -> CGImage? {
        let a = CIImage(cgImage: before, options: [.colorSpace: NSNull()])
        let b = CIImage(cgImage: after, options: [.colorSpace: NSNull()])
        let split = a.extent.width / 2
        let left = a.cropped(to: CGRect(x: 0, y: 0, width: split, height: a.extent.height))
        let right = b.cropped(to: CGRect(x: split, y: 0, width: a.extent.width - split, height: a.extent.height))
        let line = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: split - 1, y: 0, width: 2, height: a.extent.height))
        return renderer.render(line.composited(over: right.composited(over: left)), extent: a.extent)
    }

    private func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        func pixels(_ image: CGImage) -> [UInt8] {
            let w = 160, h = 90
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return data
        }
        let pa = pixels(a), pb = pixels(b)
        var sum = 0.0
        for i in 0..<pa.count where i % 4 != 3 { sum += abs(Double(pa[i]) - Double(pb[i])) / 255 }
        return sum / Double(pa.count / 4 * 3)
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        // Convert to sRGB 8-bit so any viewer shows what the app shows.
        let w = image.width, h = image.height
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let converted = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, converted, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
