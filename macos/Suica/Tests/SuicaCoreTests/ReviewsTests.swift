import Foundation
import Testing

@testable import SuicaCore

private func contract(_ name: String) throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return try Data(contentsOf: url.appending(path: "contracts/\(name)"))
}

private func summary(_ key: String) -> ReviewSummary {
    ReviewSummary(
        key: key, title: "T \(key)", url: "https://x/\(key)", draft: false,
        author: Person(username: "a", name: "A"), reviewers: [])
}

private func list(_ keys: String...) -> ReviewListDocument {
    ReviewListDocument(version: 1, mergeRequests: keys.map(summary))
}

private func detail(_ key: String) throws -> MergeRequestDetail {
    let golden = try decodeDocument(MergeRequestDetail.self, from: contract("mr-detail.v1.json"))
    let json = try JSONEncoder().encode(golden)
    var object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    object["key"] = key
    return try decodeDocument(
        MergeRequestDetail.self, from: JSONSerialization.data(withJSONObject: object))
}

actor FakeReviewsClient: ReviewsClient {
    var lists: [Result<ReviewListDocument, AgentError>]
    var detailResults: [String: Result<MergeRequestDetail, AgentError>] = [:]
    var gates: [String: Gate] = [:]
    private(set) var detailCalls: [String] = []

    init(lists: [Result<ReviewListDocument, AgentError>]) { self.lists = lists }

    func setDetail(_ key: String, _ result: Result<MergeRequestDetail, AgentError>, gate: Gate? = nil) {
        detailResults[key] = result
        gates[key] = gate
    }

    func reviews() async throws(AgentError) -> ReviewListDocument {
        let result = lists.count > 1 ? lists.removeFirst() : (lists.first ?? .failure(.launchFailed))
        return try result.get()
    }

    private(set) var actions: [String] = []
    var actionResult: Result<ActionResult, AgentError> = .success(ActionResult(code: "queued"))
    func setLists(_ next: [Result<ReviewListDocument, AgentError>]) { lists = next }
    func setActionResult(_ next: Result<ActionResult, AgentError>) { actionResult = next }

    func queueAgentReview(key: String) async throws(AgentError) -> ActionResult {
        actions.append("queue \(key)")
        return try actionResult.get()
    }

    func postAgentReview(id: Int) async throws(AgentError) -> ActionResult {
        actions.append("post \(id)")
        return try actionResult.get()
    }

    func discardAgentReview(id: Int) async throws(AgentError) -> ActionResult {
        actions.append("discard \(id)")
        return try actionResult.get()
    }

    func mergeRequest(key: String) async throws(AgentError) -> MergeRequestDetail {
        detailCalls.append(key)
        let gate = gates.removeValue(forKey: key)
        let result = detailResults[key] ?? .failure(.launchFailed)
        if let gate { await gate.wait() }
        return try result.get()
    }
}

@Test func reviewContractsDecode() throws {
    let reviews = try decodeDocument(ReviewListDocument.self, from: contract("reviews.v1.json"))
    #expect(reviews.mergeRequests.map(\.key) == ["g/p!7"])
    #expect(reviews.mergeRequests.first?.draft == true)
    #expect(reviews.mergeRequests.first?.reviewers.first?.state == "UNREVIEWED")
    #expect(reviews.me == Person(username: "me", name: "Nata"))
    #expect(reviews.sections.map(\.group) == [.drafts])
    let agent = try #require(reviews.mergeRequests.first?.agentReview)
    #expect(agent.id == 3 && agent.status == "ready" && agent.cli == "claude" && agent.isReady)
    #expect(agent.model == "claude-opus-5-5" && agent.startedAt == 1_792_148_500_000)
    #expect(agent.headSha?.hasPrefix("01234567") == true && agent.body?.hasPrefix("# Code review") == true)
    #expect(!agent.isActive && !agent.canRequeue)

    let mr = try decodeDocument(MergeRequestDetail.self, from: contract("mr-detail.v1.json"))
    #expect(mr.pipelineStatus == "SUCCESS" && mr.additions == 3 && mr.deletions == 1)
    #expect(mr.files.map(\.diff?.isEmpty) == [false, nil])
    #expect(mr.discussions.count == 2)
    #expect(mr.comments.map(\.id) == ["gid://gitlab/Discussion/2"])
    #expect(mr.comments.first?.notes.first?.filePath == "src/a.ts")
    #expect(mr.comments.first?.notes.first?.date != nil)
    #expect(mr.updatedDate != nil)
}

@Test func diffLinesAreNumberedPerSide() {
    let lines = parseDiffLines("@@ -10,3 +20,4 @@ func\n a\n-b\n+c\n+d\n\\ No newline at end of file\n")
    #expect(lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .note])
    #expect(lines.map(\.oldNumber) == [nil, 10, 11, nil, nil, nil])
    #expect(lines.map(\.newNumber) == [nil, 20, nil, 21, 22, nil])
    #expect(lines[2].text == "b")
}

@Test func aMalformedHunkHeaderLeavesLinesUnnumbered() {
    let lines = parseDiffLines("@@ nonsense @@\n x\n+y")
    #expect(lines.map(\.kind) == [.hunk, .context, .added])
    #expect(lines.allSatisfy { $0.oldNumber == nil && $0.newNumber == nil })
}

@Test func messagesAreGroupedByWhoseMRTheyAreAbout() {
    func item(_ kind: String) -> OutboxItem {
        OutboxItem(
            id: 1, kind: kind, status: "sent", detail: "", recipientName: "r", mrKey: "g/p!1",
            mrTitle: "t", mrUrl: "https://x", text: nil, createdAt: 0, updatedAt: 0)
    }
    #expect(item("nudge").isAboutYourMR)
    #expect(item("reminder").isAboutYourMR)
    #expect(!item("notice").isAboutYourMR)
    #expect(!item("something-new").isAboutYourMR)
}

@MainActor @Test func refreshSelectsTheFirstMRAndLoadsIt() async throws {
    let client = FakeReviewsClient(lists: [.success(list("g/p!1", "g/p!2"))])
    await client.setDetail("g/p!1", .success(try detail("g/p!1")))
    let model = ReviewsModel(client: client)
    await model.refresh()
    #expect(model.selectedKey == "g/p!1")
    #expect(model.selectedDetail?.key == "g/p!1")
    #expect(model.loadingList == false && model.loadingKeys.isEmpty)
}

@MainActor @Test func selectingACachedMRDoesNotFetchItAgain() async throws {
    let client = FakeReviewsClient(lists: [.success(list("g/p!1", "g/p!2"))])
    await client.setDetail("g/p!1", .success(try detail("g/p!1")))
    await client.setDetail("g/p!2", .success(try detail("g/p!2")))
    let model = ReviewsModel(client: client)
    await model.refresh()
    await model.select("g/p!2")
    await model.select("g/p!1")
    #expect(await client.detailCalls == ["g/p!1", "g/p!2"])
    #expect(model.selectedDetail?.key == "g/p!1")
}

@MainActor @Test func aFailedRefreshKeepsTheListAndAGoneMRIsDropped() async throws {
    let client = FakeReviewsClient(lists: [
        .success(list("g/p!1", "g/p!2")), .failure(.timedOut), .success(list("g/p!2")),
    ])
    await client.setDetail("g/p!1", .success(try detail("g/p!1")))
    await client.setDetail("g/p!2", .success(try detail("g/p!2")))
    let model = ReviewsModel(client: client)
    await model.refresh()
    await model.refresh()
    #expect(model.list?.mergeRequests.count == 2)
    #expect(model.errorText == Copy.agentTimedOut)
    await model.refresh()
    #expect(model.errorText == nil)
    #expect(model.selectedKey == "g/p!2")
    #expect(model.details["g/p!1"] == nil)
    #expect(model.selectedDetail?.key == "g/p!2")
}

@MainActor @Test func aFailedDetailLoadIsReportedForThatMROnly() async throws {
    let client = FakeReviewsClient(lists: [.success(list("g/p!1"))])
    await client.setDetail("g/p!1", .failure(.failed(exitCode: 1)))
    let model = ReviewsModel(client: client)
    await model.refresh()
    #expect(model.detailErrors["g/p!1"] != nil)
    #expect(model.errorText == nil)
    await client.setDetail("g/p!1", .success(try detail("g/p!1")))
    await model.loadDetail("g/p!1")
    #expect(model.detailErrors["g/p!1"] == nil)
    #expect(model.selectedDetail != nil)
}

@MainActor @Test func anOlderDetailLoadDoesNotOverwriteANewerOne() async throws {
    let client = FakeReviewsClient(lists: [.success(list("g/p!1"))])
    let gate = Gate()
    await client.setDetail("g/p!1", .failure(.timedOut), gate: gate)
    let model = ReviewsModel(client: client)
    let first = Task { await model.loadDetail("g/p!1") }
    while await client.detailCalls.isEmpty { await Task.yield() }
    await client.setDetail("g/p!1", .success(try detail("g/p!1")))
    await model.loadDetail("g/p!1")
    await gate.open()
    await first.value
    #expect(model.details["g/p!1"] != nil)
    #expect(model.detailErrors["g/p!1"] == nil)
    #expect(model.loadingKeys.isEmpty)
}

// MARK: - Grouping

private func review(
    _ key: String, draft: Bool = false, me state: String? = nil, others: [String] = []
) -> ReviewSummary {
    let mine = state.map { [ReviewerInfo(username: "me", name: "Me", state: $0)] } ?? []
    let rest = others.enumerated().map { ReviewerInfo(username: "r\($0.offset)", name: "R", state: $0.element) }
    return ReviewSummary(
        key: key, title: key, url: "https://x/\(key)", draft: draft,
        author: Person(username: "a", name: "A"), reviewers: mine + rest)
}

@Test func theListIsGroupedIntoWaitingReviewedAndDraftsInGitLabOrder() {
    let document = ReviewListDocument(
        version: 1, me: Person(username: "me", name: "Me"),
        mergeRequests: [
            review("g/p!1", me: "APPROVED"),
            review("g/p!2", me: "UNREVIEWED"),
            review("g/p!3", draft: true, me: "UNREVIEWED"),
            review("g/p!4", me: "REQUESTED_CHANGES"),
            review("g/p!5"),
        ])
    #expect(document.sections.map(\.group) == [.waiting, .reviewed, .drafts])
    #expect(document.sections.map { $0.items.map(\.key) } == [["g/p!2", "g/p!5"], ["g/p!1", "g/p!4"], ["g/p!3"]])
    #expect(document.myState(document.mergeRequests[0]) == "APPROVED")
    // Not listed among the reviewers: unknown, and counted as waiting like the badge does.
    #expect(document.myState(document.mergeRequests[4]) == nil)
}

@Test func emptyGroupsAreLeftOutAndAListWithoutMeIsOneUngroupedSection() {
    let me = Person(username: "me", name: "Me")
    let reviewedOnly = ReviewListDocument(version: 1, me: me, mergeRequests: [review("g/p!1", me: "APPROVED")])
    #expect(reviewedOnly.sections.map(\.group) == [.reviewed])
    #expect(ReviewListDocument(version: 1, me: me, mergeRequests: []).sections.isEmpty)
    let older = ReviewListDocument(version: 1, mergeRequests: [review("g/p!1", draft: true), review("g/p!2")])
    #expect(older.sections == [ReviewSection(group: .all, items: older.mergeRequests)])
    #expect(older.myState(older.mergeRequests[1]) == nil)
}

@Test func approvalsCountApprovedReviewersOutOfAll() {
    let mr = review("g/p!1", me: "UNREVIEWED", others: ["APPROVED", "REQUESTED_CHANGES"])
    #expect(mr.approvals == (1, 3))
    #expect(review("g/p!2").approvals == (0, 0))
}

@MainActor @Test func refreshSelectsTheFirstMrThatWaitsForYou() async {
    let document = ReviewListDocument(
        version: 1, me: Person(username: "me", name: "Me"),
        mergeRequests: [review("g/p!1", me: "APPROVED"), review("g/p!2", me: "UNREVIEWED")])
    let model = ReviewsModel(client: FakeReviewsClient(lists: [.success(document)]))
    await model.refresh()
    #expect(model.selectedKey == "g/p!2")
}

// MARK: - Agent Review

private func withAgent(_ status: String?) -> ReviewListDocument {
    ReviewListDocument(
        version: 1, me: Person(username: "me", name: "Me"),
        mergeRequests: [
            ReviewSummary(
                key: "g/p!1", title: "T", url: "https://x/1", draft: false, author: Person(username: "a", name: "A"),
                reviewers: [], agentReview: status.map { AgentReviewInfo(id: 9, status: $0) })
        ])
}

@MainActor @Test func queueingAReviewCallsTheAgentSaysWhatHappenedAndReadsTheListAgain() async {
    let client = FakeReviewsClient(lists: [.success(withAgent(nil)), .success(withAgent("queued"))])
    let model = ReviewsModel(client: client)
    await model.refresh()
    #expect(!model.hasActiveAgentReview)
    await model.queueAgentReview("g/p!1")
    #expect(await client.actions == ["queue g/p!1"])
    #expect(model.agentBanner == Copy.agentReviewOutcome("queued"))
    #expect(model.agentReview(for: "g/p!1")?.status == "queued")
    #expect(model.hasActiveAgentReview)
    #expect(model.agentBusyKeys.isEmpty)
}

@MainActor @Test func postingNeedsAReadyReviewAndDiscardUsesTheReviewId() async {
    let client = FakeReviewsClient(lists: [.success(withAgent("running"))])
    let model = ReviewsModel(client: client)
    await model.refresh()
    await model.postAgentReview("g/p!1")
    #expect(await client.actions.isEmpty)

    await client.setLists([.success(withAgent("ready"))])
    await model.refresh()
    await client.setActionResult(.success(ActionResult(code: "posted")))
    await model.postAgentReview("g/p!1")
    #expect(await client.actions == ["post 9"])
    #expect(model.agentBanner == "Review posted to GitLab.")
    await model.discardAgentReview("g/p!1")
    #expect(await client.actions == ["post 9", "discard 9"])
}

@MainActor @Test func aFailedAgentActionShowsTheError() async {
    let client = FakeReviewsClient(lists: [.success(withAgent("ready"))])
    await client.setActionResult(.failure(.timedOut))
    let model = ReviewsModel(client: client)
    await model.refresh()
    await model.postAgentReview("g/p!1")
    #expect(model.agentBanner == Copy.agentTimedOut)
}

@Test func agentReviewStatesSayWhatCanHappenNext() {
    #expect(AgentReviewInfo(id: 1, status: "queued").isActive)
    #expect(AgentReviewInfo(id: 1, status: "posting").isActive)
    #expect(AgentReviewInfo(id: 1, status: "failed").canRequeue)
    #expect(AgentReviewInfo(id: 1, status: "posted").canRequeue)
    #expect(!AgentReviewInfo(id: 1, status: "ready").canRequeue)
    #expect(Copy.agentReviewBadge("discarded") == nil)
}

@Test func theRunningLineNamesTheCliTheModelAndHowLongItRuns() {
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(Copy.runningLine(cli: "claude", model: "opus", since: 1_000_000 - 3 * 60_000 - 5_000, now: now)
        == "Claude Code · opus · for 3 min")
    #expect(Copy.runningLine(cli: "codex", model: nil, since: 999_000, now: now) == "Codex · just started")
    #expect(Copy.agentReviewMeta(cli: "claude", model: "claude-opus-5-5", sha: "0123456789")
        == "By Claude Code (claude-opus-5-5) at commit 01234567")
    #expect(Copy.agentReviewBadge("queued") == "Agent review queued")
    #expect(Copy.agentReviewBadge("running") == "Agent reviewing now")
}
