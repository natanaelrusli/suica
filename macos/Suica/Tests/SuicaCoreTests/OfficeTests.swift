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
    activity: String = "Thinking", updatedAt: Int = 1_000, title: String? = nil
) -> OfficeSession {
    OfficeSession(
        agent: agent, sessionId: id, title: title, cwd: room, status: status, activity: activity, recentActions: [],
        startedAt: nil, updatedAt: updatedAt, pid: nil, room: room,
        roomName: String(room.split(separator: "/").last ?? ""), hostApp: nil)
}

private func document(_ sessions: [OfficeSession], at: Int = 0) -> OfficeDocument {
    OfficeDocument(version: 1, generatedAt: at, sessions: sessions)
}

private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

private actor FakeOfficeClient: OfficeClient {
    private var script: [Result<OfficeDocument, AgentError>]
    private var chats: [Result<OfficeChatDocument, AgentError>]
    private(set) var chatCalls: [String] = []
    init(_ script: [Result<OfficeDocument, AgentError>], chats: [Result<OfficeChatDocument, AgentError>] = []) {
        self.script = script
        self.chats = chats
    }
    func office() async throws(AgentError) -> OfficeDocument {
        guard !script.isEmpty else { throw AgentError.launchFailed }
        return try script.removeFirst().get()
    }
    func chat(agent: String, sessionId: String) async throws(AgentError) -> OfficeChatDocument {
        chatCalls.append("\(agent)/\(sessionId)")
        guard !chats.isEmpty else { throw AgentError.launchFailed }
        return try chats.removeFirst().get()
    }
    private var sends: [Result<ActionResult, AgentError>] = []
    private(set) var sent: [String] = []
    func script(sends: [Result<ActionResult, AgentError>]) { self.sends = sends }
    func send(agent: String, sessionId: String, message: String) async throws(AgentError) -> ActionResult {
        sent.append("\(agent)/\(sessionId): \(message)")
        guard !sends.isEmpty else { throw AgentError.launchFailed }
        return try sends.removeFirst().get()
    }
}

private func chat(_ messages: [OfficeChatMessage], title: String? = "A title") -> OfficeChatDocument {
    OfficeChatDocument(version: 1, agent: "claude", sessionId: "a", title: title, messages: messages)
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
    #expect(office.sessions.map(\.title) == ["Probe the CLI", nil, "Office chat window"])
}

@Test func theChatMatchesTheGoldenFile() throws {
    let chat = try decodeDocument(OfficeChatDocument.self, from: contract("office-chat.v1.json"))
    #expect(chat.agent == "claude" && chat.sessionId == "c1" && chat.title == "Office chat window")
    #expect(chat.messages.map(\.role) == [.user, .assistant])
    #expect(chat.messages.first?.at == 1_792_549_940_000)
    #expect(chat.messages.last?.text.hasPrefix("I'll add a chat panel") == true)
}

@Test func aSessionWithoutATitleReadsAsItsAgentAndAnUnknownRoleAsTheAgents() throws {
    let json = #"{"version":1,"generatedAt":1,"sessions":[{"agent":"codex","sessionId":"s","cwd":"/a","status":"idle","activity":"","recentActions":[],"startedAt":null,"updatedAt":1,"pid":null,"room":"/a","roomName":"a","hostApp":null}]}"#
    let office = try decodeDocument(OfficeDocument.self, from: Data(json.utf8))
    #expect(office.sessions.first?.title == nil && office.sessions.first?.heading == "Codex")
    #expect(office.sessions.first?.bubbleTitle == "")
    let chatJson = #"{"version":1,"agent":"codex","sessionId":"s","title":null,"messages":[{"at":0,"role":"system","text":"hi"}]}"#
    let chat = try decodeDocument(OfficeChatDocument.self, from: Data(chatJson.utf8))
    #expect(chat.messages.first?.role == .assistant)
}

@Test func theTitleIsCleanedForTheHeadingAndClippedOnTheBubble() {
    let long = session("a", title: "  Fix the\nlogin   page " + String(repeating: "x", count: 40))
    #expect(long.heading.hasPrefix("Fix the login page x") && !long.heading.contains("\n"))
    #expect(long.bubbleTitle.count == 28 && long.bubbleTitle.hasSuffix("…"))
    #expect(session("a", title: "   ").heading == "Claude Code")
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

@MainActor @Test func selectingASessionReadsItsConversationAndDeselectingDropsIt() async {
    let messages = [OfficeChatMessage(at: 1, role: .user, text: "Hi"), OfficeChatMessage(at: 2, role: .assistant, text: "Hello")]
    let client = FakeOfficeClient(
        [.success(document([session("a")])), .success(document([session("a")]))],
        chats: [.success(chat(messages)), .failure(.timedOut), .success(chat([]))])
    let model = OfficeModel(client: client)
    await model.refresh(now: at(0))
    #expect(model.chat == nil)
    // Nothing to read until a Session is selected.
    await model.loadChat()
    let before = await client.chatCalls
    #expect(before.isEmpty)

    model.select("claude/a")
    await model.loadChat()
    #expect(model.chat?.messages == messages && model.chatError == nil)
    let first = await client.chatCalls
    #expect(first == ["claude/a"])
    // A poll reads the conversation again; a failure keeps the last one and says why.
    await model.refresh(now: at(2))
    #expect(model.chat?.messages == messages && model.chatError != nil)
    let second = await client.chatCalls
    #expect(second.count == 2)

    model.select(nil)
    #expect(model.chat == nil && model.chatError == nil)
    await model.loadChat()
    let third = await client.chatCalls
    #expect(third.count == 2)
}

@MainActor @Test func aConversationThatArrivesAfterADeselectionIsDropped() async {
    let client = FakeOfficeClient([], chats: [.success(chat([OfficeChatMessage(at: 1, role: .user, text: "Hi")]))])
    let model = OfficeModel(client: client)
    model.apply(document([session("a"), session("b")]), now: at(0))
    model.select("claude/a")
    async let reading: Void = model.loadChat()
    // Lets the read start (and wait on the client) before the selection moves on.
    await Task.yield()
    model.select("claude/b")
    await reading
    #expect(model.chat == nil)
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
    let widths = [1, 3, 4, 7].map { OfficeLayout.make(rooms([$0])).rooms[0] }
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

@Test func roomsDoNotOverlapAndTheBuildingIsCentred() {
    let layout = OfficeLayout.make(rooms([3, 1, 6, 2, 2]))
    let placed = layout.all
    for (index, one) in placed.enumerated() {
        for other in placed[(index + 1)...] {
            let apartX = abs(one.center.x - other.center.x) >= (one.width + other.width) / 2 - 0.001
            let apartZ = abs(one.center.z - other.center.z) >= (one.depth + other.depth) / 2 - 0.001
            #expect(apartX || apartZ)
        }
    }
    let minX = placed.map { $0.center.x - $0.width / 2 }.min() ?? 0
    let maxX = placed.map { $0.center.x + $0.width / 2 }.max() ?? 0
    let minZ = placed.map { $0.center.z - $0.depth / 2 }.min() ?? 0
    let maxZ = placed.map { $0.center.z + $0.depth / 2 }.max() ?? 0
    #expect(abs(minX + maxX) < 0.001 && abs(minZ + maxZ) < 0.001)
    #expect(abs(layout.width - (maxX - minX)) < 0.001 && abs(layout.depth - (maxZ - minZ)) < 0.001)
}

@Test func theCenterRoomRunsBetweenTwoRowsOfRoomsThatOpenOntoIt() {
    let layout = OfficeLayout.make(rooms([2, 5, 1, 3]))
    let center = layout.center
    #expect(center.isCenter && center.name == Copy.officeCenterRoom && center.desks.isEmpty)
    #expect(abs(center.width - layout.width) < 0.001)
    let far = layout.rooms.filter { $0.center.z < center.center.z }
    let near = layout.rooms.filter { $0.center.z > center.center.z }
    #expect(far.map(\.name) == ["room0", "room2"] && near.map(\.name) == ["room1", "room3"])
    // Each row fills the building's width and touches the Center Room, so it is connected.
    for (row, side) in [(far, OfficeSide.south), (near, OfficeSide.north)] {
        #expect(abs(row.map(\.width).reduce(0, +) - layout.width) < 0.001)
        for room in row {
            #expect(room.door == side && !room.isCenter)
            let gap = abs(room.center.z - center.center.z) - (room.depth + center.depth) / 2
            #expect(abs(gap) < 0.001)
        }
    }
}

@Test func aSingleRoomLeavesTheNearSideOfTheCenterRoomOpen() {
    let layout = OfficeLayout.make(rooms([2]))
    #expect(layout.rooms.count == 1 && layout.rooms[0].center.z < layout.center.center.z)
    #expect(layout.center.walls == [.west, .east])
    #expect(abs(layout.depth - (layout.rooms[0].depth + layout.center.depth)) < 0.001)
}

@Test func anEmptyOfficeIsJustTheCenterRoom() {
    let layout = OfficeLayout.make([])
    #expect(layout.rooms.isEmpty && layout.width > 0 && layout.depth > 0)
    #expect(layout.center.isCenter && layout.center.width == layout.width && layout.center.depth == layout.depth)
}

// MARK: - Walking

@Test func aFigureWalksFromTheDoorAlongTheAisleAndDownTheGapToItsChair() {
    let layout = OfficeLayout.make(rooms([5, 4, 2]))
    for room in layout.rooms {
        let out = room.door == .north ? -1.0 : 1.0
        for desk in room.desks {
            let path = OfficeLayout.walk(in: room, to: desk)
            // It starts in the doorway and ends at the chair, in front of the Desk.
            #expect(path.start == OfficePoint(x: room.center.x, z: room.center.z + out * room.depth / 2))
            #expect(path.end == OfficePoint(x: desk.position.x, z: desk.position.z + OfficeLayout.chairOffset))
            #expect(path.length > 0 && path.points.count >= 3)
            // Every point stays inside the Room.
            for point in path.points {
                #expect(abs(point.x - room.center.x) <= room.width / 2 + 0.001)
                #expect(abs(point.z - room.center.z) <= room.depth / 2 + 0.001)
            }
            // It walks through no other Desk: a Desk with its chair spans 1.2 m across and from 0.45
            // behind to 0.8 in front; the path is sampled every 5 cm.
            var distance = 0.0
            while distance <= path.length {
                let point = path.position(at: distance).point
                for other in room.desks where other.sessionId != desk.sessionId {
                    let inside =
                        abs(point.x - other.position.x) < 0.6 && point.z > other.position.z - 0.45
                        && point.z < other.position.z + 0.8
                    #expect(!inside, "\(desk.sessionId) walks through \(other.sessionId) at \(point)")
                }
                distance += 0.05
            }
        }
    }
}

@Test func aPathKnowsWhereItsWalkerIsAndWhichWayItFaces() {
    let path = OfficePath([OfficePoint(x: 0, z: 0), OfficePoint(x: 0, z: 0), OfficePoint(x: 2, z: 0), OfficePoint(x: 2, z: -1)])
    #expect(path.points.count == 3 && path.length == 3)
    let half = path.position(at: 1)
    #expect(half.point == OfficePoint(x: 1, z: 0) && half.heading == OfficePoint(x: 1, z: 0))
    let turned = path.position(at: 2.5)
    #expect(turned.point == OfficePoint(x: 2, z: -0.5) && turned.heading == OfficePoint(x: 0, z: -1))
    #expect(path.position(at: -1).point == path.start && path.position(at: 9).point == path.end)
    #expect(OfficePath([]).position(at: 1).heading == nil)
    #expect(OfficePath([OfficePoint(x: 1, z: 1)]).length == 0)
}

// MARK: - Looks and furniture

@Test func aFigureKeepsItsLookAndFiguresDiffer() {
    let looks = (0..<40).map { OfficeLook(session: session("s\($0)")) }
    #expect(OfficeLook(session: session("s7")) == looks[7])
    #expect(Set(looks.map { "\($0.hair)" }).count >= 4)
    #expect(Set(looks.map { "\($0.skin.red)" }).count >= 4)
    #expect(Set(looks.map { "\($0.shirt)" }).count >= 3)
    #expect(Set(looks.map { "\($0.extra)" }).count == 3)
}

@Test func aShirtStaysTheAgentsColour() {
    for index in 0..<20 {
        let codex = OfficeLook(session: session("c\(index)", agent: "codex")).shirtColour
        #expect(codex.green > codex.red)
        let claude = OfficeLook(session: session("a\(index)", agent: "claude")).shirtColour
        #expect(claude.red > claude.blue)
    }
}

@Test func greyedKeepsLightnessButDropsColour() {
    let coral = OfficeAgent(kind: "claude").colour.greyed
    #expect(abs(coral.red - coral.blue) < 0.1)
    #expect(OfficeColour(red: 0.1, green: 0.1, blue: 0.1).greyed.red < OfficeColour(red: 0.9, green: 0.9, blue: 0.9).greyed.red)
}

@Test func everyRoomIsFurnishedTheSameWayEachTime() {
    let layout = OfficeLayout.make(rooms([1, 3, 4, 2, 7, 1]))
    #expect(layout == OfficeLayout.make(rooms([1, 3, 4, 2, 7, 1])))
    for room in layout.all { #expect(room.furniture.count >= 2) }
    #expect(OfficeLayout.make([]).center.furniture.count >= 2)
    // Different Rooms are furnished differently.
    #expect(Set(layout.rooms.map { $0.furniture.map { "\($0.kind)" } }).count > 1)
}

@Test func furnitureStandsAgainstASideWallClearOfDesksDoorsAndTheView() {
    let half = OfficeLayout.furnitureSize / 2
    for layout in [OfficeLayout.make(rooms([1, 3, 4, 2, 7, 1, 5, 6])), OfficeLayout.make([])] {
        for room in layout.all {
            for piece in room.furniture {
                let x = piece.position.x - room.center.x
                let z = piece.position.z - room.center.z
                #expect(abs(x) + half <= room.width / 2 - 0.06 && abs(z) + half <= room.depth / 2 - 0.06)
                #expect(piece.against == (x < 0 ? .west : .east))
                // The doorway is 1.4 m wide in the middle of a wall.
                #expect(abs(x) - half > 0.7)
                // Tall pieces only in the back half, where they hide nothing from the camera.
                if piece.kind.isTall { #expect(z < 0) }
                for desk in room.desks {
                    // A Desk with its chair spans 1.2 m across and from 0.45 behind to 0.8 in front.
                    let apartX = abs(piece.position.x - desk.position.x) >= half + 0.6
                    let apartZ = piece.position.z + half <= desk.position.z - 0.45
                        || piece.position.z - half >= desk.position.z + 0.8
                    #expect(apartX || apartZ)
                }
            }
            let spots = Set(room.furniture.map { "\($0.position.x),\($0.position.z)" })
            #expect(spots.count == room.furniture.count)
        }
    }
}

@Test func theCornerUnderARoomsNameStaysFree() {
    for room in OfficeLayout.make(rooms([1, 3, 4, 2, 7, 1])).all {
        for piece in room.furniture {
            #expect(!(piece.position.x < room.center.x && piece.position.z > room.center.z + room.depth / 2 - 1))
        }
    }
}

// MARK: - Camera

@Test func wheelZoomStepsInOnScrollUpAndUndoesItselfOnScrollDown() {
    let closer = OfficeCamera.zoomFactor(scrollDelta: 1, precise: false)
    let farther = OfficeCamera.zoomFactor(scrollDelta: -1, precise: false)
    #expect(closer > 1)
    #expect(farther < 1)
    #expect(abs(closer * farther - 1) < 1e-9)
    #expect(abs(closer - 1.1275) < 0.001)
}

@Test func wheelZoomClampsAFastSpin() {
    let fast = OfficeCamera.zoomFactor(scrollDelta: 30, precise: false)
    #expect(fast == OfficeCamera.zoomFactor(scrollDelta: 3, precise: false))
    #expect(fast < 1.5)
    #expect(OfficeCamera.zoomFactor(scrollDelta: .nan, precise: false) == 1)
}

@Test func trackpadZoomIsFinerPerPointThanAWheelPerLine() {
    let trackpad = OfficeCamera.zoomFactor(scrollDelta: 10, precise: true)
    let wheel = OfficeCamera.zoomFactor(scrollDelta: 1, precise: false)
    #expect(trackpad > 1)
    #expect(trackpad < wheel)
    #expect(OfficeCamera.zoomFactor(scrollDelta: 100, precise: true) == OfficeCamera.zoomFactor(scrollDelta: 40, precise: true))
}

// MARK: - Model: writing to an agent

@MainActor @Test func aMessageGoesToTheSelectedSessionAndTheConversationIsReadAgain() async {
    let client = FakeOfficeClient([], chats: [.success(chat([OfficeChatMessage(at: 1, role: .assistant, text: "Done")]))])
    await client.script(sends: [.success(ActionResult(code: "sent"))])
    let model = OfficeModel(client: client)
    model.apply(document([session("a", status: .waiting)]), now: at(0))
    model.select("claude/a")
    #expect(await model.send("  Fix the test \n"))
    #expect(await client.sent == ["claude/a: Fix the test"])
    #expect(model.sendingTo == nil && model.sendNotice == nil)
    #expect(model.chat?.messages.first?.text == "Done")
}

@MainActor @Test func aMessageThatDidNotGoSaysWhy() async {
    let client = FakeOfficeClient([])
    await client.script(sends: [.success(ActionResult(code: "busy")), .failure(.timedOut)])
    let model = OfficeModel(client: client)
    model.apply(document([session("a")]), now: at(0))
    model.select("claude/a")
    #expect(await model.send("hi") == false)
    #expect(model.sendNotice == Copy.officeBusyHint)
    #expect(await model.send("hi") == false)
    #expect(model.sendNotice == Copy.agentTimedOut)
    model.dismissSendNotice()
    #expect(model.sendNotice == nil)
}

@MainActor @Test func nothingIsSentWithoutASelectionOrWithABlankMessage() async {
    let client = FakeOfficeClient([])
    let model = OfficeModel(client: client)
    model.apply(document([session("a")]), now: at(0))
    #expect(await model.send("hi") == false)
    model.select("claude/a")
    #expect(await model.send(" \n ") == false)
    #expect(await client.sent.isEmpty && model.sendingTo == nil)
}

@Test func theBossLooksLikeNoAgentsFigure() {
    #expect(OfficeLook.boss.shirt == .collar && OfficeLook.boss.extra == .glasses)
    for agent in ["claude", "codex", "gemini", "aider"] {
        #expect(OfficeLook.boss.shirtColour != OfficeAgent(kind: agent).colour)
    }
}

@Test func theBossSaysTheFirstLineOfAMessageAtMostSixtyCharacters() {
    #expect(OfficeLook.bossLine("Fix the test\nThen push") == "Fix the test")
    let long = OfficeLook.bossLine(String(repeating: "a", count: 80))
    #expect(long.count == 60 && long.hasSuffix("…"))
    #expect(OfficeLook.bossLine(String(repeating: "b", count: 60)).count == 60)
}
