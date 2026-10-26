import Foundation
import Testing

@testable import SuicaCore

private func contract(_ name: String) throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return try Data(contentsOf: url.appending(path: "contracts/\(name)"))
}

/// One of the documents `contracts/lessons.v1.json` holds under `list` and `show`.
private func lessonsContract(_ key: String) throws -> Data {
    let object = try #require(try JSONSerialization.jsonObject(with: contract("lessons.v1.json")) as? [String: Any])
    return try JSONSerialization.data(withJSONObject: try #require(object[key]))
}

private func output(_ text: String, exit: Int32 = 0) -> Result<CommandResult, AgentError> {
    .success(CommandResult(exitCode: exit, stdout: Data(text.utf8), stderr: Data()))
}

private let config = AgentConfig(cliPath: "/bin/suica", searchPath: "/usr/bin")

private func summary(
    _ id: Int, _ title: String, rule: String = "", topics: [String] = [], repos: [String] = []
) -> LessonSummary {
    LessonSummary(
        id: id, title: title, rule: rule, topics: topics, weight: Double(10 - id), count: 1, repos: repos,
        lastSeen: "2026-10-24T12:00:00.000Z")
}

private func listDocument(_ scopes: [LessonScope], enabled: Bool = true, pending: Int = 0) -> LessonListDocument {
    LessonListDocument(version: 1, enabled: enabled, scopes: scopes, pending: pending)
}

private func detail(_ id: Int, scope: String, archived: Bool = false) throws -> LessonDetailDocument {
    let golden = try decodeDocument(LessonDetailDocument.self, from: lessonsContract("show"))
    let lesson = golden.lesson
    return LessonDetailDocument(
        version: 1,
        lesson: LessonDetail(
            id: id, title: lesson.title, rule: lesson.rule, topics: lesson.topics, globs: lesson.globs, scope: scope,
            archived: archived, weight: lesson.weight, count: lesson.count, repos: lesson.repos,
            lastSeen: lesson.lastSeen, related: lesson.related, occurrences: lesson.occurrences))
}

// MARK: - Decoding

@Test func theLessonListDecodesFromTheContract() throws {
    let list = try decodeDocument(LessonListDocument.self, from: lessonsContract("list"))
    #expect(list.enabled && list.pending == 1)
    let scope = try #require(list.scopes.first)
    #expect(scope.path == "/work/acme" && scope.repos == 2)
    #expect(scope.lessons.map(\.id) == [1, 2])
    let first = try #require(scope.lessons.first)
    #expect(first.title == "HTTP clients need an explicit timeout")
    #expect(first.topics == ["http-client", "go"] && first.repos == ["acme/api", "acme/web"])
    #expect(first.weight == 7.07 && first.count == 3)
    #expect(first.lastSeenDate != nil)
}

@Test func theLessonDetailDecodesFromTheContract() throws {
    let document = try decodeDocument(LessonDetailDocument.self, from: lessonsContract("show"))
    let lesson = document.lesson
    #expect(lesson.id == 1 && lesson.scope == "/work/acme" && !lesson.archived)
    #expect(lesson.globs == ["**/*.go"])
    #expect(lesson.related == [RelatedLesson(id: 2, title: "Wrap errors with context")])
    #expect(lesson.occurrences.map(\.mrKey) == ["acme/web!5", "acme/api!4", "acme/api!3"])
    let newest = try #require(lesson.occurrences.first)
    #expect(newest.path == "web/fetch.go" && newest.line == 40 && newest.outcome == "changed")
    #expect(newest.severity == "" && newest.mrURL?.host() == "gitlab.example")
    #expect(newest.location == "web/fetch.go:40")
}

@Test func aLessonDetailWithoutOccurrencesOrPathDecodes() throws {
    let json = #"""
        {"version":1,"lesson":{"id":4,"title":"T","rule":"R","topics":[],"globs":[],"scope":"","archived":true,
        "weight":0,"count":0,"repos":[],"lastSeen":null,"related":[],"occurrences":[
        {"mrKey":"g/p!1","mrTitle":"M","mrUrl":"","path":null,"line":null,"severity":"Nit","outcome":"open",
        "text":"x","at":"2026-10-24T12:00:00.000Z","extra":1}],"newKey":true}}
        """#
    let document = try decodeDocument(LessonDetailDocument.self, from: Data(json.utf8))
    #expect(document.lesson.lastSeen == nil && document.lesson.archived)
    #expect(document.lesson.occurrences.first?.location == nil)
    #expect(document.lesson.occurrences.first?.mrURL == nil)
}

@Test func theReviewRepeatsDecodeFromTheReviewsContract() throws {
    let reviews = try decodeDocument(ReviewListDocument.self, from: contract("reviews.v1.json"))
    #expect(reviews.mergeRequests.first?.agentReview?.repeats == [])
    let repeats = try #require(reviews.mergeRequests.last?.agentReview?.repeats)
    #expect(
        repeats == [
            ReviewRepeat(
                finding: "1", lessonId: 1, title: "HTTP clients need an explicit timeout", before: 3,
                repos: ["g/api", "g/web"])
        ])
}

@Test func anOlderReviewWithoutRepeatsDecodesAsNone() throws {
    let json = #"{"id":1,"status":"ready","detail":"","createdAt":0,"updatedAt":0}"#
    let review = try JSONDecoder().decode(AgentReviewInfo.self, from: Data(json.utf8))
    #expect(review.repeats == [])
}

@Test func theThreadRepeatDecodesFromTheFixesContract() throws {
    let list = try decodeDocument(FixListDocument.self, from: contract("fixes.v1.json"))
    let ready = try #require(list.fixes.last)
    #expect(
        ready.threads.first?.lessonRepeat
            == ThreadRepeat(lessonId: 1, title: "Name things for what they do", before: 1, repos: ["g/api"]))
    #expect(ready.threads.dropFirst().allSatisfy { $0.lessonRepeat == nil })
    let older = #"""
        {"id":"d","author":{"username":"b","name":"B"},"filePath":null,"line":null,"notes":[],"action":null,
        "reply":"","post":false,"posted":false}
        """#
    #expect(try JSONDecoder().decode(FixThreadInfo.self, from: Data(older.utf8)).lessonRepeat == nil)
}

// MARK: - The repeat marker

@Test func theRepeatMarkerNamesTheCountAndRepos() {
    #expect(Copy.lessonRepeat(before: 1, repos: ["g/api"]) == "Flagged 1 time before, in `g/api`")
    #expect(Copy.lessonRepeat(before: 3, repos: ["g/api", "g/web"]) == "Flagged 3 times before, in `g/api`, `g/web`")
    #expect(Copy.lessonRepeat(before: 2, repos: []) == "Flagged 2 times before")
}

@Test func findingNumbersRepeatedInOneReviewGetTheirPosition() {
    #expect(uniqueFindingNumbers(["1", "2", "1", "1"]) == ["1", "2", "1#3", "1#4"])
    #expect(uniqueFindingNumbers([]) == [])
}

@Test func findingsAreReadAsTheAgentReadsThem() {
    let body = """
        # Code review

        ## Previous review
        1. `old.ts:1` — fixed.

        ## Findings
        ### Major
        1. `src/http.ts:12` — the client has no timeout.
           More about it.
        ### Minor
        1. `src/log.ts:3`: a debug line is left in.
        - `src/x.ts:9-12` a bullet
        2. Not located.

        ```
        3. `code.ts:1` — in a fence
        ```
        """
    let findings = extractReviewFindings(body)
    #expect(findings.map(\.number) == ["1", "1#2", "3"])
    #expect(findings.map(\.path) == ["src/http.ts", "src/log.ts", "src/x.ts"])
    #expect(findings.map(\.line) == [12, 3, 9])
    #expect(findings.map(\.severity) == ["Major", "Minor", "Minor"])
    #expect(findings.first?.title == "the client has no timeout.")
}

@Test func repeatsAreMatchedToTheirFindingsByNumber() throws {
    let reviews = try decodeDocument(ReviewListDocument.self, from: contract("reviews.v1.json"))
    let review = try #require(reviews.mergeRequests.last?.agentReview)
    let matched = review.repeatedFindings
    #expect(matched.count == 1)
    #expect(matched.first?.finding?.path == "src/http.ts")
    #expect(matched.first?.label == "1")

    let second = AgentReviewInfo(
        id: 4, status: "ready", body: review.body,
        repeats: [ReviewRepeat(finding: "1#2", lessonId: 2, title: "No debug lines", before: 1, repos: ["g/p"])])
    #expect(second.repeatedFindings.first?.finding?.path == "src/log.ts")
    #expect(second.repeatedFindings.first?.label == "1#2")

    let unknown = AgentReviewInfo(
        id: 5, status: "ready", body: nil,
        repeats: [ReviewRepeat(finding: "7", lessonId: 2, title: "T", before: 1, repos: [])])
    #expect(unknown.repeatedFindings.first?.finding == nil)
}

// MARK: - Filtering and merging

private let acme = LessonScope(
    path: "/work/acme", repos: 2,
    lessons: [
        summary(1, "HTTP clients need an explicit timeout", rule: "Set a deadline", topics: ["http-client", "go"],
                repos: ["acme/api", "acme/web"]),
        summary(2, "Wrap errors with context", topics: ["errors"], repos: ["acme/api"]),
        summary(3, "Scope every query", rule: "Add a tenant filter", topics: ["sql"], repos: ["acme/web"]),
    ])
private let solo = LessonScope(
    path: "/work/solo", repos: 1, lessons: [summary(4, "Log in JSON", topics: ["logging", "go"], repos: ["me/solo"])])

@Test func filteringByTopicAndRepoKeepsMatchingLessons() {
    let list = listDocument([acme, solo])
    #expect(list.topics == ["errors", "go", "http-client", "logging", "sql"])
    #expect(list.repos == ["acme/api", "acme/web", "me/solo"])
    func ids(_ filter: LessonFilter) -> [[Int]] { list.scopes(matching: filter).map { $0.lessons.map(\.id) } }
    #expect(ids(LessonFilter()) == [[1, 2, 3], [4]])
    #expect(ids(LessonFilter(topic: "go")) == [[1], [4]])
    #expect(ids(LessonFilter(repo: "acme/web")) == [[1, 3], []])
    #expect(ids(LessonFilter(topic: "go", repo: "acme/api")) == [[1], []])
    #expect(ids(LessonFilter(scope: "/work/solo")) == [[4]])
    #expect(ids(LessonFilter(query: "tenant")) == [[3], []])
    #expect(ids(LessonFilter(query: "http-client")) == [[1], []])
    #expect(ids(LessonFilter(query: "wrap CONTEXT")) == [[2], []])
    #expect(list.scope(ofLesson: 4)?.path == "/work/solo")
}

@Test func mergeCandidatesStayInTheScopeAndLeaveTheLessonOut() throws {
    let list = listDocument([acme, solo])
    let one = try detail(1, scope: "/work/acme").lesson
    #expect(list.mergeCandidates(for: one).map(\.id) == [2, 3])
    let four = try detail(4, scope: "/work/solo").lesson
    #expect(list.mergeCandidates(for: four).isEmpty)
    let archived = try detail(2, scope: "/work/acme", archived: true).lesson
    #expect(list.mergeCandidates(for: archived).isEmpty)
    let unscoped = try detail(9, scope: "").lesson
    #expect(list.mergeCandidates(for: unscoped).isEmpty)
}

// MARK: - Client

@Test func theLessonCommandsRunWithTheirArguments() async throws {
    let list = String(decoding: try lessonsContract("list"), as: UTF8.self)
    let show = String(decoding: try lessonsContract("show"), as: UTF8.self)
    let runner = FakeRunner([
        output(list), output(show), output(#"{"version":1,"status":"not-found"}"#, exit: 1),
        output(#"{"version":1,"status":"archived"}"#),
        output(#"{"version":1,"status":"bad-request","message":"lessons of two scopes cannot be merged"}"#, exit: 1),
        output(#"{"version":1,"hook":true,"mcp":{"claude":true,"codex":false}}"#),
        output(#"{"version":1,"status":"uninstalled","hookRemoved":true,"removed":["claude"],"failed":[]}"#),
        output(#"{"version":1,"status":"exported","written":4,"removed":1,"conflicts":2,"path":"/v"}"#),
    ])
    let client = CLIAgentClient(config: config, runner: runner)
    #expect(try await client.lessons().scopes.count == 1)
    #expect(try await client.lesson(id: 1)?.lesson.id == 1)
    #expect(try await client.lesson(id: 99) == nil)
    #expect(try await client.archiveLesson(id: 2) == .archived)
    #expect(try await client.mergeLessons(keep: 1, gone: 5) == .refused("lessons of two scopes cannot be merged"))
    #expect(try await client.lessonsStatus() == LessonsSetupStatus(hook: true, claude: true, codex: false))
    let removed = try await client.uninstallLessons()
    #expect(removed.status == "uninstalled" && removed.hookRemoved == true)
    let exported = try await client.exportLessons()
    #expect(exported.status == "exported" && exported.written == 4 && exported.conflicts == 2)
    let calls = await runner.invocations.map(\.arguments)
    #expect(
        calls == [
            ["lessons", "list", "--json"], ["lessons", "show", "1", "--json"], ["lessons", "show", "99", "--json"],
            ["lessons", "archive", "2", "--json"], ["lessons", "merge", "1", "5", "--json"],
            ["lessons", "status", "--json"], ["lessons", "uninstall", "--json"], ["lessons", "export", "--json"],
        ])
}

private let planJSON = #"""
    {"version":1,"status":"needs-confirmation","plan":{"settingsPath":"/h/.claude/settings.json",
    "hooks":[{"event":"SessionStart","matcher":""},{"event":"PostToolUse","matcher":"Read"},
    {"event":"PreToolUse","matcher":"Write|Edit|MultiEdit"}],"mcp":["claude"],
    "command":"'/n/node' '/s/src/lessons-hook.ts'",
    "commands":["claude mcp remove --scope user suica-lessons","claude mcp add --scope user suica-lessons -- x"],
    "note":"settings.json is rewritten as formatted JSON."}}
    """#

@Test func installAsksForThePlanFirstAndConfirmsWithYes() async throws {
    let runner = FakeRunner([
        // The CLI prints one line.
        output(planJSON.replacingOccurrences(of: "\n", with: ""), exit: 1),
        output(
            #"{"version":1,"status":"partial","settingsPath":"/h/.claude/settings.json","changed":true,"registered":[],"skipped":["codex"],"failed":["claude"]}"#,
            exit: 1),
    ])
    let client = CLIAgentClient(config: config, runner: runner)
    let planned = try await client.installLessons(confirm: false)
    let plan = try #require(planned.plan)
    #expect(planned.status == "needs-confirmation")
    #expect(plan.settingsPath == "/h/.claude/settings.json" && plan.hooks.count == 3 && plan.commands.count == 2)
    #expect(plan.hooks.last?.label == "PreToolUse (Write|Edit|MultiEdit)" && plan.hooks.first?.label == "SessionStart")
    let done = try await client.installLessons(confirm: true)
    #expect(done.status == "partial" && done.failed == ["claude"])
    let calls = await runner.invocations.map(\.arguments)
    #expect(calls == [["lessons", "install", "--json"], ["lessons", "install", "--yes", "--json"]])
}

// MARK: - Model

actor FakeLessonsClient: LessonsClient {
    private(set) var calls: [String] = []
    var list: LessonListDocument
    var details: [Int: LessonDetailDocument] = [:]
    var change: LessonChangeOutcome = .archived
    var installs: [LessonsInstallReply] = []
    var status = LessonsSetupStatus(hook: false, claude: false, codex: false)

    init(list: LessonListDocument) { self.list = list }

    func setChange(_ next: LessonChangeOutcome) { change = next }
    func setDetail(_ document: LessonDetailDocument) { details[document.lesson.id] = document }
    func setInstalls(_ next: [LessonsInstallReply]) { installs = next }
    func setStatus(_ next: LessonsSetupStatus) { status = next }

    func lessons() async throws(AgentError) -> LessonListDocument {
        calls.append("list")
        return list
    }
    func lesson(id: Int) async throws(AgentError) -> LessonDetailDocument? {
        calls.append("show \(id)")
        return details[id]
    }
    func archiveLesson(id: Int) async throws(AgentError) -> LessonChangeOutcome {
        calls.append("archive \(id)")
        return change
    }
    func mergeLessons(keep: Int, gone: Int) async throws(AgentError) -> LessonChangeOutcome {
        calls.append("merge \(keep) \(gone)")
        return change
    }
    func lessonsStatus() async throws(AgentError) -> LessonsSetupStatus {
        calls.append("status")
        return status
    }
    func installLessons(confirm: Bool) async throws(AgentError) -> LessonsInstallReply {
        calls.append(confirm ? "install --yes" : "install")
        guard !installs.isEmpty else { throw AgentError.launchFailed }
        return installs.removeFirst()
    }
    func uninstallLessons() async throws(AgentError) -> LessonsUninstallReply {
        calls.append("uninstall")
        return LessonsUninstallReply(status: "uninstalled", hookRemoved: true, removed: ["claude"], failed: [])
    }
    func exportLessons() async throws(AgentError) -> LessonsExportReply {
        calls.append("export")
        return LessonsExportReply(status: "exported", written: 3, removed: 0, conflicts: 1, path: "/v", message: nil)
    }
}

private func reply(_ json: String) throws -> LessonsInstallReply {
    try JSONDecoder().decode(LessonsInstallReply.self, from: Data(json.utf8))
}

@MainActor @Test func theInstallFlowShowsThePlanThenInstallsOnConfirm() async throws {
    let client = FakeLessonsClient(list: listDocument([acme]))
    await client.setInstalls([
        try reply(planJSON),
        try reply(
            #"{"version":1,"status":"installed","settingsPath":"/h/.claude/settings.json","changed":true,"registered":["claude"],"skipped":[],"failed":[]}"#
        ),
    ])
    await client.setStatus(LessonsSetupStatus(hook: true, claude: true, codex: false))
    let model = LessonsModel(client: client)
    await model.beginInstall()
    guard case .confirming(let plan) = model.install else {
        Issue.record("expected the plan, got \(model.install)")
        return
    }
    #expect(plan.mcp == ["claude"])
    await model.confirmInstall()
    #expect(model.install == .idle)
    #expect(model.setupNotice == Copy.lessonsInstalled(registered: ["claude"]))
    #expect(model.setup == LessonsSetupStatus(hook: true, claude: true, codex: false))
    #expect(await client.calls == ["install", "install --yes", "status"])
}

@MainActor @Test func cancellingTheInstallChangesNothing() async throws {
    let client = FakeLessonsClient(list: listDocument([acme]))
    await client.setInstalls([try reply(planJSON)])
    let model = LessonsModel(client: client)
    await model.beginInstall()
    model.cancelInstall()
    #expect(model.install == .idle)
    await model.confirmInstall()
    #expect(await client.calls == ["install"])
}

@MainActor @Test func aPartialOrRefusedInstallSaysWhy() async throws {
    let client = FakeLessonsClient(list: listDocument([acme]))
    await client.setInstalls([
        try reply(planJSON),
        try reply(
            #"{"version":1,"status":"partial","settingsPath":"/s","changed":true,"registered":[],"skipped":[],"failed":["claude","codex"]}"#
        ),
        try reply(planJSON),
        try reply(
            #"{"version":1,"status":"invalid-settings","settingsPath":"/h/.claude/settings.json","changed":false,"registered":[],"skipped":[],"failed":[]}"#
        ),
    ])
    let model = LessonsModel(client: client)
    await model.beginInstall()
    await model.confirmInstall()
    #expect(model.setupNotice == Copy.lessonsInstallPartial(failed: ["claude", "codex"]))
    await model.beginInstall()
    await model.confirmInstall()
    #expect(model.setupNotice == Copy.lessonsSettingsUnusable("invalid-settings", path: "/h/.claude/settings.json"))
    #expect(Copy.lessonsSettingsUnusable("invalid-settings", path: "/p").contains("not valid JSON"))
}

@MainActor @Test func filtersAndSearchNarrowTheShownLessons() async {
    let model = LessonsModel(client: FakeLessonsClient(list: listDocument([acme, solo])))
    await model.refresh()
    model.filter.topic = "go"
    #expect(model.shownScopes.map { $0.lessons.map(\.id) } == [[1], [4]])
    model.filter = LessonFilter(query: "json")
    #expect(model.shownScopes.map { $0.lessons.map(\.id) } == [[], [4]])
}

@MainActor @Test func archivingAndMergingRefreshAndReportRefusals() async throws {
    let client = FakeLessonsClient(list: listDocument([acme]))
    await client.setDetail(try detail(1, scope: "/work/acme"))
    await client.setDetail(try detail(2, scope: "/work/acme"))
    let model = LessonsModel(client: client)
    await model.refresh()
    await model.select(1)
    #expect(model.selected?.lesson.id == 1)

    await model.merge(1, into: 2)
    #expect(model.banner == Copy.lessonChangeOutcome(.archived))
    await client.setChange(.merged)
    await model.merge(1, into: 2)
    #expect(model.banner == Copy.lessonChangeOutcome(.merged))
    #expect(model.selectedId == 2)

    await client.setChange(.refused("lesson 2 is archived"))
    await model.archive(2)
    #expect(model.banner == "Not changed: lesson 2 is archived")
    await client.setChange(.archived)
    await model.archive(2)
    #expect(model.banner == Copy.lessonChangeOutcome(.archived))
    #expect(model.selectedId == nil)

    let calls = await client.calls
    #expect(calls.filter { $0.hasPrefix("merge") } == ["merge 2 1", "merge 2 1"])
    #expect(calls.filter { $0 == "list" }.count == 5)
}

@MainActor @Test func openingALessonClearsTheFiltersAndShowsItsScope() async throws {
    let client = FakeLessonsClient(list: listDocument([acme, solo]))
    await client.setDetail(try detail(4, scope: "/work/solo"))
    let model = LessonsModel(client: client)
    await model.refresh()
    model.filter = LessonFilter(scope: "/work/acme", topic: "sql", repo: "acme/web", query: "x")
    await model.open(4)
    #expect(model.filter == LessonFilter(scope: "/work/solo"))
    #expect(model.selected?.lesson.id == 4)
}

@MainActor @Test func exportingShowsTheCounts() async {
    let client = FakeLessonsClient(list: listDocument([acme]))
    let model = LessonsModel(client: client)
    await model.exportVault()
    #expect(model.setupNotice == Copy.lessonsExported(written: 3, removed: 0, conflicts: 1))
    await model.uninstall()
    #expect(model.setupNotice == Copy.lessonsUninstalled)
}
