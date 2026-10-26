import AppKit
import SuicaCore
import SwiftUI

// The inputs of the configuration form, one per kind of setting. Each writes through the editor
// model, and a box holding text that is not a value reports it with `setInputInvalid`.

// MARK: - Host

/// A host name after a fixed `https://`. A pasted URL keeps only its host.
struct HostInput: View {
    let field: ConfigField
    let editor: ConfigEditorModel

    private var host: String {
        if case .string(let text) = editor.value(of: field) { return text }
        return ""
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                Text("https://").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(
                    field.label,
                    text: Binding(get: { host }, set: { editor.setText(field, ConfigInputs.host(from: $0)) }),
                    prompt: Text(field.placeholder ?? "gitlab.example.com")
                )
                .labelsHidden()
                .textFieldStyle(.plain)
                // A form row right-aligns its text; a host reads from its scheme on.
                .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            Button {
                if let url = URL(string: "https://\(host)") { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .disabled(host.isEmpty || URL(string: "https://\(host)")?.host == nil)
            .help(Copy.openInBrowser)
            .accessibilityLabel(Copy.openInBrowser)
        }
        .frame(maxWidth: 380)
    }
}

// MARK: - Path

/// A file or folder path, typed or chosen; `~` stands for the home folder.
struct PathInput: View {
    let field: ConfigField
    let editor: ConfigEditorModel

    private var path: String {
        if case .string(let text) = editor.value(of: field) { return text }
        return ""
    }

    private var expanded: String { (path as NSString).expandingTildeInPath }

    /// The paths that are folders, not files: the picker lists folders only and can make a new one.
    private static let folderKeys: Set<String> = ["lessons.vaultPath", "teams.templatesPath"]

    var body: some View {
        HStack(spacing: 6) {
            TextField(
                field.label, text: Binding(get: { path }, set: { editor.setText(field, $0) }),
                prompt: Text(field.placeholder ?? ""))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .font(.body.monospaced())
            Button(Self.folderKeys.contains(field.path.joined(separator: ".")) ? Copy.chooseFolder : Copy.chooseFile, action: choose)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .disabled(path.isEmpty || !FileManager.default.fileExists(atPath: expanded))
            .help(Copy.showInFinder)
            .accessibilityLabel(Copy.showInFinder)
        }
        .frame(maxWidth: 460)
    }

    private func choose() {
        let panel = NSOpenPanel()
        let foldersOnly = Self.folderKeys.contains(field.path.joined(separator: "."))
        panel.canChooseFiles = !foldersOnly
        panel.canChooseDirectories = true
        // The panel's own New Folder button: a vault or a templates folder can be made on the spot.
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = foldersOnly ? Copy.chooseFolderPrompt : Copy.chooseFile
        let start = path.isEmpty ? (field.placeholder ?? "") : path
        if !start.isEmpty {
            let startURL = URL(fileURLWithPath: Folders.expand(start))
            // A folder opens inside itself; a file's folder is where it sits.
            panel.directoryURL = foldersOnly && Folders.isFolder(start) ? startURL : startURL.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editor.setText(field, Folders.tidy(url.path))
    }
}

// MARK: - Numbers

/// Digits only, shown with thousands separators outside editing, with a stepper and the unit.
struct NumberInput: View {
    let field: ConfigField
    let editor: ConfigEditorModel
    @State private var text: String
    @FocusState private var focused: Bool

    init(field: ConfigField, editor: ConfigEditorModel) {
        self.field = field
        self.editor = editor
        _text = State(initialValue: NumberText.render(editor.value(of: field)))
    }

    private var limit: Int { field.max ?? NumberText.largest }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                TextField(
                    field.label,
                    text: Binding(
                        get: { focused ? text : NumberText.grouped(text) },
                        set: { text = NumberText.digits($0) }),
                    prompt: Text(field.placeholder ?? "")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($focused)
                .frame(width: 96)
                Stepper(
                    field.label,
                    value: Binding(get: { Int(text) ?? 1 }, set: { text = String($0) }),
                    in: 1...limit
                )
                .labelsHidden()
                if let unit = field.unit {
                    Text(Copy.unit(unit, count: Int(text) ?? 0)).foregroundStyle(.secondary)
                }
            }
            if editor.invalidInputKeys.contains(field.path.joined(separator: ".")) {
                Text(Copy.invalidNumber).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: text) { _, new in
            if let number = Int(new), number > limit {
                text = String(limit)
            } else if let number = Int(new), number >= 1 {
                editor.set(field, .int(number))
            } else {
                // Empty or 0: not a value, unless the field has none (after "Use default").
                editor.setInputInvalid(field, !(new.isEmpty && editor.value(of: field) == .null))
            }
        }
        // The box was just built from the model, so its text is a value.
        .onAppear { editor.setInputInvalid(field, false) }
        .onChange(of: editor.value(of: field)) { _, value in
            if case .int(let number) = value {
                if Int(text) != number { text = String(number) }
            } else {
                text = NumberText.render(value)
            }
        }
    }
}

/// A length of time: a whole number of a unit picked beside it, stored in the field's own unit.
struct DurationInput: View {
    let field: ConfigField
    let editor: ConfigEditorModel
    let base: DurationUnit
    @State private var unit: DurationUnit
    @State private var text: String

    init(field: ConfigField, editor: ConfigEditorModel, base: DurationUnit) {
        self.field = field
        self.editor = editor
        self.base = base
        let value: Int? = if case .int(let number) = editor.value(of: field) { number } else { nil }
        let unit = value.map { DurationUnit.best(for: $0, base: base) } ?? base
        _unit = State(initialValue: unit)
        _text = State(initialValue: value.map { String($0 * base.seconds / unit.seconds) } ?? "")
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                TextField(field.label, text: $text, prompt: Text(field.placeholder ?? ""))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
                Stepper(
                    field.label,
                    value: Binding(get: { Int(text) ?? 1 }, set: { text = String($0) }),
                    in: 1...NumberText.largest
                )
                .labelsHidden()
                Picker(Copy.durationUnitPicker, selection: $unit) {
                    ForEach(DurationUnit.offered(for: base), id: \.self) { each in
                        Text(Copy.unit(each.rawValue, count: Int(text) ?? 0)).tag(each)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if editor.invalidInputKeys.contains(field.path.joined(separator: ".")) {
                Text(Copy.invalidNumber).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: text) { _, new in
            let digits = String(new.filter { $0.isASCII && $0.isNumber }.prefix(6))
            if digits != new { text = digits } else { write() }
        }
        // The number stays and means the new unit: "2" seconds becomes "2" minutes.
        .onChange(of: unit) { write() }
        .onAppear { editor.setInputInvalid(field, false) }
        .onChange(of: editor.value(of: field)) { _, value in
            guard case .int(let number) = value else {
                text = ""
                return
            }
            if Int(text).map({ unit.converted($0, to: base) }) != number {
                unit = DurationUnit.best(for: number, base: base)
                text = String(number * base.seconds / unit.seconds)
            }
        }
    }

    private func write() {
        if let count = Int(text), count >= 1 {
            editor.set(field, .int(unit.converted(count, to: base)))
        } else {
            editor.setInputInvalid(field, !(text.isEmpty && editor.value(of: field) == .null))
        }
    }
}

enum NumberText {
    /// Nine digits stay far inside Int and far above any setting this agent has.
    static let largest = 999_999_999

    static func digits(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(9))
    }

    static func grouped(_ digits: String) -> String {
        Int(digits).map { $0.formatted(.number.grouping(.automatic)) } ?? digits
    }

    /// A number that is not a whole `Int` (the agent reports it) is shown as written, to be replaced.
    static func render(_ value: JSONValue) -> String {
        switch value {
        case .int(let number): String(number)
        case .number(let number): "\(number)"
        default: ""
        }
    }
}

// MARK: - Choices

/// A few named choices side by side, with what the picked one does underneath. Choices this app
/// cannot name, or more than four, are a pop-up menu.
struct ChoiceInput: View {
    let key: String
    let label: String
    let options: [String]
    @Binding var selection: String?

    private func title(_ option: String) -> String {
        Copy.optionTitle(key, option) ?? DisplayText.clean(option, max: 60)
    }

    private var named: Bool { options.count <= 4 && options.allSatisfy { Copy.optionTitle(key, $0) != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if named {
                Text(label)
                picker.pickerStyle(.segmented).fixedSize()
            } else {
                LabeledContent(label) { picker.pickerStyle(.menu).fixedSize() }
            }
            if let selection, let detail = Copy.optionDetail(key, selection) {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var picker: some View {
        Picker(label, selection: $selection) {
            if selection == nil { Text(Copy.defaultOption).tag(String?.none) }
            ForEach(options, id: \.self) { Text(title($0)).tag(String?.some($0)) }
        }
        .labelsHidden()
    }
}

/// Levels from least to most on a slider with a stop per level; each name under it picks it too.
struct LevelSlider: View {
    let label: String
    let levels: [String]
    @Binding var selection: String?

    private var index: Int { selection.flatMap { levels.firstIndex(of: $0) } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(selection.map(Copy.effortTitle) ?? Copy.defaultOption).fontWeight(.semibold)
            }
            Slider(
                value: Binding(
                    get: { Double(index) },
                    set: { selection = levels[min(max(Int($0.rounded()), 0), levels.count - 1)] }),
                in: 0...Double(max(levels.count - 1, 1)),
                step: 1
            ) {
                Text(label)
            } minimumValueLabel: {
                Image(systemName: "hare").accessibilityLabel(Copy.effortTitle(levels.first ?? ""))
            } maximumValueLabel: {
                Image(systemName: "tortoise").accessibilityLabel(Copy.effortTitle(levels.last ?? ""))
            }
            .labelsHidden()
            .accessibilityValue(selection.map(Copy.effortTitle) ?? "")
            HStack(spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.element) { position, level in
                    if position > 0 { Spacer(minLength: 4) }
                    Button(Copy.effortTitle(level)) { selection = level }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(level == selection ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
            }
            // Under the slider's track, between its two end icons.
            .padding(.horizontal, 22)
            if let selection {
                Text(Copy.effortDetail(selection)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Auto and each model CLI as a card saying whether it is installed and in use.
struct ModelCliCards: View {
    @Binding var selection: String?
    let options: [String]
    let status: ModelCliStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) {
                ForEach(options, id: \.self) { card($0) }
            }
            if let selection, let detail = Copy.optionDetail("model.cli", selection) {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Text(Copy.modelCliNote).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func card(_ option: String) -> some View {
        let picked = option == selection
        let (line, tint) = state(of: option)
        return Button { selection = option } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Copy.optionTitle("model.cli", option) ?? DisplayText.clean(option, max: 40))
                        .fontWeight(.semibold)
                    Spacer(minLength: 4)
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                Text(line).font(.caption).foregroundStyle(tint)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(picked ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.background), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: picked ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// Installed, in use or missing, from the agent's status; nothing while it is not known.
    private func state(of option: String) -> (String, Color) {
        guard let status else { return ("", .secondary) }
        if option == "auto" {
            let active = status.clis.first { $0.id == status.active }
            return active.map { (Copy.modelCliInUse($0.name), .secondary) } ?? (Copy.noModelCliInstalled, .orange)
        }
        guard let cli = status.clis.first(where: { $0.id == option }) else { return ("", .secondary) }
        if cli.path == nil { return (Copy.notInstalledShort, .orange) }
        return status.active == option ? (Copy.inUse, .green) : (Copy.installed, .secondary)
    }
}

// MARK: - Times of day

/// A 24-hour time of day with a stepper; the field's `HH:MM` text is read and written.
struct ClockInput: View {
    let field: ConfigField
    let editor: ConfigEditorModel

    var body: some View {
        ClockPicker(label: field.label, minutes: Binding(
            get: { ClockPicker.minutes(of: editor.value(of: field)) },
            set: { editor.set(field, .string(ConfigInputs.clock(fromMinutes: $0))) }))
    }
}

struct ClockPicker: View {
    let label: String
    @Binding var minutes: Int

    /// The field's time, or 09:00 while it has none (nothing is written until it is changed).
    static func minutes(of value: JSONValue) -> Int {
        if case .string(let text) = value, let minutes = ConfigInputs.minutes(ofClock: text) { return minutes }
        return 9 * 60
    }

    var body: some View {
        DatePicker(
            label,
            selection: Binding(
                get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes * 60)) },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                }),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .datePickerStyle(.stepperField)
        // Always 24-hour, as the file is.
        .environment(\.locale, Locale(identifier: "en_GB"))
    }
}

/// Working hours start and end on one row, over a day-long bar that shows the span.
struct WorkingHoursEditor: View {
    let start: ConfigField
    let end: ConfigField
    let editor: ConfigEditorModel

    private func binding(_ field: ConfigField) -> Binding<Int> {
        Binding(
            get: { ClockPicker.minutes(of: editor.value(of: field)) },
            set: { editor.set(field, .string(ConfigInputs.clock(fromMinutes: $0))) })
    }

    var body: some View {
        let from = binding(start).wrappedValue
        let to = binding(end).wrappedValue
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(Copy.workingHours) {
                HStack(spacing: 8) {
                    Text(Copy.workingHoursFrom).foregroundStyle(.secondary)
                    ClockPicker(label: start.label, minutes: binding(start))
                    Text(Copy.workingHoursTo).foregroundStyle(.secondary)
                    ClockPicker(label: end.label, minutes: binding(end))
                }
            }
            DayBar(from: from, to: to)
            if from < to {
                Text(Copy.workingHoursSpan((to - from) / 60, (to - from) % 60)).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(Copy.workingHoursOrder).font(.caption).foregroundStyle(.red)
            }
            if !start.help.isEmpty {
                Text(DisplayText.clean(start.help, max: 400)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach([start, end], id: \.path) { field in
                if let issue = editor.issue(of: field) {
                    Text(DisplayText.clean(issue, max: 400)).font(.caption).foregroundStyle(.red)
                }
            }
            if [start, end].contains(where: { $0.value != .null && editor.drafts[$0.path.joined(separator: ".")] != .null }) {
                Button(Copy.resetToDefault) {
                    editor.resetToDefault(start)
                    editor.resetToDefault(end)
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityLabel("\(Copy.resetToDefault): \(Copy.workingHours)")
            }
        }
        .padding(.vertical, 2)
    }
}

/// A day from 00:00 to 24:00 with the span between two times filled in.
private struct DayBar: View {
    let from: Int
    let to: Int

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if from < to {
                        Capsule()
                            .fill(.tint)
                            .frame(width: width * CGFloat(to - from) / 1440)
                            .offset(x: width * CGFloat(from) / 1440)
                    }
                }
            }
            .frame(height: 8)
            HStack {
                ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                    if hour > 0 { Spacer() }
                    Text(String(format: "%02d", hour)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
