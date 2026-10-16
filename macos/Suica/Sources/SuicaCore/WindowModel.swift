import Observation

@MainActor @Observable
public final class WindowModel {
    /// The last good documents: a failed refresh does not clear them.
    public private(set) var status: StatusDocument?
    public private(set) var stats: StatsDocument?
    public private(set) var errorText: String?
    public private(set) var banner: String?
    public private(set) var restarting = false

    /// The instance the popover uses, so an action started in one place blocks the other.
    @ObservationIgnored public let menu: MenuModel
    @ObservationIgnored private let client: any DashboardClient
    @ObservationIgnored private var latestRefresh = 0

    public init(client: any DashboardClient, menu: MenuModel) {
        self.client = client
        self.menu = menu
    }

    /// Reads status and stats. Each keeps its last good value when its own read fails; the latest
    /// refresh to start is the only one allowed to store anything.
    public func refresh() async {
        latestRefresh += 1
        let mine = latestRefresh
        var failure: String?

        do {
            let fresh = try await client.status()
            if mine == latestRefresh { status = fresh }
        } catch {
            failure = MenuModel.message(for: error)
        }
        guard mine == latestRefresh else { return }

        do {
            let fresh = try await client.stats()
            if mine == latestRefresh { stats = fresh }
        } catch {
            failure = failure ?? MenuModel.message(for: error)
        }
        guard mine == latestRefresh else { return }
        errorText = failure
    }

    public func runRefreshLoop(every interval: Duration) async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    public func restartAgent() async {
        guard !restarting else { return }
        restarting = true
        do {
            let code = try await client.restartAgent().code
            // `flash(for:)` says a send failed; here it was the restart.
            banner = code == "failed" ? Copy.restartFailed : Copy.flash(for: code)
        } catch {
            banner = MenuModel.message(for: error)
        }
        restarting = false
        await refresh()
    }
}
