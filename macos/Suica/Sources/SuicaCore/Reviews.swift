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
        id: Int, status: String, cli: String? = nil, model: String? = nil, startedAt: Int? = nil,
        headSha: String? = nil, previousSha: String? = nil, body: String? = nil, detail: String = "",
        activity: [ReviewActivityLine]? = nil, createdAt: Int = 0, updatedAt: Int = 0
    ) {
        self.id = id
        self.status = status
        self.cli = cli
        self.model = model
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
        readyToApprove: Bool = false, rereviewWaiting: RereviewWaiting? = nil
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
        self.readyToApprove = readyToApprove
        self.rereviewWaiting = rereviewWaiting
    }

    private enum CodingKeys: String, CodingKey {
        case key, title, url, draft, createdAt, author, reviewers, agentReview, changedSinceReview, readyToApprove,
            rereviewWaiting
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

/// A tab of the review requests page: your own MRs, or one group of the MRs you review.
public enum ReviewTab: Hashable, Sendable {
    case yours
    case group(ReviewGroup)
}

extension ReviewListDocument {
    /// The page's tabs in order. Without `me` the MRs you review cannot be told apart, so they share one.
    public var tabs: [ReviewTab] {
        me == nil ? [.yours, .group(.all)] : [.yours, .group(.waiting), .group(.reviewed), .group(.drafts)]
    }

    /// The keys shown in `tab`, in the order of its rows, narrowed by the search text when there is one.
    public func keys(in tab: ReviewTab, matching query: String = "") -> [String] {
        switch tab {
        case .yours:
            yourMergeRequests(matching: query).map(\.key)
        case .group(let group):
            sections(matching: query).first { $0.group == group }?.items.map(\.key) ?? []
        }
    }

    /// The tab that holds the MR, whatever is searched.
    public func tab(containing key: String) -> ReviewTab? {
        tabs.first { keys(in: $0).contains(key) }
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
    /// Stops a queued or running review: cancelled or nothing.
    func cancelAgentReview(id: Int) async throws(AgentError) -> ActionResult
    /// Approves the MR as you at `sha`: approved, head-changed, bad-request or failed.
    func approve(key: String, sha: String) async throws(AgentError) -> ActionResult
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
    /// The outcome of the last Agent Review action.
    public private(set) var agentBanner: String?
    /// MRs with an approval in flight.
    public private(set) var approvingKeys: Set<String> = []
    /// The outcome of the last approval, per MR.
    public private(set) var approvalNotices: [String: String] = [:]
    /// MRs you approved from the app since it started; the views celebrate each one.
    public private(set) var approvedCount = 0

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
    /// runs, so its activity reads live, every 15 while one is queued or posting, else every 30.
    public var refreshSeconds: Int {
        if list?.mergeRequests.contains(where: { $0.agentReview?.status == "running" }) == true { return 3 }
        return hasActiveAgentReview ? 15 : 30
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
            // The first row on screen, so it is one that waits for the Owner when there is one.
            if selectedKey == nil { selectedKey = fresh.sections.first?.items.first?.key }
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
