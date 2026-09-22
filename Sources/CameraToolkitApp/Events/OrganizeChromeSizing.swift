import Foundation

/// Persisted chrome sizes for the Organize window — the sidebar column
/// width and the event board's storage-strip height. The values live in
/// AppStorage; this enum holds the keys, ranges, and the strip's snap
/// behavior so views and tests agree on the numbers.
enum OrganizeChromeSizing {
    /// Sidebar column between the event/source list and the board.
    static let sidebarWidthDefaultsKey = "CameraToolkit.organize.sidebarWidth"
    static let defaultSidebarWidth = 300.0
    static let sidebarWidthRange = 220.0...480.0

    /// Event board storage strip. Below the snap threshold the strip rests
    /// as a one-line summary bar; at or above it, it shows the four cards.
    static let storageStripDefaultsKey = "CameraToolkit.organize.storageStripHeight"
    static let collapsedStorageStripHeight = 40.0
    static let minimumExpandedStorageStripHeight = 152.0
    /// Comfortable card height a double-click or the expand button opens to.
    static let defaultExpandedStorageStripHeight = 176.0
    static let maximumStorageStripHeight = 320.0
    static let storageStripSnapThreshold = 96.0

    static var storageStripRange: ClosedRange<Double> {
        collapsedStorageStripHeight...maximumStorageStripHeight
    }

    static func clampedSidebarWidth(_ requested: Double) -> Double {
        min(max(requested, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
    }

    static func storageStripIsCollapsed(_ height: Double) -> Bool {
        height < storageStripSnapThreshold
    }

    /// What a drag should store: below the snap threshold the strip settles
    /// on the one-line bar; above it the value clamps into the card range.
    /// Applied to the stored value too, so a stale or hand-edited default in
    /// the dead zone still renders collapsed instead of half-open cards.
    static func coercedStorageStripHeight(_ requested: Double) -> Double {
        if requested < storageStripSnapThreshold {
            return collapsedStorageStripHeight
        }
        return min(max(requested, minimumExpandedStorageStripHeight), maximumStorageStripHeight)
    }
}
