import Foundation

// MARK: - Documents

/// One Teams message template, as `suica templates show --json` lists it.
public struct MessageTemplate: Codable, Equatable, Identifiable, Sendable {
    /// nudge, reminder, rereview, notice.approved, notice.changes, notice.comments, notice.findings or notice.refindings.
    public let name: String
    /// What the agent uses: the file's text when there is one, else the built-in text.
    public let text: String
    /// True when a file in the templates folder replaces the built-in template.
    public let custom: Bool
    public let defaultText: String

    public var id: String { name }

    public init(name: String, text: String, custom: Bool, defaultText: String) {
        self.name = name
        self.text = text
        self.custom = custom
        self.defaultText = defaultText
    }
}

/// `suica templates show --json`.
public struct TemplatesDocument: Codable, Equatable, Sendable {
    public let version: Int
    /// The templates folder.
    public let path: String
    public let placeholders: [String]
    public let templates: [MessageTemplate]

    public init(version: Int, path: String, placeholders: [String], templates: [MessageTemplate]) {
        self.version = version
        self.path = path
        self.placeholders = placeholders
        self.templates = templates
    }
}

/// `suica templates set --json`: saved, reset, invalid, bad-request or failed.
public struct TemplateSaveResult: Codable, Equatable, Sendable {
    public let status: String
    public let message: String?

    public init(status: String, message: String? = nil) {
        self.status = status
        self.message = message
    }
}

public protocol TemplatesClient: Sendable {
    func templates() async throws(AgentError) -> TemplatesDocument
    /// Nil text removes the file, so the built-in template applies again.
    func saveTemplate(name: String, text: String?) async throws(AgentError) -> TemplateSaveResult
}

// MARK: - Preview

/// Sample values for the preview, written as the agent writes real ones (escaped for Markdown).
public enum TemplatePreview {
    public static let recipient = "Rina Wijaya"
    static let title = "[ABC-12] feat: export the leave history"
    static let url = "https://gitlab.example/group/project/-/merge_requests/12"

    /// `text` with every placeholder filled in, as Teams would get it. An unknown placeholder
    /// stays as written, so the preview shows where it is.
    public static func render(_ text: String, owner: String = "You") -> String {
        let values: [String: String] = [
            "mr.title": escapeMarkdown(title),
            "mr.url": url,
            "mr.link": markdownLink(title: title, url: url),
            "mr.iid": "12",
            "mr.project": escapeMarkdown("group/project"),
            "person.name": escapeMarkdown(recipient),
            "owner.name": escapeMarkdown(owner),
            "agent.name": escapeMarkdown("Suica"),
            "review.findings": "ada 3 findings (1 Major, 2 Minor)",
        ]
        return text.replacing(/\{\{\s*([\w.]+)\s*\}\}/) { match in
            values[String(match.1)] ?? String(match.0)
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The placeholders `text` uses that the agent does not know; saving is refused while any remain.
    public static func unknownPlaceholders(in text: String, known: [String]) -> [String] {
        text.matches(of: /\{\{\s*([\w.]+)\s*\}\}/).map { String($0.1) }.filter { !known.contains($0) }
    }

    /// Same characters as the agent's `escapeMarkdown`.
    static func escapeMarkdown(_ text: String) -> String {
        text.replacing(/[\\`*_\[\]<>~#|]/) { "\\" + $0.output }
    }

    static func markdownLink(title: String, url: String) -> String {
        let target = url.replacing(/[ ()<>]/) { match in
            "%" + String(format: "%02X", match.output.unicodeScalars.first?.value ?? 0)
        }
        return "[\(escapeMarkdown(title))](\(target))"
    }
}

// MARK: - Model

/// The Message templates page: one draft per template, saved one at a time through the CLI.
@MainActor @Observable
public final class TemplateEditorModel {
    public private(set) var document: TemplatesDocument?
    public private(set) var drafts: [String: String] = [:]
    public private(set) var banner: String?
    public private(set) var issue: String?
    public private(set) var saving = false
    /// A template was saved or reset: the agent reads templates when it starts.
    public private(set) var restartSuggested = false
    public var selectedName = "nudge"

    @ObservationIgnored private let client: any TemplatesClient

    public init(client: any TemplatesClient) {
        self.client = client
    }

    public var selected: MessageTemplate? { document?.templates.first { $0.name == selectedName } }

    public func load() async {
        do {
            document = try await client.templates()
            banner = nil
        } catch {
            banner = MenuModel.message(for: error)
        }
    }

    public func text(of template: MessageTemplate) -> String { drafts[template.name] ?? template.text }

    public func setText(_ text: String, for template: MessageTemplate) {
        drafts[template.name] = text == template.text ? nil : text
        issue = nil
    }

    public func isDirty(_ template: MessageTemplate) -> Bool { drafts[template.name] != nil }

    public func unknownPlaceholders(in template: MessageTemplate) -> [String] {
        TemplatePreview.unknownPlaceholders(in: text(of: template), known: document?.placeholders ?? [])
    }

    public func canSave(_ template: MessageTemplate) -> Bool {
        !saving && isDirty(template) && unknownPlaceholders(in: template).isEmpty
            && !text(of: template).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func revert(_ template: MessageTemplate) {
        drafts[template.name] = nil
        issue = nil
    }

    public func save(_ template: MessageTemplate) async {
        guard canSave(template) else { return }
        await write(template, text: text(of: template))
    }

    /// Removes the file, so the built-in template applies again.
    public func resetToDefault(_ template: MessageTemplate) async {
        await write(template, text: nil)
    }

    public func restartHandled() { restartSuggested = false }

    private func write(_ template: MessageTemplate, text: String?) async {
        saving = true
        defer { saving = false }
        do {
            let result = try await client.saveTemplate(name: template.name, text: text)
            switch result.status {
            case "saved", "reset":
                drafts[template.name] = nil
                issue = nil
                restartSuggested = true
                banner = result.status == "saved" ? Copy.templateSaved : Copy.templateReset
                await load()
                banner = result.status == "saved" ? Copy.templateSaved : Copy.templateReset
            default:
                issue = DisplayText.clean(result.message ?? Copy.templateNotSaved, max: 300)
            }
        } catch {
            issue = MenuModel.message(for: error)
        }
    }
}
