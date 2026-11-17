import AVFoundation
@testable import CameraToolkitApp
@testable import CameraToolkitCore
import CoreImage
import VideoToolbox
import XCTest

/// The grade panel's picture paths on a synthetic S-Log3 clip: the frame
/// grabber, the look thumbnails and live playback must all read the clip's
/// code values and land where `GradePipeline` says, whether the clip is
/// tagged Rec.709 or BT.2020.
final class GradePreviewPipelineTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("GradePreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Tests

    /// Regression: the playability probe cancelled the asset's loading
    /// after it had answered, the player kept that asset, and building the
    /// grade's composition from it failed ("Operation cancelled") — so the
    /// preview played ungraded and Split showed log on both sides.
    @MainActor
    func testThePlayersAssetBuildsAGradedComposition() async throws {
        let clip = try await SyntheticSLog3Clip.write(to: folder.appendingPathComponent("C0001.MP4"), primaries: .rec709)
        let ready = await VideoPreviewSupport.readyPlayer(for: clip)
        let player = try XCTUnwrap(ready)
        let item = try XCTUnwrap(player.currentItem)
        let live = GradeLiveState(recipe: SyntheticSLog3Clip.recipe(range: .video))
        let composition = try await GradeRenderer.shared.videoComposition(for: item.asset, live: live)
        // The same composition the player gets, drawn offscreen.
        let graded = try await Self.firstFrame(of: item.asset, composition: composition)
        let expected = SyntheticSLog3Clip.expectedGraded(range: .video)
        for (index, patch) in SyntheticSLog3Clip.patches.enumerated() {
            assertClose(Self.sample(graded, patch: index), expected[index], accuracy: 0.03, "graded \(patch.name)")
        }
        // Original (log) bypasses the grade: the log grey, not Rec.709 grey.
        live.update { $0.bypass = true }
        let bypass = try await Self.firstFrame(of: item.asset, composition: composition)
        XCTAssertLessThan(Self.sample(bypass, patch: 1).x, 0.7, "Original (log) shows the log picture")
        // Split at the middle: patches 0–2 are the original, 3–5 graded.
        live.update { $0.bypass = false; $0.wipe = 0.5 }
        let split = try await Self.firstFrame(of: item.asset, composition: composition)
        XCTAssertLessThan(Self.sample(split, patch: 1).x, 0.7, "left of the line is the original")
        assertClose(Self.sample(split, patch: 5), expected[5], accuracy: 0.03, "right of the line is graded")
    }

    /// Thumbnails, the grabbed still and playback agree on a clip tagged
    /// Rec.709 and on the same clip tagged BT.2020. Before the fix a
    /// BT.2020 frame was colour-matched into Rec.709 first, which expanded
    /// the log gamut a second time: the red patch lost nearly all its green
    /// (a magenta cast) in the thumbnails and in playback.
    func testStillThumbnailAndPlaybackMatchThePipelineForEachTag() async throws {
        // Video range tagged both ways, and what a Sony A7V body writes:
        // full range with no colour tags at all.
        let cases: [(SyntheticSLog3Clip.Primaries, VideoSignalRange)] = [(.rec709, .video), (.rec2020, .video), (.untagged, .full)]
        for (primaries, range) in cases {
            let clip = try await SyntheticSLog3Clip.write(to: folder.appendingPathComponent("C-\(primaries)-\(range).MP4"), primaries: primaries, range: range)
            // The range is read from the file, as the app does.
            let read = await GradeRenderer().signalRange(of: clip)
            XCTAssertEqual(read, range, "\(primaries): signal range read from the file")
            let expected = SyntheticSLog3Clip.expectedGraded(range: range)
            let recipe = SyntheticSLog3Clip.recipe(range: range)

            let grabbed = await GradeFrameGrabber(url: clip).frame(at: .zero)
            let frame = try XCTUnwrap(grabbed, "\(primaries)")
            let still = try XCTUnwrap(GradeRenderer.shared.grade(frame, recipe: recipe))
            let small = try XCTUnwrap(GradeSession.downscaled(frame, maxWidth: 160))
            let thumbnail = try XCTUnwrap(GradeRenderer.shared.grade(small, recipe: recipe))

            let asset = AVURLAsset(url: clip)
            let composition = try await GradeRenderer.shared.videoComposition(for: asset, live: GradeLiveState(recipe: recipe))
            let played = try await Self.firstFrame(of: asset, composition: composition)

            for (index, patch) in SyntheticSLog3Clip.patches.enumerated() {
                assertClose(Self.sample(still, patch: index), expected[index], accuracy: 0.03, "\(primaries) still \(patch.name)")
                assertClose(Self.sample(thumbnail, patch: index), expected[index], accuracy: 0.03, "\(primaries) thumbnail \(patch.name)")
                assertClose(Self.sample(played, patch: index), expected[index], accuracy: 0.035, "\(primaries) playback \(patch.name)")
            }
        }
    }

    // MARK: Helpers

    /// The first frame through `composition`, as a player would draw it.
    nonisolated private static func firstFrame(of asset: AVAsset, composition: AVVideoComposition) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        generator.videoComposition = composition
        return try await generator.image(at: .zero).image
    }

    /// The middle of a patch, as the image's own values (no matching).
    static func sample(_ image: CGImage, patch: Int) -> SIMD3<Double> {
        let w = image.width, h = image.height
        var data = [UInt16](repeating: 0, count: w * h * 4)
        let space = image.colorSpace ?? GradeRenderer.outputColorSpace
        let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let count = SyntheticSLog3Clip.patches.count
        let x = (patch * w + w / 2) / count
        let y = h / 2
        let i = (y * w + x) * 4
        return SIMD3(Double(data[i]), Double(data[i + 1]), Double(data[i + 2])) / 65535
    }

    private func assertClose(_ a: SIMD3<Double>, _ b: SIMD3<Double>, accuracy: Double, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "\(message) red \(a) vs \(b)", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "\(message) green \(a) vs \(b)", file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, "\(message) blue \(a) vs \(b)", file: file, line: line)
    }
}

/// A two-frame 10-bit HEVC clip of flat S-Log3 / S-Gamut3.Cine patches,
/// full or video range, tagged Rec.709, BT.2020 or not at all (a Sony A7V
/// writes full range with no colour tags; its sidecar says Rec.709 coding).
enum SyntheticSLog3Clip {
    enum Primaries: String, CustomStringConvertible {
        case rec709, rec2020, untagged
        var description: String { rawValue }
    }

    struct Patch {
        let name: String
        /// Scene-linear Rec.709.
        let linear709: SIMD3<Double>
    }

    static let patches: [Patch] = [
        Patch(name: "18% grey", linear709: SIMD3(repeating: 0.18)),
        Patch(name: "90% white", linear709: SIMD3(repeating: 0.9)),
        Patch(name: "red", linear709: SIMD3(0.48, 0.08, 0.12)),
        Patch(name: "skin", linear709: SIMD3(0.43, 0.31, 0.24)),
        Patch(name: "foliage", linear709: SIMD3(0.10, 0.45, 0.38)),
        Patch(name: "sky", linear709: SIMD3(0.11, 0.18, 0.30)),
    ]

    static func recipe(range: VideoSignalRange) -> GradeRecipe {
        GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine, conversion: .builtIn, range: range)
    }

    /// Each patch's decoded value (0…1 R′G′B′ as the decoder hands it over).
    static func decoded(range: VideoSignalRange) -> [SIMD3<Double>] {
        let toCine = RGBPrimaries.rec709.conversion(to: .sGamut3Cine)
        return patches.map { patch in
            let cine = toCine.apply(patch.linear709)
            return SIMD3(
                range.decoded(fromCodeValue: SLog3.encode(reflection: cine.x)),
                range.decoded(fromCodeValue: SLog3.encode(reflection: cine.y)),
                range.decoded(fromCodeValue: SLog3.encode(reflection: cine.z))
            )
        }
    }

    static func expectedGraded(range: VideoSignalRange) -> [SIMD3<Double>] {
        let pipeline = GradePipeline(recipe: recipe(range: range))
        return decoded(range: range).map { pipeline.apply($0) }
    }

    static func write(to url: URL, primaries: Primaries, range: VideoSignalRange = .video) async throws -> URL {
        // HD, as the camera records: for a clip with no colour tags
        // VideoToolbox guesses the YCbCr matrix from the frame size (BT.601
        // below HD, BT.709 at HD and up), and Sony's untagged clips are
        // coded BT.709.
        let width = 1_920, height = 1_080
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // An untagged clip is still coded with the Rec.709 matrix.
        let (primariesKey, matrixKey, kr, kb): (String?, String?, Double, Double) = switch primaries {
        case .rec709: (AVVideoColorPrimaries_ITU_R_709_2, AVVideoYCbCrMatrix_ITU_R_709_2, 0.2126, 0.0722)
        case .rec2020: (AVVideoColorPrimaries_ITU_R_2020, AVVideoYCbCrMatrix_ITU_R_2020, 0.2627, 0.0593)
        case .untagged: (nil, nil, 0.2126, 0.0722)
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                AVVideoAverageBitRateKey: 20_000_000,
            ],
        ]
        if let primariesKey, let matrixKey {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: primariesKey,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: matrixKey,
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let full = range == .full
        let format = full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let values = decoded(range: range)
        for frame in 0..<2 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            let pixels = try XCTUnwrap(buffer)
            if let primariesKey, let matrixKey {
                CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, primariesKey as CFString, .shouldPropagate)
                CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, matrixKey as CFString, .shouldPropagate)
                CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            }
            CVPixelBufferLockBaseAddress(pixels, [])
            let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt16.self)
            let chroma = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!.assumingMemoryBound(to: UInt16.self)
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) / 2
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) / 2
            func ycbcr(_ v: SIMD3<Double>) -> (UInt16, UInt16, UInt16) {
                let y = kr * v.x + (1 - kr - kb) * v.y + kb * v.z
                let cb = (v.z - y) / (2 * (1 - kb)), cr = (v.x - y) / (2 * (1 - kr))
                // 10-bit, MSB-aligned in 16 bits.
                func q(_ x: Double) -> UInt16 { UInt16(min(max(x.rounded(), 0), 1023)) << 6 }
                return full
                    ? (q(1023 * y), q(512 + 1023 * cb), q(512 + 1023 * cr))
                    : (q(64 + 876 * y), q(512 + 896 * cb), q(512 + 896 * cr))
            }
            for row in 0..<height {
                for column in 0..<width {
                    let (y, cb, cr) = ycbcr(values[column * patches.count / width])
                    luma[row * lumaStride + column] = y
                    if row % 2 == 0, column % 2 == 0 {
                        chroma[(row / 2) * chromaStride + column] = cb
                        chroma[(row / 2) * chromaStride + column + 1] = cr
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            _ = frame
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }
}
