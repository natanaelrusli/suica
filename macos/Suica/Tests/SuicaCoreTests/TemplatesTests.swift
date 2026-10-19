import Foundation
import Testing

@testable import SuicaCore

private func contract(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../contracts/\(name)").standardized
    return try Data(contentsOf: root)
}

private func output(_ text: String, exit: Int32 = 0) -> Result<CommandResult, AgentError> {
    .success(CommandResult(exitCode: exit, stdout: Data(text.utf8), stderr: Data()))
}

actor FakeTemplatesClient: TemplatesClient {
    var document: TemplatesDocument
    var result = TemplateSaveResult(status: "saved")
    private(set) var saves: [(name: String, text: String?)] = []

    init(document: TemplatesDocument) { self.document = document }

    func setResult(_ next: TemplateSaveResult) { result = next }

    func templates() async throws(AgentError) -> TemplatesDocument { document }

    func saveTemplate(name: String, text: String?) async throws(AgentError) -> TemplateSaveResult {
        saves.append((name, text))
        if result.status == "saved" || result.status == "reset" {
            document = TemplatesDocument(
                version: 1, path: document.path, placeholders: document.placeholders,
                templates: document.templates.map {
                    $0.name == name
                        ? MessageTemplate(name: name, text: text ?? $0.defaultText, custom: text != nil, defaultText: $0.defaultText)
                        : $0
                })
        }
        // Like the CLI: removing the file answers reset.
        return text == nil && result.status == "saved" ? TemplateSaveResult(status: "reset") : result
    }
}

@Test func theTemplatesContractDecodes() throws {
    let document = try decodeDocument(TemplatesDocument.self, from: contract("templates.v1.json"))
    #expect(
        Set(document.templates.map(\.name))
            == ["nudge", "reminder", "rereview", "notice.approved", "notice.changes", "notice.comments"])
    // Every template the agent lists has its own title and description in the window.
    for name in document.templates.map(\.name) {
        #expect(Copy.templateTitle(name) != name && !Copy.templateWhen(name).isEmpty, "\(name)")
    }
    #expect(document.placeholders.contains("mr.link"))
    #expect(document.templates.allSatisfy { !$0.custom && $0.text == $0.defaultText && $0.text.contains("{{mr.link}}") })
}

@Test func thePreviewEscapesAndLinksAsTheAgentDoes() {
    // The same cases as the agent's own tests (test/templates.test.ts).
    #expect(TemplatePreview.escapeMarkdown("[ESS-28] feat(x): a_b *c* `d` <e> ~f~ #1 | \\")
        == "\\[ESS-28\\] feat(x): a\\_b \\*c\\* \\`d\\` \\<e\\> \\~f\\~ \\#1 \\| \\\\")
    #expect(TemplatePreview.markdownLink(title: "t", url: "https://x.example/a (b)<c>")
        == "[t](https://x.example/a%20%28b%29%3Cc%3E)")
    #expect(TemplatePreview.render("Halo {{person.name}},\n{{ mr.link }}\n{{nope}}")
        == "Halo Rina Wijaya,\n[\\[ABC-12\\] feat: export the leave history](https://gitlab.example/group/project/-/merge_requests/12)\n{{nope}}")
    #expect(TemplatePreview.unknownPlaceholders(in: "{{mr.url}} {{ person.nmae }}", known: ["mr.url"]) == ["person.nmae"])
}

@MainActor @Test func editingSavingAndResettingATemplate() async throws {
    let document = try decodeDocument(TemplatesDocument.self, from: contract("templates.v1.json"))
    let client = FakeTemplatesClient(document: document)
    let model = TemplateEditorModel(client: client)
    await model.load()
    let nudge = try #require(model.selected)
    #expect(!model.isDirty(nudge) && !model.canSave(nudge))

    model.setText("Hi {{person.nmae}}", for: nudge)
    #expect(model.isDirty(nudge) && model.unknownPlaceholders(in: nudge) == ["person.nmae"] && !model.canSave(nudge))
    model.setText(nudge.text, for: nudge)
    #expect(!model.isDirty(nudge))

    model.setText("Hi {{person.name}}\n{{mr.link}}", for: nudge)
    #expect(model.canSave(nudge))
    await model.save(nudge)
    #expect(await client.saves.map(\.text) == ["Hi {{person.name}}\n{{mr.link}}"])
    let saved = try #require(model.selected)
    #expect(saved.custom && saved.text == "Hi {{person.name}}\n{{mr.link}}" && !model.isDirty(saved))
    #expect(model.restartSuggested && model.banner == Copy.templateSaved)

    await model.resetToDefault(saved)
    #expect(await client.saves.last?.text == nil)
    #expect(model.selected?.custom == false && model.banner == Copy.templateReset)
}

@MainActor @Test func aRefusedSaveKeepsTheDraftAndSaysWhy() async throws {
    let document = try decodeDocument(TemplatesDocument.self, from: contract("templates.v1.json"))
    let client = FakeTemplatesClient(document: document)
    await client.setResult(TemplateSaveResult(status: "failed", message: "cannot write the template file"))
    let model = TemplateEditorModel(client: client)
    await model.load()
    let nudge = try #require(model.selected)
    model.setText("Hi {{person.name}}", for: nudge)
    await model.save(nudge)
    #expect(model.issue == "cannot write the template file" && model.isDirty(nudge) && !model.restartSuggested)
}

@Test func saveTemplateSendsNameAndTextOrAnExplicitNull() async throws {
    let runner = FakeRunner([output(#"{"status":"saved"}"#), output(#"{"status":"invalid","message":"bad"}"#, exit: 1)])
    let client = CLIAgentClient(config: AgentConfig(cliPath: "/x/suica", searchPath: "/usr/bin"), runner: runner)
    #expect(try await client.saveTemplate(name: "nudge", text: "Hi") == TemplateSaveResult(status: "saved"))
    #expect(try await client.saveTemplate(name: "reminder", text: nil) == TemplateSaveResult(status: "invalid", message: "bad"))
    let calls = await runner.invocations
    #expect(calls.map(\.arguments) == [["templates", "set", "--json"], ["templates", "set", "--json"]])
    let bodies = calls.map { String(decoding: $0.stdin ?? Data(), as: UTF8.self) }
    #expect(bodies[0].contains(#""name":"nudge""#) && bodies[0].contains(#""text":"Hi""#))
    #expect(bodies[1].contains(#""text":null"#))
}
