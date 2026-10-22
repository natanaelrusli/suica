import Foundation
import Testing

@testable import SuicaCore

actor FakeSetupClient: SetupClient {
    private var checkResult: Result<GitlabCheck, AgentError> = .success(GitlabCheck(status: "ok", username: "owner"))
    private var installResults: [Result<ActionResult, AgentError>] = [.success(ActionResult(code: "installed"))]
    private(set) var checkedHosts: [String] = []
    private(set) var installCalls = 0

    func setCheck(_ result: Result<GitlabCheck, AgentError>) { checkResult = result }
    func setInstalls(_ next: [Result<ActionResult, AgentError>]) { installResults = next }

    func checkGitlab(host: String) async throws(AgentError) -> GitlabCheck {
        checkedHosts.append(host)
        return try checkResult.get()
    }

    func installAgent() async throws(AgentError) -> ActionResult {
        installCalls += 1
        let result = installResults.count > 1 ? installResults.removeFirst() : installResults[0]
        return try result.get()
    }
}

@MainActor private func makeModel(
    configs: [Result<ConfigDocument, AgentError>] = [.success(makeConfig(sha: nil))]
) -> (OnboardingModel, FakeDashboardClient, FakeSetupClient) {
    let dashboard = FakeDashboardClient(configs: configs)
    let setup = FakeSetupClient()
    return (OnboardingModel(dashboard: dashboard, setup: setup), dashboard, setup)
}

@Test func decodesTheGitlabCheckGolden() throws {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    let data = try Data(contentsOf: url.appending(path: "contracts/gitlab-check.v1.json"))
    #expect(try JSONDecoder().decode(GitlabCheck.self, from: data) == GitlabCheck(status: "ok", username: "owner"))
}

@MainActor @Test func opensOnlyWhenThereIsNoConfigFile() async {
    let (missing, _, _) = makeModel()
    await missing.showIfNeeded()
    #expect(missing.presented)

    let (present, _, _) = makeModel(configs: [.success(makeConfig(sha: "abc"))])
    await present.showIfNeeded()
    #expect(!present.presented)

    // An agent that cannot be reached says nothing about a first run.
    let (unreachable, _, _) = makeModel(configs: [.failure(.launchFailed)])
    await unreachable.showIfNeeded()
    #expect(!unreachable.presented)
}

@MainActor @Test func theGitlabStepNeedsAHost() {
    let (model, _, _) = makeModel()
    model.next()
    #expect(model.step == .gitlab && !model.canContinue)
    model.next()
    #expect(model.step == .gitlab)
    model.hostText = "https://repo.example/group/project"
    #expect(model.host == "repo.example" && model.canContinue)
    model.next()
    #expect(model.step == .codingAgent)
    model.back()
    #expect(model.step == .gitlab)
}

@MainActor @Test func checksTheTypedHostAndForgetsTheAnswerWhenItChanges() async {
    let (model, _, setup) = makeModel()
    model.hostText = "https://repo.example/x"
    await model.checkConnection()
    #expect(await setup.checkedHosts == ["repo.example"])
    #expect(model.check == GitlabCheck(status: "ok", username: "owner"))
    model.hostText = "repo.example/other"
    #expect(model.check != nil)
    model.hostText = "other.example"
    #expect(model.check == nil)

    await setup.setCheck(.failure(.timedOut))
    await model.checkConnection()
    #expect(model.check == nil && model.checkError != nil)
}

@MainActor @Test func writesOnlyWhatDiffersFromTheDefaultsThenStartsTheAgent() async throws {
    let (model, dashboard, setup) = makeModel()
    model.hostText = "repo.example"
    await model.finish()
    let first = try #require(await dashboard.saveCalls.first)
    #expect(first.base == nil)
    #expect(first.edits == [ConfigEditRequest(path: ["gitlab", "hostname"], value: .string("repo.example"))])
    #expect(await setup.installCalls == 1)
    #expect(model.finished && model.failure == nil)

    let (custom, customDashboard, _) = makeModel()
    custom.hostText = "repo.example"
    custom.modelCli = "codex"
    custom.teamsEnabled = true
    await custom.finish()
    #expect(await customDashboard.saveCalls.first?.edits == [
        ConfigEditRequest(path: ["gitlab", "hostname"], value: .string("repo.example")),
        ConfigEditRequest(path: ["model", "cli"], value: .string("codex")),
        ConfigEditRequest(path: ["teams", "enabled"], value: .bool(true)),
    ])
}

@MainActor @Test func aRefusedSaveStartsNothing() async {
    let (model, dashboard, setup) = makeModel()
    model.hostText = "repo.example"
    await dashboard.setSave(.success(SaveResult(status: "conflict", issues: [], sha256: nil)))
    await model.finish()
    #expect(await setup.installCalls == 0)
    #expect(!model.finished && model.failure == Copy.setupNotSaved(status: "conflict", issues: []))
}

@MainActor @Test func aRetryAfterAFailedInstallDoesNotWriteTheFileAgain() async {
    let (model, dashboard, setup) = makeModel()
    model.hostText = "repo.example"
    await setup.setInstalls([.success(ActionResult(code: "failed")), .success(ActionResult(code: "installed"))])
    await model.finish()
    #expect(model.failure == Copy.setupAgentNotStarted && !model.finished)
    await model.finish()
    #expect(await dashboard.saveCalls.count == 1)
    #expect(await setup.installCalls == 2)
    #expect(model.finished && model.failure == nil)
}

@MainActor @Test func theCardsShowWhatTheChoiceWouldRunWithoutAConfig() async {
    var status = makeStatus()
    status.modelCli = ModelCliStatus(selected: nil, active: nil, clis: [
        DetectedModelCli(id: "claude", name: "Claude Code", path: nil),
        DetectedModelCli(id: "codex", name: "Codex", path: "/bin/codex"),
        DetectedModelCli(id: "gemini", name: "Gemini CLI", path: "/bin/gemini"),
    ])
    let dashboard = FakeDashboardClient(statuses: [.success(status)], configs: [.success(makeConfig(sha: nil))])
    let model = OnboardingModel(dashboard: dashboard, setup: FakeSetupClient())
    #expect(model.modelClis == nil)
    await model.showIfNeeded()
    #expect(model.modelClis?.active == "codex")
    model.modelCli = "gemini"
    #expect(model.modelClis?.active == "gemini")
    model.modelCli = "claude"
    #expect(model.modelClis?.active == nil)
}
