import Foundation

/// Chrome sizes for the Organize window — the persisted sidebar column
/// width and the limit on a board's top bar. The width lives in
/// UserDefaults; this enum holds the key, ranges, and rules so views and
/// tests agree on the numbers.
enum OrganizeChromeSizing {
    /// Sidebar column between the event/source list and the board.
    static let sidebarWidthDefaultsKey = "CameraToolkit.organize.sidebarWidth"
    static let defaultSidebarWidth = 300.0
    static let sidebarWidthRange = 220.0...480.0

    static func clampedSidebarWidth(_ requested: Double) -> Double {
        min(max(requested, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
    }

    /// The width the split view opens with — read once when the window is
    /// built, so a write during a drag never moves the column's ideal width
    /// under the pointer.
    static func storedSidebarWidth(in defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: sidebarWidthDefaultsKey) != nil else { return defaultSidebarWidth }
        return clampedSidebarWidth(defaults.double(forKey: sidebarWidthDefaultsKey))
    }

    /// What a measured column width should store, or nil when it should not
    /// be stored at all: a width below the range is the column collapsing
    /// or animating closed, not a size the owner picked.
    static func persistableSidebarWidth(_ measured: Double) -> Double? {
        guard measured.isFinite, measured >= sidebarWidthRange.lowerBound else { return nil }
        return clampedSidebarWidth(measured.rounded())
    }

    /// The largest share of a board's height its top bar's notices and
    /// chips may take before they scroll inside the bar. Without a limit
    /// the bar grows with the event (every subevent, person, and camera is
    /// a chip), and a bar taller than the window pushes the whole window's
    /// content up under the title bar.
    static let boardAccessoryMaximumShare = 1.0 / 3.0

    /// How tall the scrolling part of a board's top bar may get on a board
    /// `boardHeight` tall; unlimited until the board has been measured.
    static func boardAccessoryHeightLimit(boardHeight: Double?) -> Double {
        guard let boardHeight, boardHeight.isFinite, boardHeight > 0 else { return .infinity }
        return (boardHeight * boardAccessoryMaximumShare).rounded(.down)
    }
}
