import SuicaCore
import SwiftUI

/// Opens a Lesson on the Lessons page, from a repeat marker on another page.
struct OpenLessonAction {
    let run: @MainActor (Int) -> Void

    @MainActor func callAsFunction(_ id: Int) { run(id) }
}

extension EnvironmentValues {
    /// Nil outside the main window: the marker then names the Lesson without a link.
    @Entry var openLesson: OpenLessonAction? = nil
}

/// "Flagged 3 times before, in `a`, `b`" under a finding that repeats a Lesson, with the Lesson's
/// title as a link to it. Shown to the Owner only: nothing of it is posted.
struct LessonRepeatMarker: View {
    let lessonId: Int
    let title: String
    let before: Int
    let repos: [String]
    @Environment(\.openLesson) private var openLesson

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.trianglehead.counterclockwise")
                .foregroundStyle(.brown)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(inlineCode(Copy.lessonRepeat(before: before, repos: repos)))
                    .foregroundStyle(.secondary)
                if let openLesson {
                    Button { openLesson(lessonId) } label: {
                        Label(DisplayText.clean(title, max: 120), systemImage: "book")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.link)
                    .help(Copy.openLesson)
                } else {
                    Text(DisplayText.clean(title, max: 120))
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The copy's backticks as code; the text as written when it does not parse.
func inlineCode(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

// MARK: - Page

/// Lessons of each Lesson Scope by weight, filtered by Topic and repo and searched; the selected
/// Lesson with its rule, related Lessons and occurrences, and Merge into… and Archive.
struct LessonsView: View {
    let model: LessonsModel
    let navigator: Navigator

    var body: some View {
        Group {
            if let list = model.list {
                if !list.enabled {
                    emptyPage(Copy.lessonsOffTitle, symbol: "book.closed", hint: Copy.lessonsOffHint,
                              action: Copy.turnOnLessons, pending: 0)
                } else if list.scopes.isEmpty {
                    emptyPage(Copy.noScopesTitle, symbol: "folder.badge.questionmark", hint: Copy.noScopesHint,
                              action: Copy.openLessonsSettings, pending: list.pending)
                } else if list.isEmpty {
                    emptyPage(Copy.nothingLearnedTitle, symbol: "book", hint: Copy.nothingLearnedHint,
                              action: nil, pending: list.pending)
                } else {
                    LessonsSplit(model: model)
                }
            } else if let error = model.errorText {
                VStack(alignment: .leading) {
                    NoticeBox(text: error, tint: .red, closable: false)
                    Button(Copy.reload) { Task { await model.refresh() } }
                    Spacer()
                }
                .padding(20)
            } else {
                ProgressView(Copy.loading)
            }
        }
        .motion(value: model.list?.enabled)
        .task {
            await model.refresh()
            if model.selectedId == nil, let first = model.shownScopes.first(where: { !$0.lessons.isEmpty })?.lessons.first {
                await model.select(first.id)
            }
        }
        .toolbar {
            Button { Task { await model.refresh() } } label: { Label(Copy.refresh, systemImage: "arrow.clockwise") }
                .help("\(Copy.refresh) (⌘R)")
                .keyboardShortcut("r")
                .disabled(model.loading)
        }
    }

    private func emptyPage(_ title: String, symbol: String, hint: String, action: String?, pending: Int) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            VStack(spacing: 6) {
                Text(hint)
                if pending > 0 { Text(Copy.lessonsPending(pending)).foregroundStyle(.secondary) }
            }
        } actions: {
            if let action {
                Button(action) { navigator.selection = .settings(ConfigCategory(key: "lessons")) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// The list on the left and the selected Lesson on the right.
private struct LessonsSplit: View {
    @Bindable var model: LessonsModel

    var body: some View {
        UnderTitleBar { titleBar in
            HStack(spacing: 0) {
                list(titleBar: titleBar)
                    .frame(width: 320)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, titleBar)
            }
        }
        .searchable(text: $model.filter.query, placement: .toolbar, prompt: Copy.searchLessons)
    }

    private var selection: Binding<Int?> {
        Binding(get: { model.selectedId }, set: { id in Task { await model.select(id) } })
    }

    private func list(titleBar: CGFloat) -> some View {
        let scopes = model.shownScopes
        let several = (model.list?.scopes.count ?? 0) > 1
        return List(selection: selection) {
            if let text = model.errorText {
                NoticeBox(text: text, tint: .red).listRowSeparator(.hidden)
            }
            if scopes.allSatisfy({ $0.lessons.isEmpty }) {
                Text(Copy.noLessonsMatch).foregroundStyle(.secondary).listRowSeparator(.hidden)
            }
            ForEach(scopes) { scope in
                Section {
                    if scope.lessons.isEmpty && model.filter == LessonFilter(scope: model.filter.scope) {
                        Text(Copy.noLessonsInScope).foregroundStyle(.secondary).listRowSeparator(.hidden)
                    }
                    ForEach(scope.lessons) { lesson in LessonRow(lesson: lesson).tag(lesson.id) }
                } header: {
                    if several || model.filter.scope == nil { scopeHeader(scope) }
                }
            }
            if let pending = model.list?.pending, pending > 0 {
                Label(Copy.lessonsPending(pending), systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        }
        .motion(value: model.filter)
        .modifier(ListTopBar(titleBar: titleBar) { filterBar(several: several) })
    }

    private func scopeHeader(_ scope: LessonScope) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
            Text(DisplayText.clean(scope.path, max: 200)).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            Text("\(Copy.lessonCount(scope.lessons.count)) · \(Copy.lessonScopeRepos(scope.repos))")
                .fixedSize()
        }
        .help(scope.path)
    }

    private func filterBar(several: Bool) -> some View {
        let list = model.list
        return HStack(spacing: 8) {
            if several {
                Picker(Copy.scopeFilter, selection: $model.filter.scope) {
                    Text(Copy.allScopes).tag(String?.none)
                    ForEach(list?.scopes ?? []) { scope in
                        Text(DisplayText.clean(URL(fileURLWithPath: scope.path).lastPathComponent, max: 60))
                            .help(scope.path)
                            .tag(Optional(scope.path))
                    }
                }
            }
            Picker(Copy.topicFilter, selection: $model.filter.topic) {
                Text(Copy.anyTopic).tag(String?.none)
                ForEach(list?.topics ?? [], id: \.self) { Text(DisplayText.clean($0, max: 60)).tag(Optional($0)) }
            }
            Picker(Copy.repoFilter, selection: $model.filter.repo) {
                Text(Copy.anyRepo).tag(String?.none)
                ForEach(list?.repos ?? [], id: \.self) { Text(DisplayText.clean($0, max: 80)).tag(Optional($0)) }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var detail: some View {
        if let document = model.selected, document.lesson.id == model.selectedId {
            LessonDetailView(lesson: document.lesson, model: model)
                .id(document.lesson.id)
                .transition(.opacity)
        } else if let error = model.detailError {
            VStack(spacing: 12) {
                NoticeBox(text: error, tint: .orange)
                if let banner = model.banner { NoticeBox(text: banner, tint: .secondary, onClose: model.dismissBanner) }
            }
            .padding(20)
        } else if model.selectedId != nil {
            ProgressView(Copy.loading)
        } else {
            VStack(spacing: 12) {
                if let banner = model.banner {
                    NoticeBox(text: banner, tint: .secondary, onClose: model.dismissBanner).padding(.horizontal, 20)
                }
                ContentUnavailableView(Copy.selectLesson, systemImage: "book", description: Text(Copy.selectLessonHint))
            }
        }
    }
}

private struct LessonRow: View {
    let lesson: LessonSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(DisplayText.clean(lesson.title, max: 160)).fontWeight(.medium).lineLimit(2)
            Text(DisplayText.clean(lesson.rule, max: 300))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 4) {
                Badge(text: "\(lesson.count)×", tint: .brown)
                    .accessibilityLabel(Copy.lessonFlaggedCount(lesson.count))
                Text(lesson.repos.map(DisplayText.shortKey).joined(separator: ", "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                Spacer(minLength: 0)
                if let seen = lesson.lastSeenDate {
                    Text(seen.formatted(.relative(presentation: .named))).fixedSize()
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail

private struct LessonDetailView: View {
    let lesson: LessonDetail
    let model: LessonsModel
    @Environment(\.openURL) private var openURL

    private var candidates: [LessonSummary] { model.list?.mergeCandidates(for: lesson) ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let banner = model.banner { NoticeBox(text: banner, tint: .secondary, onClose: model.dismissBanner) }
                header
                section(Copy.lessonRule, symbol: "text.quote") {
                    Text(DisplayText.cleanLines(lesson.rule, max: 1000))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !lesson.topics.isEmpty || !lesson.globs.isEmpty { topicsAndFiles }
                if !lesson.related.isEmpty { related }
                occurrences
            }
            .readableWidth()
            .padding(20)
            .motion(value: model.banner)
        }
        // Links in finding text are opened only when they are http(s).
        .environment(\.openURL, OpenURLAction { url in
            DisplayText.safeURL(url.absoluteString) == nil ? .discarded : .systemAction
        })
    }

    /// Each dialog hangs on its own button: two dialogs on one view may never present.
    private var mergeRequest: LessonMergeRequest? {
        model.mergeRequest.flatMap { $0.gone.id == lesson.id ? $0 : nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(DisplayText.clean(lesson.title, max: 200))
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if model.busy { ProgressView().controlSize(.small) }
                Menu(Copy.mergeLessonInto) {
                    if candidates.isEmpty { Text(Copy.noMergeCandidates) }
                    ForEach(candidates) { candidate in
                        Button(DisplayText.clean(candidate.title, max: 100)) {
                            model.mergeRequest = LessonMergeRequest(gone: lesson, keep: candidate)
                        }
                    }
                }
                .fixedSize()
                .disabled(model.busy || candidates.isEmpty)
                .help(Copy.mergeLessonHelp)
                .confirmationDialog(
                    Copy.mergeLessonTitle(lesson.title, into: mergeRequest?.keep.title ?? ""),
                    isPresented: Binding(get: { mergeRequest != nil }, set: { if !$0 { model.mergeRequest = nil } }),
                    presenting: mergeRequest
                ) { request in
                    Button(Copy.mergeLessonAction, role: .destructive) {
                        Task { await model.merge(request.gone.id, into: request.keep.id) }
                    }
                    Button(Copy.cancel, role: .cancel) {}
                } message: { _ in
                    Text(Copy.mergeLessonMessage)
                }
                Button(Copy.archiveLesson, role: .destructive) { model.archiveRequest = lesson.id }
                    .disabled(model.busy || lesson.archived)
                    .confirmationDialog(
                        Copy.archiveLessonTitle,
                        isPresented: Binding(
                            get: { model.archiveRequest == lesson.id }, set: { if !$0 { model.archiveRequest = nil } })
                    ) {
                        Button(Copy.archiveLesson, role: .destructive) { Task { await model.archive(lesson.id) } }
                        Button(Copy.cancel, role: .cancel) {}
                    } message: {
                        Text(Copy.archiveLessonMessage)
                    }
            }
            HStack(spacing: 6) {
                if lesson.archived { Badge(text: Copy.lessonArchived, tint: .gray, symbol: "archivebox") }
                Badge(text: Copy.lessonFlagged(lesson.count), tint: .brown)
                Text(Copy.lessonWeight(lesson.weight))
                if let seen = lesson.lastSeen.flatMap(parseISO) {
                    Text("·")
                    Text(seen.formatted(.relative(presentation: .named)))
                        .help(seen.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Label(DisplayText.clean(Copy.lessonScopeLabel(lesson.scope), max: 200), systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private var topicsAndFiles: some View {
        HStack(alignment: .top, spacing: 24) {
            if !lesson.topics.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    heading(Copy.lessonTopics, symbol: "tag")
                    FlowRow(spacing: 4) {
                        ForEach(lesson.topics, id: \.self) { Badge(text: DisplayText.clean($0, max: 40), tint: .brown) }
                    }
                }
            }
            if !lesson.globs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    heading(Copy.lessonFiles, symbol: "doc.on.doc")
                    Text(lesson.globs.map { DisplayText.clean($0, max: 80) }.joined(separator: "  "))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var related: some View {
        section(Copy.lessonRelated, symbol: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lesson.related) { other in
                    Button { Task { await model.open(other.id) } } label: {
                        Label(DisplayText.clean(other.title, max: 120), systemImage: "book")
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var occurrences: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(Copy.lessonOccurrences(lesson.occurrences.count), symbol: "mappin.and.ellipse")
            ForEach(Array(lesson.occurrences.enumerated()), id: \.offset) { _, occurrence in
                OccurrenceCard(occurrence: occurrence)
            }
        }
    }

    private func heading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            heading(title, symbol: symbol)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
        }
    }
}

private func parseISO(_ text: String) -> Date? {
    (try? Date(text, strategy: .iso8601))
        ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
}

private struct OccurrenceCard: View {
    let occurrence: LessonOccurrence

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let url = occurrence.mrURL {
                    Link(destination: url) {
                        Text(DisplayText.clean(occurrence.mrTitle, max: 120)).lineLimit(1)
                    }
                    .help(url.absoluteString)
                } else {
                    Text(DisplayText.clean(occurrence.mrTitle, max: 120)).lineLimit(1)
                }
                Text(DisplayText.shortKey(occurrence.mrKey))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                Spacer(minLength: 4)
                if !occurrence.severity.isEmpty {
                    Badge(text: DisplayText.clean(occurrence.severity, max: 20), tint: severityTint)
                }
                Badge(text: Copy.lessonOutcome(occurrence.outcome), tint: outcomeTint)
            }
            .font(.callout.weight(.medium))
            HStack(spacing: 6) {
                if let location = occurrence.location {
                    Text(DisplayText.clean(location, max: 200))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                if let date = occurrence.date {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).fixedSize()
                }
            }
            .foregroundStyle(.secondary)
            Text(DisplayText.cleanLines(occurrence.text, max: 1000))
                .font(.callout)
                .lineLimit(8)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
    }

    private var severityTint: Color {
        switch occurrence.severity {
        case "Blocker": .red
        case "Major": .orange
        case "Minor": .yellow
        default: .gray
        }
    }

    private var outcomeTint: Color {
        switch occurrence.outcome {
        case "changed", "fixed": .green
        case "replied": .blue
        case "not-fixed": .red
        case "partly-fixed": .orange
        default: .gray
        }
    }
}

// MARK: - Configuration → Lessons

/// The Claude Code hook and the MCP server, and exporting the vault, under Configuration → Lessons.
/// Install… shows the agent's plan and changes nothing until it is confirmed.
struct LessonsAgentSetupSection: View {
    let model: LessonsModel
    /// `lessons.vaultPath` as saved; Export vault now needs one.
    let vaultPath: String?

    var body: some View {
        Section {
            Text(Copy.lessonsAgentSetupHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.setupError {
                HStack(spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(Copy.lessonsStatusRetry) { Task { await model.refreshSetup() } }
                        .disabled(model.setupLoading)
                }
            }
            statusRow(Copy.lessonsHook, model.setup?.hook)
            statusRow(Copy.lessonsClaudeMCP, model.setup?.claude)
            statusRow(Copy.lessonsCodexMCP, model.setup?.codex)
            HStack(spacing: 8) {
                if model.setupIsBusy {
                    ProgressView().controlSize(.small).accessibilityLabel(Copy.lessonsWorking)
                }
                Spacer()
                // Each dialog hangs on its own button: two dialogs on one view may never present.
                Button(Copy.lessonsRemove, role: .destructive) { model.removeRequested = true }
                    .disabled(!model.canRemove)
                    .confirmationDialog(Copy.lessonsRemoveTitle, isPresented: Bindable(model).removeRequested) {
                        Button(Copy.lessonsRemoveAction, role: .destructive) { Task { await model.uninstall() } }
                        Button(Copy.cancel, role: .cancel) {}
                    } message: {
                        Text(Copy.lessonsRemoveMessage)
                    }
                Button(Copy.lessonsInstall) { Task { await model.beginInstall() } }
                    .disabled(!model.canInstall)
                    // Install moves the model to installing before its task starts, and closing the
                    // dialog only parks the plan: SwiftUI may close it before or after the button runs.
                    .confirmationDialog(Copy.lessonsInstallTitle, isPresented: confirming, presenting: plan) { _ in
                        Button(Copy.lessonsInstallAction) { model.confirmInstall() }
                        Button(Copy.cancel, role: .cancel) { model.cancelInstall() }
                    } message: { plan in
                        Text(Copy.lessonsInstallPlan(plan))
                    }
            }
            LabeledContent {
                Button(Copy.lessonsExportNow) { Task { await model.exportVault() } }
                    .disabled(vaultPath == nil || model.setupIsBusy)
            } label: {
                Text(Copy.lessonsVault)
                Text(vaultPath.map { DisplayText.clean($0, max: 200) } ?? Copy.lessonsExportNeedsVault)
            }
            if let notice = model.setupNotice {
                NoticeBox(text: notice, tint: .secondary, onClose: model.dismissSetupNotice)
            }
        } header: {
            Label(Copy.lessonsAgentSetup, systemImage: "puzzlepiece.extension").font(.headline)
        }
        .motion(value: model.setupNotice)
        .task { await model.refreshSetup() }
    }

    /// The plan while the dialog shows it.
    private var plan: LessonsInstallPlan? {
        if case .confirming(let plan) = model.install { plan } else { nil }
    }

    private var confirming: Binding<Bool> {
        Binding(get: { plan != nil }, set: { if !$0 { model.installDialogClosed() } })
    }


    private func statusRow(_ title: String, _ installed: Bool?) -> some View {
        LabeledContent(title) {
            if let installed {
                Label(
                    installed ? Copy.lessonsInstalledMark : Copy.lessonsNotInstalledMark,
                    systemImage: installed ? "checkmark.circle.fill" : "circle.dashed"
                )
                .foregroundStyle(installed ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            } else if model.setupLoading {
                ProgressView().controlSize(.small).accessibilityLabel(Copy.loading)
            } else {
                Text(Copy.lessonsStatusUnknown).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Repeated findings

/// The findings of an Agent Review that repeat a Lesson, above the review's body: the app renders
/// the body as one piece of Markdown, so the markers are listed here by finding rather than
/// placed inside it.
struct RepeatedFindingsCard: View {
    let items: [RepeatedFinding]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label(Copy.repeatedFindings, systemImage: "arrow.trianglehead.counterclockwise")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.brown)
                Text(Copy.repeatedFindingsHint).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Copy.findingLabel(item.label)).font(.caption.weight(.semibold))
                        if let finding = item.finding {
                            if !finding.severity.isEmpty {
                                Badge(text: DisplayText.clean(finding.severity, max: 20), tint: .secondary)
                            }
                            Text("\(DisplayText.clean(finding.path, max: 200)):\(finding.line)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    if let finding = item.finding {
                        Text(inlineCode(DisplayText.clean(finding.title, max: 240)))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LessonRepeatMarker(
                        lessonId: item.lessonRepeat.lessonId, title: item.lessonRepeat.title,
                        before: item.lessonRepeat.before, repos: item.lessonRepeat.repos)
                }
                .padding(.leading, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brown.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.brown.opacity(0.3)))
    }
}
