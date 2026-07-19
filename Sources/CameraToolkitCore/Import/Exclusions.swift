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
