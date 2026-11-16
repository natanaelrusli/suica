import Foundation

/// A small in-memory LRU for recently viewed merge request documents.
/// Freshness is measured from the last successful store, independently of access order.
struct ReviewDetailCache {
    private struct Entry {
        var value: MergeRequestDetail
        var fetchedAt: Date
        var lastAccessedAt: Date
        var accessOrder: UInt64
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var nextOrder: UInt64 = 0

    init(capacity: Int = 8) {
        precondition(capacity > 0, "ReviewDetailCache capacity must be positive")
        self.capacity = capacity
    }

    mutating func value(for key: String, now: Date) -> MergeRequestDetail? {
        guard var entry = entries[key] else { return nil }
        entry.lastAccessedAt = now
        entry.accessOrder = issueOrder()
        entries[key] = entry
        return entry.value
    }

    mutating func store(_ value: MergeRequestDetail, now: Date, protecting selectedKey: String?) {
        let key = value.key
        let order = issueOrder()
        entries[key] = Entry(value: value, fetchedAt: now, lastAccessedAt: now, accessOrder: order)
        while entries.count > capacity {
            guard let victim = entries
                .filter({ $0.key != selectedKey })
                .min(by: { $0.value.accessOrder < $1.value.accessOrder })?.key else {
                // A single selected entry cannot exceed capacity because capacity is positive.
                break
            }
            entries.removeValue(forKey: victim)
        }
    }

    func isFresh(_ key: String, now: Date, lifetime: TimeInterval) -> Bool {
        guard lifetime >= 0, let entry = entries[key] else { return false }
        let age = now.timeIntervalSince(entry.fetchedAt)
        return age >= 0 && age < lifetime
    }

    mutating func invalidate(_ key: String) {
        // Keep the value available for display while forcing the next read to refresh it.
        entries[key]?.fetchedAt = .distantPast
    }

    mutating func remove(keys: Set<String>) {
        for key in keys { entries.removeValue(forKey: key) }
    }

    private mutating func issueOrder() -> UInt64 {
        nextOrder &+= 1
        return nextOrder
    }
}
