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
