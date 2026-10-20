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

private func detail(_ key: String, _ overrides: [String: Any] = [:]) throws -> MergeRequestDetail {
    let golden = try decodeDocument(MergeRequestDetail.self, from: contract("mr-detail.v1.json"))
    let json = try JSONEncoder().encode(golden)
    var object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    object["key"] = key
    object.merge(overrides) { _, new in new }
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

    func postAgentReview(id: Int, inline: Bool) async throws(AgentError) -> ActionResult {
        actions.append("post \(id)\(inline ? " inline" : "")")
        return try actionResult.get()
    }

    func discardAgentReview(id: Int) async throws(AgentError) -> ActionResult {
        actions.append("discard \(id)")
        return try actionResult.get()
    }

    func cancelAgentReview(id: Int) async throws(AgentError) -> ActionResult {
        actions.append("cancel \(id)")
        return try actionResult.get()
    }

    func approve(key: String, sha: String) async throws(AgentError) -> ActionResult {
        actions.append("approve \(key) \(sha)")
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
    #expect(reviews.mergeRequests.map(\.key) == ["g/p!7", "g/p!9"])
    #expect(reviews.mergeRequests.first?.draft == true)
    #expect(reviews.mergeRequests.first?.reviewers.first?.state == "UNREVIEWED")
    #expect(reviews.me == Person(username: "me", name: "Nata"))
    #expect(reviews.sections.map(\.group) == [.waiting, .drafts])
    let agent = try #require(reviews.mergeRequests.first?.agentReview)
    #expect(agent.id == 3 && agent.status == "ready" && agent.cli == "claude" && agent.isReady)
    #expect(agent.model == "claude-opus-5-5" && agent.startedAt == 1_792_148_500_000)
    #expect(agent.headSha?.hasPrefix("01234567") == true && agent.body?.hasPrefix("# Code review") == true)
    #expect(!agent.isActive && !agent.canRequeue)
    #expect(agent.activity == [])
    #expect(agent.previousSha == nil)
    let rereview = try #require(reviews.mergeRequests.last?.agentReview)
    #expect(rereview.previousSha == "0123456789abcdef0123456789abcdef01234567")
    #expect(rereview.headSha == "89abcdef0123456789abcdef0123456789abcdef")

    let mr = try decodeDocument(MergeRequestDetail.self, from: contract("mr-detail.v1.json"))
    #expect(mr.pipelineStatus == "SUCCESS" && mr.additions == 3 && mr.deletions == 1)
    #expect(mr.files.map(\.diff?.isEmpty) == [false, nil])
    #expect(mr.discussions.count == 2)
    #expect(mr.comments.map(\.id) == ["gid://gitlab/Discussion/2"])
    #expect(mr.comments.first?.notes.first?.filePath == "src/a.ts")
    #expect(mr.comments.first?.notes.first?.date != nil)
    #expect(mr.updatedDate != nil)
    #expect(mr.squashOnMerge == true && mr.canApprove == true)
    #expect(mr.headSha == "0123456789abcdef0123456789abcdef01234567")
}

@MainActor @Test func anMRFromAnOlderAgentDecodesWithoutTheApproveFields() throws {
    var object = try #require(
        try JSONSerialization.jsonObject(with: contract("mr-detail.v1.json")) as? [String: Any])
    for field in ["squashOnMerge", "headSha", "canApprove"] { object[field] = nil }
    let mr = try decodeDocument(MergeRequestDetail.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(mr.squashOnMerge == nil && mr.headSha == nil && mr.canApprove == nil)
    #expect(!ReviewsModel(client: FakeReviewsClient(lists: [])).canApprove(mr))
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
    #expect(item("rereview").isAboutYourMR)
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

@MainActor @Test func refreshReadsTheSelectedMRAgainAndForgetsTheOthers() async throws {
    let client = FakeReviewsClient(lists: [.success(list("g/p!1", "g/p!2"))])
    await client.setDetail("g/p!1", .success(try detail("g/p!1")))
    await client.setDetail("g/p!2", .success(try detail("g/p!2")))
    let model = ReviewsModel(client: client)
    await model.refresh()
    await model.select("g/p!2")
    await model.refresh()
    #expect(await client.detailCalls == ["g/p!1", "g/p!2", "g/p!2"])
    #expect(model.details["g/p!1"] == nil)
    #expect(model.selectedDetail?.key == "g/p!2")
}

@MainActor @Test func aBackgroundRefreshKeepsTheApprovalOutcome() async throws {
    let client = FakeReviewsClient(lists: [.success(list("g/p!1"))])
    await client.setDetail("g/p!1", .success(try detail("g/p!1")))
    let model = ReviewsModel(client: client)
    await model.refresh()
    await model.approve("g/p!1")
    let notice = model.approvalNotices["g/p!1"]
    await model.refresh()
    #expect(model.approvalNotices["g/p!1"] == notice)
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
    await model.postAgentReview("g/p!1", inline: false)
    #expect(await client.actions.isEmpty)

    await client.setLists([.success(withAgent("ready"))])
    await model.refresh()
    await client.setActionResult(.success(ActionResult(code: "posted")))
    await model.postAgentReview("g/p!1", inline: false)
    #expect(await client.actions == ["post 9"])
    #expect(model.agentBanner == "Review posted to GitLab.")
    await model.postAgentReview("g/p!1", inline: true)
    await model.discardAgentReview("g/p!1")
    #expect(await client.actions == ["post 9", "post 9 inline", "discard 9"])
}

@MainActor @Test func cancelStopsOnlyAQueuedOrRunningReviewAndCanBeReviewedAgain() async {
    let client = FakeReviewsClient(lists: [.success(withAgent("posting"))])
    let model = ReviewsModel(client: client)
    await model.refresh()
    await model.cancelAgentReview("g/p!1")
    #expect(await client.actions.isEmpty)

    await client.setLists([.success(withAgent("running")), .success(withAgent("cancelled"))])
    await model.refresh()
    await client.setActionResult(.success(ActionResult(code: "cancelled")))
    await model.cancelAgentReview("g/p!1")
    #expect(await client.actions == ["cancel 9"])
    #expect(model.agentBanner == "Review cancelled.")
    #expect(!model.hasActiveAgentReview)
    #expect(model.offersReview(for: "g/p!1"))
    #expect(AgentReviewInfo(id: 1, status: "queued").isCancellable)
    #expect(!AgentReviewInfo(id: 1, status: "ready").isCancellable)
}

@MainActor @Test func aFailedAgentActionShowsTheError() async {
    let client = FakeReviewsClient(lists: [.success(withAgent("ready"))])
    await client.setActionResult(.failure(.timedOut))
    let model = ReviewsModel(client: client)
    await model.refresh()
    await model.postAgentReview("g/p!1", inline: true)
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
    #expect(Copy.runningLine(cli: "codex", model: nil, since: 1_000_000 - 75 * 60_000, now: now)
        == "Codex · for 1 h 15 min")
    #expect(Copy.agentReviewMeta(cli: "claude", model: "claude-opus-5-5", sha: "0123456789")
        == "By Claude Code (claude-opus-5-5) at commit 01234567")
    #expect(Copy.agentReviewBadge("queued") == "Agent review queued")
    #expect(Copy.agentReviewBadge("running") == "Agent reviewing now")
}

@MainActor @Test func approvingUsesTheCommitOnScreenKeepsTheOutcomeAndReadsTheMRAgain() async throws {
    let sha = "0123456789abcdef0123456789abcdef01234567"
    let client = FakeReviewsClient(lists: [.success(list("g/p!1"))])
    await client.setDetail("g/p!1", .success(try detail("g/p!1")))
    await client.setActionResult(.success(ActionResult(code: "approved")))
    let model = ReviewsModel(client: client)
    await model.refresh()
    await model.approve("g/p!1")
    #expect(await client.actions == ["approve g/p!1 \(sha)"])
    #expect(await client.detailCalls == ["g/p!1", "g/p!1"])
    #expect(model.approvalNotices["g/p!1"] == "Approved on GitLab.")
    #expect(model.approvingKeys.isEmpty)
    await model.loadDetail("g/p!1")
    #expect(model.approvalNotices["g/p!1"] == nil)
}

@MainActor @Test func aPushSinceOpeningIsReported() async throws {
    let client = FakeReviewsClient(lists: [.success(list("g/p!1"))])
    await client.setDetail("g/p!1", .success(try detail("g/p!1")))
    await client.setActionResult(.success(ActionResult(code: "head-changed")))
    let model = ReviewsModel(client: client)
    await model.refresh()
    await model.approve("g/p!1")
    #expect(model.approvalNotices["g/p!1"] == Copy.approveOutcome("head-changed"))
}

@MainActor @Test func approveIsNotOfferedWhenGitLabSaysNoOrYouAlreadyApproved() async throws {
    let me = Person(username: "bob", name: "Bob")
    let mine = ReviewListDocument(version: 1, me: me, mergeRequests: [summary("g/p!1"), summary("g/p!2")])
    let client = FakeReviewsClient(lists: [.success(mine)])
    await client.setDetail("g/p!1", .success(try detail("g/p!1")))
    await client.setDetail("g/p!2", .success(try detail("g/p!2", ["approvedBy": [], "canApprove": false])))
    let model = ReviewsModel(client: client)
    await model.refresh()
    await model.select("g/p!2")
    let approved = try #require(model.details["g/p!1"])
    let refused = try #require(model.details["g/p!2"])
    #expect(model.isApprovedByMe(approved) && !model.canApprove(approved))
    #expect(!model.isApprovedByMe(refused) && !model.canApprove(refused))
    await model.approve("g/p!1")
    await model.approve("g/p!2")
    #expect(await client.actions.isEmpty)
}

@Test func theProjectURLIsTheMergeRequestURLBeforeItsDashPath() throws {
    #expect(try detail("g/p!7", ["url": "https://gitlab.example/g/sub/p/-/merge_requests/7"]).projectURL
        == "https://gitlab.example/g/sub/p")
    #expect(try detail("g/p!7", ["url": "https://gitlab.example/odd"]).projectURL == nil)
}

@Test func anOlderAgentSendsNoPreviousSha() throws {
    let json = Data(
        """
        {"id": 1, "status": "ready", "headSha": "abc", "detail": "", "createdAt": 1, "updatedAt": 2}
        """.utf8)
    let review = try JSONDecoder().decode(AgentReviewInfo.self, from: json)
    #expect(review.previousSha == nil && review.headSha == "abc")
    #expect(AgentReviewInfo(id: 1, status: "ready", previousSha: "abc").previousSha == "abc")
}

@Test func theMergeRequestPageOffersAnotherReviewOnlyWhenThereIsSomethingNewToReview() {
    func mr(_ status: String?, changed: Bool = false) -> ReviewSummary {
        ReviewSummary(
            key: "g/p!1", title: "t", url: "https://x", draft: false, author: Person(username: "a", name: "A"),
            reviewers: [], agentReview: status.map { AgentReviewInfo(id: 1, status: $0) },
            changedSinceReview: changed ? ChangedSinceReview(code: true, description: false) : nil)
    }
    #expect(mr(nil).offersReview)
    #expect(!mr("posted").offersReview)
    #expect(mr("posted", changed: true).offersReview)
    for status in ["failed", "skipped", "discarded"] { #expect(mr(status).offersReview, "\(status)") }
    for status in ["queued", "running", "ready", "posting"] { #expect(!mr(status, changed: true).offersReview, "\(status)") }
}

@Test func aMergeRequestReadyToApproveIsMarked() throws {
    let list = try decodeDocument(ReviewListDocument.self, from: contract("reviews.v1.json"))
    #expect(list.mergeRequests.map(\.readyToApprove) == [false, false])
    let older = Data("""
        {"key": "g/p!2", "title": "t", "url": "https://x", "draft": false, "author": {"username": "a", "name": "A"}, "reviewers": []}
        """.utf8)
    #expect(try JSONDecoder().decode(ReviewSummary.self, from: older).readyToApprove == false)
    #expect(Copy.readyToApprove == "Ready to approve: only minor findings left")
}

@Test func aRereviewIsLabelled() {
    #expect(Copy.agentRereviewLabel == "Re-review")
}

@Test func theListSaysHowAnMergeRequestChangedSinceTheAgentsReview() throws {
    let list = try decodeDocument(ReviewListDocument.self, from: contract("reviews.v1.json"))
    #expect(list.mergeRequests.first?.changedSinceReview == nil)
    let changed = try #require(list.mergeRequests.last?.changedSinceReview)
    #expect(changed == ChangedSinceReview(code: true, description: false))
    #expect(Copy.changedSinceReview(changed) == "Code changed since review")
    #expect(Copy.changedSinceReview(ChangedSinceReview(code: false, description: true)) == "Description changed since review")
    #expect(Copy.changedSinceReview(ChangedSinceReview(code: true, description: true)) == "Code and description changed since review")
    // The row offers Re-review only while no review is queued, running, ready or being posted.
    #expect(list.mergeRequests.last?.offersRereview == true)
    let open = ReviewSummary(
        key: "g/p!1", title: "t", url: "https://x", draft: false, author: Person(username: "a", name: "A"),
        reviewers: [], agentReview: AgentReviewInfo(id: 1, status: "ready"), changedSinceReview: ChangedSinceReview(code: true, description: false))
    #expect(!open.offersRereview)
    let unchanged = ReviewSummary(
        key: "g/p!1", title: "t", url: "https://x", draft: false, author: Person(username: "a", name: "A"), reviewers: [])
    #expect(!unchanged.offersRereview)
    let older = Data("""
        {"key": "g/p!2", "title": "t", "url": "https://x", "draft": false, "author": {"username": "a", "name": "A"}, "reviewers": []}
        """.utf8)
    #expect(try JSONDecoder().decode(ReviewSummary.self, from: older).changedSinceReview == nil)
}

@Test func aSummaryReadsWhenTheMergeRequestWasOpened() throws {
    let list = try decodeDocument(ReviewListDocument.self, from: contract("reviews.v1.json"))
    #expect(list.mergeRequests.first?.createdDate == Date(timeIntervalSince1970: 1_791_968_400))
    #expect(ReviewSummary(
        key: "g/p!1", title: "t", url: "https://x", draft: false, author: Person(username: "a", name: "A"),
        reviewers: []).createdDate == nil)
}

@Test func aRunningReviewsActivityDecodesAndAnOlderCliHasNone() throws {
    let running = #"{"id":1,"status":"running","detail":"","createdAt":0,"updatedAt":0,"activity":[{"at":1792148400000,"text":"Reading src/a.ts"}]}"#
    let review = try JSONDecoder().decode(AgentReviewInfo.self, from: Data(running.utf8))
    #expect(review.activity == [ReviewActivityLine(at: 1_792_148_400_000, text: "Reading src/a.ts")])
    let older = #"{"id":1,"status":"running","detail":"","createdAt":0,"updatedAt":0}"#
    #expect(try JSONDecoder().decode(AgentReviewInfo.self, from: Data(older.utf8)).activity == nil)
}

@MainActor @Test func thePageRefreshesEvery3SecondsWhileAReviewRuns() async {
    for (status, seconds) in [("running", 3), ("queued", 15), ("posting", 15), ("ready", 30)] {
        let model = ReviewsModel(client: FakeReviewsClient(lists: [.success(withAgent(status))]))
        await model.refresh()
        #expect(model.refreshSeconds == seconds, "\(status)")
    }
}

@MainActor @Test func onlyASuccessfulApprovalCountsForTheCelebration() async throws {
    let client = FakeReviewsClient(lists: [.success(list("g/p!1"))])
    await client.setDetail("g/p!1", .success(try detail("g/p!1")))
    await client.setActionResult(.success(ActionResult(code: "head-changed")))
    let model = ReviewsModel(client: client)
    await model.refresh()
    await model.approve("g/p!1")
    #expect(model.approvedCount == 0)
    await client.setActionResult(.success(ActionResult(code: "approved")))
    await model.approve("g/p!1")
    #expect(model.approvedCount == 1)
}

@Test func theListSaysWhyAnAutomaticRereviewHasNotRun() throws {
    let list = try decodeDocument(ReviewListDocument.self, from: contract("reviews.v1.json"))
    #expect(list.mergeRequests.first?.rereviewWaiting == nil)
    let waiting = try #require(list.mergeRequests.last?.rereviewWaiting)
    #expect(waiting == RereviewWaiting(reason: "waiting", dueAt: 1_792_152_800_000))
    #expect(waiting.dueDate == Date(timeIntervalSince1970: 1_792_152_800))
    #expect(Copy.rereviewWaiting(waiting, dueTime: "15:20") == "Auto re-review due at 15:20")
    #expect(Copy.rereviewWaiting(RereviewWaiting(reason: "daily-cap"), dueTime: nil) == "Auto re-review held: daily review cap reached")
    #expect(Copy.rereviewWaiting(RereviewWaiting(reason: "approved"), dueTime: nil) == "No auto re-review: approved")
    #expect(Copy.rereviewWaiting(RereviewWaiting(reason: "draft"), dueTime: nil) == "No auto re-review while it is a draft")
    #expect(Copy.rereviewWaiting(RereviewWaiting(reason: "later"), dueTime: nil) == nil)
    let older = Data("""
        {"key": "g/p!2", "title": "t", "url": "https://x", "draft": false, "author": {"username": "a", "name": "A"}, "reviewers": []}
        """.utf8)
    #expect(try JSONDecoder().decode(ReviewSummary.self, from: older).rereviewWaiting == nil)
}
