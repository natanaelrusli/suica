import Observation

@MainActor @Observable
public final class ConfigEditorModel {
    public private(set) var document: ConfigDocument?
    /// Unsaved edits, keyed by the field path joined with ".".
    public private(set) var drafts: [String: JSONValue] = [:]
    public private(set) var fieldIssues: [String: String] = [:]
    public private(set) var banner: String?
    public private(set) var saving = false
    public private(set) var restartSuggested = false
    /// Fields whose box holds text that is not a value yet (an empty number, a half-typed time).
    /// The drafts do not show it, so saving is blocked while any is left.
    public private(set) var invalidInputKeys: Set<String> = []

    @ObservationIgnored private let client: any DashboardClient

    public init(client: any DashboardClient) {
        self.client = client
    }

    private static func key(_ field: ConfigField) -> String {
        field.path.joined(separator: ".")
    }

    /// Reloads the document. Drafts are kept: after a conflict the Owner reviews what changed first.
    public func load() async {
        do {
            let fresh = try await client.config()
            // A new file rebuilds the form, and with it every box; the same file keeps its boxes.
            if fresh.sha256 != document?.sha256 { invalidInputKeys = [] }
            document = fresh
            banner = nil
        } catch {
            banner = MenuModel.message(for: error)
        }
    }

    /// What the form shows: the draft, else the effective value, else the value in the file.
    public func value(of field: ConfigField) -> JSONValue {
        drafts[Self.key(field)] ?? baseline(of: field)
    }

    public func set(_ field: ConfigField, _ value: JSONValue) {
        drafts[Self.key(field)] = value
        fieldIssues[Self.key(field)] = nil
        invalidInputKeys.remove(Self.key(field))
    }

    /// Keys the agent requires: an empty box is written as empty text, and the agent says why it is
    /// refused. Every other text field is optional, so an empty box removes the key.
    static let requiredTextKeys: Set<String> = ["gitlab.hostname"]

    /// What a text box writes: its text, or for an optional field left empty, the removal.
    public func setText(_ field: ConfigField, _ text: String) {
        let optional = !Self.requiredTextKeys.contains(Self.key(field))
        set(field, text.isEmpty && optional ? .null : .string(text))
    }

    /// The agent's message for this field: from the last save, else from the loaded document until
    /// the field is edited.
    public func issue(of field: ConfigField) -> String? {
        let key = Self.key(field)
        if let issue = fieldIssues[key] { return issue }
        guard drafts[key] == nil, let document else { return nil }
        let messages = document.issues.filter { $0.path == key }.map(\.message)
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    /// The boxes are gone (the section or the window closed), so what they reported is too.
    public func clearInputInvalid() {
        invalidInputKeys = []
    }

    /// The view reports, on every change of a box, whether its text is a value.
    public func setInputInvalid(_ field: ConfigField, _ invalid: Bool) {
        if invalid {
            invalidInputKeys.insert(Self.key(field))
        } else {
            invalidInputKeys.remove(Self.key(field))
        }
    }

    /// Removes the key from the file, so the agent's default applies.
    public func resetToDefault(_ field: ConfigField) {
        set(field, .null)
    }

    public var isDirty: Bool { !dirtyFields.isEmpty }

    /// There is something to save and no box holds text the drafts do not show.
    public var canSave: Bool { !saving && invalidInputKeys.isEmpty && isDirty }

    public func discard() {
        drafts = [:]
        fieldIssues = [:]
        invalidInputKeys = []
        banner = nil
    }

    /// The view calls this once the agent was restarted, so the suggestion goes away.
    public func restartHandled() {
        restartSuggested = false
    }

    public func save() async {
        guard canSave, let document else { return }
        let edits = dirtyFields.map { ConfigEditRequest(path: $0.path, value: drafts[Self.key($0)] ?? .null) }
        let snapshot = drafts
        saving = true
        banner = nil
        fieldIssues = [:]
        defer { saving = false }
        let result: SaveResult
        do {
            result = try await client.saveConfig(base: document.sha256, edits: edits)
        } catch {
            switch error {
            case .failed, .badOutput: banner = Copy.configSaveFailed
            default: banner = MenuModel.message(for: error)
            }
            return
        }
        switch result.status {
        case "saved":
            // Edits made while the save was in flight are not in the file: keep them.
            for (key, value) in snapshot where drafts[key] == value { drafts[key] = nil }
            restartSuggested = true
            await load()
        case "invalid":
            for issue in result.issues {
                fieldIssues[issue.path] = fieldIssues[issue.path].map { "\($0) \(issue.message)" } ?? issue.message
            }
            // The form shows only messages that belong to a field; the rest must not vanish.
            let fieldKeys = Set(document.fields.map(Self.key))
            let unmatched = result.issues.filter { !fieldKeys.contains($0.path) }
            if result.issues.isEmpty {
                banner = Copy.configInvalid
            } else if !unmatched.isEmpty {
                let lines = unmatched.map { "\(DisplayText.clean($0.path, max: 80)): \(DisplayText.clean($0.message))" }
                banner = "\(Copy.configInvalid) \(lines.joined(separator: "; "))"
            }
        case "conflict":
            banner = Copy.configConflict
        case "bad-request":
            banner = Copy.configBadRequest
        default:
            banner = Copy.configSaveFailed
        }
    }

    private func baseline(of field: ConfigField) -> JSONValue {
        field.effective == .null ? field.value : field.effective
    }

    /// Fields whose draft would change the file, in the order of the field list. A draft equal to
    /// what the form showed before it is not a change, and neither is removing a key that is not
    /// in the file.
    private var dirtyFields: [ConfigField] {
        guard let document else { return [] }
        return document.fields.filter { field in
            guard let draft = drafts[Self.key(field)] else { return false }
            if draft == .null { return field.value != .null }
            return draft != baseline(of: field)
        }
    }
}
