import AppKit
import Charts
import SuicaCore
import SwiftUI

struct OverviewView: View {
    let window: WindowModel
    let editor: ConfigEditorModel
    let reviews: ReviewsModel
    let navigator: Navigator
    @State private var wide = false
    @Environment(\.metrics) private var metrics
    @State private var confirmingAutoPost = false
    /// The MR whose ready review Post… asks about.
    @State private var postingKey: String?
    /// The outcome of the last Agent Review action started here.
    @State private var reviewNotice: String?
    @State private var showsReviewSettings = false
    @State private var showsSystem = false

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
                    quickActions(status)
                    tiles(status)
                    widgets(status)
                    system(status)
                } else if window.errorText == nil {
                    ProgressView(Copy.loading)
                }
            }
            .padding(metrics.gap + 4)
            .motion(value: window.errorText)
            .motion(value: window.banner)
            .motion(value: window.status)
            .motion(value: window.restarting)
            .motion(value: reviews.list)
            .motion(value: reviewNotice)
            .motion(value: showsReviewSettings)
            .motion(value: showsSystem)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tracksWidth(above: 860, $wide)
        }
        .task { await reviews.refresh() }
        // While a review is queued, running or being posted, read the list again until it is done.
        .task(id: reviews.hasActiveAgentReview) {
            while reviews.hasActiveAgentReview {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await reviews.refresh()
            }
        }
        .confirmationDialog(Copy.postConfirmTitle, isPresented: posting) {
            if let key = postingKey {
                Button(Copy.postInline) { reviewAction { await reviews.postAgentReview(key, inline: true) } }
                Button(Copy.postAsComment) { reviewAction { await reviews.postAgentReview(key, inline: false) } }
            }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.postConfirmMessage)
        }
    }

    private var posting: Binding<Bool> {
        Binding(get: { postingKey != nil }, set: { if !$0 { postingKey = nil } })
    }

    /// Runs an Agent Review action, shows its outcome here and reads the status again.
    private func reviewAction(_ run: @escaping () async -> Void) {
        reviewNotice = nil
        Task {
            await run()
            reviewNotice = reviews.agentBanner
            await window.refresh()
        }
    }

    private func show(_ section: WindowSection) { navigator.selection = .section(section) }

    /// Opens the MR on the Review requests page.
    private func openMR(_ key: String) {
        Task { await reviews.select(key) }
        show(.reviews)
    }

    // MARK: Quick actions and tiles

    /// Labelled buttons when they fit, the icons alone (named on hover) in a narrow window.
    private func quickActions(_ status: StatusDocument) -> some View {
        ViewThatFits(in: .horizontal) {
            quickActionRow(status).labelStyle(.titleAndIcon)
            quickActionRow(status).labelStyle(.iconOnly)
        }
    }

    private func quickActionRow(_ status: StatusDocument) -> some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await menu.togglePause()
                    await window.refresh()
                }
            } label: {
                Label(menu.isPaused ? Copy.resume : Copy.pause, systemImage: menu.isPaused ? "play.fill" : "pause.fill")
            }
            .help(menu.isPaused ? Copy.resume : Copy.pause)
            .disabled(menu.state == nil)
            Button {
                Task { if await window.restartAgent() { editor.restartHandled() } }
            } label: {
                Label(Copy.restartAgent, systemImage: "arrow.counterclockwise")
            }
            .help(Copy.restartAgent)
            .disabled(window.restarting)
            if window.restarting { ProgressView().controlSize(.small) }
            Button {
                Task {
                    await window.refresh()
                    await menu.refresh()
                    await reviews.refresh()
                }
            } label: {
                Label(Copy.refresh, systemImage: "arrow.clockwise")
            }
            .help(Copy.refresh)
            Button {
                show(.logs)
            } label: {
                Label(Copy.openLogs, systemImage: "doc.text")
            }
            .help(Copy.openLogs)
            Button {
                show(.configuration)
            } label: {
                Label(Copy.editConfig, systemImage: "gearshape")
            }
            .help(Copy.editConfig)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    /// Six figures at a glance; those with a page behind them open it.
    private func tiles(_ status: StatusDocument) -> some View {
        let agent = status.agent
        let paused = menu.state == nil ? (status.paused ?? false) : menu.isPaused
        let lastPoll = status.lastPoll.map {
            Date(timeIntervalSince1970: TimeInterval($0.at) / 1000).formatted(.relative(presentation: .named))
        }
        return LazyVGrid(
            // Three by two, or two by three in a narrow window, so the six never wrap unevenly.
            columns: Array(
                repeating: GridItem(.flexible(), spacing: metrics.gap * 0.75, alignment: .top), count: wide ? 3 : 2),
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
                action: { show(.reviews) }
            )
            .help(Copy.openSection(WindowSection.reviews.title))
            .staggeredEntrance(2)
            StatTile(
                title: Copy.readyToApproveShort, value: reviews.list.map { "\($0.readyToApproveCount)" } ?? "–",
                symbol: "checkmark.seal", tint: .green, caption: Copy.readyToApproveCaption,
                action: { show(.reviews) }
            )
            .help(Copy.openSection(WindowSection.reviews.title))
            .staggeredEntrance(3)
            StatTile(
                title: Copy.attentionHeading,
                value: status.teamsEnabled == false ? Copy.teamsOffShort : "\(menu.badgeCount)",
                symbol: "tray.full", tint: menu.badgeCount > 0 ? .red : .teal,
                caption: status.teamsEnabled == true ? Copy.teamsOn : nil,
                action: status.teamsEnabled == false ? nil : { show(.messages) }
            )
            .help(status.teamsEnabled == false ? Copy.teamsOff : Copy.openSection(WindowSection.messages.title))
            .staggeredEntrance(4)
            StatTile(
                title: Copy.tokensToday, value: window.usage.map { Copy.tokens($0.last24h.allTokens) } ?? "–",
                symbol: "gauge.with.dots.needle.33percent", tint: .pink, caption: Copy.last24Hours,
                action: { show(.usage) }
            )
            .help(Copy.openSection(WindowSection.usage.title))
            .staggeredEntrance(5)
        }
    }

    // MARK: Widgets

    /// Two columns when there is room: reviews and messages on the left, the agent and the week on
    /// the right; one column otherwise.
    @ViewBuilder private func widgets(_ status: StatusDocument) -> some View {
        let waiting = reviewWidget
        let agent = status.agentReview.map(agentWidget)
        let messages = menu.state?.teams.map(messagesWidget)
        let week = weekWidget
        if wide {
            HStack(alignment: .top, spacing: metrics.gap) {
                VStack(spacing: metrics.gap) {
                    waiting
                    messages
                }
                VStack(spacing: metrics.gap) {
                    agent
                    week
                }
            }
        } else {
            waiting
            agent
            messages
            week
        }
    }

    private var reviewWidget: some View {
        let link = reviews.list.map { list in
            CardLink(title: Copy.allItems(list.mergeRequests.count)) { show(.reviews) }
        }
        return Card(title: Copy.waitingForReviewHeading, symbol: "checklist", link: link) {
            if let list = reviews.list {
                let rows = list.shortcuts()
                if rows.isEmpty {
                    Label(Copy.nothingWaiting, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    reviewRow(row)
                }
            } else if let error = reviews.errorText {
                NoticeBox(text: error, tint: .red)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func reviewRow(_ row: ReviewShortcut) -> some View {
        let mr = row.mr
        let busy = reviews.agentBusyKeys.contains(mr.key)
        return HStack(spacing: 10) {
            Button { openMR(mr.key) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DisplayText.clean(mr.title, max: 160)).fontWeight(.medium).lineLimit(1)
                    reason(row)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Copy.openSection(WindowSection.reviews.title))
            switch row.action {
            case .agentReview:
                Button(Copy.agentReviewShort) { reviewAction { await reviews.queueAgentReview(mr.key) } }
                    .disabled(busy)
                    .help(Copy.reviewWithAgent)
            case .rereview:
                Button(Copy.rereviewNow) { reviewAction { await reviews.queueAgentReview(mr.key) } }
                    .disabled(busy)
                    .help(Copy.reviewAgain)
            case .open:
                Button(Copy.openShort) { openMR(mr.key) }
            }
        }
        .controlSize(.small)
        .font(.callout)
    }

    @ViewBuilder private func reason(_ row: ReviewShortcut) -> some View {
        switch row.reason {
        case .readyToApprove:
            Label(Copy.readyToApproveShort, systemImage: "checkmark.seal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .changed:
            Label(row.mr.changedSinceReview.map(Copy.changedSinceReview) ?? "", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .waiting:
            Text("\(DisplayText.clean(row.mr.author.name, max: 60)) · \(DisplayText.shortKey(row.mr.key))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func agentWidget(_ review: StatusAgentReview) -> some View {
        Card(title: Copy.agentReviewHeading, symbol: "checkmark.bubble") {
            VStack(alignment: .leading, spacing: 8) {
                if let text = reviewNotice { NoticeBox(text: text, tint: .secondary) }
                if !review.allRunning.isEmpty {
                    ForEach(review.allRunning, id: \.id) { running in
                        HStack(alignment: .top) {
                            ReviewingNow(running: running, queued: 0)
                            Spacer(minLength: 8)
                            cancelButton(id: running.id, key: running.mrKey)
                        }
                    }
                } else {
                    Label(Copy.notReviewing, systemImage: "moon.zzz").foregroundStyle(.secondary)
                }
                if !review.queued.isEmpty {
                    Text(Copy.nextInQueue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(review.queued.prefix(5), id: \.id) { queued in
                        HStack {
                            Label(DisplayText.clean(queued.mrTitle ?? queued.mrKey, max: 120), systemImage: "hourglass")
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            cancelButton(id: queued.id, key: queued.mrKey)
                        }
                    }
                    if review.queued.count > 5 {
                        Text(Copy.queuedReviews(review.queued.count - 5)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if let ready = reviews.list?.readyToPost, !ready.isEmpty {
                    Text(Copy.readyToPostHeading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(ready) { mr in
                        HStack {
                            Button { openMR(mr.key) } label: {
                                Label(DisplayText.clean(mr.title, max: 120), systemImage: "sparkles")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            Spacer(minLength: 8)
                            Button(Copy.postToGitLab) { postingKey = mr.key }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(reviews.agentBusyKeys.contains(mr.key))
                        }
                    }
                }
                Divider()
                DisclosureGroup(Copy.reviewSettings, isExpanded: $showsReviewSettings) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Copy.autoReviews(review.auto)).font(.caption).foregroundStyle(.secondary)
                        reviewSettings(review)
                    }
                    .padding(.top, 6)
                }
            }
            .font(.callout)
            .confirmationDialog(Copy.autoPostConfirmTitle, isPresented: $confirmingAutoPost) {
                Button(Copy.turnOnAutoPost) { Task { await window.setReviewPosting("auto") } }
                Button(Copy.cancel, role: .cancel) {}
            } message: {
                Text(Copy.autoPostConfirmMessage)
            }
        }
    }

    private func cancelButton(id: Int, key: String) -> some View {
        Button(Copy.cancelReview) { reviewAction { await reviews.cancelAgentReview(id: id, key: key) } }
            .controlSize(.small)
            .disabled(reviews.agentBusyKeys.contains(key))
    }

    private func messagesWidget(_ teams: TeamsSection) -> some View {
        Card(
            title: Copy.attentionHeading, symbol: "tray.full",
            link: CardLink(title: Copy.linkTo(Copy.messages)) { show(.messages) }
        ) {
            if teams.attention.isEmpty {
                Label(Copy.attentionEmpty, systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            ForEach(teams.attention.prefix(3)) { OutboxItemRow(model: menu, item: $0) }
            let more = teams.attention.count - 3 + teams.attentionHidden
            if more > 0 {
                Text(Copy.moreInMessages(more)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var weekWidget: some View {
        Card(
            title: Copy.weekHeading, symbol: "chart.bar",
            link: CardLink(title: Copy.linkTo(Copy.statistics)) { show(.statistics) }
        ) {
            if let stats = window.stats {
                let week = stats.week
                Chart(week.days, id: \.day) { day in
                    BarMark(
                        x: .value(Copy.chartDay, Self.weekday(day.day)),
                        y: .value(Copy.chartCount, day.reviewRequests)
                    )
                    .foregroundStyle(.tint)
                    .cornerRadius(3)
                }
                .chartYAxis(.hidden)
                .frame(height: 80)
                .accessibilityLabel(Copy.weekHeading)
                Text(Copy.weekSummary(requests: week.reviewRequests, nudges: week.nudgesSent, pollSuccess: week.pollSuccess))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            if let usage = window.usage {
                Divider()
                HStack {
                    Label(Copy.tokensHeading, systemImage: "gauge.with.dots.needle.33percent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(Copy.linkTo(Copy.tokenUsage)) { show(.usage) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Text(
                    Copy.tokenTotals(
                        day: Copy.tokens(usage.last24h.allTokens), week: Copy.tokens(usage.last7d.allTokens),
                        month: Copy.tokens(usage.last30d.allTokens))
                )
                .font(.callout.monospacedDigit())
            }
        }
    }

    private static let dayParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    /// "Mon" for a `YYYY-MM-DD` day; the day itself if it does not parse.
    private static func weekday(_ day: String) -> String {
        dayParser.date(from: day)?.formatted(.dateTime.weekday(.abbreviated)) ?? day
    }

    // MARK: System

    private func system(_ status: StatusDocument) -> some View {
        DisclosureGroup(isExpanded: $showsSystem) {
            let agent = Card(title: Copy.agentHeading, symbol: "cpu") { agentSection(status) }
            let polling = Card(title: Copy.pollingHeading, symbol: "arrow.triangle.2.circlepath") {
                pollingSection(status)
            }
            let files = Card(title: Copy.filesHeading, symbol: "folder") { pathsSection(status.paths) }
            let model = status.modelCli.map { cli in
                Card(title: Copy.modelCliHeading, symbol: "sparkles") { modelSection(cli) }
            }
            Group {
                if wide {
                    HStack(alignment: .top, spacing: metrics.gap) {
                        VStack(spacing: metrics.gap) {
                            agent
                            polling
                        }
                        VStack(spacing: metrics.gap) {
                            model
                            files
                        }
                    }
                } else {
                    VStack(spacing: metrics.gap) {
                        agent
                        polling
                        model
                        files
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label(Copy.systemHeading, systemImage: "wrench.and.screwdriver")
                .font(.headline)
        }
    }

    private func agentSection(_ status: StatusDocument) -> some View {
        let agent = status.agent
        let text = agent.running ? Copy.agentRunning : (agent.loaded ? Copy.agentStopped : Copy.agentNotInstalled)
        return HStack(spacing: 8) {
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
            // Pause and Resume are in the quick actions at the top.
            Text(paused ? Copy.paused : Copy.running).font(.headline)
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
                    if let latest = running.latestActivity {
                        Text(DisplayText.clean(latest, max: 160))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if queued > 0 {
                        Text(Copy.queuedReviews(queued)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
