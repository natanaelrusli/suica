import Foundation
import Testing

@testable import SuicaCore

private func cleanupContract(_ name: String) throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return try Data(contentsOf: url.appending(path: "contracts/\(name).v1.json"))
}

@Test func decodesPortsContractIncludingAddressesAndPorts() throws {
    let scan = try decodeDocument(PortScanDocument.self, from: cleanupContract("ports"))
    #expect(scan.status == "ok")
    #expect(scan.listeners.first?.endpoints == ["*:3000", "[::]:5173"])
    #expect(scan.listeners.first?.ports == ["3000", "5173"])
    #expect(scan.listeners.first?.command?.hasSuffix("vite") == true)
}

@Test func decodesWorktreeContractAndEligibility() throws {
    let scan = try decodeDocument(WorktreeScanDocument.self, from: cleanupContract("worktrees"))
    #expect(scan.defaultTarget == "origin/main")
    #expect(scan.entries.first?.status == "merged")
    #expect(scan.entries.first?.ignoredOutput == ["node_modules"])
    #expect(scan.targetRef == "refs/remotes/origin/main")
    #expect(scan.entries.last?.status == "prunable")
    let pruned = try decodeDocument(WorktreePruneDocument.self, from: cleanupContract("worktrees-prune"))
    #expect(pruned.pruned == ["/Users/example/project/.worktrees/deleted"])
}

@Test func decodesDevelopmentCleanupActionContracts() throws {
    let stopped = try decodeDocument(PortStopDocument.self, from: cleanupContract("ports-stop"))
    let fetched = try decodeDocument(WorktreeFetchDocument.self, from: cleanupContract("worktrees-fetch"))
    let removed = try decodeDocument(WorktreeRemovalDocument.self, from: cleanupContract("worktrees-remove"))
    #expect(stopped.status == "stopped")
    #expect(fetched.target == "origin/main" && fetched.targetCommit != nil)
    #expect(removed.status == "removed" && removed.branch == "feature/finished")
}

@Test func rejectsFutureDevelopmentCleanupContractVersions() {
    #expect(throws: AgentError.unsupportedVersion(2)) {
        try decodeDocument(PortScanDocument.self, from: Data(#"{"version":2}"#.utf8))
    }
}

@Test func discoversNestedRepositoriesAndLinkedWorktreesOnceAndCanRescan() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let root = temporary.appending(path: "workspace")
    let main = root.appending(path: "org/team/project")
    let linked = root.appending(path: "org/team/checkouts/project-feature")
    try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
    try runGit(in: main, ["init", "-b", "main"])
    try runGit(in: main, ["config", "user.name", "Suica Test"])
    try runGit(in: main, ["config", "user.email", "suica@example.invalid"])
    try "fixture".write(to: main.appending(path: "README.md"), atomically: true, encoding: .utf8)
    try runGit(in: main, ["add", "README.md"])
    try runGit(in: main, ["commit", "-m", "fixture"])
    try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
    try runGit(in: main, ["worktree", "add", "-b", "feature", linked.path])

    let ignored = root.appending(path: "org/team/project/node_modules/hidden-repo")
    try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
    try runGit(in: ignored, ["init"])
    try FileManager.default.createSymbolicLink(at: root.appending(path: "org/team/loop"), withDestinationURL: root)

    let first = GitRepositoryDiscovery.find(in: root.path)
    #expect(first.repositories.count == 1)
    #expect(first.repositories.first.map { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appending(path: ".git").path) } == true)
    #expect(!first.truncated)
    let directSelection = GitRepositoryDiscovery.find(in: main.path)
    #expect(directSelection.repositories == [main.path])
    #expect(directSelection.directoriesScanned == 1)
    #expect(GitRepositoryDiscovery.deduplicatedRepositories([main.path, linked.path]).count == 1)
    #expect(GitRepositoryDiscovery.linkedWorktreeCount(main.path) == 1)
    #expect(GitRepositoryDiscovery.linkedWorktreeCount(root.path) == 0)

    let later = root.appending(path: "org/another/repository")
    try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
    try runGit(in: later, ["init", "-b", "main"])
    let second = GitRepositoryDiscovery.find(in: root.path, alreadySaved: first.repositories)
    #expect(second.repositories.count == 1)
    #expect(second.repositories.first == later.path)
}

private func runGit(in directory: URL, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}
