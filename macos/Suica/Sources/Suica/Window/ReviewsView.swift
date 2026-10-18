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
            .help(Copy.refresh)
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
                } else if list.me != nil, sections.first?.group != .waiting {
                    Label(Copy.nothingWaiting, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
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
            ReviewRow(mr: mr, group: section.group, myState: list.myState(mr)).tag(mr.key)
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
                .background(section.group == .waiting ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
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
        } else {
            Text(Copy.selectMergeRequest).foregroundStyle(.secondary)
        }
    }
}

private struct ReviewRow: View {
    let mr: ReviewSummary
    let group: ReviewGroup
    let myState: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(DisplayText.clean(mr.title, max: 160))
                .fontWeight(group == .waiting ? .semibold : .medium)
                .lineLimit(2)
            HStack(spacing: 4) {
                // Inside the Drafts group the heading already says it.
                if mr.draft && group != .drafts { Badge(text: Copy.draft, tint: .gray) }
                Text(DisplayText.clean(mr.author.name, max: 60))
                Text("·").foregroundStyle(.tertiary)
                Text(Self.shortKey(mr.key)).lineLimit(1).truncationMode(.head)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let review = mr.agentReview, let badge = Copy.agentReviewBadge(review.status) {
                Label(badge, systemImage: review.status == "queued" ? "hourglass" : "sparkles")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ReviewTint.agent(review.status))
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

    /// `group/sub/project!12` as `project!12`.
    static func shortKey(_ key: String) -> String {
        DisplayText.clean(String(key.split(separator: "/").last ?? Substring(key)), max: 60)
    }
}

/// A small coloured label.
struct Badge: View {
    let text: String
    let tint: Color

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
            HStack(alignment: .firstTextBaseline) {
                Text(DisplayText.clean(detail.title, max: 300))
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
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
                if agentReview?.canRequeue ?? true {
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
            }
            if let error { NoticeBox(text: error, tint: .red) }
            if let notice = model.approvalNotices[detail.key] { NoticeBox(text: notice, tint: .secondary) }
            HStack(spacing: 6) {
                if detail.draft { Badge(text: Copy.draft, tint: .gray) }
                Text(DisplayText.clean(detail.key, max: 120)).textSelection(.enabled)
                Text("·").foregroundStyle(.tertiary)
                Text(Copy.byAuthor(DisplayText.clean(detail.author.name, max: 60)))
                if let date = detail.updatedDate {
                    Text("·").foregroundStyle(.tertiary)
                    Text(date.formatted(.relative(presentation: .named)))
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
                ForEach(detail.labels, id: \.self) { Badge(text: DisplayText.clean($0, max: 40), tint: .accentColor) }
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
    static func agent(_ status: String) -> Color {
        switch status {
        case "ready": .accentColor
        case "posted": .green
        case "failed": .red
        default: .secondary
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
                    MarkdownText(source: detail.description)
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
            withAnimation(Motion.content) {
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

    private var shown: [MRDiscussion] { showActivity ? detail.discussions : detail.comments }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(Copy.showActivity, isOn: $showActivity.animation(Motion.content))
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
                        DiscussionCard(discussion: discussion)
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
                    MarkdownText(source: note.body)
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
                        } else if review.status == "failed" || review.status == "skipped" {
                            Button(Copy.discardReview) { Task { await model.discardAgentReview(key) } }
                                .disabled(busy)
                        }
                    }
                    Text(Copy.agentReviewMeta(cli: review.cli, model: review.model, sha: review.headSha))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            Button(Copy.post) { Task { await model.postAgentReview(key) } }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.postConfirmMessage)
        }
    }
}

// MARK: - Markdown

/// GitLab Markdown, block by block: headings, lists, quotes, fenced code and paragraphs, with
/// inline styling and links from Foundation's parser. Anything else is shown as written.
struct MarkdownText: View {
    let source: String

    private enum Block {
        case heading(Int, String)
        /// `marker` is "•" for an unordered item and the number with its dot for an ordered one.
        case bullet(String, marker: String, indent: Int)
        case quote(String)
        case code(String)
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        case .bullet(let text, let marker, let indent):
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
        case .paragraph(let text):
            inline(text)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }

    private static func blocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.isEmpty {
                flush()
            } else if let match = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flush()
                blocks.append(.heading(match.1.count, String(match.2)))
            } else if let match = line.firstMatch(of: /^(\s*)([-*+]|\d+[.)])\s+(.*)$/) {
                flush()
                // Numbers stay: a review's findings are answered by number ("fix 2 and 5").
                let marker = match.2.first?.isNumber == true ? String(match.2) : "•"
                blocks.append(.bullet(String(match.3), marker: marker, indent: match.1.count / 2))
            } else if trimmed.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
