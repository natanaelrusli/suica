import Foundation
import Testing

@testable import MRACore

private func goldenData() throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return try Data(contentsOf: url.appending(path: "contracts/agent-state.v1.json"))
}

private func item(status: String) -> OutboxItem {
    OutboxItem(
        id: 1, kind: "nudge", status: status, detail: "", recipientName: "Bob", mrKey: "g/p!5",
        mrTitle: "t", mrUrl: "https://x", text: nil, createdAt: 0, updatedAt: 0)
}

@Test func decodesTheGoldenContract() throws {
    let state = try decodeAgentState(goldenData())
    #expect(state.version == 1 && state.trackedAuthored == 4 && state.reviewRequested == 5)
    #expect(state.paused == false && state.baselineDone == true)
    #expect(state.teams?.attention.first?.id == 2)
    #expect(state.teams?.attention.first?.state == .pending)
    #expect(state.teams?.attention.first?.actions == [.send, .skip])
    #expect(state.teams?.attention.first?.text == "Halo Bob")
    #expect(state.teams?.recent.first?.state == .sent)
    #expect(state.teams?.counts["dry-run"] == 0)
}

@Test func decodesTeamsDisabledAsNil() throws {
    let json = #"{"version":1,"paused":true,"baselineDone":false,"trackedAuthored":0,"reviewRequested":0,"teams":null}"#
    let state = try decodeAgentState(Data(json.utf8))
    #expect(state.teams == nil)
    #expect(state.paused)
}

@Test func rejectsANewerVersionBeforeLookingAtFields() {
    #expect(throws: AgentError.unsupportedVersion(2)) {
        try decodeAgentState(Data(#"{"version":2,"unknown":true}"#.utf8))
    }
}

@Test(arguments: ["not json", "", "[]", #"{"paused":true}"#])
func rejectsGarbage(text: String) {
    #expect(throws: AgentError.badOutput) { try decodeAgentState(Data(text.utf8)) }
}

@Test func treatsAnUnknownStatusAsUnknownWithNoActions() {
    let unknown = item(status: "teleported")
    #expect(unknown.state == .unknown)
    #expect(unknown.actions == [])
}

@Test(arguments: [
    ("pending", [ItemAction.send, .skip]), ("unresolved", [.retry, .skip]), ("queued", [.skip]),
    ("sent", []), ("failed", []), ("sending", []), ("skipped", []), ("dry-run", []),
])
func actionsFollowTheStatus(status: String, expected: [ItemAction]) {
    #expect(item(status: status).actions == expected)
}
