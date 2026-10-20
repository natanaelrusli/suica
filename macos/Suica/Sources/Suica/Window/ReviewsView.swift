import SuicaCore
import SwiftUI

/// Open MRs where you are a Reviewer: the list on the left, the selected MR on the right.
struct ReviewsView: View {
    let model: ReviewsModel

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 300)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.refresh() }
        // While a review is queued, running or being posted, read the list again until it is done.
        .task(id: model.hasActiveAgentReview) {
            while model.hasActiveAgentReview {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await model.refresh()
            }
        }
        .toolbar {
            Button { Task { await model.refresh() } } label: {
                Label(Copy.refresh, systemImage: "arrow.clockwise")
            }
            .help("\(Copy.refresh) (⌘R)")
            .keyboardShortcut("r")
            .disabled(model.loadingList)
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { model.selectedKey }, set: { key in Task { await model.select(key) } })
    }

    private var list: some View {
        List(selection: selection) {
            if let text = model.errorText {
                NoticeBox(text: text, tint: .red).listRowSeparator(.hidden)
            }
            if let list = model.list {
                let sections = list.sections
                if list.mergeRequests.isEmpty {
                    Label(Copy.noReviewRequests, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                } else if list.me != nil, sections.first?.group != .waiting {
                    Label(Copy.nothingWaiting, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(sections, id: \.group) { section in
                    if section.group == .all {
                        rows(section, in: list)
                    } else {
                        Section {
                            rows(section, in: list)
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }
            } else if model.errorText == nil {
                ProgressView(Copy.loading).frame(maxWidth: .infinity)
            }
        }
        .motion(value: model.list)
        .motion(value: model.errorText)
    }

    private func rows(_ section: ReviewSection, in list: ReviewListDocument) -> some View {
        ForEach(section.items) { mr in
            ReviewRow(
                mr: mr, group: section.group, myState: list.myState(mr),
                rereviewing: model.agentBusyKeys.contains(mr.key)
            ) {
                Task { await model.queueAgentReview(mr.key) }
            }
            .tag(mr.key)
        }
    }

    private func sectionHeader(_ section: ReviewSection) -> some View {
        HStack(spacing: 6) {
            Text(Copy.reviewGroup(section.group))
            Text("\(section.items.count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .foregroundStyle(section.group == .waiting ? Color.white : Color.secondary)
                .background(section.group == .waiting ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var detail: some View {
        if let key = model.selectedKey {
            if let detail = model.details[key] {
                MergeRequestDetailView(
                    detail: detail, loading: model.loadingKeys.contains(key),
                    error: model.detailErrors[key], model: model
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
        } else if model.list?.mergeRequests.isEmpty == true {
            ContentUnavailableView(Copy.allCaughtUp, systemImage: "checkmark.circle", description: Text(Copy.noReviewRequests))
        } else {
            ContentUnavailableView(
                Copy.selectMergeRequest, systemImage: "sidebar.left", description: Text(Copy.selectMergeRequestHint))
        }
    }
}

private struct ReviewRow: View {
    let mr: ReviewSummary
    let group: ReviewGroup
    let myState: String?
    /// True while a review of this MR is being queued from the row.
    let rereviewing: Bool
    let onRereview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(DisplayText.clean(mr.title, max: 160))
                .fontWeight(group == .waiting ? .semibold : .medium)
                .lineLimit(2)
            HStack(spacing: 4) {
                // Inside the Drafts group the heading already says it.
                if mr.draft && group != .drafts { Badge(text: Copy.draft, tint: .gray) }
                Text(DisplayText.clean(mr.author.name, max: 60)).lineLimit(1)
                Text("·").foregroundStyle(.tertiary)
                // The key gives way first: the author and the project's own name stay readable.
                Text(DisplayText.shortKey(mr.key)).lineLimit(1).truncationMode(.head).layoutPriority(-1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // On its own line, so a long name or key never cuts it off.
            if let opened = mr.createdDate {
                Text(Copy.opened(opened.formatted(.relative(presentation: .named))))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(opened.formatted(date: .abbreviated, time: .shortened))
            }
            if let review = mr.agentReview, let badge = Copy.agentReviewBadge(review.status) {
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
                    if mr.offersRereview {
                        Button(Copy.rereviewNow, action: onRereview)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(rereviewing)
                            .help(Copy.reviewAgain)
                    }
                }
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

    /// "Not reviewed" says nothing the group does not: it is the state of every MR waiting for you.
    private var shownState: String? { myState == "UNREVIEWED" ? nil : myState }

    /// Only when someone besides you reviews it; "0/1 approved" about yourself is noise.
    private var showsApprovals: Bool { mr.approvals.total > (myState == nil ? 0 : 1) }
}

/// A small coloured label.
struct Badge: View {
    let text: String
    let tint: AnyShapeStyle

    init(text: String, tint: some ShapeStyle) {
        self.text = text
        self.tint = AnyShapeStyle(tint)
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

// MARK: - Detail

private enum DetailTab: Hashable {
    case description, changes, comments, agent
}

private struct MergeRequestDetailView: View {
    let detail: MergeRequestDetail
    let loading: Bool
    let error: String?
    let model: ReviewsModel
    let onReload: () -> Void
    @State private var tab: DetailTab = .description
    @State private var confirmingApprove = false

    private var agentReview: AgentReviewInfo? { model.agentReview(for: detail.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Picker("", selection: $tab) {
                Text(Copy.descriptionTab).tag(DetailTab.description)
                Text(Copy.changesTab(detail.files.count)).tag(DetailTab.changes)
                Text(Copy.commentsTab(detail.comments.count)).tag(DetailTab.comments)
                Text(agentReview?.isReady == true ? "\(Copy.agentReviewTab) •" : Copy.agentReviewTab)
                    .tag(DetailTab.agent)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            Divider()
            ZStack {
                switch tab {
                case .description: DescriptionTab(detail: detail)
                case .changes: ChangesTab(detail: detail)
                case .comments: CommentsTab(detail: detail)
                case .agent: AgentReviewTab(key: detail.key, model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .motion(Motion.page, value: tab)
        }
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The title gets the full width; the actions sit on their own row beneath it, so a long
            // title is never squeezed into a narrow column beside them.
            Text(DisplayText.clean(detail.title, max: 300))
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if model.isApprovedByMe(detail) {
                    Badge(text: Copy.approvedByYou, tint: .green)
                } else if model.canApprove(detail) {
                    Button { confirmingApprove = true } label: {
                        Label(Copy.approve, systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.approvingKeys.contains(detail.key) || loading)
                }
                let busy = model.agentBusyKeys.contains(detail.key)
                if model.offersReview(for: detail.key) {
                    Button {
                        tab = .agent
                        Task { await model.queueAgentReview(detail.key) }
                    } label: {
                        Label(agentReview == nil ? Copy.reviewWithAgent : Copy.reviewAgain, systemImage: "sparkles")
                    }
                    .disabled(busy)
                }
                Button(action: onReload) { Image(systemName: "arrow.clockwise") }
                    .help(Copy.reload)
                    .accessibilityLabel(Copy.reload)
                    .disabled(loading)
                if let url = DisplayText.safeURL(detail.url) {
                    Link(destination: url) { Label(Copy.openInGitLab, systemImage: "arrow.up.right.square") }
                }
                Spacer(minLength: 0)
                if loading { ProgressView().controlSize(.small) }
            }
            if let error { NoticeBox(text: error, tint: .red) }
            if let notice = model.approvalNotices[detail.key] { NoticeBox(text: notice, tint: .secondary) }
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
            FlowRow {
                Label(
                    "\(DisplayText.clean(detail.sourceBranch, max: 80)) → \(DisplayText.clean(detail.targetBranch, max: 80))",
                    systemImage: "arrow.triangle.branch"
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                if let status = detail.pipelineStatus {
                    Badge(text: Copy.pipeline(status), tint: pipelineTint(status))
                }
                if let squash = detail.squashOnMerge {
                    Badge(text: squash ? Copy.squashOnMerge : Copy.noSquash, tint: squash ? .purple : .gray)
                }
                if let additions = detail.additions, let deletions = detail.deletions {
                    Text("+\(additions)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                    Text("−\(deletions)").font(.caption.monospacedDigit()).foregroundStyle(.red)
                }
                ForEach(detail.labels, id: \.self) { Badge(text: DisplayText.clean($0, max: 40), tint: .tint) }
            }
            if !detail.reviewers.isEmpty {
                FlowRow {
                    Text(Copy.reviewersHeading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(detail.reviewers, id: \.username) { reviewer in
                        Badge(
                            text: "\(DisplayText.clean(reviewer.name, max: 60)): \(Copy.reviewerState(reviewer.state))",
                            tint: ReviewTint.reviewer(reviewer.state))
                    }
                }
            }
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
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        // Parsed once per version of the MR, not on every redraw.
        .task(id: detail.updatedAt) {
            parsed = Dictionary(
                detail.files.compactMap { file in file.diff.map { (file.id, parseDiffLines($0)) } },
                uniquingKeysWith: { first, _ in first })
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
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in DiffLineRow(line: line) }
        }
    }
}

private struct DiffLineRow: View {
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

private struct CommentsTab: View {
    let detail: MergeRequestDetail
    @State private var showActivity = false
    @Environment(\.motionLevel) private var motion

    private var shown: [MRDiscussion] { showActivity ? detail.discussions : detail.comments }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                if let banner = model.agentBanner { NoticeBox(text: banner, tint: .secondary) }
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
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(Copy.postConfirmTitle, isPresented: $confirmingPost) {
            Button(Copy.postInline) { Task { await model.postAgentReview(key, inline: true) } }
            Button(Copy.postAsComment) { Task { await model.postAgentReview(key, inline: false) } }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.postConfirmMessage)
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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseMarkdownBlocks(source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> Text { Self.inline(text, projectURL: projectURL) }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        case .listItem(let text, let marker, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let text):
            inline(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text).font(.system(size: 11.5, design: .monospaced)).padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .table(let table):
            MarkdownTableView(table: table, projectURL: projectURL)
        case .rule:
            Divider().padding(.vertical, 4)
        case .paragraph(let text):
            inline(text)
        }
    }

    static func inline(_ text: String, projectURL: String?) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let source = inlineMarkdownSource(text, projectURL: projectURL)
        if let attributed = try? AttributedString(markdown: source, options: options) {
            return Text(attributed)
        }
        return Text(text)
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
