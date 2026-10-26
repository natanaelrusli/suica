import SuicaCore
import SwiftUI

/// An editable list of strings. Blank entries stay on screen while they are typed but are not
/// written; the file never gets an empty string.
struct StringListEditor: View {
    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var text: String
    }

    let field: ConfigField
    let editor: ConfigEditorModel
    @State private var rows: [Row]

    init(field: ConfigField, editor: ConfigEditorModel) {
        self.field = field
        self.editor = editor
        _rows = State(initialValue: Self.rows(from: editor.value(of: field)))
    }

    private static func rows(from value: JSONValue) -> [Row] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            if case .string(let text) = item { return Row(text: text) }
            return nil
        }
    }

    private var written: JSONValue {
        .array(
            rows.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { .string($0) })
    }

    var body: some View {
        if field.format == "path" {
            FolderListEditor(field: field, editor: editor)
        } else {
            plainBody
        }
    }

    private var plainBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rows) { $row in
                HStack {
                    TextField(field.label, text: $row.text, prompt: Text(field.placeholder ?? ""))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    Button { rows.removeAll { $0.id == row.id } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(Copy.removeItem)
                    .accessibilityLabel("\(Copy.removeItem): \(field.label)")
                }
            }
            Button { rows.append(Row(text: "")) } label: {
                Label(Copy.addItem, systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(Copy.addItem): \(field.label)")
        }
        .onChange(of: rows) { editor.set(field, written) }
        .onChange(of: editor.value(of: field)) { _, value in
            if value != written { rows = Self.rows(from: value) }
        }
    }
}

/// A username / email table. Rows with an empty username are not written.
struct EmailMapEditor: View {
    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var username: String
        var email: String
    }

    let field: ConfigField
    let editor: ConfigEditorModel
    @State private var rows: [Row]

    init(field: ConfigField, editor: ConfigEditorModel) {
        self.field = field
        self.editor = editor
        _rows = State(initialValue: Self.rows(from: editor.value(of: field)))
    }

    private static func rows(from value: JSONValue) -> [Row] {
        guard case .object(let map) = value else { return [] }
        return map.keys.sorted().compactMap { name in
            if case .string(let email) = map[name] { return Row(username: name, email: email) }
            return nil
        }
    }

    private var written: JSONValue {
        var map: [String: JSONValue] = [:]
        for row in rows {
            let name = row.username.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { map[name] = .string(row.email.trimmingCharacters(in: .whitespaces)) }
        }
        return .object(map)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text(Copy.username).font(.caption).foregroundStyle(.secondary)
                        Text(Copy.email).font(.caption).foregroundStyle(.secondary)
                        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                    }
                    ForEach($rows) { $row in
                        GridRow {
                            TextField(Copy.username, text: $row.username)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 140)
                            TextField(Copy.email, text: $row.email)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 220)
                            Button { rows.removeAll { $0.id == row.id } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(Copy.removeItem)
                            .accessibilityLabel("\(Copy.removeItem): \(field.label)")
                        }
                    }
                }
            }
            Button { rows.append(Row(username: "", email: "")) } label: {
                Label(Copy.addItem, systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(Copy.addItem): \(field.label)")
        }
        .onChange(of: rows) { editor.set(field, written) }
        .onChange(of: editor.value(of: field)) { _, value in
            if value != written { rows = Self.rows(from: value) }
        }
    }
}

/// A list of folders (the lesson folders) with a real folder picker: Add folders… opens the Finder
/// panel (several folders at once, with its New Folder button), a folder can be dropped from Finder,
/// each row shows whether the folder exists and can be shown in Finder or changed, and a folder
/// never appears twice. The folders are written with `~` for the home folder.
struct FolderListEditor: View {
    let field: ConfigField
    let editor: ConfigEditorModel
    @State private var isTargeted = false

    private var folders: [String] {
        guard case .array(let items) = editor.value(of: field) else { return [] }
        return items.compactMap { item in
            if case .string(let text) = item { return text }
            return nil
        }
    }

    private func write(_ list: [String]) {
        editor.set(field, .array(list.map { .string($0) }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if folders.isEmpty {
                Text(Copy.noFoldersYet).font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(folders.enumerated()), id: \.offset) { index, folder in
                        if index > 0 { Divider() }
                        FolderRow(
                            folder: folder, label: field.label,
                            change: { replace(index) },
                            remove: { write(folders.enumerated().filter { $0.offset != index }.map(\.element)) })
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button { add() } label: { Label(Copy.addFolders, systemImage: "folder.badge.plus") }
                    .accessibilityLabel("\(Copy.addFolders): \(field.label)")
                if isTargeted { Text(Copy.dropFoldersHint).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isTargeted ? 4 : 0)
        .overlay {
            if isTargeted { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 2) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let dropped = urls.filter { Folders.isFolder($0.path) }.map(\.path)
            guard !dropped.isEmpty else { return false }
            write(Folders.adding(dropped, to: folders))
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private func panel(multiple: Bool, start: String?) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        // The panel's own New Folder button.
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = multiple
        panel.showsHiddenFiles = true
        panel.prompt = multiple ? Copy.addFoldersPrompt : Copy.chooseFolderPrompt
        if let start, Folders.isFolder(start) {
            panel.directoryURL = URL(fileURLWithPath: Folders.expand(start))
        }
        return panel
    }

    private func add() {
        let panel = panel(multiple: true, start: folders.last)
        guard panel.runModal() == .OK else { return }
        write(Folders.adding(panel.urls.map(\.path), to: folders))
    }

    private func replace(_ index: Int) {
        let panel = panel(multiple: false, start: folders[index])
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var list = folders
        list[index] = Folders.tidy(url.path)
        // A folder already in the list elsewhere is not added a second time.
        write(Folders.adding([], to: list))
    }
}

private struct FolderRow: View {
    let folder: String
    let label: String
    let change: () -> Void
    let remove: () -> Void

    var body: some View {
        let exists = Folders.isFolder(folder)
        HStack(spacing: 8) {
            Image(systemName: exists ? "folder.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(exists ? Color.accentColor : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                if !exists { Text(Copy.folderNotFound).font(.caption).foregroundStyle(.orange) }
            }
            Spacer(minLength: 4)
            Button(Copy.chooseFile, action: change).buttonStyle(.bordered).controlSize(.small)
                .accessibilityLabel("\(Copy.chooseFile): \(folder)")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Folders.expand(folder))])
            } label: { Image(systemName: "magnifyingglass.circle") }
                .buttonStyle(.borderless).disabled(!exists)
                .help(Copy.showInFinder).accessibilityLabel("\(Copy.showInFinder): \(folder)")
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help(Copy.removeItem).accessibilityLabel("\(Copy.removeItem): \(folder)")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}
