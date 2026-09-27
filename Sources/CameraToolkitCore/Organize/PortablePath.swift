import Foundation

/// Folder and file names SMB (and exFAT) can store as themselves.
///
/// A macOS path may hold characters an SMB share cannot store portably —
/// most often `:`, which is how POSIX spells a Finder `/` ("w/ Sam" is
/// `w: Sam` on disk). The NAS mirror path of such a file is computed
/// with each unsafe component rewritten by one stable rule, so presence,
/// Sync to NAS and the NAS layout migration all agree on where it lives:
///
/// - the word `w:` (Finder "w/") becomes `with` (`W:` → `With`);
/// - any other `:`, with the spaces around it, becomes ` - `;
/// - `"` becomes `'`; `\ * ? < > |` become `-`;
/// - trailing spaces and dots are dropped (leading spaces too, in a
///   component the rule rewrote); a component left empty becomes `_`.
///
/// A component that is already portable is returned unchanged, so the rule
/// is idempotent and never touches a name that works today. It is not a
/// bijection: callers that rewrite stored paths record the original (the
/// migration plan and journal do) so an undo can restore it.
public enum PortablePath {
    /// Characters SMB and exFAT cannot store as themselves.
    public static let unsafeCharacters = ":\\*?\"<>|"
    static let unsafe = CharacterSet(charactersIn: unsafeCharacters)

    public static func isPortable(component: some StringProtocol) -> Bool {
        component.rangeOfCharacter(from: unsafe) == nil && !component.hasSuffix(" ") && !component.hasSuffix(".")
    }

    /// True when every `/`-separated component is portable.
    public static func isPortable(relativePath: String) -> Bool {
        relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { isPortable(component: $0) }
    }

    public static func sanitize(component: String) -> String {
        guard !isPortable(component: component) else { return component }
        var value = component
        // Finder's "w/" (stored as "w:") reads best as "with".
        value = value.replacingOccurrences(of: #"(?<![^\s])w:(?=\s|$)"#, with: "with", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?<![^\s])W:(?=\s|$)"#, with: "With", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s*:\s*"#, with: " - ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\"", with: "'")
        for character in ["\\", "*", "?", "<", ">", "|"] {
            value = value.replacingOccurrences(of: character, with: "-")
        }
        value = value.trimmingCharacters(in: .whitespaces)
        while let last = value.last, last == " " || last == "." { value.removeLast() }
        return value.isEmpty ? "_" : value
    }

    /// Sanitizes each `/`-separated component; a portable path comes back
    /// unchanged.
    public static func sanitize(relativePath: String) -> String {
        guard !isPortable(relativePath: relativePath) else { return relativePath }
        return relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : sanitize(component: String($0)) }
            .joined(separator: "/")
    }
}
