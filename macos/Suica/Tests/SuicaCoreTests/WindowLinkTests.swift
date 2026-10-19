import Testing

@testable import SuicaCore

private func row(_ id: Int, kind: String = "rereview") -> OutboxItem {
    OutboxItem(
        id: id, kind: kind, status: "pending", detail: "", recipientName: "Rina", mrKey: "g/p!5",
        mrTitle: "t", mrUrl: "https://x", text: "Halo", createdAt: 0, updatedAt: 0)
}

private func state(attention: [OutboxItem], recent: [OutboxItem] = []) -> AgentState {
    AgentState(
        version: 1, paused: false, baselineDone: true, trackedAuthored: 1, reviewRequested: 0,
        teams: TeamsSection(counts: [:], attentionHidden: 0, attention: attention, recent: recent))
}

@MainActor private func windowModel(_ client: FakeClient) -> WindowModel {
    WindowModel(client: FakeDashboardClient(), menu: MenuModel(client: client))
}

@MainActor @Test func aMessageLinkSelectsItsRowOnceARefreshShowsIt() async {
    // The popover model has not read anything yet: the link refreshes before it looks.
    let client = FakeClient(states: [.success(state(attention: [row(3), row(9)]))])
    let window = windowModel(client)
    window.messageGroup = .others
    await window.show(.message(9))
    #expect(window.selectedMessageId == 9)
    #expect(window.messageGroup == .yours)
    #expect(await client.stateCalls == 1)
}

@MainActor @Test func aMessageLinkAlsoFindsARowThatWasAlreadySent() async {
    let client = FakeClient(states: [.success(state(attention: [row(3)], recent: [row(9, kind: "nudge")]))])
    let window = windowModel(client)
    await window.show(.message(9))
    #expect(window.selectedMessageId == 9)
}

@MainActor @Test func aMessageLinkToARowThatIsGoneOnlyShowsYourMRs() async {
    let client = FakeClient(states: [.success(state(attention: [row(3)]))])
    let window = windowModel(client)
    window.messageGroup = .others
    window.selectedMessageId = 3
    await window.show(.message(99))
    #expect(window.selectedMessageId == nil)
    #expect(window.messageGroup == .yours)
}

@MainActor @Test func aMessageLinkToAReviewNoticeSelectsNothingBecauseThatListIsNotYourMRs() async {
    let client = FakeClient(states: [.success(state(attention: [row(3, kind: "notice")]))])
    let window = windowModel(client)
    await window.show(.message(3))
    #expect(window.selectedMessageId == nil)
    #expect(window.messageGroup == .yours)
}

@MainActor @Test func aMessageLinkWhenTheAgentCannotBeReadSelectsNothing() async {
    let window = windowModel(FakeClient(states: [.failure(.timedOut)]))
    await window.show(.message(9))
    #expect(window.selectedMessageId == nil)
    #expect(window.messageGroup == .yours)
}

@MainActor @Test func theMessagesLinkShowsYourMRsWithNothingSelectedAndReadsNothing() async {
    let client = FakeClient(states: [.success(state(attention: [row(3)]))])
    let window = windowModel(client)
    window.messageGroup = .others
    window.selectedMessageId = 3
    await window.show(.messages)
    #expect(window.selectedMessageId == nil)
    #expect(window.messageGroup == .yours)
    #expect(await client.stateCalls == 0)
}

@MainActor @Test func theLatestLinkWinsEvenWhenAnOlderOneFinishesLast() async {
    let gate = Gate()
    let both = state(attention: [row(5), row(9)])
    let client = FakeClient(states: [.success(both), .success(both)])
    await client.holdFirstState(gate)
    let window = windowModel(client)
    let older = Task { await window.show(.message(9)) }
    while await client.stateCalls == 0 { await Task.yield() }
    await window.show(.message(5))
    #expect(window.selectedMessageId == 5)
    await gate.open()
    await older.value
    #expect(window.selectedMessageId == 5)
}

@MainActor @Test func aReceivedLinkWaitsForTheWindowAndIsTakenOnce() {
    let window = windowModel(FakeClient(states: []))
    #expect(window.takePendingLink() == nil && window.linksReceived == 0)
    window.receive(.messages)
    window.receive(.message(4))
    #expect(window.linksReceived == 2)
    #expect(window.takePendingLink() == .message(4))
    #expect(window.takePendingLink() == nil)
    #expect(window.linksReceived == 2)
}
