import AppKit
import SuicaCore
import SwiftUI

struct ConfigurationView: View {
    let window: WindowModel
    let editor: ConfigEditorModel
    /// One category from the sidebar, or nil for every setting. A search looks through all of them.
    var category: ConfigCategory?
    /// Bumped by Discard so fields that hold text the model never saw start over too.
    @State private var generation = 0
    @State private var query = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let document = editor.document {
                form(document)
            } else if let text = editor.banner {
                VStack(alignment: .leading) {
                    NoticeBox(text: text, tint: .red)
                    Spacer()
                }
                .padding(20)
            } else {
                ProgressView(Copy.loading)
            }
        }
        .motion(value: editor.document == nil)
        .toolbar { toolbar }
        .task { await editor.load() }
        // The boxes that reported invalid text are destroyed with this view.
        .onDisappear { editor.clearInputInvalid() }
    }

    private func form(_ document: ConfigDocument) -> some View {
        Form {
            if let text = editor.banner { NoticeBox(text: DisplayText.clean(text, max: 600), tint: .red) }
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
            if let text = window.banner { NoticeBox(text: text, tint: .secondary) }
            if !document.exists {
                Label(Copy.configMissing, systemImage: "doc.badge.plus").foregroundStyle(.secondary)
            }
            if !document.issues.isEmpty { issues(document.issues) }
            let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
            let inScope = document.fields.filter { searching || category == nil || ConfigCategory.of($0) == category }
            let shown = groups(inScope.filter { editor.isShown($0, query: query) })
            if shown.isEmpty {
                ContentUnavailableView(
                    Copy.noSettingsMatch(DisplayText.clean(query, max: 60)), systemImage: "magnifyingglass",
                    description: Text(Copy.noSettingsMatchHint)
                )
                .frame(maxWidth: .infinity)
            }
            ForEach(shown, id: \.key) { group in
                Section {
                    ForEach(group.fields, id: \.path) { FieldEditor(field: $0, editor: editor) }
                } header: {
                    Label(group.title, systemImage: ConfigCategory(key: group.key).symbol).font(.headline)
                }
            }
        }
        .formStyle(.grouped)
        .searchable(text: $query, placement: .toolbar, prompt: Copy.searchSettings)
        .motion(value: query)
        .safeAreaInset(edge: .bottom) {
            if hasUnsavedInput {
                unsavedBar.transition(Motion.slide(from: .bottom, reduceMotion: reduceMotion))
            }
        }
        .motion(value: hasUnsavedInput)
        .motion(value: editor.restartSuggested)
        .motion(value: editor.banner)
        .motion(value: editor.saving)
        .motion(value: window.restarting)
        .id("\(generation)|\(document.sha256 ?? "")")
    }

    private var hasUnsavedInput: Bool { editor.isDirty || !editor.invalidInputKeys.isEmpty }

    private var unsavedBar: some View {
        HStack(spacing: 10) {
            Image(systemName: editor.invalidInputKeys.isEmpty ? "pencil.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(editor.invalidInputKeys.isEmpty ? Color.accentColor : Color.red)
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
        let key: String
        let title: String
        let fields: [ConfigField]
    }

    /// By the first path component, in the order the field list gives them; a top-level key
    /// (`statePath`) is Storage.
    private func groups(_ fields: [ConfigField]) -> [FieldGroup] {
        var order: [ConfigCategory] = []
        var byCategory: [ConfigCategory: [ConfigField]] = [:]
        for field in fields {
            let category = ConfigCategory.of(field)
            if byCategory[category] == nil { order.append(category) }
            byCategory[category, default: []].append(field)
        }
        return order.map { FieldGroup(key: $0.key, title: $0.title, fields: byCategory[$0] ?? []) }
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
