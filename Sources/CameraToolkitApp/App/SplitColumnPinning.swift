import SwiftUI

extension View {
    /// Keeps a split view column's content from setting the window's
    /// content height.
    ///
    /// `NavigationSplitView` asks each column for its minimum height at
    /// zero width. At that width a wrapping `Text` breaks after every
    /// character, so a column whose minimum follows its content (a
    /// `safeAreaBar` footer with a line of text, a top bar with a notice)
    /// can report thousands of points. When that minimum is taller than
    /// the window, the hosting view lays the whole split view out taller
    /// than the window and centers it. Both columns then slide up under the
    /// title bar together: the sidebar's first rows go behind the traffic
    /// lights, its footer drops off the bottom, and the board's first
    /// section goes under the toolbar. It comes and goes with whatever the
    /// column shows.
    ///
    /// A flexible frame with a zero minimum takes the height it is offered
    /// instead, so the column always fills the window and no more.
    /// `clipped` also cuts content that is still too tall at the column's
    /// real size; the detail column wants that, while the sidebar keeps
    /// drawing its glass edge and selection unclipped.
    func pinnedSplitColumn(alignment: Alignment = .top, clipped: Bool = false) -> some View {
        frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: alignment)
            .modifier(OptionalClip(isActive: clipped))
    }
}

private struct OptionalClip: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.clipped()
        } else {
            content
        }
    }
}
