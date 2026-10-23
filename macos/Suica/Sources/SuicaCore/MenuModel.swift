import Observation

@MainActor @Observable
public final class MenuModel {
    /// The last good state: a failed refresh does not clear it.
    public private(set) var state: AgentState?
    public private(set) var errorText: String?
    public private(set) var banner: String?
    /// Messages you sent from the app since it started; the views celebrate each one.
    public private(set) var sentCount = 0
    public private(set) var busyIds: Set<Int> = []
    public private(set) var confirmation: OutboxItem?
    public private(set) var clearingRecent = false

    @ObservationIgnored private let client: any AgentClient
    @ObservationIgnored private var latestRefresh = 0
    @ObservationIgnored private var pauseInFlight = false

    public init(client: any AgentClient) {
        self.client = client
    }

    /// The Owner closed the banner; the next action sets a new one.
    public func dismissBanner() { banner = nil }

    /// The Owner closed the error; the next refresh shows it again if the agent still fails.
    public func dismissError() { errorText = nil }

    public var isPaused: Bool { state?.paused ?? false }

    /// Messages that need the Owner to act.
    public var badgeCount: Int {
        state?.teams?.attention.filter { $0.state == .pending || $0.state == .unresolved }.count ?? 0
    }

    public func refresh() async {
        latestRefresh += 1
        let mine = latestRefresh
        do {
            let fresh = try await client.state()
            guard mine == latestRefresh else { return }
            state = fresh
            errorText = nil
            // The confirmation belongs to a row that was waiting for approval; if it no longer is
            // (sent or skipped elsewhere), do not leave a Send button behind.
            if let asked = confirmation,
                !(fresh.teams?.attention.contains { $0.id == asked.id && $0.state == .pending } ?? false)
            {
                confirmation = nil
            }
        } catch {
            guard mine == latestRefresh else { return }
            errorText = Self.message(for: error)
        }
    }

    public func runRefreshLoop(every interval: Duration) async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    public func requestSend(_ item: OutboxItem) {
        guard item.actions.contains(.send), !busyIds.contains(item.id) else { return }
        confirmation = item
    }

    public func cancelConfirmation() {
        confirmation = nil
    }

    public func confirmSend() async {
        guard let item = confirmation else { return }
        confirmation = nil
        await send(item)
    }

    /// Takes the item itself: the confirmation dialog can clear `confirmation` while it closes.
    public func send(_ item: OutboxItem) async {
        guard item.actions.contains(.send) else { return }
        let code = await perform(id: item.id) { (client) async throws(AgentError) -> ActionResult in
            try await client.send(id: item.id)
        }
        if code == "sent" { sentCount += 1 }
    }

    public func skip(_ item: OutboxItem) async {
        await perform(id: item.id) { (client) async throws(AgentError) -> ActionResult in
            try await client.skip(id: item.id)
        }
    }

    public func retry(_ item: OutboxItem) async {
        await perform(id: item.id) { (client) async throws(AgentError) -> ActionResult in
            try await client.retry(id: item.id)
        }
    }

    public func clear(_ item: OutboxItem) async {
        guard item.clearable else { return }
        await perform(id: item.id) { (client) async throws(AgentError) -> ActionResult in
            try await client.clear(id: item.id)
        }
    }

    /// Clears the Recent list of a group, or of both when nil.
    public func clearRecent(_ group: MessageGroup?) async {
        guard !clearingRecent else { return }
        clearingRecent = true
        do {
            banner = Copy.flash(for: try await client.clearRecent(group).code)
        } catch {
            banner = Self.message(for: error)
        }
        clearingRecent = false
        await refresh()
    }

    public func togglePause() async {
        guard !pauseInFlight else { return }
        pauseInFlight = true
        do {
            try await client.setPaused(!isPaused)
        } catch {
            banner = Self.message(for: error)
        }
        pauseInFlight = false
        await refresh()
    }

    /// One action per id at a time. The list is refreshed afterwards either way, because the row
    /// may already have been sent or skipped somewhere else.
    /// The action's result code, or nil when it did not run or the agent could not be reached.
    @discardableResult
    private func perform(
        id: Int, _ call: (any AgentClient) async throws(AgentError) -> ActionResult
    ) async -> String? {
        guard !busyIds.contains(id) else { return nil }
        busyIds.insert(id)
        var code: String?
        do {
            code = try await call(client).code
            banner = Copy.flash(for: code ?? "")
        } catch {
            banner = Self.message(for: error)
        }
        busyIds.remove(id)
        await refresh()
        return code
    }

    static func message(for error: AgentError) -> String {
        switch error {
        case .timedOut: Copy.agentTimedOut
        case .unsupportedVersion: Copy.agentOutdated
        default: Copy.agentUnreachable
        }
    }
}
