import Foundation
import SuicaCore
import SwiftUI

/// One row of the configuration form. Every edit goes through `editor.set`; input that is not a
/// valid value is never written into a draft.
struct FieldEditor: View {
    let field: ConfigField
    let editor: ConfigEditorModel
    /// Which model CLIs are installed and in use, for the Model CLI cards and model suggestions.
    var modelClis: ModelCliStatus?

    private var key: String { field.path.joined(separator: ".") }
    private var isReset: Bool { editor.drafts[key] == .null }

    /// Choices whose options this app can name and explain show that instead of the agent's help.
    private var explainsItself: Bool {
        switch field.type {
        case .level: true
        case .enum: enumOptions.allSatisfy { Copy.optionDetail(key, $0) != nil }
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if !field.help.isEmpty && !explainsItself {
                Text(DisplayText.clean(field.help, max: 400)).font(.caption).foregroundStyle(.secondary)
            }
            if let note = field.restartNote {
                Text(DisplayText.clean(note, max: 400)).font(.caption).foregroundStyle(.orange)
            }
            if isReset { Text(Copy.unsetInFile).font(.caption).foregroundStyle(.secondary) }
            if let issue = editor.issue(of: field) {
                Text(DisplayText.clean(issue, max: 400)).font(.caption).foregroundStyle(.red)
            }
            if field.value != .null && !isReset {
                Button(Copy.resetToDefault) { editor.resetToDefault(field) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityLabel("\(Copy.resetToDefault): \(field.label)")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var control: some View {
        switch field.type {
        case .string:
            switch field.format {
            case "hostname":
                LabeledContent(field.label) { HostInput(field: field, editor: editor) }
            case "path":
                LabeledContent(field.label) { PathInput(field: field, editor: editor) }
            default:
                LabeledContent(field.label) {
                    HStack(spacing: 6) {
                        TextField(field.label, text: stringBinding, prompt: Text(field.placeholder ?? ""))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                        if key == "review.model" { modelSuggestions }
                    }
                    .frame(maxWidth: 360)
                }
            }
        case .int:
            if let base = DurationUnit(fieldUnit: field.unit) {
                LabeledContent(field.label) { DurationInput(field: field, editor: editor, base: base) }
            } else if let max = field.max, max <= 6 {
                LabeledContent(field.label) { smallNumberPicker(max: max) }
            } else {
                LabeledContent(field.label) { NumberInput(field: field, editor: editor) }
            }
        case .bool:
            LabeledContent(field.label) {
                // Off would be a guess while the default applies: Discard brings the control back.
                Toggle(field.label, isOn: boolBinding).labelsHidden().toggleStyle(.switch).disabled(isReset)
            }
        case .enum:
            if key == "model.cli" {
                VStack(alignment: .leading, spacing: 8) {
                    Text(field.label)
                    ModelCliCards(selection: optionBinding, options: enumOptions, status: modelClis)
                }
            } else {
                ChoiceInput(key: key, label: field.label, options: enumOptions, selection: optionBinding)
            }
        case .level:
            LevelSlider(label: field.label, levels: enumOptions, selection: optionBinding)
        case .clock:
            LabeledContent(field.label) { ClockInput(field: field, editor: editor) }
        case .weekdays:
            LabeledContent(field.label) { weekdayToggles }
        case .stringList:
            VStack(alignment: .leading, spacing: 6) {
                Text(field.label)
                StringListEditor(field: field, editor: editor)
            }
        case .emailMap:
            VStack(alignment: .leading, spacing: 6) {
                Text(field.label)
                EmailMapEditor(field: field, editor: editor)
            }
        case .unknown:
            LabeledContent(field.label) {
                VStack(alignment: .trailing) {
                    Text(Self.describe(editor.value(of: field))).textSelection(.enabled)
                    Text(Copy.readOnlyField).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Bindings

    private var stringBinding: Binding<String> {
        Binding(
            get: {
                if case .string(let text) = editor.value(of: field) { return text }
                return ""
            },
            set: { editor.setText(field, $0) })
    }

    private var currentOption: String? {
        if case .string(let text) = editor.value(of: field) { return text }
        return nil
    }

    /// Nothing selected means the default applies; only a real option can be chosen.
    private var optionBinding: Binding<String?> {
        Binding(
            get: { currentOption },
            set: { if let option = $0 { editor.set(field, .string(option)) } })
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: {
                if case .bool(let on) = editor.value(of: field) { return on }
                return false
            },
            set: { editor.set(field, .bool($0)) })
    }

    /// The options, plus the current value when the file holds one the list lacks.
    private var enumOptions: [String] {
        let options = field.options ?? []
        if case .string(let current) = editor.value(of: field), !options.contains(current) {
            return options + [current]
        }
        return options
    }

    // MARK: Small numbers

    /// One button per value when there are only a few, as Reviews at once (1 to 4).
    private func smallNumberPicker(max: Int) -> some View {
        Picker(
            field.label,
            selection: Binding<Int?>(
                get: { if case .int(let number) = editor.value(of: field) { number } else { nil } },
                set: { if let number = $0 { editor.set(field, .int(number)) } })
        ) {
            ForEach(1...max, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    // MARK: Review model

    /// Claude Code's aliases while it reviews; any name can still be typed.
    @ViewBuilder private var modelSuggestions: some View {
        if modelClis?.active == "claude" {
            Menu {
                ForEach(["opus", "sonnet", "haiku"], id: \.self) { name in
                    Button(name) { editor.setText(field, name) }
                }
                Divider()
                Button(Copy.cliDefaultModel) { editor.setText(field, "") }
            } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Copy.modelSuggestions)
            .accessibilityLabel(Copy.modelSuggestions)
        }
    }

    // MARK: Weekdays

    private var selectedDays: Set<Int> {
        guard case .array(let items) = editor.value(of: field) else { return [] }
        return Set(
            items.compactMap { item -> Int? in
                if case .int(let day) = item, (1...7).contains(day) { return day }
                return nil
            })
    }

    private var weekdayToggles: some View {
        HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { day in
                Toggle(
                    Copy.weekdayNames[day - 1],
                    isOn: Binding(
                        get: { selectedDays.contains(day) },
                        set: { on in
                            var days = selectedDays
                            if on { days.insert(day) } else { days.remove(day) }
                            // The agent rejects an empty list: one day always stays on.
                            guard !days.isEmpty else { return }
                            editor.set(field, .array(days.sorted().map { .int($0) }))
                        })
                )
                .toggleStyle(.button)
                .accessibilityLabel(Copy.weekdayNamesLong[day - 1])
            }
        }
    }

    private static func describe(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return DisplayText.clean(text, max: 300)
    }
}
