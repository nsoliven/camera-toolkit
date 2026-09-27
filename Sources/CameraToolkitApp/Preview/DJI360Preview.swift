import CameraToolkitCore
import SwiftUI

/// What the preview is actually playing for an Osmo 360 clip — decided
/// from the scan's companions, never the filesystem.
enum DJI360PreviewKind: Equatable {
    /// The stitched LRF proxy: the whole sphere, flat equirectangular,
    /// at 2048×1024.
    case proxy
    /// No LRF beside the OSV: AVFoundation plays the OSV's first enabled
    /// track, which is one raw fisheye lens.
    case lensOnly

    init?(item: OrganizeItem) {
        guard DJI360Media.isClip(item.primary.url) else { return nil }
        self = DJI360Media.proxy(for: item) == nil ? .lensOnly : .proxy
    }

    var title: String {
        switch self {
        case .proxy: "360° preview (low-res proxy)"
        case .lensOnly: "One fisheye lens only"
        }
    }

    /// The full label, naming DJI Studio as the place for full quality.
    func caption(studioAvailable: Bool) -> String {
        switch self {
        case .proxy:
            studioAvailable
                ? "\(title) — open in DJI Studio for full quality"
                : "\(title) — full quality needs DJI Studio"
        case .lensOnly:
            studioAvailable
                ? "\(title) — no LRF proxy beside this clip. Open in DJI Studio for the full 360°"
                : "\(title) — no LRF proxy beside this clip. The full 360° needs DJI Studio"
        }
    }

    /// The look-around sphere needs a stitched frame.
    var supportsSphericalView: Bool { self == .proxy }
}

/// The glass strip over a 360 clip's player: what is playing, the
/// look-around toggle, and the DJI Studio hand-off.
struct DJI360PreviewBanner: View {
    let kind: DJI360PreviewKind
    let studioAvailable: Bool
    @Binding var sphericalView: Bool
    let onOpenInStudio: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label(kind.caption(studioAvailable: studioAvailable), systemImage: "pano")
                .font(.callout)
                .lineLimit(2)
            if kind.supportsSphericalView {
                Toggle("Look Around", systemImage: "rotate.3d", isOn: $sphericalView)
                    .toggleStyle(.button)
                    .help(sphericalView
                        ? "Show the flat equirectangular frame"
                        : "Look around the 360° proxy — drag to turn, pinch or scroll to zoom")
            }
            if studioAvailable {
                Button("Open in \(DJIStudio.name)", action: onOpenInStudio)
                    .help(DJIStudio.help)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }
}
