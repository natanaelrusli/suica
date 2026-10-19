import AppKit
import SuicaCore
import SwiftUI

/// The Teams message templates: pick one, edit it, see it as Teams will show it, save or go back
/// to the built-in text. Saving goes through the CLI, which checks it the way the agent does.
struct TemplatesView: View {
    let model: TemplateEditorModel
    let window: WindowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let document = model.document {
                HStack(spacing: 0) {
                    list(document)
                        .frame(width: 230)
                    Divider()
                    if let template = model.selected {
                        editor(template, document: document)
                            .id(template.name)
                    }
                }
            } else if let text = model.banner {
                VStack(alignment: .leading) {
                    NoticeBox(text: text, tint: .red)
                    Spacer()
                }
                .padding(20)
            } else {
                ProgressView(Copy.loading)
            }
        }
        .task { await model.load() }
        .toolbar {
            Button(action: openFolder) { Label(Copy.openTemplates, systemImage: "folder") }
                .help(Copy.openTemplates)
                .disabled(model.document == nil)
        }
    }

    private func list(_ document: TemplatesDocument) -> some View {
        List(selection: Binding(get: { model.selectedName }, set: { model.selectedName = $0 ?? model.selectedName })) {
            ForEach(document.templates) { template in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(Copy.templateTitle(template.name)).fontWeight(.medium).lineLimit(1)
                        if model.isDirty(template) {
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                                .accessibilityLabel(Copy.unsavedChanges)
                        }
                    }
                    Badge(
                        text: template.custom ? Copy.templateCustom : Copy.templateBuiltIn,
                        tint: template.custom ? .purple : .gray)
                }
                .padding(.vertical, 2)
                .tag(template.name)
            }
        }
    }

    private func editor(_ template: MessageTemplate, document: TemplatesDocument) -> some View {
        let text = Binding(get: { model.text(of: template) }, set: { model.setText($0, for: template) })
        let unknown = model.unknownPlaceholders(in: template)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.restartSuggested { restartBar }
                if let banner = model.banner { NoticeBox(text: banner, tint: .secondary) }
                if let issue = model.issue { NoticeBox(text: issue, tint: .red) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(Copy.templateTitle(template.name)).font(.title2.weight(.semibold))
                    Text(Copy.templateWhen(template.name)).foregroundStyle(.secondary)
                }
                HStack {
                    Menu(Copy.templateInsert) {
                        ForEach(document.placeholders, id: \.self) { name in
                            Button("{{\(name)}} — \(Copy.placeholderHelp(name))") {
                                model.setText(model.text(of: template) + "{{\(name)}}", for: template)
                            }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    if model.saving { ProgressView().controlSize(.small) }
                    Button(Copy.templateRevert) { model.revert(template) }
                        .disabled(!model.isDirty(template) || model.saving)
                    Button(Copy.templateResetToDefault) { Task { await model.resetToDefault(template) } }
                        .disabled(!template.custom || model.saving)
                        .help(template.defaultText)
                    Button(Copy.save) { Task { await model.save(template) } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s")
                        .disabled(!model.canSave(template))
                }
                TextEditor(text: text)
                    .font(.body.monospaced())
                    .frame(minHeight: 140)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    .accessibilityLabel(Copy.templateTitle(template.name))
                if !unknown.isEmpty {
                    Label(Copy.templateUnknown(unknown), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Text(Copy.templateHint).font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Copy.teamsPreviewHeading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TeamsMessagePreview(
                        recipient: TemplatePreview.recipient, text: TemplatePreview.render(model.text(of: template)))
                        .frame(maxWidth: 520)
                    Text(Copy.templatePreviewNote(TemplatePreview.recipient)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .motion(value: model.restartSuggested)
            .motion(value: model.banner)
            .motion(value: model.issue)
        }
    }

    private var restartBar: some View {
        HStack {
            Label(Copy.restartToApply, systemImage: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
            Spacer()
            if window.restarting { ProgressView().controlSize(.small) }
            Button(Copy.restartAgent) {
                Task { if await window.restartAgent() { model.restartHandled() } }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(window.restarting)
        }
        .transition(Motion.reveal(reduceMotion: reduceMotion))
    }

    /// Shows the folder in Finder; the files are plain text and can be edited there too.
    private func openFolder() {
        guard let path = model.document?.path else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
}
