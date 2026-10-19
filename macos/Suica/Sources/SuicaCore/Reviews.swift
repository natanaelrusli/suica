import Foundation
import Observation

// MARK: - Documents

public struct Person: Codable, Equatable, Sendable {
    public let username: String
    public let name: String

    public init(username: String, name: String) {
        self.username = username
        self.name = name
    }
}

public struct ReviewerInfo: Codable, Equatable, Sendable {
    public let username: String
    public let name: String
    /// GitLab's review state (UNREVIEWED, REVIEWED, REQUESTED_CHANGES, APPROVED, …), kept as sent.
    public let state: String

    public init(username: String, name: String, state: String) {
        self.username = username
        self.name = name
        self.state = state
    }
}

/// The newest Agent Review of an MR.
public struct AgentReviewInfo: Codable, Equatable, Sendable {
    public let id: Int
    /// queued, running, ready, posting, posted, discarded, failed or skipped; kept as sent.
    public let status: String
    public let cli: String?
    /// As the CLI reported it, else `review.model`; nil until known or for the CLI's default.
    public let model: String?
    /// Epoch milliseconds; nil while queued.
    public let startedAt: Int?
    public let headSha: String?
    /// Markdown as the model wrote it.
    public let body: String?
    public let detail: String
    public let createdAt: Int
    public let updatedAt: Int

    public init(
        id: Int, status: String, cli: String? = nil, model: String? = nil, startedAt: Int? = nil,
        headSha: String? = nil, body: String? = nil, detail: String = "", createdAt: Int = 0, updatedAt: Int = 0
    ) {
        self.id = id
        self.status = status
        self.cli = cli
        self.model = model
        self.startedAt = startedAt
        self.headSha = headSha
        self.body = body
        self.detail = detail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The agent is still on it: the page refreshes until it is done.
    public var isActive: Bool { status == "queued" || status == "running" || status == "posting" }
    /// Written and waiting for the Owner to post or discard it.
    public var isReady: Bool { status == "ready" }
    /// Another review can be started.
    public var canRequeue: Bool { !isActive && !isReady }
}

public struct ReviewSummary: Codable, Equatable, Identifiable, Sendable {
    public let key: String
    public let title: String
    public let url: String
    public let draft: Bool
    /// ISO 8601; nil when GitLab did not say, or from an older agent.
    public let createdAt: String?
    public let author: Person
    public let reviewers: [ReviewerInfo]
    /// Nil when the agent never reviewed it, or from an agent without Agent Review.
    public let agentReview: AgentReviewInfo?

    public var id: String { key }

    public var createdDate: Date? { createdAt.flatMap(MRNote.parse) }

    public init(
        key: String, title: String, url: String, draft: Bool, createdAt: String? = nil, author: Person,
        reviewers: [ReviewerInfo], agentReview: AgentReviewInfo? = nil
    ) {
        self.key = key
        self.title = title
        self.url = url
        self.draft = draft
        self.createdAt = createdAt
        self.author = author
        self.reviewers = reviewers
        self.agentReview = agentReview
    }
}

/// `suica reviews --json`: open MRs where the Owner is a Reviewer.
public struct ReviewListDocument: Codable, Equatable, Sendable {
    public let version: Int
    /// The Owner; nil from an agent older than the grouped list.
    public let me: Person?
    public let mergeRequests: [ReviewSummary]

    public init(version: Int, me: Person? = nil, mergeRequests: [ReviewSummary]) {
        self.version = version
        self.me = me
        self.mergeRequests = mergeRequests
    }

    /// The Owner's review state on this MR, as GitLab lists it; nil when unknown.
    public func myState(_ mr: ReviewSummary) -> String? {
        guard let me else { return nil }
        return mr.reviewers.first { $0.username == me.username }?.state
    }

    /// The list as the page shows it: non-empty groups in `ReviewGroup` order, each in GitLab's
    /// order. A non-draft MR waits for the Owner while the Owner's state is UNREVIEWED, the rule
    /// the menu bar badge uses. Without `me` nothing can be told apart, so every MR is in `all`.
    public var sections: [ReviewSection] {
        guard me != nil else { return mergeRequests.isEmpty ? [] : [ReviewSection(group: .all, items: mergeRequests)] }
        let grouped = Dictionary(grouping: mergeRequests) { mr -> ReviewGroup in
            if mr.draft { return .drafts }
            return (myState(mr) ?? "UNREVIEWED") == "UNREVIEWED" ? .waiting : .reviewed
        }
        return ReviewGroup.allCases.compactMap { group in
            grouped[group].map { ReviewSection(group: group, items: $0) }
        }
    }
}

public enum ReviewGroup: CaseIterable, Sendable {
    case waiting, reviewed, drafts, all
}

public struct ReviewSection: Equatable, Sendable {
    public let group: ReviewGroup
    public let items: [ReviewSummary]
}

extension ReviewSummary {
    /// Reviewers who approved, out of all reviewers.
    public var approvals: (approved: Int, total: Int) {
        (reviewers.filter { $0.state == "APPROVED" }.count, reviewers.count)
    }
}

public struct MRNote: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let body: String
    public let system: Bool
    /// ISO 8601, as GitLab sends it.
    public let createdAt: String
    public let author: Person
    public let filePath: String?
    public let line: Int?

    public var date: Date? { Self.parse(createdAt) }

    static func parse(_ text: String) -> Date? {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return (try? Date(text, strategy: .iso8601)) ?? (try? Date(text, strategy: withFraction))
    }
}

public struct MRDiscussion: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let resolvable: Bool
    public let resolved: Bool
    public let notes: [MRNote]

    /// GitLab's own activity ("added 2 commits", "requested review from …").
    public var isSystem: Bool { notes.allSatisfy(\.system) }
}

public struct DiffFile: Codable, Equatable, Identifiable, Sendable {
    public let oldPath: String
    public let newPath: String
    public let newFile: Bool
    public let renamedFile: Bool
    public let deletedFile: Bool
    /// Nil when the diff was too large to include.
    public let diff: String?

    public var id: String { "\(oldPath)→\(newPath)" }
}

/// `suica mr <key> --json`.
public struct MergeRequestDetail: Codable, Equatable, Sendable {
    public let version: Int
    public let key: String
    public let title: String
    public let description: String
    public let url: String
    public let draft: Bool
    public let sourceBranch: String
    public let targetBranch: String
    public let createdAt: String
    public let updatedAt: String
    public let author: Person
    public let labels: [String]
    public let pipelineStatus: String?
    public let additions: Int?
    public let deletions: Int?
    public let reviewers: [ReviewerInfo]
    public let approvedBy: [Person]
    /// True when merging squashes the commits; nil from an agent older than approving.
    public let squashOnMerge: Bool?
    /// The commit the diff was taken at; an approval is tied to it.
    public let headSha: String?
    /// True when GitLab lets you approve this MR now; nil from an agent older than approving.
    public let canApprove: Bool?
    public let discussions: [MRDiscussion]
    public let discussionsTruncated: Bool
    public let files: [DiffFile]
    public let filesTruncated: Bool

    public var updatedDate: Date? { MRNote.parse(updatedAt) }

    /// The project's web address, from the MR's (`…/group/project/-/merge_requests/7`).
    public var projectURL: String? {
        url.range(of: "/-/merge_requests/").map { String(url[..<$0.lowerBound]) }
    }

    /// Discussions people wrote, without GitLab's activity notes.
    public var comments: [MRDiscussion] { discussions.filter { !$0.isSystem } }
}

// MARK: - Diff lines

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case hunk, added, removed, context, note }

    public let kind: Kind
    /// Without the leading `+`, `-` or space.
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

private nonisolated(unsafe) let hunkHeader = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/

/// Splits a unified diff into numbered lines. Unknown lines (such as "\ No newline at end of
/// file") are kept as notes, and a malformed hunk header leaves the following lines unnumbered.
public func parseDiffLines(_ diff: String) -> [DiffLine] {
    var old: Int?
    var new: Int?
    var lines: [DiffLine] = []
    var rows = diff.split(separator: "\n", omittingEmptySubsequences: false)
    if rows.last == "" { rows.removeLast() }
    for row in rows {
        let text = String(row.dropFirst())
        switch row.first {
        case "@":
            if let match = row.firstMatch(of: hunkHeader) {
                old = Int(match.1)
                new = Int(match.2)
            } else {
                old = nil
                new = nil
            }
            lines.append(DiffLine(kind: .hunk, text: String(row), oldNumber: nil, newNumber: nil))
        case "+":
            lines.append(DiffLine(kind: .added, text: text, oldNumber: nil, newNumber: new))
            new = new.map { $0 + 1 }
        case "-":
            lines.append(DiffLine(kind: .removed, text: text, oldNumber: old, newNumber: nil))
            old = old.map { $0 + 1 }
        case " ", nil:
            lines.append(DiffLine(kind: .context, text: text, oldNumber: old, newNumber: new))
            old = old.map { $0 + 1 }
            new = new.map { $0 + 1 }
        default:
            lines.append(DiffLine(kind: .note, text: String(row), oldNumber: nil, newNumber: nil))
        }
    }
    return lines
}

// MARK: - Client

public protocol ReviewsClient: Sendable {
    func reviews() async throws(AgentError) -> ReviewListDocument
    func mergeRequest(key: String) async throws(AgentError) -> MergeRequestDetail
    /// queued, already-queued or bad-key.
    func queueAgentReview(key: String) async throws(AgentError) -> ActionResult
    /// posted, nothing or failed. `inline` puts findings on their diff lines as threads.
    func postAgentReview(id: Int, inline: Bool) async throws(AgentError) -> ActionResult
    /// discarded or nothing.
    func discardAgentReview(id: Int) async throws(AgentError) -> ActionResult
    /// Approves the MR as you at `sha`: approved, head-changed, bad-request or failed.
    func approve(key: String, sha: String) async throws(AgentError) -> ActionResult
}

// MARK: - Model

/// The Review requests page: the list, the selected MR and its details. Details are cached per
/// MR until the list is refreshed or the MR is reloaded.
@MainActor @Observable
public final class ReviewsModel {
    /// The last good list: a failed refresh does not clear it.
    public private(set) var list: ReviewListDocument?
    public private(set) var errorText: String?
    public private(set) var loadingList = false
    public private(set) var selectedKey: String?
    public private(set) var details: [String: MergeRequestDetail] = [:]
    public private(set) var detailErrors: [String: String] = [:]
    public private(set) var loadingKeys: Set<String> = []
    /// MRs with an Agent Review action in flight.
    public private(set) var agentBusyKeys: Set<String> = []
    /// The outcome of the last Agent Review action.
    public private(set) var agentBanner: String?
    /// MRs with an approval in flight.
    public private(set) var approvingKeys: Set<String> = []
    /// The outcome of the last approval, per MR.
    public private(set) var approvalNotices: [String: String] = [:]

    @ObservationIgnored private let client: any ReviewsClient
    @ObservationIgnored private var latestRefresh = 0
    @ObservationIgnored private var latestDetail: [String: Int] = [:]

    public init(client: any ReviewsClient) {
        self.client = client
    }

    public var selectedDetail: MergeRequestDetail? { selectedKey.flatMap { details[$0] } }

    public func agentReview(for key: String) -> AgentReviewInfo? {
        list?.mergeRequests.first { $0.key == key }?.agentReview
    }

    /// True while a review is queued, running or being posted: the page keeps refreshing.
    public var hasActiveAgentReview: Bool {
        list?.mergeRequests.contains { $0.agentReview?.isActive == true } ?? false
    }

    public func queueAgentReview(_ key: String) async {
        await agentAction(key) { (client: any ReviewsClient) async throws(AgentError) -> ActionResult in try await client.queueAgentReview(key: key) }
    }

    public func postAgentReview(_ key: String, inline: Bool) async {
        guard let review = agentReview(for: key), review.isReady else { return }
        await agentAction(key) { (client: any ReviewsClient) async throws(AgentError) -> ActionResult in
            try await client.postAgentReview(id: review.id, inline: inline)
        }
    }

    public func discardAgentReview(_ key: String) async {
        guard let review = agentReview(for: key) else { return }
        await agentAction(key) { (client: any ReviewsClient) async throws(AgentError) -> ActionResult in try await client.discardAgentReview(id: review.id) }
    }

    /// True when you are among the MR's approvers.
    public func isApprovedByMe(_ detail: MergeRequestDetail) -> Bool {
        guard let me = list?.me else { return false }
        return detail.approvedBy.contains { $0.username == me.username }
    }

    /// Shown when GitLab lets you approve, you have not yet, and the commit you saw is known.
    public func canApprove(_ detail: MergeRequestDetail) -> Bool {
        detail.canApprove == true && detail.headSha != nil && !isApprovedByMe(detail)
    }

    /// Approves at the commit on screen, then reads the MR and the list again.
    public func approve(_ key: String) async {
        guard let detail = details[key], canApprove(detail), let sha = detail.headSha,
            !approvingKeys.contains(key)
        else { return }
        approvingKeys.insert(key)
        do {
            approvalNotices[key] = Copy.approveOutcome(try await client.approve(key: key, sha: sha).code)
        } catch {
            approvalNotices[key] = MenuModel.message(for: error)
        }
        await loadDetail(key)
        approvingKeys.remove(key)
        await refresh()
    }

    /// One action per MR at a time; the list is read again afterwards so the state is current.
    private func agentAction(
        _ key: String, _ run: (any ReviewsClient) async throws(AgentError) -> ActionResult
    ) async {
        guard !agentBusyKeys.contains(key) else { return }
        agentBusyKeys.insert(key)
        do {
            agentBanner = Copy.agentReviewOutcome(try await run(client).code)
        } catch {
            agentBanner = MenuModel.message(for: error)
        }
        agentBusyKeys.remove(key)
        await refresh()
    }

    public func refresh() async {
        latestRefresh += 1
        let mine = latestRefresh
        loadingList = true
        defer { if mine == latestRefresh { loadingList = false } }
        do {
            let fresh = try await client.reviews()
            guard mine == latestRefresh else { return }
            list = fresh
            errorText = nil
            let keys = Set(fresh.mergeRequests.map(\.key))
            details = details.filter { keys.contains($0.key) }
            if let selected = selectedKey, !keys.contains(selected) { selectedKey = nil }
            // The first row on screen, so it is one that waits for the Owner when there is one.
            if selectedKey == nil { selectedKey = fresh.sections.first?.items.first?.key }
        } catch {
            guard mine == latestRefresh else { return }
            errorText = MenuModel.message(for: error)
        }
        if let key = selectedKey, details[key] == nil { await loadDetail(key) }
    }

    public func select(_ key: String?) async {
        selectedKey = key
        guard let key, details[key] == nil, !loadingKeys.contains(key) else { return }
        await loadDetail(key)
    }

    /// Fetches the MR again even when it is cached; the latest load per MR is the one stored.
    public func loadDetail(_ key: String) async {
        // A reload of your own drops the last approval's outcome; the one after approving keeps it.
        if !approvingKeys.contains(key) { approvalNotices[key] = nil }
        let mine = (latestDetail[key] ?? 0) + 1
        latestDetail[key] = mine
        loadingKeys.insert(key)
        defer { if latestDetail[key] == mine { loadingKeys.remove(key) } }
        do {
            let fresh = try await client.mergeRequest(key: key)
            guard latestDetail[key] == mine else { return }
            details[key] = fresh
            detailErrors[key] = nil
        } catch {
            guard latestDetail[key] == mine else { return }
            detailErrors[key] = MenuModel.message(for: error)
        }
    }
}
