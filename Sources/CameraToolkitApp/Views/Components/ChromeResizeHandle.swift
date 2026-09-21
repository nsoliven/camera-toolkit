import AppKit
import SwiftUI

/// A hairline divider with a fat hit area that drags the edge of a pane —
/// the same pattern as the file browser's preview-pane handle, generalized
/// for vertical dividers (sidebar width) and horizontal ones (strip
/// height). The bound value is usually AppStorage-backed so the size
/// sticks across launches.
struct ChromeResizeHandle: View {
    /// Which way the divider runs: `.vertical` sits between left and right
    /// panes and drags horizontally; `.horizontal` sits between top and
    /// bottom panes and drags vertically.
    enum Orientation {
        case vertical
        case horizontal
    }

    /// Hit-area thickness; the drawn line stays a hairline.
    static let thickness: CGFloat = 10

    let orientation: Orientation
    @Binding var value: Double
    /// Maps a raw drag request to the stored size — clamps, snap points,
    /// and dead zones live here so the handle stays dumb.
    var transform: (Double) -> Double = { $0 }
    /// NSSplitView-style double-click on the divider (two presses that end
    /// without moving). Nil disables the gesture.
    var onDoubleClick: (() -> Void)? = nil
    var help: String
    var accessibilityLabel: String

    @State private var dragOrigin: Double?
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var lastClickAt: Date?

    private var isActive: Bool { isHovering || isDragging }

    var body: some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 1)
                .fill(isActive ? Color.accentColor : Color.primary.opacity(0.2))
                .frame(
                    width: orientation == .vertical ? (isActive ? 3 : 1) : nil,
                    height: orientation == .horizontal ? (isActive ? 3 : 1) : nil
                )
        }
        .frame(
            width: orientation == .vertical ? Self.thickness : nil,
            height: orientation == .horizontal ? Self.thickness : nil
        )
        .frame(
            maxWidth: orientation == .horizontal ? .infinity : nil,
            maxHeight: orientation == .vertical ? .infinity : nil
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if dragOrigin == nil {
                        dragOrigin = value
                    }
                    let translation = orientation == .vertical ? gesture.translation.width : gesture.translation.height
                    if translation != 0 {
                        isDragging = true
                    }
                    value = transform((dragOrigin ?? value) + translation)
                }
                .onEnded { gesture in
                    let translation = orientation == .vertical ? abs(gesture.translation.width) : abs(gesture.translation.height)
                    if translation < 2 {
                        // A press that never moved is a click — two in a row
                        // are the divider double-click.
                        let now = Date()
                        if let lastClickAt, now.timeIntervalSince(lastClickAt) < 0.4 {
                            self.lastClickAt = nil
                            onDoubleClick?()
                        } else {
                            lastClickAt = now
                        }
                    }
                    dragOrigin = nil
                    isDragging = false
                }
        )
        .onHover { hovering in
            isHovering = hovering
            let cursor: NSCursor = orientation == .vertical ? .resizeLeftRight : .resizeUpDown
            (hovering ? cursor : .arrow).set()
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(Int(value)) points")
    }
}
