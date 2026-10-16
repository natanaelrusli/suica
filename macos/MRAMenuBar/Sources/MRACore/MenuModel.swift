import Observation

@MainActor @Observable
public final class MenuModel {
    /// The last good state: a failed refresh does not clear it.
    public private(set) var state: AgentState?
    public private(set) var errorText: String?
    public private(set) var banner: String?
    public private(set) var busyIds: Set<Int> = []
    public private(set) var confirmation: OutboxItem?

    @ObservationIgnored private let client: any AgentClient
    @ObservationIgnored private var latestRefresh = 0
    @ObservationIgnored private var pauseInFlight = false

    public init(client: any AgentClient) {
        self.client = client
    }

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
        await perform(id: item.id) { (client) async throws(AgentError) -> ActionResult in
            try await client.send(id: item.id)
        }
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
    private func perform(
        id: Int, _ call: (any AgentClient) async throws(AgentError) -> ActionResult
    ) async {
        guard !busyIds.contains(id) else { return }
        busyIds.insert(id)
        do {
            banner = Copy.flash(for: try await call(client).code)
        } catch {
            banner = Self.message(for: error)
        }
        busyIds.remove(id)
        await refresh()
    }

    private static func message(for error: AgentError) -> String {
        switch error {
        case .timedOut: Copy.agentTimedOut
        case .unsupportedVersion: Copy.agentOutdated
        default: Copy.agentUnreachable
        }
    }
}
