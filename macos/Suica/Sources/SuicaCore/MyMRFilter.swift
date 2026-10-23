/// The filters over My MRs. Choices in one group widen the list (approved or not, any of the
/// pipeline states); groups narrow each other. A group with nothing chosen lets every MR through.
public struct MyMRFilter: Equatable, Sendable {
    public enum Status: CaseIterable, Hashable, Sendable {
        case unapproved, approved, pipelinePassed, pipelineRunning, pipelineFailed

        public static let approval: [Status] = [.unapproved, .approved]
        public static let pipeline: [Status] = [.pipelinePassed, .pipelineRunning, .pipelineFailed]

        func admits(_ mr: YourMergeRequest) -> Bool {
            switch self {
            case .unapproved: !mr.approvedByAll
            case .approved: mr.approvedByAll
            case .pipelinePassed: mr.pipeline?.hasPassed == true
            case .pipelineRunning: mr.pipeline?.isRunning == true
            case .pipelineFailed: mr.pipeline?.hasFailed == true
            }
        }
    }

    public var statuses: Set<Status>
    /// Project paths, such as `group/project`.
    public var repositories: Set<String>

    public init(statuses: Set<Status> = [], repositories: Set<String> = []) {
        self.statuses = statuses
        self.repositories = repositories
    }

    public var isEmpty: Bool { statuses.isEmpty && repositories.isEmpty }

    /// How many choices are on, for the filter button's badge.
    public var count: Int { statuses.count + repositories.count }

    public func admits(_ mr: YourMergeRequest) -> Bool {
        [Status.approval, Status.pipeline].allSatisfy { group in
            let chosen = group.filter(statuses.contains)
            return chosen.isEmpty || chosen.contains { $0.admits(mr) }
        } && (repositories.isEmpty || repositories.contains(mr.repository))
    }

    /// The repositories whose path holds every word of the search, in their order.
    public static func repositories(_ paths: [String], matching query: String) -> [String] {
        paths.filter { Search.matches(query, [$0]) }
    }
}

extension YourMergeRequest {
    /// The project path: the key without `!<iid>`.
    public var repository: String {
        key.split(separator: "!", maxSplits: 1).first.map(String.init) ?? key
    }
}

extension ReviewListDocument {
    /// The repositories your open MRs are in, sorted.
    public var yourRepositories: [String] {
        Set(yourMergeRequests.map(\.repository)).sorted()
    }

    /// Your MRs that match the search and pass the filter.
    public func yourMergeRequests(matching query: String, filter: MyMRFilter) -> [YourMergeRequest] {
        yourMergeRequests(matching: query).filter(filter.admits)
    }
}
