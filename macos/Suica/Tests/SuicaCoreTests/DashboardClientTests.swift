import Foundation
import Testing

@testable import SuicaCore

private func output(_ text: String, exit: Int32 = 0) -> Result<CommandResult, AgentError> {
    .success(CommandResult(exitCode: exit, stdout: Data(text.utf8), stderr: Data()))
}

private let config = AgentConfig(
    nodePath: "/opt/homebrew/bin/node", repoPath: "/Users/me/suica",
    searchPath: "/opt/homebrew/bin:/usr/bin")

private let statusJSON =
    #"{"version":1,"agent":{"label":"l","loaded":true,"running":false,"pid":null},"configError":null,"paused":false,"teamsEnabled":false,"lastPoll":null,"polling":{"activeSeconds":1,"idleSeconds":2},"paths":{"config":"c","state":"s","logs":"l","templates":"t"}}"#
private let statsJSON =
    #"{"version":1,"generatedAt":5,"lastPoll":null,"polls24h":{"ok":0,"failed":0},"polls7d":{"ok":0,"failed":0},"days":[],"ownerAfterRequest":{"count":0,"medianMinutes":null,"p90Minutes":null},"reviewerAfterNudge":{"count":0,"medianMinutes":null,"p90Minutes":null}}"#
private let configJSON =
    #"{"version":1,"path":"/p","exists":false,"sha256":null,"issues":[],"fields":[]}"#

private func client(_ script: [Result<CommandResult, AgentError>]) -> (CLIAgentClient, FakeRunner) {
    let runner = FakeRunner(script)
    return (CLIAgentClient(config: config, runner: runner), runner)
}

private struct SentRequest: Decodable {
    struct Edit: Decodable {
        let path: [String]
        let value: JSONValue
    }
    let baseSha256: String?
    let edits: [Edit]
}

private let edits = [
    ConfigEditRequest(path: ["polling", "activeSeconds"], value: .int(90)),
    ConfigEditRequest(path: ["teams", "command"], value: .null),
]

@Test func statusStatsAndConfigUseTheirCommands() async throws {
    let (client, runner) = client([output(statusJSON), output(statsJSON), output(configJSON)])
    #expect(try await client.status().paths.state == "s")
    #expect(try await client.stats().generatedAt == 5)
    #expect(try await client.config().exists == false)
    let calls = await runner.invocations
    #expect(calls.map { Array($0.arguments.dropFirst()) } == [["status", "--json"], ["stats"], ["config", "show", "--json"]])
    #expect(calls.allSatisfy { $0.timeout == 20 && $0.stdin == nil })
    #expect(calls.allSatisfy { $0.arguments[0] == "/Users/me/suica/src/cli.ts" })
    #expect(calls.allSatisfy { $0.environment["SUICA_ENV"] == "production" })
}

@Test func documentsIgnoreLogLinesBeforeThem() async throws {
    let noisy = #"{"level":"info","message":"x"}"# + "\n" + statsJSON + "\n"
    let (client, _) = client([output(noisy)])
    #expect(try await client.stats().generatedAt == 5)
}

@Test func documentsFailOnNonZeroExitEmptyOutputGarbageAndNewerVersions() async {
    await #expect(throws: AgentError.failed(exitCode: 2)) {
        try await client([output(statusJSON, exit: 2)]).0.status()
    }
    await #expect(throws: AgentError.badOutput) { try await client([output("")]).0.stats() }
    await #expect(throws: AgentError.badOutput) { try await client([output("nope")]).0.config() }
    await #expect(throws: AgentError.unsupportedVersion(2)) {
        try await client([output(#"{"version":2}"#)]).0.status()
    }
    await #expect(throws: AgentError.timedOut) { try await client([.failure(.timedOut)]).0.config() }
}

@Test func saveConfigSendsTheRequestOnStdin() async throws {
    let (client, runner) = client([output(#"{"status":"saved","issues":[],"sha256":"abc"}"#)])
    let base = String(repeating: "a", count: 64)
    let result = try await client.saveConfig(base: base, edits: edits)
    #expect(result.status == "saved" && result.sha256 == "abc" && result.issues.isEmpty)
    let call = try #require(await runner.invocations.first)
    #expect(Array(call.arguments.dropFirst()) == ["config", "set", "--json"])
    #expect(call.timeout == 20)
    let sent = try JSONDecoder().decode(SentRequest.self, from: try #require(call.stdin))
    #expect(sent.baseSha256 == base)
    #expect(sent.edits.map(\.path) == [["polling", "activeSeconds"], ["teams", "command"]])
    #expect(sent.edits.map(\.value) == [.int(90), .null])
}

@Test func saveConfigWithoutABaseSendsNull() async throws {
    let (client, runner) = client([output(#"{"status":"saved","issues":[],"sha256":"abc"}"#)])
    _ = try await client.saveConfig(base: nil, edits: [])
    let stdin = try #require(await runner.invocations.first?.stdin)
    let text = String(decoding: stdin, as: UTF8.self)
    #expect(text.contains(#""baseSha256":null"#) && text.contains(#""edits":[]"#))
}

@Test func saveConfigReadsAnInvalidResultOnExitOne() async throws {
    let json = #"{"status":"invalid","issues":[{"path":"teams.templatesPath","message":"missing"}],"sha256":null}"#
    let result = try await client([output(json, exit: 1)]).0.saveConfig(base: nil, edits: edits)
    #expect(result.status == "invalid" && result.sha256 == nil)
    #expect(result.issues == [ConfigIssue(path: "teams.templatesPath", message: "missing")])
}

@Test func saveConfigKeepsUnknownStatusCodes() async throws {
    let result = try await client([output(#"{"status":"teleported","issues":[],"sha256":null}"#, exit: 1)]).0
        .saveConfig(base: nil, edits: edits)
    #expect(result.status == "teleported")
}

@Test func saveConfigWithEmptyOutputOnExitOneIsAFailure() async {
    await #expect(throws: AgentError.failed(exitCode: 1)) {
        try await client([output("", exit: 1)]).0.saveConfig(base: nil, edits: edits)
    }
}

@Test func saveConfigWithGarbageOnExitZeroIsBadOutput() async {
    await #expect(throws: AgentError.badOutput) {
        try await client([output("saved")]).0.saveConfig(base: nil, edits: edits)
    }
}

@Test func saveConfigIgnoresLogLinesBeforeTheResult() async throws {
    let noisy = #"{"level":"info","message":"x"}"# + "\n" + #"{"status":"conflict","issues":[],"sha256":null}"# + "\n"
    #expect(try await client([output(noisy, exit: 1)]).0.saveConfig(base: nil, edits: edits).status == "conflict")
}

@Test func restartUsesItsCommandAndALongerTimeout() async throws {
    let (client, runner) = client([
        output(#"{"status":"restarted"}"#), output(#"{"status":"not-installed"}"#, exit: 1),
    ])
    #expect(try await client.restartAgent() == ActionResult(code: "restarted"))
    #expect(try await client.restartAgent().code == "not-installed")
    let calls = await runner.invocations
    #expect(calls.map { Array($0.arguments.dropFirst()) } == [["agent", "restart", "--json"], ["agent", "restart", "--json"]])
    #expect(calls.allSatisfy { $0.timeout == 30 && $0.stdin == nil })
}

@Test func restartWithoutJsonOnFailureIsAFailure() async {
    await #expect(throws: AgentError.failed(exitCode: 1)) {
        try await client([output("", exit: 1)]).0.restartAgent()
    }
}
