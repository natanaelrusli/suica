import CryptoKit
import Foundation

public struct ReviewContentID: Hashable, Sendable {
    public let key: String
    public let headSha: String?
    public let contentDigest: String

    public init(key: String, headSha: String?, files: [DiffFile]) {
        self.key = key
        self.headSha = headSha
        var data = Data()
        for file in files {
            for value in [file.oldPath, file.newPath, file.diff ?? ""] {
                let bytes = Data(value.utf8)
                var length = UInt64(bytes.count).bigEndian
                withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
                data.append(bytes)
            }
        }
        contentDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct PreparedReviewDiff: Sendable {
    public let id: ReviewContentID
    public let linesByFile: [String: [DiffLine]]
}

public actor ReviewPresentationCache {
    public let byteLimit: Int
    private struct Entry<Value> { let value: Value; let cost: Int; var access: UInt64 }
    private var diffsByID: [ReviewContentID: Entry<PreparedReviewDiff>] = [:]
    private var blocksBySource: [String: Entry<[MarkdownBlock]>] = [:]
    private var totalCost = 0
    private var tick: UInt64 = 0

    public init(byteLimit: Int = 8 * 1024 * 1024) { self.byteLimit = max(0, byteLimit) }

    /// Actor-isolated parsing serializes misses and reuses completed identical content.
    public func diffs(key: String, headSha: String?, files: [DiffFile]) async throws -> PreparedReviewDiff {
        try Task.checkCancellation()
        let id = ReviewContentID(key: key, headSha: headSha, files: files)
        if var hit = diffsByID[id] { tick &+= 1; hit.access = tick; diffsByID[id] = hit; return hit.value }
        var result: [String: [DiffLine]] = [:]
        for file in files {
            try Task.checkCancellation()
            result[file.newPath] = file.diff.map(parseDiffLines) ?? []
        }
        try Task.checkCancellation()
        let prepared = PreparedReviewDiff(id: id, linesByFile: result)
        let cost = files.reduce(0) { $0 + ($1.diff?.utf8.count ?? 0) + $1.oldPath.utf8.count + $1.newPath.utf8.count }
        insertDiff(prepared, cost: cost)
        return prepared
    }

    public func blocks(source: String) async throws -> [MarkdownBlock] {
        try Task.checkCancellation()
        if var hit = blocksBySource[source] { tick &+= 1; hit.access = tick; blocksBySource[source] = hit; return hit.value }
        let result = parseMarkdownBlocks(source)
        try Task.checkCancellation()
        insertBlocks(result, source: source)
        return result
    }

    /// Source UTF-8 bytes currently retained, exposed for deterministic cache tests.
    public var cachedSourceCost: Int { totalCost }

    private func insertDiff(_ value: PreparedReviewDiff, cost: Int) {
        guard cost <= byteLimit else { return }
        if let old = diffsByID.removeValue(forKey: value.id) { totalCost -= old.cost }
        makeRoom(for: cost)
        tick &+= 1; diffsByID[value.id] = Entry(value: value, cost: cost, access: tick); totalCost += cost
    }
    private func insertBlocks(_ value: [MarkdownBlock], source: String) {
        let cost = source.utf8.count
        guard cost <= byteLimit else { return }
        if let old = blocksBySource.removeValue(forKey: source) { totalCost -= old.cost }
        makeRoom(for: cost)
        tick &+= 1; blocksBySource[source] = Entry(value: value, cost: cost, access: tick); totalCost += cost
    }
    private func makeRoom(for cost: Int) {
        while totalCost + cost > byteLimit {
            let diff = diffsByID.min { $0.value.access < $1.value.access }
            let block = blocksBySource.min { $0.value.access < $1.value.access }
            if let diff, block == nil || diff.value.access <= block!.value.access {
                diffsByID.removeValue(forKey: diff.key); totalCost -= diff.value.cost
            } else if let block {
                blocksBySource.removeValue(forKey: block.key); totalCost -= block.value.cost
            } else { break }
        }
    }
}

public enum ReviewLayout: Equatable, Sendable { case compact, split }
public func reviewLayout(availableWidth: Double) -> ReviewLayout { availableWidth < 900 ? .compact : .split }
