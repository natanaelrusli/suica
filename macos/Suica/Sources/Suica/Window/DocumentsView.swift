import AppKit
import SuicaCore
import SwiftUI

/// The Markdown files under the Plan folders: the tree (or the search results) on the left, the open file on the right.
struct DocumentsView: View {
    @Bindable var model: DocumentsModel
    /// The path whose disk-changed notice "Keep editing" hid; the next disk check or conflict shows it again.
    @State private var keptConflict: String?
    /// A failed save the model does not keep (one already running), shown until the next save outcome.
    @State private var failure: (path: String, reason: String)?
    /// A new id per save, so a closed failure notice opens again for the next one.
    @State private var saveAttempt = 0

    var body: some View {
        // As in PlansView: the tasks sit on this stable view, not on the switching content.
        ZStack {
            if model.folders.isEmpty {
                ContentUnavailableView {
                    Label(Copy.noPlanFoldersTitle, systemImage: "folder.badge.plus")
                } description: {
                    Text(Copy.noPlanFoldersHint)
                } actions: {
                    Button(Copy.addPlanFolder, action: addFolders).buttonStyle(.borderedProminent)
                }
            } else if model.files.isEmpty {
                if model.isScanning { ProgressView(Copy.loading) } else { ContentUnavailableView(Copy.noDocumentsTitle, systemImage: "doc.richtext", description: Text(Copy.noDocumentsHint)) }
            } else {
                split
            }
        }
        .task { await model.refresh() }
        .task(id: model.selectedPath) {
            failure = nil  // one file's failure never shows under another
            // In Edit the new file needs its base; loadContent also renders a Draft for View.
            if model.mode == .edit { await model.startEditing() }
            await model.loadContent()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checkDisk() }
        }
        .toolbar {
            Button(action: model.back) { Label(Copy.goBack, systemImage: "chevron.left") }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack)
            Button(action: model.forward) { Label(Copy.goForward, systemImage: "chevron.right") }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
            Picker(Copy.editMode, selection: Binding(get: { model.mode }, set: { setMode($0) })) {
                Text(Copy.viewMode).tag(DocumentsModel.Mode.view)
                Text(Copy.editMode).tag(DocumentsModel.Mode.edit)
            }
            .pickerStyle(.segmented)
            .help(model.content == .unavailable ? Copy.cantEditFile : "")
            .disabled(model.selectedPath == nil)
            if model.mode == .edit {
                Button { save() } label: { Label(Copy.saveDocument, systemImage: "square.and.arrow.down") }
                    .keyboardShortcut("s")
                    .disabled(!dirty)
                Button(action: model.revert) { Label(Copy.revertDraft, systemImage: "arrow.uturn.backward") }
                    .disabled(!dirty)
            }
            Menu {
                ForEach(model.folders, id: \.self) { folder in
                    Button("\(folder) ✕") {
                        model.removeFolder(folder)
                        Task { await model.refresh() }
                    }
                }
            } label: { Label(Copy.plansFolders, systemImage: "folder") }
            .disabled(model.folders.isEmpty)
            Button(action: addFolders) { Label(Copy.addPlanFolder, systemImage: "folder.badge.plus") }
            Button {
                Task {
                    await model.refresh()
                    await checkDisk()
                }
            } label: { Label(Copy.rescanPlans, systemImage: "arrow.clockwise") }
            .keyboardShortcut("r")
            .disabled(model.isScanning)
        }
    }

    private var dirty: Bool { model.selectedPath.map(model.unsavedPaths.contains) ?? false }

    /// A Picker takes no shortcut, so ⌘E is an invisible button on the page (one in the toolbar would leave with the overflow menu).
    private var editShortcut: some View {
        Button("") { setMode(model.mode == .edit ? .view : .edit) }
            .keyboardShortcut("e")
            .disabled(model.selectedPath == nil)
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// A clean document reloads; a Draft is kept and flagged when its file changed.
    private func checkDisk() async {
        await model.checkDisk()
        keptConflict = nil
    }

    private func setMode(_ mode: DocumentsModel.Mode) {
        Task {
            if mode == .edit {
                await model.startEditing()
            } else {
                model.mode = .view
                await model.loadContent()  // typing never updates `content`
            }
        }
    }

    private func save(overwrite: Bool = false) {
        guard let path = model.selectedPath else { return }
        saveAttempt += 1
        Task {
            switch await model.save(overwrite: overwrite) {
            case .failed(let reason): failure = (path, reason)
            case .conflict: failure = nil; keptConflict = nil
            case .saved: failure = nil
            }
        }
    }

    private func addFolders() {
        model.addFolders(pickFolders())
        Task { await model.refresh() }
    }

    /// Only a listed file opens; a folder row is just a heading.
    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedPath },
            set: { id in if let id, model.files.contains(where: { $0.path == id }) { model.open(path: id) } })
    }

    private var split: some View {
        UnderTitleBar { titleBar in
            HStack(spacing: 0) {
                list(titleBar: titleBar).frame(width: 280)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, titleBar)
            }
        }
        .background { editShortcut }
        .onChange(of: dirty) { _, isDirty in if !isDirty { failure = nil } }
        .searchable(text: $model.query, placement: .toolbar, prompt: Copy.searchDocuments)
    }

    @ViewBuilder private func list(titleBar: CGFloat) -> some View {
        Group {
            let shown = model.visible
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                let unsaved = model.unsavedPaths
                List(model.tree, children: \.children, selection: selection) { node in
                    // A folder row would take the highlight while the file stays open.
                    HStack {
                        Label(node.name, systemImage: node.file == nil ? "folder" : "doc.text").lineLimit(1)
                        if node.file != nil, unsaved.contains(node.id) { Spacer(); UnsavedDot() }
                    }
                    .selectionDisabled(node.file == nil)
                }
            } else if shown.isEmpty {
                Text(Copy.noDocumentsMatch).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let unsaved = model.unsavedPaths
                List(shown, selection: selection) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).lineLimit(1)
                            Text(file.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if unsaved.contains(file.path) { Spacer(); UnsavedDot() }
                    }
                }
            }
        }
        // No bar of its own: the rows still scroll under the title bar as on the other pages.
        .modifier(ListTopBar(titleBar: titleBar) { Color.clear.frame(height: 0) })
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.truncated {
                Text(Copy.documentsTruncated).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(6).background(.bar)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        Group {
            if let path = model.selectedPath {
                let file = model.files.first { $0.path == path }
                // Above both modes: a disk check can flag a Draft while it is being read in View.
                VStack(spacing: 0) {
                    notices(path)
                    page(path: path, file: file)
                }
            } else {
                ContentUnavailableView(Copy.documents, systemImage: "doc.richtext")
            }
        }
        .environment(\.openURL, OpenURLAction { url in model.openLink(url) == .external ? .systemAction : .handled })
    }

    @ViewBuilder private func notices(_ path: String) -> some View {
        let changed = model.diskChanged && keptConflict != path
        // A failure means nothing once the Draft is gone (saved, reverted, reloaded or typed back to the base).
        let reason = dirty ? (failure?.path == path ? failure?.reason : nil) ?? model.saveError : nil
        if changed || reason != nil {
            VStack(spacing: 8) {
                if changed {
                    DiskChangedNotice(
                        overwrite: { save(overwrite: true) }, reload: { Task { await model.reload() } }, keepEditing: { keptConflict = path })
                }
                if let reason { NoticeBox(text: Copy.saveFailed(reason), tint: .red).id(saveAttempt) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }

    @ViewBuilder private func page(path: String, file: DocumentFile?) -> some View {
        if model.mode == .edit, model.content != .unavailable {
            VStack(alignment: .leading, spacing: 14) {
                header(path: path, file: file)
                if model.content == .none {
                    ProgressView(Copy.loading).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DocumentEditor(path: path, name: file?.name ?? URL(fileURLWithPath: path).lastPathComponent, model: model).id(path)
                }
            }
            .padding(20)
        } else {
            switch model.content {
            case .text(let entries, let body):
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(path: path, file: file)
                        if !entries.isEmpty { properties(entries) }
                        MarkdownText(source: body)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A new scroll view per file, so each one opens at the top.
                .id(path)
            case .unavailable:
                ContentUnavailableView {
                    Label(Copy.documentUnavailableTitle, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(Copy.documentUnavailableHint)
                } actions: {
                    fileButtons(path)
                }
            case .none:
                ProgressView(Copy.loading)
            }
        }
    }

    private func header(path: String, file: DocumentFile?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(file?.name ?? URL(fileURLWithPath: path).lastPathComponent).font(.title2.weight(.semibold))
                if model.unsavedPaths.contains(path) { UnsavedDot() }
            }
            Text(file?.relativePath ?? path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            HStack { fileButtons(path) }
        }
    }

    private func properties(_ entries: [FrontMatterEntry]) -> some View {
        GroupBox(Copy.documentProperties) {
            // A Grid, so every value starts at the same x however long the keys are.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(entries.indices, id: \.self) { index in
                    GridRow {
                        Text(entries[index].key).foregroundStyle(.secondary)
                        Text(entries[index].value).textSelection(.enabled)
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func fileButtons(_ path: String) -> some View {
        Button(Copy.openDocument) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        Button(Copy.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
}
