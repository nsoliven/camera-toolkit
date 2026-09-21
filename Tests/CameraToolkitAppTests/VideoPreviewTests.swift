import AVFoundation
import AVKit
import Foundation
@testable import CameraToolkitApp
import XCTest

/// The burst overlay's video path must never abort the process. These
/// tests exercise the same calls `StackPreviewOverlay` makes — probe,
/// player item, `AVPlayerView` — against a synthetic clip written by
/// `AVAssetWriter` (a few generated frames, never camera media).
@MainActor
final class VideoPreviewTests: XCTestCase {

    func testSyntheticClipBuildsReadyPlayerAndView() async throws {
        let url = try await Self.writeSyntheticClip()
        defer { try? FileManager.default.removeItem(at: url) }

        // The overlay's whole "playable" path: bounded probe → ready
        // player.
        let probed = await VideoPreviewSupport.readyPlayer(for: url)
        let player = try XCTUnwrap(probed)
        XCTAssertEqual(player.status, .readyToPlay)

        // …then the pane construction that used to abort inside
        // _AVKit_SwiftUI. Building the AppKit view here proves the path
        // is metadata-safe.
        let pane = VideoPreviewPane(player: player)
        let view = VideoPreviewPane.makePlayerView(player: pane.player)
        XCTAssertTrue(view.player === player)
        XCTAssertEqual(view.controlsStyle, .floating)
    }

    func testProbeRejectsBytesThatAreNotAMovie() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitVideoProbe-\(UUID().uuidString).mp4")
        try Data("definitely not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = await VideoPreviewSupport.readyPlayer(for: url)
        XCTAssertNil(player)
    }

    func testProbeRejectsAMissingFile() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitVideoProbe-\(UUID().uuidString).mp4")
        let player = await VideoPreviewSupport.readyPlayer(for: url)
        XCTAssertNil(player)
    }

    /// A bounded probe must actually return when the budget is zero —
    /// the timeout task wins the race instead of hanging the pane.
    func testZeroBudgetProbeReturnsFalse() async throws {
        let url = try await Self.writeSyntheticClip()
        defer { try? FileManager.default.removeItem(at: url) }
        let playable = await VideoPreviewSupport.isPlayable(AVURLAsset(url: url), timeout: .zero)
        XCTAssertFalse(playable)
    }

    // MARK: - Synthetic clip

    /// Writes a few solid-color H.264 frames into a temp .mp4. Frames are
    /// generated pixel buffers — no real footage is read or written.
    private static func writeSyntheticClip(
        frames: Int = 12,
        fps: Int32 = 12,
        width: Int = 128,
        height: Int = 96
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitSyntheticClip-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        guard writer.canAdd(input) else {
            throw ClipError.unwritable
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ClipError.unwritable
        }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let buffer = try makePixelBuffer(width: width, height: height, seed: index)
            let time = CMTime(value: CMTimeValue(index), timescale: fps)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? ClipError.unwritable
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? ClipError.unwritable
        }
        return url
    }

    /// A BGRA buffer filled with a deterministic gradient that shifts per
    /// `seed` so consecutive frames differ.
    private static func makePixelBuffer(width: Int, height: Int, seed: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw ClipError.noBuffer
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                row[x * 4 + 0] = UInt8((x * 2 + seed * 16) % 256)
                row[x * 4 + 1] = UInt8((y * 2 + seed * 8) % 256)
                row[x * 4 + 2] = UInt8((96 + seed * 4) % 256)
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    private enum ClipError: Error {
        case unwritable
        case noBuffer
    }
}
