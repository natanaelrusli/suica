import Foundation
import Testing

@testable import SuicaCore

private let me = Person(username: "me", name: "Me")

private func mr(
    _ key: String, draft: Bool = false, mine: String? = "UNREVIEWED", agent: String? = nil,
    changed: Bool = false, ready: Bool = false
) -> ReviewSummary {
    ReviewSummary(
        key: key, title: key, url: "https://x/\(key)", draft: draft, author: Person(username: "a", name: "A"),
        reviewers: mine.map { [ReviewerInfo(username: "me", name: "Me", state: $0)] } ?? [],
        agentReview: agent.map { AgentReviewInfo(id: 1, status: $0) },
        changedSinceReview: changed ? ChangedSinceReview(code: true, description: false) : nil,
        readyToApprove: ready)
}

@Test func thePanelOpensOnNeedsYouOnlyWhenSomethingWaits() {
    #expect(PanelTab.opening(badgeCount: 0) == .recent)
    #expect(PanelTab.opening(badgeCount: 2) == .needsYou)
}

@Test func shortcutsListReadyThenChangedThenWaitingOncePerMrWithoutDrafts() {
    let list = ReviewListDocument(
        version: 1, me: me,
        mergeRequests: [
            mr("w1"),
            mr("reviewed", mine: "APPROVED"),
            mr("changed", mine: "REQUESTED_CHANGES", agent: "posted", changed: true),
            mr("ready", agent: "posted", ready: true),
            mr("draft", draft: true, ready: true),
            mr("w2", agent: "failed"),
        ])
    let rows = list.shortcuts()
    #expect(rows.map(\.id) == ["ready", "changed", "w1", "w2"])
    #expect(rows.map(\.reason) == [.readyToApprove, .changed, .waiting, .waiting])
    #expect(rows.map(\.action) == [.open, .rereview, .agentReview, .agentReview])
    #expect(list.shortcuts(limit: 2).map(\.id) == ["ready", "changed"])
    #expect(list.readyToApproveCount == 1)
}

@Test func aWaitingMrWithAReviewUnderWayOnlyOpens() {
    let list = ReviewListDocument(version: 1, me: me, mergeRequests: [mr("q", agent: "queued"), mr("r", agent: "ready")])
    #expect(list.shortcuts().map(\.action) == [.open, .open])
    #expect(list.readyToPost.map(\.key) == ["r"])
}

@Test func withoutMeEveryNonDraftMrWaitsAndAnEmptyListHasNoShortcuts() {
    let older = ReviewListDocument(version: 1, mergeRequests: [mr("a", mine: nil), mr("d", draft: true, mine: nil)])
    #expect(older.shortcuts().map(\.id) == ["a"])
    #expect(older.shortcuts().map(\.reason) == [.waiting])
    #expect(ReviewListDocument(version: 1, me: me, mergeRequests: []).shortcuts().isEmpty)
}

private func day(_ name: String, requests: Int, nudges: Int) -> DayStats {
    DayStats(
        day: name, reviewRequests: requests, activity: 0, nudgesSent: nudges, noticesSent: 0, skipped: 0, failed: 0)
}

private func stats(days: [DayStats], ok: Int, failed: Int) -> StatsDocument {
    StatsDocument(
        version: 1, generatedAt: 0, lastPoll: nil, polls24h: PollCounts(ok: 0, failed: 0),
        polls7d: PollCounts(ok: ok, failed: failed), days: days,
        ownerAfterRequest: Turnaround(count: 0, medianMinutes: nil, p90Minutes: nil),
        reviewerAfterNudge: Turnaround(count: 0, medianMinutes: nil, p90Minutes: nil))
}

@Test func theWeekSumsTheLastSevenDaysAndRatesPolls() {
    let ten = (1...10).map { day("d\($0)", requests: $0, nudges: 1) }
    let week = stats(days: ten, ok: 99, failed: 1).week
    #expect(week.days.map(\.day) == (4...10).map { "d\($0)" })
    #expect(week.reviewRequests == (4...10).reduce(0, +))
    #expect(week.nudgesSent == 7)
    #expect(week.pollSuccess == 0.99)
}

@Test func aShortWeekUsesWhatThereIsAndNoPollsHaveNoRate() {
    let week = stats(days: [day("a", requests: 2, nudges: 0), day("b", requests: 3, nudges: 1)], ok: 0, failed: 0).week
    #expect(week.days.count == 2 && week.reviewRequests == 5 && week.nudgesSent == 1)
    #expect(week.pollSuccess == nil)
}

@MainActor @Test func cancelByIdWorksBeforeTheListIsLoaded() async {
    let client = FakeReviewsClient(lists: [.success(ReviewListDocument(version: 1, mergeRequests: []))])
    await client.setActionResult(.success(ActionResult(code: "cancelled")))
    let model = ReviewsModel(client: client)
    await model.cancelAgentReview(id: 7, key: "g/p!1")
    #expect(await client.actions == ["cancel 7"])
    #expect(model.agentBanner == "Review cancelled.")
    #expect(model.agentBusyKeys.isEmpty)
}

@MainActor @Test func refreshStatusReadsOnlyTheStatusAndKeepsTheLastGoodOne() async {
    let client = FakeDashboardClient(statuses: [.success(makeStatus()), .failure(.timedOut)])
    let window = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    await window.refreshStatus()
    #expect(window.status == makeStatus())
    await window.refreshStatus()
    #expect(window.status == makeStatus())
    #expect(await client.statusCalls == 2)
    #expect(await client.statsCalls == 0)
}
