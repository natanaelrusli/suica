import Foundation
import Testing

@testable import SuicaCore

actor FakeDashboardClient: DashboardClient {
    private var statuses: [Result<StatusDocument, AgentError>]
    private var statsResults: [Result<StatsDocument, AgentError>]
    private var configs: [Result<ConfigDocument, AgentError>]
    private var saveResult: Result<SaveResult, AgentError> = .success(
        SaveResult(status: "saved", issues: [], sha256: "new"))
    private var restartResult: Result<ActionResult, AgentError> = .success(ActionResult(code: "restarted"))
    private var restartGate: Gate?
    private var saveGate: Gate?
    private var firstStatusGate: Gate?
    private(set) var statusCalls = 0
    private(set) var statsCalls = 0
    private(set) var configCalls = 0
    private(set) var restartCalls = 0
    private(set) var saveCalls: [(base: String?, edits: [ConfigEditRequest])] = []

    init(
        statuses: [Result<StatusDocument, AgentError>] = [.success(makeStatus())],
        stats: [Result<StatsDocument, AgentError>] = [.success(makeStats())],
        configs: [Result<ConfigDocument, AgentError>] = [.success(makeConfig())]
    ) {
        self.statuses = statuses
        self.statsResults = stats
        self.configs = configs
    }

    func setStatuses(_ next: [Result<StatusDocument, AgentError>]) { statuses = next }
    func setStats(_ next: [Result<StatsDocument, AgentError>]) { statsResults = next }
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
    await first.value
    #expect(!model.restarting)
    #expect(await client.restartCalls == 1)
}

@MainActor @Test func restartShowsTheResultAndRefreshes() async {
    let client = FakeDashboardClient()
    await client.setRestart(.success(ActionResult(code: "not-installed")))
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    await model.restartAgent()
    #expect(model.banner == Copy.agentNotInstalled)
    #expect(await client.statusCalls == 1)
    #expect(await client.statsCalls == 1)
    await client.setRestart(.success(ActionResult(code: "restarted")))
    await model.restartAgent()
    #expect(model.banner == "Agent restarted.")
    #expect(await client.statusCalls == 2)
}

@MainActor @Test func aFailedRestartSaysRestartingFailedNotSendingFailed() async {
    let client = FakeDashboardClient()
    await client.setRestart(.success(ActionResult(code: "failed")))
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    await model.restartAgent()
    #expect(model.banner == Copy.restartFailed)
    #expect(Copy.restartFailed == "Restarting the agent failed.")
    #expect(model.banner != Copy.flash(for: "failed"))
}

@MainActor @Test func aRestartThatCannotRunShowsAPlainErrorAndClearsRestarting() async {
    let client = FakeDashboardClient()
    await client.setRestart(.failure(.timedOut))
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    await model.restartAgent()
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

@Test func minutesFormatting() {
    #expect(Copy.minutes(45) == "45 min")
    #expect(Copy.minutes(0) == "0 min")
    #expect(Copy.minutes(60) == "1 h 0 min")
    #expect(Copy.minutes(135) == "2 h 15 min")
}

@Test func theNewCopyIsExact() {
    #expect(Copy.lastPoll("5 min ago", ok: true) == "Last poll 5 min ago: ok")
    #expect(Copy.lastPoll("5 min ago", ok: false) == "Last poll 5 min ago: failed")
    #expect(Copy.flash(for: "restarted") == "Agent restarted.")
    #expect(Copy.flash(for: "not-installed") == Copy.agentNotInstalled)
    #expect(Copy.agentNotInstalled == "Agent not installed. Run scripts/install-launchagent.sh.")
    #expect(Copy.configSaveFailed == "Saving failed. The config file was not changed.")
}
