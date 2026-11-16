import Foundation
import Testing

@testable import SuicaCore

private func cachedDetail(_ key: String) throws -> MergeRequestDetail {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    let data = try Data(contentsOf: url.appending(path: "contracts/mr-detail.v1.json"))
    let original = try decodeDocument(MergeRequestDetail.self, from: data)
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object["key"] = key
    return try decodeDocument(MergeRequestDetail.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func cacheEvictsLeastRecentlyUsedUnselected() throws {
    let now = Date(timeIntervalSince1970: 100)
    var cache = ReviewDetailCache(capacity: 3)
    for key in ["a", "b", "c"] { cache.store(try cachedDetail(key), now: now, protecting: nil) }
    #expect(cache.value(for: "a", now: now) != nil) // a is now most recently used
    cache.store(try cachedDetail("d"), now: now, protecting: nil)
    #expect(cache.value(for: "b", now: now) == nil)
    #expect(cache.value(for: "a", now: now) != nil)
}

@Test func cacheProtectsSelectedEntryDuringEviction() throws {
    let now = Date(timeIntervalSince1970: 100)
    var cache = ReviewDetailCache(capacity: 2)
    cache.store(try cachedDetail("selected"), now: now, protecting: "selected")
    cache.store(try cachedDetail("other"), now: now, protecting: "selected")
    cache.store(try cachedDetail("new"), now: now, protecting: "selected")
    #expect(cache.value(for: "selected", now: now) != nil)
    #expect(cache.value(for: "other", now: now) == nil)
}

@Test func cacheAccessUpdatesLRUOrder() throws {
    let now = Date(timeIntervalSince1970: 100)
    var cache = ReviewDetailCache(capacity: 2)
    cache.store(try cachedDetail("a"), now: now, protecting: nil)
    cache.store(try cachedDetail("b"), now: now, protecting: nil)
    _ = cache.value(for: "a", now: now)
    cache.store(try cachedDetail("c"), now: now, protecting: nil)
    #expect(cache.value(for: "a", now: now) != nil)
    #expect(cache.value(for: "b", now: now) == nil)
}

@Test func cacheFreshnessBoundaryAndInvalidation() throws {
    let start = Date(timeIntervalSince1970: 100)
    var cache = ReviewDetailCache()
    cache.store(try cachedDetail("a"), now: start, protecting: nil)
    #expect(cache.isFresh("a", now: start.addingTimeInterval(29.999), lifetime: 30))
    #expect(!cache.isFresh("a", now: start.addingTimeInterval(30), lifetime: 30))
    cache.invalidate("a")
    #expect(!cache.isFresh("a", now: start, lifetime: 30))
    #expect(cache.value(for: "a", now: start) != nil) // stale content remains displayable
}

@Test func cacheRemovesDeletedKeys() throws {
    let now = Date(timeIntervalSince1970: 100)
    var cache = ReviewDetailCache()
    cache.store(try cachedDetail("a"), now: now, protecting: nil)
    cache.store(try cachedDetail("b"), now: now, protecting: nil)
    cache.remove(keys: ["a"])
    #expect(cache.value(for: "a", now: now) == nil)
    #expect(cache.value(for: "b", now: now) != nil)
}
