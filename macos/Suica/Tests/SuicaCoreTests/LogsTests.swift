import Foundation
import Testing

@testable import SuicaCore

@Test func parsesJsonLinesWithSortedAttributes() {
    let text = """
        {"timestamp":"2026-10-20T03:47:55.019Z","level":"info","message":"agent review ready","attributes":{"id":33,"cli":"claude","ok":true}}
        {"timestamp":"2026-10-20T03:48:50.346Z","level":"error","message":"poll failed"}
        """
    let entries = LogParser.entries(text)
    #expect(entries.count == 2)
    #expect(entries[0].level == "info")
    #expect(entries[0].message == "agent review ready")
    #expect(entries[0].attributes == "cli=claude id=33 ok=true")
    #expect(abs((entries[0].date?.timeIntervalSince1970 ?? 0) - 1_792_468_075.019) < 0.001)
    #expect(entries[1].level == "error")
    #expect(entries[1].attributes == nil)
    #expect(entries.map(\.id) == [0, 1])
}

@Test func keepsPlainLinesTogetherUntilTheNextJsonLine() {
    let text = """
        TypeError: boom
            at run (file.js:1:2)

            at main (file.js:3:4)
        {"timestamp":"2026-10-20T03:48:50.346Z","level":"warn","message":"retrying"}
        plain again
        """
    let entries = LogParser.entries(text)
    #expect(entries.count == 3)
    #expect(entries[0].level == nil)
    #expect(entries[0].message == "TypeError: boom\n    at run (file.js:1:2)\n    at main (file.js:3:4)")
    #expect(entries[1].message == "retrying")
    #expect(entries[2].message == "plain again")
}

@Test func treatsJsonWithoutAMessageAsPlainText() {
    let entries = LogParser.entries(#"{"level":"info"}"#)
    #expect(entries == [LogEntry(id: 0, date: nil, level: nil, message: #"{"level":"info"}"#, attributes: nil)])
}

@Test func matchesMessageAttributesAndLevelIgnoringCase() {
    let entry = LogEntry(id: 0, date: nil, level: "error", message: "Poll failed", attributes: "mr_key=a!1")
    #expect(entry.matches(""))
    #expect(entry.matches("poll"))
    #expect(entry.matches("A!1"))
    #expect(entry.matches("ERROR"))
    #expect(!entry.matches("teams"))
}

@Test func readsTheWholeSmallFileAndDropsTheCutLineOfALargeOne() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("stdout.log")
    try "first line\nsecond\nthird\n".write(to: url, atomically: true, encoding: .utf8)

    #expect(try LogTail.read(url, maxBytes: 1000) == LogTail(text: "first line\nsecond\nthird\n", truncated: false))
    // The last 10 bytes start inside "second".
    #expect(try LogTail.read(url, maxBytes: 10) == LogTail(text: "third\n", truncated: true))
    #expect(try LogTail.read(folder.appendingPathComponent("missing.log"), maxBytes: 10) == nil)
}

@MainActor @Test func modelReadsTheChosenStreamAndReportsAMissingFile() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try #"{"timestamp":"2026-10-20T03:48:50.346Z","level":"info","message":"started"}"#
        .write(to: folder.appendingPathComponent("stdout.log"), atomically: true, encoding: .utf8)

    let model = LogsModel()
    model.load(folder: folder.path)
    #expect(model.entries.map(\.message) == ["started"])
    #expect(!model.missing)

    model.stream = .errors
    model.load(folder: folder.path)
    #expect(model.entries.isEmpty)
    #expect(model.missing)
    #expect(model.errorText == nil)
}
