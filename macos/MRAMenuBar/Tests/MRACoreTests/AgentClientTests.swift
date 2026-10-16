import Foundation
import Testing

@testable import MRACore

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
    nodePath: "/opt/homebrew/bin/node", repoPath: "/Users/me/suica",
    searchPath: "/opt/homebrew/bin:/usr/bin")

private let stateJSON =
    #"{"version":1,"paused":false,"baselineDone":true,"trackedAuthored":1,"reviewRequested":2,"teams":null}"#

@Test func stateRunsTheCliWithTheExactEnvironment() async throws {
    let runner = FakeRunner([output(stateJSON)])
    let state = try await CLIAgentClient(config: config, runner: runner).state()
    #expect(state.reviewRequested == 2)
    let call = try #require(await runner.invocations.first)
    #expect(call.executable == "/opt/homebrew/bin/node")
    #expect(call.arguments == ["/Users/me/suica/src/cli.ts", "state"])
    #expect(call.workingDirectory == "/Users/me/suica")
    #expect(call.environment["PATH"] == "/opt/homebrew/bin:/usr/bin")
    #expect(call.environment["MRA_ENV"] == "production")
    #expect(call.environment["HOME"]?.isEmpty == false)
    #expect(call.timeout == 20)
}

@Test func pathsWithSpacesAreOneArgument() async throws {
    let spaced = AgentConfig(nodePath: "/n", repoPath: "/Users/a b/My Repo", searchPath: "/usr/bin")
    let runner = FakeRunner([output(stateJSON)])
    _ = try await CLIAgentClient(config: spaced, runner: runner).state()
    let call = try #require(await runner.invocations.first)
    #expect(call.arguments[0] == "/Users/a b/My Repo/src/cli.ts")
    #expect(call.workingDirectory == "/Users/a b/My Repo")
}

@Test func stateIgnoresLogLinesBeforeTheDocument() async throws {
    let noisy = #"{"level":"info","message":"hello"}"# + "\n" + stateJSON + "\n"
    let state = try await CLIAgentClient(config: config, runner: FakeRunner([output(noisy)])).state()
    #expect(state.trackedAuthored == 1)
}

@Test func sendUsesTheJsonFlagAndALongTimeout() async throws {
    let runner = FakeRunner([output(#"{"status":"sent"}"#)])
    let result = try await CLIAgentClient(config: config, runner: runner).send(id: 7)
    #expect(result == ActionResult(code: "sent"))
    let call = try #require(await runner.invocations.first)
    #expect(Array(call.arguments.dropFirst()) == ["send", "7", "--json"])
    #expect(call.timeout == 150)
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
    let calls = await runner.invocations.map { Array($0.arguments.dropFirst()) }
    #expect(calls == [["skip", "3", "--json"], ["retry", "4", "--json"]])
    #expect(await runner.invocations.allSatisfy { $0.timeout == 20 })
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
    let calls = await runner.invocations.map { Array($0.arguments.dropFirst()) }
    #expect(calls == [["pause"], ["resume"]])
    await #expect(throws: AgentError.failed(exitCode: 1)) { try await client.setPaused(true) }
}

@Test func configFromTheBundleNeedsAllThreeKeys() {
    let full: [String: Any] = ["MRANodePath": "/n", "MRARepoPath": "/r", "MRASearchPath": "/p"]
    #expect(AgentConfig(infoDictionary: full) == AgentConfig(nodePath: "/n", repoPath: "/r", searchPath: "/p"))
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
