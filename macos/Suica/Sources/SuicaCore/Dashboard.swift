import Foundation

// MARK: - JSON values

/// Any JSON value the config file can hold. Numbers are integers: a fraction is `badOutput`.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            // Objects are last so that a number with a fraction reports its own mismatch.
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Status

public struct AgentService: Codable, Equatable, Sendable {
    public let label: String
    public let loaded: Bool
    public let running: Bool
    public let pid: Int?
}

public struct PollEntry: Codable, Equatable, Sendable {
    public let at: Int
    /// "ok" or "failed"; kept as sent so a new value never fails the whole document.
    public let status: String
    public let failure: String?
    public let durationMs: Int
}

public struct PollingIntervals: Codable, Equatable, Sendable {
    public let activeSeconds: Int
    public let idleSeconds: Int
}

public struct StatusPaths: Codable, Equatable, Sendable {
    public let config: String
    public let state: String
    public let logs: String
    public let templates: String
}

/// `suica status --json`. `configError` is also set when the state database cannot be read; then
/// `paused` and `lastPoll` are nil but `teamsEnabled` and `polling` are filled. When the config
/// itself failed, `paused`, `teamsEnabled`, `lastPoll` and `polling` are all nil.
public struct StatusDocument: Codable, Equatable, Sendable {
    public let version: Int
    public let agent: AgentService
    public let configError: String?
    public let paused: Bool?
    public let teamsEnabled: Bool?
    public let lastPoll: PollEntry?
    public let polling: PollingIntervals?
    public let paths: StatusPaths
}

// MARK: - Stats

public struct PollCounts: Codable, Equatable, Sendable {
    public let ok: Int
    public let failed: Int
}

public struct Turnaround: Codable, Equatable, Sendable {
    public let count: Int
    public let medianMinutes: Int?
    public let p90Minutes: Int?
}

public struct DayStats: Codable, Equatable, Sendable {
    /// Local calendar day, `YYYY-MM-DD`.
    public let day: String
    public let reviewRequests: Int
    public let activity: Int
    public let nudgesSent: Int
    public let noticesSent: Int
    public let skipped: Int
    public let failed: Int
}

/// `suica stats`.
public struct StatsDocument: Codable, Equatable, Sendable {
    public let version: Int
    public let generatedAt: Int
    public let lastPoll: PollEntry?
    public let polls24h: PollCounts
    public let polls7d: PollCounts
    /// Oldest first.
    public let days: [DayStats]
    public let ownerAfterRequest: Turnaround
    public let reviewerAfterNudge: Turnaround
}

// MARK: - Config

public enum FieldType: String, Codable, Equatable, Sendable {
    case string, int, bool, `enum`, clock, weekdays, stringList, emailMap, unknown

    /// A type this app does not know decodes as `.unknown` and is shown read-only.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = FieldType(rawValue: text) ?? .unknown
    }
}

public struct ConfigField: Codable, Equatable, Sendable {
    public let path: [String]
    public let type: FieldType
    public let label: String
    public let help: String
    public let options: [String]?
    public let placeholder: String?
    public let restartNote: String?
    /// As written in the file; `.null` when absent.
    public let value: JSONValue
    /// After defaults; `.null` when absent or when the config is invalid.
    public let effective: JSONValue
}

public struct ConfigIssue: Codable, Equatable, Sendable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// `suica config show --json`.
public struct ConfigDocument: Codable, Equatable, Sendable {
    public let version: Int
    public let path: String
    public let exists: Bool
    /// Hex sha256 of the file bytes; nil when the file does not exist.
    public let sha256: String?
    public let issues: [ConfigIssue]
    public let fields: [ConfigField]
}

/// The answer of `suica config set --json`. It carries no version.
public struct SaveResult: Codable, Equatable, Sendable {
    /// saved, invalid, conflict or bad-request; kept as sent, like `ActionResult.code`.
    public let status: String
    public let issues: [ConfigIssue]
    /// Of the file written; nil unless `status` is "saved".
    public let sha256: String?
}

public struct ConfigEditRequest: Encodable, Equatable, Sendable {
    public let path: [String]
    /// `.null` removes the key.
    public let value: JSONValue

    public init(path: [String], value: JSONValue) {
        self.path = path
        self.value = value
    }
}

/// The stdin of `suica config set --json`.
struct SaveRequestBody: Encodable, Equatable {
    let baseSha256: String?
    let edits: [ConfigEditRequest]

    private enum CodingKeys: String, CodingKey { case baseSha256, edits }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // The agent requires the key: a missing base is null, not absent.
        try container.encode(baseSha256, forKey: .baseSha256)
        try container.encode(edits, forKey: .edits)
    }
}

// MARK: - Decoding

private struct DocumentVersion: Decodable {
    let version: Int
}

private let supportedDocumentVersion = 1

/// Reads `version` first so a future contract fails as `unsupportedVersion`, not as a field error.
public func decodeDocument<T: Decodable>(_ type: T.Type, from data: Data) throws(AgentError) -> T {
    let decoder = JSONDecoder()
    let version: Int
    do {
        version = try decoder.decode(DocumentVersion.self, from: data).version
    } catch {
        throw AgentError.badOutput
    }
    guard version == supportedDocumentVersion else { throw AgentError.unsupportedVersion(version) }
    do {
        return try decoder.decode(type, from: data)
    } catch {
        throw AgentError.badOutput
    }
}

// MARK: - Client

public protocol DashboardClient: Sendable {
    func status() async throws(AgentError) -> StatusDocument
    func stats() async throws(AgentError) -> StatsDocument
    func config() async throws(AgentError) -> ConfigDocument
    func saveConfig(base: String?, edits: [ConfigEditRequest]) async throws(AgentError) -> SaveResult
    func restartAgent() async throws(AgentError) -> ActionResult
}
