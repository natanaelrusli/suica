import Foundation
import Observation

// MARK: - Documents

/// The newest Agent Fix of one of your MRs, in short, as the review list carries it.
public struct FixSummary: Codable, Equatable, Sendable {
    public let id: Int
    public let status: String
    public let threads: Int
    /// Threads the fix changed code for.
    public let changed: Int
    public let detail: String
}

/// One of your own open MRs in `suica reviews --json`.
public struct YourMergeRequest: Codable, Equatable, Identifiable, Sendable {
    public let key: String
    public let title: String
    public let url: String
    public let draft: Bool
    public let createdAt: String?
    public let reviewers: [ReviewerInfo]
    /// Every Reviewer approved: Suica no longer fixes threads on it by itself.
    public let approvedByAll: Bool
    /// Nil when Suica never fixed anything on it.
    public let fix: FixSummary?

    public var id: String { key }

    /// Reviewers who approved, out of all reviewers.
    public var approvals: (approved: Int, total: Int) {
        (reviewers.filter { $0.state == "APPROVED" }.count, reviewers.count)
    }
}

/// One Reviewer thread an Agent Fix answers.
public struct FixThreadInfo: Codable, Equatable, Identifiable, Sendable {
    public struct Note: Codable, Equatable, Sendable {
        public let author: Person
        public let body: String
        public let createdAt: String
    }

    public let id: String
    public let author: Person
    public let filePath: String?
    public let line: Int?
    public let notes: [Note]
    /// changed: the code changed for it; reply: only a reply; nil before the model answered.
    public let action: String?
    public let reply: String
    public let post: Bool
    public let posted: Bool
}

/// One Agent Fix in `suica fix list --json`.
public struct FixInfo: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let mrKey: String
    public let mrTitle: String?
    public let status: String
    public let threads: [FixThreadInfo]
    public let note: String
    public let baseSha: String?
    public let commitMessage: String
    /// Only while the fix waits for you.
    public let diff: String?
    public let pushedSha: String?
    public let cli: String?
    public let model: String?
    public let detail: String
    public let activity: [ReviewActivityLine]
    public let createdAt: Int
    public let updatedAt: Int
    public let startedAt: Int?

    public var isActive: Bool { status == "queued" || status == "running" || status == "confirming" }
    public var isCancellable: Bool { status == "queued" || status == "running" }
    public var isReady: Bool { status == "ready" }
    public var canRetry: Bool { status == "ready" || status == "failed" || status == "push-failed" }
    public var canDiscard: Bool { status == "ready" || status == "push-failed" }
    public var hasMissingReplies: Bool { status == "pushed" && threads.contains { $0.post && !$0.posted } }
    public var changedCount: Int { threads.filter { $0.action == "changed" }.count }
}

public struct FixListDocument: Codable, Equatable, Sendable {
    public let version: Int
    public let fixes: [FixInfo]

    public init(version: Int, fixes: [FixInfo]) {
        self.version = version
        self.fixes = fixes
    }
}

/// What you changed before confirming a fix, as `suica fix confirm` reads it on stdin.
public struct ConfirmEdits: Codable, Equatable, Sendable {
    public struct Thread: Codable, Equatable, Sendable {
        public let id: String
        public let reply: String
        public let post: Bool

        public init(id: String, reply: String, post: Bool) {
            self.id = id
            self.reply = reply
            self.post = post
        }
    }

    public let commitMessage: String
    public let threads: [Thread]

    public init(commitMessage: String, threads: [Thread]) {
        self.commitMessage = commitMessage
        self.threads = threads
    }
}

/// How you merge, chosen on the Merge sheet each time.
public struct MergeChoice: Equatable, Sendable {
    public var squash: Bool
    public var removeSourceBranch: Bool
    public var message: String
    public var whenPipelineSucceeds: Bool

    public init(squash: Bool, removeSourceBranch: Bool, message: String, whenPipelineSucceeds: Bool) {
        self.squash = squash
        self.removeSourceBranch = removeSourceBranch
        self.message = message
        self.whenPipelineSucceeds = whenPipelineSucceeds
    }

    /// GitLab's settings for the MR, with its default message for the squash setting.
    public init(for detail: MergeRequestDetail, availability: MergeAvailability) {
        let squash = detail.squashOnMerge ?? false
        self.init(
            squash: squash, removeSourceBranch: detail.removeSourceBranch ?? false,
            message: MergeChoice.defaultMessage(detail, squash: squash),
            whenPipelineSucceeds: availability == .whenPipelineSucceeds)
    }

    public static func defaultMessage(_ detail: MergeRequestDetail, squash: Bool) -> String {
        (squash ? detail.defaultSquashCommitMessage : detail.defaultMergeCommitMessage) ?? detail.title
    }
}

public enum MergeAvailability: Equatable, Sendable {
    case merge
    case whenPipelineSucceeds
    /// Why GitLab will not merge it now, in words.
    case blocked(String)
}

private let runningPipelines: Set<String> = ["RUNNING", "PENDING", "CREATED", "WAITING_FOR_RESOURCE", "PREPARING"]

/// Whether the Merge button merges now, merges once the pipeline passes, or says why not.
public func mergeAvailability(_ detail: MergeRequestDetail) -> MergeAvailability {
    guard detail.headSha != nil else { return .blocked(Copy.mergeBlockedOther) }
    switch detail.detailedMergeStatus {
    case "MERGEABLE": return .merge
    case "CI_STILL_RUNNING": return .whenPipelineSucceeds
    case "CI_MUST_PASS":
        return runningPipelines.contains(detail.pipelineStatus ?? "")
            ? .whenPipelineSucceeds : .blocked(Copy.mergeBlockedPipeline)
    case "NOT_APPROVED": return .blocked(Copy.mergeBlockedApproval)
    case "CONFLICT": return .blocked(Copy.mergeBlockedConflict)
    case "DRAFT_STATUS": return .blocked(Copy.mergeBlockedDraft)
    case "DISCUSSIONS_NOT_RESOLVED": return .blocked(Copy.mergeBlockedThreads)
    case "NEED_REBASE": return .blocked(Copy.mergeBlockedRebase)
    case "BLOCKED_STATUS": return .blocked(Copy.mergeBlockedDependency)
    default: return .blocked(Copy.mergeBlockedOther)
    }
}

// MARK: - Client

public protocol FixesClient: Sendable {
    func fixes() async throws(AgentError) -> FixListDocument
    /// queued, added, busy, nothing-to-fix or bad-key.
    func queueFix(key: String) async throws(AgentError) -> ActionResult
    /// pushed, partial, branch-moved, push-failed, bad-request or nothing.
    func confirmFix(id: Int, edits: ConfirmEdits) async throws(AgentError) -> ActionResult
    /// queued or nothing.
    func retryFix(id: Int, note: String) async throws(AgentError) -> ActionResult
    /// discarded or nothing.
    func discardFix(id: Int) async throws(AgentError) -> ActionResult
    /// cancelled or nothing.
    func cancelFix(id: Int) async throws(AgentError) -> ActionResult
    /// pushed, partial or nothing.
    func postMissingReplies(id: Int) async throws(AgentError) -> ActionResult
    /// posted, empty, bad-key or failed.
    func comment(key: String, body: String) async throws(AgentError) -> ActionResult
    /// merged, scheduled, not-mergeable, sha-mismatch, bad-key or failed.
    func merge(key: String, sha: String, choice: MergeChoice) async throws(AgentError) -> ActionResult
    /// closed, not-yours, bad-key or failed.
    func close(key: String) async throws(AgentError) -> ActionResult
}

// MARK: - Model

/// Agent Fixes, comments and merging for your own MRs on the Reviews page.
@MainActor @Observable
public final class FixesModel {
    /// The last good list: a failed refresh does not clear it.
    public private(set) var list: FixListDocument?
    /// The outcome of the last action.
    public private(set) var banner: String?
    /// MRs with an action in flight.
    public private(set) var busyKeys: Set<String> = []

    @ObservationIgnored private let client: any FixesClient

    public init(client: any FixesClient) {
        self.client = client
    }

    public func dismissBanner() { banner = nil }

    /// The MR's open fix, else its newest one.
    public func fix(for key: String) -> FixInfo? {
        let mine = list?.fixes.filter { $0.mrKey == key } ?? []
        return mine.first { $0.isActive || $0.isReady } ?? mine.max { $0.id < $1.id }
    }

    /// True while a fix runs or is being pushed: the page reads it again sooner.
    public var hasActiveFix: Bool { list?.fixes.contains { $0.isActive } ?? false }

    public func refresh() async {
        // A failed read keeps the last list; the next refresh tries again.
        if let fresh = try? await client.fixes() { list = fresh }
    }

    public func queueFix(_ key: String) async {
        await act(key, Copy.fixOutcome) { (client: any FixesClient) async throws(AgentError) -> ActionResult in
            try await client.queueFix(key: key)
        }
    }

    public func confirm(_ fix: FixInfo, edits: ConfirmEdits) async {
        await act(fix.mrKey, Copy.fixOutcome) { (client: any FixesClient) async throws(AgentError) -> ActionResult in
            try await client.confirmFix(id: fix.id, edits: edits)
        }
    }

    public func retry(_ fix: FixInfo, note: String) async {
        await act(fix.mrKey, Copy.fixOutcome) { (client: any FixesClient) async throws(AgentError) -> ActionResult in
            try await client.retryFix(id: fix.id, note: note)
        }
    }

    public func discard(_ fix: FixInfo) async {
        await act(fix.mrKey, Copy.fixOutcome) { (client: any FixesClient) async throws(AgentError) -> ActionResult in
            try await client.discardFix(id: fix.id)
        }
    }

    public func cancel(_ fix: FixInfo) async {
        await act(fix.mrKey, Copy.fixOutcome) { (client: any FixesClient) async throws(AgentError) -> ActionResult in
            try await client.cancelFix(id: fix.id)
        }
    }

    public func postMissingReplies(_ fix: FixInfo) async {
        await act(fix.mrKey, Copy.fixOutcome) { (client: any FixesClient) async throws(AgentError) -> ActionResult in
            try await client.postMissingReplies(id: fix.id)
        }
    }

    /// Posts a comment as you; false when it was blank or GitLab did not take it.
    public func comment(key: String, body: String) async -> Bool {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let code = await act(key, Copy.commentOutcome, refreshing: false) { (client: any FixesClient) async throws(AgentError) -> ActionResult in
            try await client.comment(key: key, body: body)
        }
        return code == "posted"
    }

    /// Merges at the commit on screen; returns GitLab's outcome code, nil when the call failed.
    @discardableResult
    public func merge(key: String, sha: String, choice: MergeChoice) async -> String? {
        await act(key, Copy.mergeOutcome, refreshing: false) { (client: any FixesClient) async throws(AgentError) -> ActionResult in
            try await client.merge(key: key, sha: sha, choice: choice)
        }
    }

    /// Closes your MR without merging; returns the outcome code, nil when the call failed.
    @discardableResult
    public func close(key: String) async -> String? {
        await act(key, Copy.closeOutcome, refreshing: false) { (client: any FixesClient) async throws(AgentError) -> ActionResult in
            try await client.close(key: key)
        }
    }

    /// One action per MR at a time; a fix action reads the list again afterwards.
    @discardableResult
    private func act(
        _ key: String, _ words: (String) -> String, refreshing: Bool = true,
        _ run: (any FixesClient) async throws(AgentError) -> ActionResult
    ) async -> String? {
        guard !busyKeys.contains(key) else { return nil }
        busyKeys.insert(key)
        defer { busyKeys.remove(key) }
        var code: String?
        do {
            let result = try await run(client).code
            code = result
            banner = words(result)
        } catch {
            banner = MenuModel.message(for: error)
        }
        if refreshing { await refresh() }
        return code
    }
}

// MARK: - Draft

/**
 * What you are about to confirm: the replies, the threads not to post and the commit message,
 * started from the fix as the agent wrote it. It belongs to one fix in one status: a draft seeded
 * while the fix ran is stale once it is ready, so the tab never confirms a change it did not show.
 */
public struct FixDraft: Equatable, Sendable {
    public let fixId: Int
    public let status: String
    public var replies: [String: String]
    public var skipped: Set<String>
    public var commitMessage: String
    public let files: [GitDiffFile]

    public init(_ fix: FixInfo) {
        fixId = fix.id
        status = fix.status
        replies = Dictionary(uniqueKeysWithValues: fix.threads.map { ($0.id, $0.reply) })
        skipped = Set(fix.threads.filter { !$0.post }.map(\.id))
        commitMessage = fix.commitMessage
        files = fix.diff.map(splitGitDiff) ?? []
    }

    public func isStale(for fix: FixInfo) -> Bool { fix.id != fixId || fix.status != status }

    public func edits(for fix: FixInfo) -> ConfirmEdits {
        ConfirmEdits(
            commitMessage: commitMessage,
            threads: fix.threads.map { thread in
                let reply = replies[thread.id] ?? thread.reply
                let blank = reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return ConfirmEdits.Thread(id: thread.id, reply: reply, post: !skipped.contains(thread.id) && !blank)
            })
    }
}

/// The commit to merge: the one the Merge sheet opened on, only while the MR is still at it.
public func mergeSha(opened: String?, current: String?) -> String? {
    guard let opened, opened == current else { return nil }
    return opened
}

// MARK: - Git diff

/// One file of a `git diff`: its new path and its lines without git's header.
public struct GitDiffFile: Equatable, Sendable {
    public let path: String
    public let lines: [DiffLine]
}

/// Header lines that say something the hunks do not: modes, renames, binary files.
private let keptHeaders = [
    "new file mode ", "deleted file mode ", "old mode ", "new mode ", "rename from ", "rename to ",
    "Binary files ", "GIT binary patch",
]

/// Splits `git diff` output by file. Git's own bookkeeping (`index`, `---`, `+++`, similarity) is
/// left out; mode changes, renames and binary files stay as notes, since they are changes too.
public func splitGitDiff(_ diff: String) -> [GitDiffFile] {
    var files: [GitDiffFile] = []
    var path: String?
    var body: [Substring] = []
    var inHunks = false
    func flush() {
        guard let path else { return }
        files.append(GitDiffFile(path: path, lines: parseDiffLines(body.joined(separator: "\n"))))
    }
    for row in diff.split(separator: "\n", omittingEmptySubsequences: false) {
        if row.hasPrefix("diff --git ") {
            flush()
            // A guess for a path holding " b/"; the +++ or rename line below names it exactly.
            path = row.range(of: " b/", options: .backwards).map { String(row[$0.upperBound...]) } ?? String(row)
            body = []
            inHunks = false
        } else if inHunks || row.hasPrefix("@@") {
            inHunks = true
            body.append(row)
        } else if row.hasPrefix("+++ b/") {
            path = String(row.dropFirst(6))
        } else if row.hasPrefix("rename to ") {
            path = String(row.dropFirst(10))
            body.append(row)
        } else if keptHeaders.contains(where: { row.hasPrefix($0) }) {
            body.append(row)
        }
    }
    flush()
    return files
}
