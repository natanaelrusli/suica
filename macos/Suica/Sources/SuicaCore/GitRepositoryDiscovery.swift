import Foundation

public struct GitRepositoryDiscoveryResult: Equatable, Sendable {
    public let repositories: [String]
    public let directoriesScanned: Int
    public let inaccessibleDirectories: Int
    public let truncated: Bool

    public init(repositories: [String], directoriesScanned: Int, inaccessibleDirectories: Int = 0, truncated: Bool) {
        self.repositories = repositories
        self.directoriesScanned = directoriesScanned
        self.inaccessibleDirectories = inaccessibleDirectories
        self.truncated = truncated
    }
}

/// Read-only discovery for local Git checkouts beneath a user-selected folder.
public enum GitRepositoryDiscovery {
    public static let maximumDirectories = 30_000

    public static func deduplicatedRepositories(_ paths: [String]) -> [String] {
        var seenCommonDirectories: Set<String> = []
        var seenPaths: Set<String> = []
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }.filter { path in
            guard seenPaths.insert(path).inserted else { return false }
            guard let common = commonDirectory(path) else { return true }
            return seenCommonDirectories.insert(common).inserted
        }
    }
    private static let skippedDirectoryNames: Set<String> = [
        "node_modules", ".build", "DerivedData", "Pods", "target", "dist", ".terraform", "__pycache__",
    ]

    public static func find(in folder: String, alreadySaved: [String] = []) -> GitRepositoryDiscoveryResult {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath()
        var knownCommonDirectories = Set(alreadySaved.compactMap(commonDirectory))
        var found: [String] = []
        var seenPaths: Set<String> = [root.path]
        // Breadth-first traversal reaches sibling repository roots before walking deep
        // inside the first checkout (which can contain millions of source directories).
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var queueIndex = 0
        var scanned = 0
        var inaccessible = 0
        var truncated = false

        while queueIndex < queue.count {
            if scanned >= maximumDirectories {
                truncated = true
                break
            }
            let (directory, depth) = queue[queueIndex]
            queueIndex += 1
            scanned += 1

            if isGitCheckout(directory), let common = commonDirectory(directory.path) {
                if knownCommonDirectories.insert(common).inserted { found.append(directory.path) }
                // A checkout is a repository root; walking its source tree cannot reveal
                // sibling repositories and can consume the scan budget needlessly.
                continue
            }
            guard depth < 32 else { truncated = true; continue }
            do {
                let children = try manager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsPackageDescendants])
                for child in children {
                    let name = child.lastPathComponent
                    guard name != ".git", !skippedDirectoryNames.contains(name), !name.hasPrefix(".") else { continue }
                    do {
                        let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    } catch {
                        inaccessible += 1
                        continue
                    }
                    let canonical = child.standardizedFileURL.resolvingSymlinksInPath()
                    guard seenPaths.insert(canonical.path).inserted else { continue }
                    queue.append((canonical, depth + 1))
                }
            } catch {
                inaccessible += 1
            }
        }
        return GitRepositoryDiscoveryResult(repositories: found.sorted(), directoriesScanned: scanned, inaccessibleDirectories: inaccessible, truncated: truncated)
    }

    /// Linked worktrees registered under the repository's common Git directory (0 when unknown).
    public static func linkedWorktreeCount(_ repository: String) -> Int {
        guard let common = commonDirectory(repository) else { return 0 }
        let entries = try? FileManager.default.contentsOfDirectory(atPath: URL(fileURLWithPath: common).appendingPathComponent("worktrees").path)
        return entries?.count ?? 0
    }

    private static func isGitCheckout(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path, isDirectory: &isDirectory)
    }

    private static func commonDirectory(_ repository: String) -> String? {
        guard let gitDirectory = git(repository, ["rev-parse", "--git-common-dir"]) else { return nil }
        let url = URL(fileURLWithPath: gitDirectory, relativeTo: URL(fileURLWithPath: repository))
            .standardizedFileURL.resolvingSymlinksInPath()
        return url.path
    }

    private static func git(_ directory: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }
}
