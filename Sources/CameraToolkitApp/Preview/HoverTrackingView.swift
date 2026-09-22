import AppKit
import SwiftUI

/// An invisible region that reports pointer enter/exit while staying
/// transparent to clicks — the face overlay's proximity targets need both
/// at once, and SwiftUI cannot express that: `allowsHitTesting(false)`
/// silences `onHover` along with the clicks, while a hit-testable target
/// would swallow the clicks that drive the canvas's zoom and pan. AppKit
/// separates the two — an `NSTrackingArea` fires geometrically regardless
/// of hit-testing, and `hitTest` returning nil lets every click fall
/// through to whatever is underneath.
struct HoverTrackingView: NSViewRepresentable {
    /// Called with `true` when the pointer enters the region, `false`
    /// when it leaves.
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        let view = HoverTrackingNSView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: HoverTrackingNSView, context: Context) {
        view.onChange = onChange
    }
}

/// The platform half of `HoverTrackingView`: owns the tracking area and
/// reports crossings, but never draws and never appears in a hit-test
/// chain — invisibility comes from having no content, not from an opacity
/// trick.
final class HoverTrackingNSView: NSView {
    var onChange: (Bool) -> Void = { _ in }

    /// Whether the pointer is currently inside — deduped so a stray
    /// double-enter can't fire the same edge twice.
    private(set) var inside = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // `.inVisibleRect` keeps the tracked rect glued to the frame as
        // zoom, pan, and layout move it; `.activeAlways` pairs every
        // enter with an exit even across window key changes.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Clicks pass through — this view exists for hover only.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) {
        setInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        setInside(false)
    }

    func setInside(_ newValue: Bool) {
        guard newValue != inside else { return }
        inside = newValue
        onChange(newValue)
    }
}
