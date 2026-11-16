import XCTest
@testable import SuicaCore

final class ReviewViewStateTests: XCTestCase {
    func testEvictsLeastRecentAndProtectsSelectedEntry() {
        var cache = ReviewViewStateCache(capacity: 8)
        for index in 0..<8 { cache.update("mr\(index)", selectedKey: nil) { $0.tab = .changes } }
        cache.update("mr0", selectedKey: "mr0") { $0.tab = .comments }
        cache.update("mr8", selectedKey: "mr8") { $0.tab = .agent }

        XCTAssertEqual(cache.state(for: "mr0").tab, .comments)
        XCTAssertEqual(cache.state(for: "mr8").tab, .agent)
        XCTAssertEqual(cache.state(for: "mr1").tab, .description)
    }

    func testRetainsTabAndCollapsedFilesTogether() {
        var cache = ReviewViewStateCache()
        cache.update("mr", selectedKey: "mr") {
            $0.tab = .changes
            $0.collapsedFiles = ["src/a.swift", "src/b.swift"]
        }
        let state = cache.state(for: "mr")
        XCTAssertEqual(state.tab, .changes)
        XCTAssertEqual(state.collapsedFiles, ["src/a.swift", "src/b.swift"])
    }
}
