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
    /// The Session Title: the name its agent gives it, or the first line of its first prompt.
    public let title: String?
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
        agent: String, sessionId: String, title: String? = nil, cwd: String, status: OfficeStatus, activity: String,
        recentActions: [OfficeAction], startedAt: Int?, updatedAt: Int, pid: Int?, room: String,
        roomName: String, hostApp: String?
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.title = title
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

    /// The Session Title as the chat panel heads it: the agent's name when there is none.
    public var heading: String {
        let clean = title.map { DisplayText.clean($0, max: 120) } ?? ""
        return clean.isEmpty ? OfficeAgent(kind: agent).name : clean
    }

    /// The Session Title on the bubble's first line, at most 28 characters; nothing without a title.
    public var bubbleTitle: String { title.map { DisplayText.clean($0, max: 28) } ?? "" }

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

public enum OfficeChatRole: String, Codable, Equatable, Sendable {
    case user, assistant

    /// A role a newer CLI invents reads as the agent's, so the message still shows.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OfficeChatRole(rawValue: raw) ?? .assistant
    }
}

/// One turn of a Session's conversation: the Owner's prompt or the agent's answer.
public struct OfficeChatMessage: Codable, Equatable, Sendable {
    /// Epoch milliseconds; 0 when the transcript gives none.
    public let at: Int
    public let role: OfficeChatRole
    public let text: String

    public init(at: Int, role: OfficeChatRole, text: String) {
        self.at = at
        self.role = role
        self.text = text
    }
}

/// `suica office chat <agent> <sessionId> --json`: the last messages of one Session.
public struct OfficeChatDocument: Codable, Equatable, Sendable {
    public let version: Int
    public let agent: String
    public let sessionId: String
    public let title: String?
    public let messages: [OfficeChatMessage]

    public init(version: Int, agent: String, sessionId: String, title: String?, messages: [OfficeChatMessage]) {
        self.version = version
        self.agent = agent
        self.sessionId = sessionId
        self.title = title
        self.messages = messages
    }
}

public protocol OfficeClient: Sendable {
    func office() async throws(AgentError) -> OfficeDocument
    func chat(agent: String, sessionId: String) async throws(AgentError) -> OfficeChatDocument
}

// MARK: - Agents

public struct OfficeColour: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
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

extension OfficeColour {
    init(_ red: Double, _ green: Double, _ blue: Double) { self.init(red: red, green: green, blue: blue) }

    public func mixed(with other: OfficeColour, _ amount: Double) -> OfficeColour {
        OfficeColour(
            red + (other.red - red) * amount, green + (other.green - green) * amount,
            blue + (other.blue - blue) * amount)
    }

    /// Nearly grey, keeping its lightness: how an idle or exited figure is drawn.
    public var greyed: OfficeColour {
        let light = red * 0.3 + green * 0.59 + blue * 0.11
        return mixed(with: OfficeColour(light, light, light), 0.85)
    }

    static let black = OfficeColour(0, 0, 0)
    static let white = OfficeColour(1, 1, 1)
}

/// A generator seeded by text: a figure or a Room looks the same on every poll and every launch
/// (Swift's `Hasher` is seeded per process). FNV-1a for the seed, SplitMix64 for the stream.
public struct OfficeSeed: RandomNumberGenerator {
    private var state: UInt64

    public init(_ text: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        state = hash
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}

// MARK: - Looks

public enum OfficeHair: CaseIterable, Sendable {
    case bald, short, long, bun, ponytail, spiky, cap
}

public enum OfficeShirt: CaseIterable, Sendable {
    case tee, stripe, hoodie, collar
}

public enum OfficeExtra: CaseIterable, Sendable {
    case none, glasses, headphones
}

/// How one Session's figure looks: picked from its id, so it keeps its look while it runs. The shirt
/// stays a shade of the agent's colour, so the agent type still reads at a glance.
public struct OfficeLook: Equatable, Sendable {
    public let skin: OfficeColour
    public let hair: OfficeHair
    public let hairColour: OfficeColour
    public let shirt: OfficeShirt
    public let shirtColour: OfficeColour
    public let trousers: OfficeColour
    public let extra: OfficeExtra

    static let skins = [
        OfficeColour(0.98, 0.85, 0.74), OfficeColour(0.94, 0.76, 0.6), OfficeColour(0.85, 0.64, 0.47),
        OfficeColour(0.72, 0.5, 0.34), OfficeColour(0.55, 0.37, 0.24), OfficeColour(0.38, 0.25, 0.17),
    ]
    static let hairColours = [
        OfficeColour(0.1, 0.08, 0.07), OfficeColour(0.28, 0.18, 0.1), OfficeColour(0.45, 0.3, 0.17),
        OfficeColour(0.88, 0.74, 0.45), OfficeColour(0.75, 0.38, 0.16), OfficeColour(0.72, 0.72, 0.74),
        OfficeColour(0.3, 0.45, 0.9), OfficeColour(0.92, 0.45, 0.65),
    ]
    static let trouserColours = [
        OfficeColour(0.16, 0.2, 0.34), OfficeColour(0.22, 0.22, 0.24), OfficeColour(0.66, 0.58, 0.42),
        OfficeColour(0.3, 0.42, 0.6), OfficeColour(0.1, 0.1, 0.11),
    ]

    public init(session: OfficeSession) {
        var seed = OfficeSeed("figure:\(session.id)")
        let agent = OfficeAgent(kind: session.agent).colour
        let shades = [
            agent.mixed(with: .black, 0.25), agent, agent.mixed(with: .white, 0.25), agent.mixed(with: .white, 0.45),
        ]
        skin = Self.skins.randomElement(using: &seed)!
        hair = OfficeHair.allCases.randomElement(using: &seed)!
        hairColour = Self.hairColours.randomElement(using: &seed)!
        shirt = OfficeShirt.allCases.randomElement(using: &seed)!
        shirtColour = shades.randomElement(using: &seed)!
        trousers = Self.trouserColours.randomElement(using: &seed)!
        // Half wear nothing extra.
        extra = Bool.random(using: &seed) ? .none : [OfficeExtra.glasses, .headphones].randomElement(using: &seed)!
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

    public init(x: Double, z: Double) {
        self.x = x
        self.z = z
    }
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

public enum OfficeFurniture: CaseIterable, Sendable {
    case plant, tree, bookshelf, cabinet, waterCooler, lamp, whiteboard, armchair, beanBag, bin

    /// Taller than a seated figure: kept to the back half of a room, so it never hides a Desk.
    public var isTall: Bool {
        switch self {
        case .tree, .bookshelf, .waterCooler, .lamp, .whiteboard: true
        case .plant, .cabinet, .armchair, .beanBag, .bin: false
        }
    }
}

/// A piece of furniture against a side wall of a room.
public struct PlacedFurniture: Equatable, Sendable {
    public let kind: OfficeFurniture
    public let position: OfficePoint
    /// The wall behind it; it faces away from it.
    public let against: OfficeSide
    /// Which of a few colours it comes in.
    public let variant: Int
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
    /// Seeded by the room's path, so it stays put while the room keeps its size.
    public internal(set) var furniture: [PlacedFurniture] = []

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
            let center = furnish(
                PlacedRoom(
                    path: "", name: centerName, center: OfficePoint(x: 0, z: 0), width: emptyWidth,
                    depth: emptyDepth, desks: [], walls: [.north, .west, .east], door: nil, isCenter: true))
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
                return furnish(
                    PlacedRoom(
                        path: size.room.path, name: size.room.name, center: centre, width: roomWidth,
                        depth: rowDepth, desks: desks, walls: [.north, .south, .west, .east], door: door,
                        isCenter: false))
            }
        }
        let placed =
            place(far, centreZ: top + farDepth / 2, rowDepth: farDepth, door: .south)
            + place(near, centreZ: top + farDepth + hallDepth + nearDepth / 2, rowDepth: nearDepth, door: .north)
        // The near side of the Center Room is open when no Room stands there.
        let center = furnish(
            PlacedRoom(
                path: "", name: centerName, center: OfficePoint(x: 0, z: top + farDepth + hallDepth / 2),
                width: width, depth: hallDepth, desks: [], walls: [.west, .east], door: nil, isCenter: true))
        return OfficeLayout(rooms: placed, center: center, width: width, depth: depth)
    }

    /// Every piece of furniture fits in a square this wide.
    public static let furnitureSize = 0.8

    /// Furniture along the side walls, where Desks never stand: a piece in most corners and now and
    /// then one between them in a deep room. Tall pieces stay in the back half, so the camera sees
    /// every Desk. The near west corner stays free: a room's name stands on that wall (on the Center
    /// Room's floor), and anything behind it made it hard to read.
    static func furnish(_ room: PlacedRoom) -> PlacedRoom {
        var seed = OfficeSeed("room:\(room.path)")
        let inset = furnitureSize / 2 + 0.1
        let back = -room.depth / 2 + inset
        let front = room.depth / 2 - inset
        let between = max(0, Int((front - back) / 1.6) - 1)
        var corners: [OfficePoint] = []
        var middles: [OfficePoint] = []
        for side in [-1.0, 1.0] {
            let x = side * (room.width / 2 - inset)
            corners.append(OfficePoint(x: x, z: back))
            if side > 0 { corners.append(OfficePoint(x: x, z: front)) }
            for step in 0..<between {
                middles.append(OfficePoint(x: x, z: back + (front - back) * Double(step + 1) / Double(between + 1)))
            }
        }
        // One corner may stay empty; each middle place is filled half the time.
        let empty = Int.random(in: 0...corners.count, using: &seed)
        var spots = corners.enumerated().filter { $0.offset != empty }.map(\.element)
        spots += middles.filter { _ in Bool.random(using: &seed) }

        var bag: [OfficeFurniture] = []
        var placed = room
        for spot in spots {
            if !bag.contains(where: { spot.z < 0 || !$0.isTall }) {
                bag = OfficeFurniture.allCases.shuffled(using: &seed)
            }
            let index = bag.firstIndex { spot.z < 0 || !$0.isTall }!
            placed.furniture.append(
                PlacedFurniture(
                    kind: bag.remove(at: index),
                    position: OfficePoint(x: room.center.x + spot.x, z: room.center.z + spot.z),
                    against: spot.x < 0 ? .west : .east, variant: Int.random(in: 0..<4, using: &seed)))
        }
        return placed
    }
}

// MARK: - Walking

/// Where a figure walks, as straight legs between points on the floor.
public struct OfficePath: Equatable, Sendable {
    public let points: [OfficePoint]
    public let length: Double

    public init(_ points: [OfficePoint]) {
        // A repeated point is a leg of no length: dropped, so headings stay defined.
        var kept: [OfficePoint] = []
        for point in points where kept.last != point { kept.append(point) }
        self.points = kept
        length = zip(kept, kept.dropFirst()).reduce(0) { total, leg in
            total + ((leg.1.x - leg.0.x) * (leg.1.x - leg.0.x) + (leg.1.z - leg.0.z) * (leg.1.z - leg.0.z)).squareRoot()
        }
    }

    public var start: OfficePoint? { points.first }
    public var end: OfficePoint? { points.last }

    /// Where the walker is after `distance` metres, and the way it faces (a unit vector, nil when
    /// the path has no length). Before the start it is at the start; past the end, at the end.
    public func position(at distance: Double) -> (point: OfficePoint, heading: OfficePoint?) {
        guard let first = points.first else { return (OfficePoint(x: 0, z: 0), nil) }
        var left = max(0, distance)
        var heading: OfficePoint?
        for (from, to) in zip(points, points.dropFirst()) {
            let dx = to.x - from.x
            let dz = to.z - from.z
            let leg = (dx * dx + dz * dz).squareRoot()
            heading = OfficePoint(x: dx / leg, z: dz / leg)
            if left <= leg {
                let t = left / leg
                return (OfficePoint(x: from.x + dx * t, z: from.z + dz * t), heading)
            }
            left -= leg
        }
        return (points.last ?? first, heading)
    }
}

extension OfficeLayout {
    /// How far in front of its Desk a figure's chair stands.
    public static let chairOffset = 0.55
    /// The aisle a figure walks along, in from the door wall.
    static let aisleInset = 0.45
    /// The gap beside a Desk a figure walks down to its chair: Desks stand 1.8 m apart and are 1.2 m wide.
    static let gapBesideDesk = 0.9

    /// Where a figure walks from `room`'s doorway to its Desk's chair: along the aisle by the door
    /// wall, down the gap beside its Desk, then across to the chair. Walked backwards to leave. A
    /// room without a door (none in a building) gives the chair alone.
    public static func walk(in room: PlacedRoom, to desk: PlacedDesk) -> OfficePath {
        let chair = OfficePoint(x: desk.position.x, z: desk.position.z + chairOffset)
        guard let side = room.door, side == .north || side == .south else { return OfficePath([chair]) }
        let out = side == .north ? -1.0 : 1.0
        let door = OfficePoint(x: room.center.x, z: room.center.z + out * room.depth / 2)
        let aisle = door.z - out * aisleInset
        let gap = min(desk.position.x + gapBesideDesk, room.center.x + room.width / 2 - 0.35)
        return OfficePath([
            door, OfficePoint(x: door.x, z: aisle), OfficePoint(x: gap, z: aisle), OfficePoint(x: gap, z: chair.z),
            chair,
        ])
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
    /// The selected Session's conversation, once read; nil until then and after a deselection.
    public private(set) var chat: OfficeChatDocument?
    public private(set) var chatError: String?

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

    /// Picks a Session; its conversation is read by `loadChat`, and dropped when it is deselected.
    public func select(_ id: String?) {
        guard selectedId != id else { return }
        selectedId = id
        chat = nil
        chatError = nil
    }

    /// Reads the CLI once; a failure keeps the last good office and says why. While a Session is
    /// selected, its conversation is read too, so the chat panel follows the agent.
    public func refresh(now: Date = Date()) async {
        do {
            let document = try await client.office()
            apply(document, now: now)
            errorText = nil
        } catch {
            errorText = MenuModel.message(for: error)
        }
        if selectedId != nil { await loadChat() }
    }

    /// Reads the selected Session's conversation; a failure keeps the last one read and says why.
    /// An answer for a Session that is no longer selected is dropped.
    public func loadChat() async {
        guard let session = selected else { return }
        do {
            let document = try await client.chat(agent: session.agent, sessionId: session.sessionId)
            guard selectedId == session.id else { return }
            chat = document
            chatError = nil
        } catch {
            guard selectedId == session.id else { return }
            chatError = MenuModel.message(for: error)
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
        if let id = selectedId, entries[id] == nil { select(nil) }
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
