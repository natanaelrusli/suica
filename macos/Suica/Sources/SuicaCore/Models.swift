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

/// How a finished message ended, from the Owner's point of view.
public enum ItemOutcome: Equatable, Sendable {
    case approvedByYou, sentAutomatically, sent, skippedByYou, noLongerNeeded, skipped, dryRun, failed
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
    /// Nil when the agent does not know (rows from before it recorded approvals, or an older agent).
    public let approved: Bool?
    /// True for a Review Notice saying you approved the MR in GitLab; nil from an older agent.
    public let mrApproved: Bool?
    public let createdAt: Int
    public let updatedAt: Int

    public init(
        id: Int, kind: String, status: String, detail: String, recipientName: String,
        mrKey: String, mrTitle: String, mrUrl: String, text: String?, approved: Bool? = nil,
        mrApproved: Bool? = nil, createdAt: Int, updatedAt: Int
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
        self.approved = approved
        self.mrApproved = mrApproved
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

    /// Nil while the message is not finished.
    public var outcome: ItemOutcome? {
        switch state {
        case .sent:
            switch approved {
            case true: .approvedByYou
            case false: .sentAutomatically
            case nil: .sent
            }
        // The agent's detail texts for a skip, see src/teams/dispatch.ts.
        case .skipped:
            switch detail {
            case "skipped by owner": .skippedByYou
            case "obsolete": .noLongerNeeded
            default: .skipped
            }
        case .dryRun: .dryRun
        case .failed: .failed
        default: nil
        }
    }

    /// Nudges, reminders and Re-review Nudges go to Reviewers of your own MRs; Review Notices go to
    /// the Authors of MRs you reviewed. An unknown kind counts as someone else's MR.
    public var isAboutYourMR: Bool { ["nudge", "reminder", "rereview"].contains(kind) }

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

public struct RunningReview: Codable, Equatable, Sendable {
    public let id: Int
    public let mrKey: String
    /// Nil until the run has read the MR.
    public let mrTitle: String?
    public let cli: String?
    /// Nil for the CLI's default model.
    public let model: String?
    /// Epoch milliseconds.
    public let startedAt: Int?

    public init(id: Int, mrKey: String, mrTitle: String?, cli: String?, model: String?, startedAt: Int?) {
        self.id = id
        self.mrKey = mrKey
        self.mrTitle = mrTitle
        self.cli = cli
        self.model = model
        self.startedAt = startedAt
    }
}

public struct QueuedReview: Codable, Equatable, Sendable {
    public let id: Int
    public let mrKey: String
    public let mrTitle: String?

    public init(id: Int, mrKey: String, mrTitle: String?) {
        self.id = id
        self.mrKey = mrKey
        self.mrTitle = mrTitle
    }
}

/// What the agent is reviewing now and what waits, in run order.
public struct ReviewActivity: Codable, Equatable, Sendable {
    public let running: RunningReview?
    public let queued: [QueuedReview]

    public init(running: RunningReview?, queued: [QueuedReview]) {
        self.running = running
        self.queued = queued
    }
}

public struct AgentState: Codable, Equatable, Sendable {
    public let version: Int
    public let paused: Bool
    public let baselineDone: Bool
    public let trackedAuthored: Int
    public let reviewRequested: Int
    public let teams: TeamsSection?
    /// Nil from an agent without Agent Review.
    public let agentReview: ReviewActivity?

    public init(
        version: Int, paused: Bool, baselineDone: Bool, trackedAuthored: Int, reviewRequested: Int,
        teams: TeamsSection?, agentReview: ReviewActivity? = nil
    ) {
        self.version = version
        self.paused = paused
        self.baselineDone = baselineDone
        self.trackedAuthored = trackedAuthored
        self.reviewRequested = reviewRequested
        self.teams = teams
        self.agentReview = agentReview
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
