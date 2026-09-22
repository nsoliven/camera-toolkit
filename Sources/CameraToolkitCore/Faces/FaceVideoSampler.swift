import AVFoundation
import CoreGraphics
import Foundation

/// Reads sampled frames out of a video file for MED/HIGH passes. Each clip
/// gets its own sampler inside a scan worker; frames are decoded serially
/// with `AVAssetImageGenerator` — no GPU pinning, media stays read-only.
public final class FaceVideoSampler {
    private let generator: AVAssetImageGenerator
    /// Native clip dimensions with the track transform applied — the frame
    /// space boxes and the min-face floor are measured in.
    public let pixelSize: CGSize
    public let duration: TimeInterval

    public init?(url: URL, maximumPixelSize: Int) {
        let asset = AVURLAsset(url: url)
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(
            width: maximumPixelSize,
            height: maximumPixelSize
        )
        var pixelSize = CGSize(width: 0, height: 0)
        if let track = asset.tracks(withMediaType: .video).first {
            let natural = track.naturalSize.applying(track.preferredTransform)
            pixelSize = CGSize(width: abs(natural.width), height: abs(natural.height))
        }
        self.generator = generator
        self.duration = duration
        self.pixelSize = pixelSize
    }

    /// Evenly spaced sample times: first frame at half a stride, then every
    /// `stride` seconds, capped at `maxFrames`. A clip shorter than one
    /// stride contributes a single mid-clip frame.
    public static func sampleTimes(
        duration: TimeInterval,
        stride: TimeInterval,
        maxFrames: Int
    ) -> [TimeInterval] {
        guard duration > 0, stride > 0, maxFrames > 0 else { return [] }
        var times: [TimeInterval] = []
        var time = min(stride / 2, duration / 2)
        while time < duration && times.count < maxFrames {
            times.append(time)
            time += stride
        }
        return times
    }

    /// The frame nearest `time`, or nil when the decoder cannot produce it.
    public func frame(at time: TimeInterval) -> CGImage? {
        try? generator.copyCGImage(
            at: CMTime(seconds: time, preferredTimescale: 600),
            actualTime: nil
        )
    }
}
