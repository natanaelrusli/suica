import Foundation

// MARK: - Documents

/// One template, as `suica templates show --json` lists it: a Teams message, or the title and
/// body of a notification to you (`group` "alert").
public struct MessageTemplate: Codable, Equatable, Identifiable, Sendable {
    /// nudge, reminder, rereview, notice.approved, notice.changes, notice.comments, notice.findings,
    /// notice.refindings, notice.reapproved, or an `alert.` name.
    public let name: String
    /// "teams" or "alert"; "teams" from an agent that predates notification templates.
    public let group: String
    /// The placeholders this template may use; nil from an agent that predates them, where the
    /// document's list applies.
    public let placeholders: [String]?
    /// What the agent uses: the file's text when there is one, else the built-in text.
    public let text: String
    /// True when a file in the templates folder replaces the built-in template.
    public let custom: Bool
    public let defaultText: String

    public var id: String { name }
    public var isAlert: Bool { group == "alert" }

    public init(
        name: String, text: String, custom: Bool, defaultText: String, group: String = "teams",
        placeholders: [String]? = nil
    ) {
        self.name = name
        self.text = text
        self.custom = custom
        self.defaultText = defaultText
        self.group = group
        self.placeholders = placeholders
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        text = try container.decode(String.self, forKey: .text)
        custom = try container.decode(Bool.self, forKey: .custom)
        defaultText = try container.decode(String.self, forKey: .defaultText)
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? "teams"
        placeholders = try container.decodeIfPresent([String].self, forKey: .placeholders)
    }
}

/// `suica templates show --json`.
public struct TemplatesDocument: Codable, Equatable, Sendable {
    public let version: Int
    /// The templates folder.
    public let path: String
    public let placeholders: [String]
    public let templates: [MessageTemplate]
    /// The `:name:` shortcodes the agent turns into emoji; empty from an older agent.
    public let emoji: [String: String]

    public init(
        version: Int, path: String, placeholders: [String], templates: [MessageTemplate], emoji: [String: String] = [:]
    ) {
        self.version = version
        self.path = path
        self.placeholders = placeholders
        self.templates = templates
        self.emoji = emoji
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        path = try container.decode(String.self, forKey: .path)
        placeholders = try container.decode([String].self, forKey: .placeholders)
        templates = try container.decode([MessageTemplate].self, forKey: .templates)
        emoji = try container.decodeIfPresent([String: String].self, forKey: .emoji) ?? [:]
    }

    /// What `template` may use.
    public func placeholders(for template: MessageTemplate) -> [String] {
        template.placeholders ?? placeholders
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

    /// `text` with its shortcodes and every placeholder filled in, as Teams would get it. An
    /// unknown placeholder stays as written, so the preview shows where it is.
    public static func render(
        _ text: String, owner: String = "You", emoji: [String: String] = [:], hour: Int = 10
    ) -> String {
        let values: [String: String] = [
            "mr.title": escapeMarkdown(title),
            "mr.url": url,
            "mr.link": markdownLink(title: title, url: url),
            "mr.iid": "12",
            "mr.project": escapeMarkdown("group/project"),
            "person.name": escapeMarkdown(recipient),
            "person.firstName": escapeMarkdown(String(recipient.split(separator: " ").first ?? "")),
            "owner.name": escapeMarkdown(owner),
            "agent.name": escapeMarkdown("Suica"),
            "review.findings": "ada 3 findings (1 Major, 2 Minor)",
            "time.greeting": greeting(hour: hour),
        ]
        return EmojiShortcodes.expand(text, table: emoji).replacing(/\{\{\s*([\w.]+)\s*\}\}/) { match in
            values[String(match.1)] ?? String(match.0)
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The agent's `time.greeting` for a local hour.
    public static func greeting(hour: Int) -> String {
        switch hour {
        case 4..<11: "pagi"
        case 11..<15: "siang"
        case 15..<18: "sore"
        default: "malam"
        }
    }

    /// A rendered message cut into text and the https images in it (`![alt](url)`), in order,
    /// so the preview can show each GIF. An image from anything but https stays as text.
    public static func segments(_ rendered: String) -> [PreviewSegment] {
        var segments: [PreviewSegment] = []
        var rest = Substring(rendered)
        while let match = rest.firstMatch(of: /!\[([^\]\n]*)\]\((https:\/\/[^)\s]+)\)/) {
            let before = String(rest[..<match.range.lowerBound]).trimmingCharacters(in: .newlines)
            if !before.isEmpty { segments.append(.text(before)) }
            if let url = DisplayText.safeURL(String(match.2)) {
                segments.append(.image(alt: String(match.1), url: url))
            } else {
                segments.append(.text(String(match.0)))
            }
            rest = rest[match.range.upperBound...]
        }
        let tail = String(rest).trimmingCharacters(in: .newlines)
        if !tail.isEmpty || segments.isEmpty { segments.append(.text(tail)) }
        return segments
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

public enum PreviewSegment: Equatable, Sendable {
    case text(String)
    case image(alt: String, url: URL)
}

/// Sample values for a notification template, as the agent fills them in: plain text.
public enum AlertPreview {
    static let values: [String: String] = [
        "mr.title": "[ABC-12] feat: export the leave history",
        "mr.iid": "12",
        "mr.project": "group/project",
        "mr.url": "https://gitlab.example/group/project/-/merge_requests/12",
        "author.name": "Rina Wijaya",
        "activity.summary": "Budi Santoso menyetujui; 2 komentar baru dari Rina Wijaya",
        "alert.count": "5",
        "alert.titles": "Diminta review: [ABC-12] feat: export | !7: fix: login +2 lainnya",
        "reviewers.names": "Budi Santoso dan Rina Wijaya",
        "review.reason": "the model CLI timed out after 20 minutes",
    ]

    /// The title (first line) and body (the rest) of an alert template.
    public static func split(_ text: String) -> (title: String, body: String) {
        guard let end = text.firstIndex(of: "\n") else { return (text, "") }
        return (String(text[..<end]), String(text[text.index(after: end)...]))
    }

    public static func join(title: String, body: String) -> String {
        "\(title.replacingOccurrences(of: "\n", with: " "))\n\(body)"
    }

    /// The notification as it would show, cleaned to one line each like the agent does.
    public static func render(_ text: String, emoji: [String: String] = [:]) -> (title: String, body: String) {
        let filled = { (part: String) -> String in
            let expanded = EmojiShortcodes.expand(part, table: emoji).replacing(/\{\{\s*([\w.]+)\s*\}\}/) { match in
                values[String(match.1)] ?? String(match.0)
            }
            return DisplayText.clean(expanded, max: 200)
        }
        let parts = split(text)
        return (filled(parts.title), filled(parts.body))
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
    /// The variant each Teams template shows in the editor; 0 when absent.
    public private(set) var variantIndex: [String: Int] = [:]

    @ObservationIgnored private let client: any TemplatesClient

    public init(client: any TemplatesClient) {
        self.client = client
    }

    public var selected: MessageTemplate? { document?.templates.first { $0.name == selectedName } }
    public var teamsTemplates: [MessageTemplate] { document?.templates.filter { !$0.isAlert } ?? [] }
    public var alertTemplates: [MessageTemplate] { document?.templates.filter(\.isAlert) ?? [] }
    public var emoji: [String: String] { document?.emoji ?? [:] }

    public func placeholders(for template: MessageTemplate) -> [String] {
        document?.placeholders(for: template) ?? []
    }

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
        TemplatePreview.unknownPlaceholders(in: text(of: template), known: placeholders(for: template))
    }

    /// Why the draft cannot be saved yet, beyond unknown placeholders; nil when it can.
    public func missingPart(of template: MessageTemplate) -> String? {
        let blank = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if template.isAlert {
            let parts = AlertPreview.split(text(of: template))
            if blank(parts.title) { return Copy.alertNeedsTitle }
            if blank(parts.body) { return Copy.alertNeedsBody }
            return nil
        }
        return variants(of: template).contains(where: blank) ? Copy.templateEmptyVariant : nil
    }

    public func canSave(_ template: MessageTemplate) -> Bool {
        !saving && isDirty(template) && unknownPlaceholders(in: template).isEmpty && missingPart(of: template) == nil
    }

    // MARK: Variants

    public func variants(of template: MessageTemplate) -> [String] { TemplateVariants.split(text(of: template)) }

    /// The variant the editor shows, kept within the variants there are.
    public func selectedVariant(of template: MessageTemplate) -> Int {
        min(variantIndex[template.name] ?? 0, variants(of: template).count - 1)
    }

    public func selectVariant(_ index: Int, of template: MessageTemplate) {
        variantIndex[template.name] = max(0, min(index, variants(of: template).count - 1))
    }

    public func setVariantText(_ text: String, for template: MessageTemplate) {
        var all = variants(of: template)
        all[selectedVariant(of: template)] = text
        setText(TemplateVariants.join(all), for: template)
    }

    /// Adds a variant after the others, starting as a copy of the one shown, and shows it.
    public func addVariant(to template: MessageTemplate) {
        var all = variants(of: template)
        all.append(all[selectedVariant(of: template)])
        setText(TemplateVariants.join(all), for: template)
        variantIndex[template.name] = all.count - 1
    }

    public func removeVariant(from template: MessageTemplate) {
        var all = variants(of: template)
        guard all.count > 1 else { return }
        all.remove(at: selectedVariant(of: template))
        setText(TemplateVariants.join(all), for: template)
        variantIndex[template.name] = min(selectedVariant(of: template), all.count - 1)
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
