import Foundation
import Testing

@testable import SuicaCore

@Test func cleanupResultMatchesTheGolden() throws {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    let data = try Data(contentsOf: url.appending(path: "contracts/cleanup.v1.json"))
    #expect(try decodeDocument(CleanupResult.self, from: data) == CleanupResult(freedBytes: 3_145_728))
}

@MainActor @Test func cleanUpSaysHowMuchItFreed() async {
    let client = FakeDashboardClient()
    let model = WindowModel(client: client, menu: MenuModel(client: FakeClient(states: [.success(makeState())])))
    await model.cleanUp()
    #expect(model.banner == Copy.cleanupDone(2_000_000))
    #expect(model.banner?.hasPrefix("Cleaned up 2") == true)
    #expect(!model.cleaningUp)
    #expect(Copy.cleanupDone(0) == "Already clean.")
}
