import Foundation

/// Persisted chrome sizes for the Organize window — the sidebar column
/// width. The value lives in UserDefaults; this enum holds the key, range,
/// and read/write rules so views and tests agree on the numbers.
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
}
