import Foundation

// MARK: - JSON values

/// Any JSON value the config file can hold. A whole number that fits `Int` is `.int`; any other
/// number (a fraction, or one too large) is `.number`, so one odd value never hides the document.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
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
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
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

public struct DetectedModelCli: Codable, Equatable, Sendable {
    /// claude, codex or gemini; kept as sent so a CLI added later never fails the whole document.
    public let id: String
    public let name: String
    /// Nil when it is not installed.
    public let path: String?

    public init(id: String, name: String, path: String?) {
        self.id = id
        self.name = name
        self.path = path
    }
}

public struct ModelCliStatus: Codable, Equatable, Sendable {
    /// `model.cli` (auto or a CLI id); nil when the config could not be loaded.
    public let selected: String?
    /// The id of the CLI language model work runs with; nil when none fits.
    public let active: String?
    public let clis: [DetectedModelCli]

    public init(selected: String?, active: String?, clis: [DetectedModelCli]) {
        self.selected = selected
        self.active = active
        self.clis = clis
    }
}

/// Agent Review in the status document: the settings that matter on Overview and the activity.
public struct StatusAgentReview: Codable, Equatable, Sendable {
    public let auto: Bool
    /// `review.post`: approval or auto; nil from an agent without the setting.
    public let post: String?
    /// `review.postAs`: comment or inline; nil from an agent without the setting.
    public let postAs: String?
    /// `review.model`; nil for the CLI's default.
    public let model: String?
    public let running: RunningReview?
    public let queued: [QueuedReview]
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
    /// Nil from an agent older than the model CLI switch.
    public var modelCli: ModelCliStatus? = nil
    /// Nil when the config or the state database could not be read, or from an older agent.
    public var agentReview: StatusAgentReview? = nil
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

/// Someone in a ranking, by the distinct MRs counted for them.
public struct PersonCount: Codable, Equatable, Sendable {
    public let username: String
    public let name: String
    public let mergeRequests: Int
}

/// One of your MRs and how long it waited for its first approval.
public struct SlowApproval: Codable, Equatable, Sendable {
    public let mrKey: String
    public let title: String
    public let url: String
    /// Epoch milliseconds.
    public let openedAt: Int
    public let approvedAt: Int
    public let minutes: Int
    public let approver: Person
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
    /// The last 90 days, at most 10 each. Nil from an older agent.
    public var peopleIReview: [PersonCount]? = nil
    public var peopleWhoReviewMe: [PersonCount]? = nil
    public var slowestApprovals: [SlowApproval]? = nil
}

// MARK: - Token usage

/// Language model tokens summed over some runs.
public struct TokenTotals: Codable, Equatable, Sendable {
    public let runs: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int

    public init(runs: Int, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheCreationTokens: Int) {
        self.runs = runs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    public var allTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
}

public struct PurposeUsage: Codable, Equatable, Sendable {
    /// review, reply, other; kept as sent so a new purpose never fails the whole document.
    public let purpose: String
    public let runs: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int

    public var totals: TokenTotals {
        TokenTotals(
            runs: runs, inputTokens: inputTokens, outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens, cacheCreationTokens: cacheCreationTokens)
    }
}

public struct DayUsage: Codable, Equatable, Sendable {
    /// Local calendar day, `YYYY-MM-DD`.
    public let day: String
    public let runs: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
}

/// `suica usage`.
public struct UsageDocument: Codable, Equatable, Sendable {
    public let version: Int
    public let generatedAt: Int
    public let last24h: TokenTotals
    public let last7d: TokenTotals
    public let last30d: TokenTotals
    /// Over the last 30 days, most tokens first.
    public let byPurpose: [PurposeUsage]
    /// Oldest first.
    public let days: [DayUsage]
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

/// One part of the Configuration page: a field's first path component, or Storage for a
/// top-level key such as `statePath`.
public struct ConfigCategory: Hashable, Identifiable, Sendable {
    public let key: String

    public init(key: String) { self.key = key }

    public var id: String { key }
    public var title: String { key == Self.storageKey ? Copy.storage : Copy.groupHeading(key) }

    static let storageKey = "storage"

    /// In the order the agent lists its fields, so the sidebar can show them before the config loads.
    public static let known = ["gitlab", "polling", "notifications", "teams", "model", "review", storageKey]
        .map(ConfigCategory.init)

    public static func of(_ field: ConfigField) -> ConfigCategory {
        ConfigCategory(key: field.path.count > 1 ? field.path[0] : storageKey)
    }
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
    func usage() async throws(AgentError) -> UsageDocument
    func config() async throws(AgentError) -> ConfigDocument
    func saveConfig(base: String?, edits: [ConfigEditRequest]) async throws(AgentError) -> SaveResult
    func restartAgent() async throws(AgentError) -> ActionResult
}
