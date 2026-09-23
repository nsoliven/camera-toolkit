import Foundation

enum StorageCapacitySource: Equatable, Sendable {
    case localVolume
    case networkShareEstimate
    case trueNAS(
        dataset: String,
        pool: String,
        poolAvailableBytes: Int64,
        poolTotalBytes: Int64,
        poolHealthy: Bool
    )
}

struct StorageCapacitySnapshot: Equatable, Sendable {
    var availableBytes: Int64
    var totalBytes: Int64
    var source: StorageCapacitySource = .localVolume

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(totalBytes - availableBytes) / Double(totalBytes), 0), 1)
    }

    var availableFraction: Double {
        1 - usedFraction
    }
}

enum StorageCapacityReader {
    nonisolated static func mountedVolumeName(for path: String) -> String? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let components = URL(fileURLWithPath: expandedPath).standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        return components[2]
    }

}
