import Foundation

/// The folders of a path list in the config (the lesson folders): written with `~` for the home
/// folder, without a trailing slash, each folder once.
public enum Folders {
    /// `/Users/me/work/` → `~/work`; anything outside `home` stays absolute.
    public static func tidy(_ path: String, home: String = NSHomeDirectory()) -> String {
        var text = path.trimmingCharacters(in: .whitespaces)
        while text.count > 1 && text.hasSuffix("/") { text.removeLast() }
        guard !home.isEmpty, home != "/" else { return text }
        if text == home { return "~" }
        if text.hasPrefix(home + "/") { return "~" + text.dropFirst(home.count) }
        return text
    }

    /// `~/work` → `/Users/me/work`.
    public static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    /// `existing` followed by the chosen folders, tidied, with no folder twice (two spellings of
    /// one folder count as one) and no blank entry.
    public static func adding(
        _ chosen: [String], to existing: [String], home: String = NSHomeDirectory()
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in existing + chosen {
            let tidy = tidy(path, home: home)
            guard !tidy.isEmpty, seen.insert(expand(tidy, home: home)).inserted else { continue }
            result.append(tidy)
        }
        return result
    }

    /// Whether `path` is a folder that exists (a file or a missing path is not).
    public static func isFolder(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expand(path, home: home), isDirectory: &directory)
            && directory.boolValue
    }
}
