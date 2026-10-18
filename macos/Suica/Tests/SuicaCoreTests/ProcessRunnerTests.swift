import Foundation
import Testing

@testable import SuicaCore

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

@Test func runnerPassesStdinToTheChild() async throws {
    let result = try await ProcessRunner().run(
        Invocation(
            executable: "/bin/cat", arguments: [], environment: [:], workingDirectory: "/tmp", timeout: 10,
            stdin: Data("hello".utf8)))
    #expect(result.exitCode == 0)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "hello")
}

@Test func runnerWithoutStdinGivesTheChildAnEmptyInput() async throws {
    let result = try await ProcessRunner().run(
        Invocation(
            executable: "/bin/cat", arguments: [], environment: [:], workingDirectory: "/tmp", timeout: 10))
    #expect(result.exitCode == 0 && result.stdout.isEmpty)
}

@Test func runnerPassesLargeStdinThroughWithoutDeadlock() async throws {
    let big = Data(repeating: 0x61, count: 2 * 1024 * 1024)
    let result = try await ProcessRunner().run(
        Invocation(
            executable: "/bin/cat", arguments: [], environment: [:], workingDirectory: "/tmp", timeout: 20,
            stdin: big))
    #expect(result.stdout.count == big.count)
}

@Test func runnerSurvivesAChildThatClosesStdinEarly() async throws {
    // Larger than the pipe buffer, so the write meets a closed pipe; this must not raise SIGPIPE.
    let big = Data(repeating: 0x61, count: 3 * 1024 * 1024)
    let result = try await ProcessRunner().run(
        Invocation(
            executable: "/bin/sh", arguments: ["-c", "exit 1"], environment: [:], workingDirectory: "/tmp",
            timeout: 10, stdin: big))
    #expect(result.exitCode == 1)
}

/// The installed `suica` command is a `#!/bin/sh` wrapper that execs node: the runner must start it
/// directly and pass the arguments through.
@Test func runsAShellWrapperLikeTheInstalledCli() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "suica-wrapper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let wrapper = folder.appending(path: "suica")
    try Data("#!/bin/sh\nexec /bin/echo \"$@\"\n".utf8).write(to: wrapper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    let result = try await ProcessRunner().run(
        Invocation(
            executable: wrapper.path, arguments: ["state", "a b"], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/tmp", timeout: 10))
    #expect(result.exitCode == 0)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "state a b\n")
}
