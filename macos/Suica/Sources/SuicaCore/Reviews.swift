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
    /// queued, running, ready, posting, posted, discarded, failed, skipped or cancelled; kept as sent.
    public let status: String
    public let cli: String?
    /// As the CLI reported it, else `review.model`; nil until known or for the CLI's default.
    public let model: String?
    /// The skill it follows; nil for the default while queued, and from an older CLI.
    public let skill: String?
    /// Epoch milliseconds; nil while queued.
    public let startedAt: Int?
    public let headSha: String?
    /// The commit the previous Agent Review covered; set only for a re-review, absent from an older CLI.
    public let previousSha: String?
    /// Markdown as the model wrote it.
    public let body: String?
    public let detail: String
    /// What the run did, oldest first (at most the last 50 steps); absent from an older CLI.
    public let activity: [ReviewActivityLine]?
    public let createdAt: Int
    public let updatedAt: Int

    public init(
        id: Int, status: String, cli: String? = nil, model: String? = nil, skill: String? = nil, startedAt: Int? = nil,
        headSha: String? = nil, previousSha: String? = nil, body: String? = nil, detail: String = "",
        activity: [ReviewActivityLine]? = nil, createdAt: Int = 0, updatedAt: Int = 0
    ) {
        self.id = id
        self.status = status
        self.cli = cli
        self.model = model
        self.skill = skill
        self.startedAt = startedAt
        self.headSha = headSha
        self.previousSha = previousSha
        self.body = body
        self.detail = detail
        self.activity = activity
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The agent is still on it: the page refreshes until it is done.
    public var isActive: Bool { status == "queued" || status == "running" || status == "posting" }
    /// Queued or running: the Owner can still cancel it. A post in flight cannot be.
    public var isCancellable: Bool { status == "queued" || status == "running" }
    /// Written and waiting for the Owner to post or discard it.
    public var isReady: Bool { status == "ready" }
    /// Another review can be started.
    public var canRequeue: Bool { !isActive && !isReady }
}

/// One step of a running Agent Review, as the agent recorded it.
public struct ReviewActivityLine: Codable, Equatable, Sendable {
    /// Epoch milliseconds.
    public let at: Int
    public let text: String

    public init(at: Int, text: String) {
        self.at = at
        self.text = text
    }

    public var date: Date { Date(timeIntervalSince1970: Double(at) / 1000) }
}

/// How an MR changed since the agent's posted review; the list marks it and offers a re-review.
public struct ChangedSinceReview: Codable, Equatable, Sendable {
    public let code: Bool
    public let description: Bool

    public init(code: Bool, description: Bool) {
        self.code = code
        self.description = description
    }
}

/// Why no automatic Agent Re-review ran yet although the head moved past the last posted review.
public struct RereviewWaiting: Codable, Equatable, Sendable {
    /// `waiting`, `daily-cap`, `approved` or `draft`; a newer CLI may send others.
    public let reason: String
    /// Epoch milliseconds when the wait after the last push ends; set for `waiting` only.
    public let dueAt: Int?

    public init(reason: String, dueAt: Int? = nil) {
        self.reason = reason
        self.dueAt = dueAt
    }

    public var dueDate: Date? { dueAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
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
    /// Set when the MR changed since the agent's posted review, no newer review is open and you have not approved it; absent from an older CLI.
    public let changedSinceReview: ChangedSinceReview?
    /// The newest posted-or-discarded Agent Review was posted, even when a later run failed or was
    /// skipped (`agentReview` is only the newest run); false from an older CLI.
    public let agentReviewPosted: Bool
    /// Only minor findings are left on an unchanged MR nobody approved yet; false from an older CLI.
    public let readyToApprove: Bool
    /// Why an automatic re-review has not run yet; nil when none waits, and from an older CLI.
    public let rereviewWaiting: RereviewWaiting?

    public var id: String { key }

    /// Another review can find something new: none yet, the last one did not finish (failed,
    /// skipped or discarded), or the MR changed since the posted one. Never while one is open.
    public var offersReview: Bool {
        guard let review = agentReview else { return true }
        if review.isActive || review.isReady { return false }
        return review.status != "posted" || changedSinceReview != nil
    }

    /// The row offers Re-review: the MR changed since the posted review and another review can start.
    public var offersRereview: Bool { changedSinceReview != nil && (agentReview?.canRequeue ?? true) }

    public var createdDate: Date? { createdAt.flatMap(MRNote.parse) }

    public init(
        key: String, title: String, url: String, draft: Bool, createdAt: String? = nil, author: Person,
        reviewers: [ReviewerInfo], agentReview: AgentReviewInfo? = nil, changedSinceReview: ChangedSinceReview? = nil,
        agentReviewPosted: Bool = false, readyToApprove: Bool = false, rereviewWaiting: RereviewWaiting? = nil
    ) {
        self.key = key
        self.title = title
        self.url = url
        self.draft = draft
        self.createdAt = createdAt
        self.author = author
        self.reviewers = reviewers
        self.agentReview = agentReview
        self.changedSinceReview = changedSinceReview
        self.agentReviewPosted = agentReviewPosted
        self.readyToApprove = readyToApprove
        self.rereviewWaiting = rereviewWaiting
    }

    private enum CodingKeys: String, CodingKey {
        case key, title, url, draft, createdAt, author, reviewers, agentReview, changedSinceReview, agentReviewPosted,
            readyToApprove, rereviewWaiting
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        draft = try container.decode(Bool.self, forKey: .draft)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        author = try container.decode(Person.self, forKey: .author)
        reviewers = try container.decode([ReviewerInfo].self, forKey: .reviewers)
        agentReview = try container.decodeIfPresent(AgentReviewInfo.self, forKey: .agentReview)
        changedSinceReview = try container.decodeIfPresent(ChangedSinceReview.self, forKey: .changedSinceReview)
        agentReviewPosted = try container.decodeIfPresent(Bool.self, forKey: .agentReviewPosted) ?? false
        readyToApprove = try container.decodeIfPresent(Bool.self, forKey: .readyToApprove) ?? false
        rereviewWaiting = try container.decodeIfPresent(RereviewWaiting.self, forKey: .rereviewWaiting)
    }
}

/// `suica reviews --json`: open MRs where the Owner is a Reviewer.
public struct ReviewListDocument: Codable, Equatable, Sendable {
    public let version: Int
    /// The Owner; nil from an agent older than the grouped list.
    public let me: Person?
    public let mergeRequests: [ReviewSummary]
    /// Your own open MRs; empty from an agent older than Agent Fix.
    public let yourMergeRequests: [YourMergeRequest]

    public init(
        version: Int, me: Person? = nil, mergeRequests: [ReviewSummary], yourMergeRequests: [YourMergeRequest] = []
    ) {
        self.version = version
        self.me = me
        self.mergeRequests = mergeRequests
        self.yourMergeRequests = yourMergeRequests
    }

    private enum CodingKeys: String, CodingKey { case version, me, mergeRequests, yourMergeRequests }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        me = try container.decodeIfPresent(Person.self, forKey: .me)
        mergeRequests = try container.decode([ReviewSummary].self, forKey: .mergeRequests)
        yourMergeRequests = try container.decodeIfPresent([YourMergeRequest].self, forKey: .yourMergeRequests) ?? []
    }

    /// The Owner's review state on this MR, as GitLab lists it; nil when unknown.
    public func myState(_ mr: ReviewSummary) -> String? {
        guard let me else { return nil }
        return mr.reviewers.first { $0.username == me.username }?.state
    }

    /// The MR still needs the Owner, drafts aside: it changed since the agent's posted review, or
    /// neither the Owner nor a posted Agent Review covered it yet (a later failed or skipped run does
    /// not undo a posted one). Never once the Owner approved it, and always without `me`.
    public func isWaiting(_ mr: ReviewSummary) -> Bool {
        guard me != nil else { return true }
        let state = myState(mr) ?? "UNREVIEWED"
        if state == "APPROVED" { return false }
        if mr.changedSinceReview != nil { return true }
        return state == "UNREVIEWED" && mr.agentReview?.status != "posted" && !mr.agentReviewPosted
    }

    /// The list as the page shows it: non-empty groups in `ReviewGroup` order, each in GitLab's
    /// order. A non-draft MR is in `waiting` while `isWaiting`; once the Owner approved it, it is
    /// approved, else reviewed. Without `me` nothing can be told apart, so every MR is in `all`.
    public var sections: [ReviewSection] {
        guard me != nil else { return mergeRequests.isEmpty ? [] : [ReviewSection(group: .all, items: mergeRequests)] }
        let grouped = Dictionary(grouping: mergeRequests) { mr -> ReviewGroup in
            if mr.draft { return .drafts }
            if isWaiting(mr) { return .waiting }
            return myState(mr) == "APPROVED" ? .approved : .reviewed
        }
        return ReviewGroup.allCases.compactMap { group in
            grouped[group].map { ReviewSection(group: group, items: $0) }
        }
    }
}

public enum ReviewGroup: CaseIterable, Sendable {
    case waiting, reviewed, approved, drafts, all
}

public struct ReviewSection: Equatable, Sendable {
    public let group: ReviewGroup
    public let items: [ReviewSummary]
}

/// Which page shows the list: the MRs you review (Merge requests) or your own (My MRs).
public enum ReviewScope: Hashable, Sendable {
    case reviewing, mine
}

extension ReviewListDocument {
    /// The Merge requests page's tabs in order. Without `me` the MRs you review cannot be told
    /// apart, so they share one.
    public var tabs: [ReviewGroup] {
        me == nil ? [.all] : [.waiting, .reviewed, .approved, .drafts]
    }

    /// The keys shown in the `group` tab, in the order of its rows, narrowed by the search text when there is one.
    public func keys(in group: ReviewGroup, matching query: String = "") -> [String] {
        sections(matching: query).first { $0.group == group }?.items.map(\.key) ?? []
    }

    /// The tab that holds the MR, whatever is searched; nil for one of yours.
    public func group(containing key: String) -> ReviewGroup? {
        tabs.first { keys(in: $0).contains(key) }
    }

    /// The keys a page lists, in the order of its rows: your own MRs, or every tab of the others.
    public func keys(in scope: ReviewScope, matching query: String = "") -> [String] {
        switch scope {
        case .mine: yourMergeRequests(matching: query).map(\.key)
        case .reviewing: tabs.flatMap { keys(in: $0, matching: query) }
        }
    }
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
    /// The head pipeline stage by stage; nil without a pipeline, or from an older agent.
    public let pipeline: PipelineDetail?
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
    /// True when the project decides squashing, so you cannot choose; nil from an older agent.
    public let squashReadOnly: Bool?
    /// True when merging deletes the source branch, as the MR is set now; nil from an older agent.
    public let removeSourceBranch: Bool?
    /// GitLab's merge readiness (MERGEABLE, NOT_APPROVED, CI_STILL_RUNNING, …); nil when unknown.
    public let detailedMergeStatus: String?
    public let defaultMergeCommitMessage: String?
    public let defaultSquashCommitMessage: String?
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

// MARK: - Pipeline

/// One job of the head pipeline, as GitLab reports it.
public struct PipelineJob: Codable, Equatable, Sendable {
    public let name: String
    /// SUCCESS, FAILED, RUNNING, PENDING, CREATED, MANUAL, SKIPPED, CANCELED, …; kept as sent.
    public let status: String
    public let allowFailure: Bool
    public let url: String?
    public let startedAt: String?
    public let finishedAt: String?

    public var isActive: Bool { PipelineDetail.activeStatuses.contains(status) }
    /// Ran to an end: passed, failed or was cancelled. A skipped or manual job never ran.
    public var isDone: Bool { ["SUCCESS", "FAILED", "CANCELED"].contains(status) }
    public var startedDate: Date? { startedAt.flatMap(MRNote.parse) }
    public var finishedDate: Date? { finishedAt.flatMap(MRNote.parse) }
}

public struct PipelineStage: Codable, Equatable, Sendable {
    public let name: String
    public let status: String
    public let jobs: [PipelineJob]
}

/// `pipeline` in `suica mr <key> --json`: the head pipeline with its stages in order.
public struct PipelineDetail: Codable, Equatable, Sendable {
    public let iid: String
    public let status: String
    public let url: String
    public let startedAt: String?
    public let finishedAt: String?
    public let stages: [PipelineStage]

    static let activeStatuses: Set<String> = [
        "RUNNING", "PENDING", "CREATED", "PREPARING", "WAITING_FOR_RESOURCE", "WAITING_FOR_CALLBACK", "SCHEDULED",
    ]

    /// Still going: the MR page reads it again sooner while it is.
    public var isActive: Bool { Self.activeStatuses.contains(status) }
    public var startedDate: Date? { startedAt.flatMap(MRNote.parse) }
    public var finishedDate: Date? { finishedAt.flatMap(MRNote.parse) }

    /// Jobs that ran to an end, out of those that run on their own: a manual or skipped job is
    /// left out unless it ran, so a pipeline that passed reads as complete.
    public var progress: (done: Int, total: Int) {
        let jobs = stages.flatMap(\.jobs).filter { $0.isDone || $0.isActive }
        return (jobs.filter(\.isDone).count, jobs.count)
    }

    /// The first stage that is still going; nil once none is.
    public var currentStage: PipelineStage? {
        stages.first { stage in stage.jobs.contains(where: \.isActive) }
    }
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
    /// queued, already-queued, bad-key, bad-skill, bad-model, covered or daily-cap. An empty choice uses the config's.
    func queueAgentReview(key: String, choice: ReviewChoice) async throws(AgentError) -> ActionResult
    /// The skills and models a review can use; `cli` names another Model CLI than the saved one.
    func reviewOptions(cli: String?) async throws(AgentError) -> ReviewOptions
    /// posted, nothing or failed. `inline` puts findings on their diff lines as threads.
    func postAgentReview(id: Int, inline: Bool) async throws(AgentError) -> ActionResult
    /// discarded or nothing.
    func discardAgentReview(id: Int) async throws(AgentError) -> ActionResult
    /// Stops a queued or running review: cancelled or nothing.
    func cancelAgentReview(id: Int) async throws(AgentError) -> ActionResult
    /// Approves the MR as you at `sha`: approved, head-changed, bad-request or failed.
    func approve(key: String, sha: String) async throws(AgentError) -> ActionResult
    /// Drafts or sends a Teams message to the MR's Author or a Reviewer (`suica message <key> --json`).
    func teamsMessage(key: String, request: TeamsMessageRequest) async throws(AgentError) -> TeamsMessageReply
}

// MARK: - Model

/// The Review requests page: the list, the selected MR and its details. Each refresh reads the
/// selected MR again, so new comments and pushes show up, and forgets the other MRs' details.
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
    private var runningWaitingRereviews = false
    /// The outcome of the last Agent Review action.
    public private(set) var agentBanner: String?
    /// MRs with an approval in flight.
    public private(set) var approvingKeys: Set<String> = []
    /// The outcome of the last approval, per MR.
    public private(set) var approvalNotices: [String: String] = [:]
    /// MRs you approved from the app since it started; the views celebrate each one.
    public private(set) var approvedCount = 0
    /// The page on screen; a refresh with nothing selected selects that page's first MR.
    public private(set) var scope: ReviewScope = .reviewing

    @ObservationIgnored private let client: any ReviewsClient
    @ObservationIgnored private var latestRefresh = 0
    @ObservationIgnored private var latestDetail: [String: Int] = [:]

    public init(client: any ReviewsClient) {
        self.client = client
    }

    /// The Owner closed the outcome of the last Agent Review action.
    public func dismissAgentBanner() { agentBanner = nil }

    /// The Owner closed the error; the next refresh shows it again if it still fails.
    public func dismissError() { errorText = nil }

    /// The Owner closed the outcome of the last approval of `key`.
    public func dismissApprovalNotice(_ key: String) { approvalNotices[key] = nil }

    public var selectedDetail: MergeRequestDetail? { selectedKey.flatMap { details[$0] } }

    /// True for one of your own MRs: its page offers Agent Fix, a comment and Merge.
    public func isYours(_ key: String) -> Bool {
        list?.yourMergeRequests.contains { $0.key == key } ?? false
    }

    /// Whether automatic fixes reach your MR.
    public func isWatched(_ key: String) -> Bool {
        list?.yourMergeRequests.first { $0.key == key }?.isWatched ?? true
    }

    /// Shows a watch choice the agent took at once; the next refresh reads it back.
    public func showWatched(_ key: String, _ watched: Bool) {
        guard let list else { return }
        self.list = ReviewListDocument(
            version: list.version, me: list.me, mergeRequests: list.mergeRequests,
            yourMergeRequests: list.yourMergeRequests.map { mr in
                var mr = mr
                if mr.key == key { mr.watched = watched }
                return mr
            })
    }

    /// The MR page offers Review with agent or Review again; see `ReviewSummary.offersReview`.
    public func offersReview(for key: String) -> Bool {
        list?.mergeRequests.first { $0.key == key }?.offersReview ?? true
    }

    public func agentReview(for key: String) -> AgentReviewInfo? {
        list?.mergeRequests.first { $0.key == key }?.agentReview
    }

    /// True while a review is queued, running or being posted: the page keeps refreshing.
    public var hasActiveAgentReview: Bool {
        list?.mergeRequests.contains { $0.agentReview?.isActive == true } ?? false
    }

    /// How often the page reads the list and the selected MR again: every 3 seconds while a review
    /// runs, so its activity reads live, every 10 while the selected MR's pipeline runs, every 15
    /// while a review is queued or posting, else every 30.
    public var refreshSeconds: Int {
        if list?.mergeRequests.contains(where: { $0.agentReview?.status == "running" }) == true { return 3 }
        if selectedDetail?.pipeline?.isActive == true { return 10 }
        return hasActiveAgentReview ? 15 : 30
    }

    /// Opens a page: keeps the selection when the page lists it, else selects the page's first MR.
    public func show(_ scope: ReviewScope) async {
        self.scope = scope
        guard let list else { return }
        let keys = list.keys(in: scope)
        guard selectedKey.map(keys.contains) != true else { return }
        await select(keys.first)
    }

    /// The template's text for a Teams message to `to`, or why there is none.
    public func draftMessage(_ key: String, to: String, template: String) async -> TeamsMessageReply {
        await teamsMessage(key, TeamsMessageRequest(to: to, template: template, text: nil, send: false))
    }

    /// Sends `text` to `to` on Teams now.
    public func sendMessage(_ key: String, to: String, template: String, text: String) async -> TeamsMessageReply {
        await teamsMessage(key, TeamsMessageRequest(to: to, template: template, text: text, send: true))
    }

    private func teamsMessage(_ key: String, _ request: TeamsMessageRequest) async -> TeamsMessageReply {
        do {
            return try await client.teamsMessage(key: key, request: request)
        } catch {
            return TeamsMessageReply(status: "failed", message: MenuModel.message(for: error))
        }
    }

    public func queueAgentReview(_ key: String, choice: ReviewChoice = ReviewChoice()) async {
        await agentAction(key) { (client: any ReviewsClient) async throws(AgentError) -> ActionResult in
            try await client.queueAgentReview(key: key, choice: choice)
        }
    }

    /// Queues now, as automatic reviews within the daily cap, the re-reviews that only wait for the
    /// push to settle (`waiting`), so opening the app does not leave them to the wait. Held ones
    /// (daily cap, approved, draft) stay as they are. A call while one runs does nothing: the window
    /// and the menu can open together.
    public func runWaitingRereviews() async {
        guard !runningWaitingRereviews else { return }
        runningWaitingRereviews = true
        defer { runningWaitingRereviews = false }
        await refresh()
        let due = list?.mergeRequests.filter { $0.rereviewWaiting?.reason == "waiting" }.map(\.key) ?? []
        for key in due { await queueAgentReview(key, choice: ReviewChoice(automatic: true)) }
    }

    /// A loader for a skill and model picker, on this page's client.
    public func optionsLoader() -> ReviewOptionsLoader { ReviewOptionsLoader(client: client) }

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

    /// Stops a queued or running review; the background agent stops a running one within seconds.
    public func cancelAgentReview(_ key: String) async {
        guard let review = agentReview(for: key), review.isCancellable else { return }
        await cancelAgentReview(id: review.id, key: key)
    }

    /// Cancels the review the Overview or the menu bar shows, which may not be in the list read yet.
    public func cancelAgentReview(id: Int, key: String) async {
        await agentAction(key) { (client: any ReviewsClient) async throws(AgentError) -> ActionResult in try await client.cancelAgentReview(id: id) }
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
            let code = try await client.approve(key: key, sha: sha).code
            approvalNotices[key] = Copy.approveOutcome(code)
            if code == "approved" { approvedCount += 1 }
        } catch {
            approvalNotices[key] = MenuModel.message(for: error)
        }
        approvingKeys.remove(key)
        // The approved MR is the selected one, so the refresh reads it again too.
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
        // The selected MR is read while the list loads, not after it: each is its own GitLab round trip.
        let early = selectedKey
        let earlyLoad = early.map { key in Task { await loadDetail(key, keepingNotice: true) } }
        do {
            let fresh = try await client.reviews()
            guard mine == latestRefresh else { return }
            // A refresh usually brings nothing new: storing the same value would still redraw the page.
            if list != fresh { list = fresh }
            if errorText != nil { errorText = nil }
            let keys = Set(fresh.mergeRequests.map(\.key) + fresh.yourMergeRequests.map(\.key))
            if let selected = selectedKey, !keys.contains(selected) { selectedKey = nil }
            // The page's first row, so on Merge requests one that waits for the Owner when there is one.
            if selectedKey == nil { selectedKey = fresh.keys(in: scope).first }
        } catch {
            guard mine == latestRefresh else { return }
            let message = MenuModel.message(for: error)
            if errorText != message { errorText = message }
        }
        if let key = selectedKey, key != early { await loadDetail(key, keepingNotice: true) }
        await earlyLoad?.value
        // After the early load, so the detail of an MR that left the list is not stored again.
        if details.keys.contains(where: { $0 != selectedKey }) { details = details.filter { $0.key == selectedKey } }
    }

    public func select(_ key: String?) async {
        selectedKey = key
        guard let key, details[key] == nil, !loadingKeys.contains(key) else { return }
        await loadDetail(key)
    }

    /// Fetches the MR again even when it is cached; the latest load per MR is the one stored.
    /// A reload of your own drops the last approval's outcome; a refresh keeps it.
    public func loadDetail(_ key: String, keepingNotice: Bool = false) async {
        if !keepingNotice && !approvingKeys.contains(key) { approvalNotices[key] = nil }
        let mine = (latestDetail[key] ?? 0) + 1
        latestDetail[key] = mine
        loadingKeys.insert(key)
        defer { if latestDetail[key] == mine { loadingKeys.remove(key) } }
        do {
            let fresh = try await client.mergeRequest(key: key)
            guard latestDetail[key] == mine else { return }
            if details[key] != fresh { details[key] = fresh }
            if detailErrors[key] != nil { detailErrors[key] = nil }
        } catch {
            guard latestDetail[key] == mine else { return }
            let message = MenuModel.message(for: error)
            if detailErrors[key] != message { detailErrors[key] = message }
        }
    }
}
