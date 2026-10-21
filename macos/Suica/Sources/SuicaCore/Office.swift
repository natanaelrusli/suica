import Foundation
import Observation

// MARK: - Documents

/// What a Session was doing, one line.
public struct OfficeAction: Codable, Equatable, Sendable {
    /// Epoch milliseconds.
    public let at: Int
    public let text: String

    public init(at: Int, text: String) {
        self.at = at
        self.text = text
    }
}

public enum OfficeStatus: String, Codable, Equatable, Sendable {
    case working, waiting, idle, exited

    /// A status a newer CLI invents is shown as idle rather than failing the whole document.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OfficeStatus(rawValue: raw) ?? .idle
    }
}

/// One running conversation of a Coding Agent, in one folder.
public struct OfficeSession: Codable, Equatable, Sendable, Identifiable {
    /// claude, codex, gemini, or the name of an `office.custom` agent.
    public let agent: String
    public let sessionId: String
    public let cwd: String
    public var status: OfficeStatus
    public let activity: String
    public let recentActions: [OfficeAction]
    public let startedAt: Int?
    public let updatedAt: Int
    public let pid: Int?
    /// The Room: the repository root, or the folder itself.
    public let room: String
    public let roomName: String
    /// The `.app` that hosts the Session, when the CLI could find it.
    public let hostApp: String?

    public var id: String { "\(agent)/\(sessionId)" }

    public init(
        agent: String, sessionId: String, cwd: String, status: OfficeStatus, activity: String,
        recentActions: [OfficeAction], startedAt: Int?, updatedAt: Int, pid: Int?, room: String,
        roomName: String, hostApp: String?
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.activity = activity
        self.recentActions = recentActions
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.pid = pid
        self.room = room
        self.roomName = roomName
        self.hostApp = hostApp
    }

    /// What the bubble above the figure says, at most 32 characters.
    public var bubble: String {
        switch status {
        case .waiting: Copy.bubbleWaiting
        case .exited: Copy.bubbleExited
        case .idle: Copy.bubbleIdle
        case .working:
            DisplayText.clean(activity, max: 32).isEmpty
                ? Copy.bubbleWorking : DisplayText.clean(activity, max: 32)
        }
    }
}

/// `suica office --json`.
public struct OfficeDocument: Codable, Equatable, Sendable {
    public let version: Int
    public let generatedAt: Int
    public let sessions: [OfficeSession]

    public init(version: Int, generatedAt: Int, sessions: [OfficeSession]) {
        self.version = version
        self.generatedAt = generatedAt
        self.sessions = sessions
    }
}

public protocol OfficeClient: Sendable {
    func office() async throws(AgentError) -> OfficeDocument
}

// MARK: - Agents

public struct OfficeColour: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
}

/// How a Coding Agent type looks and is called.
public struct OfficeAgent: Equatable, Sendable {
    public let kind: String

    public init(kind: String) { self.kind = kind }

    public var name: String {
        switch kind {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "gemini": "Gemini CLI"
        default: DisplayText.clean(kind, max: 24)
        }
    }

    /// Claude coral, Codex teal, Gemini purple, any other grey.
    public var colour: OfficeColour {
        switch kind {
        case "claude": OfficeColour(red: 0.85, green: 0.47, blue: 0.34)
        case "codex": OfficeColour(red: 0.0, green: 0.65, blue: 0.6)
        case "gemini": OfficeColour(red: 0.55, green: 0.36, blue: 0.96)
        default: OfficeColour(red: 0.55, green: 0.55, blue: 0.58)
        }
    }
}

// MARK: - Rooms and layout

/// A project folder with at least one Session; its Sessions are in Desk order.
public struct OfficeRoom: Equatable, Sendable, Identifiable {
    public let path: String
    public let name: String
    public let sessions: [OfficeSession]

    public var id: String { path }

    public init(path: String, name: String, sessions: [OfficeSession]) {
        self.path = path
        self.name = name
        self.sessions = sessions
    }
}

/// A position on the office floor: x to the right, z toward the viewer, in scene metres.
public struct OfficePoint: Equatable, Sendable {
    public let x: Double
    public let z: Double
}

/// A side of a room: north is the far side of the scene, south the near side.
public enum OfficeSide: String, Equatable, Sendable {
    case north, south, west, east
}

public struct PlacedDesk: Equatable, Sendable, Identifiable {
    public let sessionId: String
    public let position: OfficePoint

    public var id: String { sessionId }
}

/// A room of the building: a project Room, or the Center Room they all open onto.
public struct PlacedRoom: Equatable, Sendable, Identifiable {
    public let path: String
    public let name: String
    public let center: OfficePoint
    public let width: Double
    public let depth: Double
    public let desks: [PlacedDesk]
    /// The sides that have a wall.
    public let walls: Set<OfficeSide>
    /// The side with a doorway; the one facing the Center Room.
    public let door: OfficeSide?
    public let isCenter: Bool

    public var id: String { path }
}

/// Where each room and Desk stands. The building is one rectangle: the Center Room runs across its
/// middle, with a row of project Rooms on its far side and one on its near side, each opening onto
/// it through a doorway. Each Room is sized by its Desks and stretched so a row fills the width.
public struct OfficeLayout: Equatable, Sendable {
    /// The project Rooms.
    public let rooms: [PlacedRoom]
    public let center: PlacedRoom
    /// The building's extent, for fitting the camera.
    public let width: Double
    public let depth: Double

    static let deskSpacingX = 1.8
    static let deskSpacingZ = 2.0
    static let desksPerRow = 3
    static let hallDepth = 2.6
    static let emptyWidth = 5.4
    static let emptyDepth = 3.6

    /// Every room, the Center Room last.
    public var all: [PlacedRoom] { rooms + [center] }

    public static func make(_ rooms: [OfficeRoom]) -> OfficeLayout {
        let centerName = Copy.officeCenterRoom
        guard !rooms.isEmpty else {
            let center = PlacedRoom(
                path: "", name: centerName, center: OfficePoint(x: 0, z: 0), width: emptyWidth, depth: emptyDepth,
                desks: [], walls: [.north, .west, .east], door: nil, isCenter: true)
            return OfficeLayout(rooms: [], center: center, width: emptyWidth, depth: emptyDepth)
        }
        struct Size {
            let room: OfficeRoom
            let columns: Int
            let rows: Int
            var width: Double { Double(columns) * OfficeLayout.deskSpacingX + 1.8 }
            var depth: Double { Double(rows) * OfficeLayout.deskSpacingZ + 1.2 }
        }
        let sizes = rooms.map { room -> Size in
            let columns = max(1, min(room.sessions.count, desksPerRow))
            return Size(room: room, columns: columns, rows: max(1, (room.sessions.count + columns - 1) / columns))
        }
        // Alternate sides, so a new Room never leaves one side empty while the other grows.
        let far = sizes.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let near = sizes.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        func natural(_ row: [Size]) -> Double { row.map(\.width).reduce(0, +) }
        func rowDepth(_ row: [Size]) -> Double { row.map(\.depth).max() ?? 0 }
        let width = max(emptyWidth, natural(far), natural(near))
        let farDepth = rowDepth(far)
        let nearDepth = rowDepth(near)
        let depth = farDepth + hallDepth + nearDepth
        let top = -depth / 2

        func place(_ row: [Size], centreZ: Double, rowDepth: Double, door: OfficeSide) -> [PlacedRoom] {
            let extra = (width - natural(row)) / Double(max(row.count, 1))
            var x = -width / 2
            return row.map { size in
                let roomWidth = size.width + extra
                let centre = OfficePoint(x: x + roomWidth / 2, z: centreZ)
                x += roomWidth
                let desks = size.room.sessions.enumerated().map { offset, session in
                    let column = offset % size.columns
                    let line = offset / size.columns
                    return PlacedDesk(
                        sessionId: session.id,
                        position: OfficePoint(
                            x: centre.x + (Double(column) - Double(size.columns - 1) / 2) * deskSpacingX,
                            z: centre.z + (Double(line) - Double(size.rows - 1) / 2) * deskSpacingZ))
                }
                return PlacedRoom(
                    path: size.room.path, name: size.room.name, center: centre, width: roomWidth, depth: rowDepth,
                    desks: desks, walls: [.north, .south, .west, .east], door: door, isCenter: false)
            }
        }
        let placed =
            place(far, centreZ: top + farDepth / 2, rowDepth: farDepth, door: .south)
            + place(near, centreZ: top + farDepth + hallDepth + nearDepth / 2, rowDepth: nearDepth, door: .north)
        // The near side of the Center Room is open when no Room stands there.
        let center = PlacedRoom(
            path: "", name: centerName, center: OfficePoint(x: 0, z: top + farDepth + hallDepth / 2), width: width,
            depth: hallDepth, desks: [], walls: [.west, .east], door: nil, isCenter: true)
        return OfficeLayout(rooms: placed, center: center, width: width, depth: depth)
    }
}

// MARK: - Model

/// What changed between two snapshots, by session id.
public struct OfficeDiff: Equatable, Sendable {
    public var arrived: [String] = []
    public var updated: [String] = []
    /// Live a moment ago, gone now: the figure goes grey and stays at its Desk.
    public var departed: [String] = []
    /// Left for good, after the stay: the Desk is cleared.
    public var removed: [String] = []
}

/// The Office page's state: the Sessions the CLI reports, plus those that just left.
@MainActor @Observable
public final class OfficeModel {
    /// Sessions in Desk order (first seen first).
    public private(set) var sessions: [OfficeSession] = []
    public private(set) var rooms: [OfficeRoom] = []
    public private(set) var layout = OfficeLayout.make([])
    public private(set) var lastDiff = OfficeDiff()
    public private(set) var errorText: String?
    /// A snapshot has arrived at least once.
    public private(set) var loaded = false
    public private(set) var selectedId: String?

    /// A Session whose process exited stays at its Desk, greyed, this long.
    public static let stay: TimeInterval = 300

    private struct Entry {
        var session: OfficeSession
        let order: Int
        /// When it stopped being live; nil while live.
        var exitedAt: Date?
    }

    @ObservationIgnored private let client: any OfficeClient
    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var nextOrder = 0

    public init(client: any OfficeClient) { self.client = client }

    public var selected: OfficeSession? { selectedId.flatMap { entries[$0]?.session } }

    public func select(_ id: String?) { selectedId = id }

    /// Reads the CLI once; a failure keeps the last good office and says why.
    public func refresh(now: Date = Date()) async {
        do {
            let document = try await client.office()
            apply(document, now: now)
            errorText = nil
        } catch {
            errorText = MenuModel.message(for: error)
        }
    }

    /// Polls until cancelled; the page runs it only while it is on screen.
    public func runPollLoop(every interval: Duration) async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    public func apply(_ document: OfficeDocument, now: Date) {
        var diff = OfficeDiff()
        var next: [String: Entry] = [:]
        for session in document.sessions {
            let exitedAt = session.status == .exited ? Date(timeIntervalSince1970: Double(session.updatedAt) / 1000) : nil
            if let old = entries[session.id] {
                if old.session != session { diff.updated.append(session.id) }
                next[session.id] = Entry(session: session, order: old.order, exitedAt: exitedAt)
            } else {
                diff.arrived.append(session.id)
                next[session.id] = Entry(session: session, order: nextOrder, exitedAt: exitedAt)
                nextOrder += 1
            }
        }
        for (id, old) in entries where next[id] == nil {
            var entry = old
            if entry.exitedAt == nil {
                entry.session.status = .exited
                entry.exitedAt = now
                diff.departed.append(id)
            }
            if let exitedAt = entry.exitedAt, now.timeIntervalSince(exitedAt) > Self.stay {
                diff.removed.append(id)
            } else {
                next[id] = entry
            }
        }
        diff.departed.sort { (entries[$0]?.order ?? 0) < (entries[$1]?.order ?? 0) }
        diff.removed.sort { (entries[$0]?.order ?? 0) < (entries[$1]?.order ?? 0) }
        entries = next
        if let id = selectedId, entries[id] == nil { selectedId = nil }
        lastDiff = diff
        loaded = true
        rebuild()
    }

    private func rebuild() {
        sessions = entries.values.sorted { $0.order < $1.order }.map(\.session)
        var byRoom: [String: [OfficeSession]] = [:]
        for session in sessions { byRoom[session.room, default: []].append(session) }
        rooms = byRoom.map { path, members in
            OfficeRoom(path: path, name: members.first?.roomName ?? path, sessions: members)
        }
        .sorted { ($0.name, $0.path) < ($1.name, $1.path) }
        layout = OfficeLayout.make(rooms)
    }
}
