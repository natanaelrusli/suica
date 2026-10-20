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

/// The Logs page: the end of the agent's output or error log, read again when the file changes.
@MainActor @Observable
public final class LogsModel {
    public static let maxBytes = 512 * 1024

    public var stream: LogStream = .output
    public private(set) var entries: [LogEntry] = []
    public private(set) var truncated = false
    /// The file does not exist yet.
    public private(set) var missing = false
    public private(set) var errorText: String?
    /// The file's size and modification date when it was last read, so an unchanged file is not
    /// parsed again on every tick.
    @ObservationIgnored private var lastRead: (stream: LogStream, folder: String, size: Int, modified: Date?)?

    public init() {}

    public func url(in folder: String) -> URL {
        URL(fileURLWithPath: folder).appendingPathComponent(stream.fileName)
    }

    /// Reads the file again when it changed since the last read, or `force` is set.
    public func load(folder: String, force: Bool = false) {
        let url = url(in: folder)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
        let modified = attributes?[.modificationDate] as? Date
        if !force, let last = lastRead, last.stream == stream, last.folder == folder, last.size == size,
            last.modified == modified
        {
            return
        }
        lastRead = (stream, folder, size, modified)
        do {
            let tail = try LogTail.read(url, maxBytes: Self.maxBytes)
            missing = tail == nil
            truncated = tail?.truncated ?? false
            entries = tail.map { LogParser.entries($0.text) } ?? []
            errorText = nil
        } catch {
            errorText = Copy.logReadFailed(error.localizedDescription)
        }
    }
}
