import Testing
@testable import SuicaCore

private func file(_ path: String, _ diff: String) -> DiffFile {
    DiffFile(oldPath: path, newPath: path, newFile: false, renamedFile: false, deletedFile: false, diff: diff)
}

@Test func sameTimestampDifferentMRDoesNotReuseDiff() {
    #expect(ReviewContentID(key: "!1", headSha: "same", files: [file("a", "+x")]) != ReviewContentID(key: "!2", headSha: "same", files: [file("a", "+x")]))
}

@Test func contentChangeInvalidatesSameHead() {
    #expect(ReviewContentID(key: "!1", headSha: "same", files: [file("a", "+x")]) != ReviewContentID(key: "!1", headSha: "same", files: [file("a", "+y")]))
}

@Test func oldPreparationCannotReplaceSelectedMR() async {
    let cache = ReviewPresentationCache()
    let old = try! await cache.diffs(key: "!1", headSha: nil, files: [file("a", "@@ -1 +1 @@\n+x")])
    let selected = ReviewContentID(key: "!2", headSha: nil, files: [file("b", "@@ -1 +1 @@\n+y")])
    #expect(old.id != selected)
}

@Test func presentationCacheHonorsByteBudgetAndParserSemantics() async throws {
    let cache = ReviewPresentationCache(byteLimit: 12)
    let md = "[link](x)\n```\ncode\n```\n|a|\n|--|\n|b|\n- [x] done"
    #expect(try await cache.blocks(source: md) == parseMarkdownBlocks(md))
    #expect(await cache.cachedSourceCost <= 12)
    _ = try await cache.blocks(source: String(repeating: "x", count: 100_000))
    #expect(await cache.cachedSourceCost <= 12)
    let d = "@@ -1 +1 @@\n-a\n+b"
    let fs = [file("a", d)]
    let got = try await cache.diffs(key: "!1", headSha: nil, files: fs)
    #expect(got.linesByFile["a"] == parseDiffLines(d))
    #expect(await cache.cachedSourceCost <= 12)
}

@Test func identicalRequestsReuseStableCacheCostAndOutput() async throws {
    let cache = ReviewPresentationCache()
    let source = "# repeated\n\n- one\n- two"
    let first = try await cache.blocks(source: source)
    let firstCost = await cache.cachedSourceCost
    let second = try await cache.blocks(source: source)
    #expect(second == first)
    #expect(await cache.cachedSourceCost == firstCost)

    let files = [file("a", "@@ -1 +1 @@\n-old\n+new")]
    let diff1 = try await cache.diffs(key: "!1", headSha: "abc", files: files)
    let diffCost = await cache.cachedSourceCost
    let diff2 = try await cache.diffs(key: "!1", headSha: "abc", files: files)
    #expect(diff2.linesByFile == diff1.linesByFile)
    #expect(diff2.id == diff1.id)
    #expect(await cache.cachedSourceCost == diffCost)
}

@Test func cancelledCallerThrowsWithoutCacheInsertion() async {
    let cache = ReviewPresentationCache()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await cache.blocks(source: "cancelled")
    }
    do {
        _ = try await task.value
        Issue.record("Expected cancellation")
    } catch is CancellationError {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(await cache.cachedSourceCost == 0)
}

@Test func layoutUsesAvailablePageWidth() {
    #expect(reviewLayout(availableWidth: 899) == .compact)
    #expect(reviewLayout(availableWidth: 900) == .split)
}
