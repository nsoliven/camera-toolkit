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

/// Files a Sony camera writes for its own use beside the media. They are not
/// photos or clips and never belong on a board:
/// - `M4ROOT/THMBNL/…` — one small preview JPEG per clip.
/// - `M4ROOT/GENERAL/….cube` — the colour LUTs the camera keeps.
/// - `M4ROOT/MEDIAPRO.XML`, `M4ROOT/STATUS.BIN` — the clip index and status.
/// - `AVF_INFO/…` — the still-image database (`AVIN0001.INT/.INP/.BNP`).
/// - Under `PRIVATE/`: the camera database (`…/DATABASE/…`, `DATABASE.BIN`)
///   and `PRIVATE/SONY/…` card management files.
///
/// `M4ROOT` is matched wherever it sits (some bodies write it under
/// `PRIVATE/`), and its `CLIP` folder — the clips and their `M01.XML`
/// sidecars — stays listed, as do DCIM photos, Photomator edits, exports and
/// any other file under `PRIVATE/` (AVCHD streams, for one).
///
/// This only keeps them off the sorting boards (`OrganizeScanner`) and out of
/// Apply plans. It is not part of `DefaultExcludes`, so card ingest,
/// manifests and Free Up are unchanged — nothing here moves, copies or
/// deletes a file.
public enum CameraSupportFiles {
    /// True for a camera support file. `path` may be absolute or relative to a
    /// scan root; names compare case-insensitively.
    public static func isCameraGenerated(_ path: String) -> Bool {
        let components = upperComponents(path)
        guard let name = components.last, components.count >= 2 else { return false }
        let folders = components.dropLast()
        if folders.contains("AVF_INFO") { return true }
        for index in folders.indices {
            let next = folders.index(after: index)
            switch folders[index] {
            case "M4ROOT":
                // Directly inside M4ROOT: the clip index and status file.
                if next == folders.endIndex, name == "MEDIAPRO.XML" || name == "STATUS.BIN" { return true }
                guard next < folders.endIndex else { continue }
                switch folders[next] {
                case "THMBNL":
                    return true
                case "GENERAL":
                    if name.hasSuffix(".CUBE") { return true }
                default:
                    break
                }
            case "PRIVATE":
                let below = folders[next...]
                if below.contains("M4ROOT") { continue }
                if name == "DATABASE.BIN" || below.contains("DATABASE") || below.first == "SONY" { return true }
            default:
                break
            }
        }
        return false
    }

    /// True for a folder that holds nothing but support files — `M4ROOT/THMBNL`,
    /// `AVF_INFO`, a `DATABASE` folder or `SONY` folder under `PRIVATE` — so a
    /// scan can skip it without listing its files.
    public static func isSupportFolder(_ path: String) -> Bool {
        let components = upperComponents(path)
        guard let last = components.last else { return false }
        if last == "AVF_INFO" { return true }
        let parents = components.dropLast()
        if last == "THMBNL", parents.last == "M4ROOT" { return true }
        if let privateIndex = parents.lastIndex(of: "PRIVATE"), !components[privateIndex...].contains("M4ROOT") {
            if last == "DATABASE" { return true }
            if last == "SONY", parents.last == "PRIVATE" { return true }
        }
        return false
    }

    /// The `M4ROOT/THMBNL` folder itself (relative or absolute).
    public static func isThumbnailFolder(_ path: String) -> Bool {
        let components = upperComponents(path)
        guard components.count >= 2 else { return false }
        return components[components.count - 1] == "THMBNL" && components[components.count - 2] == "M4ROOT"
    }

    private static func upperComponents(_ path: String) -> [String] {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.uppercased() }
    }
}
