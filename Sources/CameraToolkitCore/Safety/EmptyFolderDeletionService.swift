import Darwin
import Foundation

public enum EmptyFolderDeletionError: LocalizedError, Equatable, Sendable {
    case protectedFolder
    case missing
    case notDirectory
    case symbolicLink
    case notEmpty
    case couldNotDelete(String)

    public var errorDescription: String? {
        switch self {
        case .protectedFolder:
            "That folder is a configured location or contains one, so Camera Toolkit will not delete it."
        case .missing:
            "The folder is no longer available. Reload the current location and try again."
        case .notDirectory:
            "The selected item is not a folder."
        case .symbolicLink:
            "Camera Toolkit will not delete a symbolic link from the file browser."
        case .notEmpty:
            "The folder is not empty. Remove or move its contents first, including any hidden files, then try again."
        case .couldNotDelete(let detail):
            "macOS could not delete the empty folder: \(detail)"
        }
    }
}

/// Deletes only an empty, ordinary directory. `rmdir` is intentionally used
/// instead of FileManager's recursive removal so a concurrent file creation
/// turns into a safe failure rather than deleting the new contents.
public enum EmptyFolderDeletionService {
    public static func delete(_ folderURL: URL, protectedURLs: [URL] = []) throws {
        let target = folderURL.standardizedFileURL
        guard target.isFileURL else {
            throw EmptyFolderDeletionError.notDirectory
        }
        try assertUnprotected(target, protectedURLs: protectedURLs)

        var metadata = stat()
        let inspectionResult = target.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &metadata)
        }
        guard inspectionResult == 0 else {
            if errno == ENOENT {
                throw EmptyFolderDeletionError.missing
            }
            throw EmptyFolderDeletionError.couldNotDelete(posixMessage(errno))
        }

        let fileType = metadata.st_mode & S_IFMT
        guard fileType != S_IFLNK else {
            throw EmptyFolderDeletionError.symbolicLink
        }
        guard fileType == S_IFDIR else {
            throw EmptyFolderDeletionError.notDirectory
        }

        let deletionResult = target.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.rmdir(path)
        }
        guard deletionResult == 0 else {
            let code = errno
            switch code {
            case ENOTEMPTY, EEXIST:
                throw EmptyFolderDeletionError.notEmpty
            case ENOENT:
                throw EmptyFolderDeletionError.missing
            case ENOTDIR:
                throw EmptyFolderDeletionError.notDirectory
            default:
                throw EmptyFolderDeletionError.couldNotDelete(posixMessage(code))
            }
        }
    }

    private static func assertUnprotected(_ target: URL, protectedURLs: [URL]) throws {
        let targetPath = normalizedPath(target)
        let components = target.pathComponents
        let isRoot = targetPath == "/"
        let isVolumesFolder = components == ["/", "Volumes"]
        let isVolumeRoot = components.count == 3 && components[0] == "/" && components[1] == "Volumes"

        guard !isRoot, !isVolumesFolder, !isVolumeRoot else {
            throw EmptyFolderDeletionError.protectedFolder
        }

        for protectedURL in protectedURLs where protectedURL.isFileURL {
            let protectedPath = normalizedPath(protectedURL.standardizedFileURL)
            if targetPath == protectedPath || protectedPath.hasPrefix(targetPath + "/") {
                throw EmptyFolderDeletionError.protectedFolder
            }
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    private static func posixMessage(_ code: Int32) -> String {
        "\(String(cString: strerror(code))) (errno \(code))"
    }
}
