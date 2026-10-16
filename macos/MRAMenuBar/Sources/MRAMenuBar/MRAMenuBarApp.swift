import AppKit
import MRACore
import SwiftUI

/// Used when the bundle has no agent paths (for example `swift run`): every call reports unreachable.
private struct UnconfiguredClient: AgentClient {
    func state() async throws(AgentError) -> AgentState { throw AgentError.launchFailed }
    func send(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func skip(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func retry(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func setPaused(_ paused: Bool) async throws(AgentError) { throw AgentError.launchFailed }
}

private let refreshInterval: Duration = .seconds(30)

@main
struct MRAMenuBarApp: App {
    @State private var model: MenuModel

    init() {
        let client: any AgentClient
        if let config = AgentConfig.fromBundle(.main) {
            client = CLIAgentClient(config: config, runner: ProcessRunner())
        } else {
            client = UnconfiguredClient()
        }
        let model = MenuModel(client: client)
        _model = State(initialValue: model)
        Task { @MainActor in await model.runRefreshLoop(every: refreshInterval) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: "tray.full")
            if model.badgeCount > 0 { Text("\(model.badgeCount)") }
        }
        .menuBarExtraStyle(.window)
    }
}
