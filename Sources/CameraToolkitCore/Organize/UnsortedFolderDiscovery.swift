import Foundation

public struct UnsortedFolderCandidate: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var volumeName: String
    public var cameraFileCount: Int
    public var byteCount: Int64
    public var isCameraCard: Bool
    /// Looks like a card or a folder of card dumps rather than finished work.
    public var isSuggested: Bool

    public init(
        path: String,
        name: String,
        volumeName: String,
        cameraFileCount: Int,
        byteCount: Int64,
        isCameraCard: Bool,
        isSuggested: Bool
    ) {
        self.path = path
        self.name = name
        self.volumeName = volumeName
        self.cameraFileCount = cameraFileCount
        self.byteCount = byteCount
        self.isCameraCard = isCameraCard
        self.isSuggested = isSuggested
    }
}

/// Finds camera cards and top-level photo folders on connected drives that
/// could be added as unsorted sources. It only lists and counts files.
public enum UnsortedFolderDiscovery {
    static let hintWords = ["unparsed", "unsorted", "import", "dump", "transfer", "card", "dcim", "inbox", "to sort"]
    static let skippedNames: Set<String> = [
        "$recycle.bin", "system volume information", ".camera toolkit", "_trash", ".trashes", ".spotlight-v100", ".fseventsd"
    ]

    public static func looksUnsorted(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return hintWords.contains { lowered.contains($0) }
    }

    public static func candidates(
        volumeRoots: [URL],
        excludedRoots: [URL],
        alreadyAddedPaths: [String],
        entryLimit: Int = 250_000,
        fileManager: FileManager = .default
    ) -> [UnsortedFolderCandidate] {
        let excluded = excludedRoots.map { EventStorageLocations.pathKey($0.path) }
        let added = Set(alreadyAddedPaths.map(EventStorageLocations.pathKey))
        var results: [UnsortedFolderCandidate] = []

        for volume in volumeRoots {
            let volumeName = volume.lastPathComponent
            if isDirectory(volume.appendingPathComponent("DCIM", isDirectory: true), fileManager: fileManager) {
                guard !added.contains(EventStorageLocations.pathKey(volume.path)) else { continue }
                let counted = countCameraFiles(in: volume, limit: entryLimit, fileManager: fileManager)
                if counted.files > 0 {
                    results.append(UnsortedFolderCandidate(
                        path: volume.standardizedFileURL.path,
                        name: volumeName,
                        volumeName: volumeName,
                        cameraFileCount: counted.files,
                        byteCount: counted.bytes,
                        isCameraCard: true,
                        isSuggested: true
                    ))
                }
                continue
            }

            let children = (try? fileManager.contentsOfDirectory(
                at: volume,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let name = child.lastPathComponent
                guard isDirectory(child, fileManager: fileManager),
                      !skippedNames.contains(name.lowercased()) else { continue }
                let key = EventStorageLocations.pathKey(child.path)
                guard !added.contains(key),
                      !excluded.contains(where: { $0 == key || $0.hasPrefix(key + "/") || key.hasPrefix($0 + "/") }) else { continue }
                let counted = countCameraFiles(in: child, limit: entryLimit, fileManager: fileManager)
                guard counted.files > 0 else { continue }
                let hasCard = isDirectory(child.appendingPathComponent("DCIM", isDirectory: true), fileManager: fileManager)
                results.append(UnsortedFolderCandidate(
                    path: child.standardizedFileURL.path,
                    name: name,
                    volumeName: volumeName,
                    cameraFileCount: counted.files,
                    byteCount: counted.bytes,
                    isCameraCard: hasCard,
                    isSuggested: hasCard || looksUnsorted(name)
                ))
            }
        }

        return results.sorted { lhs, rhs in
            if lhs.isSuggested != rhs.isSuggested { return lhs.isSuggested }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func countCameraFiles(in root: URL, limit: Int, fileManager: FileManager) -> (files: Int, bytes: Int64) {
        let cameraExtensions = OrganizeFileClassifier.rawExtensions
            .union(OrganizeFileClassifier.photoExtensions)
            .union(OrganizeFileClassifier.videoExtensions)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return (0, 0) }

        var visited = 0
        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > limit { break }
            guard cameraExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (files, bytes)
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
