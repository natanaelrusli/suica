import Foundation
import Observation

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

private nonisolated(unsafe) let wikilinkPattern = /(!)?\[\[([^\[\]|]+?)(?:\|([^\[\]]+?))?\]\]/ // regex lookbehind is unsupported, so a leading `!` is captured

public enum DocumentLinks {
    public static let scheme = "suica-doc"

    /// `[[T]]`, `[[T|alias]]`, `[[T#H]]` → `[alias or T as written](suica-doc:<T#H percent-encoded>)`.
    /// Code spans and fenced blocks are left as written, and so are `![[embeds]]`.
    public static func rewriteWikilinks(_ markdown: String) -> String {
        var fence: (character: Character, length: Int)?
        return markdown.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = fence {
                // A closing fence is the same character, at least as long, with nothing after it.
                if trimmed.count >= open.length, trimmed.allSatisfy({ $0 == open.character }) { fence = nil }
                return line
            }
            if let first = trimmed.first, first == "`" || first == "~" {
                let length = trimmed.prefix { $0 == first }.count
                // A backtick fence's info string cannot hold a backtick (that makes it a code span).
                if length >= 3, first == "~" || !trimmed.dropFirst(length).contains("`") {
                    fence = (first, length)
                    return line
                }
            }
            return rewriteOutsideCodeSpans(line)
        }.joined(separator: "\n")
    }

    /// A run of N backticks opens a span that ends at the next run of exactly N; without one it is plain text.
    private static func rewriteOutsideCodeSpans(_ line: String) -> String {
        var result = ""
        var text = ""
        var index = line.startIndex
        while index < line.endIndex {
            guard line[index] == "`" else {
                text.append(line[index])
                index = line.index(after: index)
                continue
            }
            let runEnd = line[index...].firstIndex { $0 != "`" } ?? line.endIndex
            if let spanEnd = endOfSpan(openedBy: line.distance(from: index, to: runEnd), in: line, after: runEnd) {
                result += rewrite(text) + line[index..<spanEnd]
                text = ""
                index = spanEnd
            } else {
                text += line[index..<runEnd]
                index = runEnd
            }
        }
        return result + rewrite(text)
    }

    private static func endOfSpan(openedBy length: Int, in line: String, after start: String.Index) -> String.Index? {
        var from = start
        while let tick = line[from...].firstIndex(of: "`") {
            let end = line[tick...].firstIndex { $0 != "`" } ?? line.endIndex
            if line.distance(from: tick, to: end) == length { return end }
            from = end
        }
        return nil
    }

    private static func rewrite(_ text: String) -> String {
        text.replacing(wikilinkPattern) { match in
            if match.1 != nil { return String(match.0) }
            let target = String(match.2)
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
            return "[\(match.3.map(String.init) ?? target)](\(scheme):\(encoded))"
        }
    }

    /// The decoded target of a `suica-doc:` URL (read from `absoluteString`: the URL is opaque and its `path` is empty); nil for other URLs.
    public static func wikilinkTarget(_ url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return String(url.absoluteString.dropFirst(scheme.count + 1)).removingPercentEncoding
    }

    /// An Obsidian-style target: name or path suffix, any case, with or without `.md` or `#heading`.
    /// Ties go to the file's own folder, then the shortest relative path, then path order.
    public static func resolveWikilink(_ target: String, from path: String, among files: [DocumentFile]) -> DocumentFile? {
        var key = (target.split(separator: "#", omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        if key.hasSuffix(".md") { key.removeLast(3) }
        guard !key.isEmpty else { return nil }
        let own = URL(fileURLWithPath: path).deletingLastPathComponent().path
        func sortKey(_ file: DocumentFile) -> (Int, Int, String) {
            (URL(fileURLWithPath: file.path).deletingLastPathComponent().path == own ? 0 : 1, file.relativePath.count, file.path)
        }
        return files.filter { file in
            guard key.contains("/") else { return file.name.lowercased() == key }
            let relative = file.relativePath.dropLast(3).lowercased()
            return relative == key || relative.hasSuffix("/" + key)
        }.min { sortKey($0) < sortKey($1) }
    }

    /// `target` is the decoded path of a scheme-less link (`url.path`, fragment already dropped).
    /// Tried from the file's folder and then each parent up to its Plan folder.
    public static func resolveRelative(_ target: String, from path: String, among files: [DocumentFile]) -> DocumentFile? {
        guard target.hasSuffix(".md"),
            let root = files.map(\.folder).filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count })
        else { return nil }
        var dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while true {
            let found = URL(fileURLWithPath: dir + "/" + target).standardizedFileURL.path
            if found.hasPrefix(root + "/"), let file = files.first(where: { $0.path == found }) { return file }
            if dir == root || dir == "/" { return nil }
            dir = URL(fileURLWithPath: dir).deletingLastPathComponent().path
        }
    }
}

public struct DocumentNode: Identifiable, Equatable, Sendable {
    /// A file's path; a folder's `folder + "/" + relative dir` (a root's is its folder path).
    public let id: String
    public let name: String
    public let file: DocumentFile?
    /// nil for a file, which is what `List(_:children:)` needs.
    public let children: [DocumentNode]?
}

public enum DocumentTree {
    /// One root per Plan folder (first-seen order), then folders and files by `relativePath`; siblings are folders first, each in natural name order.
    public static func build(_ files: [DocumentFile]) -> [DocumentNode] {
        var folders: [String] = []
        for file in files where !folders.contains(file.folder) { folders.append(file.folder) }
        return folders.map { folder in
            let below = files.filter { $0.folder == folder }.map { ($0, $0.relativePath.split(separator: "/").map(String.init)) }
            return DocumentNode(
                id: folder, name: URL(fileURLWithPath: folder).lastPathComponent, file: nil,
                children: nodes(below, in: folder))
        }
    }

    private static func nodes(_ items: [(file: DocumentFile, parts: [String])], in dir: String) -> [DocumentNode] {
        let leaves = items.filter { $0.parts.count == 1 }.map {
            DocumentNode(id: $0.file.path, name: $0.file.name, file: $0.file, children: nil)
        }
        let dirs = Dictionary(grouping: items.filter { $0.parts.count > 1 }, by: { $0.parts[0] }).map { name, group in
            DocumentNode(
                id: dir + "/" + name, name: name, file: nil,
                children: nodes(group.map { ($0.file, Array($0.parts.dropFirst())) }, in: dir + "/" + name))
        }
        let byName = { (a: DocumentNode, b: DocumentNode) in a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return dirs.sorted(by: byName) + leaves.sorted(by: byName)
    }
}

public enum DocumentContent: Equatable, Sendable {
    case none, unavailable
    /// `body` has already been through `DocumentLinks.rewriteWikilinks`.
    case text(entries: [FrontMatterEntry], body: String)
}

public enum LineEnding: Equatable, Sendable { case lf, crlf }

public enum DocumentText {
    /// Text with every `\r\n` and lone `\r` turned into `\n`, and the ending the file used (`.crlf` when it held any `\r\n`).
    /// rewriteWikilinks splits on "\n", and Swift reads "\r\n" as one Character, so fences need LF.
    public static func normalise(_ raw: String) -> (text: String, ending: LineEnding) {
        let lf = raw.replacingOccurrences(of: "\r\n", with: "\n")
        return (lf.replacingOccurrences(of: "\r", with: "\n"), lf == raw ? .lf : .crlf)
    }

    /// The inverse for saving: `\n` become `\r\n` for `.crlf`.
    public static func restore(_ text: String, ending: LineEnding) -> String {
        ending == .crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
    }

    /// What View mode draws for `text` (already LF): front matter split, wikilinks rewritten.
    public static func render(_ text: String) -> DocumentContent {
        let (entries, body) = FrontMatter.split(text)
        return .text(entries: entries, body: DocumentLinks.rewriteWikilinks(body))
    }
}

public enum LinkOutcome: Equatable, Sendable { case opened, ignored, external }

@MainActor @Observable
public final class DocumentsModel {
    private let plans: PlansModel
    private let find: @Sendable ([String]) -> (files: [DocumentFile], truncated: Bool)
    /// Bumped by every refresh, so a slow scan that was overtaken drops its result.
    private var generation = 0

    public private(set) var files: [DocumentFile] = []
    /// Always `DocumentTree.build(files)`, built when the list changes rather than on every redraw.
    public private(set) var tree: [DocumentNode] = []
    public private(set) var truncated = false
    public private(set) var isScanning = false
    public var query = ""
    /// Changed only through `open`, `back` and `forward`.
    public private(set) var selectedPath: String?
    public private(set) var content = DocumentContent.none
    private var backStack: [String] = []
    private var forwardStack: [String] = []

    public init(
        plans: PlansModel,
        find: @escaping @Sendable ([String]) -> (files: [DocumentFile], truncated: Bool) = { MarkdownFiles.find(in: $0) }
    ) {
        self.plans = plans
        self.find = find
    }

    public var folders: [String] { plans.folders }

    /// The files whose path or folder name hold every word of the search; all of them without one.
    public var visible: [DocumentFile] {
        files.filter { Search.matches(query, [$0.relativePath, URL(fileURLWithPath: $0.folder).lastPathComponent]) }
    }

    /// Scans off the main thread; the previous list stays until the scan is done. Only the newest
    /// refresh sets the list: an older scan that finishes later is dropped.
    public func refresh() async {
        generation += 1
        let mine = generation
        let folders = folders
        guard !folders.isEmpty else {
            files = []
            tree = []
            truncated = false
            isScanning = false
            return
        }
        isScanning = true
        let find = find
        let found = await Task.detached { find(folders) }.value
        guard mine == generation else { return }
        files = found.files
        tree = DocumentTree.build(found.files)
        truncated = found.truncated
        isScanning = false
    }

    public func addFolders(_ chosen: [String]) { plans.addFolders(chosen) }
    public func removeFolder(_ path: String) { plans.removeFolder(path) }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public func open(path: String) {
        guard path != selectedPath else { return }
        if let current = selectedPath {
            backStack.append(current)
            if backStack.count > 50 { backStack.removeFirst() }
        }
        forwardStack = []
        selectedPath = path
        content = .none
    }

    public func back() { step(from: &backStack, to: &forwardStack) }
    public func forward() { step(from: &forwardStack, to: &backStack) }

    private func step(from source: inout [String], to other: inout [String]) {
        guard let path = source.popLast() else { return }
        if let current = selectedPath { other.append(current) }
        selectedPath = path
        content = .none
    }

    /// Wikilinks resolve by name, relative links from the open file; http(s) links go to the system and every other scheme is ignored.
    public func openLink(_ url: URL) -> LinkOutcome {
        let target: DocumentFile?
        if let name = DocumentLinks.wikilinkTarget(url) {
            target = DocumentLinks.resolveWikilink(name, from: selectedPath ?? "", among: files)
        } else if url.scheme == nil {
            target = selectedPath.flatMap { DocumentLinks.resolveRelative(url.path, from: $0, among: files) }
        } else {
            return DisplayText.safeURL(url.absoluteString) == nil ? .ignored : .external
        }
        guard let target else { return .ignored }
        open(path: target.path)
        return .opened
    }

    /// Reads the open file off the main thread; the result is dropped if the selection moved meanwhile.
    public func loadContent() async {
        guard let path = selectedPath else { content = .none; return }
        let loaded = await Task.detached { () -> DocumentContent in
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
                size <= MarkdownFiles.maxBytes, let data = FileManager.default.contents(atPath: path),
                data.count <= MarkdownFiles.maxBytes, let text = String(data: data, encoding: .utf8)
            else { return .unavailable }
            return DocumentText.render(DocumentText.normalise(text).text)
        }.value
        guard path == selectedPath else { return }
        content = loaded
    }
}
