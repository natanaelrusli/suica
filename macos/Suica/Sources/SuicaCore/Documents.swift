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
