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

@Suite struct DocumentLinksTests {
    private func doc(_ path: String, folder: String = "/r") -> DocumentFile {
        DocumentFile(path: path, folder: folder, relativePath: String(path.dropFirst(folder.count + 1)))
    }

    @Test func rewriteTurnsWikilinksIntoLinks() {
        #expect(
            DocumentLinks.rewriteWikilinks("see [[Plan A]] and [[Plan A|the plan]] and [[Plan A#Goal]]")
                == "see [Plan A](suica-doc:Plan%20A) and [the plan](suica-doc:Plan%20A) and [Plan A#Goal](suica-doc:Plan%20A%23Goal)")
    }

    @Test func rewriteLeavesCodeEmbedsAndEmptyLinksAlone() {
        #expect(DocumentLinks.rewriteWikilinks("`[[x]]` and [[y]]") == "`[[x]]` and [y](suica-doc:y)")
        #expect(DocumentLinks.rewriteWikilinks("```\n[[x]]\n```\n[[y]]") == "```\n[[x]]\n```\n[y](suica-doc:y)")
        #expect(DocumentLinks.rewriteWikilinks("~~~\n[[x]]\n~~~") == "~~~\n[[x]]\n~~~")
        #expect(DocumentLinks.rewriteWikilinks("![[x]]") == "![[x]]")
        #expect(DocumentLinks.rewriteWikilinks("[[]]") == "[[]]")
    }

    @Test func aTildeFenceInsideABacktickBlockDoesNotCloseIt() {
        #expect(
            DocumentLinks.rewriteWikilinks("```\n~~~\n[[x]]\n```\n[[y]]") == "```\n~~~\n[[x]]\n```\n[y](suica-doc:y)")
    }

    @Test func aLongerFenceIsNotClosedByAShorterOne() {
        #expect(
            DocumentLinks.rewriteWikilinks("````\n```\n[[x]]\n```\n````\n[[y]]")
                == "````\n```\n[[x]]\n```\n````\n[y](suica-doc:y)")
    }

    @Test func aFenceLineWithTextAfterTheBackticksIsNotAFence() {
        #expect(DocumentLinks.rewriteWikilinks("```code``` [[x]]") == "```code``` [x](suica-doc:x)")
    }

    @Test func aDoubleBacktickSpanIsLeftAsWritten() {
        #expect(DocumentLinks.rewriteWikilinks("``[[x]]`` and [[y]]") == "``[[x]]`` and [y](suica-doc:y)")
        #expect(DocumentLinks.rewriteWikilinks("`` a ` [[x]] `` [[y]]") == "`` a ` [[x]] `` [y](suica-doc:y)")
    }

    @Test func anUnmatchedBacktickDoesNotStopLaterRewriting() {
        #expect(DocumentLinks.rewriteWikilinks("it`s [[x]]") == "it`s [x](suica-doc:x)")
        #expect(DocumentLinks.rewriteWikilinks("``a` [[x]]") == "``a` [x](suica-doc:x)")
    }

    @Test func onlyAnEmbedIsLeftAloneNextToOtherLinks() {
        #expect(DocumentLinks.rewriteWikilinks("a![[x]]") == "a![[x]]")
        #expect(DocumentLinks.rewriteWikilinks("[[a]]![[b]]") == "[a](suica-doc:a)![[b]]")
        #expect(DocumentLinks.rewriteWikilinks("![[x]] [[y]]") == "![[x]] [y](suica-doc:y)")
    }

    @Test func aTargetSurvivesFoundationsParser() throws {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let rewritten = try AttributedString(markdown: DocumentLinks.rewriteWikilinks("[[Some Note (v2)]]"), options: options)
        let link = try #require(rewritten.runs.compactMap(\.link).first)
        #expect(DocumentLinks.wikilinkTarget(link) == "Some Note (v2)")
        #expect(DocumentLinks.wikilinkTarget(URL(string: "https://x")!) == nil)

        let plain = try AttributedString(markdown: "[t](docs/x.md)", options: options)
        let relative = try #require(plain.runs.compactMap(\.link).first)
        #expect(relative.scheme == nil)
        #expect(relative.path == "docs/x.md")
    }

    @Test func wikilinkResolvesByNameCaseHeadingExtensionAndPathSuffix() {
        let files = [doc("/r/a/Plan.md"), doc("/r/b/Plan.md"), doc("/r/b/deep/Idea.md")]
        for target in ["plan", "Plan#Goal", "Plan.md"] {
            #expect(DocumentLinks.resolveWikilink(target, from: "/r/b/x.md", among: files)?.path == "/r/b/Plan.md")
            #expect(DocumentLinks.resolveWikilink(target, from: "/r/c/x.md", among: files)?.path == "/r/a/Plan.md")
        }
        for target in ["deep/Idea", "b/deep/idea"] {
            #expect(DocumentLinks.resolveWikilink(target, from: "/r/c/x.md", among: files)?.path == "/r/b/deep/Idea.md")
        }
        for target in ["Missing", "", "#H"] {
            #expect(DocumentLinks.resolveWikilink(target, from: "/r/c/x.md", among: files) == nil)
        }
    }

    @Test func relativeLinksTryTheFileFolderThenItsParentsInsideThePlanFolder() {
        let files = [doc("/r/docs/specs/s.md"), doc("/r/README.md"), doc("/outside/o.md", folder: "/outside")]
        for from in ["/r/docs/plans/p.md", "/r/docs/plans/not-listed.md"] {
            for (target, expected) in [
                ("../specs/s.md", "/r/docs/specs/s.md"), ("docs/specs/s.md", "/r/docs/specs/s.md"),
                ("README.md", "/r/README.md"),
            ] {
                #expect(DocumentLinks.resolveRelative(target, from: from, among: files)?.path == expected)
            }
            for target in ["../../../outside/o.md", "missing.md", "notes.txt", ""] {
                #expect(DocumentLinks.resolveRelative(target, from: from, among: files) == nil)
            }
        }
    }
}

@Suite struct DocumentTreeTests {
    private func doc(_ path: String, folder: String = "/r") -> DocumentFile {
        DocumentFile(path: path, folder: folder, relativePath: String(path.dropFirst(folder.count + 1)))
    }

    @Test func buildNestsByFolderWithFoldersFirstAndNaturalOrder() throws {
        let tree = DocumentTree.build([doc("/r/b.md"), doc("/r/a/10.md"), doc("/r/a/2.md"), doc("/r/a/z/q.md")])
        let root = try #require(tree.first)
        #expect(tree.count == 1)
        #expect(root.name == "r" && root.id == "/r" && root.file == nil)
        #expect(root.children?.map(\.name) == ["a", "b"])
        let a = try #require(root.children?.first)
        #expect(a.id == "/r/a")
        #expect(a.children?.map(\.name) == ["z", "2", "10"])
        #expect(a.children?.last?.id == "/r/a/10.md")
        #expect(a.children?.last?.children == nil)
        #expect(a.children?.first?.id == "/r/a/z")
    }

    @Test func buildMakesOneRootPerPlanFolderEvenWhenNamesCollide() {
        let tree = DocumentTree.build([doc("/x/docs/a.md", folder: "/x/docs"), doc("/y/docs/b.md", folder: "/y/docs")])
        #expect(tree.map(\.name) == ["docs", "docs"])
        #expect(Set(tree.map(\.id)).count == 2)
    }

    @Test func buildOfNothingIsEmpty() {
        #expect(DocumentTree.build([]).isEmpty)
    }
}
