import Darwin
import Foundation

public struct FileTrashReport: Equatable, Sendable {
    public var movedURLs: [URL]

    public init(movedURLs: [URL]) {
        self.movedURLs = movedURLs
    }
}

public enum FileTrashError: LocalizedError, Equatable, Sendable {
    case nothingSelected
    case invalidItem(String)
    case missing(String)
    case protectedItem(String)
    case couldNotMove(name: String, detail: String)
    case partialFailure(movedCount: Int, totalCount: Int, failedName: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .nothingSelected:
            "Select at least one file or folder to move to Trash."
        case .invalidItem(let name):
            "“\(name)” is not a local file or folder, so Camera Toolkit cannot move it to Trash."
        case .missing(let name):
            "“\(name)” is no longer available. Reload the current location and try again."
        case .protectedItem(let name):
            "“\(name)” is a configured location, a drive root, or contains a configured location. Camera Toolkit will not move it to Trash."
        case .couldNotMove(let name, let detail):
            "macOS could not move “\(name)” to Trash: \(detail)"
        case .partialFailure(let movedCount, let totalCount, let failedName, let detail):
            "\(movedCount) of \(totalCount) items were already moved to Trash, but macOS could not move “\(failedName)”: \(detail) You can restore the moved items from Trash."
        }
    }
}

/// Moves ordinary files and folders through macOS's Trash API. Every target is
/// validated before the first move, and selecting both a folder and one of its
/// descendants moves only the folder.
public enum FileTrashService {
    public static func moveToTrash(
        _ urls: [URL],
        protectedURLs: [URL] = []
    ) throws -> FileTrashReport {
        try moveToTrash(urls, protectedURLs: protectedURLs) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    public static func moveToTrash(
        _ urls: [URL],
        protectedURLs: [URL] = [],
        trash: (URL) throws -> Void
    ) throws -> FileTrashReport {
        let targets = normalizedTargets(urls)
        guard !targets.isEmpty else {
            throw FileTrashError.nothingSelected
        }

        for target in targets {
            try validate(target, protectedURLs: protectedURLs)
        }

        var movedURLs: [URL] = []
        for target in targets {
            do {
                try trash(target)
                movedURLs.append(target)
            } catch {
                if movedURLs.isEmpty {
                    throw FileTrashError.couldNotMove(
                        name: displayName(target),
                        detail: error.localizedDescription
                    )
                }
                throw FileTrashError.partialFailure(
                    movedCount: movedURLs.count,
                    totalCount: targets.count,
                    failedName: displayName(target),
                    detail: error.localizedDescription
                )
            }
        }

        return FileTrashReport(movedURLs: movedURLs)
    }

    private static func normalizedTargets(_ urls: [URL]) -> [URL] {
        let normalizedURLs = urls.map { url in
            url.isFileURL ? url.standardizedFileURL : url
        }

        var seenIdentities: Set<String> = []
        let unique = normalizedURLs.filter { url in
            let identity = url.isFileURL ? "file:\(normalizedPath(url))" : url.absoluteString
            return seenIdentities.insert(identity).inserted
        }
        let shallowestFirst = unique.sorted {
            if $0.pathComponents.count != $1.pathComponents.count {
                return $0.pathComponents.count < $1.pathComponents.count
            }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

        var targets: [URL] = []
        for candidate in shallowestFirst {
            guard candidate.isFileURL else {
                targets.append(candidate)
                continue
            }
            let candidatePath = normalizedPath(candidate)
            let isCoveredBySelectedFolder = targets.contains { ancestor in
                ancestor.isFileURL && candidatePath.hasPrefix(normalizedPath(ancestor) + "/")
            }
            if !isCoveredBySelectedFolder {
                targets.append(candidate)
            }
        }
        return targets
    }

    private static func validate(_ target: URL, protectedURLs: [URL]) throws {
        guard target.isFileURL else {
            throw FileTrashError.invalidItem(displayName(target))
        }

        let targetPath = normalizedPath(target)
        let components = target.pathComponents
        let isRoot = targetPath == "/"
        let isVolumesFolder = components == ["/", "Volumes"]
        let isVolumeRoot = components.count == 3 && components[0] == "/" && components[1] == "Volumes"
        guard !isRoot, !isVolumesFolder, !isVolumeRoot else {
            throw FileTrashError.protectedItem(displayName(target))
        }

        for protectedURL in protectedURLs where protectedURL.isFileURL {
            let protectedPath = normalizedPath(protectedURL.standardizedFileURL)
            if targetPath == protectedPath || protectedPath.hasPrefix(targetPath + "/") {
                throw FileTrashError.protectedItem(displayName(target))
            }
        }

        var metadata = stat()
        let result = target.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &metadata)
        }
        guard result == 0 else {
            if errno == ENOENT {
                throw FileTrashError.missing(displayName(target))
            }
            throw FileTrashError.couldNotMove(
                name: displayName(target),
                detail: "\(String(cString: strerror(errno))) (errno \(errno))"
            )
        }
    }

    private static func displayName(_ url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
