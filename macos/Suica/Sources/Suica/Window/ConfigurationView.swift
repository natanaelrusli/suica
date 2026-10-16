import AppKit
import SuicaCore
import SwiftUI

struct ConfigurationView: View {
    let window: WindowModel
    let editor: ConfigEditorModel
    /// Bumped by Discard so fields that hold text the model never saw start over too.
    @State private var generation = 0

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
                    Text(Copy.restartToApply).foregroundStyle(.orange)
                    Spacer()
                    Button(Copy.restartAgent, action: restart).disabled(window.restarting)
                }
            }
            if let text = window.banner { NoticeBox(text: text, tint: .secondary) }
            if !document.exists { Text(Copy.configMissing).foregroundStyle(.secondary) }
            if !document.issues.isEmpty { issues(document.issues) }
            ForEach(groups(document.fields), id: \.key) { group in
                Section(group.title) {
                    ForEach(group.fields, id: \.path) { FieldEditor(field: $0, editor: editor) }
                }
            }
        }
        .formStyle(.grouped)
        .id("\(generation)|\(document.sha256 ?? "")")
    }

    private func issues(_ issues: [ConfigIssue]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Copy.configIssuesHeading).fontWeight(.semibold)
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
        var order: [String] = []
        var byKey: [String: [ConfigField]] = [:]
        for field in fields {
            let key = field.path.count > 1 ? field.path[0] : "\u{0}storage"
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(field)
        }
        return order.map { key in
            FieldGroup(
                key: key, title: key == "\u{0}storage" ? Copy.storage : Copy.groupHeading(key),
                fields: byKey[key] ?? [])
        }
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
            Button {
                editor.discard()
                generation += 1
            } label: {
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

    private func openTemplates() {
        guard let path = window.status?.paths.templates else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
