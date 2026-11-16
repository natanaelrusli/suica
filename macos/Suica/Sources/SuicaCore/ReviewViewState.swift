public enum ReviewDetailTab: Hashable {
    case description, changes, comments, agent, fix
}

public struct ReviewViewState: Equatable {
    public var tab: ReviewDetailTab = .description
    public var collapsedFiles: Set<String> = []

    public init() {}
}

/// Small recency cache for transient view choices, retaining the selected MR during eviction.
public struct ReviewViewStateCache {
    public let capacity: Int
    private var values: [String: ReviewViewState] = [:]
    private var recency: [String] = []

    public init(capacity: Int = 8) { self.capacity = max(1, capacity) }

    public mutating func state(for key: String) -> ReviewViewState {
        touch(key)
        return values[key] ?? ReviewViewState()
    }

    public mutating func update(_ key: String, selectedKey: String?, _ change: (inout ReviewViewState) -> Void) {
        touch(key)
        var state = values[key] ?? ReviewViewState()
        change(&state)
        values[key] = state
        while values.count > capacity {
            guard let victim = recency.first(where: { $0 != selectedKey }) else { break }
            recency.removeAll { $0 == victim }
            values.removeValue(forKey: victim)
        }
    }

    private mutating func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
