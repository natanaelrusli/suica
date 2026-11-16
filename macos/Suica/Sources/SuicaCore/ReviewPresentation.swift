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

    public func diffs(key: String, headSha: String?, files: [DiffFile]) async -> PreparedReviewDiff {
        let id = ReviewContentID(key: key, headSha: headSha, files: files)
        if var hit = diffsByID[id] { tick &+= 1; hit.access = tick; diffsByID[id] = hit; return hit.value }
        let prepared = await Task.detached(priority: .userInitiated) {
            var result: [String: [DiffLine]] = [:]
            for file in files {
                if Task.isCancelled { break }
                result[file.newPath] = file.diff.map(parseDiffLines) ?? []
            }
            return PreparedReviewDiff(id: id, linesByFile: result)
        }.value
        let cost = files.reduce(0) { $0 + ($1.diff?.utf8.count ?? 0) + $1.oldPath.utf8.count + $1.newPath.utf8.count }
        insertDiff(prepared, cost: cost)
        return prepared
    }

    public func blocks(source: String) async -> [MarkdownBlock] {
        if var hit = blocksBySource[source] { tick &+= 1; hit.access = tick; blocksBySource[source] = hit; return hit.value }
        let result = await Task.detached(priority: .userInitiated) { parseMarkdownBlocks(source) }.value
        insertBlocks(result, source: source)
        return result
    }

    /// Source UTF-8 bytes currently retained, exposed for deterministic cache tests.
    public var cachedSourceCost: Int { totalCost }

    private func insertDiff(_ value: PreparedReviewDiff, cost: Int) {
        guard cost <= byteLimit else { return }
        diffsByID.removeValue(forKey: value.id)
        makeRoom(for: cost)
        tick &+= 1; diffsByID[value.id] = Entry(value: value, cost: cost, access: tick); totalCost += cost
    }
    private func insertBlocks(_ value: [MarkdownBlock], source: String) {
        let cost = source.utf8.count
        guard cost <= byteLimit else { return }
        blocksBySource.removeValue(forKey: source)
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
