import Foundation
import SuicaCore
import SwiftUI

/// One row of the configuration form. Every edit goes through `editor.set`; input that is not a
/// valid value is never written into a draft.
struct FieldEditor: View {
    let field: ConfigField
    let editor: ConfigEditorModel

    private var key: String { field.path.joined(separator: ".") }
    private var isReset: Bool { editor.drafts[key] == .null }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if !field.help.isEmpty {
                Text(DisplayText.clean(field.help, max: 400)).font(.caption).foregroundStyle(.secondary)
            }
            if let note = field.restartNote {
                Text(DisplayText.clean(note, max: 400)).font(.caption).foregroundStyle(.orange)
            }
            if isReset { Text(Copy.unsetInFile).font(.caption).foregroundStyle(.secondary) }
            if let issue = editor.fieldIssues[key] {
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
            LabeledContent(field.label) {
                TextField(field.label, text: stringBinding, prompt: Text(field.placeholder ?? ""))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
            }
        case .int:
            IntInput(field: field, editor: editor)
        case .bool:
            LabeledContent(field.label) {
                // Off would be a guess while the default applies: Discard brings the control back.
                Toggle(field.label, isOn: boolBinding).labelsHidden().disabled(isReset)
            }
        case .enum:
            LabeledContent(field.label) {
                Picker(field.label, selection: optionBinding) {
                    if currentOption == nil { Text(Copy.defaultOption).tag(String?.none) }
                    ForEach(enumOptions, id: \.self) {
                        Text(DisplayText.clean($0, max: 60)).tag(String?.some($0))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }
        case .clock:
            ClockInput(field: field, editor: editor)
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
            set: { editor.set(field, .string($0)) })
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

// MARK: - Integers

/// Digits only: anything else is dropped as it is typed, and an empty box writes nothing.
private struct IntInput: View {
    let field: ConfigField
    let editor: ConfigEditorModel
    @State private var text: String

    init(field: ConfigField, editor: ConfigEditorModel) {
        self.field = field
        self.editor = editor
        _text = State(initialValue: Self.render(editor.value(of: field)))
    }

    private static func render(_ value: JSONValue) -> String {
        if case .int(let number) = value { return String(number) }
        return ""
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            LabeledContent(field.label) {
                TextField(field.label, text: $text, prompt: Text(field.placeholder ?? ""))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
            }
            if editor.invalidInputKeys.contains(field.path.joined(separator: ".")) {
                Text(Copy.invalidNumber).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: text) { _, new in
            // Nine digits stay far inside Int and far above any setting this agent has.
            let digits = String(new.filter { $0.isASCII && $0.isNumber }.prefix(9))
            if digits != new {
                text = digits
            } else if let number = Int(digits) {
                editor.set(field, .int(number))
            } else {
                // Empty: not a value, unless the field has none (after "Use default").
                editor.setInputInvalid(field, editor.value(of: field) != .null)
            }
        }
        // The box was just built from the model, so its text is a value.
        .onAppear { editor.setInputInvalid(field, false) }
        .onChange(of: editor.value(of: field)) { _, value in
            if case .int(let number) = value {
                if Int(text) != number { text = String(number) }
            } else {
                text = ""
            }
        }
    }
}

// MARK: - Clock

/// `HH:MM`, 24-hour. Text that is not a time shows the invalid state and writes nothing.
private struct ClockInput: View {
    let field: ConfigField
    let editor: ConfigEditorModel
    @State private var text: String

    init(field: ConfigField, editor: ConfigEditorModel) {
        self.field = field
        self.editor = editor
        _text = State(initialValue: Self.render(editor.value(of: field)))
    }

    private static func render(_ value: JSONValue) -> String {
        if case .string(let clock) = value { return clock }
        return ""
    }

    static func isClock(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
            let hours = Int(parts[0]), let minutes = Int(parts[1])
        else { return false }
        return hours < 24 && minutes < 60
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            LabeledContent(field.label) {
                TextField(field.label, text: $text, prompt: Text(field.placeholder ?? "HH:MM"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
            if editor.invalidInputKeys.contains(field.path.joined(separator: ".")) {
                Text(Copy.invalidClock).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: text) { _, new in
            if Self.isClock(new) {
                editor.set(field, .string(new))
            } else {
                editor.setInputInvalid(field, !(new.isEmpty && editor.value(of: field) == .null))
            }
        }
        .onAppear { editor.setInputInvalid(field, false) }
        .onChange(of: editor.value(of: field)) { _, value in
            let shown = Self.render(value)
            if shown != text { text = shown }
        }
    }
}
