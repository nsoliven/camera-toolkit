import AVFoundation
import AVKit
import CameraToolkitCore
import SwiftUI

/// Bounded playability probing for the burst overlay's video pane. Every
/// stage has a wall-clock cap so an unopenable codec or a stalled source
/// (sleeping NAS, missing volume) degrades to the poster plus the
/// can't-play affordances instead of a permanent spinner.
enum VideoPreviewSupport {
    /// Cap on `AVAsset.load(.isPlayable)`.
    static let playableTimeout: Duration = .seconds(15)
    /// Cap on waiting for a created player item to reach `readyToPlay`.
    static let readinessTimeout: Duration = .seconds(15)

    /// Returns a player whose current item is actually ready to render, or
    /// nil when the clip isn't playable or never became ready inside the
    /// budget. The item is only built after `isPlayable` confirms
    /// AVFoundation can open the file — probing first keeps unopenable
    /// files out of the player machinery entirely. Readiness must be
    /// observed on an attached player: a detached `AVPlayerItem` never
    /// leaves `.unknown`.
    static func readyPlayer(
        for url: URL,
        playableTimeout: Duration = playableTimeout,
        readinessTimeout: Duration = readinessTimeout
    ) async -> AVPlayer? {
        let asset = AVURLAsset(url: url)
        let start = ContinuousClock.now
        guard await isPlayable(asset, timeout: playableTimeout) else {
            DebugLog.shared.log(
                "probe.finish",
                subsystem: .video,
                level: .warning,
                outcome: .error,
                duration: ContinuousClock.now - start,
                url: url,
                error: "not proven playable"
            )
            return nil
        }
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        guard await waitUntilReady(player, timeout: readinessTimeout) else {
            DebugLog.shared.log(
                "probe.finish",
                subsystem: .video,
                level: .warning,
                outcome: .timeout,
                duration: ContinuousClock.now - start,
                url: url,
                error: "player never reached readyToPlay"
            )
            return nil
        }
        DebugLog.shared.log(
            "probe.finish",
            subsystem: .video,
            outcome: .ok,
            duration: ContinuousClock.now - start,
            url: url
        )
        return player
    }

    /// `AVAsset` predates `Sendable`, but its async property loads and
    /// `cancelLoading()` are explicitly thread-safe — the box only carries
    /// the reference into the probe task.
    private struct AssetBox: @unchecked Sendable {
        let asset: AVAsset
    }

    /// Which probe task answered first — the asset verdict or the clock —
    /// so the log can tell a dead codec from a stalled source.
    private enum ProbeResult: Sendable {
        case answered(Bool)
        case timedOut
    }

    /// `asset.load(.isPlayable)` under a deadline. On timeout the
    /// underlying load is cancelled so the task group isn't kept alive by
    /// it; a false result always means "not proven playable", whether the
    /// codec failed or the clock ran out — the log records which one won.
    static func isPlayable(_ asset: AVAsset, timeout: Duration) async -> Bool {
        let box = AssetBox(asset: asset)
        let url = (asset as? AVURLAsset)?.url
        let start = ContinuousClock.now
        let result = await withTaskGroup(of: ProbeResult.self) { group in
            group.addTask { .answered((try? await box.asset.load(.isPlayable)) ?? false) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            asset.cancelLoading()
            return first
        }
        switch result {
        case .answered(let playable):
            DebugLog.shared.log(
                "playable.finish",
                subsystem: .video,
                level: playable ? .debug : .warning,
                outcome: playable ? .ok : .error,
                duration: ContinuousClock.now - start,
                url: url,
                error: playable ? nil : "asset not playable"
            )
            return playable
        case .timedOut:
            DebugLog.shared.log(
                "playable.finish",
                subsystem: .video,
                level: .warning,
                outcome: .timeout,
                duration: ContinuousClock.now - start,
                url: url,
                error: "isPlayable probe timed out"
            )
            return false
        }
    }

    /// Polls the player's status until it leaves `unknown`, with a
    /// deadline. Polling (rather than KVO) keeps the wait
    /// cancellation-responsive and free of observer lifetime bookkeeping.
    static func waitUntilReady(_ player: AVPlayer, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while player.status == .unknown {
            if Task.isCancelled || ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return player.status == .readyToPlay
    }
}

/// The overlay's video surface: AVKit's `AVPlayerView` wrapped directly.
/// SwiftUI's own `VideoPlayer` is not used — in this packaged binary its
/// `_AVKit_SwiftUI` representable aborts the process while SwiftUI resolves
/// the view's associated types (`getSuperclassMetadata` → `swift::fatalError`
/// inside `NSViewRepresentable._makeView`). `AVPlayerView` is a plain AppKit
/// class, so wrapping it ourselves keeps playback with standard chrome and
/// skips the metadata path that crashed.
struct VideoPreviewPane: NSViewRepresentable {
    let player: AVPlayer?

    /// Shared construction so the representable and tests build the view
    /// identically.
    static func makePlayerView(player: AVPlayer?) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFrameSteppingButtons = false
        return view
    }

    func makeNSView(context: Context) -> AVPlayerView {
        Self.makePlayerView(player: player)
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player = nil
    }
}
