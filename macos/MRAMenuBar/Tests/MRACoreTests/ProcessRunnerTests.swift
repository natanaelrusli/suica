import Foundation
import Testing

@testable import MRACore

private func shell(_ script: String, timeout: TimeInterval = 10, directory: String = "/tmp") -> Invocation {
    Invocation(
        executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin", "FOO": "bar"],
        workingDirectory: directory, timeout: timeout)
}

@Test func capturesStdoutStderrAndExitCode() async throws {
    let result = try await ProcessRunner().run(shell("echo out; echo err >&2; exit 3"))
    #expect(result.exitCode == 3)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
    #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
}

@Test func killsAHungChildAtTheTimeout() async {
    let started = Date()
    await #expect(throws: AgentError.timedOut) {
        try await ProcessRunner().run(
            Invocation(
                executable: "/bin/sleep", arguments: ["30"], environment: [:], workingDirectory: "/tmp",
                timeout: 0.5))
    }
    #expect(Date().timeIntervalSince(started) < 3)
}

@Test func reportsALaunchFailureForAMissingExecutable() async {
    await #expect(throws: AgentError.launchFailed) {
        try await ProcessRunner().run(
            Invocation(
                executable: "/nonexistent/node", arguments: [], environment: [:], workingDirectory: "/tmp",
                timeout: 5))
    }
}

@Test func reportsALaunchFailureForAMissingWorkingDirectory() async {
    await #expect(throws: AgentError.launchFailed) {
        try await ProcessRunner().run(shell("true", directory: "/nonexistent/dir"))
    }
}

@Test func doesNotDeadlockOnLargeOutput() async throws {
    let result = try await ProcessRunner().run(shell("head -c 3000000 /dev/zero"))
    #expect(result.exitCode == 0)
    #expect(result.stdout.count == 3_000_000)
}

@Test func capsCapturedOutputAtFourMebibytes() async throws {
    let result = try await ProcessRunner().run(shell("head -c 6000000 /dev/zero"))
    #expect(result.exitCode == 0)
    #expect(result.stdout.count == 4 * 1024 * 1024)
}

@Test func passesTheEnvironmentAndWorkingDirectory() async throws {
    let result = try await ProcessRunner().run(shell(#"echo "$FOO"; pwd -P"#))
    let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    #expect(lines[0] == "bar")
    #expect(lines[1] == "/private/tmp")
}

@Test func doesNotInheritTheCallersEnvironment() async throws {
    let result = try await ProcessRunner().run(shell(#"echo "${USER:-unset}""#))
    #expect(String(decoding: result.stdout, as: UTF8.self) == "unset\n")
}

@Test func doesNotHangWhenAGrandchildKeepsThePipeOpen() async throws {
    let started = Date()
    let result = try await ProcessRunner().run(shell("echo done; (sleep 8 &) ; exit 0"))
    #expect(String(decoding: result.stdout, as: UTF8.self) == "done\n")
    #expect(Date().timeIntervalSince(started) < 5)
}
