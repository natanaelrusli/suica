import AppKit
import SuicaCore
import SwiftUI

/// Used when the bundle does not name the CLI (for example `swift run`): every call reports unreachable.
private struct UnconfiguredClient: AgentClient {
    func state() async throws(AgentError) -> AgentState { throw AgentError.launchFailed }
    func send(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func skip(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func retry(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func setPaused(_ paused: Bool) async throws(AgentError) { throw AgentError.launchFailed }
}

extension UnconfiguredClient: DashboardClient {
    func status() async throws(AgentError) -> StatusDocument { throw AgentError.launchFailed }
    func stats() async throws(AgentError) -> StatsDocument { throw AgentError.launchFailed }
    func usage() async throws(AgentError) -> UsageDocument { throw AgentError.launchFailed }
    func config() async throws(AgentError) -> ConfigDocument { throw AgentError.launchFailed }
    func saveConfig(base: String?, edits: [ConfigEditRequest]) async throws(AgentError) -> SaveResult {
        throw AgentError.launchFailed
    }
    func restartAgent() async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
}

extension UnconfiguredClient: ReviewsClient {
    func reviews() async throws(AgentError) -> ReviewListDocument { throw AgentError.launchFailed }
    func mergeRequest(key: String) async throws(AgentError) -> MergeRequestDetail { throw AgentError.launchFailed }
    func queueAgentReview(key: String) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func postAgentReview(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func discardAgentReview(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func approve(key: String, sha: String) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
}

private let refreshInterval: Duration = .seconds(30)

@main
struct SuicaApp: App {
    @State private var model: MenuModel
    @State private var window: WindowModel
    @State private var editor: ConfigEditorModel
    @State private var reviews: ReviewsModel

    init() {
        let agent: any AgentClient
        let dashboard: any DashboardClient
        let reviewsClient: any ReviewsClient
        if let config = AgentConfig.fromBundle(.main) {
            let client = CLIAgentClient(config: config, runner: ProcessRunner())
            agent = client
            dashboard = client
            reviewsClient = client
        } else {
            agent = UnconfiguredClient()
            dashboard = UnconfiguredClient()
            reviewsClient = UnconfiguredClient()
        }
        let model = MenuModel(client: agent)
        _model = State(initialValue: model)
        // The window reuses the popover's model, so an action started in one blocks the other.
        _window = State(initialValue: WindowModel(client: dashboard, menu: model))
        _editor = State(initialValue: ConfigEditorModel(client: dashboard))
        _reviews = State(initialValue: ReviewsModel(client: reviewsClient))
        Task { @MainActor in await model.runRefreshLoop(every: refreshInterval) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(nsImage: PenguinGlyph.image)
            if model.badgeCount > 0 { Text("\(model.badgeCount)") }
        }
        .menuBarExtraStyle(.window)

        Window(Copy.appName, id: "main") {
            MainWindow(window: window, editor: editor, reviews: reviews)
        }
        .defaultSize(width: 1100, height: 720)
        .commands { SidebarCommands() }
    }
}
