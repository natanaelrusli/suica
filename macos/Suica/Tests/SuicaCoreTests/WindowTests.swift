import Foundation
import Testing

@testable import SuicaCore

actor FakeDashboardClient: DashboardClient {
    private var statuses: [Result<StatusDocument, AgentError>]
    private var statsResults: [Result<StatsDocument, AgentError>]
    private var configs: [Result<ConfigDocument, AgentError>]
    private var usageResults: [Result<UsageDocument, AgentError>]
    private var saveResult: Result<SaveResult, AgentError> = .success(
        SaveResult(status: "saved", issues: [], sha256: "new"))
    private var restartResult: Result<ActionResult, AgentError> = .success(ActionResult(code: "restarted"))
    private var restartGate: Gate?
    private var saveGate: Gate?
    private var firstStatusGate: Gate?
    private(set) var statusCalls = 0
    private(set) var statsCalls = 0
    private(set) var usageCalls = 0
    private(set) var configCalls = 0
    private(set) var restartCalls = 0
    private(set) var saveCalls: [(base: String?, edits: [ConfigEditRequest])] = []

    init(
        statuses: [Result<StatusDocument, AgentError>] = [.success(makeStatus())],
        stats: [Result<StatsDocument, AgentError>] = [.success(makeStats())],
        configs: [Result<ConfigDocument, AgentError>] = [.success(makeConfig())],
        usage: [Result<UsageDocument, AgentError>] = [.success(makeUsage())]
    ) {
        self.statuses = statuses
        self.statsResults = stats
        self.configs = configs
        self.usageResults = usage
    }

    func setStatuses(_ next: [Result<StatusDocument, AgentError>]) { statuses = next }
    func setStats(_ next: [Result<StatsDocument, AgentError>]) { statsResults = next }
    func setUsage(_ next: [Result<UsageDocument, AgentError>]) { usageResults = next }
    func setConfigs(_ next: [Result<ConfigDocument, AgentError>]) { configs = next }
    func setSave(_ result: Result<SaveResult, AgentError>, gate: Gate? = nil) {
        saveResult = result
        saveGate = gate
    }
    func setRestart(_ result: Result<ActionResult, AgentError>, gate: Gate? = nil) {
        restartResult = result
        restartGate = gate
    }
    /// Holds the first `status()` call until the gate opens.
    func holdFirstStatus(_ gate: Gate) { firstStatusGate = gate }

    func status() async throws(AgentError) -> StatusDocument {
        statusCalls += 1
        let result = statuses.count > 1 ? statuses.removeFirst() : (statuses.first ?? .failure(.launchFailed))
        if statusCalls == 1, let gate = firstStatusGate { await gate.wait() }
        return try result.get()
    }

    func stats() async throws(AgentError) -> StatsDocument {
        statsCalls += 1
        let result =
            statsResults.count > 1 ? statsResults.removeFirst() : (statsResults.first ?? .failure(.launchFailed))
        return try result.get()
    }

    func usage() async throws(AgentError) -> UsageDocument {
        usageCalls += 1
        let result =
            usageResults.count > 1 ? usageResults.removeFirst() : (usageResults.first ?? .failure(.launchFailed))
        return try result.get()
    }

    func config() async throws(AgentError) -> ConfigDocument {
        configCalls += 1
        let result = configs.count > 1 ? configs.removeFirst() : (configs.first ?? .failure(.launchFailed))
        return try result.get()
    }

    func saveConfig(base: String?, edits: [ConfigEditRequest]) async throws(AgentError) -> SaveResult {
        saveCalls.append((base, edits))
        if let gate = saveGate { await gate.wait() }
        return try saveResult.get()
    }

    func restartAgent() async throws(AgentError) -> ActionResult {
        restartCalls += 1
        if let gate = restartGate { await gate.wait() }
        return try restartResult.get()
    }
}

func makeStatus(running: Bool = true) -> StatusDocument {
    StatusDocument(
        version: 1, agent: AgentService(label: "x", loaded: true, running: running, pid: 1),
        configError: nil, paused: false, teamsEnabled: true, lastPoll: nil,
        polling: PollingIntervals(activeSeconds: 60, idleSeconds: 300),
        paths: StatusPaths(config: "/c", state: "/s", logs: "/l", templates: "/t"))
}

func makeStats(ok: Int = 3) -> StatsDocument {
    StatsDocument(
        version: 1, generatedAt: 0, lastPoll: nil, polls24h: PollCounts(ok: ok, failed: 0),
        polls7d: PollCounts(ok: ok, failed: 0), days: [],
        ownerAfterRequest: Turnaround(count: 0, medianMinutes: nil, p90Minutes: nil),
        reviewerAfterNudge: Turnaround(count: 0, medianMinutes: nil, p90Minutes: nil))
}

func makeUsage(input: Int = 0) -> UsageDocument {
    let totals = TokenTotals(runs: 0, inputTokens: input, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
    return UsageDocument(
        version: 1, generatedAt: 0, last24h: totals, last7d: totals, last30d: totals, byPurpose: [], days: [])
}

@MainActor @Test func refreshKeepsTheLastGoodStatusOnFailure() async {
    let client = FakeDashboardClient()
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    await model.refresh()
    #expect(model.status == makeStatus())
    #expect(model.stats == makeStats())
    #expect(model.errorText == nil)
    await client.setStatuses([.failure(.timedOut)])
    await client.setStats([.failure(.failed(exitCode: 1))])
    await model.refresh()
    #expect(model.status == makeStatus())
    #expect(model.stats == makeStats())
    #expect(model.errorText == Copy.agentTimedOut)
    await client.setStatuses([.success(makeStatus(running: false))])
    await client.setStats([.success(makeStats(ok: 9))])
    await model.refresh()
    #expect(model.status?.agent.running == false)
    #expect(model.stats?.polls24h.ok == 9)
    #expect(model.errorText == nil)
}

@MainActor @Test func refreshReadsUsageAndKeepsTheLastGoodOneOnFailure() async {
    let client = FakeDashboardClient(usage: [.success(makeUsage(input: 7))])
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    await model.refresh()
    #expect(model.usage?.last24h.inputTokens == 7)
    await client.setUsage([.failure(.failed(exitCode: 1))])
    await model.refresh()
    #expect(model.usage?.last24h.inputTokens == 7)
    #expect(model.errorText == MenuModel.message(for: .failed(exitCode: 1)))
    // With a broken config the status document already says why.
    await client.setStatuses([.success(makeBrokenConfigStatus())])
    await model.refresh()
    #expect(model.errorText == nil)
}

@MainActor @Test func switchingTheModelCliWritesOnlyThatKeyOnTheCurrentFileAndRefreshes() async {
    let client = FakeDashboardClient(configs: [.success(makeConfig(sha: "now"))])
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    await model.switchModelCli(to: "codex")
    let saves = await client.saveCalls
    #expect(saves.count == 1)
    #expect(saves.first?.base == "now")
    #expect(saves.first?.edits == [ConfigEditRequest(path: ["model", "cli"], value: .string("codex"))])
    #expect(model.banner == Copy.modelCliSwitched)
    #expect(await client.statusCalls == 1)
    #expect(!model.savingSetting)
}

@MainActor @Test func aRefusedModelCliSwitchSaysWhy() async {
    let client = FakeDashboardClient()
    await client.setSave(
        .success(SaveResult(status: "invalid", issues: [ConfigIssue(path: "gitlab", message: "Required")], sha256: nil)))
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    await model.switchModelCli(to: "gemini")
    #expect(model.banner == "\(Copy.configInvalid) gitlab: Required")
    await client.setConfigs([.failure(.timedOut)])
    await model.switchModelCli(to: "gemini")
    #expect(model.banner == Copy.agentTimedOut)
    #expect(await client.saveCalls.count == 1)
}

func makeBrokenConfigStatus() -> StatusDocument {
    StatusDocument(
        version: 1, agent: AgentService(label: "x", loaded: true, running: false, pid: nil),
        configError: "invalid config: polling.activeSeconds: Expected integer", paused: nil,
        teamsEnabled: nil, lastPoll: nil, polling: nil,
        paths: StatusPaths(config: "/c", state: "/s", logs: "/l", templates: "/t"))
}

@MainActor @Test func aStatsFailureWithABrokenConfigIsNotShownAsUnreachable() async {
    let client = FakeDashboardClient()
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    await model.refresh()
    #expect(model.stats == makeStats())
    await client.setStatuses([.success(makeBrokenConfigStatus())])
    await client.setStats([.failure(.failed(exitCode: 1))])
    await model.refresh()
    // The status document says what is wrong; the stats failure follows from it.
    #expect(model.status == makeBrokenConfigStatus())
    #expect(model.errorText == nil)
    #expect(model.stats == makeStats())
    // A stats failure with a good config still shows.
    await client.setStatuses([.success(makeStatus())])
    await model.refresh()
    #expect(model.errorText == MenuModel.message(for: .failed(exitCode: 1)))
}

@MainActor @Test func aSlowRefreshThatFinishesLastDoesNotOverwriteANewerOne() async {
    let gate = Gate()
    let client = FakeDashboardClient(statuses: [.success(makeStatus(running: false)), .success(makeStatus())])
    await client.holdFirstStatus(gate)
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    let slow = Task { await model.refresh() }
    while await client.statusCalls < 1 { await Task.yield() }
    await model.refresh()
    #expect(model.status?.agent.running == true)
    await gate.open()
    await slow.value
    #expect(model.status?.agent.running == true)
}

@MainActor @Test func theWindowRefreshLoopRefreshesRepeatedlyAndStopsOnCancel() async throws {
    let client = FakeDashboardClient()
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    let loop = Task { await model.runRefreshLoop(every: .milliseconds(10)) }
    while await client.statusCalls < 3 { try await Task.sleep(for: .milliseconds(5)) }
    loop.cancel()
    await loop.value
    let calls = await client.statusCalls
    try await Task.sleep(for: .milliseconds(60))
    #expect(await client.statusCalls == calls)
}

@MainActor @Test func restartIsIgnoredWhileOneIsRunning() async {
    let gate = Gate()
    let client = FakeDashboardClient()
    await client.setRestart(.success(ActionResult(code: "restarted")), gate: gate)
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    let first = Task { await model.restartAgent() }
    while !model.restarting { await Task.yield() }
    await model.restartAgent()
    #expect(await client.restartCalls == 1)
    await gate.open()
    _ = await first.value
    #expect(!model.restarting)
    #expect(await client.restartCalls == 1)
}

@MainActor @Test func restartShowsTheResultAndRefreshes() async {
    let client = FakeDashboardClient()
    await client.setRestart(.success(ActionResult(code: "not-installed")))
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    #expect(await model.restartAgent() == false)
    #expect(model.banner == Copy.agentNotInstalled)
    #expect(await client.statusCalls == 1)
    #expect(await client.statsCalls == 1)
    await client.setRestart(.success(ActionResult(code: "restarted")))
    #expect(await model.restartAgent() == true)
    #expect(model.banner == "Agent restarted.")
    #expect(await client.statusCalls == 2)
}

@MainActor @Test func aClosedBannerStaysClosedUntilTheNextAction() async {
    let client = FakeDashboardClient()
    await client.setRestart(.success(ActionResult(code: "restarted")))
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    _ = await model.restartAgent()
    model.dismissBanner()
    #expect(model.banner == nil)
    await model.refresh()
    #expect(model.banner == nil)
    _ = await model.restartAgent()
    #expect(model.banner == "Agent restarted.")
}

@MainActor @Test func aFailedRestartSaysRestartingFailedNotSendingFailed() async {
    let client = FakeDashboardClient()
    await client.setRestart(.success(ActionResult(code: "failed")))
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    #expect(await model.restartAgent() == false)
    #expect(model.banner == Copy.restartFailed)
    #expect(Copy.restartFailed == "Restarting the agent failed.")
    #expect(model.banner != Copy.flash(for: "failed"))
}

@MainActor @Test func aRestartThatCannotRunShowsAPlainErrorAndClearsRestarting() async {
    let client = FakeDashboardClient()
    await client.setRestart(.failure(.timedOut))
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    #expect(await model.restartAgent() == false)
    #expect(model.banner == Copy.agentTimedOut)
    #expect(!model.restarting)
}

@MainActor @Test func windowAndPopoverShareOneModel() async {
    let gate = Gate()
    let agent = FakeClient(states: [.success(makeState())])
    await agent.setSend(.success(ActionResult(code: "sent")), gate: gate)
    let menu = MenuModel(client: agent)
    let window = WindowModel(client: FakeDashboardClient(), menu: menu)
    #expect(window.menu === menu)
    let fromPopover = Task { await menu.send(item(7, "pending")) }
    while !menu.busyIds.contains(7) { await Task.yield() }
    await window.menu.send(item(7, "pending"))
    #expect(await agent.sendCalls == [7])
    await gate.open()
    await fromPopover.value
    #expect(await agent.sendCalls == [7])
}

@Test func approvedByShowsTheNameWithTheUsername() {
    #expect(Copy.approvedBy("Ayu Lestari", username: "20435") == "First approved by Ayu Lestari (@20435)")
    #expect(Copy.approvedBy("20435", username: "20435") == "First approved by @20435")
}

@Test func durationFormatting() {
    #expect(Copy.duration(90) == "1 h 30 min")
    #expect(Copy.duration(24 * 60) == "1 d")
    #expect(Copy.duration(3 * 24 * 60 + 5 * 60 + 59) == "3 d 5 h")
}

@Test func minutesFormatting() {
    #expect(Copy.minutes(45) == "45 min")
    #expect(Copy.minutes(0) == "0 min")
    #expect(Copy.minutes(60) == "1 h")
    #expect(Copy.minutes(135) == "2 h 15 min")
}

@Test func theNewCopyIsExact() {
    #expect(Copy.lastPoll("5 min ago", ok: true) == "Last poll 5 min ago: ok")
    #expect(Copy.lastPoll("5 min ago", ok: false) == "Last poll 5 min ago: failed")
    #expect(Copy.flash(for: "restarted") == "Agent restarted.")
    #expect(Copy.flash(for: "not-installed") == Copy.agentNotInstalled)
    #expect(Copy.agentNotInstalled == "Agent not installed. Run suica agent install.")
    #expect(Copy.configSaveFailed == "Saving failed. The config file was not changed.")
}

@Test func tokenCountsAreShortenedFromTenThousand() {
    #expect(Copy.tokens(0) == "0")
    #expect(Copy.tokens(9_999) == "9,999")
    #expect(Copy.tokens(12_345) == "12.3K")
    #expect(Copy.tokens(1_234_567) == "1.2M")
}

@Test func knownPurposesHaveNamesAndOthersAreShownAsSent() {
    #expect(Copy.purpose("review") == "Agent reviews")
    #expect(Copy.purpose("approve") == "Approval checks")
    #expect(Copy.purpose("reply") == "Replies")
    #expect(Copy.purpose("lessons") == "Lessons")
    #expect(Copy.purpose("triage") == "triage")
}

@MainActor @Test func theReviewSettingsSaveTheirOneKeyAndAnEmptyModelRemovesIt() async {
    let client = FakeDashboardClient(configs: [.success(makeConfig(sha: "now"))])
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    await model.setReviewPosting("auto")
    await model.setReviewModel("opus")
    await model.setReviewModel(nil)
    await model.setReviewEffort("high")
    let saves = await client.saveCalls
    #expect(saves.map(\.edits) == [
        [ConfigEditRequest(path: ["review", "post"], value: .string("auto"))],
        [ConfigEditRequest(path: ["review", "model"], value: .string("opus"))],
        [ConfigEditRequest(path: ["review", "model"], value: .null)],
        [ConfigEditRequest(path: ["review", "effort"], value: .string("high"))],
    ])
    #expect(saves.allSatisfy { $0.base == "now" })
    #expect(model.banner == Copy.reviewSettingSaved)
}
