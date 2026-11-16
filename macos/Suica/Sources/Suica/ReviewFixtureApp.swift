import AppKit
import SuicaCore
import SwiftUI

/// Explicit offline entry point: no normal app model, CLI client, or startup task is initialized.
struct ReviewFixtureApp: App {
    @State private var reviews = ReviewsModel(client: ReviewFixtureClient())
    @State private var fixes = FixesModel(client: ReviewFixtureClient())

    var body: some Scene {
        Window("Suica Offline Review Fixture", id: "review-fixture") {
            ReviewsView(model: reviews, fixes: fixes, scope: .reviewing)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate() }
        }
        .defaultSize(width: 1280, height: 800)
    }
}

/// Mutations fail locally; this client never invokes a process or network service.
private struct ReviewFixtureClient: ReviewsClient, FixesClient {

    func reviews() async throws(AgentError) -> ReviewListDocument {
        ReviewListDocument(version: 1, mergeRequests: (1...200).map {
            ReviewSummary(key: "fixture/review!\($0)", title: "Offline review \($0)", url: "https://example.invalid/\($0)", draft: false,
                author: Person(username: "fixture", name: "Fixture Author"), reviewers: [])
        })
    }
    func mergeRequest(key: String) async throws(AgentError) -> MergeRequestDetail {
        do {
            try await Task.sleep(for: .seconds(2))
            var object = try JSONSerialization.jsonObject(with: Data(Self.document.utf8)) as? [String: Any] ?? [:]
            object["key"] = key
            object["title"] = "Offline \(key)"
            let markdown = "## Review fixture\n\n[Link](https://example.invalid)\n\n- [x] Checked\n\n"
            object["description"] = String(String(repeating: markdown, count: 2000).prefix(100_000))
            object["files"] = (0..<100).map { index in
                ["oldPath": "file\(index).swift", "newPath": "file\(index).swift", "newFile": false, "renamedFile": false, "deletedFile": false,
                 "diff": String(String(repeating: "+example line\n", count: 1154).prefix(15_000))] as [String: Any]
            }
            object["discussions"] = []
            object["canApprove"] = false
            return try JSONDecoder().decode(MergeRequestDetail.self, from: JSONSerialization.data(withJSONObject: object))
        } catch { throw AgentError.launchFailed }
    }
    func queueAgentReview(key: String, choice: ReviewChoice) async throws(AgentError) -> ActionResult {
        throw AgentError.launchFailed
    }
    func reviewOptions(cli: String?) async throws(AgentError) -> ReviewOptions { throw AgentError.launchFailed }
    func postAgentReview(id: Int, inline: Bool) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func discardAgentReview(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func cancelAgentReview(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func approve(key: String, sha: String) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func teamsMessage(key: String, request: TeamsMessageRequest) async throws(AgentError) -> TeamsMessageReply {
        throw AgentError.launchFailed
    }

    func fixes() async throws(AgentError) -> FixListDocument { FixListDocument(version: 1, fixes: []) }
    func queueFix(key: String) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func queuePipelineFix(key: String) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func setWatched(key: String, watched: Bool) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func confirmFix(id: Int, edits: ConfirmEdits) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func retryFix(id: Int, note: String) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func discardFix(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func cancelFix(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func postMissingReplies(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func comment(key: String, body: String) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func merge(key: String, sha: String, choice: MergeChoice) async throws(AgentError) -> ActionResult {
        throw AgentError.launchFailed
    }
    func close(key: String) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    private static let document = ###"{"version":1,"key":"g/p!7","title":"Add thing","description":"","url":"https://example.invalid/review","draft":false,"sourceBranch":"feat/thing","targetBranch":"main","createdAt":"2026-10-16T11:36:48+07:00","updatedAt":"2026-10-16T13:26:54+07:00","author":{"username":"alice","name":"Alice"},"labels":[],"pipelineStatus":null,"pipeline":null,"additions":3,"deletions":1,"reviewers":[{"username":"me","name":"Nata","state":"UNREVIEWED"}],"approvedBy":[],"squashOnMerge":true,"squashReadOnly":false,"removeSourceBranch":true,"detailedMergeStatus":"MERGEABLE","defaultMergeCommitMessage":"Merge branch 'feat/thing' into 'main'","defaultSquashCommitMessage":"Add thing","headSha":"0123456789abcdef0123456789abcdef01234567","canApprove":false,"discussions":[],"discussionsTruncated":false,"files":[],"filesTruncated":false}"###
}
