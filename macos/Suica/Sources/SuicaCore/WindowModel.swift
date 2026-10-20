import Observation

/// The two lists of the Messages page.
public enum MessageGroup: Hashable, Sendable {
    case yours, others

    public func contains(_ item: OutboxItem) -> Bool { item.isAboutYourMR == (self == .yours) }
}

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
    /// The list the Messages page shows. It lives here so a `suica://` link can switch it.
    public var messageGroup: MessageGroup = .yours
    /// The row a `suica://message/<id>` link points at; the page draws it highlighted.
    public var selectedMessageId: Int?
    /// A link the window has not acted on yet; the window takes it with `takePendingLink`.
    public private(set) var pendingLink: DeepLink?
    /// How many links have arrived. The app brings the window forward for each, also when the
    /// window took the link first, so this is never reset.
    public private(set) var linksReceived = 0

    /// The instance the popover uses, so an action started in one place blocks the other.
    @ObservationIgnored public let menu: MenuModel
    @ObservationIgnored private let client: any DashboardClient
    @ObservationIgnored private var latestRefresh = 0
    @ObservationIgnored private var latestShow = 0

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

    /// Reads the status alone, for the menu bar panel's last poll; a failure keeps the last good one.
    public func refreshStatus() async {
        if let fresh = try? await client.status() { status = fresh }
    }

    public func runRefreshLoop(every interval: Duration) async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    public func receive(_ link: DeepLink) {
        pendingLink = link
        linksReceived += 1
    }

    public func takePendingLink() -> DeepLink? {
        defer { pendingLink = nil }
        return pendingLink
    }

    /// Shows Your MRs and, for a message link, selects its row once a refresh confirms the agent still
    /// lists it (waiting, or among the recent ones). Otherwise nothing is selected. The latest link wins.
    public func show(_ link: DeepLink) async {
        latestShow += 1
        let mine = latestShow
        messageGroup = .yours
        selectedMessageId = nil
        guard case .message(let id) = link else { return }
        await menu.refresh()
        guard mine == latestShow, let teams = menu.state?.teams else { return }
        if (teams.attention + teams.recent).contains(where: { $0.id == id && MessageGroup.yours.contains($0) }) {
            selectedMessageId = id
        }
    }

    public func switchModelCli(to choice: String) async {
        await saveSetting(["model", "cli"], .string(choice), saved: Copy.modelCliSwitched)
    }

    /// `approval` or `auto`.
    public func setReviewPosting(_ mode: String) async {
        await saveSetting(["review", "post"], .string(mode), saved: Copy.reviewSettingSaved)
    }

    /// `comment` or `inline`.
    public func setReviewPostAs(_ mode: String) async {
        await saveSetting(["review", "postAs"], .string(mode), saved: Copy.reviewSettingSaved)
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
