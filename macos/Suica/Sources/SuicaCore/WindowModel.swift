import Observation

@MainActor @Observable
public final class WindowModel {
    /// The last good documents: a failed refresh does not clear them.
    public private(set) var status: StatusDocument?
    public private(set) var stats: StatsDocument?
    public private(set) var usage: UsageDocument?
    public private(set) var errorText: String?
    public private(set) var banner: String?
    public private(set) var restarting = false
    /// A one-key save from Overview is in flight.
    public private(set) var savingSetting = false

    /// The instance the popover uses, so an action started in one place blocks the other.
    @ObservationIgnored public let menu: MenuModel
    @ObservationIgnored private let client: any DashboardClient
    @ObservationIgnored private var latestRefresh = 0

    public init(client: any DashboardClient, menu: MenuModel) {
        self.client = client
        self.menu = menu
    }

    /// Reads status, stats and usage. Each keeps its last good value when its own read fails; the latest
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
            // With a broken config `stats` fails too; the status document already says why, so the
            // agent is not reported as unreachable. The last good stats stay.
            if status?.configError == nil { failure = failure ?? MenuModel.message(for: error) }
        }
        guard mine == latestRefresh else { return }

        do {
            let fresh = try await client.usage()
            if mine == latestRefresh { usage = fresh }
        } catch {
            // Fails with a broken config for the same reason as `stats`.
            if status?.configError == nil { failure = failure ?? MenuModel.message(for: error) }
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

    public func switchModelCli(to choice: String) async {
        await saveSetting(["model", "cli"], .string(choice), saved: Copy.modelCliSwitched)
    }

    /// `approval` or `auto`.
    public func setReviewPosting(_ mode: String) async {
        await saveSetting(["review", "post"], .string(mode), saved: Copy.reviewSettingSaved)
    }

    /// Nil removes the key, so the CLI's default model applies.
    public func setReviewModel(_ model: String?) async {
        await saveSetting(["review", "model"], model.map(JSONValue.string) ?? .null, saved: Copy.reviewSettingSaved)
    }

    /// Writes one key alone, on the file as it is now, so unsaved edits in the Configuration form
    /// are neither saved nor lost. Like every config edit it applies after a restart.
    private func saveSetting(_ path: [String], _ value: JSONValue, saved: String) async {
        guard !savingSetting else { return }
        savingSetting = true
        do {
            let base = try await client.config().sha256
            let result = try await client.saveConfig(base: base, edits: [ConfigEditRequest(path: path, value: value)])
            switch result.status {
            case "saved": banner = saved
            case "invalid":
                let lines = result.issues.map { "\(DisplayText.clean($0.path, max: 80)): \(DisplayText.clean($0.message))" }
                banner = lines.isEmpty ? Copy.configInvalid : "\(Copy.configInvalid) \(lines.joined(separator: "; "))"
            case "conflict": banner = Copy.configConflict
            default: banner = Copy.configSaveFailed
            }
        } catch {
            switch error {
            case .failed, .badOutput: banner = Copy.configSaveFailed
            default: banner = MenuModel.message(for: error)
            }
        }
        savingSetting = false
        await refresh()
    }

    /// True only when the agent reported that it restarted.
    @discardableResult
    public func restartAgent() async -> Bool {
        guard !restarting else { return false }
        restarting = true
        var restarted = false
        do {
            let code = try await client.restartAgent().code
            restarted = code == "restarted"
            // `flash(for:)` says a send failed; here it was the restart.
            banner = code == "failed" ? Copy.restartFailed : Copy.flash(for: code)
        } catch {
            banner = MenuModel.message(for: error)
        }
        restarting = false
        await refresh()
        return restarted
    }
}
