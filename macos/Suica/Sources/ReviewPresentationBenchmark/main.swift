import Foundation
import SuicaCore

@main
struct ReviewPresentationBenchmark {
    static func main() async throws {
        let files: [DiffFile] = (0..<100).map { index in
            let path = "Sources/Feature/File\(index).swift"
            let header = "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@ -1,3 +1,3 @@\n"
            let body = "-let oldValue = \(index)\n+let newValue = \(index + 1)\n "
            let payloadCharacters = 1_500_000 / 100 - header.count
            let repeated = String(repeating: body, count: payloadCharacters / body.count)
            let remainder = String(body.prefix(payloadCharacters - repeated.count))
            return try! JSONDecoder().decode(DiffFile.self, from: JSONSerialization.data(withJSONObject: ["oldPath": path, "newPath": path, "newFile": false, "renamedFile": false, "deletedFile": false, "diff": header + repeated + remainder]))
        }
        let markdownUnit = "[Review](https://example.com/review)\n\n```swift\nlet ready = true\n```\n\n| Check | Result |\n| --- | --- |\n| Parsing | ready |\n\n- [x] inspect diff\n- [ ] merge change\n\n"
        let markdown = String(repeating: markdownUnit, count: 100_000 / markdownUnit.utf8.count)
            + String(repeating: " ", count: 100_000 % markdownUnit.utf8.count)
        let byteLimit = 8 * 1024 * 1024
        let cache = ReviewPresentationCache(byteLimit: byteLimit)
        let clock = ContinuousClock()

        let coldStart = clock.now
        let coldDiffs = try await cache.diffs(key: "BENCH-1", headSha: "benchmark", files: files)
        let coldBlocks = try await cache.blocks(source: markdown)
        let cold = coldStart.duration(to: clock.now)

        let warmStart = clock.now
        let warmDiffs = try await cache.diffs(key: "BENCH-1", headSha: "benchmark", files: files)
        let warmBlocks = try await cache.blocks(source: markdown)
        let warm = warmStart.duration(to: clock.now)

        guard coldDiffs.id == warmDiffs.id, coldDiffs.linesByFile == warmDiffs.linesByFile,
              coldBlocks == warmBlocks else { throw BenchmarkError.cacheMismatch }
        let cost = await cache.cachedSourceCost
        guard cost <= byteLimit else { throw BenchmarkError.cacheOverLimit(cost, byteLimit) }

        print("fixture.diffCharacters=\(files.compactMap { $0.diff }.reduce(0) { $0 + $1.count })")
        print("fixture.markdownBytes=\(markdown.utf8.count)")
        print("cold.ms=\(cold.milliseconds)")
        print("warm.ms=\(warm.milliseconds)")
        print("cachedSourceCost=\(cost)")
        print("byteLimit=\(byteLimit)")
        print("os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("hardwareArchitecture=\(ProcessInfo.processInfo.environment["PROCESSOR_ARCHITECTURE"] ?? architecture)")
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

private enum BenchmarkError: Error {
    case cacheMismatch
    case cacheOverLimit(Int, Int)
}

private extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}
