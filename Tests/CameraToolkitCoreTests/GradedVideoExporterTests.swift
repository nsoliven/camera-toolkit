import AVFoundation
@testable import CameraToolkitCore
import CoreImage
import CryptoKit
import XCTest

/// Renders a graded copy of a tiny synthetic clip: HEVC Rec.709, same size
/// and length, audio passed through, capture time and grade written into
/// it, the original untouched, never a file replaced.
final class GradedVideoExporterTests: XCTestCase {
    /// A clip's planned frames for the Jobs window: length × frame rate, and
    /// nil — never a trap — for a length that is not a number.
    func testPlannedFramesNeverTrapOnAnUnusableLength() {
        XCTAssertEqual(GradedVideoExporter.plannedFrames(duration: CMTime(value: 10, timescale: 1), frameRate: 29.97), 300)
        XCTAssertNil(GradedVideoExporter.plannedFrames(duration: .indefinite, frameRate: 30))
        XCTAssertNil(GradedVideoExporter.plannedFrames(duration: .invalid, frameRate: 30))
        XCTAssertNil(GradedVideoExporter.plannedFrames(duration: .positiveInfinity, frameRate: 30))
        // CoreMedia turns a NaN length into a zero time; it plans nothing.
        XCTAssertEqual(GradedVideoExporter.plannedFrames(duration: CMTime(seconds: .nan, preferredTimescale: 600), frameRate: 30) ?? 0, 0)
        XCTAssertNil(GradedVideoExporter.plannedFrames(duration: CMTime(value: 10, timescale: 1), frameRate: .nan))
        XCTAssertNil(GradedVideoExporter.plannedFrames(duration: CMTime(value: 10, timescale: 1), frameRate: nil))
        XCTAssertNil(GradedVideoExporter.plannedFrames(duration: CMTime(value: Int64.max / 2, timescale: 1), frameRate: 240), "an absurd length is no plan")
    }

    /// A 256×144, 12-frame, 24 fps HEVC clip with 16-bit stereo LPCM, a grey
    /// ramp standing in for a log picture.
    static func makeClip(at url: URL, frames: Int = 12) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = 256, height = 144
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        writer.add(video)
        writer.add(audio)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !video.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height {
                for x in 0..<width {
                    let v = UInt8(60 + x * 120 / width)
                    let p = base + y * stride + x * 4
                    p[0] = v; p[1] = v; p[2] = UInt8(min(255, Int(v) + frame)); p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 24)))
        }
        video.markAsFinished()
        // Half a second of silence.
        let sampleCount = 24_000
        var format: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: sampleCount * 4, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: sampleCount * 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: sampleCount * 4)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: sampleCount, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample)
        while !audio.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        XCTAssertTrue(audio.append(sample!))
        audio.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        _ = done.wait(timeout: .now() + 30)
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    private func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func testRendersAGradedCopyBesideTheOriginalWithoutTouchingIt() async throws {
        try await withTemporaryDirectoryAsync { root in
            let originals = root.appendingPathComponent("Buffer/2026/2026-06-01 Trip/Originals/A7V", isDirectory: true)
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            let source = originals.appendingPathComponent("C0001.MOV")
            try Self.makeClip(at: source)
            let stamp = Date(timeIntervalSince1970: 1_780_000_000)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: source.path)
            let originalHash = try sha(source)
            let edited = root.appendingPathComponent("Buffer/2026/2026-06-01 Trip/Edited", isDirectory: true)
            let request = GradedRenderRequest(
                source: source,
                recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine, range: .full),
                sourceKey: "C0001.MOV|1|1",
                sourceModifiedAt: stamp,
                outputFolder: GradedRenderNaming.outputFolder(editedRoot: edited),
                make: "Sony",
                model: "ILCE-7M5"
            )
            let exporter = GradedVideoExporter()
            exporter.requireHardwareEncoder = false
            let progressBox = ProgressBox()
            let first = try exporter.render(request, progress: { progressBox.add($0.fraction) })
            guard case .rendered(let url, let beside) = first else { return XCTFail("expected a render, got \(first)") }
            XCTAssertEqual(url.lastPathComponent, "C0001_709.mov")
            XCTAssertTrue(beside.isEmpty)
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Rec709")
            XCTAssertEqual(progressBox.last, 1, accuracy: 1e-9)
            XCTAssertEqual(try sha(source), originalHash, "the original is only read")

            // Readable, same size and length, HEVC tagged Rec.709, audio kept.
            let asset = AVURLAsset(url: url)
            let videoTrack = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
            let size = try await videoTrack.load(.naturalSize)
            XCTAssertEqual(size, CGSize(width: 256, height: 144))
            let originalDuration = try await AVURLAsset(url: source).load(.duration).seconds
            let copyDuration = try await asset.load(.duration).seconds
            XCTAssertEqual(copyDuration, originalDuration, accuracy: 0.1)
            let description = try await XCTUnwrapAsync(try await videoTrack.load(.formatDescriptions).first)
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_HEVC)
            let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]
            XCTAssertEqual(extensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String, kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
            XCTAssertEqual(extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String, kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audioTracks.count, 1)
            let audioFormat = try await XCTUnwrapAsync(try await audioTracks[0].load(.formatDescriptions).first)
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(audioFormat), kAudioFormatLinearPCM, "audio passed through, not re-encoded")

            // Capture time and grade are in the copy; it sorts by the same mtime.
            let tags = GradedVideoExporter.readTags(url)
            XCTAssertEqual(tags?.grade, request.recipe.fingerprint)
            XCTAssertEqual(tags?.source, request.sourceKey)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, stamp.timeIntervalSince1970, accuracy: 1)
            let metadata = try await asset.load(.metadata)
            var make: String?
            for item in metadata where item.identifier == .quickTimeMetadataMake { make = try await item.load(.stringValue) }
            XCTAssertEqual(make, "Sony")

            // No temporary file left behind.
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            XCTAssertEqual(leftovers, ["C0001_709.mov"])

            // Same original, same grade: skipped, nothing rewritten.
            let renderedHash = try sha(url)
            let second = try exporter.render(request)
            XCTAssertEqual(second, .alreadyRendered(url))
            XCTAssertEqual(try sha(url), renderedHash)

            // A changed grade gets the next free name; the first copy stays.
            var warmer = request
            warmer.recipe.grade.temperature = 30
            let third = try exporter.render(warmer)
            XCTAssertEqual(third.url.lastPathComponent, "C0001_709 (2).mov")
            XCTAssertEqual(third, .rendered(third.url, beside: [url]), "the older copy is reported, and kept")
            XCTAssertEqual(try sha(url), renderedHash, "never overwritten")

            // A graded pixel differs from the flat one.
            let generator = AVAssetImageGenerator(asset: asset)
            let gradedFrame = try await generator.image(at: CMTime(value: 6, timescale: 24)).image
            let flatFrame = try await AVAssetImageGenerator(asset: AVURLAsset(url: source)).image(at: CMTime(value: 6, timescale: 24)).image
            XCTAssertNotEqual(meanLuma(gradedFrame), meanLuma(flatFrame), accuracy: 0.01)
        }
    }

    func testStalePartialsAreClearedAndAMirroredRenderCounts() async throws {
        try await withTemporaryDirectoryAsync { root in
            let source = root.appendingPathComponent("Drive/2026/Trip/Originals/A7V/C0002.MOV")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.makeClip(at: source, frames: 6)
            let output = root.appendingPathComponent("Drive/2026/Trip/Edited/Rec709", isDirectory: true)
            let mirror = root.appendingPathComponent("NAS/2026/Trip/Edited/Rec709", isDirectory: true)

            // A crash left a partial and someone left an unrelated file.
            let temporary = output.appendingPathComponent(GradedRenderNaming.temporaryFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let stale = temporary.appendingPathComponent(GradedRenderNaming.partialName())
            try Data(repeating: 1, count: 1_000).write(to: stale)
            let unrelated = temporary.appendingPathComponent("notes.txt")
            try Data("keep".utf8).write(to: unrelated)
            XCTAssertTrue(GradedRenderNaming.isPartialName(stale.lastPathComponent))
            XCTAssertFalse(GradedRenderNaming.isPartialName("notes.txt"))
            XCTAssertFalse(GradedRenderNaming.isPartialName("x" + GradedRenderNaming.partialSuffix))
            XCTAssertTrue(GradedRenderNaming.isPartialName(stale.lastPathComponent + ".sb-45a471e7-abc"), "the writer's scratch copy")
            XCTAssertFalse(GradedRenderNaming.isPartialName("C0001_709.mov.sb-1"))
            XCTAssertTrue(NASSyncPlanner.isJunk(stale.lastPathComponent))

            XCTAssertEqual(GradedRenderNaming.removeStalePartials(in: output), 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "only the exporter's own partials go")
            try FileManager.default.removeItem(at: unrelated)

            let exporter = GradedVideoExporter()
            exporter.requireHardwareEncoder = false
            var request = GradedRenderRequest(
                source: source, recipe: GradeRecipe(grade: .converted, profile: .sLog3SGamut3Cine, range: .full),
                sourceKey: "C0002.MOV|1|1", sourceModifiedAt: Date(timeIntervalSince1970: 1_780_000_000),
                outputFolder: output, mirrorFolder: mirror
            )
            // Render once, then make it look as if Sync carried it to the
            // NAS and the drive copy is gone.
            let made = try exporter.render(request).url
            try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: made, to: mirror.appendingPathComponent(made.lastPathComponent))
            XCTAssertEqual(try exporter.render(request), .alreadyRendered(mirror.appendingPathComponent("C0002_709.mov")), "the NAS copy counts")
            XCTAssertFalse(FileManager.default.fileExists(atPath: made.path), "nothing re-rendered on the drive")

            // Another grade: the NAS's name is not reused on the drive.
            request.recipe.grade.exposure = 1
            let next = try exporter.render(request)
            XCTAssertEqual(next.url.lastPathComponent, "C0002_709 (2).mov")
            XCTAssertEqual(next.url.deletingLastPathComponent().standardizedFileURL.path, output.standardizedFileURL.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path), "the temporary folder goes once empty")
        }
    }

    func testAnUnreadableTakenNameIsNeverRenderedBeside() {
        let source = URL(fileURLWithPath: "/Volumes/Buffer/C0001.MP4")
        let folder = URL(fileURLWithPath: "/Volumes/Buffer/Edited/Rec709")
        let result = GradedRenderNaming.resolve(source: source, folder: folder, exists: { $0.lastPathComponent == "C0001_709.mov" }, identity: { _ in .unknown })
        XCTAssertEqual(result, .undecided(folder.appendingPathComponent("C0001_709.mov")))
    }

    func testBitRateFollowsTheOriginalWithinBounds() {
        XCTAssertEqual(GradedVideoExporter.bitRate(sourceDataRate: 100_000_000), 75_000_000)
        XCTAssertEqual(GradedVideoExporter.bitRate(sourceDataRate: 1_000_000), 8_000_000)
        XCTAssertEqual(GradedVideoExporter.bitRate(sourceDataRate: 400_000_000), 150_000_000)
        XCTAssertEqual(GradedVideoExporter.bitRate(sourceDataRate: 0), 40_000_000)
    }

    private func meanLuma(_ image: CGImage) -> Double {
        let w = 32, h = 18
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in stride(from: 0, to: data.count, by: 4) { sum += Double(data[i + 1]) / 255 }
        return sum / Double(w * h)
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var last: Double { lock.withLock { values.last ?? 0 } }
}

func withTemporaryDirectoryAsync(_ body: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CameraToolkitGrade-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
