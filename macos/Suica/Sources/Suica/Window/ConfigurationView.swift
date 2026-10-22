import AppKit
import SuicaCore
import SwiftUI

struct ConfigurationView: View {
    let window: WindowModel
    let editor: ConfigEditorModel
    /// For the installed skills and the models that Review skill and Review model are picked from.
    let reviews: ReviewsModel
    let navigator: Navigator
    /// One category from the sidebar, or nil for the overview of all of them. A search looks
    /// through every setting.
    var category: ConfigCategory?
    /// Bumped by Discard so fields that hold text the model never saw start over too.
    @State private var generation = 0
    @State private var query = ""
    /// Overview cards per row, from the page's width.
    @State private var columns = 4
    /// The drawer's section while it is open.
    @State private var picking: ReviewPickerPart?
    @State private var options: ReviewOptionsLoader?
    @Environment(\.motionLevel) private var motion
    @Environment(\.metrics) private var metrics

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Group {
            if let document = editor.document {
                Group {
                    if category == nil && !searching {
                        overview(document)
                    } else {
                        form(document)
                    }
                }
                .searchable(text: $query, placement: .toolbar, prompt: Copy.searchSettings)
                .motion(value: searching)
                .safeAreaInset(edge: .bottom) {
                    if hasUnsavedInput {
                        unsavedBar.transition(Motion.slide(from: .bottom, motion))
                    }
                }
                .motion(value: hasUnsavedInput)
            } else if let text = editor.banner {
                VStack(alignment: .leading) {
                    NoticeBox(text: text, tint: .red, closable: false)
                    Spacer()
                }
                .padding(20)
            } else {
                ProgressView(Copy.loading)
            }
        }
        .motion(value: editor.document == nil)
        .toolbar { toolbar }
        .inspector(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } })) {
            if let picking, let options, let document = editor.document { reviewPicker(picking, options, document) }
        }
        .task { await editor.load() }
        // The fields name the picked skill and model; the drawer reads them again as it opens.
        .task(id: draftedModelCli) {
            if options == nil { options = reviews.optionsLoader() }
            await options?.load(cli: draftedModelCli)
        }
        // The boxes that reported invalid text are destroyed with this view.
        .onDisappear { editor.clearInputInvalid() }
    }

    /// Banners, the restart suggestion and the file's problems, above the overview or the form.
    @ViewBuilder private func notices(_ document: ConfigDocument) -> some View {
        if let text = editor.banner {
            NoticeBox(text: DisplayText.clean(text, max: 600), tint: .red, onClose: editor.dismissBanner)
        }
        if editor.restartSuggested {
            HStack {
                Label(Copy.restartToApply, systemImage: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                if window.restarting { ProgressView().controlSize(.small) }
                Button(Copy.restartAgent, action: restart)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(window.restarting)
            }
        }
        if let text = window.banner { NoticeBox(text: text, tint: .secondary, onClose: window.dismissBanner) }
        if !document.exists {
            Label(Copy.configMissing, systemImage: "doc.badge.plus").foregroundStyle(.secondary)
        }
        if !document.issues.isEmpty { issues(document.issues) }
    }

    // MARK: Overview

    /// Configuration itself: one card per category, each opening its page; the settings live there.
    private func overview(_ document: ConfigDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.gap) {
                notices(document)
                Text(Copy.configOverviewHint).foregroundStyle(.secondary)
                // A Grid rather than a LazyVGrid, so every card in a row is as tall as the tallest.
                let cards = overviewCards(document)
                let gap = metrics.gap * 0.75
                Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                    ForEach(Array(stride(from: 0, to: cards.count, by: columns)), id: \.self) { start in
                        GridRow {
                            ForEach(start..<min(start + columns, cards.count), id: \.self) { index in
                                CategoryCard(card: cards[index], navigator: navigator)
                                    .frame(maxHeight: .infinity)
                                    .staggeredEntrance(index)
                            }
                            // Empty cells keep the last row's cards as wide as the others.
                            ForEach(0..<max(0, start + columns - cards.count), id: \.self) { _ in
                                Color.clear.gridCellUnsizedAxes(.vertical)
                            }
                        }
                    }
                }
                .onGeometryChange(for: Int.self) { proxy in
                    max(1, Int((proxy.size.width + gap) / (240 + gap)))
                } action: { columns = min($0, 4) }
            }
            .padding(metrics.gap + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .motion(value: editor.restartSuggested)
            .motion(value: editor.banner)
            .motion(value: window.banner)
            .motion(value: window.restarting)
        }
    }

    /// A card per category in the agent's order, then the pages Configuration also holds.
    private func overviewCards(_ document: ConfigDocument) -> [OverviewCard] {
        categories(document).map { category in
            let fields = document.fields.filter { ConfigCategory.of($0) == category }
            return OverviewCard(
                title: category.title, detail: Copy.categoryDetail(category.key), symbol: category.symbol,
                tint: category.tint, count: fields.count, unsaved: fields.filter(editor.isEdited).count,
                problems: fields.filter { editor.issue(of: $0) != nil }.count, item: .settings(category))
        } + [
            OverviewCard(
                title: Copy.messageTemplates, detail: Copy.messageTemplatesDetail, symbol: "text.bubble", tint: .blue,
                count: nil, unsaved: 0, problems: 0, item: .templates),
            OverviewCard(
                title: WindowSection.appearance.title, detail: Copy.appearanceDetail,
                symbol: WindowSection.appearance.symbol, tint: WindowSection.appearance.tint,
                count: nil, unsaved: 0, problems: 0, item: .section(.appearance)),
        ]
    }

    /// The categories the document has, in the agent's order.
    private func categories(_ document: ConfigDocument) -> [ConfigCategory] {
        var seen: [ConfigCategory] = []
        for field in document.fields where !seen.contains(ConfigCategory.of(field)) {
            seen.append(ConfigCategory.of(field))
        }
        return seen
    }

    // MARK: Form

    private func form(_ document: ConfigDocument) -> some View {
        Form {
            notices(document)
            let inScope = document.fields.filter { searching || category == nil || ConfigCategory.of($0) == category }
            let shown = groups(inScope.filter { editor.isShown($0, query: query) })
            if shown.isEmpty {
                ContentUnavailableView(
                    Copy.noSettingsMatch(DisplayText.clean(query, max: 60)), systemImage: "magnifyingglass",
                    description: Text(Copy.noSettingsMatchHint)
                )
                .frame(maxWidth: .infinity)
            }
            ForEach(shown, id: \.id) { group in
                Section {
                    rows(group.fields)
                } header: {
                    // On a category's own page its sections are named; a search names the category too.
                    let title = category == nil || searching
                        ? [group.category.title, group.title].compactMap { $0 }.joined(separator: " · ")
                        : group.title ?? group.category.title
                    Label(title, systemImage: group.category.symbol).font(.headline)
                }
            }
        }
        .formStyle(.grouped)
        .motion(value: query)
        .motion(value: editor.restartSuggested)
        .motion(value: editor.banner)
        .motion(value: window.banner)
        .motion(value: editor.saving)
        .motion(value: window.restarting)
        .id("\(generation)|\(document.sha256 ?? "")")
    }

    /// The fields of one section; working hours start and end share one row when both are shown.
    @ViewBuilder private func rows(_ fields: [ConfigField]) -> some View {
        let start = fields.first { $0.path == ["teams", "workingHours", "start"] }
        let end = fields.first { $0.path == ["teams", "workingHours", "end"] }
        let together = start != nil && end != nil
        ForEach(fields.filter { !(together && $0.path == end?.path) }, id: \.path) { field in
            if together, let start, let end, field.path == start.path {
                WorkingHoursEditor(start: start, end: end, editor: editor)
            } else {
                FieldEditor(
                    field: field, editor: editor, modelClis: window.status?.modelCli,
                    reviewOptions: options?.options, choose: { picking = $0 })
            }
        }
    }

    // MARK: Skill and model drawer

    /// Model CLI as drafted, so the drawer lists the models of an unsaved choice.
    private var draftedModelCli: String? {
        guard let field = editor.document?.fields.first(where: { $0.path == ["model", "cli"] }),
            case .string(let cli) = editor.value(of: field)
        else { return nil }
        return cli
    }

    /// Picks write drafts, saved with the rest of the form.
    private func reviewPicker(_ part: ReviewPickerPart, _ loader: ReviewOptionsLoader, _ document: ConfigDocument)
        -> some View
    {
        let skillField = document.fields.first { $0.path == ["review", "skill"] }
        let modelField = document.fields.first { $0.path == ["review", "model"] }
        let skill = Binding<String>(
            get: {
                guard let skillField else { return "" }
                if case .string(let name) = editor.value(of: skillField) { return name }
                if case .string(let name) = skillField.effective { return name }
                return ""
            },
            set: { name in if let skillField { editor.setText(skillField, name) } })
        let model = Binding<String?>(
            get: {
                guard let modelField, case .string(let name) = editor.value(of: modelField) else { return nil }
                return name
            },
            set: { name in if let modelField { editor.setText(modelField, name ?? "") } })
        return ReviewPicker(loader: loader, parts: [part], skill: skill, model: model, cli: draftedModelCli)
    }

    private var hasUnsavedInput: Bool { editor.isDirty || !editor.invalidInputKeys.isEmpty }

    private var unsavedBar: some View {
        HStack(spacing: 10) {
            Image(systemName: editor.invalidInputKeys.isEmpty ? "pencil.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(editor.invalidInputKeys.isEmpty ? AnyShapeStyle(.tint) : AnyShapeStyle(.red))
                .accessibilityHidden(true)
            Text(editor.invalidInputKeys.isEmpty ? Copy.unsavedChanges : Copy.fixInvalidInput)
            Spacer()
            if editor.saving { ProgressView().controlSize(.small) }
            Button(Copy.discard, action: discard)
            Button(Copy.save) { Task { await editor.save() } }
                .buttonStyle(.borderedProminent)
                .disabled(!editor.canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func discard() {
        editor.discard()
        generation += 1
    }

    private func issues(_ issues: [ConfigIssue]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(Copy.configIssuesHeading, systemImage: "exclamationmark.triangle.fill")
                .fontWeight(.semibold)
                .foregroundStyle(.red)
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                Text("\(DisplayText.clean(issue.path, max: 80)): \(DisplayText.clean(issue.message))")
                    .font(.callout)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private struct FieldGroup {
        let category: ConfigCategory
        /// The section within the category; nil for a category that is one section.
        let title: String?
        let fields: [ConfigField]
        var id: String { "\(category.key)|\(title ?? "")" }
    }

    /// By category, then by section within it, each in the order the field list first gives it.
    private func groups(_ fields: [ConfigField]) -> [FieldGroup] {
        var order: [String] = []
        var byGroup: [String: FieldGroup] = [:]
        for field in fields {
            let group = FieldGroup(category: ConfigCategory.of(field), title: Copy.configSection(field.path), fields: [])
            if byGroup[group.id] == nil {
                order.append(group.id)
                byGroup[group.id] = group
            }
            byGroup[group.id] = FieldGroup(
                category: group.category, title: group.title, fields: (byGroup[group.id]?.fields ?? []) + [field])
        }
        // Sections of one category stay together even when the field list interleaves them.
        let categoryOrder = order.compactMap { byGroup[$0]?.category }.reduce(into: [ConfigCategory]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        return categoryOrder.flatMap { category in order.compactMap { byGroup[$0] }.filter { $0.category == category } }
    }

    private func restart() {
        Task { if await window.restartAgent() { editor.restartHandled() } }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button(action: openConfig) { Label(Copy.openConfig, systemImage: "doc.text") }
                .help(Copy.openConfig)
                .disabled(editor.document?.exists != true)
            Button(action: openTemplates) { Label(Copy.openTemplates, systemImage: "folder") }
                .help(Copy.openTemplates)
                .disabled(window.status == nil)
            Button { Task { await editor.load() } } label: {
                Label(Copy.reload, systemImage: "arrow.clockwise")
            }
            .help(Copy.reload)
            Button(action: discard) {
                Label(Copy.discard, systemImage: "arrow.uturn.backward")
            }
            .help(Copy.discard)
            .disabled(!editor.isDirty && editor.invalidInputKeys.isEmpty)
            Button { Task { await editor.save() } } label: {
                Label(Copy.save, systemImage: "square.and.arrow.down")
            }
            .help(Copy.save)
            .keyboardShortcut("s")
            .disabled(!editor.canSave)
        }
    }

    private func openConfig() {
        guard let path = editor.document?.path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Shows the folder in Finder: the path comes from the config, and opening it could launch an app.
    private func openTemplates() {
        guard let path = window.status?.paths.templates else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// A page on the Configuration overview: what it holds, and anything waiting in it.
private struct OverviewCard {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    /// Nil for a page that is not a list of settings.
    let count: Int?
    let unsaved: Int
    let problems: Int
    let item: SidebarItem
}

private struct CategoryCard: View {
    let card: OverviewCard
    let navigator: Navigator
    @Environment(\.metrics) private var metrics

    var body: some View {
        Button { navigator.selection = card.item } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    SidebarIcon(symbol: card.symbol, tint: card.tint, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title).font(.headline).lineLimit(1)
                        Text(card.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if let count = card.count { Text(Copy.settingsCount(count)).foregroundStyle(.tertiary) }
                    if card.unsaved > 0 { Badge(text: Copy.unsavedCount(card.unsaved), tint: Color.accentColor) }
                    if card.problems > 0 { Badge(text: Copy.problemCount(card.problems), tint: .red) }
                }
                .font(.caption)
            }
            .padding(metrics.padding - 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .hoverLift(cornerRadius: 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
