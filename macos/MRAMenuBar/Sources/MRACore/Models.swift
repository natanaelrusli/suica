import Foundation

public enum AgentError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case failed(exitCode: Int32)
    case badOutput
    case unsupportedVersion(Int)
}

public enum ItemState: Equatable, Sendable {
    case queued, pending, sending, sent, skipped, failed, unresolved, dryRun, unknown
}

public enum ItemAction: Equatable, Sendable {
    case send, skip, retry
}

public struct OutboxItem: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let kind: String
    public let status: String
    public let detail: String
    public let recipientName: String
    public let mrKey: String
    public let mrTitle: String
    public let mrUrl: String
    public let text: String?
    public let createdAt: Int
    public let updatedAt: Int

    public init(
        id: Int, kind: String, status: String, detail: String, recipientName: String,
        mrKey: String, mrTitle: String, mrUrl: String, text: String?, createdAt: Int,
        updatedAt: Int
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.detail = detail
        self.recipientName = recipientName
        self.mrKey = mrKey
        self.mrTitle = mrTitle
        self.mrUrl = mrUrl
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var state: ItemState {
        switch status {
        case "queued": .queued
        case "pending": .pending
        case "sending": .sending
        case "sent": .sent
        case "skipped": .skipped
        case "failed": .failed
        case "unresolved": .unresolved
        case "dry-run": .dryRun
        default: .unknown
        }
    }

    public var actions: [ItemAction] {
        switch state {
        case .pending: [.send, .skip]
        case .unresolved: [.retry, .skip]
        case .queued: [.skip]
        default: []
        }
    }
}

public struct TeamsSection: Codable, Equatable, Sendable {
    public let counts: [String: Int]
    public let attentionHidden: Int
    public let attention: [OutboxItem]
    public let recent: [OutboxItem]

    public init(counts: [String: Int], attentionHidden: Int, attention: [OutboxItem], recent: [OutboxItem]) {
        self.counts = counts
        self.attentionHidden = attentionHidden
        self.attention = attention
        self.recent = recent
    }
}

public struct AgentState: Codable, Equatable, Sendable {
    public let version: Int
    public let paused: Bool
    public let baselineDone: Bool
    public let trackedAuthored: Int
    public let reviewRequested: Int
    public let teams: TeamsSection?

    public init(
        version: Int, paused: Bool, baselineDone: Bool, trackedAuthored: Int, reviewRequested: Int,
        teams: TeamsSection?
    ) {
        self.version = version
        self.paused = paused
        self.baselineDone = baselineDone
        self.trackedAuthored = trackedAuthored
        self.reviewRequested = reviewRequested
        self.teams = teams
    }
}

private struct VersionOnly: Decodable {
    let version: Int
}

private let supportedVersion = 1

/// Reads `version` first so a future contract fails as `unsupportedVersion`, not as a field error.
public func decodeAgentState(_ data: Data) throws(AgentError) -> AgentState {
    let decoder = JSONDecoder()
    let version: Int
    do {
        version = try decoder.decode(VersionOnly.self, from: data).version
    } catch {
        throw AgentError.badOutput
    }
    guard version == supportedVersion else { throw AgentError.unsupportedVersion(version) }
    do {
        return try decoder.decode(AgentState.self, from: data)
    } catch {
        throw AgentError.badOutput
    }
}
