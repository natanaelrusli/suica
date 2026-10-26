import Foundation
import Testing

@testable import SuicaCore

@Suite struct FoldersTests {
    private let home = "/Users/me"

    @Test func tidyWritesTheHomeFolderAsATildeAndDropsTrailingSlashes() {
        #expect(Folders.tidy("/Users/me/work/", home: home) == "~/work")
        #expect(Folders.tidy("/Users/me", home: home) == "~")
        #expect(Folders.tidy("/Users/meow/work", home: home) == "/Users/meow/work")
        #expect(Folders.tidy("/Volumes/code//", home: home) == "/Volumes/code")
        #expect(Folders.tidy("  ~/work  ", home: home) == "~/work")
        #expect(Folders.tidy("/", home: home) == "/")
    }

    @Test func expandTurnsATildeBackIntoTheHomeFolder() {
        #expect(Folders.expand("~/work", home: home) == "/Users/me/work")
        #expect(Folders.expand("~", home: home) == "/Users/me")
        #expect(Folders.expand("/Volumes/code", home: home) == "/Volumes/code")
    }

    @Test func addingKeepsEachFolderOnceWhateverItsSpelling() {
        let result = Folders.adding(
            ["/Users/me/work/", "/Volumes/code", "~/other"], to: ["~/work", "~/other/"], home: home)
        #expect(result == ["~/work", "~/other", "/Volumes/code"])
    }

    @Test func addingSkipsBlankEntriesAndKeepsTheOrder() {
        let result = Folders.adding(["", "  ", "~/b"], to: ["~/a", ""], home: home)
        #expect(result == ["~/a", "~/b"])
    }

    @Test func isFolderIsTrueForAFolderOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        try Data().write(to: file)
        #expect(Folders.isFolder(directory.path))
        #expect(!Folders.isFolder(file.path))
        #expect(!Folders.isFolder(directory.appendingPathComponent("missing").path))
    }
}
