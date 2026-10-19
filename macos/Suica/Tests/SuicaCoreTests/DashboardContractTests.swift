import Foundation
import Testing

@testable import SuicaCore

private func contract(_ name: String) throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return try Data(contentsOf: url.appending(path: "contracts/\(name)"))
}

private func data(_ text: String) -> Data { Data(text.utf8) }

@Test func statusMatchesTheGoldenFile() throws {
    let status = try decodeDocument(StatusDocument.self, from: contract("status.v1.json"))
    #expect(status.version == 1)
    #expect(status.agent.pid == 4242 && status.agent.running && status.agent.loaded)
    #expect(status.agent.label == "com.madhani.suica.agent")
    #expect(status.configError == nil)
    #expect(status.paused == false && status.teamsEnabled == true)
    #expect(status.lastPoll?.durationMs == 1500 && status.lastPoll?.status == "ok")
    #expect(status.lastPoll?.failure == nil && status.lastPoll?.at == 1_792_148_400_000)
    #expect(status.polling == PollingIntervals(activeSeconds: 120, idleSeconds: 300))
    #expect(status.paths.config == "/Users/o/.config/suica/config.yaml")
    #expect(status.paths.templates == "/Users/o/.config/suica/templates")
    #expect(status.modelCli?.selected == "auto" && status.modelCli?.active == "claude")
    #expect(status.modelCli?.clis.map(\.id) == ["claude", "codex", "gemini"])
    #expect(status.modelCli?.clis.last == DetectedModelCli(id: "gemini", name: "Gemini CLI", path: nil))
    #expect(status.agentReview?.auto == true && status.agentReview?.model == nil)
    #expect(status.agentReview?.post == "approval")
    #expect(status.agentReview?.postAs == "comment")
    #expect(status.agentReview?.running == nil && status.agentReview?.queued.isEmpty == true)
}

@Test func aStatusFromAnOlderAgentHasNoModelCli() throws {
    let json = """
        {"version":1,"agent":{"label":"x","loaded":true,"running":true,"pid":7},"configError":null,
        "paused":false,"teamsEnabled":false,"lastPoll":null,"polling":{"activeSeconds":1,"idleSeconds":2},
        "paths":{"config":"c","state":"s","logs":"l","templates":"t"}}
        """
    #expect(try decodeDocument(StatusDocument.self, from: data(json)).modelCli == nil)
}

@Test func aBrokenConfigLeavesTheConfigDependentStatusFieldsNil() throws {
    let json = """
        {"version":1,"agent":{"label":"x","loaded":false,"running":false,"pid":null},
        "configError":"bad config","paused":null,"teamsEnabled":null,"lastPoll":null,"polling":null,
        "paths":{"config":"c","state":"s","logs":"l","templates":"t"}}
        """
    let status = try decodeDocument(StatusDocument.self, from: data(json))
    #expect(status.configError == "bad config")
    #expect(status.paused == nil && status.teamsEnabled == nil)
    #expect(status.lastPoll == nil && status.polling == nil && status.agent.pid == nil)
}

@Test func anUnreadableStateDatabaseKeepsPollingButNotPausedOrLastPoll() throws {
    let json = """
        {"version":1,"agent":{"label":"x","loaded":true,"running":true,"pid":7},
        "configError":"cannot read the state database (SqliteError)","paused":null,"teamsEnabled":false,
        "lastPoll":null,"polling":{"activeSeconds":1,"idleSeconds":2},
        "paths":{"config":"c","state":"s","logs":"l","templates":"t"}}
        """
    let status = try decodeDocument(StatusDocument.self, from: data(json))
    #expect(status.configError?.hasPrefix("cannot read the state database") == true)
    #expect(status.paused == nil && status.lastPoll == nil)
    #expect(status.teamsEnabled == false && status.polling?.idleSeconds == 2)
}

@Test func statsMatchesTheGoldenFile() throws {
    let stats = try decodeDocument(StatsDocument.self, from: contract("stats.v1.json"))
    #expect(stats.generatedAt == 1_792_152_000_000)
    #expect(stats.lastPoll?.durationMs == 1500)
    #expect(stats.polls24h == PollCounts(ok: 1, failed: 1))
    #expect(stats.polls7d == PollCounts(ok: 2, failed: 1))
    #expect(stats.days.count == 2)
    #expect(stats.days.first?.day == "2026-10-15" && stats.days.first?.noticesSent == 1)
    #expect(stats.days.last?.nudgesSent == 1 && stats.days.last?.skipped == 1)
    #expect(stats.days.last?.reviewRequests == 0 && stats.days.last?.activity == 1)
    #expect(stats.days.last?.failed == 0)
    #expect(stats.ownerAfterRequest == Turnaround(count: 1, medianMinutes: 90, p90Minutes: 90))
    #expect(stats.reviewerAfterNudge.medianMinutes == 120)
}

@Test func statsWithNoDataDecodesNullTurnarounds() throws {
    let json = """
        {"version":1,"generatedAt":1,"lastPoll":null,"polls24h":{"ok":0,"failed":0},
        "polls7d":{"ok":0,"failed":0},"days":[],
        "ownerAfterRequest":{"count":0,"medianMinutes":null,"p90Minutes":null},
        "reviewerAfterNudge":{"count":0,"medianMinutes":null,"p90Minutes":null}}
        """
    let stats = try decodeDocument(StatsDocument.self, from: data(json))
    #expect(stats.lastPoll == nil && stats.days.isEmpty)
    #expect(stats.ownerAfterRequest.medianMinutes == nil && stats.ownerAfterRequest.p90Minutes == nil)
}

@Test func usageMatchesTheGoldenFile() throws {
    let usage = try decodeDocument(UsageDocument.self, from: contract("usage.v1.json"))
    #expect(usage.generatedAt == 1_792_152_000_000)
    #expect(
        usage.last24h
            == TokenTotals(runs: 2, inputTokens: 2400, outputTokens: 350, cacheReadTokens: 1000, cacheCreationTokens: 0))
    #expect(usage.last7d.runs == 3 && usage.last30d.runs == 4)
    #expect(usage.last30d.allTokens == 3500 + 560 + 6000 + 300)
    #expect(usage.byPurpose.map(\.purpose) == ["review", "reply"])
    #expect(usage.byPurpose.first?.totals.allTokens == 9910)
    #expect(usage.days.map(\.day) == ["2026-10-15", "2026-10-16"])
    #expect(usage.days.first?.cacheCreationTokens == 300 && usage.days.last?.runs == 2)
}

@Test func configMatchesTheGoldenFile() throws {
    let config = try decodeDocument(ConfigDocument.self, from: contract("config.v1.json"))
    #expect(config.path == "/tmp/config.yaml" && config.exists && config.sha256 == "0")
    #expect(config.issues.isEmpty)
    #expect(config.fields.count == 35)
    let first = try #require(config.fields.first)
    #expect(first.path == ["gitlab", "hostname"] && first.type == .string)
    #expect(first.value == .string("repo.example") && first.effective == .string("repo.example"))
    #expect(first.options == nil && first.placeholder == nil && first.restartNote == nil)

    let timeout = try #require(config.fields.first { $0.path == ["gitlab", "timeoutSeconds"] })
    #expect(timeout.type == .int && timeout.value == .null && timeout.effective == .int(60))

    let mode = try #require(config.fields.first { $0.path == ["teams", "modes", "nudge"] })
    #expect(mode.type == .enum && mode.options?.isEmpty == false)

    // The Re-review Nudge settings come through the generated form like any other key.
    let rereviewMode = try #require(config.fields.first { $0.path == ["teams", "modes", "rereview"] })
    #expect(rereviewMode.type == .enum && rereviewMode.options == mode.options)
    #expect(rereviewMode.effective == .string("approval"))
    let rereviewAfter = try #require(config.fields.first { $0.path == ["teams", "rereviewAfterMinutes"] })
    #expect(rereviewAfter.type == .int && rereviewAfter.effective == .int(10))

    let days = try #require(config.fields.first { $0.path == ["teams", "workingHours", "days"] })
    #expect(days.type == .weekdays && days.effective == .array([1, 2, 3, 4, 5].map(JSONValue.int)))

    let people = try #require(config.fields.first { $0.path == ["teams", "people"] })
    #expect(people.type == .emailMap && people.effective == .object([:]))

    let state = try #require(config.fields.first { $0.path == ["statePath"] })
    #expect(state.restartNote != nil && state.placeholder != nil)

    let types = Set(config.fields.map(\.type))
    #expect(!types.contains(.unknown))
    #expect(types.isSuperset(of: [.string, .int, .bool, .enum, .clock, .weekdays, .stringList, .emailMap]))
}

@Test func configIssuesDecode() throws {
    let json = #"{"version":1,"path":"p","exists":true,"sha256":null,"issues":[{"path":"(root)","message":"m"}],"fields":[]}"#
    let config = try decodeDocument(ConfigDocument.self, from: data(json))
    #expect(config.issues == [ConfigIssue(path: "(root)", message: "m")])
    #expect(config.sha256 == nil)
}

@Test func newerDocumentVersionsAreRejected() {
    let newer = data(#"{"version":2,"anything":true}"#)
    #expect(throws: AgentError.unsupportedVersion(2)) { try decodeDocument(StatusDocument.self, from: newer) }
    #expect(throws: AgentError.unsupportedVersion(2)) { try decodeDocument(StatsDocument.self, from: newer) }
    #expect(throws: AgentError.unsupportedVersion(2)) { try decodeDocument(ConfigDocument.self, from: newer) }
}

@Test(arguments: ["not json", "", "[]", #"{"agent":{}}"#, #"{"version":1}"#])
func documentGarbageIsBadOutput(text: String) {
    #expect(throws: AgentError.badOutput) { try decodeDocument(StatusDocument.self, from: data(text)) }
}

@Test func unknownFieldTypesDecodeAsUnknown() throws {
    let json = #"{"version":1,"path":"p","exists":true,"sha256":null,"issues":[],"fields":[{"path":["a"],"type":"color","label":"L","help":"H","value":null,"effective":null}]}"#
    let config = try decodeDocument(ConfigDocument.self, from: data(json))
    #expect(config.fields.first?.type == .unknown)
}

@Test func jsonValueDecodesEveryKind() throws {
    let json = #"{"a":null,"b":true,"c":-3,"d":"x","e":[1,"y",[]],"f":{"g":false}}"#
    let value = try JSONDecoder().decode(JSONValue.self, from: data(json))
    #expect(
        value
            == .object([
                "a": .null, "b": .bool(true), "c": .int(-3), "d": .string("x"),
                "e": .array([.int(1), .string("y"), .array([])]), "f": .object(["g": .bool(false)]),
            ]))
}

@Test func jsonValueRoundTrips() throws {
    let value = JSONValue.object([
        "a": .null, "b": .bool(false), "c": .int(0), "d": .string("é\"x"), "e": .array([.int(1), .null]),
    ])
    let encoded = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(JSONValue.self, from: encoded) == value)
}

@Test func aBooleanIsNotReadAsANumberAndViceVersa() throws {
    #expect(try JSONDecoder().decode([JSONValue].self, from: data("[true,1,0]")) == [.bool(true), .int(1), .int(0)])
}

@Test func aConfigWithANumberThatIsNotAnIntStillDecodes() throws {
    let json = #"{"version":1,"path":"p","exists":true,"sha256":null,"issues":[{"path":"a","message":"Expected integer, received float"}],"fields":[{"path":["a"],"type":"int","label":"L","help":"H","value":1.5,"effective":null}]}"#
    let config = try decodeDocument(ConfigDocument.self, from: data(json))
    #expect(config.fields.first?.value == .number(1.5))
    #expect(config.issues.first?.path == "a")
}

@Test func numbersThatAreNotIntsDecodeAsNumber() throws {
    let values = try JSONDecoder().decode(
        [JSONValue].self, from: data("[1.5, -0.25, 1E-2, 123456789012345678901234, 9223372036854775808]"))
    #expect(
        values == [
            .number(1.5), .number(-0.25), .number(0.01), .number(1.2345678901234569e23),
            .number(9223372036854775808),
        ])
}

@Test func wholeNumbersStayInts() throws {
    let values = try JSONDecoder().decode([JSONValue].self, from: data("[0, -3, 9223372036854775807, 1e3]"))
    #expect(values == [.int(0), .int(-3), .int(Int.max), .int(1000)])
}

@Test func aNumberEncodesAsAPlainJSONNumber() throws {
    let encoded = try JSONEncoder().encode(JSONValue.array([.number(1.5), .number(1e30), .int(2)]))
    let text = try #require(String(data: encoded, encoding: .utf8))
    #expect(text == "[1.5,1e+30,2]")
    let back = try #require(try JSONSerialization.jsonObject(with: encoded) as? [NSNumber])
    #expect(back.map(\.doubleValue) == [1.5, 1e30, 2])
    #expect(try JSONDecoder().decode(JSONValue.self, from: encoded) == .array([.number(1.5), .number(1e30), .int(2)]))
}

@Test func theSaveRequestEncodesANullBaseAndNullValues() throws {
    let body = SaveRequestBody(
        baseSha256: nil,
        edits: [
            ConfigEditRequest(path: ["teams", "enabled"], value: .bool(true)),
            ConfigEditRequest(path: ["statePath"], value: .null),
        ])
    let object = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    #expect(object["baseSha256"] is NSNull)
    let edits = try #require(object["edits"] as? [[String: Any]])
    #expect(edits.count == 2)
    #expect(edits[0]["path"] as? [String] == ["teams", "enabled"] && edits[0]["value"] as? Bool == true)
    #expect(edits[1]["value"] is NSNull)
}

@Test func saveResultKeepsUnknownStatusCodes() throws {
    let result = try JSONDecoder().decode(
        SaveResult.self, from: data(#"{"status":"teleported","issues":[],"sha256":null}"#))
    #expect(result.status == "teleported" && result.issues.isEmpty && result.sha256 == nil)
}

@Test func theSidebarCategoriesAreTheConfigGroupsInTheAgentsOrder() throws {
    let config = try decodeDocument(ConfigDocument.self, from: contract("config.v1.json"))
    var seen: [ConfigCategory] = []
    for field in config.fields where !seen.contains(ConfigCategory.of(field)) { seen.append(ConfigCategory.of(field)) }
    #expect(seen == ConfigCategory.known)
    #expect(ConfigCategory.known.map(\.title)
        == ["GitLab", "Polling", "Notifications", "Teams", "Language model", "Agent Review", "Storage"])
}
