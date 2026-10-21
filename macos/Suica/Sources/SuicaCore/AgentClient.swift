import Foundation

public struct Invocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
    public let timeout: TimeInterval
    /// Written to the child's standard input, which is then closed; nil gives it an empty input.
    public let stdin: Data?

    public init(
        executable: String, arguments: [String], environment: [String: String],
        workingDirectory: String, timeout: TimeInterval, stdin: Data? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.stdin = stdin
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

    /// Writes `input` off the calling thread (the child may read slowly) and always closes the pipe.
    /// A child that exits or closes stdin early is not an error here: its exit code tells the story,
    /// and the pipe is made not to raise SIGPIPE.
    private static func feed(_ input: Data, to handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global().async {
            input.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count, let base = buffer.baseAddress {
                    let written = write(descriptor, base + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    offset += written
                }
            }
            try? handle.close()
        }
    }

    public func run(_ invocation: Invocation) async throws(AgentError) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = URL(fileURLWithPath: invocation.workingDirectory)
        let inPipe: Pipe? = invocation.stdin == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice
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
                try? inPipe?.fileHandleForReading.close()
                try? inPipe?.fileHandleForWriting.close()
                continuation.resume(returning: nil)
                return
            }
            if let inPipe, let input = invocation.stdin {
                // Our copy of the read end must go, or a child that exits never breaks the pipe.
                try? inPipe.fileHandleForReading.close()
                Self.feed(input, to: inPipe.fileHandleForWriting)
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
    /// Absolute path of the installed `suica` command (scripts/install-cli.sh).
    public let cliPath: String
    public let searchPath: String

    public init(cliPath: String, searchPath: String) {
        self.cliPath = cliPath
        self.searchPath = searchPath
    }

    /// The `Info.plist` keys the install script writes. Nil when any of them is missing or empty.
    public init?(infoDictionary: [String: Any]?) {
        func value(_ key: String) -> String? {
            guard let text = infoDictionary?[key] as? String, !text.isEmpty else { return nil }
            return text
        }
        guard let cli = value("SuicaCLIPath"), let search = value("SuicaSearchPath") else { return nil }
        self.init(cliPath: cli, searchPath: search)
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
    private static let restartTimeout: TimeInterval = 30
    // GitLab reads wait for glab, which the CLI stops after gitlab.timeoutSeconds (60 s by default).
    private static let gitlabTimeout: TimeInterval = 90
    // An inline post makes one glab call per finding after two lookups; a typical review's dozen
    // calls fit, and stopping the CLI mid-post would leave the review stuck as posting.
    private static let inlinePostTimeout: TimeInterval = 600
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

    /// Kept from the app's own environment: a confirm pushes over SSH and may sign its commit.
    private static let passedThrough = ["SSH_AUTH_SOCK", "GPG_AGENT_INFO", "GNUPGHOME"]

    /// The CLI's environment: only what it needs, plus the SSH and GPG agents when the app has them.
    static func environment(searchPath: String, home: String, inherited: [String: String]) -> [String: String] {
        var environment = ["PATH": searchPath, "HOME": home, "SUICA_ENV": "production"]
        for name in passedThrough { environment[name] = inherited[name] }
        return environment
    }

    private func invocation(
        _ arguments: [String], timeout: TimeInterval, stdin: Data? = nil
    ) -> Invocation {
        let inherited = ProcessInfo.processInfo.environment
        let home = inherited["HOME"] ?? NSHomeDirectory()
        return Invocation(
            executable: config.cliPath,
            arguments: arguments,
            environment: Self.environment(searchPath: config.searchPath, home: home, inherited: inherited),
            workingDirectory: home,
            timeout: timeout, stdin: stdin)
    }

    public func state() async throws(AgentError) -> AgentState {
        let result = try await runner.run(invocation(["state"], timeout: Self.shortTimeout))
        guard result.exitCode == 0 else { throw AgentError.failed(exitCode: result.exitCode) }
        guard let line = lastLine(of: result.stdout) else { throw AgentError.badOutput }
        return try decodeAgentState(line)
    }

    private func action(_ arguments: [String], timeout: TimeInterval, stdin: Data? = nil) async throws(AgentError)
        -> ActionResult
    {
        let result = try await runner.run(invocation(arguments, timeout: timeout, stdin: stdin))
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

// MARK: - Dashboard client

extension CLIAgentClient: DashboardClient {
    private func document<T: Decodable>(
        _ type: T.Type, _ arguments: [String], timeout: TimeInterval = Self.shortTimeout
    ) async throws(AgentError) -> T {
        let result = try await runner.run(invocation(arguments, timeout: timeout))
        guard result.exitCode == 0 else { throw AgentError.failed(exitCode: result.exitCode) }
        guard let line = lastLine(of: result.stdout) else { throw AgentError.badOutput }
        return try decodeDocument(type, from: line)
    }

    public func status() async throws(AgentError) -> StatusDocument {
        try await document(StatusDocument.self, ["status", "--json"])
    }

    public func stats() async throws(AgentError) -> StatsDocument {
        try await document(StatsDocument.self, ["stats"])
    }

    public func usage() async throws(AgentError) -> UsageDocument {
        try await document(UsageDocument.self, ["usage"])
    }

    public func config() async throws(AgentError) -> ConfigDocument {
        try await document(ConfigDocument.self, ["config", "show", "--json"])
    }

    public func saveConfig(base: String?, edits: [ConfigEditRequest]) async throws(AgentError)
        -> SaveResult
    {
        let body: Data
        do {
            body = try JSONEncoder().encode(SaveRequestBody(baseSha256: base, edits: edits))
        } catch {
            throw AgentError.badOutput
        }
        let result = try await runner.run(
            invocation(["config", "set", "--json"], timeout: Self.shortTimeout, stdin: body))
        // Like `action`: the agent exits 1 for invalid, conflict and bad-request, with the reason in
        // the JSON. It prints nothing when the write itself failed, which is a plain failure.
        if let line = lastLine(of: result.stdout),
            let parsed = try? JSONDecoder().decode(SaveResult.self, from: line)
        {
            return parsed
        }
        guard result.exitCode == 0 else { throw AgentError.failed(exitCode: result.exitCode) }
        throw AgentError.badOutput
    }

    public func templates() async throws(AgentError) -> TemplatesDocument {
        try await document(TemplatesDocument.self, ["templates", "show", "--json"])
    }

    public func saveTemplate(name: String, text: String?) async throws(AgentError) -> TemplateSaveResult {
        struct Body: Encodable {
            let name: String
            let text: String?

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
                // An explicit null resets the template; the key is never left out.
                try container.encode(text, forKey: .text)
            }

            enum CodingKeys: String, CodingKey { case name, text }
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(Body(name: name, text: text))
        } catch {
            throw AgentError.badOutput
        }
        let result = try await runner.run(
            invocation(["templates", "set", "--json"], timeout: Self.shortTimeout, stdin: body))
        // The CLI exits 1 for invalid and failed, with the reason in the JSON.
        if let line = lastLine(of: result.stdout),
            let parsed = try? JSONDecoder().decode(TemplateSaveResult.self, from: line)
        {
            return parsed
        }
        guard result.exitCode == 0 else { throw AgentError.failed(exitCode: result.exitCode) }
        throw AgentError.badOutput
    }

    public func restartAgent() async throws(AgentError) -> ActionResult {
        try await action(["agent", "restart", "--json"], timeout: Self.restartTimeout)
    }
}

// MARK: - Reviews client

extension CLIAgentClient: ReviewsClient {
    public func reviews() async throws(AgentError) -> ReviewListDocument {
        try await document(ReviewListDocument.self, ["reviews", "--json"], timeout: Self.gitlabTimeout)
    }

    public func mergeRequest(key: String) async throws(AgentError) -> MergeRequestDetail {
        try await document(MergeRequestDetail.self, ["mr", key, "--json"], timeout: Self.gitlabTimeout)
    }

    public func queueAgentReview(key: String) async throws(AgentError) -> ActionResult {
        try await action(["review", "queue", key, "--json"], timeout: Self.shortTimeout)
    }

    public func postAgentReview(id: Int, inline: Bool) async throws(AgentError) -> ActionResult {
        try await action(
            ["review", "post", String(id), inline ? "--inline" : "--comment", "--json"],
            timeout: inline ? Self.inlinePostTimeout : Self.gitlabTimeout)
    }

    public func discardAgentReview(id: Int) async throws(AgentError) -> ActionResult {
        try await action(["review", "discard", String(id), "--json"], timeout: Self.shortTimeout)
    }

    public func cancelAgentReview(id: Int) async throws(AgentError) -> ActionResult {
        try await action(["review", "cancel", String(id), "--json"], timeout: Self.shortTimeout)
    }

    public func approve(key: String, sha: String) async throws(AgentError) -> ActionResult {
        try await action(["mr", "approve", key, sha, "--json"], timeout: Self.gitlabTimeout)
    }
}

extension CLIAgentClient: TemplatesClient {}

// MARK: - Fixes client

extension CLIAgentClient: FixesClient {
    // A confirm reads the MR, commits, pushes over SSH and posts one reply per thread.
    private static let confirmTimeout: TimeInterval = 600

    public func fixes() async throws(AgentError) -> FixListDocument {
        try await document(FixListDocument.self, ["fix", "list", "--json"])
    }

    public func queueFix(key: String) async throws(AgentError) -> ActionResult {
        try await action(["fix", "queue", key, "--json"], timeout: Self.gitlabTimeout)
    }

    public func confirmFix(id: Int, edits: ConfirmEdits) async throws(AgentError) -> ActionResult {
        let body: Data
        do {
            body = try JSONEncoder().encode(edits)
        } catch {
            throw AgentError.badOutput
        }
        return try await action(["fix", "confirm", String(id), "--json"], timeout: Self.confirmTimeout, stdin: body)
    }

    public func retryFix(id: Int, note: String) async throws(AgentError) -> ActionResult {
        try await action(["fix", "retry", String(id), "--json"], timeout: Self.shortTimeout, stdin: Data(note.utf8))
    }

    public func discardFix(id: Int) async throws(AgentError) -> ActionResult {
        try await action(["fix", "discard", String(id), "--json"], timeout: Self.shortTimeout)
    }

    public func cancelFix(id: Int) async throws(AgentError) -> ActionResult {
        try await action(["fix", "cancel", String(id), "--json"], timeout: Self.shortTimeout)
    }

    public func postMissingReplies(id: Int) async throws(AgentError) -> ActionResult {
        try await action(["fix", "replies", String(id), "--json"], timeout: Self.inlinePostTimeout)
    }

    public func comment(key: String, body: String) async throws(AgentError) -> ActionResult {
        try await action(["mr", "comment", key, "--json"], timeout: Self.gitlabTimeout, stdin: Data(body.utf8))
    }

    public func merge(key: String, sha: String, choice: MergeChoice) async throws(AgentError) -> ActionResult {
        var arguments = ["mr", "merge", key, sha]
        if choice.squash { arguments.append("--squash") }
        if choice.removeSourceBranch { arguments.append("--remove-source-branch") }
        if choice.whenPipelineSucceeds { arguments.append("--when-pipeline-succeeds") }
        arguments.append("--json")
        return try await action(arguments, timeout: Self.gitlabTimeout, stdin: Data(choice.message.utf8))
    }

    public func close(key: String) async throws(AgentError) -> ActionResult {
        try await action(["mr", "close", key, "--json"], timeout: Self.gitlabTimeout)
    }
}
