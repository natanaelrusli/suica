import Foundation

/// Text written by other people (titles, names, messages) is cleaned before it is shown.
public enum DisplayText {
    /// Control characters and newlines become spaces, runs of spaces collapse, outer spaces are
    /// trimmed, and text longer than `max` characters is cut with a trailing "…".
    public static func clean(_ text: String, max: Int = 200) -> String {
        var words: [String] = []
        var current = ""
        for character in text {
            if character.isNewline || character.isWhitespace || isControl(character) {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        let joined = words.joined(separator: " ")
        guard joined.count > max else { return joined }
        return String(joined.prefix(max - 1)) + "…"
    }

    /// Only `http` and `https` links are ever opened.
    public static func safeURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host() != nil
        else { return nil }
        return url
    }

    private static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1
            && character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
    }
}
