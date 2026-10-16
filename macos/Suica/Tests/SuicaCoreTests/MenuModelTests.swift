import Foundation
import Testing

@testable import SuicaCore

actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

actor FakeClient: AgentClient {
    private var states: [Result<AgentState, AgentError>]
    private var sendResult: Result<ActionResult, AgentError> = .success(ActionResult(code: "sent"))
    private var otherResult: Result<ActionResult, AgentError> = .success(ActionResult(code: "skipped"))
    private var pauseResult: Result<Void, AgentError> = .success(())
    private var gate: Gate?
    private(set) var stateCalls = 0
    private(set) var sendCalls: [Int] = []
    private(set) var skipCalls: [Int] = []
    private(set) var retryCalls: [Int] = []
    private(set) var pauseCalls: [Bool] = []

    init(states: [Result<AgentState, AgentError>]) { self.states = states }

    func setSend(_ result: Result<ActionResult, AgentError>, gate: Gate? = nil) {
        sendResult = result
        self.gate = gate
    }
    func setOther(_ result: Result<ActionResult, AgentError>) { otherResult = result }
    func setPause(_ result: Result<Void, AgentError>) { pauseResult = result }
    func setStates(_ next: [Result<AgentState, AgentError>]) { states = next }

    func state() async throws(AgentError) -> AgentState {
        stateCalls += 1
        let result = states.count > 1 ? states.removeFirst() : (states.first ?? .failure(.launchFailed))
        return try result.get()
    }

    func send(id: Int) async throws(AgentError) -> ActionResult {
        sendCalls.append(id)
        if let gate { await gate.wait() }
        return try sendResult.get()
    }

    func skip(id: Int) async throws(AgentError) -> ActionResult {
        skipCalls.append(id)
        return try otherResult.get()
    }

    func retry(id: Int) async throws(AgentError) -> ActionResult {
        retryCalls.append(id)
        return try otherResult.get()
    }

    func setPaused(_ paused: Bool) async throws(AgentError) {
        pauseCalls.append(paused)
        try pauseResult.get()
    }
}

func item(_ id: Int, _ status: String) -> OutboxItem {
    OutboxItem(
        id: id, kind: "nudge", status: status, detail: "", recipientName: "Bob", mrKey: "g/p!5",
        mrTitle: "t", mrUrl: "https://x", text: "Halo Bob", createdAt: 0, updatedAt: 0)
}

func makeState(attention: [OutboxItem] = [], paused: Bool = false) -> AgentState {
    AgentState(
        version: 1, paused: paused, baselineDone: true, trackedAuthored: 1, reviewRequested: 2,
        teams: TeamsSection(counts: [:], attentionHidden: 0, attention: attention, recent: []))
}

@MainActor @Test func refreshStoresTheStateAndClearsAnEarlierError() async {
    let client = FakeClient(states: [.failure(.failed(exitCode: 1)), .success(makeState())])
    let model = MenuModel(client: client)
    await model.refresh()
    #expect(model.state == nil)
    #expect(model.errorText == Copy.agentUnreachable)
    await model.refresh()
    #expect(model.state?.reviewRequested == 2)
    #expect(model.errorText == nil)
}

@MainActor @Test func aFailedRefreshKeepsTheLastGoodStateAndShowsAPlainError() async {
    let good = makeState(attention: [item(1, "pending")])
    let client = FakeClient(states: [.success(good)])
    let model = MenuModel(client: client)
    await model.refresh()
    let cases: [(AgentError, String)] = [
        (.timedOut, Copy.agentTimedOut), (.unsupportedVersion(2), Copy.agentOutdated),
        (.failed(exitCode: 9), Copy.agentUnreachable), (.badOutput, Copy.agentUnreachable),
        (.launchFailed, Copy.agentUnreachable),
    ]
    for (error, text) in cases {
        await client.setStates([.failure(error)])
        await model.refresh()
        #expect(model.state == good)
        #expect(model.errorText == text)
    }
}

@MainActor @Test func badgeCountsPendingAndUnresolvedOnly() async {
    let attention = [
        item(1, "pending"), item(2, "unresolved"), item(3, "failed"), item(4, "queued"), item(5, "sending"),
    ]
    let model = MenuModel(client: FakeClient(states: [.success(makeState(attention: attention))]))
    #expect(model.badgeCount == 0)
    await model.refresh()
    #expect(model.badgeCount == 2)
}

@MainActor @Test func sendNeedsAConfirmationAndOnlyForSendableItems() async {
    let client = FakeClient(states: [.success(makeState())])
    let model = MenuModel(client: client)
    for status in ["sent", "skipped", "failed", "unresolved", "queued", "sending", "dry-run", "teleported"] {
        model.requestSend(item(1, status))
        #expect(model.confirmation == nil, "\(status)")
    }
    model.requestSend(item(1, "pending"))
    #expect(model.confirmation?.id == 1)
    #expect(await client.sendCalls.isEmpty)
}

@MainActor @Test func cancellingTheConfirmationSendsNothing() async {
    let client = FakeClient(states: [.success(makeState())])
    let model = MenuModel(client: client)
    model.requestSend(item(1, "pending"))
    model.cancelConfirmation()
    #expect(model.confirmation == nil)
    await model.confirmSend()
    #expect(await client.sendCalls.isEmpty)
}

@MainActor @Test func confirmSendCallsTheClientOnceThenRefreshesAndShowsTheOutcome() async {
    let client = FakeClient(states: [.success(makeState())])
    let model = MenuModel(client: client)
    model.requestSend(item(7, "pending"))
    await model.confirmSend()
    #expect(await client.sendCalls == [7])
    #expect(await client.stateCalls == 1)
    #expect(model.banner == Copy.flash(for: "sent"))
    #expect(model.confirmation == nil)
    #expect(model.state != nil)
    #expect(model.busyIds.isEmpty)
}

@MainActor @Test func aSecondSendOfTheSameIdWhileInFlightIsIgnored() async throws {
    let gate = Gate()
    let client = FakeClient(states: [.success(makeState())])
    await client.setSend(.success(ActionResult(code: "sent")), gate: gate)
    let model = MenuModel(client: client)
    model.requestSend(item(7, "pending"))
    let first = Task { await model.confirmSend() }
    while !model.busyIds.contains(7) { await Task.yield() }
    model.requestSend(item(7, "pending"))
    #expect(model.confirmation == nil)
    await model.confirmSend()
    await model.skip(item(7, "pending"))
    #expect(await client.sendCalls == [7])
    #expect(await client.skipCalls.isEmpty)
    await gate.open()
    await first.value
    #expect(model.busyIds.isEmpty)
}

@MainActor @Test func busyIdsAreClearedAfterAFailureAndTheLastStateSurvives() async {
    let client = FakeClient(states: [.success(makeState(attention: [item(7, "pending")]))])
    let model = MenuModel(client: client)
    await model.refresh()
    await client.setSend(.failure(.timedOut))
    model.requestSend(item(7, "pending"))
    await model.confirmSend()
    #expect(model.banner == Copy.agentTimedOut)
    #expect(model.busyIds.isEmpty)
    #expect(model.state != nil)
}

@MainActor @Test func aStaleRowGivesAnExplanationAndARefresh() async {
    let client = FakeClient(states: [.success(makeState())])
    await client.setSend(.success(ActionResult(code: "not-pending")))
    let model = MenuModel(client: client)
    model.requestSend(item(3, "pending"))
    await model.confirmSend()
    #expect(model.banner == Copy.flash(for: "not-pending"))
    #expect(await client.stateCalls == 1)
}

@MainActor @Test func skipRetryAndPauseCallTheClientAndRefresh() async {
    let client = FakeClient(states: [.success(makeState())])
    let model = MenuModel(client: client)
    await model.skip(item(1, "pending"))
    #expect(await client.skipCalls == [1])
    #expect(model.banner == Copy.flash(for: "skipped"))
    await client.setOther(.success(ActionResult(code: "retried")))
    await model.retry(item(2, "unresolved"))
    #expect(await client.retryCalls == [2])
    #expect(model.banner == Copy.flash(for: "retried"))
    await model.refresh()
    await model.togglePause()
    #expect(await client.pauseCalls == [true])
    await client.setStates([.success(makeState(paused: true))])
    await model.refresh()
    #expect(model.isPaused)
    await model.togglePause()
    #expect(await client.pauseCalls == [true, false])
    #expect(await client.stateCalls == 6)
}

@MainActor @Test func aFailedPauseShowsAPlainError() async {
    let client = FakeClient(states: [.success(makeState())])
    await client.setPause(.failure(.failed(exitCode: 1)))
    let model = MenuModel(client: client)
    await model.togglePause()
    #expect(model.banner == Copy.agentUnreachable)
}

@MainActor @Test func theRefreshLoopRefreshesRepeatedlyAndStopsOnCancel() async throws {
    let client = FakeClient(states: [.success(makeState())])
    let model = MenuModel(client: client)
    let loop = Task { await model.runRefreshLoop(every: .milliseconds(10)) }
    while await client.stateCalls < 3 { try await Task.sleep(for: .milliseconds(5)) }
    loop.cancel()
    await loop.value
    let calls = await client.stateCalls
    try await Task.sleep(for: .milliseconds(60))
    #expect(await client.stateCalls == calls)
}

@MainActor @Test func sendTakesTheItemItIsGivenEvenIfTheConfirmationWasAlreadyCleared() async {
    let client = FakeClient(states: [.success(makeState())])
    let model = MenuModel(client: client)
    model.requestSend(item(4, "pending"))
    model.cancelConfirmation()
    await model.send(item(4, "pending"))
    #expect(await client.sendCalls == [4])
    #expect(model.banner == Copy.flash(for: "sent"))
}

@MainActor @Test func sendRefusesAnItemThatCannotBeSent() async {
    let client = FakeClient(states: [.success(makeState())])
    let model = MenuModel(client: client)
    await model.send(item(4, "sent"))
    #expect(await client.sendCalls.isEmpty)
}

@MainActor @Test func aRefreshThatNoLongerListsTheItemAsPendingClearsTheConfirmation() async {
    let pending = makeState(attention: [item(7, "pending")])
    let client = FakeClient(states: [.success(pending)])
    let model = MenuModel(client: client)
    await model.refresh()
    model.requestSend(item(7, "pending"))
    await model.refresh()
    #expect(model.confirmation?.id == 7)
    // Sent elsewhere in the meantime: it moved to "recent" as sent.
    let sentElsewhere = AgentState(
        version: 1, paused: false, baselineDone: true, trackedAuthored: 1, reviewRequested: 2,
        teams: TeamsSection(counts: [:], attentionHidden: 0, attention: [], recent: [item(7, "sent")]))
    await client.setStates([.success(sentElsewhere)])
    await model.refresh()
    #expect(model.confirmation == nil)
}

@MainActor @Test func aFailedRefreshKeepsTheConfirmation() async {
    let client = FakeClient(states: [.success(makeState(attention: [item(7, "pending")]))])
    let model = MenuModel(client: client)
    await model.refresh()
    model.requestSend(item(7, "pending"))
    await client.setStates([.failure(.timedOut)])
    await model.refresh()
    #expect(model.confirmation?.id == 7)
}
