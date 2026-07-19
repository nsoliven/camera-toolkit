import Foundation

public struct EventNameValidation: Equatable, Sendable {
    public var normalizedName: String
    public var folderName: String
    public var errorMessage: String?
    public var suggestion: String?

    public var isValid: Bool { errorMessage == nil }
}

public enum EventNamePolicy {
    public static let maximumLength = 100

    private static let reservedCharacters = CharacterSet(charactersIn: "/:\\?*\"<>|")

    public static func validate(_ rawName: String) -> EventNameValidation {
        let normalizedName = normalizeWhitespace(rawName)
        guard !normalizedName.isEmpty else {
            return invalid(
                normalizedName: normalizedName,
                message: "Enter an event name. Spaces are allowed."
            )
        }

        if normalizedName == "." || normalizedName == ".." {
            return invalid(
                normalizedName: normalizedName,
                message: "An event name can’t be only dots. Try a descriptive name such as “Photo-Event”.",
                suggestion: "Photo-Event"
            )
        }

        if normalizedName.count > maximumLength {
            let suggestion = safeSuggestion(String(normalizedName.prefix(maximumLength)))
            return invalid(
                normalizedName: normalizedName,
                message: "Keep the event name to \(maximumLength) characters or fewer.",
                suggestion: suggestion
            )
        }

        let invalidCharacters = uniqueInvalidCharacters(in: normalizedName)
        if !invalidCharacters.isEmpty {
            let renderedCharacters = invalidCharacters.map { "“\($0)”" }.joined(separator: ", ")
            let noun = invalidCharacters.count == 1 ? "character" : "characters"
            let suggestion = safeSuggestion(normalizedName)
            return invalid(
                normalizedName: normalizedName,
                message: "The \(renderedCharacters) \(noun) can’t be used in portable folder names. Use a dash instead.",
                suggestion: suggestion
            )
        }

        if normalizedName.last == "." {
            let suggestion = normalizedName.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            return invalid(
                normalizedName: normalizedName,
                message: "An event name can’t end with a period on every supported filesystem. Remove it or use a dash.",
                suggestion: suggestion.isEmpty ? "Photo-Event" : suggestion
            )
        }

        return EventNameValidation(
            normalizedName: normalizedName,
            folderName: normalizedName,
            errorMessage: nil,
            suggestion: nil
        )
    }

    public static func folderName(for rawName: String, fallback: String = "Event") -> String {
        let validation = validate(rawName)
        if validation.isValid {
            return validation.folderName
        }
        if let suggestion = validation.suggestion, !suggestion.isEmpty {
            return suggestion
        }
        return fallback
    }

    private static func invalid(
        normalizedName: String,
        message: String,
        suggestion: String? = nil
    ) -> EventNameValidation {
        EventNameValidation(
            normalizedName: normalizedName,
            folderName: suggestion ?? "",
            errorMessage: message,
            suggestion: suggestion
        )
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func uniqueInvalidCharacters(in value: String) -> [String] {
        var seen: Set<String> = []
        return value.unicodeScalars.compactMap { scalar in
            guard reservedCharacters.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) else {
                return nil
            }
            let rendered = CharacterSet.controlCharacters.contains(scalar) ? "control character" : String(scalar)
            guard seen.insert(rendered).inserted else { return nil }
            return rendered
        }
    }

    private static func safeSuggestion(_ value: String) -> String {
        var result = ""
        var previousWasDash = false

        for scalar in value.unicodeScalars {
            if reservedCharacters.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                if !previousWasDash {
                    result.append("-")
                    previousWasDash = true
                }
            } else {
                result.append(Character(scalar))
                previousWasDash = scalar == "-"
            }
        }

        let trimmed = normalizeWhitespace(result)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return trimmed.isEmpty ? "Photo-Event" : String(trimmed.prefix(maximumLength))
    }
}
