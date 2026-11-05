import Foundation
import Testing

@testable import SuicaCore

@Suite struct DocumentTextTests {
    @Test func normaliseReportsTheEndingTheFileUsed() {
        let cases: [(String, String, LineEnding)] = [
            ("a\r\nb\r\n", "a\nb\n", .crlf), ("a\nb", "a\nb", .lf), ("a\rb", "a\nb", .lf),
            ("", "", .lf), ("a\r\nb\nc", "a\nb\nc", .crlf),
        ]
        for (raw, text, ending) in cases {
            let result = DocumentText.normalise(raw)
            #expect(result.text == text && result.ending == ending)
        }
    }

    @Test func restoreIsTheInverseForUniformFiles() {
        for s in ["\u{FEFF}---\nk: v\n---\nbody\n\n", "x", "a\n\nb\n", "a\r\n\r\nb\r\n", "\u{FEFF}---\r\nk: v\r\n---\r\nbody\r\n"] {
            let n = DocumentText.normalise(s)
            #expect(DocumentText.restore(n.text, ending: n.ending) == s)
        }
    }

    @Test func renderSplitsFrontMatterAndRewritesWikilinks() {
        #expect(
            DocumentText.render("---\ntitle: T\n---\nsee [[x]]\n")
                == .text(entries: [FrontMatterEntry(key: "title", value: "T")], body: "see [x](suica-doc:x)\n"))
    }
}

@Suite struct DocumentDiskTests {
    private func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    private func names(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    }

    @Test func readGivesLFTextAndTheEnding() throws {
        let root = try tree(["a.md": "a\r\nb\r\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("big.md"), bad = root.appendingPathComponent("bad.md")
        try Data(repeating: 0x61, count: 1_000_001).write(to: big)
        try Data([0xFF, 0xFE]).write(to: bad)
        #expect(DocumentDisk.read(root.appendingPathComponent("a.md").path) == DiskDocument(text: "a\nb\n", ending: .crlf))
        for url in [root.appendingPathComponent("nope.md"), big, bad] { #expect(DocumentDisk.read(url.path) == nil) }
    }

    @Test func writeSavesAndKeepsCRLFAndTheBOM() throws {
        let root = try tree(["a.md": "\u{FEFF}a\r\nb"])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.md")
        #expect(DocumentDisk.write("\u{FEFF}a\nB", ending: .crlf, to: url.path, expecting: "\u{FEFF}a\nb") == .saved)
        #expect(try bytes(url) == Data("\u{FEFF}a\r\nB".utf8))
    }

    @Test func writeRefusesWhenTheFileChangedOnDisk() throws {
        let root = try tree(["a.md": "changed"])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.md")
        #expect(DocumentDisk.write("mine", ending: .lf, to: url.path, expecting: "orig") == .conflict)
        #expect(try bytes(url) == Data("changed".utf8))
        #expect(DocumentDisk.write("mine", ending: .lf, to: url.path, expecting: "orig", overwrite: true) == .saved)
        #expect(try bytes(url) == Data("mine".utf8))
    }

    @Test func writeKeepsPermissionsAndLeavesNoTempFile() throws {
        let root = try tree(["a.md": "x"])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        #expect(DocumentDisk.write("y", ending: .lf, to: url.path, expecting: "x") == .saved)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o640)
        #expect(try names(url) == ["a.md"])
    }

    @Test func writeFailsCleanlyForAReadOnlyDeletedOrTooBigFile() throws {
        let root = try tree(["ro.md": "x", "gone.md": "x", "big.md": "x"])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("ro.md").path)
            try? FileManager.default.removeItem(at: root)
        }
        let ro = root.appendingPathComponent("ro.md"), gone = root.appendingPathComponent("gone.md")
        let big = root.appendingPathComponent("big.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: ro.path)
        try FileManager.default.removeItem(at: gone)

        for outcome in [
            DocumentDisk.write("y", ending: .lf, to: ro.path, expecting: "x"),
            DocumentDisk.write("y", ending: .lf, to: ro.path, expecting: "x", overwrite: true),
            DocumentDisk.write("y", ending: .lf, to: gone.path, expecting: "x"),
            DocumentDisk.write("y", ending: .lf, to: gone.path, expecting: "x", overwrite: true),
            DocumentDisk.write(String(repeating: "a", count: 1_000_001), ending: .lf, to: big.path, expecting: "x"),
        ] {
            guard case .failed(let reason) = outcome else { Issue.record("expected .failed, got \(outcome)"); continue }
            #expect(!reason.isEmpty)
        }
        #expect(try bytes(ro) == Data("x".utf8))
        #expect(try bytes(big) == Data("x".utf8))
        #expect(!FileManager.default.fileExists(atPath: gone.path))
        #expect(try names(ro).sorted() == ["big.md", "ro.md"])
    }

    @Test func writeNeverReplacesAFileItCannotRead() throws {
        for unreadable in [Data(repeating: 0x61, count: 1_000_001), Data([0xFF, 0xFE, 0x41])] {
            let root = try tree(["a.md": "x"])
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("a.md")
            try unreadable.write(to: url)
            for overwrite in [false, true] {
                let outcome = DocumentDisk.write("mine", ending: .lf, to: url.path, expecting: "x", overwrite: overwrite)
                guard case .failed(let reason) = outcome else { Issue.record("expected .failed, got \(outcome)"); continue }
                #expect(!reason.isEmpty)
                #expect(try bytes(url) == unreadable)
                #expect(try names(url) == ["a.md"])
            }
        }
    }

    @Test func savingUnchangedTextRewritesTheSameBytes() throws {
        let root = try tree(["a.md": "x\r\n\r\ny"])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.md")
        let read = try #require(DocumentDisk.read(url.path))
        #expect(DocumentDisk.write(read.text, ending: read.ending, to: url.path, expecting: read.text) == .saved)
        #expect(try bytes(url) == Data("x\r\n\r\ny".utf8))
    }
}

@MainActor @Suite struct DocumentDraftTests {
    private func model() -> DocumentsModel {
        let plans = PlansModel(store: MemoryStore(), scan: { _ in [] })
        plans.addFolders(["/p"])
        return DocumentsModel(plans: plans, find: { _ in ([], false) })
    }

    private func edit(_ documents: DocumentsModel, _ path: String, _ text: String? = nil) async {
        documents.open(path: path)
        await documents.startEditing()
        if let text { documents.draftText = text }
    }

    private func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    @Test func typingMakesADraftAndRestoringTheTextRemovesIt() async throws {
        let root = try tree(["a.md": "orig"])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("a.md").path
        let documents = model()
        #expect(documents.mode == .view)
        await edit(documents, path, "new")
        #expect(documents.mode == .edit)
        #expect(documents.draft(for: path) == "new" && documents.unsavedPaths == [path])
        documents.draftText = "orig"
        #expect(documents.draft(for: path) == nil && documents.unsavedPaths.isEmpty)
        #expect(documents.draftText == "orig")
    }

    @Test func saveWritesTheFileAndClearsTheDraft() async throws {
        let root = try tree(["a.md": "orig"])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("a.md").path
        let documents = model()
        await edit(documents, path, "one")
        #expect(await documents.save() == .saved)
        #expect(try read(path) == "one" && documents.unsavedPaths.isEmpty && documents.saveError == nil)
        #expect(documents.draftText == "one")
        documents.draftText = "two"
        #expect(await documents.save() == .saved)
        #expect(try read(path) == "two")
    }

    @Test func savingWithoutADraftDoesNotTouchTheFile() async throws {
        let root = try tree(["a.md": "a\rb"])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("a.md").path
        let documents = model()
        await edit(documents, path)
        #expect(await documents.save() == .saved)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("a\rb".utf8))
    }

    @Test func saveRefusesAfterAnExternalChangeAndKeepsTheDraft() async throws {
        let root = try tree(["a.md": "orig"])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("a.md").path
        let documents = model()
        await edit(documents, path, "mine")
        try "theirs".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(await documents.save() == .conflict)
        #expect(try read(path) == "theirs" && documents.draft(for: path) == "mine")
        #expect(await documents.save(overwrite: true) == .saved)
        #expect(try read(path) == "mine")

        documents.draftText = "again"
        try "theirs2".write(toFile: path, atomically: true, encoding: .utf8)
        await documents.reload()
        #expect(documents.draft(for: path) == nil && documents.draftText == "theirs2")
    }

    @Test func aFailedSaveKeepsTheDraftAndSaysWhy() async throws {
        let root = try tree(["a.md": "orig"])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.md")
        let documents = model()
        await edit(documents, url.path, "mine")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        guard case .failed = await documents.save() else { Issue.record("expected .failed"); return }
        #expect(documents.saveError?.isEmpty == false && documents.draft(for: url.path) == "mine")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(await documents.save() == .saved)
        #expect(documents.saveError == nil)
    }

    @Test func draftsSurviveNavigationAndRescan() async throws {
        let root = try tree(["a.md": "A", "b.md": "B"])
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.md").path, b = root.appendingPathComponent("b.md").path
        let documents = model()
        await edit(documents, a, "mine")
        documents.open(path: b)
        documents.back()
        #expect(documents.draft(for: a) == "mine" && documents.unsavedPaths == [a])
        await documents.refresh()
        await documents.loadContent()
        #expect(documents.draft(for: a) == "mine" && documents.content == .text(entries: [], body: "mine"))
    }

    @Test func viewModeShowsTheDraftAsAPreview() async throws {
        let root = try tree(["a.md": "orig"])
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = model()
        await edit(documents, root.appendingPathComponent("a.md").path, "\u{FEFF}see [[x]]")
        documents.mode = .view
        await documents.loadContent()
        #expect(documents.content == .text(entries: [], body: "see [x](suica-doc:x)"))
        documents.revert()
        await documents.loadContent()
        #expect(documents.content == .text(entries: [], body: "orig"))
    }

    @Test func checkDiskReloadsACleanDocumentAndFlagsADirtyOne() async throws {
        let root = try tree(["a.md": "orig"])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("a.md").path
        let documents = model()
        documents.open(path: path)
        await documents.loadContent()
        try "new".write(toFile: path, atomically: true, encoding: .utf8)
        await documents.checkDisk()
        #expect(documents.content == .text(entries: [], body: "new") && !documents.diskChanged)

        await documents.startEditing()
        documents.draftText = "mine"
        try "newer".write(toFile: path, atomically: true, encoding: .utf8)
        await documents.checkDisk()
        #expect(documents.diskChanged && documents.draft(for: path) == "mine")
        #expect(await documents.save(overwrite: true) == .saved)
        #expect(!documents.diskChanged)
    }

    @Test func startEditingAnUnavailableFileStaysInViewMode() async throws {
        let root = try tree(["good.md": "good"])
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("big.md"), bad = root.appendingPathComponent("bad.md")
        try Data(repeating: 0x61, count: 1_000_001).write(to: big)
        try Data([0xFF, 0xFE]).write(to: bad)
        let documents = model()
        for url in [big, bad] {
            await edit(documents, root.appendingPathComponent("good.md").path)
            #expect(documents.mode == .edit)
            await edit(documents, url.path)
            #expect(documents.mode == .view && documents.unsavedPaths.isEmpty)
            documents.draftText = "x"  // no stale base from the previous file
            #expect(documents.unsavedPaths.isEmpty)
        }
    }

    @Test func typingBackToTheSavedTextClearsTheConflictAndTheError() async throws {
        let root = try tree(["a.md": "orig"])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.md")
        let documents = model()
        await edit(documents, url.path, "mine")
        try "theirs".write(to: url, atomically: true, encoding: .utf8)
        #expect(await documents.save() == .conflict && documents.diskChanged)
        documents.draftText = "orig"
        #expect(documents.draft(for: url.path) == nil && !documents.diskChanged)
        #expect(await documents.save() == .saved && !documents.diskChanged)

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        documents.draftText = "mine"
        guard case .failed = await documents.save() else { Issue.record("expected .failed"); return }
        #expect(documents.saveError != nil)
        documents.draftText = "orig"
        #expect(documents.saveError == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    @Test func aDocumentThatBecomesUneditableLeavesEditMode() async throws {
        let root = try tree(["a.md": "orig"])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.md")
        let documents = model()
        await edit(documents, url.path)
        #expect(documents.mode == .edit)
        try Data([0xFF, 0xFE]).write(to: url)
        await documents.checkDisk()
        #expect(documents.mode == .view && documents.unsavedPaths.isEmpty && documents.content == .unavailable)
    }

    @Test func saveAllAndDiscardAll() async throws {
        let root = try tree(["a.md": "A", "b.md": "B"])
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.md").path, b = root.appendingPathComponent("b.md").path
        let documents = model()
        await edit(documents, a, "A2")
        await edit(documents, b, "B2")
        #expect(documents.unsavedPaths == [a, b])
        #expect(await documents.saveAll() == [a: .saved, b: .saved])
        #expect(try [read(a), read(b)] == ["A2", "B2"])

        await edit(documents, a, "A3")
        await edit(documents, b, "B3")
        documents.discardAll()
        #expect(documents.unsavedPaths.isEmpty)
        #expect(try [read(a), read(b)] == ["A2", "B2"])
    }

    @Test func aSecondSaveWhileOneIsInFlightIsRefused() async throws {
        let root = try tree(["a.md": "orig"])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("a.md").path
        let documents = model()
        // Both calls run on the main actor: the first suspends on its disk write before the second starts, so they overlap.
        for round in 1...3 {
            await edit(documents, path, "mine \(round)")
            async let first = documents.save()
            async let second = documents.save()
            let outcomes = await [first, second]
            #expect(outcomes.contains(.saved) && outcomes.contains(.failed("The file is already being saved.")))
            #expect(try read(path) == "mine \(round)" && documents.unsavedPaths.isEmpty)
        }
    }
}
