import Foundation
import Testing

@testable import SuicaCore

@Suite struct MarkdownFilesTests {
    @Test func findReturnsFolderAndRelativePath() throws {
        let root = try tree(["a/b/x.md": "x", "a/y.txt": "y"])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = MarkdownFiles.find(in: [root.path])
        #expect(result.files.count == 1)
        let file = try #require(result.files.first)
        #expect(file.relativePath == "a/b/x.md")
        #expect(file.name == "x")
        #expect(file.path == file.folder + "/a/b/x.md")
        #expect(result.truncated == false)
    }

    @Test func findSkipsHiddenNodeModulesBuildHugeAndSymlinkedFiles() throws {
        let root = try tree([
            ".h/a.md": "a", "node_modules/b.md": "b", ".build/c.md": "c",
            "huge.md": String(repeating: "x", count: 1_000_001), "ok.md": "ok",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.md"), withDestinationURL: root.appendingPathComponent("ok.md"))
        let names = MarkdownFiles.find(in: [root.path]).files.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        #expect(names == ["ok.md"])
    }

    @Test func findListsAFileOnceWhenAPlanFolderIsInsideAnother() throws {
        let root = try tree(["a/p.md": "p"])
        defer { try? FileManager.default.removeItem(at: root) }
        let files = MarkdownFiles.find(in: [root.path, root.path + "/a"]).files
        #expect(files.count == 1)
        #expect(files.first?.relativePath == "a/p.md")
    }

    @Test func findStopsAtTheLimitAndSaysSo() throws {
        let three = try tree(["a.md": "a", "b.md": "b", "c.md": "c"])
        let two = try tree(["a.md": "a", "b.md": "b"])
        defer {
            try? FileManager.default.removeItem(at: three)
            try? FileManager.default.removeItem(at: two)
        }
        let cut = MarkdownFiles.find(in: [three.path], limit: 2)
        #expect(cut.files.count == 2)
        #expect(cut.truncated == true)
        let whole = MarkdownFiles.find(in: [two.path], limit: 2)
        #expect(whole.files.count == 2)
        #expect(whole.truncated == false)
    }

    @Test func findExpandsATildeAndIgnoresAMissingFolder() throws {
        let root = try tree(["a/p.md": "p"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MarkdownFiles.find(in: ["~/a", "/nonexistent-suica"], home: root.path).files.count == 1)
    }
}

@Suite struct FrontMatterTests {
    private func entry(_ key: String, _ value: String) -> FrontMatterEntry { FrontMatterEntry(key: key, value: value) }

    @Test func splitReadsKeysListsAndQuotes() {
        let text = "---\nname: Plan\ntags: [a, b]\nowner: \"Nata\"\nurl: http://x\nlist:\n  - x\n  - y\n---\n# Title\n"
        let result = FrontMatter.split(text)
        #expect(
            result.entries == [
                entry("name", "Plan"), entry("tags", "a, b"), entry("owner", "Nata"),
                entry("url", "http://x"), entry("list", "x, y"),
            ])
        #expect(result.body == "# Title\n")
    }

    @Test func splitHandlesCRLFBOMAndAnEmptyBody() {
        let crlf = FrontMatter.split("\u{FEFF}---\r\na: b\r\n---\r\ntext")
        #expect(crlf.entries == [entry("a", "b")])
        #expect(crlf.body == "text")
        let empty = FrontMatter.split("---\na: b\n---")
        #expect(empty.entries == [entry("a", "b")])
        #expect(empty.body == "")
    }

    @Test func anUnterminatedBlockIsNotFrontMatter() {
        let text = "---\na: b\n\ntext"
        let result = FrontMatter.split(text)
        #expect(result.entries.isEmpty)
        #expect(result.body == text)
    }

    @Test func aRuleAtTheTopWithProseBetweenIsNotFrontMatter() {
        let text = "---\n\nSome prose here.\n\n---\nmore"
        let result = FrontMatter.split(text)
        #expect(result.entries.isEmpty)
        #expect(result.body == text)
    }

    @Test func noBlockMeansNoEntries() {
        for text in ["# Title\n---\nx", ""] {
            let result = FrontMatter.split(text)
            #expect(result.entries.isEmpty)
            #expect(result.body == text)
        }
    }

    @Test func quotedListItemsAreUnquotedOneByOne() {
        let result = FrontMatter.split("---\ntags: [\"a\", 'b']\n---\n")
        #expect(result.entries == [entry("tags", "a, b")])
    }

    @Test func aValueWithQuotesInsideKeepsThemAsWritten() {
        let result = FrontMatter.split("---\ntitle: 'x' and 'y'\n---\n")
        #expect(result.entries == [entry("title", "'x' and 'y'")])
    }

    @Test func threeDotsCloseTheBlock() {
        let result = FrontMatter.split("---\na: b\n...\ntext")
        #expect(result.entries == [entry("a", "b")])
        #expect(result.body == "text")
    }

    @Test func aKeyWithoutValueOrItemsHasAnEmptyValue() {
        let result = FrontMatter.split("---\nempty:\nnext: 1\n---\n")
        #expect(result.entries == [entry("empty", ""), entry("next", "1")])
    }
}
