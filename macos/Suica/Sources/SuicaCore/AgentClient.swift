import Foundation

public struct Invocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
    public let timeout: TimeInterval

    public init(
        executable: String, arguments: [String], environment: [String: String],
        workingDirectory: String, timeout: TimeInterval
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }
}

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(_ invocation: Invocation) async throws(AgentError) -> CommandResult
}

// MARK: - Process runner

/// Collects one pipe without ever blocking the child: output past `limit` is drained and dropped.
private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    private let group: DispatchGroup

    init(limit: Int, group: DispatchGroup) {
        self.limit = limit
        self.group = group
    }

    func attach(to handle: FileHandle) {
        group.enter()
        handle.readabilityHandler = { [self] file in
            let chunk = file.availableData
            if chunk.isEmpty {
                file.readabilityHandler = nil
                group.leave()
                return
            }
            lock.lock()
            if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
            lock.unlock()
        }
    }

    var bytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOutFlag = false
    let process: Process

    init(process: Process) { self.process = process }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOutFlag
    }

    func markTimedOut() {
        lock.lock()
        timedOutFlag = true
        lock.unlock()
    }
}

public struct ProcessRunner: CommandRunning {
    private static let outputLimit = 4 * 1024 * 1024
    private static let killGrace: TimeInterval = 2
    private static let drainGrace: TimeInterval = 2

    public init() {}

    public func run(_ invocation: Invocation) async throws(AgentError) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = URL(fileURLWithPath: invocation.workingDirectory)
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let group = DispatchGroup()
        let out = Capture(limit: Self.outputLimit, group: group)
        let err = Capture(limit: Self.outputLimit, group: group)
        out.attach(to: outPipe.fileHandleForReading)
        err.attach(to: errPipe.fileHandleForReading)

        let state = RunState(process: process)
        let timeout = invocation.timeout
        let status: Int32? = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard state.process.isRunning else { return }
                state.markTimedOut()
                state.process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) {
                    if state.process.isRunning { kill(state.process.processIdentifier, SIGKILL) }
                }
            }
        }

        guard let status else {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw AgentError.launchFailed
        }
        // A grandchild that inherited the pipe can keep it open: wait a little, then take what we have.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = group.wait(timeout: .now() + Self.drainGrace)
                continuation.resume()
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if state.timedOut { throw AgentError.timedOut }
        return CommandResult(exitCode: status, stdout: out.bytes, stderr: err.bytes)
    }
}

// MARK: - Agent client

public struct AgentConfig: Equatable, Sendable {
    public let nodePath: String
    public let repoPath: String
    public let searchPath: String

    public init(nodePath: String, repoPath: String, searchPath: String) {
        self.nodePath = nodePath
        self.repoPath = repoPath
        self.searchPath = searchPath
    }

    /// The `Info.plist` keys the install script writes. Nil when any of them is missing or empty.
    public init?(infoDictionary: [String: Any]?) {
        func value(_ key: String) -> String? {
            guard let text = infoDictionary?[key] as? String, !text.isEmpty else { return nil }
            return text
        }
        guard let node = value("SuicaNodePath"), let repo = value("SuicaRepoPath"),
            let search = value("SuicaSearchPath")
        else { return nil }
        self.init(nodePath: node, repoPath: repo, searchPath: search)
    }

    public static func fromBundle(_ bundle: Bundle) -> AgentConfig? {
        AgentConfig(infoDictionary: bundle.infoDictionary)
    }
}

public struct ActionResult: Equatable, Sendable {
    public let code: String

    public init(code: String) { self.code = code }
}

public protocol AgentClient: Sendable {
    func state() async throws(AgentError) -> AgentState
    func send(id: Int) async throws(AgentError) -> ActionResult
    func skip(id: Int) async throws(AgentError) -> ActionResult
    func retry(id: Int) async throws(AgentError) -> ActionResult
    func setPaused(_ paused: Bool) async throws(AgentError)
}

private struct StatusLine: Decodable {
    let status: String
}

/// The agent's own JSON logger also writes to stdout, so the answer is the last non-empty line.
/// Only "\n" ends a line: JSON.stringify leaves U+2028, U+2029 and U+0085 unescaped inside strings.
private func lastLine(of data: Data) -> Data? {
    let blanks: Set<UInt8> = [0x20, 0x09, 0x0D]
    return data.split(separator: 0x0A, omittingEmptySubsequences: true)
        .last { !$0.allSatisfy { blanks.contains($0) } }
        .map { Data($0) }
}

public struct CLIAgentClient: AgentClient {
    private static let shortTimeout: TimeInterval = 20
    // The CLI's own worst case with the default config: Teams start (30 s) plus three calls
    // (lookup, open chat, send; 60 s each) is 210 s. Killing it later than that keeps a row from
    // being stranded in `sending`; a larger teams.callTimeoutSeconds needs a larger value here.
    private static let sendTimeout: TimeInterval = 300

    private let config: AgentConfig
    private let runner: any CommandRunning

    public init(config: AgentConfig, runner: any CommandRunning) {
        self.config = config
        self.runner = runner
    }

    private func invocation(_ arguments: [String], timeout: TimeInterval) -> Invocation {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return Invocation(
            executable: config.nodePath,
            arguments: ["\(config.repoPath)/src/cli.ts"] + arguments,
            environment: ["PATH": config.searchPath, "HOME": home, "SUICA_ENV": "production"],
            workingDirectory: config.repoPath,
            timeout: timeout)
    }

    public func state() async throws(AgentError) -> AgentState {
        let result = try await runner.run(invocation(["state"], timeout: Self.shortTimeout))
        guard result.exitCode == 0 else { throw AgentError.failed(exitCode: result.exitCode) }
        guard let line = lastLine(of: result.stdout) else { throw AgentError.badOutput }
        return try decodeAgentState(line)
    }

    private func action(_ arguments: [String], timeout: TimeInterval) async throws(AgentError)
        -> ActionResult
    {
        let result = try await runner.run(invocation(arguments, timeout: timeout))
        // The CLI exits 1 when nothing happened, with the reason in the JSON: read that first.
        if let line = lastLine(of: result.stdout),
            let parsed = try? JSONDecoder().decode(StatusLine.self, from: line)
        {
            return ActionResult(code: parsed.status)
        }
        guard result.exitCode == 0 else { throw AgentError.failed(exitCode: result.exitCode) }
        throw AgentError.badOutput
    }

    public func send(id: Int) async throws(AgentError) -> ActionResult {
        try await action(["send", String(id), "--json"], timeout: Self.sendTimeout)
    }

    public func skip(id: Int) async throws(AgentError) -> ActionResult {
        try await action(["skip", String(id), "--json"], timeout: Self.shortTimeout)
    }

    public func retry(id: Int) async throws(AgentError) -> ActionResult {
        try await action(["retry", String(id), "--json"], timeout: Self.shortTimeout)
    }

    public func setPaused(_ paused: Bool) async throws(AgentError) {
        let result = try await runner.run(
            invocation([paused ? "pause" : "resume"], timeout: Self.shortTimeout))
        guard result.exitCode == 0 else { throw AgentError.failed(exitCode: result.exitCode) }
    }
}
