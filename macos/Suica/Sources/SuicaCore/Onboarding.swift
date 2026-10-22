import Observation

/// `suica gitlab check <host> --json`. It carries no version, like `SaveResult`.
public struct GitlabCheck: Codable, Equatable, Sendable {
    /// ok, bad-host, glab-missing, gitlab-auth, gitlab-unreachable or gitlab-error; kept as sent.
    public let status: String
    /// The signed-in GitLab user, only with ok.
    public let username: String?

    public init(status: String, username: String?) {
        self.status = status
        self.username = username
    }
}

/// The first-run commands, which work before a config file exists.
public protocol SetupClient: Sendable {
    func checkGitlab(host: String) async throws(AgentError) -> GitlabCheck
    /// `suica agent install --json`: installed, no-config or failed.
    func installAgent() async throws(AgentError) -> ActionResult
}

public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, gitlab, codingAgent, teams, finish
}

/// Set up Suica: a few answers that become the first config file, then the agent starts. While
/// there is no config file the window and the menu bar panel show it in place of their pages, whose
/// commands all fail without one.
@MainActor @Observable
public final class OnboardingModel {
    /// No config file yet, as last checked. False until a check says so, and while the agent
    /// cannot be reached, which says nothing about a first run.
    public private(set) var needsSetup = false
    public private(set) var step: OnboardingStep = .welcome
    /// What the host box holds; `host` is what gets written.
    public var hostText = "" {
        didSet { if ConfigInputs.host(from: hostText) != ConfigInputs.host(from: oldValue) { check = nil } }
    }
    public var modelCli = "auto"
    public var teamsEnabled = false
    public private(set) var check: GitlabCheck?
    public private(set) var checkError: String?
    public private(set) var checking = false
    /// The coding agent CLIs the agent found on this Mac; nil while not known.
    private var detectedClis: [DetectedModelCli]?
    public private(set) var finishing = false
    public private(set) var finished = false
    public private(set) var failure: String?
    /// The file was written by an earlier try, so a retry only starts the agent.
    @ObservationIgnored private var saved = false

    @ObservationIgnored private let dashboard: any DashboardClient
    @ObservationIgnored private let setup: any SetupClient

    public init(dashboard: any DashboardClient, setup: any SetupClient) {
        self.dashboard = dashboard
        self.setup = setup
    }

    public var host: String { ConfigInputs.host(from: hostText) }

    /// The CLIs as the cards show them, with the one this choice would run in use. Without a config
    /// file the agent names none in use, so it is worked out here as the agent would: Auto takes
    /// the first installed, in the agent's order.
    public var modelClis: ModelCliStatus? {
        guard let clis = detectedClis else { return nil }
        let installed = clis.filter { $0.path != nil }
        let active = modelCli == "auto" ? installed.first : installed.first { $0.id == modelCli }
        return ModelCliStatus(selected: modelCli, active: active?.id, clis: clis)
    }

    /// A missing config file is the one sure sign of a first run. A file that exists but does not
    /// load is Configuration's to fix. Answers typed before a check are kept.
    public func checkNeeded() async {
        // The sheet's own "you're all set" stays until Done, whatever the file says now.
        guard !finished, let document = try? await dashboard.config() else { return }
        needsSetup = !document.exists
        if needsSetup, let status = try? await dashboard.status() { detectedClis = status.modelCli?.clis }
    }

    /// Done on the last step: the window and the panel go back to their pages.
    public func complete() {
        needsSetup = false
        finished = false
        step = .welcome
    }

    public var canContinue: Bool { step != .gitlab || !host.isEmpty }

    public func next() {
        guard canContinue, let following = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = following
    }

    public func back() {
        guard !finishing, let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
        failure = nil
    }

    public func checkConnection() async {
        let host = self.host
        guard !host.isEmpty else { return }
        checking = true
        checkError = nil
        defer { checking = false }
        do {
            let result = try await setup.checkGitlab(host: host)
            // The host changed while glab ran: that answer is for another host.
            if host == self.host { check = result }
        } catch {
            checkError = MenuModel.message(for: error)
        }
    }

    /// Only what differs from the agent's defaults, so the file stays short.
    public var edits: [ConfigEditRequest] {
        var edits = [ConfigEditRequest(path: ["gitlab", "hostname"], value: .string(host))]
        if modelCli != "auto" { edits.append(ConfigEditRequest(path: ["model", "cli"], value: .string(modelCli))) }
        if teamsEnabled { edits.append(ConfigEditRequest(path: ["teams", "enabled"], value: .bool(true))) }
        return edits
    }

    /// Writes the file (never over one that exists) and installs the agent.
    public func finish() async {
        guard !finishing, !finished else { return }
        finishing = true
        failure = nil
        defer { finishing = false }
        do {
            if !saved {
                let result = try await dashboard.saveConfig(base: nil, edits: edits)
                guard result.status == "saved" else {
                    failure = Copy.setupNotSaved(status: result.status, issues: result.issues)
                    return
                }
                saved = true
            }
            let installed = try await setup.installAgent()
            guard installed.code == "installed" else {
                failure = Copy.setupAgentNotStarted
                return
            }
            finished = true
        } catch {
            failure = MenuModel.message(for: error)
        }
    }
}
