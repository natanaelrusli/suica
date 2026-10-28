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
    /// Hides a finished message from the lists.
    func clear(id: Int) async throws(AgentError) -> ActionResult
    /// Hides every sent or skipped message of the group, or of both when nil.
    func clearRecent(_ group: MessageGroup?) async throws(AgentError) -> ActionResult
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

    public func clear(id: Int) async throws(AgentError) -> ActionResult {
        try await action(["clear", String(id), "--json"], timeout: Self.shortTimeout)
    }

    public func clearRecent(_ group: MessageGroup?) async throws(AgentError) -> ActionResult {
        let target =
            switch group {
            case .yours: "yours"
            case .others: "others"
            case nil: "all"
            }
        return try await action(["clear", target, "--json"], timeout: Self.shortTimeout)
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

// MARK: - Setup client

extension CLIAgentClient: SetupClient {
    public func checkGitlab(host: String) async throws(AgentError) -> GitlabCheck {
        // `--` keeps a host typed as an option from being read as one; the CLI refuses it anyway.
        let result = try await runner.run(
            invocation(["gitlab", "check", "--json", "--", host], timeout: Self.gitlabTimeout))
        // The CLI exits 1 for every answer but ok, with the reason in the JSON.
        if let line = lastLine(of: result.stdout),
            let parsed = try? JSONDecoder().decode(GitlabCheck.self, from: line)
        {
            return parsed
        }
        guard result.exitCode == 0 else { throw AgentError.failed(exitCode: result.exitCode) }
        throw AgentError.badOutput
    }

    public func installAgent() async throws(AgentError) -> ActionResult {
        try await action(["agent", "install", "--json"], timeout: Self.restartTimeout)
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

    public func queueAgentReview(key: String, choice: ReviewChoice) async throws(AgentError) -> ActionResult {
        try await action(["review", "queue", key] + choice.arguments + ["--json"], timeout: Self.shortTimeout)
    }

    public func reviewOptions(cli: String?) async throws(AgentError) -> ReviewOptions {
        try await document(
            ReviewOptions.self, ["review", "options"] + (cli.map { ["--cli", $0] } ?? []) + ["--json"])
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

    /// Sending waits as long as a pending message does; a draft only reads the MR.
    public func teamsMessage(key: String, request: TeamsMessageRequest) async throws(AgentError) -> TeamsMessageReply {
        let body: Data
        do {
            body = try JSONEncoder().encode(request)
        } catch {
            throw AgentError.badOutput
        }
        let result = try await runner.run(
            invocation(
                ["message", key, "--json"], timeout: request.send ? Self.sendTimeout : Self.gitlabTimeout, stdin: body))
        // The CLI exits 1 when nothing was sent, with the reason in the JSON: read that first.
        if let line = lastLine(of: result.stdout), let reply = try? JSONDecoder().decode(TeamsMessageReply.self, from: line) {
            return reply
        }
        guard result.exitCode == 0 else { throw AgentError.failed(exitCode: result.exitCode) }
        throw AgentError.badOutput
    }
}

extension CLIAgentClient: OfficeClient {
    public func office() async throws(AgentError) -> OfficeDocument {
        try await document(OfficeDocument.self, ["office", "--json"])
    }

    public func chat(agent: String, sessionId: String) async throws(AgentError) -> OfficeChatDocument {
        try await document(OfficeChatDocument.self, ["office", "chat", agent, sessionId, "--json"])
    }

    /// The CLI gives the agent's turn 30 minutes; this leaves it time to say so.
    private static let officeSendTimeout: TimeInterval = 31 * 60

    public func send(agent: String, sessionId: String, message: String) async throws(AgentError) -> ActionResult {
        try await action(
            ["office", "send", agent, sessionId, "--json"], timeout: Self.officeSendTimeout, stdin: Data(message.utf8))
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

    public func queuePipelineFix(key: String) async throws(AgentError) -> ActionResult {
        try await action(["fix", "queue", key, "--pipeline", "--json"], timeout: Self.gitlabTimeout)
    }

    public func setWatched(key: String, watched: Bool) async throws(AgentError) -> ActionResult {
        try await action(["fix", watched ? "watch" : "unwatch", key, "--json"], timeout: Self.gitlabTimeout)
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

// MARK: - Lessons client

/// `{"status": …, "message": …}`, as `suica lessons archive|merge|show` answer a refusal.
private struct LessonStatusLine: Decodable {
    let status: String
    let message: String?
}

extension CLIAgentClient: LessonsClient {
    // `status` asks `claude mcp list` and `codex mcp list`, which check every server they know.
    private static let lessonsStatusTimeout: TimeInterval = 60
    // Install and uninstall run up to four claude/codex mcp calls of up to 30 s each.
    private static let lessonsInstallTimeout: TimeInterval = 150

    /// A command that answers with JSON even when it exits 1 (a refusal, a plan): the last line.
    private func lessonsReply<T: Decodable>(_ type: T.Type, _ arguments: [String], timeout: TimeInterval)
        async throws(AgentError) -> T
    {
        let result = try await runner.run(invocation(arguments, timeout: timeout))
        if let line = lastLine(of: result.stdout), let parsed = try? JSONDecoder().decode(T.self, from: line) {
            return parsed
        }
        guard result.exitCode == 0 else { throw AgentError.failed(exitCode: result.exitCode) }
        throw AgentError.badOutput
    }

    public func lessons() async throws(AgentError) -> LessonListDocument {
        try await document(LessonListDocument.self, ["lessons", "list", "--json"])
    }

    public func lesson(id: Int) async throws(AgentError) -> LessonDetailDocument? {
        let result = try await runner.run(
            invocation(["lessons", "show", String(id), "--json"], timeout: Self.shortTimeout))
        guard let line = lastLine(of: result.stdout) else {
            throw result.exitCode == 0 ? AgentError.badOutput : AgentError.failed(exitCode: result.exitCode)
        }
        if let status = try? JSONDecoder().decode(LessonStatusLine.self, from: line), status.status == "not-found" {
            return nil
        }
        guard result.exitCode == 0 else { throw AgentError.failed(exitCode: result.exitCode) }
        return try decodeDocument(LessonDetailDocument.self, from: line)
    }

    public func archiveLesson(id: Int) async throws(AgentError) -> LessonChangeOutcome {
        let line = try await lessonsReply(
            LessonStatusLine.self, ["lessons", "archive", String(id), "--json"], timeout: Self.shortTimeout)
        return LessonChangeOutcome(status: line.status, message: line.message)
    }

    public func mergeLessons(keep: Int, gone: Int) async throws(AgentError) -> LessonChangeOutcome {
        let line = try await lessonsReply(
            LessonStatusLine.self, ["lessons", "merge", String(keep), String(gone), "--json"],
            timeout: Self.shortTimeout)
        return LessonChangeOutcome(status: line.status, message: line.message)
    }

    public func lessonsStatus() async throws(AgentError) -> LessonsSetupStatus {
        try await document(LessonsSetupStatus.self, ["lessons", "status", "--json"], timeout: Self.lessonsStatusTimeout)
    }

    public func installLessons(confirm: Bool) async throws(AgentError) -> LessonsInstallReply {
        try await lessonsReply(
            LessonsInstallReply.self, ["lessons", "install"] + (confirm ? ["--yes"] : []) + ["--json"],
            timeout: Self.lessonsInstallTimeout)
    }

    public func uninstallLessons() async throws(AgentError) -> LessonsUninstallReply {
        try await lessonsReply(
            LessonsUninstallReply.self, ["lessons", "uninstall", "--json"], timeout: Self.lessonsInstallTimeout)
    }

    public func exportLessons(zipTo: String?) async throws(AgentError) -> LessonsExportReply {
        let arguments = zipTo.map { ["lessons", "export", "--zip", $0, "--json"] } ?? ["lessons", "export", "--json"]
        return try await lessonsReply(LessonsExportReply.self, arguments, timeout: Self.gitlabTimeout)
    }
}

// MARK: - Updates client

extension CLIAgentClient: UpdatesClient {
    // Downloading and verifying a release.
    private static let updateApplyTimeout: TimeInterval = 1800

    /// These commands answer with JSON even when they exit 1 (a refusal): the last line.
    private func updateReply<T: Decodable>(_ type: T.Type, _ arguments: [String], timeout: TimeInterval)
        async throws(AgentError) -> T
    {
        let result = try await runner.run(invocation(arguments, timeout: timeout))
        if let line = lastLine(of: result.stdout), let parsed = try? decodeDocument(T.self, from: line) { return parsed }
        guard result.exitCode == 0 else { throw AgentError.failed(exitCode: result.exitCode) }
        throw AgentError.badOutput
    }

    public func checkUpdate() async throws(AgentError) -> UpdateCheck {
        try await updateReply(UpdateCheck.self, ["update", "check", "--json"], timeout: Self.gitlabTimeout)
    }

    public func applyUpdate() async throws(AgentError) -> UpdateApplied {
        try await updateReply(UpdateApplied.self, ["update", "apply", "--json"], timeout: Self.updateApplyTimeout)
    }
}
