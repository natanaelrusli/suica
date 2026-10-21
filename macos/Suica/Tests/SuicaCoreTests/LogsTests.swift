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

/// A log folder holding `stdout.log` with these lines; removed by the caller.
private func logFolder(_ lines: [String]) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("stdout.log"), atomically: true, encoding: .utf8)
    return folder
}

private func line(_ day: Int, _ message: String) -> String {
    #"{"timestamp":"2026-10-\#(day)T03:48:50.346Z","level":"info","message":"\#(message)"}"#
}

private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

@MainActor @Test func modelShowsTheLatest200EntriesByDefault() throws {
    let folder = try logFolder((1...220).map { line(20, "poll \($0)") })
    defer { try? FileManager.default.removeItem(at: folder) }

    let model = LogsModel()
    model.load(folder: folder.path)
    #expect(model.entries.count == 200)
    #expect(model.entries.first?.message == "poll 21")
    #expect(model.entries.last?.message == "poll 220")
    #expect(model.truncated)

    // A new limit is read without `force`.
    model.limit = 500
    model.load(folder: folder.path)
    #expect(model.entries.count == 220)
    #expect(!model.truncated)
}

@MainActor @Test func modelReadsFurtherBackForALargeLimit() throws {
    // About 100 bytes a line, so 2000 lines are well past the first read.
    let folder = try logFolder((1...3000).map { line(20, "poll \($0)") })
    defer { try? FileManager.default.removeItem(at: folder) }

    let model = LogsModel()
    model.limit = 2000
    model.load(folder: folder.path)
    #expect(model.entries.count == 2000)
    #expect(model.entries.first?.message == "poll 1001")
    #expect(model.truncated)
}

@MainActor @Test func modelShowsOnlyEntriesInTheDateRange() throws {
    // Day 18 lies before the first read of the end of the file.
    let folder = try logFolder(
        (1...10).map { line(17, "old \($0)") } + (1...300).map { line(18, "in \($0)") }
            + (1...3000).map { line(19, "new \($0)") })
    defer { try? FileManager.default.removeItem(at: folder) }

    let model = LogsModel()
    model.dateRange = utc("2026-10-18T00:00:00Z")...utc("2026-10-18T23:59:59Z")
    model.load(folder: folder.path)
    #expect(model.entries.count == 200)
    #expect(model.entries.first?.message == "in 101")
    #expect(model.entries.last?.message == "in 300")
    #expect(model.truncated)

    model.limit = 500
    model.load(folder: folder.path)
    #expect(model.entries.count == 300)
    #expect(model.entries.first?.message == "in 1")
    // The read reached day 17, so nothing in the range was left out.
    #expect(!model.truncated)

    model.dateRange = utc("2026-10-25T00:00:00Z")...utc("2026-10-26T00:00:00Z")
    model.load(folder: folder.path)
    #expect(model.entries.isEmpty)
}

@Test func undatedEntriesGoWithTheDatedEntryBeforeThem() {
    let entries = [
        LogEntry(id: 0, date: nil, level: nil, message: "orphan", attributes: nil),
        LogEntry(id: 1, date: utc("2026-10-17T10:00:00Z"), level: "info", message: "before", attributes: nil),
        LogEntry(id: 2, date: nil, level: nil, message: "trace before", attributes: nil),
        LogEntry(id: 3, date: utc("2026-10-18T10:00:00Z"), level: "error", message: "inside", attributes: nil),
        LogEntry(id: 4, date: nil, level: nil, message: "trace inside", attributes: nil),
    ]
    let range = utc("2026-10-18T00:00:00Z")...utc("2026-10-19T00:00:00Z")
    #expect(LogFilter.within(entries, range).map(\.message) == ["inside", "trace inside"])
}

@Test func dayRangeCoversWholeDaysInEitherOrder() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Jakarta")!
    let range = LogFilter.days(from: utc("2026-10-20T18:00:00Z"), to: utc("2026-10-18T01:00:00Z"), calendar: calendar)
    // 20 Oct 18:00 UTC is already 21 Oct in Jakarta (UTC+7).
    #expect(range.lowerBound == utc("2026-10-17T17:00:00Z"))
    #expect(range.contains(utc("2026-10-21T16:59:59Z")))
    #expect(!range.contains(utc("2026-10-21T17:00:00Z")))
}
