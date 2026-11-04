import Foundation

/// A Markdown file found under one of the Owner's folders.
public struct DocumentFile: Equatable, Identifiable, Sendable {
    /// Absolute, symlinks resolved.
    public let path: String
    /// The folder it was found under, absolute and resolved.
    public let folder: String
    /// The path below `folder`, without a leading slash.
    public let relativePath: String
    public let modified: Date
    public var id: String { path }
    /// The file name without ".md".
    public var name: String { String(URL(fileURLWithPath: path).lastPathComponent.dropLast(3)) }

    public init(path: String, folder: String, relativePath: String, modified: Date = .distantPast) {
        self.path = path
        self.folder = folder
        self.relativePath = relativePath
        self.modified = modified
    }
}

/// The one walk that finds Markdown files for Plans and Documents.
public enum MarkdownFiles {
    public static let maxBytes = 1_000_000
    public static let maxFiles = 5_000

    /// Every `.md` file below `folders` of at most `maxBytes`, each once (the first folder to reach it wins).
    /// Hidden folders, `node_modules` and `.build` are skipped and symlinks are not followed.
    /// `truncated` is true when more than `limit` files exist.
    public static func find(
        in folders: [String], home: String = NSHomeDirectory(), limit: Int = maxFiles
    ) -> (files: [DocumentFile], truncated: Bool) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var seen = Set<String>()
        var files: [DocumentFile] = []
        for folder in folders {
            let root = URL(fileURLWithPath: Folders.expand(folder, home: home)).resolvingSymlinksInPath()
            guard
                let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if ["node_modules", ".build"].contains(url.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                guard url.pathExtension == "md", values?.isRegularFile == true,
                    (values?.fileSize ?? 0) <= maxBytes
                else { continue }
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard seen.insert(path).inserted, path.hasPrefix(root.path + "/") else { continue }
                if files.count == limit { return (files, true) }
                files.append(
                    DocumentFile(
                        path: path, folder: root.path, relativePath: String(path.dropFirst(root.path.count + 1)),
                        modified: values?.contentModificationDate ?? .distantPast))
            }
        }
        return (files, false)
    }
}

public struct FrontMatterEntry: Equatable, Sendable {
    public let key: String
    public let value: String
}

public enum FrontMatter {
    /// Entries of a leading `---` block and the text after it; the whole text when there is none.
    public static func split(_ text: String) -> (entries: [FrontMatterEntry], body: String) {
        var cursor = text.first == "\u{FEFF}" ? text.index(after: text.startIndex) : text.startIndex
        var lines: [Substring] = []
        var body: Substring?
        while cursor < text.endIndex {
            let end = text[cursor...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[cursor..<end]
            cursor = end == text.endIndex ? end : text.index(after: end)
            if lines.isEmpty && line != "---" { break }
            if !lines.isEmpty && (line == "---" || line == "...") {
                body = text[cursor...]
                break
            }
            lines.append(line)
        }
        guard let body, lines.dropFirst().allSatisfy(isFrontMatterLine) else { return ([], text) }

        var entries: [FrontMatterEntry] = []
        var open = false  // the last key had no value, so `- item` lines belong to it
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if open, trimmed.hasPrefix("- "), let last = entries.popLast() {
                let item = clean(String(trimmed.dropFirst(2)))
                entries.append(FrontMatterEntry(key: last.key, value: last.value.isEmpty ? item : last.value + ", " + item))
            } else if line.first?.isWhitespace == false, let colon = line.firstIndex(of: ":"), isKey(line) {
                let value = clean(String(line[line.index(after: colon)...]))
                entries.append(FrontMatterEntry(key: String(line[..<colon]), value: value))
                open = value.isEmpty
            }
        }
        return (entries, String(body))
    }

    private static func isKey(_ line: Substring) -> Bool {
        line.range(of: "^[A-Za-z0-9_-]+:", options: .regularExpression) != nil
    }

    private static func isFrontMatterLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#") || line.first?.isWhitespace == true
            || trimmed.hasPrefix("- ") || isKey(line)
    }

    /// Drops `[ ]` around a flow list (unquoting each item) and quotes around a scalar.
    private static func clean(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("["), value.hasSuffix("]") else { return unquote(value) }
        return value.dropFirst().dropLast().split(separator: ",").map { unquote(String($0)) }.joined(separator: ", ")
    }

    /// Drops one pair of matching quotes, unless the same quote appears inside (`'x' and 'y'`).
    private static func unquote(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, let quote = value.first, "\"'".contains(quote), value.last == quote,
            !value.dropFirst().dropLast().contains(quote)
        else { return value }
        return String(value.dropFirst().dropLast())
    }
}
