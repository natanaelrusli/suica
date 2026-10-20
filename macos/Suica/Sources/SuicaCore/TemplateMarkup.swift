import Foundation

// MARK: - Runs

/// Inline styles the visual template editor can show.
public struct TemplateStyle: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = TemplateStyle(rawValue: 1)
    public static let italic = TemplateStyle(rawValue: 2)
    public static let strikethrough = TemplateStyle(rawValue: 4)
}

/// One piece of a template as the visual editor holds it.
public enum TemplateRun: Equatable, Sendable {
    case text(String, TemplateStyle)
    case link(text: String, url: String, TemplateStyle)
    /// `{{name}}`, shown as a chip.
    case placeholder(String, TemplateStyle)
    /// `![alt](url)`, a GIF or other image.
    case image(alt: String, url: String)

    var style: TemplateStyle {
        switch self {
        case .text(_, let style), .link(_, _, let style), .placeholder(_, let style): style
        case .image: []
        }
    }
}

// MARK: - Markdown subset

/// The Markdown a Teams template is written in, limited to what the visual editor shows:
/// `**bold**`, `_italic_` (or `*italic*`), `~~strikethrough~~`, `[text](url)`, `![alt](url)`,
/// `{{placeholder}}` and backslash escapes. Anything else is kept as literal text, and
/// `isFaithful` tells whether the editor can show a template without changing its Markdown.
public enum TemplateMarkup {
    /// Characters a literal in the text is escaped for when the editor writes Markdown.
    static let escaped: Set<Character> = ["\\", "*", "_", "~", "`", "[", "]", "<"]

    public static func parse(_ source: String) -> [TemplateRun] {
        let characters = Array(source)
        var runs: [TemplateRun] = []
        parse(characters, characters.startIndex..<characters.endIndex, style: [], into: &runs)
        return merged(runs)
    }

    /// True when the visual editor would write `source` back unchanged.
    public static func isFaithful(_ source: String) -> Bool {
        markdown(parse(source)) == source
    }

    // MARK: Parsing

    private enum Delimiter: CaseIterable {
        case bold, strike, underscore, star

        var marker: [Character] {
            switch self {
            case .bold: ["*", "*"]
            case .strike: ["~", "~"]
            case .underscore: ["_"]
            case .star: ["*"]
            }
        }

        var style: TemplateStyle {
            switch self {
            case .bold: .bold
            case .strike: .strikethrough
            case .underscore, .star: .italic
            }
        }
    }

    private static func parse(
        _ c: [Character], _ range: Range<Int>, style: TemplateStyle, into runs: inout [TemplateRun]
    ) {
        var text = ""
        func flush() {
            if !text.isEmpty { runs.append(.text(text, style)) }
            text = ""
        }
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            let character = c[i]
            if character == "\\", i + 1 < end, isASCIIPunctuation(c[i + 1]) {
                text.append(c[i + 1])
                i += 2
            } else if let (name, next) = placeholder(c, at: i, end: end) {
                flush()
                runs.append(.placeholder(name, style))
                i = next
            } else if character == "!", let (alt, url, next) = bracketed(c, at: i + 1, end: end) {
                flush()
                runs.append(.image(alt: alt, url: url))
                i = next
            } else if let (label, url, next) = bracketed(c, at: i, end: end) {
                flush()
                runs.append(.link(text: label, url: url, style))
                i = next
            } else if let delimiter = opening(c, at: i, end: end),
                let close = closing(delimiter, in: c, from: i + delimiter.marker.count, end: end)
            {
                flush()
                parse(c, (i + delimiter.marker.count)..<close, style: style.union(delimiter.style), into: &runs)
                i = close + delimiter.marker.count
            } else {
                text.append(character)
                i += 1
            }
        }
        flush()
    }

    private static func isASCIIPunctuation(_ character: Character) -> Bool {
        character.isASCII && character.isPunctuation || character.isASCII && character.isSymbol
    }

    /// `{{name}}` with a name of word characters and dots, no spaces.
    private static func placeholder(_ c: [Character], at i: Int, end: Int) -> (String, Int)? {
        guard i + 1 < end, c[i] == "{", c[i + 1] == "{" else { return nil }
        var j = i + 2
        var name = ""
        while j + 1 < end, c[j] != "}" {
            guard c[j].isLetter || c[j].isNumber || c[j] == "_" || c[j] == "." else { return nil }
            name.append(c[j])
            j += 1
        }
        guard !name.isEmpty, j + 1 < end, c[j] == "}", c[j + 1] == "}" else { return nil }
        return (name, j + 2)
    }

    /// `[label](url)` starting at `i`: the label on one line, the URL without spaces.
    private static func bracketed(_ c: [Character], at i: Int, end: Int) -> (String, String, Int)? {
        guard i < end, c[i] == "[" else { return nil }
        var j = i + 1
        var label = ""
        while j < end, c[j] != "]" {
            if c[j] == "\n" || c[j] == "[" { return nil }
            if c[j] == "\\", j + 1 < end, isASCIIPunctuation(c[j + 1]) {
                label.append(c[j + 1])
                j += 2
                continue
            }
            label.append(c[j])
            j += 1
        }
        guard j + 1 < end, c[j] == "]", c[j + 1] == "(" else { return nil }
        j += 2
        var url = ""
        while j < end, c[j] != ")" {
            if c[j].isWhitespace || c[j] == "(" { return nil }
            url.append(c[j])
            j += 1
        }
        guard j < end, !url.isEmpty else { return nil }
        return (label, url, j + 1)
    }

    private static func matches(_ marker: [Character], _ c: [Character], at i: Int, end: Int) -> Bool {
        guard i + marker.count <= end else { return false }
        return Array(c[i..<(i + marker.count)]) == marker
    }

    private static func opening(_ c: [Character], at i: Int, end: Int) -> Delimiter? {
        for delimiter in Delimiter.allCases where matches(delimiter.marker, c, at: i, end: end) {
            let after = i + delimiter.marker.count
            // The content may not start with a space, and `*` alone is not part of `**`.
            guard after < end, !c[after].isWhitespace else { continue }
            if delimiter == .star, c[after] == "*" { continue }
            return delimiter
        }
        return nil
    }

    /// Where `delimiter` closes, on the same line, after at least one character; placeholders,
    /// links and escapes are skipped over so a `_` inside them never closes anything.
    private static func closing(_ delimiter: Delimiter, in c: [Character], from start: Int, end: Int) -> Int? {
        var j = start + 1
        while j < end {
            if c[j] == "\n" { return nil }
            if c[j] == "\\" {
                j += 2
                continue
            }
            if let (_, next) = placeholder(c, at: j, end: end) {
                j = next
                continue
            }
            if let (_, _, next) = bracketed(c, at: c[j] == "!" ? j + 1 : j, end: end) {
                j = next
                continue
            }
            if matches(delimiter.marker, c, at: j, end: end), !c[j - 1].isWhitespace {
                let after = j + delimiter.marker.count
                let lone = delimiter != .star || ((after >= end || c[after] != "*") && c[j - 1] != "*")
                let notLonger = delimiter != .bold || after >= end || c[after] != "*"
                if lone && notLonger { return j }
            }
            j += 1
        }
        return nil
    }

    private static func merged(_ runs: [TemplateRun]) -> [TemplateRun] {
        var result: [TemplateRun] = []
        for run in runs {
            if case .text(let text, let style) = run, case .text(let previous, let previousStyle)? = result.last,
                previousStyle == style
            {
                result[result.count - 1] = .text(previous + text, style)
            } else {
                result.append(run)
            }
        }
        return result
    }

    // MARK: Writing

    /// A written piece: text (which may move around a delimiter) or a delimiter itself.
    private enum Piece {
        case text(String)
        case marker(String)
        /// An italic delimiter, one of the pair `id`: `_`, or `*` when the pair touches a letter or
        /// digit outside it, where `_` would stay literal.
        case italic(id: Int, opening: Bool)
    }

    public static func markdown(_ runs: [TemplateRun]) -> String {
        var pieces: [Piece] = []
        var open: [TemplateStyle] = []
        var italicPairs = 0
        let order: [TemplateStyle] = [.bold, .italic, .strikethrough]

        func marker(_ style: TemplateStyle, opening: Bool) -> Piece {
            guard style == .italic else { return .marker(style == .bold ? "**" : "~~") }
            if opening { italicPairs += 1 }
            return .italic(id: italicPairs, opening: opening)
        }
        /// A delimiter never closes after a space: trailing spaces move outside it.
        func close() {
            let style = open.removeLast()
            var trailing = ""
            if case .text(let text)? = pieces.last {
                let kept = String(text.reversed().drop(while: { $0 == " " }).reversed())
                trailing = String(text.dropFirst(kept.count))
                pieces[pieces.count - 1] = .text(kept)
            }
            pieces.append(marker(style, opening: false))
            if !trailing.isEmpty { pieces.append(.text(trailing)) }
        }

        for run in split(runs) {
            let style = run.style
            if case .text(let text, _) = run, text.allSatisfy({ $0 == " " }) {
                pieces.append(.text(text))
                continue
            }
            if let first = open.firstIndex(where: { !style.contains($0) }) {
                while open.count > first { close() }
            }
            var content = content(of: run)
            // Nor does it open before one: leading spaces move in front of it.
            let missing = order.filter { style.contains($0) && !open.contains($0) }
            if !missing.isEmpty {
                let leading = String(content.prefix(while: { $0 == " " }))
                if !leading.isEmpty { pieces.append(.text(leading)) }
                content.removeFirst(leading.count)
            }
            for each in missing {
                pieces.append(marker(each, opening: true))
                open.append(each)
            }
            pieces.append(.text(content))
        }
        while !open.isEmpty { close() }
        return rendered(pieces)
    }

    /// Text runs are split at line breaks, which no delimiter spans; the break itself is plain.
    private static func split(_ runs: [TemplateRun]) -> [TemplateRun] {
        runs.flatMap { run -> [TemplateRun] in
            guard case .text(let text, let style) = run, !style.isEmpty, text.contains("\n") else { return [run] }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return lines.enumerated().flatMap { index, line -> [TemplateRun] in
                (index == 0 ? [] : [.text("\n", [])]) + (line.isEmpty ? [] : [.text(line, style)])
            }
        }
    }

    private static func content(of run: TemplateRun) -> String {
        switch run {
        case .text(let text, _): escape(text)
        case .link(let text, let url, _): "[\(escape(text))](\(url))"
        case .placeholder(let name, _): "{{\(name)}}"
        case .image(let alt, let url): "![\(escape(alt))](\(url))"
        }
    }

    /// A literal for the Markdown the editor writes: the characters it would otherwise read as syntax
    /// get a backslash.
    public static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if escaped.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    private static func rendered(_ pieces: [Piece]) -> String {
        func isWord(_ character: Character?) -> Bool { character?.isLetter == true || character?.isNumber == true }
        /// The character just outside a delimiter: in the text piece next to it, if there is one.
        func outside(_ index: Int, before: Bool) -> Character? {
            let neighbour = before ? index - 1 : index + 1
            guard pieces.indices.contains(neighbour), case .text(let text) = pieces[neighbour] else { return nil }
            return before ? text.last : text.first
        }
        var starred: Set<Int> = []
        for (index, piece) in pieces.enumerated() {
            if case .italic(let id, let opening) = piece, isWord(outside(index, before: opening)) { starred.insert(id) }
        }
        var result = ""
        for piece in pieces {
            switch piece {
            case .text(let text), .marker(let text):
                // `!` right before a link would turn it into an image.
                if text.hasPrefix("["), result.hasSuffix("!"), !result.hasSuffix("\\!") {
                    result.removeLast()
                    result += "\\!"
                }
                result += text
            case .italic(let id, _):
                result += starred.contains(id) ? "*" : "_"
            }
        }
        return result
    }
}

// MARK: - Variants

/// A line that is exactly `--- or ---` splits a template into variants; the agent picks one per
/// message.
public enum TemplateVariants {
    public static let separator = "--- or ---"

    public static func split(_ text: String) -> [String] {
        var variants: [String] = []
        var current: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) == separator {
                variants.append(current.joined(separator: "\n"))
                current = []
            } else {
                current.append(line)
            }
        }
        variants.append(current.joined(separator: "\n"))
        return variants
    }

    public static func join(_ variants: [String]) -> String {
        variants.joined(separator: "\n\(separator)\n")
    }
}

// MARK: - Emoji shortcodes

public enum EmojiShortcodes {
    /// Each known `:name:` in `text` replaced by its emoji; unknown names stay as written.
    public static func expand(_ text: String, table: [String: String]) -> String {
        text.replacing(/:([a-z0-9_+\-]+):/) { match in table[String(match.1)] ?? String(match.0) }
    }

    /// The `:name:` that `text` ends with, when `name` is known: what typing the closing colon
    /// turns into an emoji. `length` counts UTF-16 units, as a text view does.
    public static func completed(in text: String, table: [String: String]) -> (length: Int, emoji: String)? {
        guard let match = text.firstMatch(of: /:([a-z0-9_+\-]+):$/), let emoji = table[String(match.1)] else {
            return nil
        }
        return (match.0.utf16.count, emoji)
    }
}
