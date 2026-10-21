import Foundation
import Observation

/// One of the two files launchd writes the background agent's output to.
public enum LogStream: String, CaseIterable, Identifiable, Sendable {
    case output, errors

    public var id: String { rawValue }

    public var fileName: String {
        switch self {
        case .output: "stdout.log"
        case .errors: "stderr.log"
        }
    }
}

/// One entry of a log file: a JSON line the agent wrote, or a run of other lines (a Node stack
/// trace, say), kept together as they were written.
public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: Int
    public let date: Date?
    /// debug, info, warn or error; nil for lines that are not JSON.
    public let level: String?
    public var message: String
    /// The attributes as `key=value` pairs, keys sorted; nil when there are none.
    public let attributes: String?

    public init(id: Int, date: Date?, level: String?, message: String, attributes: String?) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
        self.attributes = attributes
    }

    public func matches(_ query: String) -> Bool {
        query.isEmpty || message.localizedCaseInsensitiveContains(query)
            || attributes?.localizedCaseInsensitiveContains(query) == true
            || level?.localizedCaseInsensitiveContains(query) == true
    }
}

public enum LogParser {
    public static func entries(_ text: String) -> [LogEntry] {
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var entries: [LogEntry] = []
        var previousWasPlain = false
        for line in text.split(whereSeparator: \.isNewline) {
            if let entry = json(String(line), id: entries.count, dates: dates) {
                entries.append(entry)
                previousWasPlain = false
            } else if line.allSatisfy(\.isWhitespace) {
                continue
            } else if previousWasPlain {
                entries[entries.count - 1].message += "\n" + line
            } else {
                entries.append(LogEntry(id: entries.count, date: nil, level: nil, message: String(line), attributes: nil))
                previousWasPlain = true
            }
        }
        return entries
    }

    private static func json(_ line: String, id: Int, dates: ISO8601DateFormatter) -> LogEntry? {
        guard line.hasPrefix("{"),
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let message = object["message"] as? String
        else { return nil }
        let attributes = (object["attributes"] as? [String: Any]).flatMap { pairs($0) }
        return LogEntry(
            id: id, date: (object["timestamp"] as? String).flatMap { dates.date(from: $0) },
            level: object["level"] as? String, message: message, attributes: attributes)
    }

    private static func pairs(_ attributes: [String: Any]) -> String? {
        guard !attributes.isEmpty else { return nil }
        return attributes.keys.sorted().map { key in
            let value = attributes[key]!
            if let text = value as? String { return "\(key)=\(text)" }
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) {
                return "\(key)=\(String(decoding: data, as: UTF8.self))"
            }
            return "\(key)=\(value)"
        }.joined(separator: " ")
    }
}

/// The end of a log file. The agent does not rotate its logs, so only the last part is read.
public struct LogTail: Equatable, Sendable {
    public let text: String
    /// Earlier lines were left out.
    public let truncated: Bool

    /// Nil when the file does not exist yet.
    public static func read(_ url: URL, maxBytes: Int) throws -> LogTail? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        if start > 0 {
            // The first line was cut in the middle.
            if let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                data = data[data.index(after: newline)...]
            } else {
                data = Data()
            }
        }
        return LogTail(text: String(decoding: data, as: UTF8.self), truncated: start > 0)
    }
}

/// Entries written within a date range. An entry without a date (a stack trace) belongs with the
/// dated entry before it; one with no dated entry before it is left out.
public enum LogFilter {
    public static func within(_ entries: [LogEntry], _ range: ClosedRange<Date>) -> [LogEntry] {
        var date: Date?
        return entries.filter { entry in
            date = entry.date ?? date
            return date.map(range.contains) ?? false
        }
    }

    /// From the start of the day of `from` to the end of the day of `to`, in either order.
    public static func days(from: Date, to: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let first = calendar.startOfDay(for: min(from, to))
        let lastDay = calendar.startOfDay(for: max(from, to))
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay)!.addingTimeInterval(-0.001)
        return first...end
    }
}

/// The Logs page: the end of the agent's output or error log, read again when the file changes.
@MainActor @Observable
public final class LogsModel {
    /// How many entries the page shows unless the person picks another number, so it parses and
    /// lays out a few hundred rows, not thousands, each time the agent writes.
    public static let defaultLimit = 200
    public static let limitChoices = [50, 100, 200, 500, 1000, 2000]
    /// The first read: about 700 lines of 180 bytes, the agent's usual line.
    static let firstReadBytes = 128 * 1024
    /// Reads grow fourfold until they hold enough entries, up to this much. The agent does not
    /// rotate its logs, so a date range far back in a large file stops here.
    public static let maxBytes = 32 * 1024 * 1024

    public var stream: LogStream = .output
    /// The most entries shown, the latest ones.
    public var limit = LogsModel.defaultLimit
    /// Only entries written in this range are shown; nil shows them all.
    public var dateRange: ClosedRange<Date>?
    public private(set) var entries: [LogEntry] = []
    /// Earlier entries were left out, by `limit` or `maxBytes`.
    public private(set) var truncated = false
    /// The file does not exist yet.
    public private(set) var missing = false
    public private(set) var errorText: String?
    /// What was read last time, so an unchanged file is not parsed again on every tick.
    @ObservationIgnored private var lastRead: ReadKey?

    private struct ReadKey: Equatable {
        let stream: LogStream
        let folder: String
        let size: Int
        let modified: Date?
        let limit: Int
        let dateRange: ClosedRange<Date>?
    }

    public init() {}

    public func url(in folder: String) -> URL {
        URL(fileURLWithPath: folder).appendingPathComponent(stream.fileName)
    }

    /// Reads the file again when it, the limit or the range changed since the last read, or
    /// `force` is set.
    public func load(folder: String, force: Bool = false) {
        let url = url(in: folder)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = ReadKey(
            stream: stream, folder: folder, size: (attributes?[.size] as? NSNumber)?.intValue ?? -1,
            modified: attributes?[.modificationDate] as? Date, limit: limit, dateRange: dateRange)
        if !force, key == lastRead { return }
        lastRead = key
        do {
            var bytes = Self.firstReadBytes
            while true {
                let tail = try LogTail.read(url, maxBytes: bytes)
                let parsed = tail.map { LogParser.entries($0.text) } ?? []
                let kept = dateRange.map { LogFilter.within(parsed, $0) } ?? parsed
                // Entries come in the order they were written, so once the read reaches back past
                // the range, reading further finds nothing more in it.
                let firstDate = parsed.lazy.compactMap(\.date).first
                let pastRange = dateRange.map { range in firstDate.map { $0 < range.lowerBound } ?? false } ?? false
                let readAll = !(tail?.truncated ?? false) || pastRange
                if readAll || kept.count > limit || bytes >= Self.maxBytes {
                    missing = tail == nil
                    truncated = !readAll || kept.count > limit
                    entries = Array(kept.suffix(limit))
                    errorText = nil
                    return
                }
                bytes = min(bytes * 4, Self.maxBytes)
            }
        } catch {
            errorText = Copy.logReadFailed(error.localizedDescription)
        }
    }
}
