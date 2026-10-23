import Foundation
import Testing

@testable import SuicaCore

actor FakeRunner: CommandRunning {
    private(set) var invocations: [Invocation] = []
    private var script: [Result<CommandResult, AgentError>]

    init(_ script: [Result<CommandResult, AgentError>]) { self.script = script }

    func run(_ invocation: Invocation) async throws(AgentError) -> CommandResult {
        invocations.append(invocation)
        guard !script.isEmpty else { throw AgentError.launchFailed }
        return try script.removeFirst().get()
    }
}

private func output(_ text: String, exit: Int32 = 0) -> Result<CommandResult, AgentError> {
    .success(CommandResult(exitCode: exit, stdout: Data(text.utf8), stderr: Data()))
}

private let config = AgentConfig(
    cliPath: "/Users/me/.local/bin/suica", searchPath: "/opt/homebrew/bin:/usr/bin")

private let stateJSON =
    #"{"version":1,"paused":false,"baselineDone":true,"trackedAuthored":1,"reviewRequested":2,"teams":null}"#

@Test func stateRunsTheCliWithTheExactEnvironment() async throws {
    let runner = FakeRunner([output(stateJSON)])
    let state = try await CLIAgentClient(config: config, runner: runner).state()
    #expect(state.reviewRequested == 2)
    let call = try #require(await runner.invocations.first)
    #expect(call.executable == "/Users/me/.local/bin/suica")
    #expect(call.arguments == ["state"])
    #expect(call.workingDirectory == call.environment["HOME"])
    #expect(call.environment["PATH"] == "/opt/homebrew/bin:/usr/bin")
    #expect(call.environment["SUICA_ENV"] == "production")
    #expect(call.environment["HOME"]?.isEmpty == false)
    #expect(call.timeout == 20)
}

@Test func aCliPathWithSpacesIsTheExecutableAsIs() async throws {
    let spaced = AgentConfig(cliPath: "/Users/a b/.local/bin/suica", searchPath: "/usr/bin")
    let runner = FakeRunner([output(stateJSON)])
    _ = try await CLIAgentClient(config: spaced, runner: runner).state()
    let call = try #require(await runner.invocations.first)
    #expect(call.executable == "/Users/a b/.local/bin/suica")
    #expect(call.arguments == ["state"])
}

@Test func stateIgnoresLogLinesBeforeTheDocument() async throws {
    let noisy = #"{"level":"info","message":"hello"}"# + "\n" + stateJSON + "\n"
    let state = try await CLIAgentClient(config: config, runner: FakeRunner([output(noisy)])).state()
    #expect(state.trackedAuthored == 1)
}

@Test func unicodeLineSeparatorsInsideTextDoNotBreakTheDocument() async throws {
    // Node's JSON.stringify leaves U+2028, U+2029 and U+0085 unescaped; only "\n" ends a line.
    let tricky = "{\"version\":1,\"paused\":false,\"baselineDone\":true,\"trackedAuthored\":1,\"reviewRequested\":2,"
        + "\"teams\":{\"counts\":{},\"attentionHidden\":0,\"recent\":[],\"attention\":[{\"id\":1,\"kind\":\"nudge\","
        + "\"status\":\"pending\",\"detail\":\"\",\"recipientName\":\"Bob\",\"mrKey\":\"g/p!5\","
        + "\"mrTitle\":\"Refactor\u{2028}parser\u{2029}and\u{0085}more\",\"mrUrl\":\"https://x\",\"text\":null,"
        + "\"createdAt\":1,\"updatedAt\":2}]}}\n"
    let client = CLIAgentClient(config: config, runner: FakeRunner([output(tricky)]))
    let state = try await client.state()
    #expect(state.teams?.attention.first?.mrTitle == "Refactor\u{2028}parser\u{2029}and\u{0085}more")
}

@Test func sendUsesTheJsonFlagAndALongTimeout() async throws {
    let runner = FakeRunner([output(#"{"status":"sent"}"#)])
    let result = try await CLIAgentClient(config: config, runner: runner).send(id: 7)
    #expect(result == ActionResult(code: "sent"))
    let call = try #require(await runner.invocations.first)
    #expect(call.arguments == ["send", "7", "--json"])
    #expect(call.timeout == 300)
}

@Test func aNonZeroExitWithAStatusIsAnOutcomeNotAnError() async throws {
    let runner = FakeRunner([output(#"{"status":"busy"}"#, exit: 1)])
    let result = try await CLIAgentClient(config: config, runner: runner).send(id: 7)
    #expect(result.code == "busy")
}

@Test func sendIgnoresLogLinesBeforeTheStatus() async throws {
    let noisy = #"{"level":"info","message":"x"}"# + "\n" + #"{"status":"sent"}"# + "\n"
    let result = try await CLIAgentClient(config: config, runner: FakeRunner([output(noisy)])).send(id: 1)
    #expect(result.code == "sent")
}

@Test func skipAndRetryReturnTheirCodes() async throws {
    let runner = FakeRunner([output(#"{"status":"skipped"}"#), output(#"{"status":"nothing"}"#, exit: 1)])
    let client = CLIAgentClient(config: config, runner: runner)
    #expect(try await client.skip(id: 3).code == "skipped")
    #expect(try await client.retry(id: 4).code == "nothing")
    let calls = await runner.invocations.map { $0.arguments }
    #expect(calls == [["skip", "3", "--json"], ["retry", "4", "--json"]])
    #expect(await runner.invocations.allSatisfy { $0.timeout == 20 })
}

@Test func clearPassesTheIdOrTheGroup() async throws {
    let runner = FakeRunner([
        output(#"{"status":"cleared"}"#), output(#"{"status":"cleared"}"#), output(#"{"status":"nothing"}"#),
        output(#"{"status":"cleared"}"#),
    ])
    let client = CLIAgentClient(config: config, runner: runner)
    #expect(try await client.clear(id: 7).code == "cleared")
    _ = try await client.clearRecent(.yours)
    #expect(try await client.clearRecent(.others).code == "nothing")
    _ = try await client.clearRecent(nil)
    let calls = await runner.invocations.map { $0.arguments }
    #expect(
        calls == [
            ["clear", "7", "--json"], ["clear", "yours", "--json"], ["clear", "others", "--json"],
            ["clear", "all", "--json"],
        ])
}

@Test func aNonZeroExitWithoutJsonFails() async {
    let client = CLIAgentClient(config: config, runner: FakeRunner([output("", exit: 3)]))
    await #expect(throws: AgentError.failed(exitCode: 3)) { try await client.send(id: 1) }
}

@Test(arguments: ["garbage", "", #"{"nope":1}"#, #"{"status":5}"#])
func exitZeroWithGarbageIsBadOutput(text: String) async {
    let client = CLIAgentClient(config: config, runner: FakeRunner([output(text)]))
    await #expect(throws: AgentError.badOutput) { try await client.skip(id: 1) }
}

@Test func stateFailsOnNonZeroExit() async {
    let client = CLIAgentClient(config: config, runner: FakeRunner([output(stateJSON, exit: 2)]))
    await #expect(throws: AgentError.failed(exitCode: 2)) { try await client.state() }
}

@Test func stateRejectsGarbageAndNewerVersions() async {
    let garbage = CLIAgentClient(config: config, runner: FakeRunner([output("nope")]))
    await #expect(throws: AgentError.badOutput) { try await garbage.state() }
    let newer = CLIAgentClient(config: config, runner: FakeRunner([output(#"{"version":2}"#)]))
    await #expect(throws: AgentError.unsupportedVersion(2)) { try await newer.state() }
}

@Test func runnerErrorsPassThrough() async {
    let client = CLIAgentClient(config: config, runner: FakeRunner([.failure(.timedOut)]))
    await #expect(throws: AgentError.timedOut) { try await client.state() }
}

@Test func pauseAndResumeUseTheirCommands() async throws {
    let runner = FakeRunner([output("paused\n"), output("resumed\n"), output("", exit: 1)])
    let client = CLIAgentClient(config: config, runner: runner)
    try await client.setPaused(true)
    try await client.setPaused(false)
    let calls = await runner.invocations.map { $0.arguments }
    #expect(calls == [["pause"], ["resume"]])
    await #expect(throws: AgentError.failed(exitCode: 1)) { try await client.setPaused(true) }
}

@Test func configFromTheBundleNeedsBothKeys() {
    let full: [String: Any] = ["SuicaCLIPath": "/c", "SuicaSearchPath": "/p"]
    #expect(AgentConfig(infoDictionary: full) == AgentConfig(cliPath: "/c", searchPath: "/p"))
    for key in full.keys {
        var missing = full
        missing[key] = nil
        #expect(AgentConfig(infoDictionary: missing) == nil, "\(key)")
        var empty = full
        empty[key] = ""
        #expect(AgentConfig(infoDictionary: empty) == nil, "\(key)")
    }
    #expect(AgentConfig(infoDictionary: nil) == nil)
}
