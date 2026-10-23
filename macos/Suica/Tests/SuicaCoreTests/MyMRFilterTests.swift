import Testing

@testable import SuicaCore

private func mine(_ key: String, approved: Bool = false, pipeline: String? = nil) -> YourMergeRequest {
    YourMergeRequest(
        key: key, title: "t \(key)", url: "https://x/\(key)", draft: false, createdAt: nil, reviewers: [],
        approvedByAll: approved, fix: nil, pipeline: pipeline.map { PipelineInfo(iid: "1", status: $0, url: "https://p") })
}

private let list = ReviewListDocument(
    version: 1, mergeRequests: [],
    yourMergeRequests: [
        mine("g/api!1", approved: true, pipeline: "SUCCESS"),
        mine("g/api!2", pipeline: "FAILED"),
        mine("g/web!3", approved: true, pipeline: "RUNNING"),
        mine("g/sub/web!4"),
    ])

private func keys(_ filter: MyMRFilter, _ query: String = "") -> [String] {
    list.yourMergeRequests(matching: query, filter: filter).map(\.key)
}

@Test func anEmptyFilterShowsEveryMR() {
    #expect(MyMRFilter().isEmpty)
    #expect(keys(MyMRFilter()) == ["g/api!1", "g/api!2", "g/web!3", "g/sub/web!4"])
}

@Test func approvalAndPipelineChoicesEachNarrowTheList() {
    #expect(keys(MyMRFilter(statuses: [.approved])) == ["g/api!1", "g/web!3"])
    #expect(keys(MyMRFilter(statuses: [.unapproved])) == ["g/api!2", "g/sub/web!4"])
    #expect(keys(MyMRFilter(statuses: [.pipelinePassed])) == ["g/api!1"])
    #expect(keys(MyMRFilter(statuses: [.pipelineRunning])) == ["g/web!3"])
    #expect(keys(MyMRFilter(statuses: [.pipelineFailed])) == ["g/api!2"])
}

@Test func choicesInOneGroupWidenAndGroupsNarrowEachOther() {
    #expect(keys(MyMRFilter(statuses: [.approved, .unapproved])).count == 4)
    #expect(keys(MyMRFilter(statuses: [.pipelinePassed, .pipelineFailed])) == ["g/api!1", "g/api!2"])
    #expect(keys(MyMRFilter(statuses: [.unapproved, .pipelinePassed, .pipelineFailed])) == ["g/api!2"])
}

@Test func reposAreTheProjectPathsSortedAndFilterByPath() {
    #expect(list.yourRepositories == ["g/api", "g/sub/web", "g/web"])
    #expect(keys(MyMRFilter(repositories: ["g/web"])) == ["g/web!3"])
    #expect(keys(MyMRFilter(statuses: [.approved], repositories: ["g/api", "g/sub/web"])) == ["g/api!1"])
}

@Test func theFilterAndTheSearchBothApply() {
    #expect(keys(MyMRFilter(statuses: [.approved]), "web") == ["g/web!3"])
}

@Test func aRepositorySearchMatchesEveryWordOfThePath() {
    #expect(MyMRFilter.repositories(list.yourRepositories, matching: "WEB") == ["g/sub/web", "g/web"])
    #expect(MyMRFilter.repositories(list.yourRepositories, matching: "sub web") == ["g/sub/web"])
    #expect(MyMRFilter.repositories(list.yourRepositories, matching: " ") == list.yourRepositories)
}

@Test func theCountSaysHowManyChoicesAreOn() {
    #expect(MyMRFilter(statuses: [.approved, .pipelineFailed], repositories: ["g/api"]).count == 3)
}
