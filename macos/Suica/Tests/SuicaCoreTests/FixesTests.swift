import Foundation
import Testing

@testable import SuicaCore

private func contract(_ name: String) throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return try Data(contentsOf: url.appending(path: "contracts/\(name)"))
}

private func output(_ text: String, exit: Int32 = 0) -> Result<CommandResult, AgentError> {
    .success(CommandResult(exitCode: exit, stdout: Data(text.utf8), stderr: Data()))
}

private let config = AgentConfig(cliPath: "/bin/suica", searchPath: "/usr/bin")

private func detail(_ overrides: [String: Any]) throws -> MergeRequestDetail {
    let golden = try decodeDocument(MergeRequestDetail.self, from: contract("mr-detail.v1.json"))
    var object = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(golden)) as? [String: Any])
    object.merge(overrides) { _, new in new }
    return try decodeDocument(MergeRequestDetail.self, from: JSONSerialization.data(withJSONObject: object))
}

actor FakeFixesClient: FixesClient {
    private(set) var calls: [String] = []
    private(set) var lastEdits: ConfirmEdits?
    var result: Result<ActionResult, AgentError> = .success(ActionResult(code: "pushed"))
    var document = FixListDocument(version: 1, fixes: [])

    func setResult(_ next: Result<ActionResult, AgentError>) { result = next }
    func setDocument(_ next: FixListDocument) { document = next }

    func fixes() async throws(AgentError) -> FixListDocument {
        calls.append("list")
        return document
    }
    func queueFix(key: String) async throws(AgentError) -> ActionResult {
        calls.append("queue \(key)")
        return try result.get()
    }
    func queuePipelineFix(key: String) async throws(AgentError) -> ActionResult {
        calls.append("queue pipeline \(key)")
        return try result.get()
    }
    func confirmFix(id: Int, edits: ConfirmEdits) async throws(AgentError) -> ActionResult {
        calls.append("confirm \(id)")
        lastEdits = edits
        return try result.get()
    }
    func retryFix(id: Int, note: String) async throws(AgentError) -> ActionResult {
        calls.append("retry \(id) \(note)")
        return try result.get()
    }
    func discardFix(id: Int) async throws(AgentError) -> ActionResult {
        calls.append("discard \(id)")
        return try result.get()
    }
    func cancelFix(id: Int) async throws(AgentError) -> ActionResult {
        calls.append("cancel \(id)")
        return try result.get()
    }
    func postMissingReplies(id: Int) async throws(AgentError) -> ActionResult {
        calls.append("replies \(id)")
        return try result.get()
    }
    func comment(key: String, body: String) async throws(AgentError) -> ActionResult {
        calls.append("comment \(key) \(body)")
        return try result.get()
    }
    func merge(key: String, sha: String, choice: MergeChoice) async throws(AgentError) -> ActionResult {
        calls.append("merge \(key) \(sha) squash=\(choice.squash)")
        return try result.get()
    }
    func close(key: String) async throws(AgentError) -> ActionResult {
        calls.append("close \(key)")
        return try result.get()
    }
}

@Test func theFixListAndYourMergeRequestsDecodeFromTheContracts() throws {
    let list = try decodeDocument(FixListDocument.self, from: contract("fixes.v1.json"))
    #expect(list.fixes.map(\.status) == ["skipped", "failed", "ready"])
    let piped = try #require(list.fixes.first?.pipeline)
    #expect(piped.iid == "41" && piped.jobs.map(\.name) == ["test:unit"] && piped.summary == "A runner lost its network.")
    #expect(list.fixes.first?.threads.isEmpty == true && list.fixes.last?.pipeline == nil)
    let ready = try #require(list.fixes.last)
    #expect(ready.isReady && ready.diff == "diff --git a b\n")
    #expect(ready.threads.map(\.action) == ["changed", "reply", "reply"])
    #expect(ready.threads.first?.notes.first?.body == "Rename this")
    #expect(ready.changedCount == 1)

    let reviews = try decodeDocument(ReviewListDocument.self, from: contract("reviews.v1.json"))
    let mine = try #require(reviews.yourMergeRequests.first)
    #expect(mine.key == "g/p!8" && mine.fix?.status == "ready" && mine.fix?.changed == 1)
    #expect(!mine.approvedByAll)
    #expect(mine.pipeline?.hasFailed == true && mine.pipeline?.url == "https://gitlab.example/g/p/-/pipelines/2921")
    #expect(reviews.yourMergeRequests.last?.pipeline == nil)
}

@Test func aPipelineIsFailedPassedOrStillRunning() {
    let pipeline = { (status: String) in PipelineInfo(iid: "1", status: status, url: "u") }
    #expect(pipeline("FAILED").hasFailed && !pipeline("FAILED").isRunning)
    #expect(pipeline("SUCCESS").hasPassed)
    #expect(pipeline("RUNNING").isRunning && pipeline("PENDING").isRunning)
    #expect(!pipeline("CANCELED").isRunning && !pipeline("CANCELED").hasFailed && !pipeline("CANCELED").hasPassed)
}

@MainActor @Test func aPipelineFixIsQueuedAndSaysWhatHappened() async {
    let client = FakeFixesClient()
    await client.setResult(.success(ActionResult(code: "no-failed-pipeline")))
    let model = FixesModel(client: client)
    await model.queuePipelineFix("g/p!7")
    #expect(await client.calls == ["queue pipeline g/p!7", "list"])
    #expect(model.banner == Copy.fixOutcome("no-failed-pipeline"))
}

@Test func aReviewListFromAnOlderAgentHasNoMergeRequestsOfYours() throws {
    let older = Data(#"{"version":1,"mergeRequests":[]}"#.utf8)
    #expect(try decodeDocument(ReviewListDocument.self, from: older).yourMergeRequests.isEmpty)
}

@Test func mergeAvailabilityFollowsGitLabsMergeStatus() throws {
    #expect(mergeAvailability(try detail(["detailedMergeStatus": "MERGEABLE"])) == .merge)
    #expect(mergeAvailability(try detail(["detailedMergeStatus": "CI_STILL_RUNNING"])) == .whenPipelineSucceeds)
    #expect(
        mergeAvailability(try detail(["detailedMergeStatus": "CI_MUST_PASS", "pipelineStatus": "RUNNING"]))
            == .whenPipelineSucceeds)
    #expect(
        mergeAvailability(try detail(["detailedMergeStatus": "CI_MUST_PASS", "pipelineStatus": "FAILED"]))
            == .blocked(Copy.mergeBlockedPipeline))
    #expect(mergeAvailability(try detail(["detailedMergeStatus": "NOT_APPROVED"])) == .blocked(Copy.mergeBlockedApproval))
    #expect(mergeAvailability(try detail(["detailedMergeStatus": "CONFLICT"])) == .blocked(Copy.mergeBlockedConflict))
    #expect(mergeAvailability(try detail(["detailedMergeStatus": "DRAFT_STATUS"])) == .blocked(Copy.mergeBlockedDraft))
    #expect(
        mergeAvailability(try detail(["detailedMergeStatus": "DISCUSSIONS_NOT_RESOLVED"]))
            == .blocked(Copy.mergeBlockedThreads))
    #expect(mergeAvailability(try detail(["detailedMergeStatus": "NEED_REBASE"])) == .blocked(Copy.mergeBlockedRebase))
    #expect(mergeAvailability(try detail(["detailedMergeStatus": "TELEPORTED"])) == .blocked(Copy.mergeBlockedOther))
    #expect(mergeAvailability(try detail(["detailedMergeStatus": NSNull()])) == .blocked(Copy.mergeBlockedOther))
    #expect(mergeAvailability(try detail(["detailedMergeStatus": "MERGEABLE", "headSha": NSNull()])) == .blocked(Copy.mergeBlockedOther))
}

@MainActor @Test func confirmSendsTheEditsAndSaysWhatHappened() async throws {
    let client = FakeFixesClient()
    let list = try decodeDocument(FixListDocument.self, from: contract("fixes.v1.json"))
    await client.setDocument(list)
    let model = FixesModel(client: client)
    await model.refresh()
    let fix = try #require(model.fix(for: "g/p!7"))
    let edits = ConfirmEdits(
        commitMessage: "Rename", threads: fix.threads.map { ConfirmEdits.Thread(id: $0.id, reply: $0.reply, post: $0.post) })
    await model.confirm(fix, edits: edits)
    #expect(await client.lastEdits == edits)
    #expect(model.banner == Copy.fixOutcome("pushed"))
    #expect(await client.calls == ["list", "confirm \(fix.id)", "list"])

    await client.setResult(.success(ActionResult(code: "branch-moved")))
    await model.confirm(fix, edits: edits)
    #expect(model.banner == Copy.fixOutcome("branch-moved"))
}

@MainActor @Test func aBlankCommentIsNeverSentAndASentOneSaysSo() async throws {
    let client = FakeFixesClient()
    let model = FixesModel(client: client)
    #expect(await model.comment(key: "g/p!7", body: "  \n") == false)
    #expect(await client.calls.isEmpty)
    await client.setResult(.success(ActionResult(code: "posted")))
    #expect(await model.comment(key: "g/p!7", body: "Thanks!") == true)
    #expect(await client.calls == ["comment g/p!7 Thanks!"])
    #expect(model.banner == Copy.commentOutcome("posted"))
}

@Test func theCliGetsTheFixVerbsWithTheirInputOnStdin() async throws {
    let runner = FakeRunner([
        output(#"{"status":"pushed"}"#), output(#"{"status":"queued"}"#), output(#"{"status":"scheduled"}"#),
        output(#"{"status":"posted"}"#),
    ])
    let client = CLIAgentClient(config: config, runner: runner)
    let edits = ConfirmEdits(commitMessage: "m", threads: [.init(id: "d1", reply: "r", post: true)])
    #expect(try await client.confirmFix(id: 4, edits: edits).code == "pushed")
    #expect(try await client.retryFix(id: 4, note: "smaller").code == "queued")
    let choice = MergeChoice(squash: true, removeSourceBranch: false, message: "Add thing", whenPipelineSucceeds: true)
    #expect(try await client.merge(key: "g/p!7", sha: "abc1234", choice: choice).code == "scheduled")
    #expect(try await client.comment(key: "g/p!7", body: "hi").code == "posted")
    let calls = await runner.invocations
    #expect(calls.map(\.arguments) == [
        ["fix", "confirm", "4", "--json"],
        ["fix", "retry", "4", "--json"],
        ["mr", "merge", "g/p!7", "abc1234", "--squash", "--when-pipeline-succeeds", "--json"],
        ["mr", "comment", "g/p!7", "--json"],
    ])
    let sent = try JSONDecoder().decode(ConfirmEdits.self, from: try #require(calls[0].stdin))
    #expect(sent == edits)
    #expect(calls[1].stdin == Data("smaller".utf8))
    #expect(calls[2].stdin == Data("Add thing".utf8))
    #expect(calls[3].stdin == Data("hi".utf8))
}

@MainActor @Test func oneOfYourMergeRequestsStaysSelectedAcrossRefreshes() async throws {
    let mine = try #require(
        try decodeDocument(ReviewListDocument.self, from: contract("reviews.v1.json")).yourMergeRequests.first)
    let list = ReviewListDocument(version: 1, mergeRequests: [], yourMergeRequests: [mine])
    let client = FakeReviewsClient(lists: [.success(list)])
    let model = ReviewsModel(client: client)
    await model.refresh()
    await model.select("g/p!8")
    await model.refresh()
    #expect(model.selectedKey == "g/p!8")
    #expect(model.isYours("g/p!8") && !model.isYours("g/p!9"))
}

@Test func aGitDiffSplitsIntoFilesAndKeepsTheChangesThatAreNotLines() {
    let diff = """
        diff --git a/src/a.ts b/src/a.ts
        index 111..222 100644
        --- a/src/a.ts
        +++ b/src/a.ts
        @@ -1,2 +1,2 @@
        --- not a header: a removed line starting with two dashes
        +new
        diff --git a/img.png b/img.png
        new file mode 100644
        index 0000000..333
        Binary files /dev/null and b/img.png differ
        diff --git a/old.ts b/new.ts
        similarity index 100%
        rename from old.ts
        rename to new.ts
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        diff --git a/x b/y.ts b/x b/y.ts
        --- a/x b/y.ts
        +++ b/x b/y.ts
        @@ -1 +1 @@
        -a
        +b

        """
    let files = splitGitDiff(diff)
    #expect(files.map(\.path) == ["src/a.ts", "img.png", "new.ts", "run.sh", "x b/y.ts"])
    #expect(files[0].lines.map(\.kind) == [.hunk, .removed, .added])
    #expect(files[0].lines[1].text == "-- not a header: a removed line starting with two dashes")
    #expect(files[1].lines.map(\.text) == ["new file mode 100644", "Binary files /dev/null and b/img.png differ"])
    #expect(files[2].lines.map(\.text) == ["rename from old.ts", "rename to new.ts"])
    #expect(files[3].lines.map(\.text) == ["old mode 100644", "new mode 100755"])
    #expect(files[3].lines.allSatisfy { $0.kind == .note })
}

@Test func aFixDraftStartsAgainWhenTheFixTurnsReady() throws {
    let list = try decodeDocument(FixListDocument.self, from: contract("fixes.v1.json"))
    let ready = try #require(list.fixes.last)
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ready)) as? [String: Any])
    object["status"] = "running"
    object["diff"] = NSNull()
    object["commitMessage"] = ""
    object["threads"] = (object["threads"] as! [[String: Any]]).map { thread in
        var thread = thread
        thread["action"] = NSNull(); thread["reply"] = ""; thread["post"] = false
        return thread
    }
    let running = try JSONDecoder().decode(FixInfo.self, from: JSONSerialization.data(withJSONObject: object))

    let early = FixDraft(running)
    #expect(early.isStale(for: running) == false)
    // The same fix, now ready: what was seeded while it ran must not be what you confirm.
    #expect(early.isStale(for: ready))
    let draft = FixDraft(ready)
    #expect(draft.commitMessage == "Rename the total")
    #expect(draft.files.count == 1)
    #expect(draft.skipped == [ready.threads[2].id])
    #expect(draft.replies[ready.threads[0].id] == "Fixed in {{sha}}: renamed.")

    var edited = draft
    edited.replies[ready.threads[1].id] = "  "
    let edits = edited.edits(for: ready)
    #expect(edits.commitMessage == "Rename the total")
    #expect(edits.threads.map(\.post) == [true, false, false])
}

@Test func theMergeSheetMergesOnlyTheCommitItOpenedOn() {
    #expect(mergeSha(opened: "abc1234", current: "abc1234") == "abc1234")
    #expect(mergeSha(opened: "abc1234", current: "def5678") == nil)
    #expect(mergeSha(opened: nil, current: "abc1234") == nil)
}

@Test func theCliKeepsTheSshAgentSoAConfirmCanPush() {
    let env = CLIAgentClient.environment(
        searchPath: "/usr/bin", home: "/Users/me",
        inherited: ["SSH_AUTH_SOCK": "/tmp/agent.sock", "GNUPGHOME": "/Users/me/.gnupg", "SECRET": "x"])
    #expect(env == [
        "PATH": "/usr/bin", "HOME": "/Users/me", "SUICA_ENV": "production",
        "SSH_AUTH_SOCK": "/tmp/agent.sock", "GNUPGHOME": "/Users/me/.gnupg",
    ])
}

@MainActor @Test func closingAnMRSaysWhatHappened() async throws {
    let client = FakeFixesClient()
    await client.setResult(.success(ActionResult(code: "closed")))
    let model = FixesModel(client: client)
    #expect(await model.close(key: "g/p!7") == "closed")
    #expect(await client.calls == ["close g/p!7"])
    #expect(model.banner == Copy.closeOutcome("closed"))
    await client.setResult(.success(ActionResult(code: "not-yours")))
    await model.close(key: "g/p!7")
    #expect(model.banner == Copy.closeOutcome("not-yours"))

    let runner = FakeRunner([output(#"{"status":"closed"}"#)])
    #expect(try await CLIAgentClient(config: config, runner: runner).close(key: "g/p!7").code == "closed")
    #expect(await runner.invocations.map(\.arguments) == [["mr", "close", "g/p!7", "--json"]])
}
