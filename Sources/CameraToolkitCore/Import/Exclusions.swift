import Foundation

public enum DefaultExcludes {
    public static let all = [
        "._*",
        ".DS_Store",
        ".Trashes/**",
        ".Spotlight-V100/**",
        ".fseventsd/**",
        ".TemporaryItems/**",
        "_Trash/**"
    ]
}

public enum JunkPolicy {
    public static func isJunkFile(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._")
    }
}

public enum ExclusionMatcher {
    public static func isExcluded(_ relativePath: String, excludes: [String] = DefaultExcludes.all) -> Bool {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/").map(String.init)

        for pattern in excludes {
            if pattern.hasSuffix("/**") {
                let prefix = String(pattern.dropLast(3))
                if normalized == prefix || normalized.hasPrefix(prefix + "/") || parts.dropLast().contains(prefix) {
                    return true
                }
            } else if pattern.contains("/") {
                if wildcard(pattern, matches: normalized) {
                    return true
                }
            } else if parts.contains(where: { wildcard(pattern, matches: $0) }) {
                return true
            }
        }

        return false
    }

    private static func wildcard(_ pattern: String, matches value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return value.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }
}

public enum PathSafety {
    public static func validateRelativePath(_ relativePath: String) throws {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        if normalized.isEmpty || normalized.hasPrefix("/") || components.contains("..") {
            throw ToolkitError.unsafeRelativePath(relativePath)
        }
    }

    public static func safeAppend(root: URL, relativePath: String) throws -> URL {
        try validateRelativePath(relativePath)
        return root.appendingPathComponent(relativePath)
    }
}

/// Files a Sony camera writes for its own use beside the media: one small
/// preview JPEG per clip under `M4ROOT/THMBNL`, and the colour LUTs it keeps
/// under `M4ROOT/GENERAL`. They are not photos and never belong on a board.
///
/// This only keeps them off the sorting boards (`OrganizeScanner`) and out of
/// Apply plans. It is deliberately narrow and path-based: the clips in
/// `M4ROOT/CLIP` and their XML sidecars, DCIM photos, Photomator edits and
/// any other JPEG stay listed. It is not part of `DefaultExcludes`, so card
/// ingest, manifests and Free Up are unchanged — nothing here moves, copies
/// or deletes a file.
public enum CameraSupportFiles {
    /// True for a file under `M4ROOT/THMBNL/` or a `.cube` file under
    /// `M4ROOT/GENERAL/`. `path` may be absolute or relative to a scan root;
    /// folder names compare case-insensitively.
    public static func isCameraGenerated(_ path: String) -> Bool {
        let components = path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.uppercased() }
        // The file itself is the last component; its folders come before.
        guard components.count >= 3 else { return false }
        let folders = components.dropLast()
        for index in folders.indices where folders[index] == "M4ROOT" {
            let next = folders.index(after: index)
            guard next < folders.endIndex else { continue }
            switch folders[next] {
            case "THMBNL":
                return true
            case "GENERAL":
                if components.last?.hasSuffix(".CUBE") == true { return true }
            default:
                break
            }
        }
        return false
    }

    /// True for the `M4ROOT/THMBNL` folder itself (relative or absolute), so a
    /// scan can skip it without listing its files.
    public static func isThumbnailFolder(_ path: String) -> Bool {
        let components = path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.uppercased() }
        guard components.count >= 2 else { return false }
        return components[components.count - 1] == "THMBNL" && components[components.count - 2] == "M4ROOT"
    }
}
