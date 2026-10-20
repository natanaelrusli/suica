import AppKit
import SuicaCore
import SwiftUI

/// The message templates: Teams messages, edited visually (or as Markdown) with emoji, GIFs and
/// variants and seen as Teams will show them; and your own notifications, a title and a body
/// seen as macOS will show them. Saving goes through the CLI, which checks it the way the agent
/// does.
struct TemplatesView: View {
    let model: TemplateEditorModel
    let window: WindowModel
    @Environment(\.motionLevel) private var motion
    @State private var controller = RichEditorController()
    /// Teams templates the Owner switched to the Markdown view.
    @State private var markdownView: Set<String> = []
    @State private var showingEmoji = false
    @State private var showingGIF = false
    @FocusState private var alertField: AlertField?
    /// Room for the preview beside the editor rather than beneath it.
    @State private var wide = false

    private enum AlertField { case title, body }

    var body: some View {
        Group {
            if let document = model.document {
                HStack(spacing: 0) {
                    list
                        .frame(width: 240)
                    Divider()
                    if let template = model.selected {
                        editor(template, document: document)
                            .id(template.name)
                    }
                }
            } else if let text = model.banner {
                VStack(alignment: .leading) {
                    NoticeBox(text: text, tint: .red, closable: false)
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

    // MARK: List

    private var list: some View {
        List(selection: Binding(get: { model.selectedName }, set: { model.selectedName = $0 ?? model.selectedName })) {
            Section(Copy.teamsMessagesSection) {
                ForEach(model.teamsTemplates) { row($0, symbol: "bubble.left.and.text.bubble.right") }
            }
            Section(Copy.alertsSection) {
                ForEach(model.alertTemplates) { row($0, symbol: "bell.badge") }
            }
        }
    }

    private func row(_ template: MessageTemplate, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(Copy.templateTitle(template.name)).fontWeight(.medium).lineLimit(1)
                    if model.isDirty(template) {
                        Circle().fill(.tint).frame(width: 6, height: 6)
                            .accessibilityLabel(Copy.unsavedChanges)
                    }
                }
                HStack(spacing: 4) {
                    Badge(
                        text: template.custom ? Copy.templateCustom : Copy.templateBuiltIn,
                        tint: template.custom ? .purple : .gray)
                    let count = TemplateVariants.split(model.text(of: template)).count
                    if !template.isAlert && count > 1 {
                        Badge(text: "\(count) \(Copy.variantsHeading.lowercased())", tint: .teal)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .tag(template.name)
    }

    // MARK: Editor

    private func editor(_ template: MessageTemplate, document: TemplatesDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.restartSuggested { restartBar }
                if let banner = model.banner { NoticeBox(text: banner, tint: .secondary, onClose: model.dismissBanner) }
                if let issue = model.issue { NoticeBox(text: issue, tint: .red, onClose: model.dismissIssue) }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Copy.templateTitle(template.name)).font(.title2.weight(.semibold))
                        Text(Copy.templateWhen(template.name)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    actions(template)
                }
                if template.isAlert {
                    alertEditor(template)
                } else {
                    teamsEditor(template)
                }
                problems(template)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tracksWidth(above: 1000, $wide)
            .motion(value: model.restartSuggested)
            .motion(value: model.banner)
            .motion(value: model.issue)
        }
    }

    private func actions(_ template: MessageTemplate) -> some View {
        HStack {
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
    }

    @ViewBuilder private func problems(_ template: MessageTemplate) -> some View {
        let unknown = model.unknownPlaceholders(in: template)
        if !unknown.isEmpty {
            Label(Copy.templateUnknown(unknown), systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
        if model.isDirty(template), let missing = model.missingPart(of: template) {
            Label(missing, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
        }
    }

    // MARK: Teams message

    private func teamsEditor(_ template: MessageTemplate) -> some View {
        let variant = model.selectedVariant(of: template)
        let text = Binding(
            get: { model.variants(of: template)[model.selectedVariant(of: template)] },
            set: { model.setVariantText($0, for: template) })
        let faithful = TemplateMarkup.isFaithful(text.wrappedValue)
        let visual = faithful && !markdownView.contains(template.name)
        return withPreview {
            formatBar(template, text: text, visual: visual, faithful: faithful)
            variantBar(template)
            Group {
                if visual {
                    RichTemplateEditor(
                        markdown: text, controller: controller, emoji: model.emoji,
                        accessibilityLabel: Copy.templateTitle(template.name)
                    )
                    .id("\(template.name)#\(variant)")
                } else {
                    TextEditor(text: text)
                        .font(.body.monospaced())
                        .accessibilityLabel(Copy.templateTitle(template.name))
                }
            }
            .frame(minHeight: 150)
            .padding(6)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            if !faithful {
                Label(Copy.visualUnavailable, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            Text(Copy.templateHint).font(.caption).foregroundStyle(.secondary)
        } preview: {
            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.teamsPreviewHeading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TeamsMessagePreview(
                    recipient: TemplatePreview.recipient,
                    text: TemplatePreview.render(
                        text.wrappedValue, emoji: model.emoji, hour: Calendar.current.component(.hour, from: .now)))
                    .frame(maxWidth: 520)
                Text(Copy.templatePreviewNote(TemplatePreview.recipient)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func formatBar(_ template: MessageTemplate, text: Binding<String>, visual: Bool, faithful: Bool) -> some View {
        HStack(spacing: 6) {
            Picker(
                "",
                selection: Binding(
                    get: { visual },
                    set: { wantsVisual in
                        if wantsVisual { markdownView.remove(template.name) } else { markdownView.insert(template.name) }
                    })
            ) {
                Text(Copy.viewVisual).tag(true)
                Text(Copy.viewMarkdown).tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!faithful)
            .help(faithful ? "" : Copy.visualUnavailable)
            Divider().frame(height: 18)
            Group {
                formatButton("bold", Copy.formatBold, key: "b") { controller.toggle(.bold) }
                formatButton("italic", Copy.formatItalic, key: "i") { controller.toggle(.italic) }
                formatButton("strikethrough", Copy.formatStrikethrough, key: "x", modifiers: [.command, .shift]) {
                    controller.toggle(.strikethrough)
                }
                formatButton("link", Copy.formatLink, key: "k") { controller.editLink() }
            }
            .disabled(!visual)
            Divider().frame(height: 18)
            Menu {
                ForEach(model.placeholders(for: template), id: \.self) { name in
                    Button("{{\(name)}} — \(Copy.placeholderHelp(name))") {
                        if visual { controller.insertPlaceholder(name) } else { text.wrappedValue += "{{\(name)}}" }
                    }
                }
            } label: {
                Label(Copy.templateInsert, systemImage: "curlybraces")
            }
            .fixedSize()
            Button { showingEmoji = true } label: { Label(Copy.formatEmoji, systemImage: "face.smiling") }
                .help(Copy.formatEmoji)
                .popover(isPresented: $showingEmoji, arrowEdge: .bottom) {
                    EmojiPicker(
                        emoji: model.emoji,
                        onPick: { emoji in
                            if visual { controller.insertText(emoji) } else { text.wrappedValue += emoji }
                        },
                        onMore: {
                            showingEmoji = false
                            controller.showCharacterPalette()
                        })
                }
            Button { showingGIF = true } label: { Label(Copy.formatGIF, systemImage: "photo.on.rectangle.angled") }
                .help(Copy.gifTitle)
                .sheet(isPresented: $showingGIF) {
                    GIFPickerSheet { alt, url in
                        if visual {
                            controller.insertImage(alt: alt, url: url)
                        } else {
                            text.wrappedValue += "\n![\(TemplateMarkup.escape(alt))](\(url))"
                        }
                    }
                }
            Spacer(minLength: 0)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
    }

    private func formatButton(
        _ symbol: String, _ label: String, key: KeyEquivalent, modifiers: EventModifiers = .command,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 16) }
            .keyboardShortcut(key, modifiers: modifiers)
            .help(label)
            .accessibilityLabel(label)
    }

    private func variantBar(_ template: MessageTemplate) -> some View {
        let count = model.variants(of: template).count
        return HStack(spacing: 8) {
            Text(Copy.variantsHeading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if count > 1 {
                Picker(
                    Copy.variantsHeading,
                    selection: Binding(get: { model.selectedVariant(of: template) }, set: { model.selectVariant($0, of: template) })
                ) {
                    ForEach(0..<count, id: \.self) { Text(Copy.variantLabel($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Button { model.addVariant(to: template) } label: { Image(systemName: "plus") }
                .help(Copy.variantAdd)
                .accessibilityLabel(Copy.variantAdd)
            if count > 1 {
                Button { model.removeVariant(from: template) } label: { Image(systemName: "minus") }
                    .help(Copy.variantRemove)
                    .accessibilityLabel(Copy.variantRemove)
            }
            Text(Copy.variantsHelp).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .controlSize(.small)
    }

    // MARK: Notification

    private func alertEditor(_ template: MessageTemplate) -> some View {
        let title = Binding(
            get: { AlertPreview.split(model.text(of: template)).title },
            set: { model.setText(AlertPreview.join(title: $0, body: AlertPreview.split(model.text(of: template)).body), for: template) })
        let body = Binding(
            get: { AlertPreview.split(model.text(of: template)).body },
            set: { model.setText(AlertPreview.join(title: AlertPreview.split(model.text(of: template)).title, body: $0), for: template) })
        let insert = { (addition: String) in
            if alertField == .title { title.wrappedValue += addition } else { body.wrappedValue += addition }
        }
        let preview = AlertPreview.render(model.text(of: template), emoji: model.emoji)
        return withPreview {
            HStack(spacing: 6) {
                Menu {
                    ForEach(model.placeholders(for: template), id: \.self) { name in
                        Button("{{\(name)}} — \(Copy.placeholderHelp(name))") { insert("{{\(name)}}") }
                    }
                } label: {
                    Label(Copy.templateInsert, systemImage: "curlybraces")
                }
                .fixedSize()
                Button { showingEmoji = true } label: { Label(Copy.formatEmoji, systemImage: "face.smiling") }
                    .popover(isPresented: $showingEmoji, arrowEdge: .bottom) {
                        EmojiPicker(emoji: model.emoji, onPick: insert, onMore: {
                            showingEmoji = false
                            NSApp.orderFrontCharacterPalette(nil)
                        })
                    }
                Spacer(minLength: 0)
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            Text(Copy.alertTitleField).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(Copy.alertTitleField, text: title)
                .textFieldStyle(.roundedBorder)
                .focused($alertField, equals: .title)
            Text(Copy.alertBodyField).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: body)
                .focused($alertField, equals: .body)
                .frame(minHeight: 70)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .accessibilityLabel(Copy.alertBodyField)
            Text(Copy.alertHint).font(.caption).foregroundStyle(.secondary)
        } preview: {
            VStack(alignment: .leading, spacing: 6) {
                Text(Copy.alertPreviewHeading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                NotificationBannerPreview(title: preview.title, body_: preview.body)
                    .padding(8)
                Text(Copy.alertPreviewNote).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// The editor with its preview beside it when there is room, beneath it otherwise.
    @ViewBuilder private func withPreview(
        @ViewBuilder editor: () -> some View, @ViewBuilder preview: () -> some View
    ) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) { editor() }
                preview().frame(width: 400, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                editor()
                preview()
            }
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
        .transition(Motion.reveal(motion))
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
