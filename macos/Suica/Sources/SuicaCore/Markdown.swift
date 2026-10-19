import Foundation

// MARK: - Markdown blocks

/// One block of GitLab Markdown as the review page draws it. Inline styling stays in the text.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// `marker` is "•" for an unordered item and the number with its dot for an ordered one; a task
    /// item's box is "☐" or "☑" instead of the bullet, or after the number. Lines that continue the
    /// item are joined to `text` with newlines.
    case listItem(text: String, marker: String, indent: Int)
    case quote(String)
    case code(String)
    case paragraph(String)
    case table(MarkdownTable)
    /// `---`, `***` or `___` on a line of its own.
    case rule
}

public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }

    public let header: [String]
    public let alignments: [Alignment]
    /// Each row has exactly as many cells as the header: short rows are padded, long ones cut.
    public let rows: [[String]]
}

private nonisolated(unsafe) let headingPattern = /^(#{1,6})\s+(.*)$/
private nonisolated(unsafe) let listItemPattern = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/
private nonisolated(unsafe) let delimiterCellPattern = /^:?-+:?$/
private nonisolated(unsafe) let taskPattern = /^\[([ xX])\](?:\s+(.*))?$/
private nonisolated(unsafe) let rulePattern = /^(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$/
private nonisolated(unsafe) let setextPattern = /^(=+|-+)$/

/// Splits Markdown into blocks: headings (`#` and underlined), list and task items, quotes, fenced
/// code (``` or ~~~), GFM tables, rules and paragraphs. HTML comments are hidden, as GitLab does;
/// anything else is kept as paragraph text.
public func parseMarkdownBlocks(_ source: String) -> [MarkdownBlock] {
    let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var code: [String]?
    /// The fence that opened `code`: a closing fence starts with the same three characters.
    var fence = ""
    var inComment = false
    var previousBlank = true

    func flush() {
        if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
        paragraph = []
    }

    var index = 0
    while index < lines.count {
        var line = lines[index]
        index += 1
        if code == nil {
            let visible = removingHTMLComments(line, inComment: &inComment)
            // A line that held only a comment is not there at all, not even as a blank line.
            if visible != line && visible.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            line = visible
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        defer { previousBlank = trimmed.isEmpty && code == nil }
        if let fenced = code, trimmed.hasPrefix(fence) {
            blocks.append(.code(fenced.joined(separator: "\n")))
            code = nil
            continue
        }
        if code == nil, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            flush()
            fence = String(trimmed.prefix(3))
            code = []
            continue
        }
        if code != nil {
            code?.append(line)
            continue
        }
        if trimmed.isEmpty {
            flush()
        } else if let match = trimmed.firstMatch(of: headingPattern) {
            flush()
            blocks.append(.heading(level: match.1.count, text: String(match.2)))
        } else if !paragraph.isEmpty, let match = trimmed.wholeMatch(of: setextPattern) {
            blocks.append(.heading(level: match.1.first == "=" ? 1 : 2, text: paragraph.joined(separator: "\n")))
            paragraph = []
        } else if trimmed.wholeMatch(of: rulePattern) != nil {
            flush()
            blocks.append(.rule)
        } else if let match = line.firstMatch(of: listItemPattern) {
            flush()
            // Numbers stay: a review's findings are answered by number ("fix 2 and 5").
            let number = match.2.first?.isNumber == true ? String(match.2) : nil
            var text = String(match.3)
            var marker = number ?? "•"
            if let task = text.wholeMatch(of: taskPattern) {
                let box = task.1 == " " ? "☐" : "☑"
                marker = number.map { "\($0) \(box)" } ?? box
                text = String(task.2 ?? "")
            }
            blocks.append(.listItem(text: text, marker: marker, indent: match.1.count / 2))
        } else if trimmed.hasPrefix(">") {
            flush()
            blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
        } else if index < lines.count, let table = tableStart(header: trimmed, delimiter: lines[index]) {
            flush()
            index += 1
            var rows: [[String]] = []
            while index < lines.count {
                let row = lines[index].trimmingCharacters(in: .whitespaces)
                guard !row.isEmpty, row.contains("|") else { break }
                rows.append(fit(tableCells(row), to: table.header.count))
                index += 1
            }
            blocks.append(.table(MarkdownTable(header: table.header, alignments: table.alignments, rows: rows)))
        } else if paragraph.isEmpty, case .listItem(let text, let marker, let indent)? = blocks.last,
            !previousBlank || line.first?.isWhitespace == true
        {
            // An indented line, or one right below the item, continues it as in GitLab.
            blocks[blocks.count - 1] = .listItem(text: text + "\n" + trimmed, marker: marker, indent: indent)
        } else {
            paragraph.append(line)
        }
    }
    if let fenced = code { blocks.append(.code(fenced.joined(separator: "\n"))) }
    flush()
    return blocks
}

/// `line` without its `<!-- … -->` parts; a comment left open hides the lines after it until `-->`.
func removingHTMLComments(_ line: String, inComment: inout Bool) -> String {
    var rest = Substring(line)
    var kept = ""
    while true {
        if inComment {
            guard let end = rest.range(of: "-->") else { return kept }
            rest = rest[end.upperBound...]
            inComment = false
        }
        guard let start = rest.range(of: "<!--") else { return kept + rest }
        kept += rest[..<start.lowerBound]
        rest = rest[start.upperBound...]
        inComment = true
    }
}

/// Inline Markdown as the page draws it: an image becomes a link labelled with its alt text (the
/// page loads no images), and GitLab's project-relative `/uploads/…` targets point into
/// `projectURL`. Code spans are left as written.
public func inlineMarkdownSource(_ text: String, projectURL: String?) -> String {
    text.split(separator: "`", omittingEmptySubsequences: false).enumerated().map { index, part in
        guard index % 2 == 0 else { return String(part) }
        var changed = part.replacing(/!\[([^\]]*)\]\(/) { match in "[\(match.1.isEmpty ? "image" : match.1)](" }
        if let projectURL { changed = changed.replacing("](/uploads/", with: "](\(projectURL)/uploads/") }
        return String(changed)
    }.joined(separator: "`")
}

/// A header row followed by a delimiter row with the same number of cells starts a GFM table.
private func tableStart(header: String, delimiter: String) -> (header: [String], alignments: [MarkdownTable.Alignment])? {
    guard header.contains("|") else { return nil }
    let names = tableCells(header)
    let marks = tableCells(delimiter.trimmingCharacters(in: .whitespaces))
    guard marks.count == names.count, marks.allSatisfy({ $0.wholeMatch(of: delimiterCellPattern) != nil })
    else { return nil }
    let alignments = marks.map { mark -> MarkdownTable.Alignment in
        switch (mark.hasPrefix(":"), mark.hasSuffix(":")) {
        case (true, true): .center
        case (false, true): .trailing
        default: .leading
        }
    }
    return (names, alignments)
}

/// Cells of one table row: outer pipes are optional, `\|` is a literal pipe, cells are trimmed.
func tableCells(_ row: String) -> [String] {
    var cells: [String] = []
    var cell = ""
    var escaped = false
    for character in row {
        if escaped {
            cell.append(character == "|" ? "|" : "\\\(character)")
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if character == "|" {
            cells.append(cell)
            cell = ""
        } else {
            cell.append(character)
        }
    }
    if escaped { cell.append("\\") }
    cells.append(cell)
    if row.hasPrefix("|") { cells.removeFirst() }
    if row.hasSuffix("|") && !row.hasSuffix("\\|") && !cells.isEmpty { cells.removeLast() }
    return cells.map { $0.trimmingCharacters(in: .whitespaces) }
}

private func fit(_ cells: [String], to count: Int) -> [String] {
    cells.count >= count ? Array(cells.prefix(count)) : cells + Array(repeating: "", count: count - cells.count)
}
