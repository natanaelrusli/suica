import SuicaCore
import SwiftUI

/// One of your own MRs in the list.
struct YourMRRow: View {
    let mr: YourMergeRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DisplayText.clean(mr.title, max: 160))
                .fontWeight(mr.fix?.status == "ready" ? .semibold : .medium)
                .lineLimit(2)
            HStack(spacing: 4) {
                if mr.draft { Badge(text: Copy.draft, tint: .gray) }
                Text(DisplayText.shortKey(mr.key)).lineLimit(1).truncationMode(.head)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            if let fix = mr.fix, fix.status != "discarded" {
                Label(Copy.fixBadge(fix), systemImage: fix.status == "queued" ? "hourglass" : "wand.and.stars")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ReviewTint.agent(fix.status == "pushed" ? "posted" : fix.status))
            }
            if mr.isWatched && !mr.approvedByAll {
                Label(Copy.watching, systemImage: "eye")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let pipeline = mr.pipeline, let mark = PipelineMark(pipeline) {
                Label(mark.text, systemImage: mark.symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(mark.tint)
            }
            let approvals = mr.approvals
            if approvals.total > 0 {
                Label(Copy.approvals(approvals.approved, of: approvals.total), systemImage: "checkmark.seal")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(mr.approvedByAll ? Color.green : Color.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// How a row of yours shows its head pipeline: failed, still running, or passed; nothing otherwise.
private struct PipelineMark {
    let text: String
    let symbol: String
    let tint: Color

    init?(_ pipeline: PipelineInfo) {
        if pipeline.hasFailed {
            (text, symbol, tint) = (Copy.pipelineFailed, "xmark.octagon.fill", .red)
        } else if pipeline.isRunning {
            (text, symbol, tint) = (Copy.pipelineRunning, "clock.arrow.circlepath", .orange)
        } else if pipeline.hasPassed {
            (text, symbol, tint) = (Copy.pipelinePassed, "checkmark.circle.fill", .green)
        } else {
            return nil
        }
    }
}

/// The Agent Fix of one of your MRs: what it is doing, or the change and replies waiting for you.
struct FixTab: View {
    let detail: MergeRequestDetail
    let fixes: FixesModel
    /// Your edits to the fix on screen; replaced whenever the fix or its status changes.
    @State private var draft: FixDraft?
    @State private var confirming = false
    @State private var retrying = false
    @State private var note = ""

    init(detail: MergeRequestDetail, fixes: FixesModel) {
        self.detail = detail
        self.fixes = fixes
        // Seeded here so the first frame already shows the fix; `load` keeps it current.
        _draft = State(initialValue: fixes.fix(for: detail.key).map(FixDraft.init))
    }

    /// The draft, only when it was made from this fix in this status.
    private func current(_ fix: FixInfo) -> FixDraft? {
        guard let draft, !draft.isStale(for: fix) else { return nil }
        return draft
    }

    var body: some View {
        let fix = fixes.fix(for: detail.key)
        let busy = fixes.busyKeys.contains(detail.key)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let banner = fixes.banner { NoticeBox(text: banner, tint: .secondary, onClose: fixes.dismissBanner) }
                if let fix {
                    header(fix, busy: busy)
                    if let pipeline = fix.pipeline { pipelineCard(pipeline) }
                    if fix.status == "running" { ActivityFeed(lines: fix.activity) }
                    if fix.status == "queued" { Text(Copy.fixQueued).foregroundStyle(.secondary) }
                    if fix.status == "confirming" { Text(Copy.fixConfirming).foregroundStyle(.secondary) }
                    if !fix.detail.isEmpty {
                        NoticeBox(
                            text: DisplayText.clean(fix.detail, max: 400),
                            tint: fix.status == "failed" || fix.status == "push-failed" ? .red : .orange)
                    }
                    if fix.status == "pushed" && fix.detail.isEmpty {
                        Text(Copy.fixPushedNote).foregroundStyle(.secondary)
                    }
                    if fix.isReady, let draft = current(fix) { readyBody(fix, draft: draft) }
                } else {
                    Text(Copy.fixNone).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .motion(value: fixes.banner)
        }
        .collapsesHeader()
        .task(id: fix.map { "\($0.id)-\($0.status)" }) { load(fix) }
        .confirmationDialog(confirmTitle(fix), isPresented: $confirming) {
            Button(fix?.diff?.isEmpty == false ? Copy.fixConfirm : Copy.fixConfirmRepliesOnly) {
                guard let fix, let draft = current(fix) else { return }
                Task { await fixes.confirm(fix, edits: draft.edits(for: fix)) }
            }
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.fixConfirmMessage)
        }
        .sheet(isPresented: $retrying) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Copy.fixRetryTitle).font(.headline)
                Text(Copy.fixRetryHint).font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .font(.body)
                    .frame(minHeight: 100)
                    .editorBox()
                HStack {
                    Spacer()
                    Button(Copy.cancel, role: .cancel) { retrying = false }
                    Button(Copy.fixRetryAction) {
                        retrying = false
                        guard let fix else { return }
                        Task { await fixes.retry(fix, note: note) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }

    private func header(_ fix: FixInfo, busy: Bool) -> some View {
        HStack(spacing: 8) {
            if fix.isActive { ProgressView().controlSize(.small) }
            Text(Copy.fixStatus(fix.status)).font(.headline)
                .foregroundStyle(ReviewTint.agent(fix.status == "pushed" ? "posted" : fix.status))
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if fix.isCancellable {
                Button(Copy.fixCancel) { Task { await fixes.cancel(fix) } }.disabled(busy)
            }
            if fix.hasMissingReplies {
                Button(Copy.fixPostMissing) { Task { await fixes.postMissingReplies(fix) } }.disabled(busy)
            }
            if fix.canRetry {
                Button(Copy.fixRetry) {
                    note = fix.note
                    retrying = true
                }
                .disabled(busy)
            }
            if fix.canDiscard {
                Button(Copy.fixDiscard, role: .destructive) { Task { await fixes.discard(fix) } }.disabled(busy)
            }
            if fix.isReady {
                Button(fix.diff?.isEmpty == false ? Copy.fixConfirm : Copy.fixConfirmRepliesOnly) { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || current(fix) == nil)
            }
        }
    }

    @ViewBuilder private func readyBody(_ fix: FixInfo, draft: FixDraft) -> some View {
        ForEach(fix.threads) { thread in threadCard(thread) }
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.fixCommitMessage).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if fix.diff?.isEmpty == false {
                TextEditor(text: Binding(get: { draft.commitMessage }, set: { self.draft?.commitMessage = $0 }))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60)
                    .editorBox()
            } else {
                Text(Copy.fixNoCodeChange).foregroundStyle(.secondary)
            }
        }
        ForEach(Array(draft.files.enumerated()), id: \.offset) { _, file in
            VStack(alignment: .leading, spacing: 0) {
                Text(DisplayText.clean(file.path, max: 300))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Divider() }
                ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in DiffLineRow(line: line) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
        }
    }

    /// The failed pipeline the fix works on: a link to it, its failed jobs, and the model's sentence.
    private func pipelineCard(_ pipeline: FixPipelineInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(Copy.fixPipelineHeading(pipeline.iid)).font(.callout.weight(.semibold))
                if let sha = pipeline.sha {
                    Text(sha.prefix(8)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = URL(string: pipeline.url), url.scheme == "https" || url.scheme == "http" {
                    Link(Copy.openInGitLab, destination: url).font(.caption)
                }
            }
            if pipeline.jobs.isEmpty {
                Text(Copy.fixPipelineWaiting).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(pipeline.jobs.enumerated()), id: \.offset) { _, job in
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                    if let url = URL(string: job.url), url.scheme == "https" || url.scheme == "http" {
                        Link(DisplayText.clean(Copy.fixPipelineJob(name: job.name, stage: job.stage), max: 200), destination: url)
                    } else {
                        Text(DisplayText.clean(Copy.fixPipelineJob(name: job.name, stage: job.stage), max: 200))
                    }
                }
                .font(.callout.monospaced())
            }
            if !pipeline.summary.isEmpty {
                Text(DisplayText.clean(pipeline.summary, max: 600)).font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
    }

    private func threadCard(_ thread: FixThreadInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let file = thread.filePath {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(thread.line.map { "\(DisplayText.clean(file, max: 200)):\($0)" } ?? DisplayText.clean(file, max: 200))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                Badge(
                    text: thread.action == "changed" ? Copy.fixChangedBadge : Copy.fixReplyBadge,
                    tint: thread.action == "changed" ? .green : .blue)
            }
            ForEach(Array(thread.notes.enumerated()), id: \.offset) { _, note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(DisplayText.clean(note.author.name, max: 60)).font(.caption.weight(.semibold))
                    MarkdownText(source: note.body)
                }
            }
            if let lesson = thread.lessonRepeat {
                LessonRepeatMarker(
                    lessonId: lesson.lessonId, title: lesson.title, before: lesson.before, repos: lesson.repos)
            }
            Divider()
            if thread.reply.isEmpty && thread.action == "reply" {
                Text(Copy.fixNoAnswer).font(.caption).foregroundStyle(.orange)
            }
            TextEditor(text: binding(for: thread))
                .font(.body)
                .frame(minHeight: 54)
                .editorBox()
                .disabled(draft?.skipped.contains(thread.id) == true)
                .opacity(draft?.skipped.contains(thread.id) == true ? 0.5 : 1)
                .accessibilityLabel(Copy.fixReplyPlaceholder)
            Toggle(Copy.fixDontPost, isOn: skipBinding(for: thread))
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
    }

    private func binding(for thread: FixThreadInfo) -> Binding<String> {
        Binding(get: { draft?.replies[thread.id] ?? thread.reply }, set: { draft?.replies[thread.id] = $0 })
    }

    private func skipBinding(for thread: FixThreadInfo) -> Binding<Bool> {
        Binding(
            get: { draft?.skipped.contains(thread.id) == true },
            set: { if $0 { draft?.skipped.insert(thread.id) } else { draft?.skipped.remove(thread.id) } })
    }

    /// Starts the edits again from the fix as the agent wrote it whenever the fix or its status changed.
    private func load(_ fix: FixInfo?) {
        guard let fix else { return }
        if draft?.isStale(for: fix) ?? true { draft = FixDraft(fix) }
    }

    private func confirmTitle(_ fix: FixInfo?) -> String {
        guard let fix, let draft = current(fix) else { return "" }
        let posts = draft.edits(for: fix).threads.filter(\.post).count
        return Copy.fixConfirmTitle(branch: detail.sourceBranch, replies: posts, changes: fix.diff?.isEmpty == false)
    }
}

/// Posts a general comment on one of your MRs.
struct CommentComposer: View {
    let key: String
    let fixes: FixesModel
    let onPosted: () -> Void
    @State private var text = ""
    @State private var previewing = false

    var body: some View {
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            if previewing {
                MarkdownText(source: blank ? " " : text)
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
            } else {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 70)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(Copy.commentPlaceholder).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .editorBox()
            }
            HStack {
                Toggle(Copy.commentPreview, isOn: $previewing).toggleStyle(.switch).controlSize(.small)
                Spacer()
                if fixes.busyKeys.contains(key) { ProgressView().controlSize(.small) }
                Button(Copy.commentSend) {
                    let body = text
                    Task {
                        if await fixes.comment(key: key, body: body) {
                            text = ""
                            previewing = false
                            onPosted()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(blank || fixes.busyKeys.contains(key))
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
    }
}

/// Picks squash, source branch and message, then merges at the commit on screen.
struct MergeSheet: View {
    let detail: MergeRequestDetail
    let fixes: FixesModel
    let onDone: () -> Void
    @State private var choice: MergeChoice
    /// The commit on screen when the sheet opened; a newer push is never merged from here.
    @State private var openedSha: String?
    @Environment(\.dismiss) private var dismiss

    init(detail: MergeRequestDetail, fixes: FixesModel, onDone: @escaping () -> Void) {
        self.detail = detail
        self.fixes = fixes
        self.onDone = onDone
        _choice = State(initialValue: MergeChoice(for: detail, availability: mergeAvailability(detail)))
        _openedSha = State(initialValue: detail.headSha)
    }

    var body: some View {
        let availability = mergeAvailability(detail)
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.mergeTitle).font(.headline)
            Text(DisplayText.clean(detail.title, max: 200)).foregroundStyle(.secondary)
            Toggle(Copy.mergeSquash, isOn: $choice.squash)
                .disabled(detail.squashReadOnly == true)
                .help(detail.squashReadOnly == true ? Copy.mergeSquashLocked : "")
                .onChange(of: choice.squash) { _, squash in
                    choice.message = MergeChoice.defaultMessage(detail, squash: squash)
                }
            Toggle(Copy.mergeRemoveBranch, isOn: $choice.removeSourceBranch)
            Text(Copy.mergeMessage).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $choice.message)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80)
                .editorBox()
            if let sha = openedSha {
                Text(Copy.mergeSha(sha)).font(.caption).foregroundStyle(.secondary)
            }
            if mergeSha(opened: openedSha, current: detail.headSha) == nil {
                NoticeBox(text: Copy.mergeNewCommits, tint: .orange)
            }
            if case .blocked(let reason) = availability {
                NoticeBox(text: reason, tint: .orange)
            }
            HStack {
                Spacer()
                Button(Copy.cancel, role: .cancel) { dismiss() }
                Button(availability == .whenPipelineSucceeds ? Copy.mergeWhenPipelineSucceeds : Copy.mergeNow) {
                    guard let sha = mergeSha(opened: openedSha, current: detail.headSha) else { return }
                    var picked = choice
                    picked.whenPipelineSucceeds = availability == .whenPipelineSucceeds
                    Task {
                        await fixes.merge(key: detail.key, sha: sha, choice: picked)
                        dismiss()
                        onDone()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isBlocked(availability) || fixes.busyKeys.contains(detail.key)
                        || mergeSha(opened: openedSha, current: detail.headSha) == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func isBlocked(_ availability: MergeAvailability) -> Bool {
        if case .blocked = availability { return true }
        return false
    }
}

extension View {
    /// A plain text editor with an inset and a thin border, like a text field.
    func editorBox() -> some View {
        scrollContentBackground(.hidden)
            .padding(6)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}
