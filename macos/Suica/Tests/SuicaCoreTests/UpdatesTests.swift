import Foundation
import Testing

@testable import SuicaCore

private func golden() throws -> [String: [String: Data]] {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appending(path: "contracts/update.v1.json")))
    let groups = try #require(root as? [String: [String: Any]])
    return try groups.mapValues { try $0.mapValues { try JSONSerialization.data(withJSONObject: $0) } }
}

@Test func checkDocumentsMatchTheGolden() throws {
    let check = try #require(try golden()["check"])
    func decode(_ key: String) throws -> UpdateCheck { try decodeDocument(UpdateCheck.self, from: #require(check[key])) }
    #expect(try decode("up-to-date") == .upToDate(current: "0.1.0"))
    #expect(try decode("available") == .available(current: "0.1.0", latest: "0.1.1"))
    #expect(try decode("unavailable") == .unavailable(message: "manifest signature is invalid"))
}

@Test func applyDocumentsMatchTheGolden() throws {
    let apply = try #require(try golden()["apply"])
    func decode(_ key: String) throws -> UpdateApplied { try decodeDocument(UpdateApplied.self, from: #require(apply[key])) }
    let staged = try decode("staged")
    #expect(staged.status == "staged" && staged.release == "0.1.1")
    #expect(staged.target == "/Users/me/Applications/Suica.app")
    #expect(staged.swapScript?.hasSuffix("swap-app.sh") == true && staged.staged?.hasSuffix("Suica.app") == true)
    #expect(try decode("up-to-date").status == "up-to-date")
    #expect(try decode("failed").message == "downloaded release does not match its sha256")
}

private struct StubUpdates: UpdatesClient {
    final class Calls: @unchecked Sendable { var checks = 0, applies = 0 }
    let calls = Calls()
    var check: UpdateCheck = .available(current: "1", latest: "2")
    var apply = UpdateApplied(
        status: "staged", release: "2", staged: "/s/Suica.app", target: "/t/Suica.app", swapScript: "/s/swap.sh", message: nil)
    func checkUpdate() async throws(AgentError) -> UpdateCheck { calls.checks += 1; return check }
    func applyUpdate() async throws(AgentError) -> UpdateApplied { calls.applies += 1; return apply }
}

private func store() -> UserDefaults {
    let name = "updates-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor private final class Relaunches { var applied: [UpdateApplied] = []; var works = false }

@MainActor @Test func checkIfDueRunsOncePerDay() async {
    let stub = StubUpdates()
    var clock = Date(timeIntervalSince1970: 1_000_000)
    let model = UpdatesModel(client: stub, store: store(), now: { clock }, relaunch: { _ in true })
    await model.checkIfDue()
    #expect(model.state == .available("2"))
    clock += 3600
    await model.checkIfDue()
    #expect(stub.calls.checks == 1)
    clock += 24 * 3600
    await model.checkIfDue()
    #expect(stub.calls.checks == 2)
}

@MainActor @Test func unavailableIsSilentWhenDueButShownByCheckNow() async {
    var stub = StubUpdates()
    stub.check = .unavailable(message: "offline")
    let model = UpdatesModel(client: stub, store: store(), now: { Date() }, relaunch: { _ in true })
    await model.checkIfDue()
    #expect(model.state == .idle)
    await model.checkNow()
    #expect(model.state == .failed("offline"))
}

@MainActor @Test func installRelaunchesOnStagedAndFailsOtherwise() async {
    let relaunches = Relaunches()
    let stub = StubUpdates()
    let model = UpdatesModel(client: stub, store: store(), now: { Date() }, relaunch: { relaunches.applied.append($0); return true })
    await model.install()
    #expect(relaunches.applied.count == 1 && relaunches.applied[0].release == "2")
    #expect(model.state == .installing)

    var failing = StubUpdates()
    failing.apply = UpdateApplied(status: "failed", release: nil, staged: nil, target: nil, swapScript: nil, message: "bad sha")
    let other = UpdatesModel(client: failing, store: store(), now: { Date() }, relaunch: { relaunches.applied.append($0); return true })
    await other.install()
    #expect(other.state == .failed("bad sha") && relaunches.applied.count == 1)
}

@MainActor @Test func aRelaunchThatCannotStartFailsAndCanBeRetried() async {
    let relaunches = Relaunches()
    let model = UpdatesModel(
        client: StubUpdates(), store: store(), now: { Date() },
        relaunch: { relaunches.applied.append($0); return relaunches.works })
    await model.install()
    #expect(model.state == .failed(Copy.updateInstallFailed))
    relaunches.works = true
    await model.install()
    #expect(model.state == .installing && relaunches.applied.count == 2)
}

/// Holds `applyUpdate` open so a second call can arrive while the first is installing.
private actor InstallGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

private struct SlowUpdates: UpdatesClient {
    let gate = InstallGate()
    let inner = StubUpdates()
    func checkUpdate() async throws(AgentError) -> UpdateCheck { try await inner.checkUpdate() }
    func applyUpdate() async throws(AgentError) -> UpdateApplied { await gate.wait(); return try await inner.applyUpdate() }
}

@MainActor @Test func installWhileInstallingAndChecksDuringInstallLeaveItAlone() async {
    let slow = SlowUpdates()
    let relaunches = Relaunches()
    let model = UpdatesModel(
        client: slow, store: store(), now: { Date() }, relaunch: { relaunches.applied.append($0); return true })
    let first = Task { await model.install() }
    while model.state != .installing { await Task.yield() }
    await model.install()
    await model.checkNow()
    await model.checkIfDue()
    #expect(model.state == .installing && slow.inner.calls.applies == 0 && slow.inner.calls.checks == 0)
    await slow.gate.release()
    await first.value
    #expect(slow.inner.calls.applies == 1 && relaunches.applied.count == 1)
}
