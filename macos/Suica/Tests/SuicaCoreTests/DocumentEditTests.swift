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
