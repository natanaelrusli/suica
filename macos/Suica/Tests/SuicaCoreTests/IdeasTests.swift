import Foundation
import Testing

@testable import SuicaCore

private func ideaOutput(_ json: String) -> Result<CommandResult, AgentError> {
    .success(CommandResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data()))
}

private let ideaConfig = AgentConfig(cliPath: "/bin/suica", searchPath: "/usr/bin")

private let ideaRecord = #"{"id":7,"text":"Build a tiny greenhouse","projectPath":null,"createdAt":1761700000000,"updatedAt":1761700000000,"archivedAt":null,"revision":1,"notes":[{"id":8,"text":"Ask about winter light","createdAt":1761700001000}],"planPaths":["/work/plans/greenhouse.md"],"sessions":[{"agent":"codex","sessionId":"session-1","linkedAt":1761700002000}]}"#

@Test func ideaDocumentsDecodeLocalContentAndReferences() throws {
    let list = try JSONDecoder().decode(IdeaListDocument.self, from: Data(#"{"status":"ok","ideas":[\#(ideaRecord)]}"#.utf8))
    let idea = try #require(list.ideas.first)
    #expect(list.status == "ok" && idea.id == 7 && idea.revision == 1)
    #expect(idea.projectPath == nil && idea.notes.first?.text == "Ask about winter light")
    #expect(idea.planPaths == ["/work/plans/greenhouse.md"])
    #expect(idea.sessions.first?.id == "codex/session-1")
}

@Test func ideasListCommandDecodesTheCLIContract() async throws {
    let response = #"{"status":"ok","ideas":[\#(ideaRecord)]}"#
    let runner = FakeRunner([ideaOutput(response)])
    let client = CLIAgentClient(config: ideaConfig, runner: runner)
    let reply = try await client.ideas(archived: false)
    #expect(reply.status == "ok" && reply.ideas.first?.text == "Build a tiny greenhouse")
}

@MainActor @Test func changingBrainstormQuestionInvalidatesTheRenderedPrompt() async throws {
    let list = ideaOutput(#"{"status":"ok","ideas":[\#(ideaRecord)]}"#)
    let prompt = ideaOutput(#"{"status":"ok","prompt":"Discuss these ideas.","length":20,"maxLength":8000,"withinLimit":true}"#)
    let runner = FakeRunner([list, prompt])
    let model = IdeasModel(client: CLIAgentClient(config: ideaConfig, runner: runner))
    await model.load()
    model.select(7)
    await model.buildPrompt()
    #expect(model.prompt?.prompt == "Discuss these ideas.")
    model.promptQuestion = "Explore another angle"
    #expect(model.prompt == nil)
}

@Test func promptCommandUsesIdsAndOmitsAbsentQuestionFromStdin() async throws {
    let promptReply = #"{"status":"ok","prompt":"Discuss these ideas.","length":20,"maxLength":8000,"withinLimit":true}"#
    let runner = FakeRunner([ideaOutput(promptReply)])
    let client = CLIAgentClient(config: ideaConfig, runner: runner)
    let reply = try await client.ideaPrompt(ids: [7, 9], question: nil)
    #expect(reply.prompt == "Discuss these ideas." && reply.withinLimit == true)
    let call = try #require(await runner.invocations.first)
    #expect(call.arguments == ["ideas", "prompt", "--json"])
    let payload = try #require(call.stdin)
    let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    #expect((object["ids"] as? [Int]) == [7, 9])
    #expect(object["question"] == nil)
}

@Test func ideasCreateAndCasUpdateUseStdinPayloads() async throws {
    let created = #"{"status":"ok","idea":\#(ideaRecord)}"#
    let updatedRecord = ideaRecord.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":2")
        .replacingOccurrences(of: "Build a tiny greenhouse", with: "Build a winter greenhouse")
    let updated = #"{"status":"ok","idea":\#(updatedRecord)}"#
    let runner = FakeRunner([ideaOutput(created), ideaOutput(updated)])
    let client = CLIAgentClient(config: ideaConfig, runner: runner)
    let first = try await client.createIdea(text: "Build a tiny greenhouse", projectPath: nil)
    let createdIdea = try #require(first.idea)
    let reply = try await client.updateIdea(id: createdIdea.id, revision: createdIdea.revision,
                                            text: "Build a winter greenhouse", projectPath: nil)
    #expect(createdIdea.id == 7 && reply.idea?.revision == 2)
    let calls = await runner.invocations
    #expect(calls.map(\.arguments) == [["ideas", "create", "--json"], ["ideas", "update", "7", "--json"]])
    let createPayload = try #require(calls[0].stdin)
    let updatePayload = try #require(calls[1].stdin)
    let createJSON = try #require(JSONSerialization.jsonObject(with: createPayload) as? [String: Any])
    let updateJSON = try #require(JSONSerialization.jsonObject(with: updatePayload) as? [String: Any])
    #expect(createJSON["text"] as? String == "Build a tiny greenhouse" && createJSON["projectPath"] is NSNull)
    #expect(updateJSON["revision"] as? Int == 1 && updateJSON["projectPath"] is NSNull)
}
