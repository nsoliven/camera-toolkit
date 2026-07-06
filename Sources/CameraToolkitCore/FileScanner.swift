import CryptoKit
import Foundation

public struct FileScanner {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(root: URL, excludes: [String] = DefaultExcludes.all, hashing: Bool = false) throws -> [FileRecord] {
        try assertDirectory(root)

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [],
            errorHandler: nil
        ) else {
            return []
        }

        var records: [FileRecord] = []

        for case let url as URL in enumerator {
            let relativePath = Self.relativePath(for: url, under: root)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])

            if values.isDirectory == true {
                if ExclusionMatcher.isExcluded(relativePath, excludes: excludes) ||
                    ExclusionMatcher.isExcluded(relativePath + "/**", excludes: excludes) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true else {
                continue
            }

            if ExclusionMatcher.isExcluded(relativePath, excludes: excludes) {
                continue
            }

            let size = Int64(values.fileSize ?? 0)
            let modifiedAt = values.contentModificationDate ?? .distantPast
            let digest = hashing ? try Self.sha256(url) : nil
            records.append(FileRecord(path: relativePath, size: size, modifiedAt: modifiedAt, sha256: digest))
        }

        return records.sorted { $0.path < $1.path }
    }

    public func assertDirectory(_ url: URL) throws {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ToolkitError.pathNotFound(url.path)
        }
        guard isDirectory.boolValue else {
            throw ToolkitError.notDirectory(url.path)
        }
    }

    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func relativePath(for url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        var relative = String(filePath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative.replacingOccurrences(of: "\\", with: "/")
    }
}
