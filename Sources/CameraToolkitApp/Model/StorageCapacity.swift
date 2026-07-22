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

    nonisolated static func read(path: String, fileManager: FileManager = .default) -> StorageCapacitySnapshot? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        let url = URL(fileURLWithPath: expandedPath, isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsLocalKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              total > 0 else {
            return nil
        }

        let importantUsageAvailable = values.volumeAvailableCapacityForImportantUsage ?? 0
        let basicAvailable = values.volumeAvailableCapacity.map(Int64.init) ?? 0
        let available = max(importantUsageAvailable, basicAvailable)
        return StorageCapacitySnapshot(
            availableBytes: min(max(available, 0), Int64(total)),
            totalBytes: Int64(total),
            source: values.volumeIsLocal == false ? .networkShareEstimate : .localVolume
        )
    }
}
