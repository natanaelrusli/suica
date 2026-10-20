import AppKit
import SuicaCore
import SwiftUI

struct OverviewView: View {
    let window: WindowModel
    let editor: ConfigEditorModel
    let navigator: Navigator
    @State private var wide = false
    @Environment(\.metrics) private var metrics
    @State private var confirmingAutoPost = false

    private var menu: MenuModel { window.menu }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.gap) {
                if let text = window.errorText { NoticeBox(text: text, tint: .red) }
                if let text = window.banner { NoticeBox(text: text, tint: .secondary) }
                if let status = window.status {
                    if let error = status.configError {
                        NoticeBox(text: DisplayText.clean(error, max: 400), tint: .red)
                    }
                    tiles(status)
                    // Two columns when there is room: the agent and polling on the left, files on
                    // the right; one column otherwise.
                    let agent = Card(title: Copy.agentHeading, symbol: "cpu") { agentSection(status) }
                    let polling = Card(title: Copy.pollingHeading, symbol: "arrow.triangle.2.circlepath") {
                        pollingSection(status)
                    }
                    let files = Card(title: Copy.filesHeading, symbol: "folder") { pathsSection(status.paths) }
                    let model = status.modelCli.map { cli in
                        Card(title: Copy.modelCliHeading, symbol: "sparkles") { modelSection(cli) }
                    }
                    let reviews = status.agentReview.map { review in
                        Card(title: Copy.agentReviewHeading, symbol: "checkmark.bubble") { reviewSection(review) }
                    }
                    if wide {
                        HStack(alignment: .top, spacing: metrics.gap) {
                            VStack(spacing: metrics.gap) {
                                agent
                                reviews
                                polling
                            }
                            VStack(spacing: metrics.gap) {
                                model
                                files
                            }
                        }
                    } else {
                        agent
                        reviews
                        polling
                        model
                        files
                    }
                } else if window.errorText == nil {
                    ProgressView(Copy.loading)
                }
            }
            .padding(metrics.gap + 4)
            .motion(value: window.errorText)
            .motion(value: window.banner)
            .motion(value: window.status)
            .motion(value: window.restarting)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tracksWidth(above: 860, $wide)
        }
    }

    /// The four things to see at a glance.
    private func tiles(_ status: StatusDocument) -> some View {
        let agent = status.agent
        let paused = menu.state == nil ? (status.paused ?? false) : menu.isPaused
        let lastPoll = status.lastPoll.map {
            Date(timeIntervalSince1970: TimeInterval($0.at) / 1000).formatted(.relative(presentation: .named))
        }
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190), spacing: metrics.gap * 0.75, alignment: .top)],
            spacing: metrics.gap * 0.75
        ) {
            StatTile(
                title: Copy.agentHeading,
                value: agent.running
                    ? Copy.agentRunningShort : (agent.loaded ? Copy.agentStoppedShort : Copy.agentMissingShort),
                symbol: "cpu", tint: agent.running ? .green : .orange,
                caption: agent.pid.map(Copy.pid)
            )
            .staggeredEntrance(0)
            StatTile(
                title: Copy.pollingHeading, value: paused ? Copy.paused : Copy.running,
                symbol: paused ? "pause.fill" : "arrow.triangle.2.circlepath",
                tint: paused ? .orange : (status.lastPoll?.status == "failed" ? .red : .blue),
                caption: lastPoll.map { Copy.lastPoll($0, ok: status.lastPoll?.status == "ok") }
            )
            .staggeredEntrance(1)
            StatTile(
                title: Copy.reviewRequests, value: menu.state.map { "\($0.reviewRequested)" } ?? "–",
                symbol: "person.crop.circle.badge.questionmark", tint: .purple,
                caption: menu.state.map { Copy.tracked($0.trackedAuthored) },
                action: { navigator.selection = .section(.reviews) }
            )
            .help(Copy.openSection(WindowSection.reviews.title))
            .staggeredEntrance(2)
            StatTile(
                title: Copy.attentionHeading,
                value: status.teamsEnabled == false ? Copy.teamsOffShort : "\(menu.badgeCount)",
                symbol: "tray.full", tint: menu.badgeCount > 0 ? .red : .teal,
                caption: status.teamsEnabled == true ? Copy.teamsOn : nil,
                action: status.teamsEnabled == false ? nil : { navigator.selection = .section(.messages) }
            )
            .help(status.teamsEnabled == false ? Copy.teamsOff : Copy.openSection(WindowSection.messages.title))
            .staggeredEntrance(3)
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

    private func reviewSection(_ review: StatusAgentReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let running = review.running {
                ReviewingNow(running: running, queued: review.queued.count)
            } else {
                Label(Copy.notReviewing, systemImage: "moon.zzz").foregroundStyle(.secondary)
            }
            if !review.queued.isEmpty {
                Text(Copy.nextInQueue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(review.queued.prefix(5), id: \.id) { queued in
                    Label(
                        DisplayText.clean(queued.mrTitle ?? queued.mrKey, max: 120),
                        systemImage: "hourglass"
                    )
                    .font(.caption)
                    .lineLimit(1)
                }
                if review.queued.count > 5 {
                    Text(Copy.queuedReviews(review.queued.count - 5)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Divider()
            Text(Copy.autoReviews(review.auto)).font(.caption).foregroundStyle(.secondary)
            reviewSettings(review)
        }
        .font(.callout)
        .confirmationDialog(Copy.autoPostConfirmTitle, isPresented: $confirmingAutoPost) {
            Button(Copy.turnOnAutoPost) { Task { await window.setReviewPosting("auto") } }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.autoPostConfirmMessage)
        }
    }

    /// Posting and model, each saved on its own; turning on automatic posting asks first.
    @ViewBuilder private func reviewSettings(_ review: StatusAgentReview) -> some View {
        let posting = Binding<String>(
            get: { review.post ?? "approval" },
            set: { mode in
                if mode == "auto" {
                    confirmingAutoPost = true
                } else {
                    Task { await window.setReviewPosting(mode) }
                }
            })
        // Claude Code's aliases are offered when it reviews; any other value set in the config is kept.
        let claude = window.status?.modelCli?.active == "claude"
        let aliases = claude ? ["opus", "sonnet", "haiku"] : []
        let options = aliases + (review.model.map { aliases.contains($0) ? [] : [$0] } ?? [])
        let postAs = Binding<String>(
            get: { review.postAs ?? "comment" },
            set: { mode in Task { await window.setReviewPostAs(mode) } })
        let model = Binding<String>(
            get: { review.model ?? "" },
            set: { name in Task { await window.setReviewModel(name.isEmpty ? nil : name) } })
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text(Copy.postingPicker).foregroundStyle(.secondary)
                Picker(Copy.postingPicker, selection: posting) {
                    Text(Copy.postWait).tag("approval")
                    Text(Copy.postAuto).tag("auto")
                }
                .labelsHidden()
                .fixedSize()
            }
            if review.postAs != nil {
                GridRow {
                    Text(Copy.postAsPicker).foregroundStyle(.secondary)
                    Picker(Copy.postAsPicker, selection: postAs) {
                        Text(Copy.postAsCommentOption).tag("comment")
                        Text(Copy.postAsInlineOption).tag("inline")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help(Copy.postAsHint)
                }
            }
            GridRow {
                Text(Copy.reviewModelPicker).foregroundStyle(.secondary)
                Picker(Copy.reviewModelPicker, selection: model) {
                    Text(Copy.cliDefaultModel).tag("")
                    ForEach(options, id: \.self) { Text(DisplayText.clean($0, max: 60)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .disabled(window.savingSetting || review.post == nil)
        Text(Copy.otherModelsHint).font(.caption2).foregroundStyle(.tertiary)
    }

    private func modelSection(_ cli: ModelCliStatus) -> some View {
        let selection = Binding<String>(
            get: { cli.selected ?? "auto" },
            set: { choice in Task { await window.switchModelCli(to: choice) } })
        let active = cli.clis.first { $0.id == cli.active }
        let chosen = cli.clis.first { $0.id == cli.selected }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(Copy.modelCliPicker, selection: selection) {
                    Text(Copy.modelCliAuto).tag("auto")
                    ForEach(cli.clis, id: \.id) { each in
                        Text(each.path == nil ? Copy.notInstalled(each.name) : each.name).tag(each.id)
                    }
                }
                .fixedSize()
                // Without a loadable config there is nothing to write the choice into.
                .disabled(cli.selected == nil || window.savingSetting)
                if window.savingSetting { ProgressView().controlSize(.small) }
            }
            if let active {
                Label(Copy.modelCliInUse(active.name), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let path = active.path {
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else if let chosen {
                Label(Copy.modelCliMissing(chosen.name), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if cli.selected != nil {
                Label(Copy.noModelCliInstalled, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(Copy.modelCliNote).font(.caption).foregroundStyle(.tertiary)
        }
        .font(.callout)
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
            Divider()
            lastPollLine(status.lastPoll)
            // What is tracked, waiting and needs you is in the tiles above; only say Teams is off.
            if status.teamsEnabled == false {
                Text(Copy.teamsOff).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
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

/// The MR the agent is reviewing now: shared by Overview and the menu bar popover.
struct ReviewingNow: View {
    let running: RunningReview
    let queued: Int

    var body: some View {
        // Re-rendered every 30 seconds so "for N min" stays current.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.reviewing(DisplayText.clean(running.mrTitle ?? running.mrKey, max: 120)))
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Text(Copy.runningLine(cli: running.cli, model: running.model, since: running.startedAt, now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if queued > 0 {
                        Text(Copy.queuedReviews(queued)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
