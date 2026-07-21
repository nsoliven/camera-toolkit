import CameraToolkitCore
import Foundation

enum EventCopyAvailabilityPhase: Equatable, Sendable {
    case idle
    case checking
    case ready
}

struct EventCopyAvailability: Equatable, Sendable {
    var phase: EventCopyAvailabilityPhase = .idle
    var contextID: String = ""
    var assignedCount: Int = 0
    var presentFiles: [FileRecord] = []
    var filesReadyToCopy: [FileRecord] = []
    var alreadyInBufferCount: Int = 0
    var missingFromSourceCount: Int = 0
    var changedOnSourceCount: Int = 0
    var bufferConflictCount: Int = 0
    var scheduledCount: Int = 0
    var sourceIsUnavailable: Bool = false
    var bufferIsUnavailable: Bool = false

    var hasFilesReadyToCopy: Bool {
        !filesReadyToCopy.isEmpty
    }

    static func checking(contextID: String, assignedCount: Int) -> EventCopyAvailability {
        EventCopyAvailability(
            phase: .checking,
            contextID: contextID,
            assignedCount: assignedCount
        )
    }
}

enum EventCopyAvailabilityScanner {
    static func scan(
        contextID: String,
        files: [FileRecord],
        sourceRoot: URL,
        bufferRoot: URL,
        scheduledPaths: Set<String> = []
    ) -> EventCopyAvailability {
        let fileManager = FileManager.default
        var result = EventCopyAvailability(
            phase: .ready,
            contextID: contextID,
            assignedCount: files.count
        )

        guard volumeIsAvailableIfExternal(sourceRoot, fileManager: fileManager),
              fileManager.fileExists(atPath: sourceRoot.standardizedFileURL.path) else {
            result.sourceIsUnavailable = true
            return result
        }
        let bufferIsAvailable = volumeIsAvailableIfExternal(bufferRoot, fileManager: fileManager)
        result.bufferIsUnavailable = !bufferIsAvailable

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]

        for file in files.sorted(by: { $0.path < $1.path }) {
            if Task.isCancelled { break }
            guard (try? PathSafety.validateRelativePath(file.path)) != nil else {
                result.changedOnSourceCount += 1
                continue
            }

            let sourceURL = sourceRoot.appendingPathComponent(file.path)
            guard let sourceValues = try? sourceURL.resourceValues(forKeys: keys),
                  sourceValues.isRegularFile == true else {
                result.missingFromSourceCount += 1
                continue
            }

            let actualSize = Int64(sourceValues.fileSize ?? -1)
            guard actualSize == file.size else {
                result.changedOnSourceCount += 1
                continue
            }

            let currentFile = FileRecord(
                path: file.path,
                size: actualSize,
                modifiedAt: sourceValues.contentModificationDate ?? file.modifiedAt
            )
            result.presentFiles.append(currentFile)

            guard bufferIsAvailable else { continue }

            if scheduledPaths.contains(file.path) {
                result.scheduledCount += 1
                continue
            }

            let bufferURL = bufferRoot.appendingPathComponent(file.path)
            guard fileManager.fileExists(atPath: bufferURL.path) else {
                result.filesReadyToCopy.append(currentFile)
                continue
            }

            let bufferValues = try? bufferURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if bufferValues?.isRegularFile == true,
               Int64(bufferValues?.fileSize ?? -1) == actualSize {
                result.alreadyInBufferCount += 1
            } else {
                result.bufferConflictCount += 1
            }
        }

        return result
    }

    private static func volumeIsAvailableIfExternal(_ url: URL, fileManager: FileManager) -> Bool {
        let standardized = url.standardizedFileURL
        let components = standardized.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else {
            return true
        }

        let volumeRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            .appendingPathComponent(components[2], isDirectory: true)
            .standardizedFileURL.path
        let mountedVolumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) ?? []
        return mountedVolumes.contains { $0.standardizedFileURL.path == volumeRoot }
    }
}
