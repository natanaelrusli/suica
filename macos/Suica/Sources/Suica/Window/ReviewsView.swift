import SuicaCore
import SwiftUI

/// Merge requests (the open MRs where you are a Reviewer, in tabs) or My MRs (your own): the list
/// on the left, the selected MR on the right. Both pages share one model and its selection.
struct ReviewsView: View {
    let model: ReviewsModel
    let fixes: FixesModel
    let scope: ReviewScope
    @State private var query = ""
    @State private var tab: ReviewGroup = .waiting

    var body: some View {
        // The list runs up under the title bar and scrolls beneath it; the MR starts below it.
        UnderTitleBar { titleBar in
            HStack(spacing: 0) {
                list(titleBar: titleBar)
                    .frame(width: 300)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, titleBar)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: scope == .mine ? Copy.searchMyMRs : Copy.searchReviews)
        .task {
            await model.show(scope)
            await refreshAll()
            syncTabToSelection()
        }
        // Reads the list and the selected MR again while the page is open, more often while a
        // review, a fix or the MR's pipeline is queued or running (see `refreshSeconds`).
        .task(id: refreshSeconds) {
            while true {
                do { try await Task.sleep(for: .seconds(refreshSeconds)) } catch { return }
                await refreshAll()
            }
        }
        .toolbar {
            ListRefreshButton(model: model) { await refreshAll() }
        }
    }

    private var refreshSeconds: Int { fixes.hasActiveFix ? 3 : model.refreshSeconds }

    private func refreshAll() async {
        async let list: Void = model.refresh()
        async let fixList: Void = fixes.refresh()
        _ = await (list, fixList)
    }

    private var selection: Binding<String?> {
        Binding(get: { model.selectedKey }, set: { key in Task { await model.select(key) } })
    }

    private func list(titleBar: CGFloat) -> some View {
        List(selection: selection) {
            if let text = model.errorText {
                NoticeBox(text: text, tint: .red, onClose: model.dismissError).listRowSeparator(.hidden)
            }
            if let list = model.list {
                rows(in: list)
            } else if model.errorText == nil {
                ProgressView(Copy.loading).frame(maxWidth: .infinity)
            }
        }
        .motion(value: model.list)
        .motion(value: model.errorText)
        .modifier(ListTopBar(titleBar: titleBar) {
            if scope == .reviewing, let list = model.list { tabBar(in: list) }
        })
        .onChange(of: tab) { _, tab in
            guard let list = model.list else { return }
            let keys = list.keys(in: tab, matching: query)
            guard model.selectedKey.map(keys.contains) != true else { return }
            Task { await model.select(keys.first) }
        }
        .onChange(of: model.selectedKey) { syncTabToSelection() }
        .onAppear { syncTabToSelection() }
    }

    /// The tab on screen: `tab`, unless this list has none of that name (no `me`, so one group).
    private func shownTab(in list: ReviewListDocument) -> ReviewGroup {
        list.tabs.contains(tab) ? tab : .all
    }

    /// Follows the selection into its tab, when it is chosen elsewhere (the Overview, a refresh).
    private func syncTabToSelection() {
        guard scope == .reviewing, let key = model.selectedKey, let list = model.list,
            let owner = list.group(containing: key), owner != shownTab(in: list)
        else { return }
        tab = owner
    }

    /// One tab per category with its count (the matches while searching), so a category never
    /// shares a list with another.
    private func tabBar(in list: ReviewListDocument) -> some View {
        let shown = shownTab(in: list)
        return Picker("", selection: Binding(get: { shown }, set: { tab = $0 })) {
            ForEach(list.tabs, id: \.self) { tab in
                Text("\(Copy.reviewTab(tab)) \(list.keys(in: tab, matching: query).count)")
                    .help(Copy.reviewTabHelp(tab))
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func rows(in list: ReviewListDocument) -> some View {
        let text = query.trimmingCharacters(in: .whitespaces)
        switch scope {
        case .mine:
            let mine = list.yourMergeRequests(matching: query)
            if mine.isEmpty {
                Text(text.isEmpty ? Copy.noOpenMRsOfYours : Copy.noReviewsMatch(text))
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(mine) { mr in YourMRRow(mr: mr).tag(mr.key) }
        case .reviewing:
            let shown = shownTab(in: list)
            let items = list.sections(matching: query).first { $0.group == shown }?.items ?? []
            if items.isEmpty {
                Text(text.isEmpty ? Copy.nothingInReviewTab(shown) : Copy.noReviewsMatch(text))
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(items) { mr in
                ReviewRow(
                    mr: mr, group: shown, myState: list.myState(mr),
                    rereviewing: model.agentBusyKeys.contains(mr.key)
                ) {
                    Task { await model.queueAgentReview(mr.key) }
                }
                .tag(mr.key)
            }
        }
    }

    /// The selected MR, when it belongs to this page; the other page's selection is not shown here.
    private var shownKey: String? {
        guard let key = model.selectedKey, let list = model.list else { return model.selectedKey }
        return list.keys(in: scope).contains(key) ? key : nil
    }

    @ViewBuilder private var detail: some View {
        if let key = shownKey {
            if let detail = model.details[key] {
                MergeRequestDetailView(
                    detail: detail, error: model.detailErrors[key], model: model, fixes: fixes
                ) {
                    Task { await model.loadDetail(key) }
                }
                .id(key)
                .transition(.opacity)
            } else if let error = model.detailErrors[key] {
                VStack(spacing: 12) {
                    NoticeBox(text: error, tint: .red)
                    Button(Copy.reload) { Task { await model.loadDetail(key) } }
                }
                .padding(20)
            } else {
                ProgressView(Copy.loading)
            }
        } else if scope == .reviewing && model.list?.mergeRequests.isEmpty == true {
            ContentUnavailableView(Copy.allCaughtUp, systemImage: "checkmark.circle", description: Text(Copy.noReviewRequests))
        } else if scope == .mine && model.list?.yourMergeRequests.isEmpty == true {
            ContentUnavailableView(Copy.myMergeRequests, systemImage: "arrow.triangle.pull", description: Text(Copy.noOpenMRsOfYours))
        } else {
            ContentUnavailableView(
                Copy.selectMergeRequest, systemImage: "sidebar.left", description: Text(Copy.selectMergeRequestHint))
        }
    }
}

/// The tab switch over the top of the list, below the title bar. On macOS 26 the rows scroll under
/// both, which blur them as they pass; before it, a strip with a line under it.
private struct ListTopBar<Bar: View>: ViewModifier {
    let titleBar: CGFloat
    @ViewBuilder let bar: Bar

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .safeAreaBar(edge: .top, spacing: 0) { bar.padding(.top, titleBar) }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    bar
                    Divider()
                }
                .padding(.top, titleBar)
                .background(.bar)
            }
        }
    }
}

/// Reads `loadingList` on its own, so the list loading in the background redraws only this button.
private struct ListRefreshButton: View {
    let model: ReviewsModel
    let refresh: () async -> Void

    var body: some View {
        Button { Task { await refresh() } } label: {
            Label(Copy.refresh, systemImage: "arrow.clockwise")
        }
        .help("\(Copy.refresh) (⌘R)")
        .keyboardShortcut("r")
        .disabled(model.loadingList)
    }
}

/// Hands `content` whether the MR is loading, reading it on its own: each refresh loads the MR
/// again, and the page around these controls need not be drawn again for it.
private struct WhileLoading<Content: View>: View {
    let model: ReviewsModel
    let key: String
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(model.loadingKeys.contains(key)) }
}

private struct ReviewRow: View {
    let mr: ReviewSummary
    let group: ReviewGroup
    let myState: String?
    /// True while a review of this MR is being queued from the row.
    let rereviewing: Bool
    let onRereview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DisplayText.clean(mr.title, max: 160))
                .fontWeight(group == .waiting ? .semibold : .medium)
                .lineLimit(2)
            HStack(spacing: 4) {
                // Inside the Drafts group the heading already says it.
                if mr.draft && group != .drafts { Badge(text: Copy.draft, tint: .gray) }
                Text(DisplayText.clean(mr.author.name, max: 60)).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                // The key gives way first: when it was opened always stays readable.
                Text(DisplayText.shortKey(mr.key)).lineLimit(1).truncationMode(.head).layoutPriority(-1)
                if let opened = mr.createdDate {
                    Text("·")
                    Text(Copy.opened(opened.formatted(.relative(presentation: .named))))
                        .lineLimit(1)
                        .fixedSize()
                        .help(opened.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            if let review = mr.agentReview, let badge = shownAgentBadge(review) {
                Label(badge, systemImage: review.status == "queued" ? "hourglass" : "sparkles")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ReviewTint.agent(review.status))
            }
            if mr.readyToApprove {
                Label(Copy.readyToApprove, systemImage: "checkmark.seal")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
            if let change = mr.changedSinceReview {
                HStack(spacing: 6) {
                    Label(Copy.changedSinceReview(change), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if mr.offersRereview {
                        Button(Copy.rereviewNow, action: onRereview)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(rereviewing)
                            .help(Copy.reviewAgain)
                    }
                }
            }
            if let waiting = mr.rereviewWaiting,
                let line = Copy.rereviewWaiting(
                    waiting, dueTime: waiting.dueDate?.formatted(date: .omitted, time: .shortened))
            {
                Label(line, systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if shownState != nil || showsApprovals {
                HStack(spacing: 4) {
                    if let shownState {
                        Badge(text: Copy.yourState(shownState), tint: ReviewTint.reviewer(shownState))
                    }
                    let approvals = mr.approvals
                    if showsApprovals {
                        Label(Copy.approvals(approvals.approved, of: approvals.total), systemImage: "checkmark.seal")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(approvals.approved == approvals.total ? Color.green : Color.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// A failed run says nothing once you approved the MR yourself.
    private func shownAgentBadge(_ review: AgentReviewInfo) -> String? {
        if myState == "APPROVED" && review.status == "failed" { return nil }
        return Copy.agentReviewBadge(review.status)
    }

    /// "Not reviewed" says nothing the group does not: it is the state of every MR waiting for you.
    private var shownState: String? { myState == "UNREVIEWED" ? nil : myState }

    /// Only when someone besides you reviews it; "0/1 approved" about yourself is noise.
    private var showsApprovals: Bool { mr.approvals.total > (myState == nil ? 0 : 1) }
}

/// A small coloured label.
struct Badge: View {
    let text: String
    let tint: AnyShapeStyle
    var symbol: String?

    init(text: String, tint: some ShapeStyle, symbol: String? = nil) {
        self.text = text
        self.tint = AnyShapeStyle(tint)
        self.symbol = symbol
    }

    var body: some View {
        Group {
            if let symbol { Label(text, systemImage: symbol).labelStyle(BadgeLabelStyle()) } else { Text(text) }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(tint.opacity(0.15), in: Capsule())
    }
}

/// A badge's icon sits close to its text.
private struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// The MR's tabs as text with an accent underline under the one shown, its count beside it and a
/// dot when something there waits for you.
private struct DetailTabBar: View {
    struct Item {
        let tab: DetailTab
        let title: String
        var count: Int?
        var waiting = false
    }

    @Binding var selection: DetailTab
    let tabs: [Item]
    @Namespace private var underline
    @Environment(\.motionLevel) private var motion

    var body: some View {
        HStack(spacing: 22) {
            ForEach(tabs, id: \.tab) { item in
                let selected = item.tab == selection
                Button {
                    withAnimation(Motion.animation(Motion.content, motion)) { selection = item.tab }
                } label: {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .fontWeight(selected ? .semibold : .regular)
                            .foregroundStyle(selected ? .primary : .secondary)
                        if let count = item.count {
                            Text("\(count)")
                                .font(.caption.monospacedDigit().weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary.opacity(0.7), in: Capsule())
                        }
                        if item.waiting {
                            Circle().fill(.tint).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        if selected {
                            Capsule()
                                .fill(.tint)
                                .frame(height: 2)
                                .matchedGeometryEffect(id: "underline", in: underline)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.count.map { "\(item.title), \($0)" } ?? item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension EnvironmentValues {
    /// Set by an MR's page: a tab's scroll view collapses the page header once it is scrolled.
    @Entry var headerCollapsed: Binding<Bool>? = nil
}

extension View {
    /// Collapses the MR page's header once this scroll view leaves the top, and expands it near
    /// the top again; the gap between the two keeps it from flickering at the edge.
    func collapsesHeader() -> some View { modifier(CollapsesHeader()) }

    /// Text at a comfortable line length, at the leading edge of a wider page.
    func readableWidth() -> some View {
        frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CollapsesHeader: ViewModifier {
    @Environment(\.headerCollapsed) private var collapsed

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
            guard let collapsed else { return }
            if !collapsed.wrappedValue, offset > 48 { collapsed.wrappedValue = true }
            if collapsed.wrappedValue, offset < 4 { collapsed.wrappedValue = false }
        }
    }
}

// MARK: - Detail

private enum DetailTab: Hashable {
    case description, changes, comments, agent, fix
}

private struct MergeRequestDetailView: View {
    let detail: MergeRequestDetail
    let error: String?
    let model: ReviewsModel
    let fixes: FixesModel
    let onReload: () -> Void
    @State private var tab: DetailTab = .description
    @State private var confirmingApprove = false
    @State private var merging = false
    @State private var confirmingClose = false
    @State private var messaging = false
    /// Who the last Teams message from this page went to.
    @State private var messageNotice: String?
    @State private var collapsed = false
    @Environment(\.openURL) private var openURL

    private var agentReview: AgentReviewInfo? { model.agentReview(for: detail.key) }
    /// Your own MR: Agent Fix, a comment box and Merge instead of reviewing.
    private var yours: Bool { model.isYours(detail.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, collapsed ? 10 : 16)
                .padding(.bottom, collapsed ? 8 : 12)
                .motion(value: error)
                .motion(value: model.approvalNotices[detail.key])
                .motion(value: messageNotice)
                .motion(value: collapsed)
            DetailTabBar(selection: $tab, tabs: tabs)
            ZStack {
                switch tab {
                case .description: DescriptionTab(detail: detail)
                case .changes: ChangesTab(detail: detail)
                case .comments:
                    CommentsTab(detail: detail) {
                        if yours { CommentComposer(key: detail.key, fixes: fixes, onPosted: onReload) }
                    }
                case .agent: AgentReviewTab(key: detail.key, model: model)
                case .fix: FixTab(detail: detail, fixes: fixes)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .motion(Motion.page, value: tab)
            .environment(\.headerCollapsed, $collapsed)
        }
        .onChange(of: tab) { collapsed = false }
        // Links in text written by others open only when they are http(s).
        .environment(\.openURL, OpenURLAction { url in
            DisplayText.safeURL(url.absoluteString) == nil ? .discarded : .systemAction
        })
        .confirmationDialog(Copy.approveConfirmTitle, isPresented: $confirmingApprove) {
            Button(Copy.approveAction) { Task { await model.approve(detail.key) } }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.approveConfirmMessage(sha: detail.headSha ?? ""))
        }
        .confirmationDialog(Copy.closeConfirmTitle, isPresented: $confirmingClose) {
            Button(Copy.closeAction, role: .destructive) {
                Task {
                    if await fixes.close(key: detail.key) == "closed" {
                        await model.refresh()
                    } else {
                        onReload()
                    }
                }
            }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.closeConfirmMessage)
        }
        .sheet(isPresented: $messaging) {
            TeamsMessageSheet(detail: detail, model: model) { name in messageNotice = Copy.messageSent(name) }
        }
        .sheet(isPresented: $merging) {
            MergeSheet(detail: detail, fixes: fixes) {
                tab = .description
                onReload()
                Task { await model.refresh() }
            }
        }
    }

    private var tabs: [DetailTabBar.Item] {
        var items: [DetailTabBar.Item] = [
            .init(tab: .description, title: Copy.descriptionTab),
            .init(tab: .changes, title: Copy.changesTab, count: detail.files.count),
            .init(tab: .comments, title: Copy.commentsTab, count: detail.comments.count),
        ]
        if yours {
            items.append(.init(tab: .fix, title: Copy.fixTab, waiting: fixes.fix(for: detail.key)?.isReady == true))
        } else {
            items.append(.init(tab: .agent, title: Copy.agentReviewTab, waiting: agentReview?.isReady == true))
        }
        return items
    }

    /// The title, the actions and the facts about the MR; once the content is scrolled, only the
    /// title on one line and the actions, so more of the MR fits.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if collapsed {
                HStack(spacing: 12) {
                    title.font(.headline).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 12)
                    actions
                }
            } else {
                title.font(.title2.weight(.semibold))
                // The actions sit beside the facts while they fit, and beneath them otherwise, so a
                // long title is never squeezed into a narrow column beside them.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        facts
                        Spacer(minLength: 12)
                        actions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        facts
                        actions
                    }
                }
                chips
                if let pipeline = detail.pipeline { PipelineProgressView(pipeline: pipeline) }
            }
            if let error { NoticeBox(text: error, tint: .red) }
            if let messageNotice {
                NoticeBox(text: messageNotice, tint: .green) { self.messageNotice = nil }
            }
            if let notice = model.approvalNotices[detail.key] {
                NoticeBox(text: notice, tint: .secondary) { model.dismissApprovalNotice(detail.key) }
            }
            if yours, tab != .fix, let banner = fixes.banner {
                NoticeBox(text: banner, tint: .secondary, onClose: fixes.dismissBanner)
            }
        }
    }

    private var title: some View {
        Text(DisplayText.clean(detail.title, max: 300)).textSelection(.enabled)
    }

    /// Key, author and when it was last updated.
    private var facts: some View {
        HStack(spacing: 6) {
            if detail.draft { Badge(text: Copy.draft, tint: .gray) }
            Text(DisplayText.shortKey(detail.key))
                .textSelection(.enabled)
                .help(DisplayText.clean(detail.key, max: 120))
            Text("·").foregroundStyle(.tertiary)
            Text(Copy.byAuthor(DisplayText.clean(detail.author.name, max: 60)))
            if let date = detail.updatedDate {
                Text("·").foregroundStyle(.tertiary)
                Text(Copy.updated(date.formatted(.relative(presentation: .named))))
                    .help(date.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    private var actions: some View {
        WhileLoading(model: model, key: detail.key) { loading in actions(loading: loading) }
    }

    private func actions(loading: Bool) -> some View {
        HStack(spacing: 8) {
            if yours {
                let availability = mergeAvailability(detail)
                Button { merging = true } label: {
                    Label(availability == .whenPipelineSucceeds ? Copy.mergeWhenPipelineSucceeds : Copy.merge,
                          systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading || fixes.busyKeys.contains(detail.key))
                .help(blockedReason(availability) ?? "")
                Button {
                    tab = .fix
                    Task { await fixes.queueFix(detail.key) }
                } label: {
                    Label(Copy.fixFindingsNow, systemImage: "wand.and.stars")
                }
                .disabled(fixes.busyKeys.contains(detail.key) || fixes.fix(for: detail.key).map { $0.isActive || $0.isReady } == true)
                let watched = model.isWatched(detail.key)
                Button {
                    Task {
                        if await fixes.setWatched(detail.key, !watched) { model.showWatched(detail.key, !watched) }
                    }
                } label: {
                    Label(watched ? Copy.unwatch : Copy.watch, systemImage: watched ? "eye.slash" : "eye")
                }
                .help(watched ? Copy.unwatchHelp : Copy.watchHelp)
                .disabled(fixes.busyKeys.contains(detail.key))
                if detail.pipelineStatus == "FAILED" {
                    Button {
                        tab = .fix
                        Task { await fixes.queuePipelineFix(detail.key) }
                    } label: {
                        Label(Copy.fixPipelineNow, systemImage: "hammer")
                    }
                    .disabled(fixes.busyKeys.contains(detail.key) || fixes.fix(for: detail.key).map { $0.isActive || $0.isReady } == true)
                }
                Button(role: .destructive) { confirmingClose = true } label: {
                    Label(Copy.closeMR, systemImage: "xmark.circle")
                }
                .disabled(loading || fixes.busyKeys.contains(detail.key))
            } else if model.isApprovedByMe(detail) {
                Label(Copy.approvedByYou, systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.12), in: Capsule())
            } else if model.canApprove(detail) {
                Button { confirmingApprove = true } label: {
                    Label(Copy.approve, systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.approvingKeys.contains(detail.key) || loading)
            }
            if !yours && model.offersReview(for: detail.key) {
                Button {
                    tab = .agent
                    Task { await model.queueAgentReview(detail.key) }
                } label: {
                    Label(agentReview == nil ? Copy.reviewWithAgent : Copy.reviewAgain, systemImage: "sparkles")
                }
                .disabled(model.agentBusyKeys.contains(detail.key))
            }
            Button { messaging = true } label: {
                Label(Copy.messageOnTeams, systemImage: "bubble.left.and.text.bubble.right")
            }
            .help(Copy.messageOnTeamsHelp)
            if let url = DisplayText.safeURL(detail.url) {
                Button { openURL(url) } label: {
                    Label(Copy.openInGitLab, systemImage: "arrow.up.right.square")
                }
            }
            // The spinner takes the reload button's place while the MR loads.
            Button(action: onReload) {
                ZStack {
                    Image(systemName: "arrow.clockwise").opacity(loading ? 0 : 1)
                    if loading { ProgressView().controlSize(.mini) }
                }
                .frame(width: 16)
            }
            .help(Copy.reload)
            .accessibilityLabel(Copy.reload)
            .disabled(loading)
        }
        .fixedSize()
    }

    /// Branches, pipeline, squash, size, labels and Reviewers, wrapping when the row is full.
    private var chips: some View {
        FlowRow(spacing: 8) {
            Label(
                "\(DisplayText.clean(detail.sourceBranch, max: 80)) → \(DisplayText.clean(detail.targetBranch, max: 80))",
                systemImage: "arrow.triangle.branch"
            )
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: Capsule())
            // The pipeline's own strip shows it below; an older agent sends only the status.
            if detail.pipeline == nil, let status = detail.pipelineStatus {
                Badge(text: Copy.pipeline(status), tint: pipelineTint(status), symbol: pipelineSymbol(status))
            }
            if let squash = detail.squashOnMerge {
                Badge(text: squash ? Copy.squashOnMerge : Copy.noSquash, tint: squash ? .purple : .gray)
            }
            if let additions = detail.additions, let deletions = detail.deletions {
                HStack(spacing: 4) {
                    Text("+\(additions)").foregroundStyle(.green)
                    Text("−\(deletions)").foregroundStyle(.red)
                }
                .font(.caption.monospacedDigit().weight(.medium))
            }
            ForEach(detail.labels, id: \.self) { Badge(text: DisplayText.clean($0, max: 40), tint: .tint) }
            if !detail.reviewers.isEmpty {
                Text(Copy.reviewersHeading)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                ForEach(detail.reviewers, id: \.username) { reviewer in
                    Badge(
                        text: "\(DisplayText.clean(reviewer.name, max: 60)): \(Copy.reviewerState(reviewer.state))",
                        tint: ReviewTint.reviewer(reviewer.state),
                        symbol: reviewer.state == "APPROVED" ? "checkmark" : nil)
                }
            }
        }
    }

    private func blockedReason(_ availability: MergeAvailability) -> String? {
        if case .blocked(let reason) = availability { return reason }
        return nil
    }

    private func pipelineSymbol(_ status: String) -> String {
        switch status {
        case "SUCCESS": "checkmark.circle.fill"
        case "FAILED": "xmark.circle.fill"
        case "CANCELED": "slash.circle"
        case "RUNNING", "PENDING", "PREPARING", "WAITING_FOR_RESOURCE": "clock"
        default: "circle.dashed"
        }
    }

    private func pipelineTint(_ status: String) -> Color {
        switch status {
        case "SUCCESS": .green
        case "FAILED", "CANCELED": .red
        case "RUNNING", "PENDING", "PREPARING", "WAITING_FOR_RESOURCE": .blue
        default: .gray
        }
    }

}

enum ReviewTint {
    /// A ready review takes the accent colour, so it follows Appearance → Accent colour.
    static func agent(_ status: String) -> AnyShapeStyle {
        switch status {
        case "ready": AnyShapeStyle(.tint)
        case "posted": AnyShapeStyle(.green)
        case "failed": AnyShapeStyle(.red)
        default: AnyShapeStyle(.secondary)
        }
    }

    static func reviewer(_ state: String) -> Color {
        switch state {
        case "APPROVED": .green
        case "REQUESTED_CHANGES": .red
        case "REVIEWED", "REVIEW_STARTED": .blue
        default: .gray
        }
    }
}

/// Lays children out left to right and wraps to a new line when the row is full.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Tabs

private struct DescriptionTab: View {
    let detail: MergeRequestDetail

    var body: some View {
        ScrollView {
            Group {
                if detail.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(Copy.noDescription).foregroundStyle(.secondary)
                } else {
                    MarkdownText(source: detail.description, projectURL: detail.projectURL)
                }
            }
            .readableWidth()
            .padding(20)
        }
        .collapsesHeader()
    }
}

private struct ChangesTab: View {
    let detail: MergeRequestDetail
    @State private var collapsed: Set<String> = []
    @State private var parsed: [String: [DiffLine]] = [:]
    @Environment(\.motionLevel) private var motion

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if detail.filesTruncated {
                    NoticeBox(text: Copy.filesTruncated, tint: .orange).padding(12)
                }
                ForEach(detail.files) { file in
                    Section {
                        if !collapsed.contains(file.id) { lines(of: file) }
                    } header: {
                        fileHeader(file)
                    }
                }
            }
        }
        .collapsesHeader()
        // Parsed once per version of the MR, not on every redraw, and away from the main thread so a
        // large diff does not stall the page while it opens.
        .task(id: detail.updatedAt) {
            let files = detail.files
            let fresh = await Task.detached {
                Dictionary(
                    files.compactMap { file in file.diff.map { (file.id, parseDiffLines($0)) } },
                    uniquingKeysWith: { first, _ in first })
            }.value
            // A newer version of the MR may have arrived while this one was parsed.
            guard !Task.isCancelled else { return }
            parsed = fresh
        }
    }

    private func fileHeader(_ file: DiffFile) -> some View {
        let open = !collapsed.contains(file.id)
        return Button {
            withMotion(Motion.content, motion) {
                if open { collapsed.insert(file.id) } else { collapsed.remove(file.id) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .font(.caption.weight(.semibold))
                Text(path(file))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                if file.newFile { Badge(text: Copy.newFile, tint: .green) }
                if file.deletedFile { Badge(text: Copy.deletedFile, tint: .red) }
                if file.renamedFile { Badge(text: Copy.renamedFile, tint: .blue) }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityLabel(path(file))
        .accessibilityValue(open ? "expanded" : "collapsed")
    }

    private func path(_ file: DiffFile) -> String {
        let new = DisplayText.clean(file.newPath, max: 300)
        guard file.renamedFile else { return new }
        return "\(DisplayText.clean(file.oldPath, max: 300)) → \(new)"
    }

    @ViewBuilder private func lines(of file: DiffFile) -> some View {
        if file.diff == nil {
            Text(Copy.diffTooLarge)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
        } else if let lines = parsed[file.id] {
            ForEach(lines.indices, id: \.self) { DiffLineRow(line: lines[$0]) }
        }
    }
}

struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(line.text.isEmpty ? " " : line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(line.kind == .hunk || line.kind == .note ? Color.secondary : Color.primary)
        .padding(.vertical, 1)
        .background(background)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: .green.opacity(0.14)
        case .removed: .red.opacity(0.14)
        case .hunk: .blue.opacity(0.08)
        case .context, .note: .clear
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
            .foregroundStyle(.tertiary)
    }
}

private struct CommentsTab<Composer: View>: View {
    let detail: MergeRequestDetail
    /// Shown above the comments: the comment box on your own MRs.
    @ViewBuilder let composer: () -> Composer
    @State private var showActivity = false
    @Environment(\.motionLevel) private var motion

    private var shown: [MRDiscussion] { showActivity ? detail.discussions : detail.comments }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                composer()
                Toggle(Copy.showActivity, isOn: $showActivity.animation(Motion.animation(Motion.content, motion)))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                if detail.discussionsTruncated {
                    NoticeBox(text: Copy.discussionsTruncated, tint: .orange)
                }
                if shown.isEmpty {
                    Text(Copy.noComments).foregroundStyle(.secondary)
                }
                ForEach(shown) { discussion in
                    if discussion.isSystem {
                        ForEach(discussion.notes) { ActivityLine(note: $0) }
                    } else {
                        DiscussionCard(discussion: discussion, projectURL: detail.projectURL)
                    }
                }
            }
            .readableWidth()
            .padding(20)
        }
        .collapsesHeader()
    }
}

private struct DiscussionCard: View {
    let discussion: MRDiscussion
    let projectURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let first = discussion.notes.first, let file = first.filePath {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(first.line.map { "\(DisplayText.clean(file, max: 200)):\($0)" } ?? DisplayText.clean(file, max: 200))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    if discussion.resolvable {
                        Badge(
                            text: discussion.resolved ? Copy.resolved : Copy.unresolved,
                            tint: discussion.resolved ? .green : .orange)
                    }
                }
            } else if discussion.resolvable {
                HStack {
                    Spacer()
                    Badge(
                        text: discussion.resolved ? Copy.resolved : Copy.unresolved,
                        tint: discussion.resolved ? .green : .orange)
                }
            }
            ForEach(Array(discussion.notes.enumerated()), id: \.element.id) { index, note in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(DisplayText.clean(note.author.name, max: 60)).fontWeight(.semibold)
                        if let date = note.date {
                            Text(date.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    MarkdownText(source: note.body, projectURL: projectURL)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
        .opacity(discussion.resolved ? 0.7 : 1)
    }
}

private struct ActivityLine: View {
    let note: MRNote

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.tertiary)
            Text("\(DisplayText.clean(note.author.name, max: 60)) \(DisplayText.clean(note.body, max: 160))")
                .lineLimit(1)
            if let date = note.date {
                Text(date.formatted(.relative(presentation: .named))).foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct AgentReviewTab: View {
    let key: String
    let model: ReviewsModel
    @State private var confirmingPost = false

    var body: some View {
        let review = model.agentReview(for: key)
        let busy = model.agentBusyKeys.contains(key)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let banner = model.agentBanner { NoticeBox(text: banner, tint: .secondary, onClose: model.dismissAgentBanner) }
                if let review {
                    HStack(spacing: 8) {
                        if review.isActive { ProgressView().controlSize(.small) }
                        Text(Copy.agentReviewStatus(review.status)).font(.headline)
                            .foregroundStyle(ReviewTint.agent(review.status))
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                        if review.isReady {
                            Button(Copy.discardReview, role: .destructive) {
                                Task { await model.discardAgentReview(key) }
                            }
                            .disabled(busy)
                            Button(Copy.postToGitLab) { confirmingPost = true }
                                .buttonStyle(.borderedProminent)
                                .disabled(busy)
                        } else if review.isCancellable {
                            Button(Copy.cancelReview) { Task { await model.cancelAgentReview(key) } }
                                .disabled(busy)
                        } else if review.status == "failed" || review.status == "skipped" {
                            Button(Copy.discardReview) { Task { await model.discardAgentReview(key) } }
                                .disabled(busy)
                        }
                    }
                    HStack(spacing: 6) {
                        if review.previousSha != nil { Badge(text: Copy.agentRereviewLabel, tint: .purple) }
                        Text(Copy.agentReviewMeta(cli: review.cli, model: review.model, sha: review.headSha))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if review.status == "running" { ActivityFeed(lines: review.activity ?? []) }
                    if !review.detail.isEmpty {
                        NoticeBox(
                            text: DisplayText.clean(review.detail, max: 400),
                            tint: review.status == "failed" ? .red : .orange)
                    }
                    if let body = review.body, !body.isEmpty {
                        MarkdownText(source: body)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
                    }
                } else {
                    Text(Copy.noAgentReview).foregroundStyle(.secondary)
                }
            }
            .readableWidth()
            .padding(20)
            .motion(value: model.agentBanner)
        }
        .collapsesHeader()
        .confirmationDialog(Copy.postConfirmTitle, isPresented: $confirmingPost) {
            Button(Copy.postInline) { Task { await model.postAgentReview(key, inline: true) } }
            Button(Copy.postAsComment) { Task { await model.postAgentReview(key, inline: false) } }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.postConfirmMessage)
        }
    }
}

/// A running review's steps, oldest first and newest kept in view.
struct ActivityFeed: View {
    let lines: [ReviewActivityLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.activityHeading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if lines.isEmpty {
                            Text(Copy.activityStarting).foregroundStyle(.secondary)
                        }
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(line.date.formatted(date: .omitted, time: .standard))
                                    .foregroundStyle(.tertiary)
                                Text(DisplayText.clean(line.text, max: 200))
                                    .foregroundStyle(line.text.hasPrefix("Thinking:") ? .secondary : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(index)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                .onChange(of: lines.count) { _, count in
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
        }
    }
}

// MARK: - Markdown

/// GitLab Markdown, block by block (`parseMarkdownBlocks`): headings, lists and task lists,
/// quotes, fenced code, tables, rules and paragraphs, with inline styling and links from
/// Foundation's parser. Images show as links. Anything else is shown as written.
struct MarkdownText: View {
    let source: String
    /// Makes GitLab's `/uploads/…` links absolute; nil for text that is not from a project.
    var projectURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let blocks = MarkdownCache.blocks(source)
            ForEach(blocks.indices, id: \.self) { view(for: blocks[$0]) }
        }
        .lineSpacing(3)
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> Text { Self.inline(text, projectURL: projectURL) }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, level <= 2 ? 10 : 6)
        case .listItem(let text, let marker, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                    .frame(minWidth: 10, alignment: .trailing)
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let text):
            inline(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
        case .code(let text):
            CodeBlock(text: text)
        case .table(let table):
            MarkdownTableView(table: table, projectURL: projectURL)
        case .rule:
            Divider().padding(.vertical, 4)
        case .paragraph(let text):
            inline(text)
        }
    }

    static func inline(_ text: String, projectURL: String?) -> Text {
        Text(MarkdownCache.inline(text, projectURL: projectURL) { attributed(text, projectURL: projectURL) })
    }

    private static func attributed(_ text: String, projectURL: String?) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let source = inlineMarkdownSource(text, projectURL: projectURL)
        guard var attributed = try? AttributedString(markdown: source, options: options) else { return AttributedString(text) }
        // Inline code a size down on a tinted ground, so a line full of paths still reads as prose.
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(.callout, design: .monospaced)
            attributed[run.range].backgroundColor = Color.secondary.opacity(0.12)
        }
        return attributed
    }
}

/// Parsed Markdown by its text. The MR page redraws often (each refresh, the header folding, a tab
/// switch), and parsing a long review or comment thread again each time costs tens of milliseconds,
/// enough to drop frames.
@MainActor private enum MarkdownCache {
    private final class Entry<Value> {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private static let blockCache = limited(NSCache<NSString, Entry<[MarkdownBlock]>>())
    private static let inlineCache = limited(NSCache<NSString, Entry<AttributedString>>())

    private static func limited<Value>(_ cache: NSCache<NSString, Value>) -> NSCache<NSString, Value> {
        cache.countLimit = 2000
        return cache
    }

    static func blocks(_ source: String) -> [MarkdownBlock] {
        let key = source as NSString
        if let hit = blockCache.object(forKey: key) { return hit.value }
        let blocks = parseMarkdownBlocks(source)
        blockCache.setObject(Entry(blocks), forKey: key)
        return blocks
    }

    static func inline(_ text: String, projectURL: String?, make: () -> AttributedString) -> AttributedString {
        let key = "\(projectURL ?? "")\u{0}\(text)" as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.value }
        let attributed = make()
        inlineCache.setObject(Entry(attributed), forKey: key)
        return attributed
    }
}

/// Fenced code: monospaced on a tinted card that scrolls sideways, with a copy button.
private struct CodeBlock: View {
    let text: String
    @State private var copied = false

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(2)
                .padding(12)
                .padding(.trailing, 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.5)))
        .overlay(alignment: .topTrailing) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(Copy.copyCode)
            .accessibilityLabel(Copy.copyCode)
            .padding(6)
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// A GFM table: bold header, a rule under it and between rows, cells wrapping within the width.
private struct MarkdownTableView: View {
    let table: MarkdownTable
    let projectURL: String?

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
            row(table.header).font(.callout.weight(.semibold))
            Divider()
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, cells in
                if index > 0 { Divider().opacity(0.5) }
                row(cells).font(.callout)
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator.opacity(0.6)))
    }

    private func row(_ cells: [String]) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                let alignment = table.alignments[column]
                MarkdownText.inline(cell, projectURL: projectURL)
                    .multilineTextAlignment(Self.textAlignment(alignment))
                    .fixedSize(horizontal: false, vertical: true)
                    .gridColumnAlignment(Self.horizontalAlignment(alignment))
            }
        }
    }

    private static func textAlignment(_ alignment: MarkdownTable.Alignment) -> TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private static func horizontalAlignment(_ alignment: MarkdownTable.Alignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
