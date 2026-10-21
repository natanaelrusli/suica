import Foundation
import Testing

@testable import SuicaCore

private func contract(_ name: String) throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return try Data(contentsOf: url.appending(path: "contracts/\(name)"))
}

private func session(
    _ id: String, agent: String = "claude", room: String = "/work/suica", status: OfficeStatus = .working,
    activity: String = "Thinking", updatedAt: Int = 1_000
) -> OfficeSession {
    OfficeSession(
        agent: agent, sessionId: id, cwd: room, status: status, activity: activity, recentActions: [],
        startedAt: nil, updatedAt: updatedAt, pid: nil, room: room,
        roomName: String(room.split(separator: "/").last ?? ""), hostApp: nil)
}

private func document(_ sessions: [OfficeSession], at: Int = 0) -> OfficeDocument {
    OfficeDocument(version: 1, generatedAt: at, sessions: sessions)
}

private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

private actor FakeOfficeClient: OfficeClient {
    private var script: [Result<OfficeDocument, AgentError>]
    init(_ script: [Result<OfficeDocument, AgentError>]) { self.script = script }
    func office() async throws(AgentError) -> OfficeDocument {
        guard !script.isEmpty else { throw AgentError.launchFailed }
        return try script.removeFirst().get()
    }
}

// MARK: - Contract and client

@Test func officeMatchesTheGoldenFile() throws {
    let office = try decodeDocument(OfficeDocument.self, from: contract("office.v1.json"))
    #expect(office.sessions.map(\.agent) == ["gemini", "codex", "claude"])
    #expect(office.sessions.map(\.status) == [.idle, .waiting, .working])
    let claude = try #require(office.sessions.last)
    #expect(claude.room == "/work/suica" && claude.roomName == "suica" && claude.cwd == "/work/suica/macos")
    #expect(claude.activity == "Editing OfficeView.swift" && claude.recentActions.count == 2)
    #expect(claude.pid == 4001 && claude.hostApp == "/System/Applications/Utilities/Terminal.app")
    #expect(office.sessions[1].startedAt == nil && office.sessions[1].hostApp == nil)
}

@Test func anUnknownStatusIsIdle() throws {
    let json = #"{"version":1,"generatedAt":1,"sessions":[{"agent":"x","sessionId":"s","cwd":"/a","status":"napping","activity":"","recentActions":[],"startedAt":null,"updatedAt":1,"pid":null,"room":"/a","roomName":"a","hostApp":null,"newField":3}]}"#
    let office = try decodeDocument(OfficeDocument.self, from: Data(json.utf8))
    #expect(office.sessions.first?.status == .idle)
}

@Test func officeUsesItsCommand() async throws {
    let json = #"{"version":1,"generatedAt":9,"sessions":[]}"#
    let runner = FakeRunner([.success(CommandResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data()))])
    let client = CLIAgentClient(
        config: AgentConfig(cliPath: "/Users/me/.local/bin/suica", searchPath: "/usr/bin"), runner: runner)
    #expect(try await client.office().generatedAt == 9)
    #expect(await runner.invocations.map { $0.arguments } == [["office", "--json"]])
}

// MARK: - Text and colours

@Test func theBubbleSaysWhatTheAgentDoesInThirtyTwoCharacters() {
    #expect(session("a", activity: "Editing OfficeView.swift").bubble == "Editing OfficeView.swift")
    let long = session("a", activity: "Running " + String(repeating: "x", count: 80)).bubble
    #expect(long.count == 32 && long.hasSuffix("…"))
    #expect(session("a", activity: "").bubble == "Working")
    #expect(session("a", status: .waiting, activity: "Running rm x").bubble == "Waiting for you")
    #expect(session("a", status: .idle, activity: "").bubble == "Idle")
    #expect(session("a", status: .exited, activity: "").bubble == "Left the office")
    #expect(session("a", activity: "Running a\nb").bubble == "Running a b")
}

@Test func agentsHaveANameAndAColour() {
    #expect(OfficeAgent(kind: "claude").name == "Claude Code")
    #expect(OfficeAgent(kind: "codex").name == "Codex")
    #expect(OfficeAgent(kind: "gemini").name == "Gemini CLI")
    #expect(OfficeAgent(kind: "aider").name == "aider")
    let colours = ["claude", "codex", "gemini", "aider"].map { OfficeAgent(kind: $0).colour }
    #expect(Set(colours.map { "\($0.red)-\($0.green)-\($0.blue)" }).count == 4)
}

// MARK: - Model: diff

@MainActor @Test func aSessionArrivesUpdatesAndLeaves() {
    let model = OfficeModel(client: FakeOfficeClient([]))
    model.apply(document([session("a"), session("b")]), now: at(0))
    #expect(model.lastDiff.arrived == ["claude/a", "claude/b"] && model.lastDiff.departed.isEmpty)

    model.apply(document([session("a", activity: "Editing x.ts"), session("b")]), now: at(2))
    #expect(model.lastDiff.updated == ["claude/a"] && model.lastDiff.arrived.isEmpty)
    #expect(model.sessions.first { $0.sessionId == "a" }?.activity == "Editing x.ts")

    model.apply(document([session("a", activity: "Editing x.ts")]), now: at(4))
    #expect(model.lastDiff.departed == ["claude/b"])
    // It stays at its Desk, greyed, for five minutes.
    #expect(model.sessions.first { $0.sessionId == "b" }?.status == .exited)
    #expect(model.sessions.count == 2)

    model.apply(document([session("a", activity: "Editing x.ts")]), now: at(4 + 299))
    #expect(model.sessions.count == 2)
    model.apply(document([session("a", activity: "Editing x.ts")]), now: at(4 + 301))
    #expect(model.sessions.map(\.sessionId) == ["a"])
}

@MainActor @Test func aSessionThatComesBackIsLiveAgain() {
    let model = OfficeModel(client: FakeOfficeClient([]))
    model.apply(document([session("a")]), now: at(0))
    model.apply(document([]), now: at(2))
    #expect(model.sessions.first?.status == .exited)
    model.apply(document([session("a")]), now: at(10))
    #expect(model.sessions.first?.status == .working && model.lastDiff.arrived.isEmpty)
}

@MainActor @Test func theCliReportedExitedStayOutlastsNothingMoreThanItsFiveMinutes() {
    let model = OfficeModel(client: FakeOfficeClient([]))
    model.apply(document([session("a", status: .exited, updatedAt: 100_000)]), now: at(110))
    #expect(model.sessions.count == 1)
    model.apply(document([]), now: at(120))
    // Left when the CLI stopped reporting it, five minutes after its last sign of life at the latest.
    #expect(model.sessions.count == 1)
    model.apply(document([]), now: at(100 + 301))
    #expect(model.sessions.isEmpty)
}

@MainActor @Test func theSelectionEndsWhenItsSessionIsGone() {
    let model = OfficeModel(client: FakeOfficeClient([]))
    model.apply(document([session("a")]), now: at(0))
    model.select("claude/a")
    #expect(model.selected?.sessionId == "a")
    model.apply(document([]), now: at(2))
    #expect(model.selected?.status == .exited)
    model.apply(document([]), now: at(400))
    #expect(model.selected == nil && model.selectedId == nil)
}

@MainActor @Test func refreshKeepsTheLastGoodOfficeWhenTheCliFails() async {
    let model = OfficeModel(
        client: FakeOfficeClient([.success(document([session("a")])), .failure(.timedOut)]))
    await model.refresh(now: at(0))
    #expect(model.sessions.count == 1 && model.errorText == nil && model.loaded)
    await model.refresh(now: at(2))
    #expect(model.sessions.count == 1 && model.errorText != nil)
}

// MARK: - Model: rooms and layout

@MainActor @Test func sessionsAreGroupedByRoomAndKeepTheirDeskOrder() {
    let model = OfficeModel(client: FakeOfficeClient([]))
    model.apply(
        document([
            session("a", room: "/w/suica"), session("b", agent: "codex", room: "/w/kinsen"),
            session("c", room: "/w/suica"),
        ]), now: at(0))
    #expect(model.rooms.map(\.name) == ["kinsen", "suica"])
    #expect(model.rooms[1].sessions.map(\.sessionId) == ["a", "c"])
    // A later arrival takes the next desk; nobody moves.
    model.apply(
        document([
            session("z", room: "/w/suica"), session("a", room: "/w/suica"), session("c", room: "/w/suica"),
            session("b", agent: "codex", room: "/w/kinsen"),
        ]), now: at(2))
    #expect(model.rooms[1].sessions.map(\.sessionId) == ["a", "c", "z"])
}

private func rooms(_ counts: [Int]) -> [OfficeRoom] {
    counts.enumerated().map { index, count in
        let path = "/w/room\(index)"
        return OfficeRoom(
            path: path, name: "room\(index)",
            sessions: (0..<count).map { session("s\(index)-\($0)", room: path) })
    }
}

@Test func aRoomGrowsWithItsDesks() {
    let widths = [1, 3, 4, 7].map { OfficeLayout.make(rooms(Array(repeating: 0, count: 0) + [$0])).rooms[0] }
    #expect(widths[0].depth == widths[1].depth)
    #expect(widths[1].width > widths[0].width)
    #expect(widths[2].depth > widths[1].depth)
    #expect(widths[3].depth > widths[2].depth)
    #expect(widths.map { $0.desks.count } == [1, 3, 4, 7])
}

@Test func desksSitInsideTheirRoomWithoutOverlapping() {
    let layout = OfficeLayout.make(rooms([1, 5, 2, 4, 3]))
    for room in layout.rooms {
        let seen = Set(room.desks.map { "\($0.position.x),\($0.position.z)" })
        #expect(seen.count == room.desks.count)
        for desk in room.desks {
            #expect(abs(desk.position.x - room.center.x) <= room.width / 2 - 0.5)
            #expect(abs(desk.position.z - room.center.z) <= room.depth / 2 - 0.5)
        }
    }
}

@Test func roomsDoNotOverlapAndTheOfficeIsCentred() {
    let layout = OfficeLayout.make(rooms([3, 1, 6, 2, 2]))
    let placed = layout.rooms
    for (index, one) in placed.enumerated() {
        for other in placed[(index + 1)...] {
            let apartX = abs(one.center.x - other.center.x) >= (one.width + other.width) / 2
            let apartZ = abs(one.center.z - other.center.z) >= (one.depth + other.depth) / 2
            #expect(apartX || apartZ)
        }
    }
    let minX = placed.map { $0.center.x - $0.width / 2 }.min() ?? 0
    let maxX = placed.map { $0.center.x + $0.width / 2 }.max() ?? 0
    #expect(abs(minX + maxX) < 0.001)
    #expect(layout.width >= maxX - minX - 0.001)
}

@Test func anEmptyOfficeHasNoRooms() {
    let layout = OfficeLayout.make([])
    #expect(layout.rooms.isEmpty && layout.width > 0 && layout.depth > 0)
}
