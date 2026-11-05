import AppKit
import SuicaCore
import SwiftUI

/// The Markdown files under the Plan folders: the tree (or the search results) on the left, the open file on the right.
struct DocumentsView: View {
    @Bindable var model: DocumentsModel

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
        .task(id: model.selectedPath) { await model.loadContent() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.loadContent() }
        }
        .toolbar {
            Button(action: model.back) { Label(Copy.goBack, systemImage: "chevron.left") }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack)
            Button(action: model.forward) { Label(Copy.goForward, systemImage: "chevron.right") }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
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
                    await model.loadContent()
                }
            } label: { Label(Copy.rescanPlans, systemImage: "arrow.clockwise") }
            .keyboardShortcut("r")
            .disabled(model.isScanning)
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
        .searchable(text: $model.query, placement: .toolbar, prompt: Copy.searchDocuments)
    }

    @ViewBuilder private func list(titleBar: CGFloat) -> some View {
        Group {
            if model.query.isEmpty {
                List(model.tree, children: \.children, selection: selection) { node in
                    // A folder row would take the highlight while the file stays open.
                    Label(node.name, systemImage: node.file == nil ? "folder" : "doc.text").lineLimit(1)
                        .selectionDisabled(node.file == nil)
                }
            } else {
                List(model.visible, selection: selection) { file in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).lineLimit(1)
                        Text(file.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
            } else {
                ContentUnavailableView(Copy.documents, systemImage: "doc.richtext")
            }
        }
        .environment(\.openURL, OpenURLAction { url in model.openLink(url) == .external ? .systemAction : .handled })
    }

    private func header(path: String, file: DocumentFile?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(file?.name ?? URL(fileURLWithPath: path).lastPathComponent).font(.title2.weight(.semibold))
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
