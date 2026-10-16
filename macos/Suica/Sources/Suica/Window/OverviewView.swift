import AppKit
import SuicaCore
import SwiftUI

struct OverviewView: View {
    let window: WindowModel
    let editor: ConfigEditorModel

    private var menu: MenuModel { window.menu }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let text = window.errorText { NoticeBox(text: text, tint: .red) }
                if let text = window.banner { NoticeBox(text: text, tint: .secondary) }
                if let status = window.status {
                    if let error = status.configError {
                        NoticeBox(text: DisplayText.clean(error, max: 400), tint: .red)
                    }
                    agentSection(status)
                    pollingSection(status)
                    pathsSection(status.paths)
                } else if window.errorText == nil {
                    ProgressView(Copy.loading)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func agentSection(_ status: StatusDocument) -> some View {
        let agent = status.agent
        let text = agent.running ? Copy.agentRunning : (agent.loaded ? Copy.agentStopped : Copy.agentNotInstalled)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: agent.running ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(agent.running ? Color.green : Color.orange)
                    .accessibilityLabel(text)
                Text(text).font(.headline)
                if agent.running, let pid = agent.pid {
                    Text(Copy.pid(pid)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if window.restarting { ProgressView().controlSize(.small) }
                Button(Copy.restartAgent) {
                    Task { if await window.restartAgent() { editor.restartHandled() } }
                }
                .disabled(window.restarting)
            }
        }
    }

    private func pollingSection(_ status: StatusDocument) -> some View {
        let paused = menu.state == nil ? (status.paused ?? false) : menu.isPaused
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(paused ? Copy.paused : Copy.running).font(.headline)
                Spacer()
                // The button flips the popover model's state, so it is labelled from it too.
                Button(menu.isPaused ? Copy.resume : Copy.pause) {
                    Task {
                        await menu.togglePause()
                        await window.refresh()
                    }
                }
                .disabled(menu.state == nil)
            }
            if let polling = status.polling {
                Text(Copy.pollIntervals(active: polling.activeSeconds, idle: polling.idleSeconds))
                    .font(.caption).foregroundStyle(.secondary)
            }
            lastPollLine(status.lastPoll)
            if let state = menu.state {
                Text("\(Copy.tracked(state.trackedAuthored)) · \(Copy.waitingForYou(state.reviewRequested))")
                    .foregroundStyle(.secondary)
            }
            if let teams = status.teamsEnabled {
                Text(
                    teams
                        ? "\(Copy.teamsOn) · \(Copy.needsAttention(menu.badgeCount))" : Copy.teamsOff
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func lastPollLine(_ poll: PollEntry?) -> some View {
        if let poll {
            let date = Date(timeIntervalSince1970: TimeInterval(poll.at) / 1000)
            let relative = date.formatted(.relative(presentation: .named))
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.lastPoll(relative, ok: poll.status == "ok"))
                if let failure = poll.failure {
                    Text(DisplayText.clean(failure, max: 300)).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(Copy.noPollYet).foregroundStyle(.secondary)
        }
    }

    private func pathsSection(_ paths: StatusPaths) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            pathRow(Copy.configPath, paths.config)
            pathRow(Copy.statePath, paths.state)
            pathRow(Copy.logsPath, paths.logs)
            pathRow(Copy.templatesPath, paths.templates)
        }
    }

    private func pathRow(_ title: String, _ path: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(DisplayText.clean(path, max: 300))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(DisplayText.clean(path, max: 300))
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "folder")
            }
            .help(Copy.revealInFinder)
            .accessibilityLabel("\(Copy.revealInFinder): \(title)")
        }
    }
}
