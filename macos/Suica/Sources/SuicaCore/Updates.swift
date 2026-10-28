import Foundation
import Observation

// MARK: - Documents (contracts/update.v1.json)

/// `suica update check --json`, told apart by its `status`.
public enum UpdateCheck: Decodable, Equatable, Sendable {
    case upToDate(current: String)
    case available(current: String, latest: String)
    case unavailable(message: String)

    private enum Keys: String, CodingKey { case status, current, latest, message }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .status) {
        case "up-to-date": self = .upToDate(current: try c.decode(String.self, forKey: .current))
        case "available":
            self = .available(current: try c.decode(String.self, forKey: .current), latest: try c.decode(String.self, forKey: .latest))
        case "unavailable": self = .unavailable(message: try c.decode(String.self, forKey: .message))
        default: throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "unknown status")
        }
    }
}

/// `suica update apply --json`: `staged` carries the paths for the swap script.
public struct UpdateApplied: Decodable, Equatable, Sendable {
    public let status: String
    public let release: String?
    public let staged: String?
    public let target: String?
    public let swapScript: String?
    public let message: String?
}

public protocol UpdatesClient: Sendable {
    func checkUpdate() async throws(AgentError) -> UpdateCheck
    func applyUpdate() async throws(AgentError) -> UpdateApplied
}

// MARK: - Model

@MainActor @Observable
public final class UpdatesModel {
    public enum State: Equatable { case idle, available(String), installing, failed(String) }

    public private(set) var state: State = .idle
    private let client: any UpdatesClient
    private let store: UserDefaults
    private let now: () -> Date
    private let relaunch: @MainActor (UpdateApplied) -> Bool
    private static let lastCheckKey = "updates.lastCheck"

    /// `relaunch` runs the swap script and quits the app (it lives in the app target); false when it could not start.
    public init(
        client: any UpdatesClient, store: UserDefaults, now: @escaping () -> Date,
        relaunch: @escaping @MainActor (UpdateApplied) -> Bool
    ) {
        self.client = client
        self.store = store
        self.now = now
        self.relaunch = relaunch
    }

    /// Checks at most once every 24 hours and says nothing when the check cannot run.
    public func checkIfDue() async {
        let last = store.double(forKey: Self.lastCheckKey)
        guard now().timeIntervalSince1970 - last >= 24 * 3600 else { return }
        await check(surfaceUnavailable: false)
    }

    public func checkNow() async { await check(surfaceUnavailable: true) }

    private func check(surfaceUnavailable: Bool) async {
        guard state != .installing else { return }
        guard let result = try? await client.checkUpdate() else {
            if surfaceUnavailable { state = .failed(Copy.updateCheckFailed) }
            return
        }
        store.set(now().timeIntervalSince1970, forKey: Self.lastCheckKey)
        switch result {
        case .upToDate: state = .idle
        case .available(_, let latest): state = .available(latest)
        case .unavailable(let message): state = surfaceUnavailable ? .failed(message) : .idle
        }
    }

    public func install() async {
        guard state != .installing else { return }
        state = .installing
        let applied: UpdateApplied
        do { applied = try await client.applyUpdate() } catch {
            state = .failed(Copy.updateInstallFailed)
            return
        }
        guard applied.status == "staged", applied.staged != nil, applied.target != nil, applied.swapScript != nil else {
            state = applied.status == "up-to-date" ? .idle : .failed(applied.message ?? Copy.updateInstallFailed)
            return
        }
        if !relaunch(applied) { state = .failed(Copy.updateInstallFailed) }
    }
}
