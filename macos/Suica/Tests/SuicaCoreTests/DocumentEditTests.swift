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
