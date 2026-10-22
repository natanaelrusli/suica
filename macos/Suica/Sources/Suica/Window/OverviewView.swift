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
                if let text = window.banner { NoticeBox(text: text, tint: .secondary, onClose: window.dismissBanner) }
                if let status = window.status {
                    if let error = status.configError {
                        NoticeBox(text: DisplayText.clean(error, max: 400), tint: .red)
                    }
                    statusBar(status)
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

    /// Opens the MR on its page: My MRs for one of yours, else Merge requests.
    private func openMR(_ key: String) {
        Task { await reviews.select(key) }
        show(reviews.isYours(key) ? .myMergeRequests : .reviews)
    }

    // MARK: Status bar and tiles

    /// The agent's health in one line, with the quick actions at its end.
    private func statusBar(_ status: StatusDocument) -> some View {
        let paused = menu.state == nil ? (status.paused ?? false) : menu.isPaused
        let health = AgentHealth(
            running: status.agent.running, loaded: status.agent.loaded, paused: paused,
            lastPollOK: status.lastPoll.map { $0.status == "ok" })
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                healthSummary(health, status)
                Spacer(minLength: 8)
                quickActionRow
            }
            VStack(alignment: .leading, spacing: 8) {
                healthSummary(health, status)
                quickActionRow
            }
        }
        .padding(.horizontal, metrics.padding)
        .padding(.vertical, metrics.padding - 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.tint(health).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Self.tint(health).opacity(0.25)))
    }

    private static func tint(_ health: AgentHealth) -> Color {
        switch health {
        case .ok: .green
        case .paused, .stopped, .missing: .orange
        case .pollFailed: .red
        }
    }

    private func healthSummary(_ health: AgentHealth, _ status: StatusDocument) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Self.tint(health))
                .frame(width: 9, height: 9)
                .shadow(color: Self.tint(health).opacity(0.6), radius: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(Copy.health(health)).font(.headline)
                Text(healthDetail(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(status.lastPoll?.failure.map { DisplayText.clean($0, max: 300) } ?? "")
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// "Last poll 2 minutes ago · every 60 s · pid 123", leaving out what is not known.
    private func healthDetail(_ status: StatusDocument) -> String {
        let lastPoll = status.lastPoll.map {
            Copy.lastPollAgo(Date(timeIntervalSince1970: TimeInterval($0.at) / 1000).formatted(.relative(presentation: .named)))
        }
        let parts = [
            lastPoll ?? Copy.noPollYet, status.polling.map { Copy.pollEvery($0.activeSeconds) },
            status.agent.pid.map(Copy.pid), status.teamsEnabled == false ? Copy.teamsOff : nil,
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private var quickActionRow: some View {
        HStack(spacing: 6) {
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
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    /// What waits for you, four figures in a row (two by two in a narrow window); each opens its page.
    private func tiles(_ status: StatusDocument) -> some View {
        let list = reviews.list
        return LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: metrics.gap * 0.75, alignment: .top), count: wide ? 4 : 2),
            spacing: metrics.gap * 0.75
        ) {
            StatTile(
                title: Copy.waitingForReviewShort,
                value: list.map { "\($0.tally.waiting)" } ?? menu.state.map { "\($0.reviewRequested)" } ?? "–",
                symbol: "person.crop.circle.badge.questionmark", tint: .purple,
                caption: list.map { Copy.reviewTally($0.tally) },
                action: { show(.reviews) }
            )
            .help(Copy.openSection(WindowSection.reviews.title))
            .staggeredEntrance(0)
            StatTile(
                title: Copy.readyToApproveShort, value: list.map { "\($0.readyToApproveCount)" } ?? "–",
                symbol: "checkmark.seal", tint: .green, caption: Copy.readyToApproveCaption,
                action: { show(.reviews) }
            )
            .help(Copy.openSection(WindowSection.reviews.title))
            .staggeredEntrance(1)
            StatTile(
                title: Copy.attentionHeading,
                value: status.teamsEnabled == false ? Copy.teamsOffShort : "\(menu.badgeCount)",
                symbol: "tray.full", tint: menu.badgeCount > 0 ? .red : .teal,
                caption: status.teamsEnabled == false ? Copy.teamsOff : Copy.attentionCaption,
                action: status.teamsEnabled == false ? nil : { show(.messages) }
            )
            .help(status.teamsEnabled == false ? Copy.teamsOff : Copy.openSection(WindowSection.messages.title))
            .staggeredEntrance(2)
            StatTile(
                title: Copy.yourMRs, value: list.map { "\($0.yourTally.open)" } ?? "–",
                symbol: "arrow.triangle.pull", tint: list.map { $0.yourTally.fixesReady > 0 } == true ? .orange : .blue,
                caption: list.map { Copy.yourTally($0.yourTally) },
                action: { show(.myMergeRequests) }
            )
            .help(Copy.openSection(WindowSection.myMergeRequests.title))
            .staggeredEntrance(3)
        }
    }

    // MARK: Widgets

    /// Your reviews beside the agent's, the messages waiting for you, then the week across the page;
    /// one column in a narrow window. Cards side by side share a height.
    @ViewBuilder private func widgets(_ status: StatusDocument) -> some View {
        let agent = status.agentReview.map(agentWidget)
        // The tile already says nothing waits; the card earns its room only with something in it.
        let messages = menu.state?.teams.flatMap { $0.attention.isEmpty ? nil : messagesWidget($0) }
        if wide {
            HStack(alignment: .top, spacing: metrics.gap) {
                reviewWidget
                agent
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            reviewWidget
            agent
        }
        messages
        weekWidget
    }

    private var reviewWidget: some View {
        let link = reviews.list.map { list in
            CardLink(title: Copy.allItems(list.mergeRequests.count)) { show(.reviews) }
        }
        return Card(title: Copy.waitingForReviewHeading, symbol: "checklist", link: link, fillsHeight: wide) {
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
        Card(title: Copy.agentReviewHeading, symbol: "checkmark.bubble", fillsHeight: wide) {
            VStack(alignment: .leading, spacing: 8) {
                if let text = reviewNotice { NoticeBox(text: text, tint: .secondary) { reviewNotice = nil } }
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

    /// The chart beside the week's figures; the figures go under the chart in a narrow window.
    private var weekWidget: some View {
        Card(
            title: Copy.weekHeading, symbol: "chart.bar",
            link: CardLink(title: Copy.linkTo(Copy.statistics)) { show(.statistics) }
        ) {
            if let stats = window.stats {
                let week = stats.week
                if wide {
                    HStack(alignment: .top, spacing: metrics.gap * 1.5) {
                        weekChart(week)
                        weekFigures(week)
                    }
                } else {
                    weekChart(week)
                    weekFigures(week)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func weekChart(_ week: WeekSummary) -> some View {
        Chart(week.days, id: \.day) { day in
            BarMark(
                x: .value(Copy.chartDay, Self.weekday(day.day)),
                y: .value(Copy.chartCount, day.reviewRequests)
            )
            .foregroundStyle(.tint)
            .cornerRadius(3)
            .annotation(position: .top, spacing: 2) {
                if day.reviewRequests > 0 {
                    Text("\(day.reviewRequests)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Copy.weekHeading)
    }

    /// The week's review requests, nudges and polls beside the tokens spent, as label and figure:
    /// stacked next to the chart, side by side under it.
    @ViewBuilder private func weekFigures(_ week: WeekSummary) -> some View {
        let activity = Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            figureRow(Copy.reviewRequests, "\(week.reviewRequests)")
            figureRow(Copy.nudgesSent, "\(week.nudgesSent)")
            if let rate = week.pollSuccess {
                figureRow(Copy.pollsOk, "\(Int((rate * 100).rounded()))%")
            }
        }
        let tokens = window.usage.map { usage in
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                figureRow(Copy.tokensFor("24 h"), Copy.tokens(usage.last24h.allTokens))
                figureRow(Copy.tokensFor("7 d"), Copy.tokens(usage.last7d.allTokens))
                figureRow(Copy.tokensFor("30 d"), Copy.tokens(usage.last30d.allTokens))
                GridRow {
                    Button(Copy.linkTo(Copy.tokenUsage)) { show(.usage) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .gridCellColumns(2)
                }
            }
        }
        Group {
            if wide {
                VStack(alignment: .leading, spacing: 10) {
                    activity
                    if tokens != nil { Divider() }
                    tokens
                }
            } else {
                HStack(alignment: .top, spacing: metrics.gap * 2) {
                    activity
                    tokens
                }
            }
        }
        .font(.callout)
        .fixedSize()
    }

    private func figureRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit().gridColumnAlignment(.trailing)
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
        VStack(alignment: .leading, spacing: 10) {
            ChoiceInput(key: "review.post", label: Copy.postingPicker, options: ["approval", "auto"], selection: Binding(
                get: { posting.wrappedValue }, set: { if let mode = $0 { posting.wrappedValue = mode } }))
            if review.postAs != nil {
                ChoiceInput(key: "review.postAs", label: Copy.postAsPicker, options: ["comment", "inline"], selection: Binding(
                    get: { postAs.wrappedValue }, set: { if let mode = $0 { postAs.wrappedValue = mode } }))
                    .help(Copy.postAsHint)
            }
            LabeledContent(Copy.reviewModelPicker) {
                Picker(Copy.reviewModelPicker, selection: model) {
                    Text(Copy.cliDefaultModel).tag("")
                    ForEach(options, id: \.self) { Text(DisplayText.clean($0, max: 60)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if let effort = review.effort {
                LevelSlider(label: Copy.reviewEffortPicker, levels: Self.efforts, selection: Binding(
                    get: { effort }, set: { level in if let level { Task { await window.setReviewEffort(level) } } }))
            }
        }
        .disabled(window.savingSetting || review.post == nil)
        Text(Copy.otherModelsHint).font(.caption2).foregroundStyle(.tertiary)
    }

    /// `review.effort`'s levels, lowest first, as the agent lists them.
    private static let efforts = ["low", "medium", "high", "xhigh", "max"]

    private func modelSection(_ cli: ModelCliStatus) -> some View {
        let selection = Binding<String>(
            get: { cli.selected ?? "auto" },
            set: { choice in Task { await window.switchModelCli(to: choice) } })
        let active = cli.clis.first { $0.id == cli.active }
        let chosen = cli.clis.first { $0.id == cli.selected }
        return VStack(alignment: .leading, spacing: 8) {
            ModelCliCards(
                selection: Binding(get: { selection.wrappedValue }, set: { if let choice = $0 { selection.wrappedValue = choice } }),
                options: ["auto"] + cli.clis.map(\.id), status: cli
            )
            // Without a loadable config there is nothing to write the choice into.
            .disabled(cli.selected == nil || window.savingSetting)
            if window.savingSetting { ProgressView().controlSize(.small) }
            if let path = active?.path {
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            } else if let chosen, active == nil {
                Label(Copy.modelCliMissing(chosen.name), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
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
