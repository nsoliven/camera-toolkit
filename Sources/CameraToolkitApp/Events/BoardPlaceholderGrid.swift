import SwiftUI

/// Blank tiles standing in for photos that are still being found. Shown
/// while an event's files are loading and a drive that holds them is up —
/// the board never says "not connected" about a load that has not finished.
/// Nothing here touches the filesystem.
struct BoardPlaceholderGrid: View {
    let title: String
    /// How many files the event owns; only sizes the number of blanks.
    let count: Int
    let tileWidth: Double

    /// Enough blanks to fill a large window, never a wall of thousands.
    private var blankCount: Int { min(max(count, 1), 60) }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth * 1.3), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(0..<blankCount, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary.opacity(0.5))
                        .aspectRatio(3 / 2, contentMode: .fit)
                }
            }
            .padding(16)
        }
        .scrollDisabled(true)
        .allowsHitTesting(false)
        .overlay(alignment: .top) {
            ProgressView(title)
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityIdentifier("eventBoardLoading")
    }
}
